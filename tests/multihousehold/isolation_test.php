<?php

/**
 * Multi-household isolation test harness.
 *
 * Written BEFORE the feature, deliberately. It encodes the contract that
 * "more than one household in the same app" has to satisfy, so it fails
 * honestly today and turns green as the implementation lands. Written
 * afterwards it would only ratify whatever got built.
 *
 * Run:  ./dev.sh test
 *
 * THE CONTRACT
 *   1. A `households` table exists.
 *   2. Every household-scoped table carries a `household_id`.
 *   3. Every view over household-scoped data EXPOSES `household_id`, so the
 *      application layer is able to filter it. A view that cannot be filtered
 *      is a leak waiting to happen.
 *   4. Two users in different households, hitting the same API, never see each
 *      other's rows. This is the one that actually matters — 1-3 are the
 *      preconditions that make it achievable.
 *   5. A household created through the API is immediately USABLE. Correct
 *      isolation is not the same as a working feature: a household with no
 *      master data looks fine and silently drops writes.
 *
 * Exit code 0 only when every check passes.
 */

const DB_PATH = '/app/www/data/grocy.db';
const BASE_URL = 'http://127.0.0.1';

// Phase 5 needs to know whether self-registration is enabled. Grocy's config
// defines settings as GROCY_* constants via a Setting() helper, which does not
// exist in this standalone script, so shim it and load the same file the app does.
if (!function_exists('Setting')) {
    function Setting(string $name, $value): void
    {
        if (!defined('GROCY_' . $name)) {
            define('GROCY_' . $name, $value);
        }
    }
    function DefaultUserSetting(string $name, $value): void
    {
        // not needed here, but config.php calls it
    }
    $configFile = '/app/www/data/config.php';
    if (file_exists($configFile)) {
        include $configFile;
    }
}

/**
 * Tables that are infrastructure or already user-scoped, and therefore do NOT
 * get a household_id. Everything else in the schema must have one.
 *
 * `users` is the special case: a user BELONGS to a household, so it needs the
 * column too, but it is listed separately because it is the join that makes
 * every other scope check work.
 */
const GLOBAL_TABLES = [
	'migrations',            // schema versioning
	'sessions',              // auth sessions, scoped via their user
	'api_keys',              // scoped via their user
	'user_settings',         // per user, not per household
	'user_permissions',      // per user
	'permission_hierarchy',  // static permission definitions
	// Rate-limit ledger for /register. Keyed by IP and written BEFORE any
	// household exists, so it cannot be household-scoped even in principle.
	'registration_attempts',
];

const USERS_TABLE = 'users';

// ---------------------------------------------------------------- plumbing --

function db(): PDO
{
	static $pdo = null;
	if ($pdo === null) {
		$pdo = new \Pdo\Sqlite('sqlite:' . DB_PATH);
		$pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);

		// Grocy registers these in DatabaseService and its views depend on them.
		// Without them even `PRAGMA table_info(<view>)` fails, because SQLite has
		// to prepare the view definition. Stubs are enough for schema inspection.
		$pdo->createFunction('regexp', fn ($pattern, $value) => 0);
		$pdo->createFunction('grocy_user_setting', fn ($value) => null);
		$pdo->createFunction('ceil', fn ($value) => ceil((float)$value));
	}
	return $pdo;
}

function columnsOf(string $object): array
{
	$cols = [];
	foreach (db()->query('PRAGMA table_info(' . $object . ')') as $c) {
		$cols[] = $c['name'];
	}
	return $cols;
}

function tables(): array
{
	$out = [];
	foreach (db()->query('SELECT name FROM sqlite_master WHERE type = "table" AND name NOT LIKE "sqlite_%" ORDER BY name') as $r) {
		$out[] = $r['name'];
	}
	return $out;
}

function views(): array
{
	$out = [];
	foreach (db()->query('SELECT name FROM sqlite_master WHERE type = "view" ORDER BY name') as $r) {
		$out[] = $r['name'];
	}
	return $out;
}

function objectExists(string $name): bool
{
	$st = db()->prepare('SELECT COUNT(*) FROM sqlite_master WHERE name = ?');
	$st->execute([$name]);
	return (int)$st->fetchColumn() > 0;
}

/** Minimal HTTP client against the local instance, authenticated by API key. */
function api(string $method, string $path, ?string $apiKey = null, ?array $body = null): array
{
	$ch = curl_init(BASE_URL . '/api' . $path);
	$headers = ['Accept: application/json', 'Content-Type: application/json'];
	if ($apiKey !== null) {
		$headers[] = 'GROCY-API-KEY: ' . $apiKey;
	}
	curl_setopt_array($ch, [
		CURLOPT_RETURNTRANSFER => true,
		CURLOPT_CUSTOMREQUEST => $method,
		CURLOPT_HTTPHEADER => $headers,
		CURLOPT_TIMEOUT => 20,
	]);
	if ($body !== null) {
		curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($body));
	}
	$raw = curl_exec($ch);
	$status = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
	curl_close($ch);
	return ['status' => $status, 'body' => json_decode((string)$raw, true), 'raw' => (string)$raw];
}

// ------------------------------------------------------------- reporting ---

$RESULTS = ['pass' => 0, 'fail' => 0, 'skip' => 0];
$FAILURES = [];

function heading(string $text): void
{
	echo "\n\033[1m" . $text . "\033[0m\n" . str_repeat('-', strlen($text)) . "\n";
}

