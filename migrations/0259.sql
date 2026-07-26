-- Multi-household, phase 5b: the remaining global UNIQUE constraints.
--
-- Three more that block a second household, all found by auditing sqlite_master
-- rather than by guessing:
--
--   ix_product_barcodes  UNIQUE(barcode) — a barcode is a GLOBAL fact (an EAN
--                        identifies a product worldwide), so two households
--                        stocking the same item are guaranteed to collide.
--   userentities         UNIQUE(name)
--   userfields           UNIQUE(entity, name)
--
-- Left alone deliberately, because the columns they constrain are already
-- globally unique integer PKs and therefore cannot collide across households:
--   recipes_nestings UNIQUE(recipe_id, includes_recipe_id)
--   userfield_values UNIQUE(field_id, object_id)
--   cache__products_average_price / cache__products_last_purchased UNIQUE(product_id)

DROP INDEX ix_product_barcodes;
CREATE UNIQUE INDEX ix_product_barcodes ON product_barcodes (
	barcode,
	household_id
);


-- userentities --------------------------------------------------------
CREATE TABLE userentities__stage AS SELECT * FROM userentities;
DROP TABLE userentities;
CREATE TABLE userentities (
	id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT UNIQUE,
	name TEXT NOT NULL,
	caption TEXT NOT NULL,
	description TEXT,
	show_in_sidebar_menu TINYINT NOT NULL DEFAULT 1,
	icon_css_class TEXT,
	row_created_timestamp DATETIME DEFAULT (datetime('now', 'localtime')), household_id INTEGER NOT NULL DEFAULT 1,

	UNIQUE(name, household_id)
);
INSERT INTO userentities SELECT * FROM userentities__stage;
DROP TABLE userentities__stage;

-- userfields ----------------------------------------------------------
CREATE TABLE userfields__stage AS SELECT * FROM userfields;
DROP TABLE userfields;
CREATE TABLE userfields (
	id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT UNIQUE,
	entity TEXT NOT NULL,
	name TEXT NOT NULL,
	caption TEXT NOT NULL,
	type TEXT NOT NULL,
	show_as_column_in_tables TINYINT NOT NULL DEFAULT 0,
	row_created_timestamp DATETIME DEFAULT (datetime('now', 'localtime')), config TEXT, sort_number INTEGER, input_required TINYINT NOT NULL DEFAULT 0 CHECK(input_required IN (0, 1)), default_value TEXT, household_id INTEGER NOT NULL DEFAULT 1,

	UNIQUE(entity, name, household_id)
);
INSERT INTO userfields SELECT * FROM userfields__stage;
DROP TABLE userfields__stage;
CREATE TRIGGER cascade_userfield_removal AFTER DELETE ON userfields
BEGIN
	DELETE FROM userfield_values
	WHERE object_id = OLD.id
		AND field_id = OLD.id;
END;
