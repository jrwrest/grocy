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

	private function SettingOr(string $name, $fallback)
	{
		return defined('GROCY_' . $name) ? constant('GROCY_' . $name) : $fallback;
	}

	/**
	 * The requesting IP.
	 *
	 * Behind a reverse proxy (this instance runs behind Caddy) REMOTE_ADDR is the
	 * proxy, so X-Forwarded-For is needed. A client can send its own
	 * X-Forwarded-For and the proxy APPENDS to it, so the value the proxy added
	 * is the LAST entry — taking the first would let anyone spoof a fresh IP per
	 * request and walk straight through the per-IP limit.
	 */
	private function ClientIp(): string
	{
		if (!empty($_SERVER['HTTP_X_FORWARDED_FOR']))
		{
			$parts = array_map('trim', explode(',', $_SERVER['HTTP_X_FORWARDED_FOR']));
			$last = end($parts);
			if ($last !== false && $last !== '')
			{
				return $last;
			}
		}

		return $_SERVER['REMOTE_ADDR'] ?? 'unknown';
	}

	private function RecordAttempt(string $ip, bool $successful)
	{
		$this->getDatabaseService()->ExecuteDbStatement(
			'INSERT INTO registration_attempts (ip_address, successful) VALUES (?, ?)',
			[$ip, $successful ? 1 : 0]
		);

		// Keep the table from growing without bound; it is purely a rolling window.
		$this->getDatabaseService()->ExecuteDbStatement(
			"DELETE FROM registration_attempts WHERE row_created_timestamp < datetime('now', 'localtime', '-7 days')"
		);
	}

	private function CountAttempts(?string $ip): int
	{
		$sql = "SELECT COUNT(*) FROM registration_attempts WHERE row_created_timestamp > datetime('now', 'localtime', '-1 hour')";
		if ($ip !== null)
		{
			$sql .= ' AND ip_address = ' . $this->getDatabaseService()->GetDbConnectionRaw()->quote($ip);
		}

		return (int)$this->getDatabaseService()->ExecuteDbQuery($sql)->fetchColumn();
	}

	/**
	 * Free abuse protection, applied before anything is written.
	 *
	 * Every rejection is recorded as an attempt, so hammering the endpoint with
	 * invalid requests still burns the attacker's own quota rather than being
	 * free to retry.
	 */
	private function CheckAbuseLimits(array $meta)
	{
		$ip = $this->ClientIp();

		// 1. honeypot — a field real users never see and never fill
		if (!empty($meta['honeypot']))
		{
			$this->RecordAttempt($ip, false);
			throw new \Exception('Registration failed');
		}

		// 2. submit timing — a human cannot fill this form instantly
		$minSeconds = (int)$this->SettingOr('SELF_REGISTRATION_MIN_SUBMIT_SECONDS', 2);
		if ($minSeconds > 0 && isset($meta['form_rendered_at']) && is_numeric($meta['form_rendered_at']))
		{
			$elapsed = time() - (int)$meta['form_rendered_at'];
			if ($elapsed >= 0 && $elapsed < $minSeconds)
			{
				$this->RecordAttempt($ip, false);
				throw new \Exception('Registration failed');
			}
		}

		// 3. per-IP throttle
		$perIp = (int)$this->SettingOr('SELF_REGISTRATION_MAX_PER_IP_PER_HOUR', 3);
		if ($perIp > 0 && $this->CountAttempts($ip) >= $perIp)
		{
			$this->RecordAttempt($ip, false);
			throw new \Exception('Too many registration attempts from your network. Please try again later.');
		}

		// 4. instance-wide throttle, so a botnet cannot bypass the per-IP limit
		$perInstance = (int)$this->SettingOr('SELF_REGISTRATION_MAX_ATTEMPTS_PER_HOUR', 30);
		if ($perInstance > 0 && $this->CountAttempts(null) >= $perInstance)
		{
			$this->RecordAttempt($ip, false);
			throw new \Exception('Registrations are temporarily rate limited. Please try again later.');
		}

		// 5. hard cap — the direct defence against filling the disk
		$maxHouseholds = (int)$this->SettingOr('SELF_REGISTRATION_MAX_HOUSEHOLDS', 100);
		if ($maxHouseholds > 0)
		{
			$existing = (int)$this->getDatabaseService()->ExecuteDbQuery('SELECT COUNT(*) FROM households')->fetchColumn();
			if ($existing >= $maxHouseholds)
			{
				$this->RecordAttempt($ip, false);
				throw new \Exception('This instance is not accepting new households at the moment');
			}
		}

		return $ip;
	}

	/**
	 * Creates a household plus its first user. Returns the new user id.
	 *
	 * Ordering matters: the household is created and seeded first, then the user
	 * is inserted directly into it. A user cannot be created "then moved",
	 * because a brand-new household has no members and therefore cannot be
	 * reached from inside its own scope.
	 */
	public function Register(string $username, string $password, string $householdName, array $meta = [])
	{
		if (!$this->IsEnabled())
		{
			throw new \Exception('Self-registration is disabled on this instance');
		}

		// Before any write, and before revealing whether a username exists.
		$ip = $this->CheckAbuseLimits($meta);

		$username = trim($username);
		$householdName = trim($householdName);

		if ($username === '' || $householdName === '')
		{
			$this->RecordAttempt($ip, false);
			throw new \Exception('A username and a household name are required');
		}

		if (strlen($password) < 8)
		{
			$this->RecordAttempt($ip, false);
			throw new \Exception('The password must be at least 8 characters long');
		}

		// Usernames are global (they are the login identity), so this check must
		// step outside the household scope.
		$existing = (int)$this->getDatabaseService()->ExecuteDbQuery(
			'SELECT COUNT(*) FROM users WHERE username = ' . $this->getDatabaseService()->GetDbConnectionRaw()->quote($username)
		)->fetchColumn();

		if ($existing > 0)
		{
			$this->RecordAttempt($ip, false);
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
		$this->RecordAttempt($ip, true);

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