function check(string $label, bool $ok, string $detail = ''): bool
{
	global $RESULTS, $FAILURES;
	if ($ok) {
		$RESULTS['pass']++;
		echo "  \033[32mPASS\033[0m  $label\n";
	} else {
		$RESULTS['fail']++;
		$FAILURES[] = $label . ($detail !== '' ? ' — ' . $detail : '');
		echo "  \033[31mFAIL\033[0m  $label" . ($detail !== '' ? "\n          $detail" : '') . "\n";
	}
	return $ok;
}

function skip(string $label, string $why): void
{
	global $RESULTS;
	$RESULTS['skip']++;
	echo "  \033[33mSKIP\033[0m  $label — $why\n";
}

/**
 * Clears the registration rate-limit window.
 *
 * The limits are per-IP and every check in this harness comes from the same IP,
 * so without this, phase 5's guard tests would be refused for being rate limited
 * rather than for the reason under test — passing for the wrong reason.
 */
function resetRegistrationLimits(): void
{
    if (objectExists('registration_attempts')) {
        db()->exec('DELETE FROM registration_attempts');
    }
}

// ------------------------------------------------------- phase 1: schema ---

function phase1SchemaCoverage(): bool
{
	heading('Phase 1 — schema: every household-scoped table carries household_id');

	$householdsExists = objectExists('households');
	check('`households` table exists', $householdsExists,
		$householdsExists ? '' : 'create it in a migration: id, name, row_created_timestamp');

	$scoped = array_values(array_diff(tables(), GLOBAL_TABLES, [USERS_TABLE, 'households']));
	$missing = [];
	foreach ($scoped as $t) {
		if (!in_array('household_id', columnsOf($t), true)) {
			$missing[] = $t;
		}
	}
	$have = count($scoped) - count($missing);
	echo "\n  coverage: $have/" . count($scoped) . " scoped tables have household_id\n\n";

	check('every household-scoped table has household_id', $missing === [],
		$missing === [] ? '' : count($missing) . ' missing: ' . implode(', ', $missing));

	$usersScoped = $householdsExists && in_array('household_id', columnsOf(USERS_TABLE), true);
	check('`users` carries household_id (the join everything else relies on)', $usersScoped);

	return $householdsExists && $missing === [] && $usersScoped;
}

// -------------------------------------------------------- phase 2: views ---

function phase2ViewCoverage(): bool
{
	heading('Phase 2 — views: every view exposes household_id so it CAN be filtered');

	// Views built purely from global tables never need scoping.
	$globalOnlyViews = ['permission_tree', 'user_permissions_resolved', 'uihelper_user_permissions'];

	$missing = [];
	$all = views();
	foreach ($all as $v) {
		if (in_array($v, $globalOnlyViews, true)) {
			continue;
		}
		if (!in_array('household_id', columnsOf($v), true)) {
			$missing[] = $v;
		}
	}
	$relevant = count($all) - count($globalOnlyViews);
	$have = $relevant - count($missing);
	echo "\n  coverage: $have/$relevant views expose household_id\n\n";

	if ($missing !== []) {
		echo "  still unscoped:\n";
		foreach (array_chunk($missing, 3) as $row) {
			echo '    ' . implode(', ', $row) . "\n";
		}
		echo "\n";
	}

	return check('every content view exposes household_id', $missing === [],
		$missing === [] ? '' : count($missing) . ' of ' . $relevant . ' views cannot be filtered by household');
}

// ------------------------------------------------------ phase 3: runtime ---

/**
 * The test that actually matters: two users, two households, same API.
 * Seeds a uniquely-named row in each household, then asserts neither user can
 * see the other's — across every entity the API exposes.
 */
