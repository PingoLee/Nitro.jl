## `CSRFMiddleware` — a bearer-only request skips the token check by default (#438)

- **Version**: Unreleased
- **Nitro ref**: [#438](https://github.com/PingoLee/Nitro.jl/issues/438) ;
  `src/middleware/csrf_middleware.jl`
- **Recorded**: 2026-10-03
- **Severity**: **behavior change.** No call stops compiling. An unsafe request that carries
  `Authorization: Bearer <token>` and no `Cookie` header used to get `403 Invalid CSRF token`; it
  now reaches the next layer.

### What changed

`CSRFMiddleware` gained `exempt_bearer::Bool = true`. With it on, an unsafe request (`POST`,
`PUT`, `PATCH`, `DELETE`, …) skips the token check when **both** of these hold:

- its `Authorization` header is `Bearer <token>`: the scheme in any case, one non-empty token;
- it carries **no `Cookie` header at all**.

CSRF exists because a browser attaches cookies to a cross-site request on its own. It never
attaches an `Authorization` header that way, so a request with a bearer header and no cookie has
nothing a forger could borrow. Any cookie keeps the check on, including one the middleware does
not recognise, so a request mixing a bearer header with a session cookie is still checked.

The exemption decides only whether a CSRF token is needed. It does not validate the bearer token:
`BearerAuth`, or your handler, still authenticates the request. A route that authenticates nothing
now accepts bearer-shaped requests without a token. A request with no cookie carries no session or
credential of anyone's, and borrowing those is what CSRF protects against.

The exception is authority that comes from **network position** rather than a credential: an
intranet-only route, or an IP allow-list built on `ExtractIP`. If your `Cors` also lets an
untrusted origin send an `Authorization` header (it has to be listed by name; `allowed_headers =
["*"]` does not cover it), a page in a victim's browser can reach such a route from inside the
victim's network with a bearer header and no cookie. Protect those routes with
`exempt_bearer = false`, or do not allow `Authorization` from untrusted origins.

| Request (unsafe method, no CSRF token) | Before | After |
|---|---|---|
| `Authorization: Bearer x`, no `Cookie` | `403` | passes the CSRF layer |
| `Authorization: Bearer x` + any `Cookie` | `403` | `403` (unchanged) |
| `Authorization: Basic …`, no `Cookie` | `403` | `403` (unchanged) |
| Cookie only | `403` | `403` (unchanged) |
| `CSRFMiddleware(secret; exempt_bearer = false)` | — | `403` for all of the above |

### How to find the calls to migrate

```bash
# every CSRF layer; those without `exempt_bearer =` now let bearer-only requests through
grep -rn 'CSRFMiddleware(' --include=*.jl .
# tests that expect a bearer request to be refused by CSRF
grep -rn 'Bearer' --include=*.jl test/ | grep -in 'csrf\|403'
```

Most apps need no change: this is what removes the `403` a global `CSRFMiddleware` gave every
bearer API client. Act only if you relied on CSRF to refuse bearer-only requests, for instance a
test asserting it, or an endpoint that authenticates nothing and leaned on the CSRF `403`.

### Migrate your app

```julia
# ✗ before: bearer-only POSTs were refused with 403 by the CSRF layer
CSRFMiddleware(csrf_secret)

# ✓ after: the same call lets them through to BearerAuth / your handler.
#   To keep refusing them, say so:
CSRFMiddleware(csrf_secret; exempt_bearer = false)
```

See *Bearer-token API clients* in `docs/src/tutorial/sessions_and_auth.md`.
