## `jwt_validator` returns a `Principal`, not the raw claims object (#46)

- **Version**: 0.1.0
- **Nitro ref**: #46, #4; `src/Auth/`, `src/middleware/`, `docs/src/tutorial/authentication.md`
- **Recorded**: 2026-07-31
- **Severity**: **breaking (return type)** — part of the `0.1.x` claim-based identity wave.

### What changed

`jwt_validator` used without a `user_validator` set `req.user` to the decoded claims object, so apps
reached into it with property sugar (`req.user.sub`) and sometimes mutated it. It now yields a
`Principal`: an immutable, dict-like wrapper over the *verified* claims with typed fields `id`
(normalized identity), `kid` (keyset-verified key id) and `source` (`:claim` / `:kid`).

Dict-style **reads** are unchanged — `user["sub"]`, `get`, `haskey`, iteration, `==`, and the JSON
serialization (which is exactly the claims object) all behave as before. Only property access and
mutation break.

### How to find the calls to migrate

```bash
rg -n 'user\.[a-z_]+' <app>/src        # property sugar on req.user
rg -n 'req\.user\[[^]]+\]\s*='  <app>/src   # mutation of req.user
```

`.id`, `.claims`, `.kid` and `.source` are the only valid properties; every other `req.user.<name>`
is a claim read that must become an index.

### Migrate your app

```julia
# ✗ before — property sugar over the claims object
subject = req.user.sub
email   = req.user.email

# ✓ after — index the Principal
subject = req.user["sub"]
email   = req.user["email"]
# or use the normalized identity field
subject = req.user.id

# ✗ before — mutating the claims in place
req.user["tenant"] = tenant_id

# ✓ after — the Principal is immutable; build your own user object in a
# user_validator, or copy out of it
u = Dict(req.user)
u["tenant"] = tenant_id
```
