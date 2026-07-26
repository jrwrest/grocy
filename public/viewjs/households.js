var householdsTable = $('#households-table').DataTable({
	'order': [[1, 'asc']],
	'columnDefs': [
		{ 'orderable': false, 'targets': 0 },
		{ 'searchable': false, 'targets': 0 }
	].concat($.fn.dataTable.defaults.columnDefs)
});
$('#households-table tbody').removeClass("d-none");
householdsTable.columns.adjust().draw();

$(document).on('click', '.household-delete-button', function(e)
{
	var objectName = $(e.currentTarget).attr('data-household-name');
	var objectId = $(e.currentTarget).attr('data-household-id');

	bootbox.confirm({
		message: __t('Are you sure you want to delete household "%s"?', objectName),
		closeButton: false,
		buttons: {
			cancel: { label: __t('No'), className: 'btn-secondary' },
			confirm: { label: __t('Yes'), className: 'btn-danger' }
		},
		callback: function(result)
		{
			if (result === true)
			{
				// Deliberately the dedicated endpoint, not objects/households:
				// it refuses to delete a household that still has members, which
				// would otherwise strand those users on a household_id that no
				// longer exists.
				Grocy.Api.Delete('households/' + objectId, {},
					function(result)
					{
						window.location.href = U('/households');
					},
					function(xhr)
					{
						Grocy.FrontendHelpers.ShowGenericError('Cannot delete this household', xhr.response);
					}
				);
			}
		}
	});
});
