-- Multi-household, phase 2: make every content view filterable by household.
--
-- Two changes per view, and BOTH matter:
--   1. expose household_id, so HouseholdScopedDatabase can filter the view
--   2. constrain every join by household_id, so a view cannot itself splice
--      rows from two households together before any filter is applied
--
-- (2) is the subtle one. Exposing the column while leaving joins unconstrained
-- would produce rows whose household_id is arbitrary — filtered, but wrong.
--
-- Views are recreated in dependency order: views built on other views come
-- after their sources.

-- batch 1: views reading directly from scoped base tables ------------------

DROP VIEW products_resolved;
CREATE VIEW products_resolved
AS
SELECT
	CASE
		WHEN p.parent_product_id IS NULL THEN
			p.id
		ELSE
			p.parent_product_id
	END AS parent_product_id,
	p.id as sub_product_id,
	p.household_id
FROM products p
WHERE p.active = 1;

DROP VIEW stock_current_locations;
CREATE VIEW stock_current_locations
AS
SELECT
	1 AS id, -- Dummy, LessQL needs an id column
	s.product_id,
	SUM(s.amount) as amount,
	s.location_id AS location_id,
	l.name AS location_name,
	l.is_freezer AS location_is_freezer,
	s.household_id
FROM stock s
JOIN locations l
	ON s.location_id = l.id
	AND l.household_id = s.household_id
GROUP BY s.product_id, s.location_id, l.name, s.household_id;

DROP VIEW product_barcodes_comma_separated;
CREATE VIEW product_barcodes_comma_separated
AS
SELECT
	pb.id, -- Dummy, LessQL needs an id column
	pb.product_id,
	GROUP_CONCAT(pb.barcode) AS barcodes,
	pb.household_id
FROM product_barcodes pb
JOIN products p
	ON pb.product_id = p.id
	AND p.household_id = pb.household_id
WHERE p.active = 1
GROUP BY pb.product_id, pb.household_id;

DROP VIEW chores_assigned_users_resolved;
CREATE VIEW chores_assigned_users_resolved
AS
SELECT
	c.id AS chore_id,
	u.id AS user_id,
	c.household_id
FROM chores c
JOIN users u
	ON ',' || c.assignment_config || ',' LIKE '%,' || CAST(u.id AS TEXT) || ',%'
	AND u.household_id = c.household_id
WHERE c.active = 1;

DROP VIEW users_dto;
CREATE VIEW users_dto
AS
SELECT
	id,
	username,
	first_name,
	last_name,
	row_created_timestamp,
	(CASE
		WHEN IFNULL(first_name, '') = '' AND IFNULL(last_name, '') != '' THEN last_name
		WHEN IFNULL(last_name, '') = '' AND IFNULL(first_name, '') != '' THEN first_name
		WHEN IFNULL(last_name, '') != '' AND IFNULL(first_name, '') != '' THEN first_name || ' ' || last_name
		ELSE username
	END
	) AS display_name,
	picture_file_name,
	household_id
FROM users;

DROP VIEW quantity_units_resolved;
CREATE VIEW quantity_units_resolved
AS
-- This view builds the relationship between QUs based on their (default) conversions

SELECT
	-1 AS id, -- Dummy, LessQL needs an id column
	qu.id AS qu_id,
	quc.to_qu_id AS related_qu_id,
	quc.factor,
	qu.household_id
FROM quantity_units qu
JOIN quantity_unit_conversions quc
	ON qu.id = quc.from_qu_id
	AND quc.household_id = qu.household_id
	AND quc.product_id IS NULL;

-- batch 2: base-table views, UNIONs and one recursive CTE ------------------

DROP VIEW batteries_current;
CREATE VIEW batteries_current
AS
SELECT
	b.id, -- Dummy, LessQL needs an id column
	b.id AS battery_id,
	MAX(l.tracked_time) AS last_tracked_time,
	CASE WHEN b.charge_interval_days = 0
		THEN '2999-12-31 23:59:59'
		ELSE datetime(MAX(l.tracked_time), '+' || CAST(b.charge_interval_days AS TEXT) || ' day')
	END AS next_estimated_charge_time,
	b.household_id
FROM batteries b
LEFT JOIN battery_charge_cycles l
	ON b.id = l.battery_id
	AND l.household_id = b.household_id
	AND l.undone = 0
WHERE b.active = 1
GROUP BY b.id, b.charge_interval_days, b.household_id;

DROP VIEW chores_execution_timeline;
CREATE VIEW chores_execution_timeline
AS
SELECT
	cl.chore_id,
	cl.tracked_time,
	(SELECT tracked_time FROM chores_log WHERE chore_id = cl.chore_id AND household_id = cl.household_id AND undone = 0 AND tracked_time < cl.tracked_time ORDER BY tracked_time DESC LIMIT 1) AS tracked_time_before,
	CAST((JULIANDAY(cl.tracked_time) - JULIANDAY((SELECT tracked_time FROM chores_log WHERE chore_id = cl.chore_id AND household_id = cl.household_id AND undone = 0 AND tracked_time < cl.tracked_time ORDER BY tracked_time DESC LIMIT 1))) * 24 AS INT) AS frequency_hours,
	cl.household_id
FROM chores_log cl
WHERE cl.undone = 0;

DROP VIEW chores_execution_average_frequency;
CREATE VIEW chores_execution_average_frequency
AS
SELECT
	cet.chore_id,
	AVG(cet.frequency_hours) AS average_frequency_hours,
	cet.household_id
FROM chores_execution_timeline cet
GROUP BY cet.chore_id, cet.household_id;

DROP VIEW chores_execution_users_statistics;
CREATE VIEW chores_execution_users_statistics
AS
SELECT
	c.id AS id, -- Dummy, LessQL needs an id column
	c.id AS chore_id,
	caur.user_id AS user_id,
	(SELECT COUNT(1) FROM chores_log WHERE chore_id = c.id AND household_id = c.household_id AND done_by_user_id = caur.user_id AND undone = 0) AS execution_count,
	c.household_id
FROM chores c
JOIN chores_assigned_users_resolved caur
	ON c.id = caur.chore_id
	AND caur.household_id = c.household_id
GROUP BY c.id, caur.user_id, c.household_id;

DROP VIEW stock_current_location_content;
CREATE VIEW stock_current_location_content
AS
SELECT
	IFNULL(s.location_id, p.location_id) AS location_id,
	s.product_id,
	SUM(s.amount) AS amount,
	ROUND(SUM(IFNULL(s.price, 0) * s.amount), 2) AS value,
	MIN(s.best_before_date) AS best_before_date,
	IFNULL((SELECT SUM(amount) FROM stock WHERE product_id = s.product_id AND household_id = s.household_id AND location_id = s.location_id AND open = 1), 0) AS amount_opened,
	s.household_id
FROM stock s
JOIN products p
	ON s.product_id = p.id
	AND p.household_id = s.household_id
	AND p.active = 1
GROUP BY IFNULL(s.location_id, p.location_id), s.product_id, s.household_id;

DROP VIEW product_barcodes_view;
CREATE VIEW product_barcodes_view
AS
SELECT
	pb.id,
	pb.product_id,
	pb.barcode,
	pb.qu_id,
	pb.amount,
	pb.shopping_location_id,
	pb.last_price,
	pb.note,
	pb.household_id
FROM product_barcodes pb

UNION ALL

-- Product Grocycodes
SELECT
	p.id,
	p.id AS product_id,
	'grcy:p:' || CAST(p.id AS TEXT) AS barcode,
	p.qu_id_stock AS qu_id,
	NULL AS amount,
	NULL AS shopping_location_id,
	NULL AS last_price,
	NULL AS note,
	p.household_id
FROM products p;

DROP VIEW meal_plan_internal_recipe_relation;
CREATE VIEW meal_plan_internal_recipe_relation
AS

-- Relation between a meal plan (day) and the corresponding internal recipe(s)

SELECT mp.day, r.id AS recipe_id, mp.household_id
FROM meal_plan mp
JOIN recipes r
	ON r.name = CAST(mp.day AS TEXT)
	AND r.household_id = mp.household_id
	AND r.type = 'mealplan-day'

UNION

SELECT mp.day, r.id AS recipe_id, mp.household_id
FROM meal_plan mp
JOIN recipes r
	ON r.name = LTRIM(STRFTIME('%Y-%W', mp.day), '0')
	AND r.household_id = mp.household_id
	AND r.type = 'mealplan-week'

UNION

SELECT mp.day, r.id AS recipe_id, mp.household_id
FROM meal_plan mp
JOIN recipes r
	ON r.name = CAST(mp.day AS TEXT) || '#' || CAST(mp.id AS TEXT)
	AND r.household_id = mp.household_id
	AND r.type = 'mealplan-shadow';

DROP VIEW userfield_values_resolved;
CREATE VIEW userfield_values_resolved
AS
SELECT
	u.id, -- Dummy, LessQL needs an id column
	u.entity,
	u.name,
	u.caption,
	u.type,
	u.show_as_column_in_tables,
	u.row_created_timestamp,
	u.config,
	uv.object_id,
	uv.value,
	u.household_id
FROM userfields u
JOIN userfield_values uv
	ON u.id = uv.field_id
	AND uv.household_id = u.household_id

UNION

