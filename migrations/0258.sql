-- Multi-household, phase 5: make UNIQUE(name) per-household.
--
-- Grocy declares `name TEXT NOT NULL UNIQUE` on 11 content tables. That is a
-- GLOBAL constraint, so once a second household exists neither can have a
-- location called "Fridge", a product called "Milk", or a list called
-- "Shopping list" if the other already does. Not a data leak - a hard blocker.
--
-- SQLite cannot drop the implicit index a column-level UNIQUE creates, so each
-- table is rebuilt. No ALTER TABLE ... RENAME is used, because renaming while
-- views reference a just-dropped table is fragile; a plain staging copy is not.
-- Triggers and indexes are dropped with their table and recreated verbatim.
--
-- This file is generated from the live schema, not hand-written.


-- batteries -----------------------------------------------------------
CREATE TABLE batteries__stage AS SELECT * FROM batteries;
DROP TABLE batteries;
CREATE TABLE batteries (
	id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT UNIQUE,
	name TEXT NOT NULL,
	description TEXT,
	used_in TEXT,
	charge_interval_days INTEGER NOT NULL DEFAULT 0,
	row_created_timestamp DATETIME DEFAULT (datetime('now', 'localtime'))
, active TINYINT NOT NULL DEFAULT 1 CHECK(active IN (0, 1)), household_id INTEGER NOT NULL DEFAULT 1,
	UNIQUE(name, household_id)
);
INSERT INTO batteries SELECT * FROM batteries__stage;
DROP TABLE batteries__stage;
CREATE INDEX ix_batteries_performance1 ON batteries (
	id,
	active
);
CREATE TRIGGER cascade_battery_removal AFTER DELETE ON batteries
BEGIN
	DELETE FROM battery_charge_cycles
	WHERE battery_id = OLD.id;

	DELETE FROM userfield_values
	WHERE object_id = OLD.id
		AND field_id IN (SELECT id FROM userfields WHERE entity = 'batteries');
END;

-- chores --------------------------------------------------------------
CREATE TABLE chores__stage AS SELECT * FROM chores;
DROP TABLE chores;
CREATE TABLE "chores" (
	id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT UNIQUE,
	name TEXT NOT NULL,
	description TEXT,
	period_type TEXT NOT NULL,
	period_days INTEGER,
	row_created_timestamp DATETIME DEFAULT (datetime('now', 'localtime'))
, period_config TEXT, track_date_only TINYINT DEFAULT 0, rollover TINYINT DEFAULT 0, assignment_type TEXT, assignment_config TEXT, next_execution_assigned_to_user_id INT, consume_product_on_execution TINYINT NOT NULL DEFAULT 0, product_id TINYINT, product_amount REAL, period_interval INTEGER NOT NULL DEFAULT 1 CHECK(period_interval > 0), active TINYINT NOT NULL DEFAULT 1 CHECK(active IN (0, 1)), start_date DATETIME, rescheduled_date DATETIME, rescheduled_next_execution_assigned_to_user_id INT, household_id INTEGER NOT NULL DEFAULT 1,
	UNIQUE(name, household_id)
);
INSERT INTO chores SELECT * FROM chores__stage;
DROP TABLE chores__stage;
CREATE INDEX ix_chores_performance1 ON chores (
	id,
	active
);
CREATE INDEX chores_household_id ON chores (household_id);
CREATE TRIGGER default_start_date_when_empty_INS AFTER INSERT ON chores
BEGIN
	UPDATE chores
	SET start_date =  DATETIME('now', 'localtime')
	WHERE id = NEW.id
		AND IFNULL(start_date, '') = '';
END;
CREATE TRIGGER default_start_date_when_empty_UPD AFTER UPDATE ON chores
BEGIN
	UPDATE chores
	SET start_date =  DATETIME('now', 'localtime')
	WHERE id = NEW.id
		AND IFNULL(start_date, '') = '';
END;
CREATE TRIGGER cascade_chore_removal AFTER DELETE ON chores
BEGIN
	DELETE FROM chores_log
	WHERE chore_id = OLD.id;

	DELETE FROM userfield_values
	WHERE object_id = OLD.id
		AND field_id IN (SELECT id FROM userfields WHERE entity = 'chores');
