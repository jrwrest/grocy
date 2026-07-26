<?php

namespace Grocy\Controllers;

use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;

/**
 * Self-registration endpoint. Reachable WITHOUT authentication (see
 * AuthMiddleware), so it refuses unless FEATURE_FLAG_SELF_REGISTRATION is on.
 */
class RegistrationApiController extends BaseApiController
{
	public function Register(Request $request, Response $response, array $args)
	{
		try
		{
			$service = \Grocy\Services\RegistrationService::getInstance();

			if (!$service->IsEnabled())
			{
				return $this->GenericErrorResponse($response, 'Self-registration is disabled on this instance', 403);
			}

			$requestBody = $this->GetParsedAndFilteredRequestBody($request);

			$userId = $service->Register(
				$requestBody['username'] ?? '',
				$requestBody['password'] ?? '',
				$requestBody['household_name'] ?? ''
			);

			return $this->ApiResponse($response, ['created_object_id' => $userId]);
		}
		catch (\Exception $ex)
		{
			return $this->GenericErrorResponse($response, $ex->getMessage());
		}
	}
}