-- Kind of a hack, include userentity userfields also for the table userobjects
SELECT
	u.id, -- Dummy, LessQL needs an id column,
	'userobjects',
	u.name,
	u.caption,
	u.type,
	u.show_as_column_in_tables,
	u.row_created_timestamp,
	u.config,
	uv.object_id,
	uv.value,
	u.household_id
FROM userfields u
JOIN userfield_values uv
	ON u.id = uv.field_id
	AND uv.household_id = u.household_id
WHERE u.entity like 'userentity-%';

DROP VIEW recipes_nestings_resolved;
CREATE VIEW recipes_nestings_resolved
AS
WITH RECURSIVE r1(recipe_id, includes_recipe_id, includes_servings, level, household_id)
AS (
	SELECT
		id AS recipe_id,
		id AS includes_recipe_id,
		1 AS includes_servings,
		0 AS level,
		household_id
	FROM recipes

	UNION ALL

	SELECT
		rn.recipe_id,
		r1.includes_recipe_id,
		rn.servings * r1.includes_servings AS includes_servings,
		r1.level + 1 AS level,
		r1.household_id
	FROM recipes_nestings rn, r1 r1
	WHERE rn.includes_recipe_id = r1.recipe_id
		AND rn.household_id = r1.household_id
)
SELECT
	*,
	1 AS id -- Dummy, LessQL needs an id column
FROM r1;

-- batch 3: views whose dependencies are already scoped above ---------------

DROP VIEW uihelper_stock_journal;
CREATE VIEW uihelper_stock_journal
AS
SELECT
	sl.id,
	sl.row_created_timestamp,
	sl.correlation_id,
	sl.undone,
	sl.undone_timestamp,
	sl.transaction_type,
	sl.spoiled,
	sl.amount,
	sl.location_id,
	l.name AS location_name,
	p.name AS product_name,
	qu.name AS qu_name,
	qu.name_plural AS qu_name_plural,
	u.display_name AS user_display_name,
	p.id AS product_id,
	sl.note,
	sl.stock_id,
	sl.household_id
FROM stock_log sl
LEFT JOIN users_dto u
	ON sl.user_id = u.id
	AND u.household_id = sl.household_id
JOIN products p
	ON sl.product_id = p.id
	AND p.household_id = sl.household_id
JOIN locations l
	ON sl.location_id = l.id
	AND l.household_id = sl.household_id
JOIN quantity_units qu
	ON p.qu_id_stock = qu.id
	AND qu.household_id = sl.household_id;

DROP VIEW uihelper_stock_journal_summary;
CREATE VIEW uihelper_stock_journal_summary
AS
SELECT
	user_id AS id, -- Dummy, LessQL needs an id column
	user_id, u.display_name AS user_display_name,
	p.name AS product_name,
	product_id,
	transaction_type,
	qu.name AS qu_name,
	qu.name_plural AS qu_name_plural,
	SUM(amount) AS amount,
	sl.household_id
FROM stock_log sl
JOIN users_dto u
	on sl.user_id = u.id
	AND u.household_id = sl.household_id
JOIN products p
	ON sl.product_id = p.id
	AND p.household_id = sl.household_id
JOIN quantity_units qu
	ON p.qu_id_stock = qu.id
	AND qu.household_id = sl.household_id
WHERE undone = 0
GROUP BY user_id, product_id, transaction_type, sl.household_id;

DROP VIEW stock_splits;
CREATE VIEW stock_splits
AS

/*
	Helper view which shows splitted stock rows which could be compacted

	Stock entries with a stock_id starting with "x"
	and those with userfields shouldn't be compacted
*/

SELECT
	s.product_id,
	SUM(s.amount) AS total_amount,
	MIN(s.stock_id) AS stock_id_to_keep,
	MAX(s.id) AS id_to_keep,
	GROUP_CONCAT(s.id) AS id_group,
	GROUP_CONCAT(s.stock_id) AS stock_id_group,
	s.id, -- Dummy
	s.household_id
FROM stock s
WHERE s.stock_id NOT LIKE 'x%'
	AND NOT EXISTS(
		SELECT 1 FROM userfield_values
		WHERE object_id = s.stock_id
			AND household_id = s.household_id
			AND field_id IN (SELECT id FROM userfields WHERE entity = 'stock' AND household_id = s.household_id)
			AND IFNULL(value, '') != ''
		)
GROUP BY s.product_id, s.best_before_date, s.purchased_date, s.price, s.open, s.opened_date, s.location_id, s.shopping_location_id, IFNULL(s.note, ''), s.household_id
HAVING COUNT(*) > 1;

DROP VIEW products_current_price;
CREATE VIEW products_current_price
AS

/*
	Current price per product,
	based on the stock entry to use next,
	or on the last price if the product is currently not in stock
*/

SELECT
	-1 AS id, -- Dummy,
	p.id AS product_id,
	IFNULL(snu.price, plp.price) AS price,
	p.household_id
FROM products p
LEFT JOIN (
	SELECT
		product_id,
		MAX(priority),
		price, -- Bare column, ref https://www.sqlite.org/lang_select.html#bare_columns_in_an_aggregate_query
		household_id
	FROM stock_next_use
	GROUP BY product_id, household_id
	ORDER BY priority DESC, open DESC, best_before_date ASC, purchased_date ASC
	) snu
	ON p.id = snu.product_id
	AND snu.household_id = p.household_id
LEFT JOIN cache__products_last_purchased plp
	ON p.id = plp.product_id
	AND plp.household_id = p.household_id;

-- batch 4: the stock core -------------------------------------------------
-- Note the correlated subqueries: constraining only the joins would leave
-- SUM(amount) totals silently mixing both households' stock.

DROP VIEW stock_edited_entries;
CREATE VIEW stock_edited_entries
AS
/*
	Returns stock_id's which have been edited manually
*/
SELECT
	x.stock_id,
	x.stock_log_id_of_newest_edited_entry,

	-- When an origin entry was edited, the new origin amount is the one of the newest "stock-edit-new" + all
	-- previous consume transactions (mind that consume transaction amounts are negative, hence here - instead of +)
	(
		SELECT amount
		FROM stock_log sli
		WHERE sli.id = x.stock_log_id_of_newest_edited_entry
			AND sli.household_id = x.household_id
	)
	-
	IFNULL((
		SELECT SUM(amount)
		FROM stock_log sli_consumed
		WHERE sli_consumed.stock_id = x.stock_id
			AND sli_consumed.household_id = x.household_id
			AND sli_consumed.transaction_type IN ('consume', 'inventory-correction')
			AND sli_consumed.id < x.stock_log_id_of_newest_edited_entry
			AND sli_consumed.amount < 0
			AND sli_consumed.undone = 0), 0) AS edited_origin_amount,
	x.household_id
FROM (
	SELECT
		sl_add.stock_id,
		MAX(sl_edit.id) AS stock_log_id_of_newest_edited_entry,
		sl_add.household_id
	FROM stock_log sl_add
	JOIN stock_log sl_edit
		ON sl_add.stock_id = sl_edit.stock_id
		AND sl_edit.household_id = sl_add.household_id
		AND sl_edit.transaction_type = 'stock-edit-new'
	WHERE sl_add.transaction_type IN ('purchase', 'inventory-correction', 'self-production')
		AND sl_add.amount > 0
GROUP BY sl_add.stock_id, sl_add.household_id
) x
JOIN stock_log sl_edit
	ON x.stock_log_id_of_newest_edited_entry = sl_edit.id
	AND sl_edit.household_id = x.household_id;

DROP VIEW stock_current;
CREATE VIEW stock_current
AS
SELECT
	pr.parent_product_id AS product_id,
	IFNULL((SELECT SUM(amount) FROM stock WHERE product_id = pr.parent_product_id AND household_id = pr.household_id), 0) AS amount,
	SUM(s.amount * IFNULL(qucr.factor, 1.0)) AS amount_aggregated,
	IFNULL(ROUND((SELECT SUM(IFNULL(price,0) * amount) FROM stock WHERE product_id = pr.parent_product_id AND household_id = pr.household_id), 2), 0)  AS value,
	MIN(s.best_before_date) AS best_before_date,
	IFNULL((SELECT SUM(amount) FROM stock WHERE product_id = pr.parent_product_id AND household_id = pr.household_id AND open = 1), 0) AS amount_opened,
	IFNULL((SELECT SUM(amount) FROM stock WHERE product_id IN (SELECT sub_product_id FROM products_resolved WHERE parent_product_id = pr.parent_product_id AND household_id = pr.household_id) AND household_id = pr.household_id AND open = 1), 0) * IFNULL(qucr.factor, 1) AS amount_opened_aggregated,
	CASE WHEN COUNT(p_sub.parent_product_id) > 0  THEN 1 ELSE 0 END AS is_aggregated_amount,
	MAX(p_parent.due_type) AS due_type,
	pr.household_id
FROM products_resolved pr
JOIN stock s
	ON pr.sub_product_id = s.product_id
	AND s.household_id = pr.household_id
JOIN products p_parent
	ON pr.parent_product_id = p_parent.id
	AND p_parent.household_id = pr.household_id
	AND p_parent.active = 1
JOIN products p_sub
	ON pr.sub_product_id = p_sub.id
	AND p_sub.household_id = pr.household_id
	AND p_sub.active = 1
LEFT JOIN cache__quantity_unit_conversions_resolved qucr
	ON pr.sub_product_id = qucr.product_id
	AND qucr.household_id = pr.household_id
	AND p_sub.qu_id_stock = qucr.from_qu_id
	AND p_parent.qu_id_stock = qucr.to_qu_id
