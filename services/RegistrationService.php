<?php

namespace Grocy\Services;

use Grocy\Controllers\Users\User;

/**
 * Self-registration: one person signs up and gets their OWN household.
 *
 * Gated behind FEATURE_FLAG_SELF_REGISTRATION because enabling it means
 * strangers can create accounts on the instance.
 *
 * THE PERMISSION DECISION, which is the security-critical part:
 * a self-registered user gets full rights over their own household and NOTHING
 * else. Specifically NOT ADMIN — ADMIN grants the /households endpoints, which
 * would let any stranger who signed up rename or delete other people's
 * households and move users between them. They do get the USERS permissions,
 * which is safe: the users table is household-scoped, so a user they create is
 * stamped with their own household and cannot reach anyone else's.
 */
class RegistrationService extends BaseService
{
	/** Everything needed to run a household — deliberately excluding ADMIN. */
	const HOUSEHOLD_OWNER_PERMISSIONS = [
		User::PERMISSION_STOCK,
		User::PERMISSION_SHOPPINGLIST,
		User::PERMISSION_RECIPES,
		User::PERMISSION_CHORES,
		User::PERMISSION_TASKS,
		User::PERMISSION_BATTERIES,
		User::PERMISSION_EQUIPMENT,
		User::PERMISSION_CALENDAR,
		User::PERMISSION_MASTER_DATA_EDIT,
		User::PERMISSION_USERS,
		User::PERMISSION_USERS_EDIT_SELF,
	];

	public function IsEnabled(): bool
	{
		return defined('GROCY_FEATURE_FLAG_SELF_REGISTRATION') && GROCY_FEATURE_FLAG_SELF_REGISTRATION === true;
	}

	/**
	 * Creates a household plus its first user. Returns the new user id.
	 *
	 * Ordering matters: the household is created and seeded first, then the user
	 * is inserted directly into it. A user cannot be created "then moved",
	 * because a brand-new household has no members and therefore cannot be
	 * reached from inside its own scope.
	 */
	public function Register(string $username, string $password, string $householdName)
	{
		if (!$this->IsEnabled())
		{
			throw new \Exception('Self-registration is disabled on this instance');
		}

		$username = trim($username);
		$householdName = trim($householdName);

		if ($username === '' || $householdName === '')
		{
			throw new \Exception('A username and a household name are required');
		}

		if (strlen($password) < 8)
		{
			throw new \Exception('The password must be at least 8 characters long');
		}

		// Usernames are global (they are the login identity), so this check must
		// step outside the household scope.
		$existing = (int)$this->getDatabaseService()->ExecuteDbQuery(
			'SELECT COUNT(*) FROM users WHERE username = ' . $this->getDatabaseService()->GetDbConnectionRaw()->quote($username)
		)->fetchColumn();

		if ($existing > 0)
		{
			throw new \Exception('This username is already taken');
		}

		$householdId = $this->getHouseholdService()->CreateHousehold($householdName);

		$this->getDatabaseService()->ExecuteDbStatement(
			'INSERT INTO users (username, password, household_id) VALUES (?, ?, ?)',
			[$username, password_hash($password, PASSWORD_DEFAULT), $householdId]
		);

		$userId = (int)$this->getDatabaseService()->ExecuteDbQuery(
			'SELECT id FROM users WHERE username = ' . $this->getDatabaseService()->GetDbConnectionRaw()->quote($username)
		)->fetchColumn();

		$this->GrantOwnerPermissions($userId);

		return $userId;
	}

	private function GrantOwnerPermissions(int $userId)
	{
		$permissionIds = [];
		foreach (self::HOUSEHOLD_OWNER_PERMISSIONS as $permissionName)
		{
			$row = $this->getDatabaseService()->ExecuteDbQuery(
				'SELECT id FROM permission_hierarchy WHERE name = ' .
				$this->getDatabaseService()->GetDbConnectionRaw()->quote($permissionName)
			)->fetchColumn();

			if ($row !== false)
			{
				$permissionIds[] = (int)$row;
			}
		}

		foreach ($permissionIds as $permissionId)
		{
			$this->getDatabaseService()->ExecuteDbStatement(
				'INSERT INTO user_permissions (user_id, permission_id) VALUES (?, ?)',
				[$userId, $permissionId]
			);
		}
	}
}
