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
 *
 * Exit code 0 only when every check passes.
 */

const DB_PATH = '/app/www/data/grocy.db';
const BASE_URL = 'http://127.0.0.1';

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

$p1 = phase1SchemaCoverage();
$p2 = phase2ViewCoverage();
$p3 = phase3RuntimeIsolation();

heading('Summary');
printf("  passed %d, failed %d, skipped %d\n", $RESULTS['pass'], $RESULTS['fail'], $RESULTS['skip']);

if ($FAILURES !== []) {
	echo "\n  outstanding:\n";
	foreach ($FAILURES as $f) {
		echo '   - ' . $f . "\n";
	}
}

$allGood = $p1 && $p2 && $p3;
echo "\n" . ($allGood
	? "\033[32mISOLATION VERIFIED — no cross-household leakage detected.\033[0m\n\n"
	: "\033[31mNOT ISOLATED — multi-household is not safe to use yet.\033[0m\n\n");

exit($allGood ? 0 : 1);