GROUP BY pr.parent_product_id, pr.household_id
HAVING SUM(s.amount) > 0

UNION

-- This is the same as above but sub products not rolled up (no QU conversion and column is_aggregated_amount = 0 here)
SELECT
	pr.sub_product_id AS product_id,
	SUM(s.amount) AS amount,
	SUM(s.amount) AS amount_aggregated,
	ROUND(SUM(IFNULL(s.price, 0) * s.amount), 2) AS value,
	MIN(s.best_before_date) AS best_before_date,
	IFNULL((SELECT SUM(amount) FROM stock WHERE product_id = s.product_id AND household_id = pr.household_id AND open = 1), 0) AS amount_opened,
	IFNULL((SELECT SUM(amount) FROM stock WHERE product_id = s.product_id AND household_id = pr.household_id AND open = 1), 0) AS amount_opened_aggregated,
	0 AS is_aggregated_amount,
	MAX(p_sub.due_type) AS due_type,
	pr.household_id
FROM products_resolved pr
JOIN stock s
	ON pr.sub_product_id = s.product_id
	AND s.household_id = pr.household_id
JOIN products p_sub
	ON pr.sub_product_id = p_sub.id
	AND p_sub.household_id = pr.household_id
	AND p_sub.active = 1
WHERE pr.parent_product_id != pr.sub_product_id
GROUP BY pr.sub_product_id, pr.household_id
HAVING SUM(s.amount) > 0;

DROP VIEW stock_missing_products;
CREATE VIEW stock_missing_products
AS

SELECT *
FROM (

-- Products WITHOUT sub products where the amount of the sub products SHOULD NOT be cumulated
SELECT
	p.id,
	MAX(p.name) AS name,
	p.min_stock_amount - IFNULL(SUM(s.amount), 0) + (CASE WHEN p.treat_opened_as_out_of_stock = 1 THEN IFNULL(SUM(s.amount_opened), 0) ELSE 0 END) AS amount_missing,
	CASE WHEN IFNULL(SUM(s.amount), 0) > 0 THEN 1 ELSE 0 END AS is_partly_in_stock,
	p.household_id
FROM products_view p
LEFT JOIN stock_current s
	ON p.id = s.product_id
	AND s.household_id = p.household_id
WHERE p.min_stock_amount != 0
	AND p.cumulate_min_stock_amount_of_sub_products = 0
	AND p.has_sub_products = 0
	AND p.parent_product_id IS NULL
	AND IFNULL(p.active, 0) = 1
GROUP BY p.id, p.household_id

UNION

-- Parent products WITH sub products where the amount of the sub products SHOULD be cumulated
SELECT
	p.id,
	MAX(p.name) AS name,
	SUM(sub_p.min_stock_amount) - IFNULL(SUM(s.amount_aggregated), 0) + (CASE WHEN p.treat_opened_as_out_of_stock = 1 THEN IFNULL(SUM(s.amount_opened_aggregated), 0) ELSE 0 END) AS amount_missing,
	CASE WHEN IFNULL(SUM(s.amount), 0) > 0 THEN 1 ELSE 0 END AS is_partly_in_stock,
	p.household_id
FROM products_view p
JOIN products_resolved pr
	ON p.id = pr.parent_product_id
	AND pr.household_id = p.household_id
JOIN products sub_p
	ON pr.sub_product_id = sub_p.id
	AND sub_p.household_id = p.household_id
LEFT JOIN stock_current s
	ON pr.sub_product_id = s.product_id
	AND s.household_id = p.household_id
WHERE sub_p.min_stock_amount != 0
	AND p.cumulate_min_stock_amount_of_sub_products = 1
	AND IFNULL(p.active, 0) = 1
GROUP BY p.id, p.household_id

UNION

-- Sub products where the amount SHOULD NOT be cumulated into the parent product
SELECT
	sub_p.id,
	MAX(sub_p.name) AS name,
	SUM(sub_p.min_stock_amount) - IFNULL(SUM(s.amount_aggregated), 0) + (CASE WHEN p.treat_opened_as_out_of_stock = 1 THEN IFNULL(SUM(s.amount_opened_aggregated), 0) ELSE 0 END) AS amount_missing,
	CASE WHEN IFNULL(SUM(s.amount), 0) > 0 THEN 1 ELSE 0 END AS is_partly_in_stock,
	sub_p.household_id
FROM products p
JOIN products_resolved pr
	ON p.id = pr.parent_product_id
	AND pr.household_id = p.household_id
JOIN products sub_p
	ON pr.sub_product_id = sub_p.id
	AND sub_p.household_id = p.household_id
LEFT JOIN stock_current s
	ON pr.sub_product_id = s.product_id
	AND s.household_id = p.household_id
WHERE sub_p.min_stock_amount != 0
	AND p.cumulate_min_stock_amount_of_sub_products = 0
	AND IFNULL(p.active, 0) = 1
GROUP BY sub_p.id, sub_p.household_id
) x
WHERE x.amount_missing > 0;

DROP VIEW stock_average_product_shelf_life;
CREATE VIEW stock_average_product_shelf_life
AS
SELECT
	p.id,
	CASE WHEN x.product_id IS NULL THEN -1 ELSE AVG(x.shelf_life_days) END AS average_shelf_life_days,
	p.household_id
FROM products p
LEFT JOIN (
		SELECT
			sl_p.product_id,
			JULIANDAY(sl_p.best_before_date) - JULIANDAY(sl_p.purchased_date) AS shelf_life_days,
			sl_p.household_id
		FROM stock_log sl_p
		WHERE sl_p.undone = 0
			AND (
				(sl_p.transaction_type IN ('purchase', 'inventory-correction', 'self-production') AND sl_p.stock_id NOT IN (SELECT stock_id FROM stock_edited_entries WHERE household_id = sl_p.household_id))
				OR (sl_p.transaction_type = 'stock-edit-new' AND sl_p.stock_id IN (SELECT stock_id FROM stock_edited_entries WHERE household_id = sl_p.household_id))
			)
	) x
	ON p.id = x.product_id
	AND x.household_id = p.household_id
GROUP BY p.id, p.household_id;

DROP VIEW products_volatile_status;
CREATE VIEW products_volatile_status
AS
SELECT
	-1 AS id, -- Dummy
	p.id AS product_id,
	p.name AS product_name,
	CASE WHEN JULIANDAY(sc.best_before_date) - JULIANDAY('now', 'localtime') < 0 THEN
		CASE WHEN p.due_type = 1 THEN 'overdue' ELSE 'expired' END
	ELSE
		CASE WHEN JULIANDAY(sc.best_before_date) - JULIANDAY('now', 'localtime') < CAST(grocy_user_setting('stock_due_soon_days') AS INT) THEN
			'due_soon'
		ELSE
			'ok'
		END
	END AS current_due_status,
	CASE WHEN smp.id IS NOT NULL THEN 1 ELSE 0 END AS is_currently_below_min_stock_amount,
	p.household_id
FROM products p
LEFT JOIN stock_current sc
	ON p.id = sc.product_id
	AND sc.household_id = p.household_id
LEFT JOIN stock_missing_products smp
	ON p.id = smp.id
	AND smp.household_id = p.household_id;

-- batch 4b: uihelper_stock_current_overview --------------------------------
-- Its inner UNION does "SELECT *" from stock_current, so adding a column
-- there changes the arity every other branch must match.

DROP VIEW uihelper_stock_current_overview;
CREATE VIEW uihelper_stock_current_overview
AS
SELECT
	p.id,
	sc.amount_opened AS amount_opened,
	p.tare_weight AS tare_weight,
	p.enable_tare_weight_handling AS enable_tare_weight_handling,
	sc.amount AS amount,
	sc.value as value,
	sc.product_id AS product_id,
	IFNULL(sc.best_before_date, '2888-12-31') AS best_before_date,
	EXISTS(SELECT id FROM stock_missing_products WHERE id = sc.product_id AND household_id = sc.household_id) AS product_missing,
	p.name AS product_name,
	pg.name AS product_group_name,
	sl.name AS default_store_name,
	EXISTS(SELECT * FROM shopping_list WHERE shopping_list.product_id = sc.product_id AND shopping_list.household_id = sc.household_id) AS on_shopping_list,
	qu_stock.name AS qu_stock_name,
	qu_stock.name_plural AS qu_stock_name_plural,
	qu_purchase.name AS qu_purchase_name,
	qu_purchase.name_plural AS qu_purchase_name_plural,
	qu_consume.name AS qu_consume_name,
	qu_consume.name_plural AS qu_consume_name_plural,
	qu_price.name AS qu_price_name,
	qu_price.name_plural AS qu_price_name_plural,
	sc.is_aggregated_amount,
	sc.amount_opened_aggregated,
	sc.amount_aggregated,
	p.calories AS product_calories,
	sc.amount * p.calories AS calories,
	sc.amount_aggregated * p.calories AS calories_aggregated,
	p.quick_consume_amount,
	p.quick_consume_amount / p.qu_factor_consume_to_stock AS quick_consume_amount_qu_consume,
	p.quick_open_amount,
	p.quick_open_amount / p.qu_factor_consume_to_stock AS quick_open_amount_qu_consume,
	p.due_type,
	plp.purchased_date AS last_purchased,
	plp.price AS last_price,
	pap.price as average_price,
	p.min_stock_amount,
	pbcs.barcodes AS product_barcodes,
	p.description AS product_description,
	l.name AS product_default_location_name,
	p_parent.id AS parent_product_id,
	p_parent.name AS parent_product_name,
	p.picture_file_name AS product_picture_file_name,
	p.no_own_stock AS product_no_own_stock,
	p.qu_factor_purchase_to_stock AS product_qu_factor_purchase_to_stock,
	p.qu_factor_price_to_stock AS product_qu_factor_price_to_stock,
	sc.is_in_stock_or_below_min_stock,
	p.disable_open,
	sc.household_id
