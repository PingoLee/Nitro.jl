## Route- and router-level middleware lists now run top-down, in the order written (#312)

- **Version**: Unreleased
- **Nitro ref**: [#312](https://github.com/PingoLee/Nitro.jl/issues/312) ; `src/routerhof.jl`,
  `src/core/pipeline.jl`
- **Recorded**: 2026-09-24
- **Severity**: **behaviour change.** It affects every `path(...; middleware = [...])` and
  `router(...; middleware = [...])` list with two or more entries. A one-entry list and the
  global `serve(middleware = [...])` list behave as before.

### What changed

The global list ran top-down: the first entry saw the request first. Route and router lists ran
**bottom-up**, because only the global list was reversed before the chain was built. So
`path("/x", h; middleware = [A, B])` ran `B`, then `A`.

The shape the docs teach inverted with it. `middleware = [BearerAuth(v), GuardMiddleware(...)]`
checked its guards **before** authenticating:

- `login_required` saw no user and redirected a valid token (302).
- `role_required` and the other claim guards saw no claims and refused a valid admin token (403).
- The guards decided on the session fallback instead of the token principal.

Every other pair inverted the same way. `[RateLimiter(...), BearerAuth(...)]` never counted a
failed authentication, `[ExtractIP(...), RateLimiter(...)]` limited on the proxy's address, and
`[SessionMiddleware(...), CSRFMiddleware(...)]` ran CSRF with no session.

Every list now runs top-down. The nesting is unchanged:

```
global middleware  →  router middleware  →  route middleware  →  handler
```

| List | Before | After |
|---|---|---|
| `serve(middleware = [A, B])` | A, B | A, B |
| `router(...; middleware = [R1, R2])` | R2, R1 | R1, R2 |
| `path(...; middleware = [A, B])` | B, A | A, B |
| router `[R1, R2]` + route `[A, B]` | R2, R1, B, A | R1, R2, A, B |

This shipped together with #313, which makes an auth validator that returns `false` a `401`.
With the auth layer now running first, `login_required` no longer stands between a predicate
validator's `false` and the handler.

### How to find the calls to migrate

List every `middleware =` keyword. That includes lists split across lines, lists bound to a
variable, and a router's per-route `api("/x"; middleware = [...])` call:

```bash
grep -rnE -A3 'middleware *= *[\[A-Za-z_]' --include=*.jl .
```

Skip the hits on `serve(` and `internalrequest(`, since the global list is unchanged, and skip
lists with a single entry. For each remaining hit, read the list top-down: that is now the order
it runs in. A list written in the
order you meant (auth before guards) needs no edit. It works now, where before it was wrong.

### Migrate your app

An app that flipped a list to get the old code to work must flip it back:

```julia
# ✗ before — reversed on purpose, so the guard ran after BearerAuth under the old fold
path("/admin", admin; middleware = [GuardMiddleware(role_required("admin")), BearerAuth(validator)])

# ✓ after — written in the order it runs
path("/admin", admin; middleware = [BearerAuth(validator), GuardMiddleware(role_required("admin"))])
```

A test that asserted the old bottom-up order (`route2 → route1`) was asserting the bug. Update it.
