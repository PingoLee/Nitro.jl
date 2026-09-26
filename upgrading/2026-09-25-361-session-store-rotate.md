## `AbstractSessionStore` — a new required `rotate_session!`, and `regenerate_session!` may return `nothing` (#361)

- **Version**: Unreleased
- **Nitro ref**: [#361](https://github.com/PingoLee/Nitro.jl/issues/361) ; `src/types.jl`,
  `src/cookies.jl`, `src/middleware/session_middleware.jl`, `ext/NitroPormGExt.jl`
- **Recorded**: 2026-09-25
- **Severity**: **breaking** for a custom session store, which must add one method.
  **Behavior change (auth)** for every app using `regenerate_session!` or `rotate_on_auth`: a
  rotation of a session that was logged out mid-request is now dropped.

### What changed

`regenerate_session!` wrote the request's session data under a new id with `set_session!`, then
deleted the old id, without checking that the old id still existed. So a request that rotated after
a concurrent logout brought the logged-out session back under a fresh id:

1. Request A loads session `S` (`user_id = 42`).
2. Request B logs out: `empty!(getsession(req))` + `regenerate_session!`. `S` is deleted.
3. A rotates: an explicit `regenerate_session!` (recommended on any privilege change), or
   `rotate_on_auth` on a user switch.
4. A copied its stale `user_id = 42` into a new id, and `SessionMiddleware` set that new cookie.

The browser was logged back in as the user who had just logged out. The #318 entry closed this for
the plain write-back; this is the same resurrection through the rotation path.

Rotation now goes through a new store method,
`rotate_session!(store, old_id, new_id, data; ttl) -> Bool`, which moves the session **only if**
`old_id` still exists and has not expired, as one atomic step. When it returns `false`:

- `regenerate_session!` returns **`nothing`** instead of a new id, and leaves
  `req.context[:session_id]` unchanged;
- `SessionMiddleware` drops the request's write and sets no cookie, exactly as #318 does for a
  write-back.

`rotate_session!` is a **required** part of the `AbstractSessionStore` contract, next to
`Base.get`, `set_session!`, `update_session!` and `delete_session!`. `MemoryStore` and
`PormGSessionStore` implement it. A custom store that does not now fails with `StoreInterfaceError`
on its first rotation, and `missing_session_methods` lists `:rotate_session!`. It ships in the same
release train as #318's `update_session!`, so a custom store migrates once for both.

A session `SessionMiddleware` created during the request itself, never stored and never sent,
still rotates to a new id as before, with no store call. The middleware marks one with
`req.context[:session_new] = true`. Two edge cases outside that path behave differently now:

- `regenerate_session!` called **without** `SessionMiddleware`, on a `req.context[:session_id]`
  the store does not hold, used to create the session. It now returns `nothing` and leaves the
  id in place: an id the store does not hold is indistinguishable from a logged-out one. Store the
  session first, or set `req.context[:session_new] = true` for an id minted in that request.
- A handler that swaps `req.context[:session_id]` for a fresh id by hand, on a session the request
  loaded, had that id upserted. It is now written update-only, so the write is dropped; only a
  session left empty is still written, as a fresh one (#362). Call `regenerate_session!` instead.

### How to find the calls to migrate

Every custom session store:

```bash
grep -rnE '<:\s*(Nitro\.)?(Core\.)?(Types\.)?AbstractSessionStore' --include=*.jl .
```

Or ask the store itself, in a test:

```julia
@test isempty(Nitro.Core.Types.missing_session_methods(MySessionStore))
```

And every call that uses `regenerate_session!`'s return value:

```bash
grep -rnE '=\s*(Nitro\.)?regenerate_session!\(' --include=*.jl .
```

### Migrate your app

Add `rotate_session!` to each custom store. Make the existence check and both writes **one**
atomic step. A check followed by separate writes re-opens the race this entry closes.

```julia
# ✗ before — the store implemented get / set_session! / update_session! / delete_session!
struct RedisSessionStore <: AbstractSessionStore{String, Dict{String,Any}}
    conn::RedisConnection
end

# ✓ after — also rotate_session!: move the session only if the old key still exists
import Nitro.Core.Types: rotate_session!

# A Lua script runs atomically in Redis: nothing can run between the check and the writes. The
# session is a hash (as in the #318 entry's `update_session!`), and RENAME moves the whole key,
# so every field but `data` -- such as the `created` instant #362 requires -- is carried over.
const ROTATE_SESSION = """
if redis.call('EXISTS', KEYS[1]) == 0 then return 0 end
redis.call('RENAME', KEYS[1], KEYS[2])
redis.call('HSET', KEYS[2], 'data', ARGV[1])
redis.call('EXPIRE', KEYS[2], ARGV[2])
return 1
"""

function rotate_session!(s::RedisSessionStore, old_id::String, new_id::String,
                         data::Dict{String,Any}; ttl::Int = 3600)
    moved = execute(s.conn, ["EVAL", ROTATE_SESSION, "2", "session:" * old_id,
                             "session:" * new_id, JSON.json(data), string(ttl)])
    return moved == 1
end
```

In SQL, a single `UPDATE … SET key = new WHERE key = old AND expires > now` is the simplest form
when your layer allows a key update. Otherwise, run a `DELETE … WHERE key = old AND expires > now`
first and `INSERT` the new row only when its row count is 1: that count decides between the
rotation and a concurrent logout.

Return `false` only when the old session is gone or expired. A store failure must **throw**:
`false` tells the caller the session was logged out, and it drops the rotation.

A caller that uses the return value handles `nothing`:

```julia
# ✗ before — assumed a String
new_id::String = regenerate_session!(req, store)

# ✓ after — `nothing` means the session was logged out while this request ran
new_id = regenerate_session!(req, store)
new_id === nothing && return Res.status(401)
```
