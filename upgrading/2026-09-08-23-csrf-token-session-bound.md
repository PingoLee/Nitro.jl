## CSRF tokens are bound to the session and the cookie is renamed `__Host-csrf_token` (#23)

- **Version**: 0.3.0
- **Nitro ref**: #23; `src/middleware/csrf_middleware.jl`, `docs/src/tutorial/sessions_and_auth.md`
- **Recorded**: 2026-09-08
- **Severity**: **breaking (pipeline order, cookie name, token format)** — a security fix; part of
  the `0.1.x` pre-publish wave.

### What changed

`CSRFMiddleware` signed its token with an HMAC over the random token value alone, so the signature
proved only that *Nitro* had minted the token — not that it had minted it for the client
presenting it. Because the cookie is deliberately not `httponly`, an attacker could read their own
valid token and, given any way to write cookies for your domain (a sibling subdomain, a MITM on a
plain-HTTP sibling origin), plant it as the victim's and forge a cross-site mutation that
validated. Protection degraded to an *unsigned* double-submit.

Three consequences for a consuming app:

1. **The HMAC now covers `req.context[:session_id]` as well as the token.** `SessionMiddleware`
   must therefore run **outside** `CSRFMiddleware`. If no session id is present the middleware
   **fails closed** — it issues no cookie and rejects every unsafe request with `403`, after one
   warning naming the ordering rule. There is no unbound fallback.
2. **The default cookie name is now `__Host-csrf_token`** (was `csrf_token`). Any SPA code reading
   the cookie by name must be updated. `CSRFMiddleware` and `issue_csrf_token!` now throw an
   `ArgumentError` at construction if a `__Host-`/`__Secure-` name is paired with a config
   browsers would reject (`secure=false`, a `domain`, or `path != "/"`), instead of emitting a
   cookie every browser silently discards.
3. **`issue_csrf_token!` takes a required `binding` keyword.** Calling it without one now throws
   `UndefKeywordError` rather than minting a quietly unbound token.

Every token already in a browser stops validating. That self-heals without an app change: the
middleware now re-issues whenever the presented cookie would not verify under the current session,
rather than only when the cookie is absent. Three paths cover it — the next safe request, a handler
that calls `regenerate_session!` (which gets a fresh cookie in the same response), and a rejected
mutation, which is refused with `403` *and* handed a replacement bound to the requester's own
session — so a `rotate_on_auth` login cannot lock a POST-only SPA out. That last path relies on the
default cookie configuration (`__Host-` plus `SameSite=Lax`) to keep it from being used to churn
another user's token; if you opt out of both, see the note in
[Sessions & Auth](https://pingolee.github.io/Nitro.jl/dev/tutorial/sessions_and_auth/).

### How to find the calls to migrate

```bash
rg -n 'CSRFMiddleware|issue_csrf_token!' <app>/src <app>/test   # pipeline order, cookie config
rg -n 'csrf_token' <app>/frontend <app>/src <app>/static        # JS reading the cookie by name
```

Every hit on the first grep needs a `SessionMiddleware` outside it; every hit on the second needs
the `__Host-` prefix, unless you opt back out of it (see the plain-HTTP form below).

### Migrate your app

```julia
# ✗ before — CSRF alone; the token was bound to nothing
serve(urlpatterns, middleware=[
    CSRFMiddleware(ENV["CSRF_SECRET"]),
])

# ✓ after — SessionMiddleware OUTSIDE; the token is bound to its session id
serve(urlpatterns, middleware=[
    SessionMiddleware(),
    CSRFMiddleware(ENV["CSRF_SECRET"]),
])

# ✗ before — a __Host- cookie cannot be Secure=false; this now throws at construction
CSRFMiddleware(secret; config=CookieConfig(httponly=false, secure=false, samesite="Lax", path="/"))

# ✓ after — serving over plain HTTP in development? drop the prefix explicitly
CSRFMiddleware(secret;
    cookie_name = "csrf_token",
    config = CookieConfig(httponly=false, secure=false, samesite="Lax", path="/"))

# ✗ before — minting a token by hand produced an unbound one
issue_csrf_token!(res, secret)

# ✓ after — `binding` is required; pass the session id the request is carrying
issue_csrf_token!(res, secret; binding = req.context[:session_id])
```

```js
// ✗ before
document.cookie.match(/csrf_token=([^;]+)/)[1]
// ✓ after
document.cookie.match(/__Host-csrf_token=([^;]+)/)[1]
```
