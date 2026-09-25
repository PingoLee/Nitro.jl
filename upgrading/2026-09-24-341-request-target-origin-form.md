## Request targets — `//` in the path is a `400`, and absolute-form reaches middleware as a path (#341)

- **Version**: Unreleased
- **Nitro ref**: [#341](https://github.com/PingoLee/Nitro.jl/issues/341) ;
  `src/core/framework_middleware.jl`, `src/core/pipeline.jl`
- **Recorded**: 2026-09-24
- **Severity**: **behavior change.** It affects clients that send a path with an empty segment,
  and global middleware that reads `req.target` on an absolute-form request. Every app is covered,
  with or without a `prefix`.

### What changed

HTTP.jl's router drops empty path segments and routes an absolute-form target by the path after
its authority. Global middleware runs before the route is chosen, and it read `req.target` as the
client wrote it. So a global gate testing `startswith(req.target, "/admin")` let all of these
through to `/admin/users`:

| Request-target | Before | After |
|---|---|---|
| `//admin/users` | served by `/admin/users`; gate saw `//admin/users` | `400`, before any middleware |
| `/admin//users` | served by `/admin/users` | `400` |
| `http://x/admin/users` | served; gate saw `http://x/admin/users` | served; gate sees `/admin/users` |
| `http://x/api/users`, with `prefix = "/api"` | `404` | served; middleware sees `/users` |
| `http://x?y=/admin` | served by `/admin` | served by `/` |
| `http://x#/admin` | served by `/admin` | `404` (the fragment stays in the path) |
| `/admin/users/`, `/a?x=//y` | served | unchanged |

A new framework layer runs on every request before the prefix strip and before any of your
middleware:

- **An empty segment in the path is refused with `400 Bad Request`.** Only the path counts, up to
  the first `?`, so `//` inside a query string is fine, and so is a single trailing `/`.
- **An absolute-form target is reduced to origin-form.** The scheme and authority are dropped,
  and the path and query are kept. RFC 9112 §3.2.2 requires a server to accept this form; nothing
  in Nitro reads the authority. The `Host` header is left as the client sent it.
- `OPTIONS *` is untouched. `internalrequest` with a target that has no leading `/` gets one, which
  is how the router already read it.

The practical break is on the client side. A client that builds URLs by concatenation, such as
`base * "/" * path` with a `base` ending in `/`, used to be served, and now gets `400`.

### How to find the calls to migrate

Look for clients, proxies and tests that produce a doubled slash, and for middleware that took
the scheme and authority off `req.target` itself. That middleware is now dead code:

```bash
# a path joined onto a base URL: check the base cannot end in '/'
grep -rnE '\* *"/' --include=*.jl .
# a literal doubled slash that is not a scheme
grep -rnE '"[^"]*//[^"]*"' --include=*.jl . | grep -vE '[a-z]+://'
# middleware reading the target
grep -rn 'req.target' --include=*.jl .
```

The built-in access log does not show these requests as `//` paths. It reads a leading `//` as an
authority and logs only what follows, so `GET //users/42` is logged as a `400` for `/42`. An
`AccessLog` in your own middleware list never sees them, because they are refused before it runs.

A URL gate is now sound for the literal segments of a route, and no further. A file below a
static or SPA mount is looked up by its percent-decoded path after middleware runs, so gate the
mount's root rather than a directory inside it, or put the protected files in their own mount.
Since #351 that is no longer needed: see the entry on the canonical request path.

### Migrate your app

```julia
# ✗ before: joined into "//users/42" when `base` ends in '/', and was served
HTTP.get(base * "/users/42")
# ✓ after
HTTP.get(rstrip(base, '/') * "/users/42")

# ✗ before: parsing the target so an absolute-form request could not slip past the gate
is_admin(req) = startswith(HTTP.URI(req.target).path, "/admin/")
# ✓ after: global middleware always gets origin-form, and never a `//` path
is_admin(req) = startswith(req.target, "/admin/")
```
