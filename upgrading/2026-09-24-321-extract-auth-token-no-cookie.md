## `extract_auth_token` no longer falls back to the `auth_token` cookie by default (#321)

- **Version**: Unreleased
- **Nitro ref**: [#321](https://github.com/PingoLee/Nitro.jl/issues/321) ; `src/Auth/cookies.jl`
- **Recorded**: 2026-09-24
- **Severity**: **behaviour (auth).** Fails closed. An app that relied on the cookie fallback now
  gets `nothing` for a cookie-only request, which usually means a 401.

### What changed

`Nitro.Auth.extract_auth_token(req)` read the `Authorization` header and, when that had no token,
fell back to the `auth_token` cookie. A cookie is an **ambient** credential: the browser attaches
it to cross-site requests too. So an API meant to be bearer-only that used this helper also
accepted the cookie, and with it cross-site request forgery. `BearerAuth` already defaulted to
`cookie_name = nothing`.

The helper now matches `BearerAuth`. It reads the header only, unless you pass a `cookie_name`:

| Call | Before | After |
|---|---|---|
| `extract_auth_token(req)` with a bearer header | the header token | the header token |
| `extract_auth_token(req)` with only the `auth_token` cookie | the cookie token | **`nothing`** |
| `extract_auth_token(req; cookie_name = "auth_token")` | header, then cookie | header, then cookie |

`set_auth_cookie!`, `clear_auth_cookie!` and `DEFAULT_AUTH_COOKIE_NAME` are unchanged.
`CookieAuthMiddleware` does not use this helper and is unchanged.

### How to find the calls to migrate

```bash
grep -rn 'extract_auth_token(' --include=*.jl .
```

A call that passes no `cookie_name` and serves browser clients authenticated only by the
`auth_token` cookie needs the edit below. A call that already passes `cookie_name` is unaffected,
and so is one that passes `cookie_name = nothing`.

### Migrate your app

```julia
# ✗ before — the cookie fallback was implicit
token = Nitro.Auth.extract_auth_token(req)

# ✓ after — opt in, and protect state-changing routes from CSRF
token = Nitro.Auth.extract_auth_token(req; cookie_name = "auth_token")
```

If the route is meant to be bearer-only, change nothing: the new default is the fix. If it does
take the cookie, put `CSRFMiddleware` in front of its state-changing methods.
