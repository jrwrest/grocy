@php require_frontend_packages(['datatables']); @endphp

@extends('layout.default')

@section('title', $__t('Households'))

@section('content')
<div class="row">
	<div class="col">
		<div class="title-related-links">
			<h2 class="title">@yield('title')</h2>
			<div class="related-links collapse d-md-flex order-2 width-xs-sm-100"
				id="related-links">
				<a class="btn btn-primary responsive-button m-1 mt-md-0 mb-md-0 float-right"
					href="{{ $U('/household/new') }}">
					{{ $__t('Add') }}
				</a>
			</div>
		</div>
	</div>
</div>

<hr class="my-2">

<div class="row">
	<div class="col-12">
		<p class="text-muted small">
			{{ $__t('Each household has its own products, stock, shopping list, recipes and chores. Members of a household see only that household\'s data.') }}
		</p>
		<table id="households-table"
			class="table table-sm table-striped dt-responsive w-100">
			<thead>
				<tr>
					<th></th>
					<th>{{ $__t('Name') }}</th>
					<th>{{ $__t('Members') }}</th>
					<th>{{ $__t('Created') }}</th>
				</tr>
			</thead>
			<tbody class="d-none">
				@foreach($households as $household)
				<tr>
					<td class="fit-content border-right">
						<a class="btn btn-info btn-sm"
							href="{{ $U('/household/') }}{{ $household->id }}">
							<i class="fa-solid fa-pencil-alt"></i>
						</a>
						<a class="btn btn-danger btn-sm household-delete-button"
							href="#"
							data-household-id="{{ $household->id }}"
							data-household-name="{{ $household->name }}">
							<i class="fa-solid fa-trash"></i>
						</a>
					</td>
					<td>
						{{ $household->name }}
						@if($currentHouseholdId == $household->id)
						<span class="badge badge-info ml-1">{{ $__t('Yours') }}</span>
						@endif
					</td>
					<td>{{ $memberCounts[$household->id] ?? 0 }}</td>
					<td>{{ $household->row_created_timestamp }}</td>
				</tr>
				@endforeach
			</tbody>
		</table>
	</div>
</div>
@stop