END;

-- equipment -----------------------------------------------------------
CREATE TABLE equipment__stage AS SELECT * FROM equipment;
DROP TABLE equipment;
CREATE TABLE equipment (
	id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT UNIQUE,
	name TEXT NOT NULL,
	description TEXT,
	instruction_manual_file_name TEXT,
	row_created_timestamp DATETIME DEFAULT (datetime('now', 'localtime'))
, household_id INTEGER NOT NULL DEFAULT 1,
	UNIQUE(name, household_id)
);
INSERT INTO equipment SELECT * FROM equipment__stage;
DROP TABLE equipment__stage;

-- locations -----------------------------------------------------------
CREATE TABLE locations__stage AS SELECT * FROM locations;
DROP TABLE locations;
CREATE TABLE locations (
	id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT UNIQUE,
	name TEXT NOT NULL,
	description TEXT,
	row_created_timestamp DATETIME DEFAULT (datetime('now', 'localtime'))
, is_freezer TINYINT NOT NULL DEFAULT 0, active TINYINT NOT NULL DEFAULT 1 CHECK(active IN (0, 1)), household_id INTEGER NOT NULL DEFAULT 1,
	UNIQUE(name, household_id)
);
INSERT INTO locations SELECT * FROM locations__stage;
DROP TABLE locations__stage;

-- meal_plan_sections --------------------------------------------------
CREATE TABLE meal_plan_sections__stage AS SELECT * FROM meal_plan_sections;
DROP TABLE meal_plan_sections;
CREATE TABLE meal_plan_sections (
	id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT UNIQUE,
	name TEXT NOT NULL,
	sort_number INTEGER,
	row_created_timestamp DATETIME DEFAULT (datetime('now', 'localtime'))
, time_info TEXT, household_id INTEGER NOT NULL DEFAULT 1,
	UNIQUE(name, household_id)
);
INSERT INTO meal_plan_sections SELECT * FROM meal_plan_sections__stage;
DROP TABLE meal_plan_sections__stage;
CREATE TRIGGER prevent_internal_meal_plan_section_removal BEFORE DELETE ON meal_plan_sections
BEGIN
	SELECT CASE WHEN((
		SELECT 1
		FROM meal_plan_sections
		WHERE id = OLD.id
			AND id = -1
	) NOTNULL) THEN RAISE(ABORT, 'This is an internally used/required default section and therefore can''t be deleted') END;
END;

-- product_groups ------------------------------------------------------
CREATE TABLE product_groups__stage AS SELECT * FROM product_groups;
DROP TABLE product_groups;
CREATE TABLE product_groups (
	id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT UNIQUE,
	name TEXT NOT NULL,
	description TEXT,
	row_created_timestamp DATETIME DEFAULT (datetime('now', 'localtime'))
, active TINYINT NOT NULL DEFAULT 1 CHECK(active IN (0, 1)), household_id INTEGER NOT NULL DEFAULT 1,
	UNIQUE(name, household_id)
);
INSERT INTO product_groups SELECT * FROM product_groups__stage;
DROP TABLE product_groups__stage;

