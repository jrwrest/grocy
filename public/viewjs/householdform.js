$('#save-household-button').on('click', function(e)
{
	e.preventDefault();

	if (!Grocy.FrontendHelpers.ValidateForm("household-form", true))
	{
		return;
	}

	var jsonData = $('#household-form').serializeJSON();
	Grocy.FrontendHelpers.BeginUiBusy("household-form");

	// Deliberately the dedicated households endpoint rather than
	// objects/households: creating through the service also seeds the default
	// shopping list, location and quantity unit, without which the new
	// household silently no-ops on ordinary operations.
	if (Grocy.EditMode === 'create')
	{
		Grocy.Api.Post('households', jsonData,
			function(result)
			{
				window.location.href = U('/households');
			},
			function(xhr)
			{
				Grocy.FrontendHelpers.EndUiBusy("household-form");
				Grocy.FrontendHelpers.ShowGenericError('Error while saving, probably this household already exists', xhr.response);
			}
		);
	}
	else
	{
		Grocy.Api.Put('households/' + Grocy.EditObjectId, jsonData,
			function(result)
			{
				window.location.href = U('/households');
			},
			function(xhr)
			{
				Grocy.FrontendHelpers.EndUiBusy("household-form");
				Grocy.FrontendHelpers.ShowGenericError('Error while saving, probably this household already exists', xhr.response);
			}
		);
	}
});

$('#household-form input').keydown(function(event)
{
	if (event.keyCode === 13) // Enter
	{
		event.preventDefault();
		$('#save-household-button').click();
	}
});

setTimeout(function()
{
	$('#name').focus();
}, Grocy.FormFocusDelay);
Grocy.FrontendHelpers.ValidateForm('household-form');
