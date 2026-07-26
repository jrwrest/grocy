$('#register-button').on('click', function(e)
{
	e.preventDefault();

	$('#register-error').addClass('d-none').text('');

	var householdName = $('#household_name').val().trim();
	var username = $('#username').val().trim();
	var password = $('#password').val();
	var passwordConfirm = $('#password_confirm').val();

	// Validated here for a fast, clear message; the server enforces the same
	// rules independently, since this endpoint is reachable without an account.
	if (householdName === '' || username === '')
	{
		$('#register-error').removeClass('d-none').text(__t('A username and a household name are required'));
		return;
	}

	if (password.length < 8)
	{
		$('#register-error').removeClass('d-none').text(__t('The password must be at least 8 characters long'));
		return;
	}

	if (password !== passwordConfirm)
	{
		$('#register-error').removeClass('d-none').text(__t('Passwords do not match'));
		return;
	}

	$('#register-button').prop('disabled', true);

	Grocy.Api.Post('register', { username: username, password: password, household_name: householdName },
		function(result)
		{
			// Straight to login: registration deliberately does not sign the
			// person in, so no session is created by an unauthenticated endpoint.
			window.location.href = U('/login');
		},
		function(xhr)
		{
			$('#register-button').prop('disabled', false);
			var message = __t('Could not create your household');
			try
			{
				var parsed = JSON.parse(xhr.response);
				if (parsed.error_message)
				{
					message = parsed.error_message;
				}
			}
			catch (ignored) { }
			$('#register-error').removeClass('d-none').text(message);
		}
	);
});

$('#register-form input').keydown(function(event)
{
	if (event.keyCode === 13) // Enter
	{
		event.preventDefault();
		$('#register-button').click();
	}
});
