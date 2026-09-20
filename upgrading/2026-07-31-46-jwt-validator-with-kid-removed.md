## `jwt_validator(...; with_kid=...)` is now a construction-time `ArgumentError` (#46)

- **Version**: 0.1.0
- **Nitro ref**: #46; `src/Auth/`
- **Recorded**: 2026-07-31
- **Severity**: **breaking (removed kwarg)** — part of the `0.1.x` claim-based identity wave.

### What changed

`with_kid` existed to opt into surfacing the token's key id. The kid now always flows through the
`Principal` (`req.user.kid`, populated only when the key id was *verified* against a keyset), so the
kwarg is redundant and is rejected at construction time rather than silently ignored. Passing it
throws an `ArgumentError` when the validator is built — at bootstrap, not per-request.

Note the tightened trust rule that comes with it: only a keyset-verified kid is exposed. A `kid`
header on a single-secret token is never trusted and leaves `req.user.kid` unset.

### How to find the calls to migrate

```bash
rg -n 'with_kid' <app>/src
```

### Migrate your app

```julia
# ✗ before
validator = jwt_validator(keyset = ks, with_kid = true)

# ✓ after — drop the kwarg; read the verified kid off the Principal
validator = jwt_validator(keyset = ks)

# in a handler or guard:
signing_key = req.user.kid          # nothing unless keyset-verified

# to authorize on it, prefer the declarative guard over a manual check
path("/admin", admin_handler, middleware = [kid_required(["ops-2026"])])
```
