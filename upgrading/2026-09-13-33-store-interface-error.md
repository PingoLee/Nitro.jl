## Store contracts raise `StoreInterfaceError`, and session cleanup is explicitly optional (#33)

- **Version**: Unreleased
- **Nitro ref**: #33; `src/errors.jl`, `src/types.jl`, `src/cookies.jl`, `src/Workers/registry.jl`,
  `src/exts.jl`, `ext/NitroPormGExt.jl`, `docs/src/tutorial/sessions_and_auth.md`
- **Recorded**: 2026-09-13
- **Severity**: **behavior, and it fails LOUDLY** where it fails at all. An app only has to act if
  it implements its own `AbstractWorkerStore` / `AbstractSessionStore`, or catches `MethodError`
  around store calls. One change goes the *other* way and is silent — see the third bullet.

### What changed

Both store contracts were declared as bare stubs with no fallback and no docstring, so an
incomplete backend failed with an opaque `MethodError` raised from deep inside request or task
handling. `AbstractSessionStore` did not even declare `Base.get`, which it requires. Both contracts
are now data — `WORKER_STORE_INTERFACE` and `SESSION_STORE_INTERFACE` — with generated fallbacks
and a conformance helper reading the same rows.

Four things a consuming app can observe:

- **A missing required method now raises `StoreInterfaceError`, not `MethodError`**, naming the
  method and your store type. Code that catches `MethodError` around store calls to detect an
  unimplemented backend must catch `Nitro.Core.Errors.StoreInterfaceError` instead. (A *caller*
  mistake — wrong argument types against a store that does implement the method — still raises
  `MethodError`, carrying the real arguments.)
- **`prunesessions!` no longer swallows a `MethodError` raised inside a store's own
  `cleanup_expired_sessions!` body.** It used to catch any `MethodError` whose `.f` was that
  function, which discarded genuine bugs in a conforming store's cleanup. Those now propagate — and
  `prunesessions!` runs on the request path, so a store whose cleanup was quietly broken will start
  surfacing it.
- **`cleanup_expired_sessions!` gained a no-op default and is now explicitly optional.** This is the
  one change that is silent and goes the other way: a custom session store that did *not* implement
  it previously raised inside `prunesessions!`'s rescue and returned `nothing`; it now returns
  `nothing` without raising at all. Behaviour is unchanged, but `missing_session_methods` will never
  report it, so do not read "conforming" as "prunes".
- **The abstract types now carry fallback methods**, so a third-party store sees a different
  exception on a wrong-argument call than it did.

`pormg_nitro_worker` and `pormg_nitro_session` also lost their duplicate docstrings on the concrete
methods; `?pormg_nitro_worker` now resolves to one entry instead of two conflicting ones. Nothing to
migrate.

### How to find the calls to migrate

```bash
# Custom backends of either contract.
grep -rn "<: AbstractWorkerStore\|<: AbstractSessionStore" --include=*.jl .

# Code that treats a MethodError as "this store did not implement it".
grep -rn "MethodError" --include=*.jl .
```

```julia
using Nitro.Workers: missing_store_methods
using Nitro.Types: missing_session_methods

missing_store_methods(MyWorkerStore)      # empty means conforming
missing_session_methods(MySessionStore)   # required methods only; cleanup is optional
```

### Before → after

```julia
# BEFORE — detecting an unimplemented backend by exception type
try
    cleanup_expired_sessions!(store)
catch e
    e isa MethodError || rethrow()
    # ...treat as "not implemented"
end

# AFTER — ask the type directly, before anything runs
using Nitro.Types: missing_session_methods
isempty(missing_session_methods(typeof(store))) || error("store is incomplete")

# AFTER — and if you really are catching the not-implemented case at a call site:
using Nitro.Core.Errors: StoreInterfaceError
try
    set_session!(store, id, data; ttl = 60)
catch e
    e isa StoreInterfaceError || rethrow()
    # ...
end
```