-- products ------------------------------------------------------------
CREATE TABLE products__stage AS SELECT * FROM products;
DROP TABLE products;
CREATE TABLE products (
	id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT UNIQUE,
	name TEXT NOT NULL,
	description TEXT,
	product_group_id INTEGER,
	active TINYINT NOT NULL DEFAULT 1 CHECK(active IN (0, 1)),
	location_id INTEGER NOT NULL,
	shopping_location_id INTEGER,
	qu_id_purchase INTEGER NOT NULL,
	qu_id_stock INTEGER NOT NULL,
	min_stock_amount INTEGER NOT NULL DEFAULT 0,
	default_best_before_days INTEGER NOT NULL DEFAULT 0,
	default_best_before_days_after_open INTEGER NOT NULL DEFAULT 0,
	default_best_before_days_after_freezing INTEGER NOT NULL DEFAULT 0,
	default_best_before_days_after_thawing INTEGER NOT NULL DEFAULT 0,
	picture_file_name TEXT,
	enable_tare_weight_handling TINYINT NOT NULL DEFAULT 0,
	tare_weight REAL NOT NULL DEFAULT 0,
	not_check_stock_fulfillment_for_recipes TINYINT DEFAULT 0,
	parent_product_id INT,
	calories INTEGER,
	cumulate_min_stock_amount_of_sub_products TINYINT DEFAULT 0,
	due_type TINYINT NOT NULL DEFAULT 1 CHECK(due_type IN (1, 2)),
	quick_consume_amount REAL NOT NULL DEFAULT 1,
	hide_on_stock_overview TINYINT NOT NULL DEFAULT 0 CHECK(hide_on_stock_overview IN (0, 1)),
	default_stock_label_type INTEGER NOT NULL DEFAULT 0,
	should_not_be_frozen TINYINT NOT NULL DEFAULT 0 CHECK(should_not_be_frozen IN (0, 1)),
	treat_opened_as_out_of_stock TINYINT NOT NULL DEFAULT 1 CHECK(treat_opened_as_out_of_stock IN (0, 1)),
	no_own_stock TINYINT NOT NULL DEFAULT 0 CHECK(no_own_stock IN (0, 1)),
	default_consume_location_id INTEGER,
	move_on_open TINYINT NOT NULL DEFAULT 0 CHECK(move_on_open IN (0, 1)),
	row_created_timestamp DATETIME DEFAULT (datetime('now', 'localtime'))
, qu_id_consume INTEGER, auto_reprint_stock_label TINYINT NOT NULL DEFAULT 0 CHECK(auto_reprint_stock_label IN (0, 1)), quick_open_amount REAL NOT NULL DEFAULT 1, qu_id_price INTEGER, disable_open TINYINT NOT NULL DEFAULT 0 CHECK(disable_open IN (0, 1)), default_purchase_price_type TINYINT NOT NULL DEFAULT 1 CHECK(default_purchase_price_type IN (1, 2, 3)), household_id INTEGER NOT NULL DEFAULT 1,
	UNIQUE(name, household_id)
);
INSERT INTO products SELECT * FROM products__stage;
DROP TABLE products__stage;
CREATE INDEX ix_products_performance1 ON products (
    parent_product_id
);
CREATE INDEX ix_products_performance2 ON products (
    CASE WHEN parent_product_id IS NULL THEN id ELSE parent_product_id END,
    active
);
CREATE INDEX products_household_id ON products (household_id);
CREATE TRIGGER enforce_parent_product_id_null_when_empty_INS AFTER INSERT ON products
BEGIN
	UPDATE products
	SET parent_product_id = NULL
	WHERE id = NEW.id
		AND IFNULL(parent_product_id, '') = '';
END;
CREATE TRIGGER enforce_parent_product_id_null_when_empty_UPD AFTER UPDATE ON products
BEGIN
	UPDATE products
	SET parent_product_id = NULL
	WHERE id = NEW.id
		AND IFNULL(parent_product_id, '') = '';
END;
CREATE TRIGGER cascade_product_removal AFTER DELETE ON products
BEGIN
	DELETE FROM stock
	WHERE product_id = OLD.id;

	DELETE FROM stock_log
	WHERE product_id = OLD.id;

	DELETE FROM product_barcodes
	WHERE product_id = OLD.id;

	DELETE FROM quantity_unit_conversions
	WHERE product_id = OLD.id;

	DELETE FROM recipes_pos
	WHERE product_id = OLD.id;

	UPDATE recipes
	SET product_id = NULL
	WHERE product_id = OLD.id;

	DELETE FROM meal_plan
	WHERE product_id = OLD.id
		AND type = 'product';

	DELETE FROM shopping_list
	WHERE product_id = OLD.id;

	DELETE FROM userfield_values
	WHERE object_id = OLD.id
		AND field_id IN (SELECT id FROM userfields WHERE entity = 'products');
