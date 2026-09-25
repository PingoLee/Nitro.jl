## `AbstractSessionStore` — a new required `update_session!`, and a loaded session is written back update-only (#318)

- **Version**: Unreleased
- **Nitro ref**: [#318](https://github.com/PingoLee/Nitro.jl/issues/318) ; `src/types.jl`,
  `src/middleware/session_middleware.jl`, `ext/NitroPormGExt.jl`
- **Recorded**: 2026-09-25
- **Severity**: **breaking** for a custom session store, which must add one method.
  **Behavior change (auth)** for every app using `SessionMiddleware`: a write to a session that
  was deleted mid-request is now dropped.

### What changed

Both stores upserted. So if a slow request was still running when a concurrent request logged its
session out, the slow request brought the session back:

1. Request A carries session `S` (`user_id = 42`) and writes to it, for example a flash message
   after an upload.
2. Request B logs out with `empty!(getsession(req))` + `regenerate_session!`, or `rotate_on_auth`
   fires. `S` is deleted and B returns a new id.
3. A finishes, re-creates `S` with `user_id = 42`, and its response sets the `S` cookie again.

The browser was logged back in, and a stolen `S` survived the logout meant to kill it.

`SessionMiddleware` now writes a session the request **loaded** with the new
`update_session!(store, id, data; ttl) -> Bool`. It writes only if an unexpired row still exists.
When it returns `false` the write is dropped and the cookie is not re-set. That is Django's
`UpdateError` → `SessionInterrupted`. An id minted during the request, for a new visitor or by
`regenerate_session!`, is still written with `set_session!`.

`update_session!` is a **required** part of the `AbstractSessionStore` contract, next to
`Base.get`, `set_session!` and `delete_session!`. `MemoryStore` and `PormGSessionStore` implement
it. A custom store that does not now fails with `StoreInterfaceError` on the first write-back of
an existing session, and `missing_session_methods` lists `:update_session!`.

Session values are also isolated now. `MemoryStore` deep-copies on write and on read, and so does
`SessionMiddleware`'s load, so no two requests share a nested vector or dict. A shallow copy used to
let every concurrent request of one session mutate the same `cart` vector: lost appends,
`ConcurrencyViolationError`, and a corrupted nested `Dict`. No code has to change for this. The
only visible difference: mutating a value you got from `get_session`, or one you already handed to
`set_session!`, no longer changes what the store holds. That aliasing was the bug.

### How to find the calls to migrate

Every custom session store:

```bash
grep -rnE '<:\s*(Nitro\.)?(Core\.)?(Types\.)?AbstractSessionStore' --include=*.jl .
```

Or ask the store itself, in a test:

```julia
@test isempty(Nitro.Core.Types.missing_session_methods(MySessionStore))
```

### Migrate your app

Add `update_session!` to each custom store. Do the existence check and the write in **one**
atomic step: an `UPDATE … WHERE` in SQL, or one lock hold in memory. A read followed by a separate
write re-opens the race this entry closes.

```julia
# ✗ before — the store implemented get / set_session! / delete_session! only
struct RedisSessionStore <: AbstractSessionStore{String, Dict{String,Any}}
    conn::RedisConnection
end

# ✓ after — also update_session!: write only if the key still exists
import Nitro.Core.Types: update_session!

function update_session!(s::RedisSessionStore, id::String, data::Dict{String,Any}; ttl::Int = 3600)
    # SET … XX writes only when the key exists, atomically; the EX gives the fresh expiry
    reply = execute(s.conn, ["SET", "session:" * id, JSON.json(data), "EX", string(ttl), "XX"])
    return reply == "OK"
end
```

Return `false` only when the session is gone or expired. A store failure must **throw**, like
`set_session!` does. `false` tells the middleware the session was logged out, and it drops the write.