FROM (
	SELECT *, 1 AS is_in_stock_or_below_min_stock
	FROM stock_current
	WHERE best_before_date IS NOT NULL
	UNION
	SELECT m.id, 0, 0, 0, null, 0, 0, 0, p.due_type, m.household_id, 1 AS is_in_stock_or_below_min_stock
	FROM stock_missing_products m
	JOIN products p
		ON m.id = p.id
		AND p.household_id = m.household_id
	WHERE m.id NOT IN (SELECT product_id FROM stock_current WHERE household_id = m.household_id)
	UNION
	SELECT p2.id, 0, 0, 0, null, 0, 0, 0, p2.due_type, p2.household_id, 0 AS is_in_stock_or_below_min_stock
	FROM products p2
	WHERE active = 1
		AND p2.id NOT IN (SELECT product_id FROM stock_current WHERE household_id = p2.household_id UNION SELECT id FROM stock_missing_products WHERE household_id = p2.household_id)
	) sc
JOIN products_view p
	ON sc.product_id = p.id
	AND p.household_id = sc.household_id
JOIN locations l
	ON p.location_id = l.id
	AND l.household_id = sc.household_id
JOIN quantity_units qu_stock
	ON p.qu_id_stock = qu_stock.id
	AND qu_stock.household_id = sc.household_id
JOIN quantity_units qu_purchase
	ON p.qu_id_purchase = qu_purchase.id
	AND qu_purchase.household_id = sc.household_id
JOIN quantity_units qu_consume
	ON p.qu_id_consume = qu_consume.id
	AND qu_consume.household_id = sc.household_id
JOIN quantity_units qu_price
	ON p.qu_id_price = qu_price.id
	AND qu_price.household_id = sc.household_id
LEFT JOIN product_groups pg
	ON p.product_group_id = pg.id
	AND pg.household_id = sc.household_id
LEFT JOIN shopping_locations sl
	ON p.shopping_location_id = sl.id
	AND sl.household_id = sc.household_id
LEFT JOIN cache__products_last_purchased plp
	ON sc.product_id = plp.product_id
	AND plp.household_id = sc.household_id
LEFT JOIN cache__products_average_price pap
	ON sc.product_id = pap.product_id
	AND pap.household_id = sc.household_id
LEFT JOIN product_barcodes_comma_separated pbcs
	ON sc.product_id = pbcs.product_id
	AND pbcs.household_id = sc.household_id
LEFT JOIN products p_parent
	ON p.parent_product_id = p_parent.id
	AND p_parent.household_id = sc.household_id
WHERE p.hide_on_stock_overview = 0;

-- batch 5: the products family --------------------------------------------

DROP VIEW product_qu_relations;
CREATE VIEW product_qu_relations
AS
-- This view builds which product is related to which QU, direct or indirect, based on QU conversions

-- The products stock QU
SELECT
	-1 AS id, -- Dummy, LessQL needs an id column
	p.id AS product_id,
	p.qu_id_stock AS qu_id,
	p.household_id
FROM products p

UNION

-- The products purchase QU
SELECT
	-1 AS id, -- Dummy, LessQL needs an id column
	p.id AS product_id,
	p.qu_id_purchase AS qu_id,
	p.household_id
FROM products p

UNION

-- All (direct) product conversions (product overrides)
SELECT
	-1 AS id, -- Dummy, LessQL needs an id column
	quc.product_id,
	quc.to_qu_id AS qu_id,
	quc.household_id
FROM quantity_unit_conversions quc
WHERE quc.product_id IS NOT NULL

UNION

-- All (indirect) default QU conversions
SELECT
	-1 AS id, -- Dummy, LessQL needs an id column
	p.id AS product_id,
	qur2.qu_id,
	p.household_id
from products p
JOIN quantity_unit_conversions quc
	ON (p.qu_id_stock = quc.from_qu_id OR p.qu_id_purchase = quc.from_qu_id)
	AND p.id = quc.product_id
	AND quc.household_id = p.household_id
JOIN quantity_units_resolved qur1
	ON quc.to_qu_id = qur1.qu_id
	AND qur1.household_id = p.household_id
JOIN quantity_units_resolved qur2
	ON qur1.related_qu_id = qur2.qu_id
	AND qur2.household_id = p.household_id;

DROP VIEW products_average_price;
CREATE VIEW products_average_price
AS
SELECT
	1 AS id, -- Dummy, LessQL needs an id column
	sl.product_id,
	SUM(IFNULL(sl.edited_origin_amount, sl.amount) * sl.price) / SUM(IFNULL(sl.edited_origin_amount, sl.amount)) as price,
	sl.household_id
FROM (
	SELECT sl.*, CASE WHEN sl.transaction_type = 'stock-edit-new' THEN see.edited_origin_amount END AS edited_origin_amount
	FROM stock_log sl
	LEFT JOIN stock_edited_entries see
		ON sl.stock_id = see.stock_id
		AND see.household_id = sl.household_id
) sl
WHERE sl.undone = 0
	AND (
		(sl.transaction_type IN ('purchase', 'inventory-correction', 'self-production') AND sl.stock_id NOT IN (SELECT stock_id FROM stock_edited_entries WHERE household_id = sl.household_id)) -- Unedited origin entries
		OR (sl.transaction_type = 'stock-edit-new' AND sl.id IN (SELECT stock_log_id_of_newest_edited_entry FROM stock_edited_entries WHERE household_id = sl.household_id)) -- Edited origin entries => take the newest "stock-edit-new" one
	)
	AND IFNULL(sl.price, 0) > 0
	AND IFNULL(sl.amount, 0) > 0
GROUP BY sl.product_id, sl.household_id;

DROP VIEW products_price_history;
CREATE VIEW products_price_history
AS
SELECT
	sl.product_id AS id, -- Dummy, LessQL needs an id column
	sl.product_id,
	sl.price,
	IFNULL(sl.edited_origin_amount, sl.amount) AS amount,
	sl.purchased_date,
	sl.shopping_location_id,
	sl.transaction_type,
	sl.household_id
FROM (
	SELECT sl.*, CASE WHEN sl.transaction_type = 'stock-edit-new' THEN see.edited_origin_amount END AS edited_origin_amount
	FROM stock_log sl
	LEFT JOIN stock_edited_entries see
		ON sl.stock_id = see.stock_id
		AND see.household_id = sl.household_id
) sl
WHERE sl.undone = 0
	AND (
		(sl.transaction_type IN ('purchase', 'inventory-correction', 'self-production') AND sl.stock_id NOT IN (SELECT stock_id FROM stock_edited_entries WHERE household_id = sl.household_id)) -- Unedited origin entries
		OR (sl.transaction_type = 'stock-edit-new' AND sl.id IN (SELECT stock_log_id_of_newest_edited_entry FROM stock_edited_entries WHERE household_id = sl.household_id)) -- Edited origin entries => take the newest "stock-edit-new" one
	)
	AND IFNULL(sl.price, 0) > 0
	AND IFNULL(sl.amount, 0) > 0;

DROP VIEW products_current_substitutions;
CREATE VIEW products_current_substitutions
AS

/*
	When a parent product is not in stock itself,
	any sub product (the next based on the default consume rule) should be used

	This view lists all parent products and in the column "product_id_effective" either itself,
	when the corresponding parent product is currently in stock itself, or otherwise the next sub product to use
*/

SELECT
	-1, -- Dummy
	p_sub.id AS parent_product_id,
	CASE WHEN p_sub.has_sub_products = 1 THEN
		CASE WHEN IFNULL(sc.amount, 0) = 0 THEN -- Parent product itself is currently not in stock => use the next sub product
			(
			SELECT x_snu.product_id
			FROM products_resolved x_pr
			JOIN stock_next_use x_snu
				ON x_pr.sub_product_id = x_snu.product_id
				AND x_snu.household_id = x_pr.household_id
			WHERE x_pr.parent_product_id = p_sub.id
				AND x_pr.household_id = p_sub.household_id
				AND x_pr.parent_product_id != x_pr.sub_product_id
			ORDER BY x_snu.priority DESC, x_snu.open DESC, x_snu.best_before_date ASC, x_snu.purchased_date ASC
			LIMIT 1
			)
		ELSE -- Parent product itself is currently in stock => use it
			p_sub.id
		END
	END AS product_id_effective,
	p_sub.household_id
FROM products_view p
JOIN products_resolved pr
	ON p.id = pr.parent_product_id
	AND pr.household_id = p.household_id
JOIN products_view p_sub
	ON pr.sub_product_id = p_sub.id
	AND p_sub.household_id = p.household_id
JOIN stock_current sc
	ON p_sub.id = sc.product_id
	AND sc.household_id = p.household_id
WHERE p_sub.has_sub_products = 1;

-- batch 6: last-purchased and product details -----------------------------

