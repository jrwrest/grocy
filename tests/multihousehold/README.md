# Multi-household isolation harness

Definition of done for running more than one household in a single Grocy instance.

Written **before** the feature, deliberately. It fails today and turns green as the
implementation lands. Written afterwards it would only ratify whatever got built.

```bash
./dev.sh up      # start the local dev instance
./dev.sh test    # run this harness
```

Exit code is 0 only when every check passes.

## What it checks

**Phase 1 — schema.** Every household-scoped table carries `household_id`. 30 tables
qualify; the 6 exempt ones (`migrations`, `sessions`, `api_keys`, `user_settings`,
`user_permissions`, `permission_hierarchy`) are infrastructure or already user-scoped.
`users` is checked separately — it is the join every other scope check depends on.

**Phase 2 — views.** Every content view *exposes* `household_id`, so the application
layer is able to filter it. 42 of the 45 views qualify (3 are permission views built
only from global tables). A view that cannot be filtered is a leak waiting to happen,
and this is where the real work is — grocy pushes its business logic into SQL views
like `products_resolved` and `stock_current`.

**Phase 3 — runtime.** The one that actually matters: two users in two households hit
the same API and must never see each other's rows. Covers 14 entities plus `/stock`.

## Two design rules it enforces on itself

**No vacuous passes.** A probe only counts if the *other* household genuinely owns a
tagged fixture row. Without that guard an entity with no fixture "passes" because there
was nothing to leak — which is how leak tests end up worthless. Missing fixtures are
reported `SKIP — inconclusive, not passing`, never `PASS`.

**Stock is matched by `product_id`, not just by name**, because `/stock` does not
reliably echo the product name back. String matching alone would pass vacuously.

Both rules were added after the harness was caught doing exactly these things during
its own validation.

## Validating the harness itself

A leak test that cannot fail is worse than none. To prove this one detects real
leakage, scaffold the schema without any application-layer scoping:

```bash
docker exec grocy-dev php -r '
$d = new PDO("sqlite:/app/www/data/grocy.db");
$d->exec("CREATE TABLE IF NOT EXISTS households (id INTEGER PRIMARY KEY, name TEXT, row_created_timestamp DATETIME)");
foreach (["users","products","locations","quantity_units","shopping_lists","shopping_list",
          "meal_plan","stock","recipes","chores","tasks","batteries","equipment",
          "task_categories","product_groups","shopping_locations"] as $t) {
  try { $d->exec("ALTER TABLE $t ADD COLUMN household_id INTEGER DEFAULT 1"); } catch (Throwable $e) {}
}'
./dev.sh test     # expect ~32 failures, 0 skipped — every entity leaking both ways
./dev.sh reset    # back to a virgin database
```

If that produces passes, the harness is broken, not the application.

## Fixtures

Each run stamps its fixtures with a unique `ISOTEST<hex>` prefix and deletes them
afterwards, so it is safe to run repeatedly against a working database. It has only
ever been run against the local dev instance — never point `DB_PATH` at production.