function phase3RuntimeIsolation(): bool
{
	heading('Phase 3 — runtime: two accounts, two households, zero cross-visibility');

	if (!objectExists('households') || !in_array('household_id', columnsOf(USERS_TABLE), true)) {
		skip('runtime isolation probes', 'households/users.household_id do not exist yet');
		echo "\n  This is the decisive phase. It stays skipped until Phase 1 passes.\n";
		return false;
	}

	$stamp = 'ISOTEST' . bin2hex(random_bytes(3));
	$fixtures = seedTwoHouseholds($stamp);
	if ($fixtures === null) {
		return check('seed two households with a user + API key each', false, 'seeding failed');
	}
	check('seed two households with a user + API key each', true);

	// Entities worth probing — the ones that hold household content.
	$entities = [
		'products', 'locations', 'shopping_list', 'shopping_lists', 'shopping_locations',
		'product_groups', 'quantity_units', 'recipes', 'chores', 'tasks', 'batteries',
		'equipment', 'meal_plan', 'task_categories',
	];

	$ok = true;
	foreach ($entities as $entity) {
		// A probe is only meaningful if the OTHER household actually owns a
		// tagged row. Without this guard an entity with no fixture "passes"
		// vacuously — the failure mode that makes leak tests worthless.
		$seededIn = [];
		foreach (['A', 'B'] as $letter) {
			if (in_array($entity, $fixtures[$letter]['seeded'], true)) {
				$seededIn[] = $letter;
			}
		}
		if (count($seededIn) < 2) {
			skip("$entity isolation", 'no fixture in ' . (count($seededIn) === 1 ? 'one household' : 'either household') . ' — inconclusive, not passing');
			continue;
		}

		// POSITIVE CONTROL. If a household cannot see its OWN row, the negative
		// probe below is meaningless — it would "pass" simply because the
		// endpoint returns nothing. Every vacuous pass this harness has produced
		// so far was caught by reasoning; this catches them automatically.
		foreach (['A', 'B'] as $letter) {
			$res = api('GET', '/objects/' . $entity, $fixtures[$letter]['apiKey']);
			$seesOwn = false;
			if ($res['status'] === 200 && is_array($res['body'])) {
				foreach ($res['body'] as $row) {
					if (str_contains((string)json_encode($row), $stamp . '-' . $letter)) {
						$seesOwn = true;
					}
				}
			}
			$ok = check("household $letter CAN see its own $entity (control)", $seesOwn,
				$seesOwn ? '' : 'endpoint returned nothing for its own data — the isolation probe below proves nothing') && $ok;
		}

		foreach ([['A', 'B'], ['B', 'A']] as [$self, $other]) {
			$res = api('GET', '/objects/' . $entity, $fixtures[$self]['apiKey']);
			if ($res['status'] !== 200 || !is_array($res['body'])) {
				$ok = check("GET /objects/$entity as household $self", false,
					'HTTP ' . $res['status'] . ' ' . substr($res['raw'], 0, 120)) && $ok;
				continue;
			}
			$leaked = [];
			foreach ($res['body'] as $row) {
				$blob = json_encode($row);
				if (str_contains((string)$blob, $stamp . '-' . $other)) {
					$leaked[] = $row['id'] ?? '?';
				}
			}
			$ok = check(
				"household $self cannot see household $other's $entity",
				$leaked === [],
				$leaked === [] ? '' : 'LEAKED ' . count($leaked) . ' row(s): id ' . implode(', ', $leaked)
			) && $ok;
		}
	}

	// Stock is the highest-value leak: it is the actual contents of a fridge.
	// Matched on the other household's product_id, not just the tag string, because
	// /stock does not necessarily echo the product name back.
	if (!in_array('stock', $fixtures['A']['seeded'], true) || !in_array('stock', $fixtures['B']['seeded'], true)) {
		skip('stock isolation', 'stock fixture missing in one or both households — inconclusive, not passing');
		$ok = false;
	} else {
		// Positive control for stock too — /stock reads the stock_current view.
		foreach (['A', 'B'] as $letter) {
			$ownProductId = (int)db()->query(
				'SELECT id FROM products WHERE name LIKE "' . $stamp . '-' . $letter . '%" LIMIT 1'
			)->fetchColumn();
			$res = api('GET', '/stock', $fixtures[$letter]['apiKey']);
			$seesOwn = false;
			if ($res['status'] === 200 && is_array($res['body'])) {
				foreach ($res['body'] as $row) {
					if (isset($row['product_id']) && (int)$row['product_id'] === $ownProductId) {
						$seesOwn = true;
					}
				}
			}
			$ok = check("household $letter CAN see its own stock (control)", $seesOwn,
				$seesOwn ? '' : '/stock returned nothing for its own entry — the isolation probe below proves nothing') && $ok;
		}

		foreach ([['A', 'B'], ['B', 'A']] as [$self, $other]) {
			$otherProductId = (int)db()->query(
				'SELECT id FROM products WHERE name LIKE "' . $stamp . '-' . $other . '%" LIMIT 1'
			)->fetchColumn();

			$res = api('GET', '/stock', $fixtures[$self]['apiKey']);
			$leaked = [];
			if ($res['status'] === 200 && is_array($res['body'])) {
				foreach ($res['body'] as $row) {
					$byId = isset($row['product_id']) && (int)$row['product_id'] === $otherProductId;
					$byTag = str_contains((string)json_encode($row), $stamp . '-' . $other);
					if ($byId || $byTag) {
						$leaked[] = $row['product_id'] ?? '?';
					}
				}
			}
			$ok = check("household $self cannot see household $other's stock", $leaked === [],
				$leaked === [] ? '' : 'LEAKED stock for product_id ' . implode(', ', $leaked)) && $ok;
		}
	}

	// SAME-NAME check. Two households must be able to use the SAME name for the
	// same kind of thing — both can have a "Fridge", a "Milk", a "Shopping list".
	// The isolation probes above cannot catch this, because their fixtures are
	// stamped per household and so never collide. Grocy declares
	// `name TEXT NOT NULL UNIQUE` on 11 content tables, which is global.
	$shared = $stamp . '-shared-name';
	foreach (['locations', 'quantity_units', 'product_groups', 'shopping_lists', 'chores', 'batteries'] as $entity) {
		$created = [];
		foreach (['A', 'B'] as $letter) {
			$body = ['name' => $shared];
			if ($entity === 'chores') {
				$body['period_type'] = 'manually';
			}
			$res = api('POST', '/objects/' . $entity, $fixtures[$letter]['apiKey'], $body);
			if ($res['status'] >= 200 && $res['status'] < 300) {
				$created[] = $letter;
			}
		}
		$ok = check(
			"both households can have a $entity called the same thing",
			count($created) === 2,
			count($created) === 2 ? '' : 'only household ' . (implode(',', $created) ?: 'none') . ' could — a global UNIQUE(name) blocks the second household'
		) && $ok;
	}

	// A household whose default shopping list is NOT id 1 must still be able to
	// use it. Callers historically passed a literal list_id of 1, which under
	// household scoping matches nothing and silently no-ops.
	foreach (['A', 'B'] as $letter) {
		$listId = (int)db()->query(
			'SELECT id FROM shopping_lists WHERE household_id = ' . $fixtures[$letter]['householdId'] . ' ORDER BY id LIMIT 1'
		)->fetchColumn();
		$productId = (int)db()->query(
			'SELECT id FROM products WHERE name LIKE "' . $stamp . '-' . $letter . '%" LIMIT 1'
		)->fetchColumn();

		if ($listId === 0 || $productId === 0) {
			skip("household $letter can use its own shopping list", 'fixture missing');
			continue;
		}

		// deliberately omit list_id, forcing the default path
		api('POST', '/stock/shoppinglist/add-product', $fixtures[$letter]['apiKey'], [
			'product_id' => $productId,
			'product_amount' => 3,
		]);

		$landed = (int)db()->query(
			'SELECT COUNT(*) FROM shopping_list WHERE product_id = ' . $productId . ' AND shopping_list_id = ' . $listId
		)->fetchColumn();

		$ok = check("household $letter can add to its own shopping list without naming it (list id $listId)", $landed > 0,
			$landed > 0 ? '' : 'nothing landed — the literal list_id 1 default silently no-ops for this household') && $ok;
	}

	// Same real-world barcode in two households. Barcodes are global facts (an
	// EAN identifies a product worldwide), so two households stocking the same
	// item WILL collide on a globally-unique barcode index.
	$sharedBarcode = '4' . substr((string)abs(crc32($stamp)), 0, 12);
	$barcodeOk = [];
	foreach (['A', 'B'] as $letter) {
		$productId = (int)db()->query(
			'SELECT id FROM products WHERE name LIKE "' . $stamp . '-' . $letter . '%" LIMIT 1'
		)->fetchColumn();
		if ($productId === 0) {
			continue;
		}
		$res = api('POST', '/objects/product_barcodes', $fixtures[$letter]['apiKey'], [
			'product_id' => $productId,
			'barcode' => $sharedBarcode,
		]);
		if ($res['status'] >= 200 && $res['status'] < 300) {
			$barcodeOk[] = $letter;
		}
	}
	$ok = check('both households can stock the same barcode', count($barcodeOk) === 2,
		count($barcodeOk) === 2 ? '' : 'only household ' . (implode(',', $barcodeOk) ?: 'none') . ' could — ix_product_barcodes is globally unique') && $ok;

	// Same user-defined entity name in two households.
	$entOk = [];
	foreach (['A', 'B'] as $letter) {
		$res = api('POST', '/objects/userentities', $fixtures[$letter]['apiKey'], [
			'name' => $stamp . '-shared-entity',
			'caption' => 'Shared',
			'description' => '',
			'show_in_sidebar_menu' => 0,
		]);
		if ($res['status'] >= 200 && $res['status'] < 300) {
			$entOk[] = $letter;
		}
	}
	$ok = check('both households can have a userentity called the same thing', count($entOk) === 2,
		count($entOk) === 2 ? '' : 'only household ' . (implode(',', $entOk) ?: 'none') . ' could — UNIQUE(name) is global') && $ok;

	cleanupFixtures($stamp);
	return $ok;
}

