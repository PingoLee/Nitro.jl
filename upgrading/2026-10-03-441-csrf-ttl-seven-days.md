## `CSRFMiddleware` — the CSRF cookie lasts seven days by default, not one hour (#441)

- **Version**: Unreleased
- **Nitro ref**: [#441](https://github.com/PingoLee/Nitro.jl/issues/441) ;
  `src/middleware/csrf_middleware.jl`
- **Recorded**: 2026-10-03
- **Severity**: **behavior change.** No call stops compiling, and no app has to change. The CSRF
  cookie a browser receives now carries `Max-Age=604800` instead of `Max-Age=3600`.

### What changed

The default `ttl` of `CSRFMiddleware` and `issue_csrf_token!` went from `3600` (one hour) to
`604800` (seven days). That is `SessionMiddleware`'s default `absolute_max_age`, so with default
settings the CSRF cookie no longer expires before the session it is bound to.

The one-hour cookie protected nothing the session binding (#23) does not already protect: a token
verifies only under the session it was minted for, so a cookie that outlives its session is
inert. What it did cost was a `403` for every single-page app idle for more than an hour, and for
every form left open that long, while their session was still alive. Django (one year), Rails (the
session's lifetime) and Spring Security (a browser-session cookie) all keep the token at least as
long as the session.

| Default | Before | After |
|---|---|---|
| `CSRFMiddleware(secret)` cookie `Max-Age` | `3600` | `604800` |
| `issue_csrf_token!(res, secret; binding)` cookie `Max-Age` | `3600` | `604800` |
| An explicit `ttl = N` | `N` | `N` (unchanged) |

### How to find the calls to migrate

```bash
# every CSRF layer; those without `ttl =` now issue a seven-day cookie
grep -rn 'CSRFMiddleware(\|issue_csrf_token!(' --include=*.jl .
# tests that assert the old cookie lifetime
grep -rn 'Max-Age=3600' --include=*.jl test/
```

Nothing has to change. Update a test that pins `Max-Age=3600` on the CSRF cookie. An app that
wants the old lifetime back passes it explicitly.

### Migrate your app

```julia
# ✗ before: a one-hour cookie by default
CSRFMiddleware(csrf_secret)

# ✓ after: the same call issues a seven-day cookie. To keep the old lifetime, say so:
CSRFMiddleware(csrf_secret; ttl = 3600)
```

If you raised `SessionMiddleware`'s `max_age` or `absolute_max_age` above seven days, raise `ttl`
to match. A single-page app should keep its retry on `403`: the token still dies with its session.

See *Single-page apps* in `docs/src/tutorial/sessions_and_auth.md`.
