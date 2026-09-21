## `set_auth_cookie!` — `ttl` is now a required keyword, and `DEFAULT_AUTH_COOKIE_TTL` is gone

- **Version**: Unreleased
- **Nitro ref**: [#232](https://github.com/PingoLee/Nitro.jl/issues/232) ; `src/Auth/cookies.jl`
- **Recorded**: 2026-09-21
- **Severity**: **breaking** — every existing `set_auth_cookie!` call that relied on the default
  stops compiling, with an `UndefKeywordError` at the call site. It fails loudly and at the first
  call, which is the point: there is no correct value this helper could have substituted.

### What changed

`set_auth_cookie!` used to default `ttl` to `DEFAULT_AUTH_COOKIE_TTL = 24 * 60 * 60`. The tokens it
carries are bounded by `DEFAULT_JWT_MAX_AGE_SECONDS = 15 * 60`, either through their own `exp` or
through `decode_jwt`'s `iat + exp_timeout` fallback. The two defaults disagreed by a factor of 96.

| | before | after |
|---|---|---|
| `ttl` | keyword, default `86400` | **required** keyword, no default |
| `DEFAULT_AUTH_COOKIE_TTL` | `const` in `src/Auth/cookies.jl` | **removed** |

`DEFAULT_AUTH_COOKIE_NAME`, `clear_auth_cookie!` and `extract_auth_token` are unchanged.

### Why it had to break rather than be re-defaulted

Aligning the two constants was the smaller diff and the wrong fix: it keeps a guess, and the guess
is wrong for every app that mints with its own `expires_in`. `set_auth_cookie!` receives an opaque
string and never decodes it, so it cannot know the credential's lifetime. Only the caller that just
minted the token knows, so the API now makes the caller say.

The defect this closes is a usability and diagnosability one, not an authorization one — the stale
cookie was never accepted, because the token inside it still failed validation. What it produced
was 23h45m of requests arriving *with* an auth cookie and coming back `401`, which is the shape
that reads as a server fault rather than an expired session, and nothing in the framework cleared
the cookie: `clear_auth_cookie!` is only ever called by the application, and neither `BearerAuth`
nor `CookieAuthMiddleware` touches the cookie on a validation failure.

### How to find the calls to migrate

```bash
# Every call site. Any one WITHOUT a `ttl =` is a call that was taking the old 24h default.
rg -n 'set_auth_cookie!' <app>/src

# The value to pass is whatever you handed `encode_jwt` as `expires_in`, so find that too.
rg -n 'encode_jwt' <app>/src
```

Anything referencing the removed constant by name — it is unexported, so this is rare:

```bash
rg -n 'DEFAULT_AUTH_COOKIE_TTL' <app>
```

### Migrate your app

```julia
# ✗ before -- cookie lived 24h, token died at 15 min
token = encode_jwt(claims, secret; expires_in = 900)
set_auth_cookie!(res, token)

# ✓ after -- one lifetime, stated once, by the only code that knows it
token = encode_jwt(claims, secret; expires_in = 900)
set_auth_cookie!(res, token; ttl = 900)
```

**Re-setting a token minted in an earlier request** — a refresh flow, or a re-login that reuses
a live token — is the one case where `expires_in` is the wrong number. `Max-Age` counts from
when the browser receives the cookie; `exp` counts from `iat`. Passing the original
`expires_in` overshoots by however long the token has already lived, which is a smaller
instance of the very defect this entry closes. Pass what is left:

```julia
# ✓ re-setting an existing token
set_auth_cookie!(res, token; ttl = claims["exp"] - trunc(Int, time()))
```

If you never passed `expires_in`, your tokens carry no `exp` and are bounded by `decode_jwt`'s
`exp_timeout` fallback instead. Pass that same bound — `900` unless you overrode it:

```julia
# ✗ before
set_auth_cookie!(res, token)

# ✓ after -- matches the `exp_timeout` default the token is actually validated against
set_auth_cookie!(res, token; ttl = 900)
```

Do **not** reach for `24 * 60 * 60` to keep the old behavior. It restores the defect: the browser
holds a credential your own validator rejects, and the resulting `401`s carry an auth cookie.
