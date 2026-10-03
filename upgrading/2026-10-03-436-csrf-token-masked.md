## `csrf_token!` — the CSRF token handed to a handler is masked per call (#436)

- **Version**: Unreleased
- **Nitro ref**: [#436](https://github.com/PingoLee/Nitro.jl/issues/436) ;
  `src/middleware/csrf_middleware.jl`
- **Recorded**: 2026-10-03
- **Severity**: **behavior change.** No call stops compiling, and every token a client sends back
  still verifies. Code that compares the token with the cookie, compares two tokens, or checks
  the token's length or format has to change.

### What changed

Since #431 the endorsed way to get the CSRF token is `csrf_token!(req)`, and the docs put it in
HTML forms and SPA JSON. Every body therefore carried the **same** token for the cookie's whole
lifetime. Behind a proxy that compresses responses (the Caddy and nginx setups in
`docs/src/tutorial/reverse_proxy.md` both do), a fixed secret in a body next to reflected input
is the BREACH condition: the attacker recovers the secret from the compressed length.

Every value handed out is now `base64url(mask ‖ (mask ⊕ raw))` under a fresh random mask, the
one-time pad Django, Rails and Spring Security 6 use. Validation unmasks before comparing. The
cookie is unchanged and keeps the raw token.

| | Before | After |
|---|---|---|
| `csrf_token!(req)` | the raw token (43 chars), the same on every call | the token masked (86 chars), different on every call |
| `req.context[:csrf_token]` | the raw token | the token masked (a new mask per request) |
| `issue_csrf_token!(res, secret; binding)` returns | the raw token | the token masked |
| The CSRF cookie | `<raw>.<signature>` | unchanged |
| Accepted in `X-CSRF-Token` / `_csrf` | the raw token, or the whole cookie value | the masked token, the raw token, or the whole cookie value |

A single-page app that reads the raw token from `document.cookie` (the part before the first `.`)
keeps working: the raw form is still accepted. It was never in a response body, so accepting it
reopens nothing.

### How to find the calls to migrate

```bash
# code that reads the token: compare it through the middleware, not with `==`
grep -rn 'csrf_token!\|:csrf_token\]\|issue_csrf_token!' --include=*.jl .
# tests that compare the returned token with the cookie's raw half, or pin its length
grep -rnE 'csrf_token!.*==|==.*csrf_token!|split\([^)]*csrf[^)]*\.' --include=*.jl test/
# front-end code that validates the token's shape (e.g. a 43-character check)
grep -rn 'csrf' --include=*.js --include=*.ts --include=*.vue --include=*.jsx --include=*.tsx .
```

Forms and SPAs that only embed the token and echo it back need no change.

### Migrate your app

```julia
# ✗ before: the token equalled the cookie's raw half, and two calls returned the same string
token = csrf_token!(req)
@test token == split(cookie, '.')[1]
@test csrf_token!(req) == token

# ✓ after: the token is masked per call. Assert what matters: the client can use it.
token = csrf_token!(req)
res = app(HTTP.Request("POST", "/form", ["X-CSRF-Token" => token, "Cookie" => cookies]))
@test res.status == 200
```

An app that stored `csrf_token!(req)` to check it later should not: the check is the
middleware's, and a stored copy will not equal the next one handed out.

See *Server-rendered forms* in `docs/src/tutorial/sessions_and_auth.md`.