END;
CREATE TRIGGER enforce_min_stock_amount_for_cumulated_childs_INS AFTER INSERT ON products
BEGIN
	/*
		When a parent product has cumulate_min_stock_amount_of_sub_products enabled,
		the child should not have any min_stock_amount
	*/

	UPDATE products
	SET min_stock_amount = 0
	WHERE id IN (
			SELECT
				p_child.id
			FROM products p_parent
			JOIN products p_child
				ON p_child.parent_product_id = p_parent.id
			WHERE p_parent.id = NEW.id
				AND IFNULL(p_parent.cumulate_min_stock_amount_of_sub_products, 0) = 1
			)
		AND min_stock_amount > 0;
END;
CREATE TRIGGER enforce_min_stock_amount_for_cumulated_childs_UPD AFTER UPDATE ON products
BEGIN
	/*
		When a parent product has cumulate_min_stock_amount_of_sub_products enabled,
		the child should not have any min_stock_amount
	*/

	UPDATE products
	SET min_stock_amount = 0
	WHERE id IN (
			SELECT
				p_child.id
			FROM products p_parent
			JOIN products p_child
				ON p_child.parent_product_id = p_parent.id
			WHERE p_parent.id = NEW.id
				AND IFNULL(p_parent.cumulate_min_stock_amount_of_sub_products, 0) = 1
			)
		AND min_stock_amount > 0;
END;
CREATE TRIGGER default_qu_id_consume AFTER INSERT ON products
BEGIN
	UPDATE products
	SET qu_id_consume = qu_id_stock
	WHERE id = NEW.id
		AND IFNULL(qu_id_consume, 0) = 0;
END;
CREATE TRIGGER cascade_change_qu_id_stock2 AFTER UPDATE ON products WHEN NEW.qu_id_stock != OLD.qu_id_stock
BEGIN
	-- See also the trigger "cascade_change_qu_id_stock BEFORE UPDATE ON products"
	-- This here applies the needed changes to the products table itself only AFTER the update

	UPDATE products
	SET quick_consume_amount = quick_consume_amount * IFNULL((SELECT factor FROM quantity_unit_conversions_resolved WHERE product_id = NEW.id AND from_qu_id = OLD.qu_id_stock AND to_qu_id = NEW.qu_id_stock LIMIT 1), 1.0),
	quick_open_amount = quick_open_amount * IFNULL((SELECT factor FROM quantity_unit_conversions_resolved WHERE product_id = NEW.id AND from_qu_id = OLD.qu_id_stock AND to_qu_id = NEW.qu_id_stock LIMIT 1), 1.0),
	calories = calories / IFNULL((SELECT factor FROM quantity_unit_conversions_resolved WHERE product_id = NEW.id AND from_qu_id = OLD.qu_id_stock AND to_qu_id = NEW.qu_id_stock LIMIT 1), 1.0),
	tare_weight = tare_weight * IFNULL((SELECT factor FROM quantity_unit_conversions_resolved WHERE product_id = NEW.id AND from_qu_id = OLD.qu_id_stock AND to_qu_id = NEW.qu_id_stock LIMIT 1), 1.0)
	WHERE id = NEW.id;
END;
CREATE TRIGGER default_qu_id_price AFTER INSERT ON products
BEGIN
	UPDATE products
	SET qu_id_price = qu_id_purchase
	WHERE id = NEW.id
		AND IFNULL(qu_id_price, 0) = 0;
END;
CREATE TRIGGER products_INS AFTER INSERT ON products
BEGIN
	-- Update quantity_unit_conversions_resolved cache
	DELETE FROM cache__quantity_unit_conversions_resolved
	WHERE product_id = NEW.id;

	INSERT INTO cache__quantity_unit_conversions_resolved
		(product_id, from_qu_id, from_qu_name, from_qu_name_plural, to_qu_id, to_qu_name, to_qu_name_plural, factor, path)
	SELECT product_id, from_qu_id, from_qu_name, from_qu_name_plural, to_qu_id, to_qu_name, to_qu_name_plural, factor, path
	FROM quantity_unit_conversions_resolved
	WHERE product_id = NEW.id;
