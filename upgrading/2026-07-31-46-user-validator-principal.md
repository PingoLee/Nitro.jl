## `user_validator` receives the `Principal`; the tuple contract is `(user, principal)` (#46)

- **Version**: 0.1.0
- **Nitro ref**: #46; `src/Auth/`, `src/middleware/`
- **Recorded**: 2026-07-31
- **Severity**: **breaking (callback argument + context key)** — part of the `0.1.x` claim-based
  identity wave.

### What changed

A `user_validator` used to be handed the raw claims dict, and a validator returning a tuple returned
`(user, claims)`. It now receives the `Principal` — a dict-compatible superset of the old argument —
and the tuple contract is `(user, principal)`. Consequently `req.context[:auth_claims]` now holds
the `Principal` rather than a raw claims dict.

Because `Principal` supports the same dict reads, a validator that only *indexes* its argument keeps
working untouched. What breaks is a validator that treats the argument as a mutable `Dict`, calls
`Dict`-only methods on it, or annotates the parameter with `::Dict`.

### How to find the calls to migrate

```bash
rg -n 'user_validator' <app>/src
rg -n 'auth_claims' <app>/src
```

Then check each validator body for `::Dict` annotations, `setindex!`/`push!`/`delete!` on the
argument, and any downstream code that reads `req.context[:auth_claims]` expecting a plain dict.

### Migrate your app

```julia
# ✗ before — annotated and mutated as a Dict
function load_user(claims::Dict)
    claims["seen_at"] = now()
    return (fetch_user(claims["sub"]), claims)
end

# ✓ after — accept the Principal, copy before mutating, return (user, principal)
function load_user(principal)
    user = fetch_user(principal["sub"])   # or principal.id
    return (user, principal)
end

# ✗ before — downstream consumer assumed a dict
claims = req.context[:auth_claims]
claims["extra"] = 1

# ✓ after — it is a Principal; copy out if you need a mutable dict
principal = req.context[:auth_claims]
claims = Dict(principal)
claims["extra"] = 1
```