/** Creates two households, a user and API key in each, and one product each. */
function seedTwoHouseholds(string $stamp): ?array
{
	try {
		$pdo = db();
		$out = [];
		foreach (['A', 'B'] as $letter) {
			$pdo->prepare('INSERT INTO households (name) VALUES (?)')->execute([$stamp . '-household-' . $letter]);
			$householdId = (int)$pdo->lastInsertId();

			$username = strtolower($stamp . '-user-' . $letter);
			$pdo->prepare('INSERT INTO users (username, first_name, last_name, password, household_id) VALUES (?, ?, ?, ?, ?)')
				->execute([$username, 'Iso', $letter, password_hash('test', PASSWORD_DEFAULT), $householdId]);
			$userId = (int)$pdo->lastInsertId();

			// full permissions, so a failure is a real leak and not a 403
			$pdo->prepare('INSERT INTO user_permissions (user_id, permission_id) VALUES (?, 1)')->execute([$userId]);

			$apiKey = bin2hex(random_bytes(20));
			$pdo->prepare('INSERT INTO api_keys (api_key, user_id, expires, key_type) VALUES (?, ?, "2999-12-31 23:59:59", "default")')
				->execute([$apiKey, $userId]);

			$out[$letter] = [
				'householdId' => $householdId,
				'userId' => $userId,
				'apiKey' => $apiKey,
				'seeded' => seedEntityFixtures($stamp, $letter, $householdId),
			];
		}
		return $out;
	} catch (Throwable $e) {
		echo '  seeding error: ' . $e->getMessage() . "\n";
		return null;
	}
}

/**
 * Puts one uniquely-tagged row into each probed entity for a household, so that
 * a leak has something to leak. Returns the entities actually seeded — anything
 * missing is reported as inconclusive rather than silently passing.
 */
