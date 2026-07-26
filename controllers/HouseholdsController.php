<?php

namespace Grocy\Controllers;

use Grocy\Controllers\Users\User;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;

class HouseholdsController extends BaseController
{
	public function HouseholdsList(Request $request, Response $response, array $args)
	{
		User::checkPermission($request, User::PERMISSION_ADMIN);

		$households = $this->getDatabase()->households()->orderBy('name', 'COLLATE NOCASE')->fetchAll();

		// Member counts must be read outside the household scope: the users table
		// carries household_id, so a scoped query only ever sees the current
		// household's members.
		$memberCounts = [];
		$rows = $this->getDatabaseService()->ExecuteDbQuery(
			'SELECT household_id, COUNT(*) AS member_count FROM users GROUP BY household_id'
		)->fetchAll(\PDO::FETCH_ASSOC);
		foreach ($rows as $row)
		{
			$memberCounts[$row['household_id']] = $row['member_count'];
		}

		return $this->renderPage($response, 'households', [
			'households' => $households,
			'memberCounts' => $memberCounts,
			'currentHouseholdId' => defined('GROCY_HOUSEHOLD_ID') ? GROCY_HOUSEHOLD_ID : null
		]);
	}

	public function HouseholdEditForm(Request $request, Response $response, array $args)
	{
		User::checkPermission($request, User::PERMISSION_ADMIN);

		if ($args['householdId'] == 'new')
		{
			return $this->renderPage($response, 'householdform', [
				'mode' => 'create'
			]);
		}

		return $this->renderPage($response, 'householdform', [
			'household' => $this->getDatabase()->households($args['householdId']),
			'members' => $this->getHouseholdService()->GetMembers($args['householdId']),
			'mode' => 'edit'
		]);
	}
}