DROP VIEW products_last_purchased;
CREATE VIEW products_last_purchased
AS
SELECT
	1 AS id, -- Dummy, LessQL needs an id column
	sl.product_id,
	sl.amount,
	sl.best_before_date,
	sl.purchased_date,
	sl.location_id,
	sl.shopping_location_id,
	IFNULL((SELECT price FROM products_price_history WHERE product_id = sl.product_id AND household_id = sl.household_id ORDER BY purchased_date DESC LIMIT 1), 0) AS price,
	sl.household_id
FROM stock_log sl
JOIN (
	/*
		This subquery gets the ID of the stock_log row (per product) which referes to the last purchase transaction,
		while taking undone and edited transactions into account
	*/
	SELECT
		sl1.product_id,
		MAX(sl1.id) stock_log_id_of_last_purchase,
		sl1.household_id
	FROM stock_log sl1
	JOIN (
		/*
			This subquery finds the last purchased date per product,
			there can be multiple purchase transactions per day, therefore a JOIN by purchased_date
			for the outer query on this and then take MAX id of stock_log (of that day)
		*/
		SELECT
			sl2.product_id,
			MAX(sl2.purchased_date) AS last_purchased_date,
			sl2.household_id
		FROM stock_log sl2
		WHERE sl2.undone = 0
			AND (
				(sl2.transaction_type IN ('purchase', 'inventory-correction', 'self-production') AND sl2.stock_id NOT IN (SELECT stock_id FROM stock_edited_entries WHERE household_id = sl2.household_id))
				OR (sl2.transaction_type = 'stock-edit-new' AND sl2.stock_id IN (SELECT stock_id FROM stock_edited_entries WHERE household_id = sl2.household_id) AND sl2.id IN (SELECT stock_log_id_of_newest_edited_entry FROM stock_edited_entries WHERE household_id = sl2.household_id))
			)
		GROUP BY sl2.product_id, sl2.household_id
	) x2
		ON sl1.product_id = x2.product_id
		AND sl1.purchased_date = x2.last_purchased_date
		AND x2.household_id = sl1.household_id
	WHERE sl1.undone = 0
		AND (
			(sl1.transaction_type IN ('purchase', 'inventory-correction', 'self-production') AND sl1.stock_id NOT IN (SELECT stock_id FROM stock_edited_entries WHERE household_id = sl1.household_id))
			OR (sl1.transaction_type = 'stock-edit-new' AND sl1.stock_id IN (SELECT stock_id FROM stock_edited_entries WHERE household_id = sl1.household_id) AND sl1.id IN (SELECT stock_log_id_of_newest_edited_entry FROM stock_edited_entries WHERE household_id = sl1.household_id))
		)
	GROUP BY sl1.product_id, sl1.household_id
) x
	ON sl.product_id = x.product_id
	AND sl.id = x.stock_log_id_of_last_purchase
	AND x.household_id = sl.household_id;

DROP VIEW uihelper_product_details;
CREATE VIEW uihelper_product_details
AS
SELECT
	p.id,
	plp.purchased_date AS last_purchased_date,
	plp.price AS last_purchased_price,
	plp.shopping_location_id AS last_purchased_shopping_location_id,
	pap.price AS average_price,
	sl.average_shelf_life_days,
	pcp.price AS current_price,
	last_used.used_date AS last_used_date,
	next_due.best_before_date AS next_due_date,
	IFNULL((spoil_count.amount * 100.0) / consume_count.amount, 0) AS spoil_rate,
	CAST(IFNULL(quc_purchase2stock.factor, 1.0) AS REAL) AS qu_factor_purchase_to_stock,
	CAST(IFNULL(quc_price2stock.factor, 1.0) AS REAL) AS qu_factor_price_to_stock,
	CASE WHEN EXISTS(SELECT 1 FROM products px WHERE px.parent_product_id = p.id AND px.household_id = p.household_id) THEN 1 ELSE 0 END AS has_childs,
	p.household_id
FROM products p
LEFT JOIN cache__products_last_purchased plp
	ON p.id = plp.product_id
	AND plp.household_id = p.household_id
LEFT JOIN cache__products_average_price pap
	ON p.id = pap.product_id
	AND pap.household_id = p.household_id
LEFT JOIN stock_average_product_shelf_life sl
	ON p.id = sl.id
	AND sl.household_id = p.household_id
LEFT JOIN products_current_price pcp
	ON p.id = pcp.product_id
	AND pcp.household_id = p.household_id
LEFT JOIN cache__quantity_unit_conversions_resolved quc_purchase2stock
	ON p.id = quc_purchase2stock.product_id
	AND quc_purchase2stock.household_id = p.household_id
	AND p.qu_id_purchase = quc_purchase2stock.from_qu_id
	AND p.qu_id_stock = quc_purchase2stock.to_qu_id
LEFT JOIN cache__quantity_unit_conversions_resolved quc_price2stock
	ON p.id = quc_price2stock.product_id
	AND quc_price2stock.household_id = p.household_id
	AND p.qu_id_price = quc_price2stock.from_qu_id
	AND p.qu_id_stock = quc_price2stock.to_qu_id
LEFT JOIN (
	SELECT product_id, MAX(used_date) AS used_date, household_id
	FROM stock_log
	WHERE transaction_type = 'consume'
		AND undone = 0
	GROUP BY product_id, household_id
) last_used
	ON p.id = last_used.product_id
	AND last_used.household_id = p.household_id
LEFT JOIN (
	SELECT product_id, MIN(best_before_date) AS best_before_date, household_id
	FROM stock
	GROUP BY product_id, household_id
) next_due
	ON p.id = next_due.product_id
	AND next_due.household_id = p.household_id
LEFT JOIN (
	SELECT product_id, SUM(amount) AS amount, household_id
	FROM stock_log
	WHERE transaction_type = 'consume'
		AND undone = 0
	GROUP BY product_id, household_id
) consume_count
	ON p.id = consume_count.product_id
	AND consume_count.household_id = p.household_id
LEFT JOIN (
	SELECT product_id, SUM(amount) AS amount, household_id
	FROM stock_log
	WHERE transaction_type = 'consume'
		AND undone = 0
		AND spoiled = 1
	GROUP BY product_id, household_id
) spoil_count
	ON p.id = spoil_count.product_id
	AND spoil_count.household_id = p.household_id;

-- batch 7a: chores_current ------------------------------------------------
-- Seven repeated correlated subqueries on chores_log, each needing the
-- household constraint, plus the adaptive-period average frequency lookup.

DROP VIEW chores_current;
CREATE VIEW chores_current
AS
SELECT
	x.chore_id AS id, -- Dummy, LessQL needs an id column
	x.chore_id,
	x.chore_name,
	x.last_tracked_time,
	CASE WHEN x.rollover = 1 AND DATETIME('now', 'localtime') > x.next_estimated_execution_time THEN
		CASE WHEN IFNULL(x.track_date_only, 0) = 1 THEN
			DATETIME(STRFTIME('%Y-%m-%d', DATETIME('now', 'localtime')) || ' 23:59:59')
		ELSE
			DATETIME(STRFTIME('%Y-%m-%d', DATETIME('now', 'localtime')) || ' ' || STRFTIME('%H:%M:%S', x.next_estimated_execution_time))
		END
	ELSE
		CASE WHEN IFNULL(x.track_date_only, 0) = 1 THEN
			DATETIME(STRFTIME('%Y-%m-%d', x.next_estimated_execution_time) || ' 23:59:59')
		ELSE
			x.next_estimated_execution_time
		END
	END AS next_estimated_execution_time,
	x.track_date_only,
	x.next_execution_assigned_to_user_id,
	CASE WHEN IFNULL(x.rescheduled_date, '') != '' THEN 1 ELSE 0 END AS is_rescheduled,
	CASE WHEN IFNULL(x.rescheduled_next_execution_assigned_to_user_id, '') != '' THEN 1 ELSE 0 END AS is_reassigned,
	x.household_id
