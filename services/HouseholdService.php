<?php

namespace Grocy\Services;

/**
 * Multi-household, phase 4: creating a household that is actually usable.
 *
 * A bare INSERT into `households` is not enough. Grocy's migrations seed the
 * default shopping list, location and quantity unit for household 1 only, so a
 * household created without them starts with no master data at all — and
 * because callers pass a literal list_id of 1, "add to shopping list" then
 * matches nothing under that household's scope and silently does nothing.
 * Not a leak, but unusable.
 *
 * Always create households through here.
 */
class HouseholdService extends BaseService
{
	/**
	 * Creates a household and the minimum master data it needs to function.
	 * Returns the new household id.
	 */
	public function CreateHousehold(string $name)
	{
		$db = $this->getDatabase();

		$existing = $db->households()->where('name', $name)->fetch();
		if ($existing !== null)
		{
			throw new \Exception('A household called "' . $name . '" already exists');
		}

		// Insert unscoped: the household row itself has no household_id, and at
		// this point there is no current-household context for the new one.
		$newHousehold = $db->households()->createRow(['name' => $name])->save();
		$householdId = $newHousehold->id;

		$this->SeedDefaults($householdId);

		return $householdId;
	}

	/**
	 * The master data grocy assumes exists. Mirrors what the migrations create
	 * for household 1.
	 */
	public function SeedDefaults($householdId)
	{
		$db = $this->getDatabase();

		if ($db->shopping_lists()->where('household_id', $householdId)->count() == 0)
		{
			$db->shopping_lists()->createRow([
				'name' => 'Shopping list',
				'household_id' => $householdId
			])->save();
		}

		if ($db->locations()->where('household_id', $householdId)->count() == 0)
		{
			$db->locations()->createRow([
				'name' => 'Home',
				'household_id' => $householdId
			])->save();
		}

		if ($db->quantity_units()->where('household_id', $householdId)->count() == 0)
		{
			$db->quantity_units()->createRow([
				'name' => 'Piece',
				'name_plural' => 'Pieces',
				'household_id' => $householdId
			])->save();
		}
	}

	/**
	 * Renames a household.
	 */
	public function EditHousehold($householdId, string $name)
	{
		$household = $this->getDatabase()->households($householdId);
		if ($household === null)
		{
			throw new \Exception('Household does not exist');
		}

		$clash = $this->getDatabase()->households()->where('name = :1 AND id != :2', $name, $householdId)->fetch();
		if ($clash !== null)
		{
			throw new \Exception('A household called "' . $name . '" already exists');
		}

		$household->update(['name' => $name]);

		return $household;
	}

	/**
	 * Deletes a household. Refuses while it still has members, because deleting
	 * a household out from under a logged-in user would leave them with a
	 * household_id pointing at nothing — every scoped query would then return
	 * empty and the app would look broken rather than tell them why.
	 */
	public function DeleteHousehold($householdId)
	{
		if ($householdId == 1)
		{
			throw new \Exception('The first household cannot be deleted');
		}

		$household = $this->getDatabase()->households($householdId);
		if ($household === null)
		{
			throw new \Exception('Household does not exist');
		}

		// users is itself household-scoped, so count outside the scope
		$memberCount = (int)$this->getDatabaseService()->ExecuteDbQuery(
			'SELECT COUNT(*) FROM users WHERE household_id = ' . intval($householdId)
		)->fetchColumn();

		if ($memberCount > 0)
		{
			throw new \Exception('Household still has ' . $memberCount . ' member(s) — move or delete them first');
		}

		$household->delete();
	}

	/**
	 * Moves a user into a household.
	 *
	 * Deliberately raw SQL: the users table carries household_id and is
	 * therefore household-scoped like everything else, so $db->users($id) cannot
	 * see a user outside the CURRENT household. Creating or moving the first
	 * member of a new household has to step outside that scope — which is
	 * exactly why this lives here, in one auditable place, instead of being
	 * scattered through controllers.
	 */
	public function AssignUserToHousehold($userId, $householdId)
	{
		$exists = (int)$this->getDatabaseService()->ExecuteDbQuery(
			'SELECT COUNT(*) FROM households WHERE id = ' . intval($householdId)
		)->fetchColumn();

		if ($exists === 0)
		{
			throw new \Exception('Household does not exist');
		}

		$this->getDatabaseService()->ExecuteDbStatement(
			'UPDATE users SET household_id = ? WHERE id = ?',
			[intval($householdId), intval($userId)]
		);
	}

	/**
	 * Members of a household, ignoring the current household scope.
	 */
	public function GetMembers($householdId)
	{
		return $this->getDatabaseService()->ExecuteDbQuery(
			'SELECT id, username, first_name, last_name FROM users WHERE household_id = ' . intval($householdId) . ' ORDER BY username'
		)->fetchAll(\PDO::FETCH_ASSOC);
	}

	/**
	 * The shopping list to use when a caller does not name one. Callers pass a
	 * literal 1, which is only correct for the first household.
	 */
	public function GetDefaultShoppingListId($householdId)
	{
		$list = $this->getDatabase()->shopping_lists()
			->where('household_id', $householdId)
			->orderBy('id')
			->fetch();

		return $list === null ? null : $list->id;
	}
}
