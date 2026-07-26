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