FROM (

SELECT
	h.id AS chore_id,
	h.name AS chore_name,
	MAX(l.tracked_time) AS last_tracked_time,
	CASE WHEN IFNULL(h.rescheduled_date, '') != '' THEN
		h.rescheduled_date
	ELSE
		CASE WHEN MAX(l.tracked_time) IS NULL AND h.period_type != 'manually' THEN
			h.start_date
		ELSE
			CASE h.period_type
				WHEN 'manually' THEN NULL
				WHEN 'hourly' THEN DATETIME(MAX(l.tracked_time), '+' || CAST(h.period_interval AS TEXT) || ' hour')
				WHEN 'daily' THEN DATETIME(SUBSTR(CAST(DATETIME(MAX(l.tracked_time), '+' || CAST(h.period_interval AS TEXT) || ' days') AS TEXT), 1, 11) || SUBSTR(CAST(h.start_date AS TEXT), -8))
				WHEN 'weekly' THEN (
					SELECT next
						FROM (
						SELECT 'sunday' AS day, DATETIME((SELECT tracked_time FROM chores_log WHERE chore_id = h.id AND household_id = h.household_id ORDER BY tracked_time DESC LIMIT 1), '1 days', '+' || CAST((h.period_interval - 1) * 7 AS TEXT) || ' days', 'weekday 0') AS next
						UNION
						SELECT 'monday' AS day, DATETIME((SELECT tracked_time FROM chores_log WHERE chore_id = h.id AND household_id = h.household_id ORDER BY tracked_time DESC LIMIT 1), '1 days', '+' || CAST((h.period_interval - 1) * 7 AS TEXT) || ' days', 'weekday 1') AS next
						UNION
						SELECT 'tuesday' AS day, DATETIME((SELECT tracked_time FROM chores_log WHERE chore_id = h.id AND household_id = h.household_id ORDER BY tracked_time DESC LIMIT 1), '1 days', '+' || CAST((h.period_interval - 1) * 7 AS TEXT) || ' days', 'weekday 2') AS next
						UNION
						SELECT 'wednesday' AS day, DATETIME((SELECT tracked_time FROM chores_log WHERE chore_id = h.id AND household_id = h.household_id ORDER BY tracked_time DESC LIMIT 1), '1 days', '+' || CAST((h.period_interval - 1) * 7 AS TEXT) || ' days', 'weekday 3') AS next
						UNION
						SELECT 'thursday' AS day, DATETIME((SELECT tracked_time FROM chores_log WHERE chore_id = h.id AND household_id = h.household_id ORDER BY tracked_time DESC LIMIT 1), '1 days', '+' || CAST((h.period_interval - 1) * 7 AS TEXT) || ' days', 'weekday 4') AS next
						UNION
						SELECT 'friday' AS day, DATETIME((SELECT tracked_time FROM chores_log WHERE chore_id = h.id AND household_id = h.household_id ORDER BY tracked_time DESC LIMIT 1), '1 days', '+' || CAST((h.period_interval - 1) * 7 AS TEXT) || ' days', 'weekday 5') AS next
						UNION
						SELECT 'saturday' AS day, DATETIME((SELECT tracked_time FROM chores_log WHERE chore_id = h.id AND household_id = h.household_id ORDER BY tracked_time DESC LIMIT 1), '1 days', '+' || CAST((h.period_interval - 1) * 7 AS TEXT) || ' days', 'weekday 6') AS next
					)
					WHERE INSTR(period_config, day) > 0
					ORDER BY next
					LIMIT 1
				)
				WHEN 'monthly' THEN DATETIME(MAX(l.tracked_time), 'start of month', '+' || CAST(h.period_interval AS TEXT) || ' month', '+' || CAST(h.period_days - 1 AS TEXT) || ' day')
				WHEN 'yearly' THEN DATETIME(SUBSTR(CAST(DATETIME(MAX(l.tracked_time), '+' || CAST(h.period_interval AS TEXT) || ' years') AS TEXT), 1, 4) || SUBSTR(CAST(h.start_date AS TEXT), 5, 6) || SUBSTR(CAST(DATETIME(MAX(l.tracked_time), '+' || CAST(h.period_interval AS TEXT) || ' years') AS TEXT), -9))
				WHEN 'adaptive' THEN DATETIME(MAX(l.tracked_time), '+' || CAST(IFNULL((SELECT average_frequency_hours FROM chores_execution_average_frequency WHERE chore_id = h.id AND household_id = h.household_id), 0) AS TEXT) || ' hour')
			END
		END
	END AS next_estimated_execution_time,
	h.track_date_only,
	h.rollover,
	h.next_execution_assigned_to_user_id,
	h.rescheduled_date,
	h.rescheduled_next_execution_assigned_to_user_id,
	h.household_id
FROM chores h
LEFT JOIN chores_log l
	ON h.id = l.chore_id
	AND l.household_id = h.household_id
	AND l.undone = 0
WHERE h.active = 1
GROUP BY h.id, h.name, h.period_days, h.household_id
) x;

-- batch 7b: quantity_unit_conversions_resolved -----------------------------
-- A seven-CTE recursive closure. household_id is threaded only through the
-- final projection, deliberately: every scoped table uses a globally unique
-- INTEGER PRIMARY KEY, so a given qu_id or product_id belongs to exactly one
-- household and the closure's joins cannot cross households on their own.
-- The column is needed so the view can be FILTERED, not to make its joins safe.

DROP VIEW quantity_unit_conversions_resolved;
CREATE VIEW quantity_unit_conversions_resolved
AS

WITH RECURSIVE

-- Default QU conversions are handled in a later CTE, as we can't determine yet, for which products they are applicable.
default_conversions(from_qu_id, to_qu_id, factor)
AS (
	SELECT
		from_qu_id,
		to_qu_id,
		factor
	FROM quantity_unit_conversions
	WHERE product_id IS NULL
),

-- First find the closure for all default conversions. This will allow for further pruning when looking for product closure.
default_closure(depth, from_qu_id, to_qu_id, factor, path)
AS (
	-- As a base case, select all available default conversions
	SELECT
		1 as depth,
		from_qu_id,
		to_qu_id,
		factor,
		'/' || from_qu_id || '/' || to_qu_id || '/' -- We need to keep track of the conversion path in order to prevent cycles
	FROM default_conversions

	UNION

	-- Recursive case: Find all paths
	SELECT
		c.depth + 1,
		c.from_qu_id,
		s.to_qu_id,
		c.factor * s.factor,
		c.path || s.to_qu_id || '/'
	FROM default_closure c
	JOIN default_conversions s
		ON c.to_qu_id = s.from_qu_id
	WHERE c.path NOT LIKE ('%/' || s.to_qu_id || '/%') -- Prevent cycles
		AND NOT EXISTS(SELECT 1 FROM default_conversions ci WHERE ci.from_qu_id = c.from_qu_id AND ci.to_qu_id = s.to_qu_id) -- Prune if one of the existing conversions repeats (saves a lot of processing time)

),

default_closure_distinct(from_qu_id, to_qu_id, factor, path)
AS (
	SELECT DISTINCT
		from_qu_id,
		to_qu_id,
		FIRST_VALUE(factor) OVER win AS factor,
		FIRST_VALUE(path) OVER win AS path
	FROM default_closure
	GROUP BY from_qu_id, to_qu_id
	WINDOW win AS (PARTITION BY from_qu_id, to_qu_id ORDER BY depth)
	ORDER BY from_qu_id, to_qu_id
),

product_conversions(product_id, from_qu_id, to_qu_id, factor)
AS (
	-- Priority 1: Product-specific QU overrides
	-- Note that the quantity_unit_conversions table already contains both conversion directions for every conversion.
	SELECT
		product_id,
		from_qu_id,
		to_qu_id,
		factor
	FROM quantity_unit_conversions
	WHERE product_id IS NOT NULL

	UNION

	-- Priority 2: QU conversions with a factor of 1.0 from the stock unit to the stock unit
	SELECT
		id,
		qu_id_stock,
		qu_id_stock,
		1.0
	FROM products
),

product_closure(depth, product_id, from_qu_id, to_qu_id, factor, path)
AS (
	-- As a base case, select all available product-specific conversions
	SELECT
		1 as depth,
		product_id,
		from_qu_id,
		to_qu_id,
		factor,
		'/' || from_qu_id || '/' || to_qu_id || '/' -- We need to keep track of the conversion path in order to prevent cycles
	FROM product_conversions

	UNION

	-- Recursive case: Find all paths
	SELECT
		c.depth + 1,
		c.product_id,
		c.from_qu_id,
		s.to_qu_id,
		c.factor * s.factor,
		c.path || s.to_qu_id || '/'
	FROM product_closure c
	JOIN product_conversions s
		ON c.product_id = s.product_id
		AND c.to_qu_id = s.from_qu_id
	WHERE c.path NOT LIKE ('%/' || s.to_qu_id || '/%') -- Prevent cycles
		AND NOT EXISTS(SELECT 1 FROM product_conversions ci WHERE ci.product_id = c.product_id AND ci.from_qu_id = c.from_qu_id AND ci.to_qu_id = s.to_qu_id) -- Prune if one of the existing conversions repeats (saves a lot of processing time)
),

product_closure_distinct(product_id, from_qu_id, to_qu_id, factor, path)
AS (
	SELECT DISTINCT
		product_id,
		from_qu_id,
		to_qu_id,
		FIRST_VALUE(factor) OVER win AS factor,
		FIRST_VALUE(path) OVER win AS path
	FROM product_closure
	GROUP BY product_id, from_qu_id, to_qu_id
	WINDOW win AS (PARTITION BY product_id, from_qu_id, to_qu_id ORDER BY depth)
	ORDER BY product_id, from_qu_id, to_qu_id
),

-- Now we connect the two closures by adding the reachable conversions from product specific conversions to default conversions
product_reachable(product_id, from_qu_id, to_qu_id, factor, path)
AS (
	SELECT
		product_id,
		from_qu_id,
		to_qu_id,
		factor,
		path
	FROM product_closure_distinct

	UNION

	SELECT
		cd.product_id,
		dcd.from_qu_id,
		dcd.to_qu_id,
		dcd.factor,
		'/' || dcd.from_qu_id || '/' || dcd.to_qu_id || '/'
	FROM product_closure_distinct cd
	JOIN default_closure_distinct dcd
		ON cd.to_qu_id = dcd.from_qu_id
		OR cd.to_qu_id = dcd.to_qu_id
	WHERE NOT EXISTS(SELECT 1 FROM product_closure_distinct ci WHERE ci.product_id = cd.product_id AND ci.from_qu_id = dcd.from_qu_id AND ci.to_qu_id = dcd.to_qu_id)
),