function seedEntityFixtures(string $stamp, string $letter, int $householdId): array
{
	$pdo = db();
	$tag = $stamp . '-' . $letter;
	$seeded = [];

	// chores additionally requires period_type.
	try {
		$pdo->prepare('INSERT INTO chores (name, period_type, household_id) VALUES (?, "manually", ?)')
			->execute([$tag . '-chores', $householdId]);
		$seeded[] = 'chores';
	} catch (Throwable $e) {
	}

	// Simple name-only master data.
	foreach (['locations', 'quantity_units', 'product_groups', 'shopping_locations',
		'recipes', 'tasks', 'batteries', 'equipment', 'task_categories',
		'shopping_lists'] as $entity) {
		try {
			$pdo->prepare("INSERT INTO $entity (name, household_id) VALUES (?, ?)")
				->execute([$tag . '-' . $entity, $householdId]);
			$seeded[] = $entity;
		} catch (Throwable $e) {
			// entity has required columns beyond name — handled below or skipped
		}
	}

	// products needs a location and quantity unit from the SAME household.
	try {
		$loc = $pdo->query('SELECT id FROM locations WHERE household_id = ' . $householdId . ' LIMIT 1')->fetchColumn();
		$qu = $pdo->query('SELECT id FROM quantity_units WHERE household_id = ' . $householdId . ' LIMIT 1')->fetchColumn();
		if ($loc && $qu) {
			$pdo->prepare('INSERT INTO products (name, location_id, qu_id_purchase, qu_id_stock, household_id) VALUES (?, ?, ?, ?, ?)')
				->execute([$tag . '-product', $loc, $qu, $qu, $householdId]);
			$seeded[] = 'products';
		}
	} catch (Throwable $e) {
	}

	// shopping_list entries are note lines, not named rows.
	try {
		$list = $pdo->query('SELECT id FROM shopping_lists WHERE household_id = ' . $householdId . ' LIMIT 1')->fetchColumn();
		if ($list) {
			$pdo->prepare('INSERT INTO shopping_list (shopping_list_id, amount, note, household_id) VALUES (?, 1, ?, ?)')
				->execute([$list, $tag . '-shoppinglistitem', $householdId]);
			$seeded[] = 'shopping_list';
		}
	} catch (Throwable $e) {
	}

	// meal_plan needs a day and carries free text in `note`.
	try {
		$pdo->prepare('INSERT INTO meal_plan (day, type, note, household_id) VALUES ("2030-01-01", "note", ?, ?)')
			->execute([$tag . '-mealplan', $householdId]);
		$seeded[] = 'meal_plan';
	} catch (Throwable $e) {
	}

	// stock: the highest-value leak, needs a product of this household.
	try {
		$prod = $pdo->query('SELECT id FROM products WHERE household_id = ' . $householdId . ' AND name LIKE "' . $tag . '%" LIMIT 1')->fetchColumn();
		if ($prod) {
			// stock_id is a required opaque identifier for the stock entry
			$pdo->prepare('INSERT INTO stock (product_id, amount, best_before_date, stock_id, household_id) VALUES (?, 5, "2030-01-01", ?, ?)')
				->execute([$prod, strtolower($tag) . '-stockentry', $householdId]);
			$seeded[] = 'stock';
		}
	} catch (Throwable $e) {
	}

	return $seeded;
}

function cleanupFixtures(string $stamp): void
{
	try {
		$pdo = db();
		$pdo->exec('DELETE FROM api_keys WHERE user_id IN (SELECT id FROM users WHERE username LIKE "' . strtolower($stamp) . '%")');
		$pdo->exec('DELETE FROM user_permissions WHERE user_id IN (SELECT id FROM users WHERE username LIKE "' . strtolower($stamp) . '%")');
		$pdo->exec('DELETE FROM stock WHERE product_id IN (SELECT id FROM products WHERE name LIKE "' . $stamp . '%")');
		foreach (['products', 'locations', 'quantity_units', 'product_groups', 'shopping_locations',
			'recipes', 'chores', 'tasks', 'batteries', 'equipment', 'task_categories', 'shopping_lists'] as $entity) {
			try {
				$pdo->exec('DELETE FROM ' . $entity . ' WHERE name LIKE "' . $stamp . '%"');
			} catch (Throwable $e) {
			}
		}
		foreach (['locations', 'quantity_units', 'product_groups', 'shopping_lists', 'chores', 'batteries'] as $entity) {
			try {
				$pdo->exec('DELETE FROM ' . $entity . ' WHERE name LIKE "' . $stamp . '-shared-name%"');
			} catch (Throwable $e) {
			}
		}
		$pdo->exec('DELETE FROM product_barcodes WHERE product_id IN (SELECT id FROM products WHERE name LIKE "' . $stamp . '%")');
		$pdo->exec('DELETE FROM userentities WHERE name LIKE "' . $stamp . '%"');
		$pdo->exec('DELETE FROM shopping_list WHERE note LIKE "' . $stamp . '%"');
		$pdo->exec('DELETE FROM meal_plan WHERE note LIKE "' . $stamp . '%"');
		$pdo->exec('DELETE FROM users WHERE username LIKE "' . strtolower($stamp) . '%"');
		$pdo->exec('DELETE FROM households WHERE name LIKE "' . $stamp . '%"');
	} catch (Throwable $e) {
		echo "  cleanup warning: " . $e->getMessage() . "\n";
	}
}

// ------------------------------------------------------------------ main ---

echo "\n\033[1mGrocy multi-household isolation harness\033[0m\n";
echo 'database: ' . DB_PATH . "\n";

/**
 * Phase 4: a household created through the API must be immediately USABLE.
 *
 * Isolation being correct is not the same as the feature working. A household
 * with no master data looks fine and silently drops writes, so this checks the
 * creation path end to end rather than just the schema.
 */
