## `SessionMiddleware` — the session cookie defaults to `__Host-nitro_session`

- **Version**: Unreleased
- **Nitro ref**: [#329](https://github.com/PingoLee/Nitro.jl/issues/329) ; `src/middleware/session_middleware.jl`, `src/cookies.jl`
- **Recorded**: 2026-09-24
- **Severity**: behavior change — the default session cookie is renamed, so every user is logged
  out once on deploy; an explicit `__Host-`/`__Secure-` `cookie_name` the attributes cannot carry
  is now an `ArgumentError`.

### What changed

The session cookie was always called `nitro_session`. An unprefixed cookie can be planted by a
sibling subdomain or over any plain-HTTP hop, so an attacker could set
`nitro_session=<a session they are logged into>; Path=/account` — sent first, so it won — and the
victim then acted inside the attacker's account (login CSRF / session swapping). Session fixation
and CSRF bypass were not possible (unknown ids are refused, CSRF tokens are session-bound).

`cookie_name` now defaults to the most protected name the cookie's own attributes allow:

| Attributes | Before | After |
|---|---|---|
| `secure=true`, `path="/"`, no `domain` (the default) | `nitro_session` | `__Host-nitro_session` |
| `secure=true` with a `domain` or another `path` | `nitro_session` | `__Secure-nitro_session` |
| `secure=false` | `nitro_session` | `nitro_session` |

An explicit `cookie_name` is kept as given. If it carries a `__Host-` or `__Secure-` prefix the
attributes break (`__Host-` needs `secure`, `Path=/` and no `Domain`; `__Secure-` needs `secure`),
`SessionMiddleware` throws an `ArgumentError` at construction, because browsers would silently drop
the cookie. `CSRFMiddleware` already applied the same check; the two now share it.

### How to find the calls to migrate

```bash
# Every SessionMiddleware without an explicit cookie_name changes name on upgrade.
grep -rnE 'SessionMiddleware\(' --include=*.jl .
# Anything outside Julia that names the old cookie: proxies, load balancers (sticky sessions),
# front-end code, monitoring, cookie-consent banners.
grep -rn 'nitro_session' .
```

### Migrate your app

```julia
# ✗ before — implicit `nitro_session`
SessionMiddleware(store = store)

# ✓ after — nothing to change for the protected default. Expect one logout per user on deploy,
#   and update anything outside Nitro that referred to `nitro_session` by name.
SessionMiddleware(store = store)                     # __Host-nitro_session

# To keep the old name (and the old exposure), say so explicitly:
SessionMiddleware(store = store, cookie_name = "nitro_session")
```
