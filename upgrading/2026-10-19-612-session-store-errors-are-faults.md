## A session store's exception reaches the caller as a value-free `SessionStoreFault` (#612)

- **Version**: 0.7.0
- **Nitro ref**: [#612](https://github.com/PingoLee/Nitro.jl/issues/612) ; `src/types.jl`, `src/cookies.jl`, `src/middleware/session_middleware.jl`, `src/errors.jl`
- **Recorded**: 2026-10-19
- **Severity**: behavior change. Nothing about status codes changes. Code that catches a session
  store's own exception type around `regenerate_session!` or `get_session` stops matching.

### What changed

Nitro hands the session store the session id, which is a bearer credential, and the session data.
Whatever the store threw used to reach the caller unchanged: its own error, a `MethodError` over the
call's arguments, or the `TypeError` of a `::Bool` assert holding the returned value. At the error
boundary, any of those could write the id or the data to the log.

These store calls now raise a `Nitro.Errors.SessionStoreFault` instead:

- `Base.get`, `set_session!`, `update_session!` and `rotate_session!`, made by `SessionMiddleware`,
  `regenerate_session!` and `get_session`.

So does a `Bool` contract method that returns anything else: `update_session!`, `rotate_session!`
or `session_store_full`.

The fault's message names the store method and the **type** of what it threw or returned, never a
value: ``the session store's `rotate_session!` threw an exception of type `PQConnectionError` ``.

Unaffected:

- Inside `SessionMiddleware`, a failing store was a `500` and still is.
- A `StoreInterfaceError` (a store that does not implement a required method) still propagates as
  itself.
- An `InterruptException`, `StackOverflowError` or `OutOfMemoryError` still propagates as itself.

### How to find the calls to migrate

Look for direct calls in handlers and services, including calls that span several lines:

```bash
grep -rn -B3 -A3 -E 'regenerate_session!\(|get_session\(' --include=*.jl .
```

A hit needs a change only when it sits inside a `try` whose `catch` tests the store's exception
type, or reads its message.

### Migrate your app

```julia
# ✗ before -- matched the store's own exception
try
    regenerate_session!(req, store)
catch e
    e isa LibPQ.Errors.PQConnectionError || rethrow()
    return Res.status(503)
end

# ✓ after -- the store's exception arrives as a SessionStoreFault
try
    regenerate_session!(req, store)
catch e
    e isa Nitro.Errors.SessionStoreFault || rethrow()
    return Res.status(503)
end
```

To see the store's original exception while you debug, call the store method directly in a test,
e.g. `rotate_session!(store, old_id, new_id, data; ttl = 60)`.
