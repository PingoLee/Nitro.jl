## PormG stores — a Ctrl-C during a query now propagates as a bare `InterruptException`

- **Version**: Unreleased
- **Nitro ref**: #904 (follow-up to #254 and #646); `ext/NitroPormGExt.jl` (`_unrecoverable`,
  `_bare`, every catch around a PormG statement)
- **Recorded**: 2026-11-09
- **Severity**: **behavior change** — no API changes. It matters only when a Ctrl-C (or another
  `InterruptException`) lands while `PormGSessionStore` or `PormGWorkerStore` is running a query.

### What changed

PormG hands a Ctrl-C during a query back wrapped: a `PormG.DatabaseError` whose `cause` is the
`InterruptException`. The PormG stores' catches did not look inside that wrapper, so:

| call | before | now |
|---|---|---|
| `Base.get(::PormGSessionStore, …)` (every request with a session cookie) | read as "no session": the request went on signed out | raises `InterruptException` |
| `cleanup_expired_sessions!` / the `SessionMiddleware` prune | swallowed with a warning; the prune janitor kept ticking | raises `InterruptException`; the janitor stops with its usual Ctrl-C warning (#369) |
| session writes (`set_session!`, `update_session!`, `rotate_session!`, `delete_session!`) and the task store's reads, writes and listings | logged a "failed to …" warning, then raised the `PormG.DatabaseError` | raises a bare `InterruptException`, with no warning |
| the boot migrations that add a column | raised the `PormG.DatabaseError` | raises a bare `InterruptException` |

Every other database failure is handled exactly as before.

### How to find the calls to migrate

You are affected only if your code catches PormG's error type around a call into a Nitro store
and relied on it to catch an interrupt too:

```bash
grep -rnB2 -A4 "catch" src/ bin/ *.jl | grep -n "PormG\.\(DatabaseError\|StatementError\)"
```

Nothing to migrate otherwise.

### Migrate your app

```julia
# ✗ before: a Ctrl-C during the store call arrived as PormG's wrapper
try
    set_session!(store, sid, data; ttl = 3600)
catch e
    e isa PormG.DatabaseError && e.cause isa InterruptException && rethrow()
    handle_store_failure(e)
end

# ✓ after: it arrives bare, as from any other Julia call
try
    set_session!(store, sid, data; ttl = 3600)
catch e
    e isa InterruptException && rethrow()
    handle_store_failure(e)
end
```