product_reachable_distinct(product_id, from_qu_id, to_qu_id, factor, path)
AS (
	SELECT DISTINCT
		product_id,
		from_qu_id,
		to_qu_id,
		FIRST_VALUE(factor) OVER win AS factor,
		FIRST_VALUE(path) OVER win AS path
	FROM product_reachable
	GROUP BY product_id, from_qu_id, to_qu_id
	WINDOW win AS (PARTITION BY product_id, from_qu_id, to_qu_id)
	ORDER BY product_id, from_qu_id, to_qu_id
),

-- Finally we build the combined closure
closure_final(depth, product_id, from_qu_id, to_qu_id, factor, path)
AS (
	-- As a base case, select the product closure
	SELECT
		1,
		product_id,
		from_qu_id,
		to_qu_id,
		factor,
		path -- We need to keep track of the conversion path in order to prevent cycles
	FROM product_reachable_distinct

	UNION

	-- Add a default unit conversion to the *end* of the conversion chain
	SELECT
		c.depth + 1,
		c.product_id,
		c.from_qu_id,
		s.to_qu_id,
		c.factor * s.factor,
		c.path || s.to_qu_id || '/'
	FROM closure_final c
	JOIN product_reachable_distinct s
		ON c.product_id = s.product_id
		AND c.to_qu_id = s.from_qu_id
	WHERE c.path NOT LIKE ('%/' || s.to_qu_id || '/%') -- Prevent cycles
		AND NOT EXISTS(SELECT 1 FROM product_reachable_distinct ci WHERE ci.product_id = c.product_id AND ci.from_qu_id = c.from_qu_id AND ci.to_qu_id = s.to_qu_id) -- Prune (if already exists)
)

SELECT DISTINCT
	-1 AS id, -- Dummy, LessQL needs an id column
	c.product_id,
	c.from_qu_id,
	qu_from.name AS from_qu_name,
	qu_from.name_plural AS from_qu_name_plural,
	c.to_qu_id,
	qu_to.name AS to_qu_name,
	qu_to.name_plural AS to_qu_name_plural,
	FIRST_VALUE(c.factor) OVER win AS factor,
	FIRST_VALUE(c.path) OVER win AS path,
	qu_from.household_id
FROM closure_final c
JOIN quantity_units qu_from
	ON c.from_qu_id = qu_from.id
JOIN quantity_units qu_to
	ON c.to_qu_id = qu_to.id
GROUP BY c.product_id, c.from_qu_id, c.to_qu_id, qu_from.household_id
WINDOW win AS (PARTITION BY c.product_id, c.from_qu_id, c.to_qu_id ORDER BY c.depth)
ORDER BY c.product_id, c.from_qu_id, c.to_qu_id;

-- batch 7c: the recipes chain ---------------------------------------------
-- recipes_pos_resolved has two near-identical UNION branches, both rooted at
-- "FROM recipes r"; household_id comes from there. Same reasoning as
-- quantity_unit_conversions_resolved: the ids joined on are globally unique,
-- so the joins cannot cross households; the column exists to allow filtering.
-- Order matters below: recipes_pos_resolved -> missing counts -> resolved.

DROP VIEW recipes_resolved;
DROP VIEW recipes_missing_product_counts;
DROP VIEW recipes_pos_resolved;
CREATE VIEW recipes_pos_resolved
AS

-- Multiplication by 1.0 to force conversion to float (REAL)

-- Resolved amount (here used multiple times):
-- CASE WHEN rnr.recipe_id = rnr.includes_recipe_id THEN rp.amount * ((r.desired_servings*1.0) / (r.base_servings*1.0)) ELSE rp.amount * ((r.desired_servings*1.0) / (r.base_servings*1.0)) * ((rnr.includes_servings*1.0) / (rnrr.base_servings*1.0)) END

SELECT
	r.id AS recipe_id,
	rp.id AS recipe_pos_id,
	rp.product_id AS product_id,
	CASE WHEN rp.round_up = 1 THEN CEIL(CASE WHEN rnr.recipe_id = rnr.includes_recipe_id THEN rp.amount * ((r.desired_servings*1.0) / (r.base_servings*1.0)) ELSE rp.amount * ((r.desired_servings*1.0) / (r.base_servings*1.0)) * ((rnr.includes_servings*1.0) / (rnrr.base_servings*1.0)) END) ELSE CASE WHEN rnr.recipe_id = rnr.includes_recipe_id THEN rp.amount * ((r.desired_servings*1.0) / (r.base_servings*1.0)) ELSE rp.amount * ((r.desired_servings*1.0) / (r.base_servings*1.0)) * ((rnr.includes_servings*1.0) / (rnrr.base_servings*1.0)) END END AS recipe_amount,
	IFNULL(sc.amount_aggregated, 0) AS stock_amount,
	CASE WHEN IFNULL(sc.amount_aggregated, 0) >= CASE WHEN rp.only_check_single_unit_in_stock = 1 THEN 0.00000001 ELSE CASE WHEN rp.round_up = 1 THEN CEIL(CASE WHEN rnr.recipe_id = rnr.includes_recipe_id THEN rp.amount * ((r.desired_servings*1.0) / (r.base_servings*1.0)) ELSE rp.amount * ((r.desired_servings*1.0) / (r.base_servings*1.0)) * ((rnr.includes_servings*1.0) / (rnrr.base_servings*1.0)) END) ELSE CASE WHEN rnr.recipe_id = rnr.includes_recipe_id THEN rp.amount * ((r.desired_servings*1.0) / (r.base_servings*1.0)) ELSE rp.amount * ((r.desired_servings*1.0) / (r.base_servings*1.0)) * ((rnr.includes_servings*1.0) / (rnrr.base_servings*1.0)) END END END THEN 1 ELSE 0 END AS need_fulfilled,
	CASE WHEN IFNULL(sc.amount_aggregated, 0) - CASE WHEN rp.only_check_single_unit_in_stock = 1 THEN 0.00000001 ELSE CASE WHEN rp.round_up = 1 THEN CEIL(CASE WHEN rnr.recipe_id = rnr.includes_recipe_id THEN rp.amount * ((r.desired_servings*1.0) / (r.base_servings*1.0)) ELSE rp.amount * ((r.desired_servings*1.0) / (r.base_servings*1.0)) * ((rnr.includes_servings*1.0) / (rnrr.base_servings*1.0)) END) ELSE CASE WHEN rnr.recipe_id = rnr.includes_recipe_id THEN rp.amount * ((r.desired_servings*1.0) / (r.base_servings*1.0)) ELSE rp.amount * ((r.desired_servings*1.0) / (r.base_servings*1.0)) * ((rnr.includes_servings*1.0) / (rnrr.base_servings*1.0)) END END END < 0 THEN ABS(IFNULL(sc.amount_aggregated, 0) - (CASE WHEN rp.round_up = 1 THEN CEIL(CASE WHEN rnr.recipe_id = rnr.includes_recipe_id THEN rp.amount * ((r.desired_servings*1.0) / (r.base_servings*1.0)) ELSE rp.amount * ((r.desired_servings*1.0) / (r.base_servings*1.0)) * ((rnr.includes_servings*1.0) / (rnrr.base_servings*1.0)) END) ELSE CASE WHEN rnr.recipe_id = rnr.includes_recipe_id THEN rp.amount * ((r.desired_servings*1.0) / (r.base_servings*1.0)) ELSE rp.amount * ((r.desired_servings*1.0) / (r.base_servings*1.0)) * ((rnr.includes_servings*1.0) / (rnrr.base_servings*1.0)) END END)) ELSE 0 END AS missing_amount,
	IFNULL(sl.amount, 0) AS amount_on_shopping_list,
	CASE WHEN ROUND(IFNULL(sc.amount_aggregated, 0) + CASE WHEN r.not_check_shoppinglist = 1 THEN 0 ELSE IFNULL(sl.amount, 0) END, 2) >= ROUND(CASE WHEN rp.only_check_single_unit_in_stock = 1 THEN 0.00000001 ELSE CASE WHEN rp.round_up = 1 THEN CEIL(CASE WHEN rnr.recipe_id = rnr.includes_recipe_id THEN rp.amount * ((r.desired_servings*1.0) / (r.base_servings*1.0)) ELSE rp.amount * ((r.desired_servings*1.0) / (r.base_servings*1.0)) * ((rnr.includes_servings*1.0) / (rnrr.base_servings*1.0)) END) ELSE CASE WHEN rnr.recipe_id = rnr.includes_recipe_id THEN rp.amount * ((r.desired_servings*1.0) / (r.base_servings*1.0)) ELSE rp.amount * ((r.desired_servings*1.0) / (r.base_servings*1.0)) * ((rnr.includes_servings*1.0) / (rnrr.base_servings*1.0)) END END END, 2) THEN 1 ELSE 0 END AS need_fulfilled_with_shopping_list,
	rp.qu_id,
	(r.desired_servings*1.0 / r.base_servings*1.0) * CASE WHEN rp.only_check_single_unit_in_stock = 1 THEN IFNULL(qucr.factor, 1.0) ELSE 1 END * (rnr.includes_servings*1.0 / CASE WHEN rnr.recipe_id != rnr.includes_recipe_id THEN rnrr.base_servings*1.0 ELSE 1 END) * rp.amount * IFNULL(pcp.price, 0) * rp.price_factor * CASE WHEN rp.product_id != p_effective.id THEN IFNULL(qucr.factor, 1.0) ELSE 1.0 END AS costs,
	CASE WHEN rnr.recipe_id = rnr.includes_recipe_id THEN 0 ELSE 1 END AS is_nested_recipe_pos,
	rp.ingredient_group,
	pg.name as product_group,
	rp.id, -- Just a dummy id column
	r.type as recipe_type,
	rnr.includes_recipe_id as child_recipe_id,
	rp.note,
	rp.variable_amount AS recipe_variable_amount,
	rp.only_check_single_unit_in_stock,
	rp.amount * CASE WHEN rp.only_check_single_unit_in_stock = 1 THEN IFNULL(qucr.factor, 1.0) ELSE 1 END / r.base_servings*1.0 * (rnr.includes_servings*1.0 / CASE WHEN rnr.recipe_id != rnr.includes_recipe_id THEN rnrr.base_servings*1.0 ELSE 1 END) * IFNULL(p_effective.calories, 0) * CASE WHEN rp.product_id != p_effective.id THEN IFNULL(qucr.factor, 1.0) ELSE 1.0 END AS calories,
	p.active AS product_active,
	CASE pvs.current_due_status
		WHEN 'ok' THEN 0
		WHEN 'due_soon' THEN 1
		WHEN 'overdue' THEN 10
		WHEN 'expired' THEN 20
	END AS due_score,
	IFNULL(pcs.product_id_effective, rp.product_id) AS product_id_effective,
	p.name AS product_name,
	r.household_id