END;
CREATE TRIGGER products_UPD AFTER UPDATE ON products
BEGIN
	-- Update quantity_unit_conversions_resolved cache
	DELETE FROM cache__quantity_unit_conversions_resolved
	WHERE product_id = NEW.id;

	INSERT INTO cache__quantity_unit_conversions_resolved
		(product_id, from_qu_id, from_qu_name, from_qu_name_plural, to_qu_id, to_qu_name, to_qu_name_plural, factor, path)
	SELECT product_id, from_qu_id, from_qu_name, from_qu_name_plural, to_qu_id, to_qu_name, to_qu_name_plural, factor, path
	FROM quantity_unit_conversions_resolved
	WHERE product_id = NEW.id;
END;
CREATE TRIGGER products_DELETE AFTER DELETE ON products
BEGIN
	-- Update quantity_unit_conversions_resolved cache
	DELETE FROM cache__quantity_unit_conversions_resolved
	WHERE product_id = OLD.id;
END;
CREATE TRIGGER enfore_product_nesting_level BEFORE UPDATE ON products
BEGIN
	-- Currently only 1 level is supported
    SELECT CASE WHEN((
        SELECT 1
        FROM products p
        WHERE IFNULL(NEW.parent_product_id, '') != ''
            AND IFNULL(parent_product_id, '') = NEW.id
    ) NOTNULL) THEN RAISE(ABORT, 'Unsupported product nesting level detected (currently only 1 level is supported)') END;
END;
CREATE TRIGGER cascade_change_qu_id_stock BEFORE UPDATE ON products WHEN NEW.qu_id_stock != OLD.qu_id_stock
BEGIN
	-- All amounts anywhere are related to the products stock QU,
	-- so apply the appropriate unit conversion to all amounts everywhere on change
	-- (and enforce that such a conversion need to exist when the product was once added to stock)

	SELECT CASE WHEN((
		SELECT 1
		FROM quantity_unit_conversions_resolved
		WHERE product_id = NEW.id
			AND from_qu_id = OLD.qu_id_stock
			AND to_qu_id = NEW.qu_id_stock
	) ISNULL)
	AND
	((
        SELECT 1
        FROM stock_log
		WHERE product_id = NEW.id
			AND NEW.qu_id_stock != OLD.qu_id_stock
    ) NOTNULL) THEN RAISE(ABORT, 'qu_id_stock can only be changed when a corresponding QU conversion (old QU => new QU) exists when the product was once added to stock') END;

	UPDATE chores
	SET product_amount = product_amount * IFNULL((SELECT factor FROM quantity_unit_conversions_resolved WHERE product_id = NEW.id AND from_qu_id = OLD.qu_id_stock AND to_qu_id = NEW.qu_id_stock LIMIT 1), 1.0)
	WHERE product_id = NEW.id;

	UPDATE meal_plan
	SET product_amount = product_amount * IFNULL((SELECT factor FROM quantity_unit_conversions_resolved WHERE product_id = NEW.id AND from_qu_id = OLD.qu_id_stock AND to_qu_id = NEW.qu_id_stock LIMIT 1), 1.0)
	WHERE type = 'product'
		AND product_id = NEW.id;

	UPDATE recipes_pos
	SET amount = amount * IFNULL((SELECT factor FROM quantity_unit_conversions_resolved WHERE product_id = NEW.id AND from_qu_id = OLD.qu_id_stock AND to_qu_id = NEW.qu_id_stock LIMIT 1), 1.0)
	WHERE product_id = NEW.id;

	UPDATE shopping_list
	SET amount = amount * IFNULL((SELECT factor FROM quantity_unit_conversions_resolved WHERE product_id = NEW.id AND from_qu_id = OLD.qu_id_stock AND to_qu_id = NEW.qu_id_stock LIMIT 1), 1.0)
	WHERE product_id = NEW.id
		AND product_id IS NOT NULL;

	UPDATE stock
	SET amount = amount * IFNULL((SELECT factor FROM quantity_unit_conversions_resolved WHERE product_id = NEW.id AND from_qu_id = OLD.qu_id_stock AND to_qu_id = NEW.qu_id_stock LIMIT 1), 1.0),
	price = price / IFNULL((SELECT factor FROM quantity_unit_conversions_resolved WHERE product_id = NEW.id AND from_qu_id = OLD.qu_id_stock AND to_qu_id = NEW.qu_id_stock LIMIT 1), 1.0)
	WHERE product_id = NEW.id;

	UPDATE stock_log
	SET amount = amount * IFNULL((SELECT factor FROM quantity_unit_conversions_resolved WHERE product_id = NEW.id AND from_qu_id = OLD.qu_id_stock AND to_qu_id = NEW.qu_id_stock LIMIT 1), 1.0),
	price = price / IFNULL((SELECT factor FROM quantity_unit_conversions_resolved WHERE product_id = NEW.id AND from_qu_id = OLD.qu_id_stock AND to_qu_id = NEW.qu_id_stock LIMIT 1), 1.0)
	WHERE product_id = NEW.id;