function phase4HouseholdManagement(): bool
{
	heading('Phase 4 — household management: created via API, usable immediately');

	if (!objectExists('households')) {
		skip('household management', 'households table does not exist');
		return false;
	}

	// An admin key on household 1, i.e. how a real operator would call this.
	$adminKey = bin2hex(random_bytes(20));
	db()->prepare('INSERT INTO api_keys (api_key, user_id, expires, key_type) VALUES (?, 1, "2999-12-31 23:59:59", "default")')
		->execute([$adminKey]);

	$name = 'PHASE4-' . bin2hex(random_bytes(3));
	$created = api('POST', '/households', $adminKey, ['name' => $name]);
	$householdId = $created['body']['created_object_id'] ?? null;

	$ok = check('POST /households creates a household', $householdId !== null,
		$householdId !== null ? '' : 'HTTP ' . $created['status'] . ' ' . substr($created['raw'], 0, 120));

	if ($householdId === null) {
		db()->exec('DELETE FROM api_keys WHERE api_key = "' . $adminKey . '"');
		return false;
	}

	// The whole point: it must arrive with the master data grocy assumes exists.
	foreach (['shopping_lists', 'locations', 'quantity_units'] as $table) {
		$count = (int)db()->query('SELECT COUNT(*) FROM ' . $table . ' WHERE household_id = ' . (int)$householdId)->fetchColumn();
		$ok = check("new household has a default $table row", $count > 0,
			$count > 0 ? '' : 'a household without this silently no-ops on ordinary operations') && $ok;
	}

	$dupe = api('POST', '/households', $adminKey, ['name' => $name]);
	$ok = check('duplicate household name is rejected', $dupe['status'] >= 400) && $ok;

	$noName = api('POST', '/households', $adminKey, ['name' => '   ']);
	$ok = check('blank household name is rejected', $noName['status'] >= 400) && $ok;

	$renamed = api('PUT', '/households/' . $householdId, $adminKey, ['name' => $name . '-renamed']);
	$ok = check('PUT /households/{id} renames', $renamed['status'] < 300) && $ok;

	// Member assignment is the bootstrap path: a household with no members
	// cannot be reached from inside its own scope at all.
	$username = strtolower($name) . '-member';
	db()->prepare('INSERT INTO users (username, password, household_id) VALUES (?, ?, 1)')
		->execute([$username, password_hash('x', PASSWORD_DEFAULT)]);
	$memberId = (int)db()->lastInsertId();

	$added = api('POST', '/households/' . $householdId . '/members', $adminKey, ['user_id' => $memberId]);
	$ok = check('POST /households/{id}/members moves a user in', $added['status'] < 300,
		$added['status'] < 300 ? '' : 'HTTP ' . $added['status']) && $ok;

	$landed = (int)db()->query('SELECT household_id FROM users WHERE id = ' . $memberId)->fetchColumn();
	$ok = check('the user actually landed in the new household', $landed === (int)$householdId, "got $landed") && $ok;

	$members = api('GET', '/households/' . $householdId . '/members', $adminKey);
	$ok = check('GET /households/{id}/members lists them', is_array($members['body']) && count($members['body']) === 1) && $ok;

	// Guards
	$delWithMember = api('DELETE', '/households/' . $householdId, $adminKey);
	$ok = check('deleting a household with members is refused', $delWithMember['status'] >= 400,
		'otherwise its users are stranded on a household_id that no longer exists') && $ok;

	$delFirst = api('DELETE', '/households/1', $adminKey);
	$ok = check('deleting the first household is refused', $delFirst['status'] >= 400) && $ok;

	$badAssign = api('POST', '/households/999999/members', $adminKey, ['user_id' => $memberId]);
	$ok = check('assigning to a nonexistent household is refused', $badAssign['status'] >= 400) && $ok;

	// Now empty it and confirm deletion works
	db()->exec('UPDATE users SET household_id = 1 WHERE id = ' . $memberId);
	$delEmpty = api('DELETE', '/households/' . $householdId, $adminKey);
	$ok = check('an empty household can be deleted', $delEmpty['status'] < 300,
		$delEmpty['status'] < 300 ? '' : 'HTTP ' . $delEmpty['status']) && $ok;

	// cleanup
	db()->exec('DELETE FROM users WHERE id = ' . $memberId);
	db()->exec('DELETE FROM api_keys WHERE api_key = "' . $adminKey . '"');
	foreach (['shopping_lists', 'locations', 'quantity_units'] as $table) {
		db()->exec('DELETE FROM ' . $table . ' WHERE household_id = ' . (int)$householdId);
	}
	db()->exec('DELETE FROM households WHERE id = ' . (int)$householdId);

	return $ok;
}

/**
 * Phase 5: self-registration, and the permission boundary it depends on.
 *
 * Self-registration turns a mild gap into a serious one: if the /households
 * endpoints are unguarded, any stranger who signs up can rename or delete other
 * people's households and move users between them. So the boundary is tested
 * here alongside the feature, not assumed.
 */
