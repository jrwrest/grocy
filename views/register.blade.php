@extends('layout.default')

@section('title', $__t('Create your household'))

@section('content')
<div class="row">
	<div class="col-lg-5 offset-lg-3 col-md-6 offset-md-3 col-12">
		<h2 class="text-center">@yield('title')</h2>

		<p class="text-muted small text-center">
			{{ $__t('You get your own private household. Its products, stock, shopping list, recipes and chores are visible only to you and the people you add to it.') }}
		</p>

		<form id="register-form"
			novalidate>

			<div class="form-group">
				<label for="household_name">{{ $__t('Household name') }}</label>
				<input type="text"
					class="form-control"
					required
					id="household_name"
					name="household_name"
					autocomplete="off">
				<div class="invalid-feedback">{{ $__t('A name is required') }}</div>
			</div>

			<div class="form-group">
				<label for="username">{{ $__t('Username') }}</label>
				<input type="text"
					class="form-control"
					required
					id="username"
					name="username"
					autocomplete="username">
				<div class="invalid-feedback">{{ $__t('A username is required') }}</div>
			</div>

			<div class="form-group">
				<label for="password">{{ $__t('Password') }}</label>
				<input type="password"
					class="form-control"
					required
					minlength="8"
					id="password"
					name="password"
					autocomplete="new-password">
				<div class="invalid-feedback">{{ $__t('The password must be at least 8 characters long') }}</div>
			</div>

			<div class="form-group">
				<label for="password_confirm">{{ $__t('Confirm password') }}</label>
				<input type="password"
					class="form-control"
					required
					id="password_confirm"
					name="password_confirm"
					autocomplete="new-password">
				<div class="invalid-feedback">{{ $__t('Passwords do not match') }}</div>
			</div>

			<div id="register-error"
				class="alert alert-danger d-none"
				role="alert"></div>

			<button id="register-button"
				class="btn btn-success btn-block">{{ $__t('Create household') }}</button>

			<a class="btn btn-link btn-block"
				href="{{ $U('/login') }}">{{ $__t('I already have an account') }}</a>

		</form>
	</div>
</div>
@stop
