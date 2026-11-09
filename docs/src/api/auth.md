# Authorization And Secrets

## Guards

A guard is a `req -> Union{Nothing, HTTP.Response}` that admits a request (`nothing`) or denies it
(a response). Any other result is an error and a `500`, never an admission.
[`GuardMiddleware`](@ref) turns a list of guards into a middleware; put it after the
authentication middleware that sets `getuser(req)`. The walkthrough is in [Sessions and Auth](@ref).

```@docs
GuardMiddleware
login_required
claim_required
role_required
permission_required
kid_required
```

## Tokens And Auth Cookies

```@docs
Nitro.Auth.jwt_validator
Nitro.Auth.session_user_validator
Nitro.Auth.JWTKeyset
Nitro.Auth.set_auth_cookie!
Nitro.Auth.extract_auth_token
```

## Refresh Tokens

Opt-in rotation with reuse detection: a store holding each sign-in's current token, a new
refresh token per use, and a rotated-away token coming back revokes its whole family. The walkthrough is in
[Authentication](../tutorial/authentication.md) §4, *Token lifetime and renewal*.

```@docs
Nitro.Auth.issue_refresh_token
Nitro.Auth.rotate_refresh_token
Nitro.Auth.revoke_refresh_token
Nitro.Auth.RefreshRotation
Nitro.Errors.RefreshTokenError
Nitro.Auth.MemoryRefreshTokenStore
Nitro.Auth.RefreshTokenPruner
Nitro.Auth.AbstractRefreshTokenStore
Nitro.Auth.RefreshTokenRecord
Nitro.Auth.RefreshTokenMiss
Nitro.Auth.record_refresh_token!
Nitro.Auth.consume_refresh_token!
Nitro.Auth.revoke_refresh_family!
Nitro.Auth.prune_refresh_tokens!
Nitro.Auth.missing_refresh_store_methods
```

## Passwords

```@docs
Nitro.Auth.make_password
Nitro.Auth.check_password
Nitro.Auth.password_concurrency
Nitro.Auth.set_password_concurrency!
Nitro.Auth.parse_argon2_phc
```

## Secrets

```@docs
SecretString
reveal
```
