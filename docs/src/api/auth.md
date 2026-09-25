# Authorization And Secrets

## Guards

A guard is a `req -> Union{Nothing, HTTP.Response}` that admits a request (`nothing`) or denies it
(a response). [`GuardMiddleware`](@ref) turns a list of guards into a middleware; put it after the
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

## Passwords

```@docs
Nitro.Auth.make_password
Nitro.Auth.check_password
Nitro.Auth.parse_argon2_phc
```

## Secrets

```@docs
SecretString
reveal
```