END;
CREATE TRIGGER products_default_qu_conversions_INS AFTER INSERT ON products
BEGIN
	-- Create product specific 1:1 conversions when QU stock != QU purchase/consume/price
	-- and when no default QU conversion apply

	-- with qu_id_stock != qu_id_purchase
	INSERT INTO quantity_unit_conversions
		(from_qu_id, to_qu_id, factor, product_id)
	SELECT p.qu_id_purchase, p.qu_id_stock, 1, p.id
	FROM products p
	WHERE p.id = NEW.id
		AND p.qu_id_stock != qu_id_purchase
		AND NOT EXISTS(SELECT 1 FROM quantity_unit_conversions_resolved WHERE product_id = p.id AND from_qu_id = p.qu_id_stock AND to_qu_id = p.qu_id_purchase);

	-- with qu_id_stock != qu_id_consume
	INSERT INTO quantity_unit_conversions
		(from_qu_id, to_qu_id, factor, product_id)
	SELECT p.qu_id_consume, p.qu_id_stock, 1, p.id
	FROM products p
	WHERE p.id = NEW.id
		AND p.qu_id_stock != qu_id_consume
		AND NOT EXISTS(SELECT 1 FROM quantity_unit_conversions_resolved WHERE product_id = p.id AND from_qu_id = p.qu_id_stock AND to_qu_id = p.qu_id_consume);

	-- with qu_id_stock != qu_id_price
	INSERT INTO quantity_unit_conversions
		(from_qu_id, to_qu_id, factor, product_id)
	SELECT p.qu_id_price, p.qu_id_stock, 1, p.id
	FROM products p
	WHERE p.id = NEW.id
		AND p.qu_id_stock != qu_id_price
		AND NOT EXISTS(SELECT 1 FROM quantity_unit_conversions_resolved WHERE product_id = p.id AND from_qu_id = p.qu_id_stock AND to_qu_id = p.qu_id_price);
END;
CREATE TRIGGER products_default_qu_conversions_UPD AFTER UPDATE ON products
BEGIN
	-- Create product specific 1:1 conversions when QU stock != QU purchase/consume/price
	-- and when no default QU conversion apply

	-- with qu_id_stock != qu_id_purchase
	INSERT INTO quantity_unit_conversions
		(from_qu_id, to_qu_id, factor, product_id)
	SELECT p.qu_id_purchase, p.qu_id_stock, 1, p.id
	FROM products p
	WHERE p.id = NEW.id
		AND p.qu_id_stock != qu_id_purchase
		AND NOT EXISTS(SELECT 1 FROM quantity_unit_conversions_resolved WHERE product_id = p.id AND from_qu_id = p.qu_id_stock AND to_qu_id = p.qu_id_purchase);

	-- with qu_id_stock != qu_id_consume
	INSERT INTO quantity_unit_conversions
		(from_qu_id, to_qu_id, factor, product_id)
	SELECT p.qu_id_consume, p.qu_id_stock, 1, p.id
	FROM products p
	WHERE p.id = NEW.id
		AND p.qu_id_stock != qu_id_consume
		AND NOT EXISTS(SELECT 1 FROM quantity_unit_conversions_resolved WHERE product_id = p.id AND from_qu_id = p.qu_id_stock AND to_qu_id = p.qu_id_consume);

	-- with qu_id_stock != qu_id_price
	INSERT INTO quantity_unit_conversions
		(from_qu_id, to_qu_id, factor, product_id)
	SELECT p.qu_id_price, p.qu_id_stock, 1, p.id
	FROM products p
	WHERE p.id = NEW.id
		AND p.qu_id_stock != qu_id_price
		AND NOT EXISTS(SELECT 1 FROM quantity_unit_conversions_resolved WHERE product_id = p.id AND from_qu_id = p.qu_id_stock AND to_qu_id = p.qu_id_price);
