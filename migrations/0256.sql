-- Multi-household, phase 1: scope every content table to a household.
--
-- Existing installations have exactly one household's worth of data, so every
-- existing row is backfilled to household 1 via the column default. That makes
-- this migration safe to run against a live single-household instance: nothing
-- moves, nothing disappears.
--
-- Deliberately NOT scoped (infrastructure or already user-scoped):
--   migrations, sessions, api_keys, user_settings, user_permissions,
--   permission_hierarchy
--
-- No inline REFERENCES clause: SQLite refuses ADD COLUMN with both a non-NULL
-- default and a foreign key. Referential integrity is enforced in the
-- application layer instead.

CREATE TABLE households (
	id INTEGER PRIMARY KEY,
	name TEXT NOT NULL,
	row_created_timestamp DATETIME DEFAULT (datetime('now', 'localtime'))
);

CREATE UNIQUE INDEX households_name ON households (name);

INSERT INTO households (id, name)
VALUES (1, 'My household');

-- Users belong to a household. This is the join every other scope check relies
-- on: the application resolves the current user's household, then filters.
ALTER TABLE users ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;

-- Content tables ---------------------------------------------------------

ALTER TABLE batteries ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE battery_charge_cycles ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE chores ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE chores_log ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE equipment ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE locations ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE meal_plan ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE meal_plan_sections ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE product_barcodes ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE product_groups ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE products ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE quantity_unit_conversions ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE quantity_units ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE recipes ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE recipes_nestings ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE recipes_pos ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE shopping_list ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE shopping_lists ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE shopping_locations ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE stock ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE stock_log ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE task_categories ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE tasks ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE userentities ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE userfields ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE userfield_values ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE userobjects ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;

-- Derived caches mirror scoped data, so they need the same scope.
ALTER TABLE cache__products_average_price ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE cache__products_last_purchased ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE cache__quantity_unit_conversions_resolved ADD COLUMN household_id INTEGER NOT NULL DEFAULT 1;

-- Indexes on the hot paths ------------------------------------------------

CREATE INDEX products_household_id ON products (household_id);
CREATE INDEX stock_household_id ON stock (household_id);
CREATE INDEX stock_log_household_id ON stock_log (household_id);
CREATE INDEX shopping_list_household_id ON shopping_list (household_id);
CREATE INDEX recipes_household_id ON recipes (household_id);
CREATE INDEX chores_household_id ON chores (household_id);
CREATE INDEX tasks_household_id ON tasks (household_id);
CREATE INDEX users_household_id ON users (household_id);
