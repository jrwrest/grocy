@extends('layout.default')

@if($mode == 'edit')
@section('title', $__t('Edit household'))
@else
@section('title', $__t('Create household'))
@endif

@section('content')
<div class="row">
	<div class="col">
		<h2 class="title">@yield('title')</h2>
	</div>
</div>

<hr class="my-2">

<div class="row">
	<div class="col-lg-6 col-12">
		<script>
			Grocy.EditMode = '{{ $mode }}';
		</script>

		@if($mode == 'edit')
		<script>
			Grocy.EditObjectId = {{ $household->id }};
		</script>
		@endif

		<form id="household-form"
			novalidate>

			<div class="form-group">
				<label for="name">{{ $__t('Name') }}</label>
				<input type="text"
					class="form-control"
					required
					id="name"
					name="name"
					value="@if($mode == 'edit'){{ $household->name }}@endif">
				<div class="invalid-feedback">{{ $__t('A name is required') }}</div>
			</div>

			@if($mode == 'create')
			<p class="text-muted small">
				{{ $__t('A new household starts with its own default shopping list, location and quantity unit. Assign members from the user\'s own page.') }}
			</p>
			@endif

			<button id="save-household-button"
				class="btn btn-success">{{ $__t('Save') }}</button>

		</form>
	</div>

	@if($mode == 'edit')
	<div class="col-lg-6 col-12">
		<h4>{{ $__t('Members') }}</h4>
		@if(count($members) === 0)
		<p class="text-muted">{{ $__t('This household has no members yet') }}</p>
		@else
		<ul class="list-group">
			@foreach($members as $member)
			<li class="list-group-item d-flex justify-content-between align-items-center">
				<span>
					{{ $member['username'] }}
					<small class="text-muted">{{ trim($member['first_name'] . ' ' . $member['last_name']) }}</small>
				</span>
				<a class="btn btn-sm btn-outline-secondary"
					href="{{ $U('/user/') }}{{ $member['id'] }}">{{ $__t('Edit') }}</a>
			</li>
			@endforeach
		</ul>
		@endif
	</div>
	@endif
</div>
@stop
