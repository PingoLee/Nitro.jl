## `SessionMiddleware` — sessions end 7 days after creation; `SessionPayload` gains `created` (#362)

- **Version**: Unreleased
- **Nitro ref**: [#362](https://github.com/PingoLee/Nitro.jl/issues/362) ; `src/types.jl`,
  `src/middleware/session_middleware.jl`, `ext/NitroPormGExt.jl`
- **Recorded**: 2026-09-25
- **Severity**: **Behavior change (auth)** for every app using `SessionMiddleware`: a session
  now ends 7 days after it was created, however active it is. **Breaking** for a custom session
  store, which must record and return each session's creation instant. **Schema change** for the
  PormG `nitro_session` table: `pormg_nitro_session()` migrates it on boot.

### What changed

A session had no absolute lifetime. Every write-back moved its expiry to `max_age` from now, so a
session that kept being used never expired, and a stolen session id stayed valid for as long as
the thief kept using it.

`SessionMiddleware` has a new keyword, `absolute_max_age::Nullable{Int}`, in seconds, defaulting
to **604800 (7 days)**:

- A session older than that is treated as absent when it is loaded, like an expired one: the
  visitor gets a fresh session id and signs in again, whatever the sliding expiry says.
- Every write caps the stored expiry, and the cookie's `Max-Age`, at the absolute deadline. So
  readers that bypass the middleware (`get_session`, the `Session{T}` extractor,
  `Auth.session_user_validator`) enforce the cap through the expiry check they already make.
- Rotation does **not** restart the clock. `regenerate_session!` and `rotate_on_auth` move the
  session to a new id and keep its creation instant.
- `absolute_max_age = nothing` switches the cap off, which is the old behavior and Django's
  default. A zero or negative value is an `ArgumentError` at construction.

To measure a session's age, every store now records when the session was created:

- `SessionPayload` has a third, required field: `SessionPayload(data, expires, created)`. There is
  no two-argument form. A store that could not report `created` would switch the cap off without a
  word, so the old call fails with a `MethodError` rather than being accepted.
- `set_session!` sets `created` to now. `update_session!` must keep it, and `rotate_session!`
  (#361) must carry it to the new id.
- A store whose `Base.get` returns bare data instead of a `SessionPayload` cannot say when a
  session was created. Under a cap, `SessionMiddleware` now treats such a session as absent and
  logs one warning.
- `MemoryStore` does all of this already. `PormGSessionStore` stores it in a new `created_at`
  column.

### How to find the calls to migrate

Every `SessionMiddleware`, to decide whether the 7-day default suits it:

```bash
grep -rn 'SessionMiddleware(' --include=*.jl .
```

Every custom session store that builds a payload:

```bash
grep -rnE 'SessionPayload\(' --include=*.jl .
```

Every `PormGSessionStore` built directly rather than through `pormg_nitro_session()`, which skips
the boot migration:

```bash
grep -rn 'PormGSessionStore(' --include=*.jl .
```

### Migrate your app

Nothing to change if 7 days suits you. Otherwise say what you want:

```julia
# ✗ before — a session in use never ended
SessionMiddleware(store = store, max_age = 3600)

# ✓ after — pick a cap, or keep the old behavior explicitly
SessionMiddleware(store = store, max_age = 3600)                              # 7-day cap (default)
SessionMiddleware(store = store, max_age = 3600, absolute_max_age = 12 * 3600) # 12 h cap
SessionMiddleware(store = store, max_age = 3600, absolute_max_age = nothing)   # no cap
```

A custom store records `created` once and hands it back. Keep it apart from the data, for example
as a Redis hash field or a SQL column, so that `update_session!` never overwrites it:

```julia
# ✗ before
function Base.get(s::RedisSessionStore, id::String, default)
    fields = execute(s.conn, ["HGETALL", "session:" * id])
    isempty(fields) && return default
    return SessionPayload(JSON.parse(fields["data"]), expires_of(s, id))
end

# ✓ after — `created` is written by set_session! only, kept by update, carried by rotate
function Base.get(s::RedisSessionStore, id::String, default)
    fields = execute(s.conn, ["HGETALL", "session:" * id])
    isempty(fields) && return default
    return SessionPayload(JSON.parse(fields["data"]), expires_of(s, id),
                          DateTime(fields["created"]))
end
```

A `nitro_session` table is migrated by `pormg_nitro_session()` on its next boot. It adds
`created_at` and stamps the rows already there with the upgrade instant, so live sessions get a
full 7 days from the upgrade instead of ending at once. A store constructed directly needs the
column added by hand. Use the instant you migrate, in UTC:

```sql
-- SQLite
ALTER TABLE "nitro_session" ADD COLUMN "created_at" DATETIME NOT NULL DEFAULT '2026-09-25T00:00:00.000+00:00';
-- PostgreSQL
ALTER TABLE "nitro_session" ADD COLUMN "created_at" TIMESTAMPTZ NOT NULL DEFAULT '2026-09-25T00:00:00.000+00:00';
```

Until the column exists, every session read on that table fails: it is logged, and the visitor is
treated as new. Every session write throws.
