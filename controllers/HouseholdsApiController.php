<?php

namespace Grocy\Controllers;

use Grocy\Controllers\Users\User;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;

/**
 * Multi-household, phase 4: managing households over the API.
 *
 * Creation deliberately does NOT go through the generic /objects/households
 * route, because a bare INSERT produces a household with no master data — no
 * shopping list, location or quantity unit — which then silently no-ops on
 * ordinary operations. Everything here routes through HouseholdService so a
 * household is usable the moment it exists.
 */
class HouseholdsApiController extends BaseApiController
{
	public function GetHouseholds(Request $request, Response $response, array $args)
	{
		User::checkPermission($request, User::PERMISSION_ADMIN);

		return $this->ApiResponse($response, $this->getDatabase()->households()->orderBy('name')->fetchAll());
	}

	public function CreateHousehold(Request $request, Response $response, array $args)
	{
		User::checkPermission($request, User::PERMISSION_ADMIN);

		try
		{
			$requestBody = $this->GetParsedAndFilteredRequestBody($request);

			if (!array_key_exists('name', $requestBody) || empty(trim($requestBody['name'])))
			{
				throw new \Exception('A name is required');
			}

			$householdId = $this->getHouseholdService()->CreateHousehold(trim($requestBody['name']));

			return $this->ApiResponse($response, [
				'created_object_id' => $householdId
			]);
		}
		catch (\Exception $ex)
		{
			return $this->GenericErrorResponse($response, $ex->getMessage());
		}
	}

	public function EditHousehold(Request $request, Response $response, array $args)
	{
		User::checkPermission($request, User::PERMISSION_ADMIN);

		try
		{
			$requestBody = $this->GetParsedAndFilteredRequestBody($request);

			if (!array_key_exists('name', $requestBody) || empty(trim($requestBody['name'])))
			{
				throw new \Exception('A name is required');
			}

			$this->getHouseholdService()->EditHousehold($args['householdId'], trim($requestBody['name']));

			return $this->EmptyApiResponse($response);
		}
		catch (\Exception $ex)
		{
			return $this->GenericErrorResponse($response, $ex->getMessage());
		}
	}

	public function DeleteHousehold(Request $request, Response $response, array $args)
	{
		User::checkPermission($request, User::PERMISSION_ADMIN);

		try
		{
			$this->getHouseholdService()->DeleteHousehold($args['householdId']);

			return $this->EmptyApiResponse($response);
		}
		catch (\Exception $ex)
		{
			return $this->GenericErrorResponse($response, $ex->getMessage());
		}
	}

	public function GetMembers(Request $request, Response $response, array $args)
	{
		User::checkPermission($request, User::PERMISSION_ADMIN);

		try
		{
			return $this->ApiResponse($response, $this->getHouseholdService()->GetMembers($args['householdId']));
		}
		catch (\Exception $ex)
		{
			return $this->GenericErrorResponse($response, $ex->getMessage());
		}
	}

	/**
	 * Moves an existing user into this household.
	 *
	 * This is how the first member of a new household is set: because the users
	 * table is itself household-scoped, a household with no members cannot be
	 * reached from inside its own scope at all.
	 */
	public function AddMember(Request $request, Response $response, array $args)
	{
		User::checkPermission($request, User::PERMISSION_ADMIN);

		try
		{
			$requestBody = $this->GetParsedAndFilteredRequestBody($request);

			if (!array_key_exists('user_id', $requestBody) || !is_numeric($requestBody['user_id']))
			{
				throw new \Exception('A numeric user_id is required');
			}

			$this->getHouseholdService()->AssignUserToHousehold(
				intval($requestBody['user_id']),
				$args['householdId']
			);

			return $this->EmptyApiResponse($response);
		}
		catch (\Exception $ex)
		{
			return $this->GenericErrorResponse($response, $ex->getMessage());
		}
	}
}
