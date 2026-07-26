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