function phase5SelfRegistration(): bool
{
	heading('Phase 5 — self-registration and its permission boundary');

	$enabled = defined('GROCY_FEATURE_FLAG_SELF_REGISTRATION') && GROCY_FEATURE_FLAG_SELF_REGISTRATION === true;
	$stamp = 'reg' . bin2hex(random_bytes(3));
	$ok = true;

	resetRegistrationLimits();

	if (!$enabled) {
		// The safe default. Verify it is genuinely closed, not merely hidden.
		$res = api('POST', '/register', null, [
			'username' => $stamp,
			'password' => 'supersecret1',
			'household_name' => $stamp . ' Home',
		]);
		$ok = check('with the flag off, POST /register is refused', $res['status'] >= 400,
			'HTTP ' . $res['status']) && $ok;

		$created = (int)db()->query('SELECT COUNT(*) FROM users WHERE username = "' . $stamp . '"')->fetchColumn();
		$ok = check('with the flag off, no user is created', $created === 0) && $ok;

		echo "\n  FEATURE_FLAG_SELF_REGISTRATION is off (the default). Set it to true in\n";
		echo "  data/config.php to exercise the rest of this phase.\n";
		return $ok;
	}

	// --- flag on ---------------------------------------------------------
	$res = api('POST', '/register', null, [
		'username' => $stamp,
		'password' => 'supersecret1',
		'household_name' => $stamp . ' Home',
	]);
	$userId = $res['body']['created_object_id'] ?? null;
	$ok = check('anyone can register without an account', $userId !== null,
		$userId !== null ? '' : 'HTTP ' . $res['status'] . ' ' . substr($res['raw'], 0, 120)) && $ok;

	if ($userId === null) {
		return false;
	}

	$householdId = (int)db()->query('SELECT household_id FROM users WHERE id = ' . (int)$userId)->fetchColumn();
	$ok = check('registration created a NEW household', $householdId > 1, "household_id=$householdId") && $ok;

	foreach (['shopping_lists', 'locations', 'quantity_units'] as $table) {
		$n = (int)db()->query('SELECT COUNT(*) FROM ' . $table . ' WHERE household_id = ' . $householdId)->fetchColumn();
		$ok = check("the registered household has a default $table row", $n > 0) && $ok;
	}

	// The security-critical assertion.
	$perms = db()->query(
		'SELECT ph.name FROM user_permissions up JOIN permission_hierarchy ph ON up.permission_id = ph.id WHERE up.user_id = ' . (int)$userId
	)->fetchAll(\PDO::FETCH_COLUMN);
	$ok = check('a self-registered user is NOT granted ADMIN', !in_array('ADMIN', $perms, true),
		'ADMIN would let any stranger manage or delete other households') && $ok;
	$ok = check('a self-registered user CAN run their own household', in_array('STOCK', $perms, true) && in_array('SHOPPINGLIST', $perms, true)) && $ok;

	// Give them a key and prove the boundary holds over HTTP, not just in the DB.
	$key = bin2hex(random_bytes(20));
	db()->prepare('INSERT INTO api_keys (api_key, user_id, expires, key_type) VALUES (?, ?, "2999-12-31 23:59:59", "default")')
		->execute([$key, $userId]);

	foreach ([['GET', '/households'], ['POST', '/households'], ['DELETE', '/households/1'], ['GET', '/households/1/members'], ['POST', '/households/1/members']] as [$method, $path]) {
		$r = api($method, $path, $key, ['name' => 'hijack', 'user_id' => 1]);
		$ok = check("registered user is refused $method $path", $r['status'] === 403,
			'HTTP ' . $r['status'] . ' — anything but 403 lets a stranger touch other households') && $ok;
	}

	// They can still invite into their OWN household, which is the point.
	$member = api('POST', '/users', $key, [
		'username' => $stamp . '-member',
		'first_name' => 'M',
		'last_name' => 'M',
		'password' => 'anotherpass1',
	]);
	$ok = check('registered user can add a member to their own household', $member['status'] < 300,
		'HTTP ' . $member['status']) && $ok;

	$memberHousehold = (int)db()->query(
		'SELECT household_id FROM users WHERE username = "' . $stamp . '-member"'
	)->fetchColumn();
	$ok = check('the invited member landed in the SAME household', $memberHousehold === $householdId,
		"got $memberHousehold, expected $householdId") && $ok;

	// Guards
	resetRegistrationLimits();
	$dupe = api('POST', '/register', null, ['username' => $stamp, 'password' => 'supersecret1', 'household_name' => 'Other']);
	$ok = check('duplicate username is rejected', $dupe['status'] >= 400) && $ok;

	resetRegistrationLimits();
	$weak = api('POST', '/register', null, ['username' => $stamp . 'x', 'password' => 'short', 'household_name' => 'Weak']);
	$ok = check('a password under 8 characters is rejected', $weak['status'] >= 400) && $ok;

	resetRegistrationLimits();
	$blank = api('POST', '/register', null, ['username' => $stamp . 'y', 'password' => 'supersecret1', 'household_name' => '   ']);
	$ok = check('a blank household name is rejected', $blank['status'] >= 400) && $ok;

	// cleanup
	db()->exec('DELETE FROM api_keys WHERE api_key = "' . $key . '"');
	db()->exec('DELETE FROM user_permissions WHERE user_id IN (SELECT id FROM users WHERE username LIKE "' . $stamp . '%")');
	db()->exec('DELETE FROM users WHERE username LIKE "' . $stamp . '%"');
	foreach (['shopping_lists', 'locations', 'quantity_units'] as $table) {
		db()->exec('DELETE FROM ' . $table . ' WHERE household_id = ' . $householdId);
	}
	db()->exec('DELETE FROM households WHERE id = ' . $householdId);

	return $ok;
}

/**
 * Phase 6: the free abuse protections on the public /register endpoint.
 *
 * /register is unauthenticated and writes to the database, so without limits it
 * can be hammered to fill the disk with households. No third-party CAPTCHA is
 * used deliberately — these cost nothing and add no external dependency.
 */
