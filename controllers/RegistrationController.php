<?php

namespace Grocy\Controllers;

use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;

class RegistrationController extends BaseController
{
	public function RegisterPage(Request $request, Response $response, array $args)
	{
		$service = \Grocy\Services\RegistrationService::getInstance();

		// Do not render a form the backend will refuse.
		if (!$service->IsEnabled())
		{
			return $response->withStatus(404);
		}

		return $this->renderPage($response, 'register', []);
	}
}