FROM recipes r
JOIN recipes_nestings_resolved rnr
	ON r.id = rnr.recipe_id
JOIN recipes rnrr
	ON rnr.includes_recipe_id = rnrr.id
JOIN recipes_pos rp
	ON rnr.includes_recipe_id = rp.recipe_id
JOIN products p
	ON rp.product_id = p.id
JOIN products_volatile_status pvs
	ON rp.product_id = pvs.product_id
LEFT JOIN product_groups pg
	ON p.product_group_id = pg.id
LEFT JOIN (
	SELECT product_id, SUM(amount) AS amount
	FROM shopping_list
	GROUP BY product_id) sl
	ON rp.product_id = sl.product_id
LEFT JOIN stock_current sc
	ON rp.product_id = sc.product_id
LEFT JOIN products_current_substitutions pcs
	ON rp.product_id = pcs.parent_product_id
LEFT JOIN products_current_price pcp
	ON IFNULL(pcs.product_id_effective, rp.product_id) = pcp.product_id
LEFT JOIN products p_effective
	ON IFNULL(pcs.product_id_effective, rp.product_id) = p_effective.id
LEFT JOIN cache__quantity_unit_conversions_resolved qucr
	ON IFNULL(pcs.product_id_effective, rp.product_id) = qucr.product_id
	AND CASE WHEN rp.product_id != p_effective.id THEN p.qu_id_stock ELSE rp.qu_id END = qucr.from_qu_id
	AND IFNULL(p_effective.qu_id_stock, p.qu_id_stock) = qucr.to_qu_id
WHERE rp.not_check_stock_fulfillment = 0

UNION

-- Just add all recipe positions which should not be checked against stock with fulfilled need

SELECT
	r.id AS recipe_id,
	rp.id AS recipe_pos_id,
	rp.product_id AS product_id,
	CASE WHEN rp.round_up = 1 THEN CEIL(CASE WHEN rnr.recipe_id = rnr.includes_recipe_id THEN rp.amount * ((r.desired_servings*1.0) / (r.base_servings*1.0)) ELSE rp.amount * ((r.desired_servings*1.0) / (r.base_servings*1.0)) * ((rnr.includes_servings*1.0) / (rnrr.base_servings*1.0)) END) ELSE CASE WHEN rnr.recipe_id = rnr.includes_recipe_id THEN rp.amount * ((r.desired_servings*1.0) / (r.base_servings*1.0)) ELSE rp.amount * ((r.desired_servings*1.0) / (r.base_servings*1.0)) * ((rnr.includes_servings*1.0) / (rnrr.base_servings*1.0)) END END AS recipe_amount,
	IFNULL(sc.amount_aggregated, 0) AS stock_amount,
	1 AS need_fulfilled,
	0 AS missing_amount,
	IFNULL(sl.amount, 0) AS amount_on_shopping_list,
	1 AS need_fulfilled_with_shopping_list,
	rp.qu_id,
	(r.desired_servings*1.0 / r.base_servings*1.0) * CASE WHEN rp.only_check_single_unit_in_stock = 1 THEN IFNULL(qucr.factor, 1.0) ELSE 1 END * (rnr.includes_servings*1.0 / CASE WHEN rnr.recipe_id != rnr.includes_recipe_id THEN rnrr.base_servings*1.0 ELSE 1 END) * rp.amount * IFNULL(pcp.price, 0) * rp.price_factor * CASE WHEN rp.product_id != p_effective.id THEN IFNULL(qucr.factor, 1.0) ELSE 1.0 END AS costs,
	CASE WHEN rnr.recipe_id = rnr.includes_recipe_id THEN 0 ELSE 1 END AS is_nested_recipe_pos,
	rp.ingredient_group,
	pg.name as product_group,
	rp.id, -- Just a dummy id column
	r.type as recipe_type,
	rnr.includes_recipe_id as child_recipe_id,
	rp.note,
	rp.variable_amount AS recipe_variable_amount,
	rp.only_check_single_unit_in_stock,
	rp.amount * CASE WHEN rp.only_check_single_unit_in_stock = 1 THEN IFNULL(qucr.factor, 1.0) ELSE 1 END / r.base_servings*1.0 * (rnr.includes_servings*1.0 / CASE WHEN rnr.recipe_id != rnr.includes_recipe_id THEN rnrr.base_servings*1.0 ELSE 1 END) * IFNULL(p_effective.calories, 0) * CASE WHEN rp.product_id != p_effective.id THEN IFNULL(qucr.factor, 1.0) ELSE 1.0 END AS calories,
	p.active AS product_active,
	CASE pvs.current_due_status
		WHEN 'ok' THEN 0
		WHEN 'due_soon' THEN 1
		WHEN 'overdue' THEN 10
		WHEN 'expired' THEN 20
	END AS due_score,
	IFNULL(pcs.product_id_effective, rp.product_id) AS product_id_effective,
	p.name AS product_name,
	r.household_id
FROM recipes r
JOIN recipes_nestings_resolved rnr
	ON r.id = rnr.recipe_id
JOIN recipes rnrr
	ON rnr.includes_recipe_id = rnrr.id
JOIN recipes_pos rp
	ON rnr.includes_recipe_id = rp.recipe_id
JOIN products p
	ON rp.product_id = p.id
JOIN products_volatile_status pvs
	ON rp.product_id = pvs.product_id
LEFT JOIN product_groups pg
	ON p.product_group_id = pg.id
LEFT JOIN (
	SELECT product_id, SUM(amount) AS amount
	FROM shopping_list
	GROUP BY product_id) sl
	ON rp.product_id = sl.product_id
LEFT JOIN stock_current sc
	ON rp.product_id = sc.product_id
LEFT JOIN products_current_substitutions pcs
	ON rp.product_id = pcs.parent_product_id
LEFT JOIN products_current_price pcp
	ON IFNULL(pcs.product_id_effective, rp.product_id) = pcp.product_id
LEFT JOIN products p_effective
	ON IFNULL(pcs.product_id_effective, rp.product_id) = p_effective.id
LEFT JOIN cache__quantity_unit_conversions_resolved qucr
	ON IFNULL(pcs.product_id_effective, rp.product_id) = qucr.product_id
	AND CASE WHEN rp.product_id != p_effective.id THEN p.qu_id_stock ELSE rp.qu_id END = qucr.from_qu_id
	AND IFNULL(p_effective.qu_id_stock, p.qu_id_stock) = qucr.to_qu_id
WHERE rp.not_check_stock_fulfillment = 1;

CREATE VIEW recipes_missing_product_counts
AS
SELECT
	recipe_id,
	COUNT(*) AS missing_products_count,
	household_id
FROM recipes_pos_resolved
WHERE need_fulfilled = 0
GROUP BY recipe_id, household_id;

CREATE VIEW recipes_resolved
AS
SELECT
	1 AS id, -- Dummy, LessQL needs an id column
	r.id AS recipe_id,
	IFNULL(MIN(rpr.need_fulfilled), 1) AS need_fulfilled,
	IFNULL(MIN(rpr.need_fulfilled_with_shopping_list), 1) AS need_fulfilled_with_shopping_list,
	IFNULL(rmpc.missing_products_count, 0) AS missing_products_count,
	IFNULL(SUM(rpr.costs), 0) AS costs,
	IFNULL(SUM(rpr.costs) / CASE WHEN IFNULL(r.desired_servings, 0) = 0 THEN 1 ELSE r.desired_servings END, 0) AS costs_per_serving,
	IFNULL(SUM(rpr.calories), 0) AS calories,
	IFNULL(SUM(rpr.due_score), 0) AS due_score,
	GROUP_CONCAT(rpr.product_name) AS product_names_comma_separated,
	CASE WHEN MIN(IFNULL(rpr.costs, 0)) = 0 THEN 1 ELSE 0 END AS prices_incomplete,
	r.household_id
FROM recipes r
LEFT JOIN recipes_pos_resolved rpr
	ON r.id = rpr.recipe_id
	AND rpr.household_id = r.household_id
LEFT JOIN recipes_missing_product_counts rmpc
	ON r.id = rmpc.recipe_id
	AND rmpc.household_id = r.household_id
GROUP BY r.id, r.household_id;
