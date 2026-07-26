<?php

namespace Grocy\Services;

use LessQL\Database;

/**
 * Multi-household, phase 3: the application-layer scope.
 *
 * Every query in grocy funnels through LessQL's Database::table() — controllers
 * call $this->getDatabase()->products(), which becomes __call() -> table().
 * That single chokepoint is where household scoping belongs. Applying it here
 * rather than in each controller means the default is fail-CLOSED: a new query
 * added anywhere in the codebase is scoped automatically, and forgetting to add
 * a filter cannot leak data.
 *
 * Two responsibilities:
 *   - reads:  every scoped table/view is filtered to the current household
 *   - writes: new rows are stamped with the current household
 *
 * A table is "scoped" purely by whether it has a household_id column, resolved
 * once from the schema. That keeps this in step with the migrations instead of
 * duplicating a list that would silently rot.
 */
class HouseholdScopedDatabase extends Database
{
	private $scopedObjects;

	public function __construct($pdo, array $scopedObjects)
	{
		parent::__construct($pdo);
		$this->scopedObjects = array_flip($scopedObjects);
	}

	/**
	 * Names of every table and view carrying a household_id, read from the
	 * schema itself so it cannot drift from the migrations.
	 */
	public static function DiscoverScopedObjects(\PDO $pdo): array
	{
		$scoped = [];

		$objects = $pdo->query('SELECT name FROM sqlite_master WHERE type IN ("table", "view") AND name NOT LIKE "sqlite_%"');
		foreach ($objects as $object)
		{
			$name = $object['name'];

			try
			{
				foreach ($pdo->query('PRAGMA table_info(' . $name . ')') as $column)
				{
					if ($column['name'] === 'household_id')
					{
						$scoped[] = $name;
						break;
					}
				}
			}
			catch (\Throwable $ex)
			{
				// A view that cannot be prepared yet (missing custom SQLite
				// function, mid-migration state) is simply not scoped here.
				continue;
			}
		}

		return $scoped;
	}

	private function IsScoped(string $name): bool
	{
		return isset($this->scopedObjects[$name]);
	}

	/**
	 * The current household, or null when there is no user context yet
	 * (migrations, CLI, the login route).
	 */
	private function CurrentHouseholdId()
	{
		if (defined('GROCY_HOUSEHOLD_ID') && GROCY_HOUSEHOLD_ID !== null)
		{
			return GROCY_HOUSEHOLD_ID;
		}

		return null;
	}

	public function table($name, $id = null)
	{
		// mirrors the parent's handling of the List suffix
		$name = preg_replace('/List$/', '', $name);

		$result = $this->createResult($this, $name);

		$householdId = $this->CurrentHouseholdId();
		if ($householdId !== null && $this->IsScoped($name))
		{
			$result = $result->where('household_id', $householdId);
		}

		if ($id !== null)
		{
			if (!is_array($id))
			{
				$table = $this->getAlias($name);
				$primary = $this->getPrimary($table);
				$id = array($primary => $id);
			}

			// The household filter is applied BEFORE the id lookup, so fetching
			// another household's row by guessing its id returns nothing.
			return $result->where($id)->fetch();
		}

		return $result;
	}

	/**
	 * Stamp new rows with the current household, so writes cannot silently land
	 * in household 1.
	 */
	public function createRow($name, $properties = array(), $result = null)
	{
		$householdId = $this->CurrentHouseholdId();

		if ($householdId !== null && $this->IsScoped($name) && !isset($properties['household_id']))
		{
			$properties['household_id'] = $householdId;
		}

		return parent::createRow($name, $properties, $result);
	}
}