END;

-- quantity_units ------------------------------------------------------
CREATE TABLE quantity_units__stage AS SELECT * FROM quantity_units;
DROP TABLE quantity_units;
CREATE TABLE quantity_units (
	id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT UNIQUE,
	name TEXT NOT NULL,
	description TEXT,
	row_created_timestamp DATETIME DEFAULT (datetime('now', 'localtime'))
, name_plural TEXT, plural_forms TEXT, active TINYINT NOT NULL DEFAULT 1 CHECK(active IN (0, 1)), household_id INTEGER NOT NULL DEFAULT 1,
	UNIQUE(name, household_id)
);
INSERT INTO quantity_units SELECT * FROM quantity_units__stage;
DROP TABLE quantity_units__stage;
CREATE TRIGGER remove_conversions AFTER DELETE ON quantity_units
BEGIN
	DELETE FROM quantity_unit_conversions
	WHERE from_qu_id = OLD.id
		OR to_qu_id = OLD.id;
END;

-- shopping_lists ------------------------------------------------------
CREATE TABLE shopping_lists__stage AS SELECT * FROM shopping_lists;
DROP TABLE shopping_lists;
CREATE TABLE shopping_lists (
	id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT UNIQUE,
	name TEXT NOT NULL,
	description TEXT,
	row_created_timestamp DATETIME DEFAULT (datetime('now', 'localtime'))
, household_id INTEGER NOT NULL DEFAULT 1,
	UNIQUE(name, household_id)
);
INSERT INTO shopping_lists SELECT * FROM shopping_lists__stage;
DROP TABLE shopping_lists__stage;
CREATE TRIGGER remove_items_from_deleted_shopping_list AFTER DELETE ON shopping_lists
BEGIN
    DELETE FROM shopping_list WHERE shopping_list_id = OLD.id;
END;

-- shopping_locations --------------------------------------------------
CREATE TABLE shopping_locations__stage AS SELECT * FROM shopping_locations;
DROP TABLE shopping_locations;
CREATE TABLE shopping_locations (
	id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT UNIQUE,
	name TEXT NOT NULL,
	description TEXT,
	row_created_timestamp DATETIME DEFAULT (datetime('now', 'localtime'))
, active TINYINT NOT NULL DEFAULT 1 CHECK(active IN (0, 1)), household_id INTEGER NOT NULL DEFAULT 1,
	UNIQUE(name, household_id)
);
INSERT INTO shopping_locations SELECT * FROM shopping_locations__stage;
DROP TABLE shopping_locations__stage;

-- task_categories -----------------------------------------------------
CREATE TABLE task_categories__stage AS SELECT * FROM task_categories;
DROP TABLE task_categories;
CREATE TABLE task_categories (
	id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT UNIQUE,
	name TEXT NOT NULL,
	description TEXT,
	row_created_timestamp DATETIME DEFAULT (datetime('now', 'localtime'))
, active TINYINT NOT NULL DEFAULT 1 CHECK(active IN (0, 1)), household_id INTEGER NOT NULL DEFAULT 1,
	UNIQUE(name, household_id)
);
INSERT INTO task_categories SELECT * FROM task_categories__stage;
DROP TABLE task_categories__stage;
