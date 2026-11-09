## `jwt_validator` refuses a token whose `token_use` is `"refresh"`

- **Version**: Unreleased
- **Nitro ref**: #231 (PR #901, review round 2); `src/Auth/validators.jl` (`jwt_validator`,
  `_is_refresh_token`)
- **Recorded**: 2026-11-08
- **Severity**: **behavior change**. No signature changes. A verified token carrying
  `token_use = "refresh"` no longer authenticates through `BearerAuth` or `CookieAuthMiddleware`.

### What changed

`jwt_validator` now refuses a token whose `token_use` claim is the string `"refresh"`, after the
signature and time checks and before any `user_validator` runs. The auth middleware answers it with
its usual `401` (`:invalid_credentials`), on every route, whatever guards the route has.

**Why:** a refresh token has no legitimate use at a resource route. With one secret for both kinds
of token, a route that forgot `claim_required("token_use", "access")` used to accept a long-lived
refresh token as a bearer credential. AWS Cognito's verifiers make the `token_use` check mandatory
for the same reason. The refresh tokens `issue_refresh_token` mints carry `token_use = "refresh"`
and are verified by `rotate_refresh_token`, which is unaffected.

**Not affected:**
- a token with no `token_use` claim, or with any other value (`"access"`, `"id"`);
- `decode_jwt` and `encode_jwt`, which never read `token_use`;
- a custom validator that does not call `jwt_validator`.

### How to find the calls to migrate

Only one pattern breaks: a route that authenticates the **refresh** token itself through
`BearerAuth` or `CookieAuthMiddleware`, as the old "two tokens and a guard" tutorial recipe did.
One grep finds both the guard that requires the refresh value and the places that mint such a
token, whatever the spacing, and with a String or a Symbol key (`encode_jwt` writes `:token_use` as
`"token_use"`):

```bash
grep -rnE 'token_use"?\s*(=>|,)\s*"refresh"' src/ bin/ *.jl
```

Every route that receives one of those tokens through `BearerAuth` or `CookieAuthMiddleware` now
gets a `401` and needs migrating.

### Migrate your app

Verify the refresh token in the refresh handler instead, and take the middleware off that route.
`extract_auth_token` reads the same `Authorization: Bearer` header `BearerAuth` did (pass
`cookie_name` for a cookie-borne token), so clients need no change:

```julia
# ✗ before: the refresh route authenticates the refresh token through BearerAuth
urlpatterns(app, "",
    path("/auth/refresh", refresh_handler, method = "POST", middleware = [
        BearerAuth(jwt_validator(secret)),
        GuardMiddleware(claim_required("token_use", "refresh")),
    ]),
)

# ✓ after: the handler verifies it itself; the route has no auth middleware
function refresh_handler(req)
    token = extract_auth_token(req)
    token === nothing && return Res.status(401)
    claims = try
        decode_jwt(token, secret; require_exp = true, required_claims = ["sub", "token_use"])
    catch e
        e isa AuthError || rethrow()
        return Res.status(401)
    end
    claims["token_use"] == "refresh" || return Res.status(401)
    access = encode_jwt(Dict("sub" => claims["sub"], "token_use" => "access"), secret; expires_in = 900)
    return Res.json(Dict("access_token" => access))
end

urlpatterns(app, "", path("/auth/refresh", refresh_handler, method = "POST"))
```

If you want rotation and reuse detection as well, `issue_refresh_token` and `rotate_refresh_token`
replace the hand-rolled handler (tutorial: *Authentication* → *Token lifetime and renewal*).