function phase6RegistrationAbuseProtection(): bool
{
	heading('Phase 6 — abuse protection on the public /register endpoint');

	$enabled = defined('GROCY_FEATURE_FLAG_SELF_REGISTRATION') && GROCY_FEATURE_FLAG_SELF_REGISTRATION === true;

	if (!objectExists('registration_attempts')) {
		return check('registration_attempts table exists', false, 'migration 0260 has not run');
	}
	check('registration_attempts table exists', true);

	if (!$enabled) {
		skip('abuse protection probes', 'self-registration is off, so there is nothing to protect');
		return true;
	}

	$ok = true;
	$long_ago = time() - 60;

	// 1. honeypot
	resetRegistrationLimits();
	$stamp = 'hp' . bin2hex(random_bytes(3));
	$res = api('POST', '/register', null, [
		'username' => $stamp,
		'password' => 'supersecret1',
		'household_name' => $stamp . ' Home',
		'website' => 'http://spam.example',
		'form_rendered_at' => $long_ago,
	]);
	$ok = check('a filled honeypot field is rejected', $res['status'] >= 400) && $ok;
	$created = (int)db()->query('SELECT COUNT(*) FROM users WHERE username = "' . $stamp . '"')->fetchColumn();
	$ok = check('the honeypot request created no user', $created === 0) && $ok;
	$ok = check('the rejection message does not reveal which check tripped',
		($res['body']['error_message'] ?? '') === 'Registration failed') && $ok;

	// 2. impossibly fast submit
	resetRegistrationLimits();
	$stamp = 'fast' . bin2hex(random_bytes(3));
	$res = api('POST', '/register', null, [
		'username' => $stamp,
		'password' => 'supersecret1',
		'household_name' => $stamp . ' Home',
		'form_rendered_at' => time(),
	]);
	$ok = check('an instantly submitted form is rejected', $res['status'] >= 400) && $ok;

	// 3. per-IP throttle. Every attempt counts, successful or not, so invalid
	//    requests cannot be retried for free.
	resetRegistrationLimits();
	$limit = defined('GROCY_SELF_REGISTRATION_MAX_PER_IP_PER_HOUR') ? (int)GROCY_SELF_REGISTRATION_MAX_PER_IP_PER_HOUR : 3;
	$blocked = false;
	$createdIds = [];
	for ($i = 0; $i < $limit + 2; $i++) {
		$stamp = 'rl' . bin2hex(random_bytes(3)) . $i;
		$res = api('POST', '/register', null, [
			'username' => $stamp,
			'password' => 'supersecret1',
			'household_name' => $stamp . ' Home',
			'form_rendered_at' => $long_ago,
		]);
		if (isset($res['body']['created_object_id'])) {
			$createdIds[] = (int)$res['body']['created_object_id'];
		}
		if (str_contains((string)($res['body']['error_message'] ?? ''), 'Too many registration attempts')) {
			$blocked = true;
			break;
		}
	}
	$ok = check("the per-IP throttle blocks after $limit attempts in an hour", $blocked,
		$blocked ? '' : 'the endpoint accepted more than the configured limit') && $ok;
	$ok = check('the throttle allowed no more registrations than the limit', count($createdIds) <= $limit,
		count($createdIds) . ' created, limit ' . $limit) && $ok;

	// 4. hard household cap — the direct defence against filling the disk
	resetRegistrationLimits();
	$cap = defined('GROCY_SELF_REGISTRATION_MAX_HOUSEHOLDS') ? (int)GROCY_SELF_REGISTRATION_MAX_HOUSEHOLDS : 0;
	$ok = check('a household cap is configured', $cap > 0,
		$cap > 0 ? "cap = $cap" : 'unlimited — a public endpoint with no cap can fill the disk') && $ok;

	// cleanup: remove everything this phase created
	resetRegistrationLimits();
	foreach (['hp', 'fast', 'rl'] as $prefix) {
		$rows = db()->query('SELECT id, household_id FROM users WHERE username LIKE "' . $prefix . '%"')->fetchAll(\PDO::FETCH_ASSOC);
		foreach ($rows as $row) {
			db()->exec('DELETE FROM user_permissions WHERE user_id = ' . (int)$row['id']);
			db()->exec('DELETE FROM api_keys WHERE user_id = ' . (int)$row['id']);
			db()->exec('DELETE FROM users WHERE id = ' . (int)$row['id']);
			if ((int)$row['household_id'] > 1) {
				foreach (['shopping_lists', 'locations', 'quantity_units'] as $table) {
					db()->exec('DELETE FROM ' . $table . ' WHERE household_id = ' . (int)$row['household_id']);
				}
				db()->exec('DELETE FROM households WHERE id = ' . (int)$row['household_id']);
			}
		}
	}

	return $ok;
}

$p1 = phase1SchemaCoverage();
$p2 = phase2ViewCoverage();
$p3 = phase3RuntimeIsolation();
$p4 = phase4HouseholdManagement();
$p5 = phase5SelfRegistration();
$p6 = phase6RegistrationAbuseProtection();

heading('Summary');
printf("  passed %d, failed %d, skipped %d\n", $RESULTS['pass'], $RESULTS['fail'], $RESULTS['skip']);

if ($FAILURES !== []) {
	echo "\n  outstanding:\n";
	foreach ($FAILURES as $f) {
		echo '   - ' . $f . "\n";
	}
}

$allGood = $p1 && $p2 && $p3 && $p4 && $p5 && $p6;
echo "\n" . ($allGood
	? "\033[32mISOLATION VERIFIED — no cross-household leakage detected.\033[0m\n\n"
	: "\033[31mNOT ISOLATED — multi-household is not safe to use yet.\033[0m\n\n");

exit($allGood ? 0 : 1);
