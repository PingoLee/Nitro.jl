## `CSRFMiddleware` / `issue_csrf_token!` / `validate_csrf_token` — an empty secret is an `ArgumentError`

- **Version**: Unreleased
- **Nitro ref**: [#269](https://github.com/PingoLee/Nitro.jl/issues/269) ; `src/middleware/csrf_middleware.jl`, `src/crypto.jl`, `src/Auth/keyset.jl`
- **Recorded**: 2026-09-23
- **Severity**: behavior change — a CSRF secret that is empty, or that HMAC treats as empty,
  used to be accepted and signed every CSRF token under a key anyone knows. It is now refused
  loudly. No valid configuration changes which tokens verify.

### What changed

The JWT side of this class was closed in
[#264](2026-09-23-264-jwt-empty-string-secret.md); the CSRF middleware was not.
`CSRFMiddleware("")` — which is exactly what `get(ENV, "CSRF_SECRET", "")` produces when the
variable is unset — signed tokens with the empty HMAC key, so anyone able to plant the CSRF
cookie could mint a token that verified for a session id they knew.

The rule is HMAC's, not `isempty`'s, and is the same one the JWT secret is held to: HMAC-SHA256
zero-pads a short key, so `"\0"`, `"\0\0"`, and any run of NUL bytes up to 64 are the empty key
too. Every one of those is now refused:

| Call | Before | After |
|---|---|---|
| `CSRFMiddleware("")` | a middleware whose tokens anyone can sign | `ArgumentError`, at construction (app startup) |
| `issue_csrf_token!(res, ""; binding)` | a token anyone can sign | `ArgumentError` |
| `validate_csrf_token(req, "")` | `true` for a token signed with `""` | `ArgumentError` on every call — including the calls that used to return `false` early for a missing binding or cookie |

### How to find the calls to migrate

```bash
# An env var read with an empty-string default is the realistic trigger.
grep -rnE 'get\(ENV, *"[^"]*", *""\)' --include=*.jl .
# A literal empty secret passed directly (over-matches on purpose).
grep -rnE '(CSRFMiddleware|issue_csrf_token!|validate_csrf_token)\(.*""' --include=*.jl .
```

At runtime, the startup error reads `the CSRF secret is empty, or equivalent to the empty HMAC key`.

### Migrate your app

```julia
# ✗ before — an unset CSRF_SECRET silently becomes "", and "" signs tokens anyone can forge
CSRFMiddleware(get(ENV, "CSRF_SECRET", ""))

# ✓ after — read it with a `nothing` default and fail at startup when it is missing
csrf_secret = get(ENV, "CSRF_SECRET", nothing)
isnothing(csrf_secret) && error("CSRF_SECRET must be set")
CSRFMiddleware(csrf_secret)
```

A test suite that built the middleware with `""` for convenience needs a real (non-empty) test
secret.
