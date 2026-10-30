"""
This module holds all the partial function & struct definitions for all package extensions
"""

export ProtoBuffer, protobuf
export mustache, otera
export png, svg, pdf
export pormg_nitro_session, pormg_nitro_worker, pormg_nitro_pools, sync_pormg_env!

# Serialization extension definitions
function protobuf end
struct ProtoBuffer{T} <: Extractor{T}
    payload::T
end

# Templating extension definitions
function mustache end
function otera end

# Plotting extension definitions
function png end
function svg end
function pdf end

"""
    pormg_nitro_session(; db_key="db", max_sessions=nothing) -> PormGSessionStore

One-call setup for PormG-backed sessions: creates the `nitro_session` table and its expiry
index if they do not already exist (`IF NOT EXISTS`), and returns a ready-to-use
`PormGSessionStore`. Sessions are stored as JSON with a fixed-point expiry timestamp; there
is no sliding expiry.

Each row also records when the session was created (`created_at`), which
`SessionMiddleware(absolute_max_age = …)` measures a session's absolute lifetime from (#362). On a
table created before that column existed, this call adds it on boot and stamps the existing rows
with the upgrade instant, so live sessions get a full lifetime from the upgrade. A store you
construct directly skips this bootstrap, so add the column yourself there (see the #362 entry
in `upgrade_guide()`).

Session data may nest at most **512** levels deep, the same bound as request JSON
(`MAX_JSON_DEPTH`). Writing a deeper payload throws an `ArgumentError` before the row is
touched, rather than storing a session that could never be read back. The check walks the value
before serializing it, so even a payload deep enough to overflow `JSON.json` gets that
`ArgumentError` rather than a `StackOverflowError`. A row stored deeper
before this bound existed reads as no session, and logs a warning that names no payload.

A failed query logs a warning that names no session key or payload either (#646). On
PostgreSQL a constraint violation's `DETAIL` line quotes the row, session key included, and the
key is a bearer credential. So the warning carries PormG's own rendering of the error, which is
built from the SQLSTATE, the constraint, the table and the server's primary message, plus a
`sqlstate` field. It never carries the error object, whose `.cause` keeps the driver's full text.
An error that is not one of PormG's database errors is logged by its type name only.
LibPQ logs the failed statement itself, `DETAIL` included, through its own Memento logger
(`[warn | LibPQ]`) before Nitro sees it. To keep that line out of your logs, raise the level of
LibPQ's Memento logger in your application.

`db_key` names the PormG connection, defaulting to `"db"`. It governs **both** halves: the
table is created on that connection, and the returned store routes every session query — read,
write, delete and prune — to the same one. Pass a different key when your session database uses
another PormG connection, for example `db_key="sessions"`.

`max_sessions` bounds the table against a flood of anonymous sessions (#440). **The default,
`nothing`, is unbounded**: unlike `MemoryStore`, a database store has no size limit of its own.
With a bound, once the table holds `max_sessions` rows `SessionMiddleware` stops saving new
*anonymous* sessions — the request still succeeds, and a warning is logged at most once per
`prune_interval` — while sessions that
end signed in, existing sessions and rotations are never refused. A full store can still keep a
visitor with no cookie from signing in through a form with a session-bound CSRF token. The count
is read at boot, kept by the store's own writes, and re-read on every prune tick, so it costs no
query per request. Size it from the sessions tutorial's *Anonymous Sessions and Floods* section. A non-positive value is an
`ArgumentError`.

Requires `using PormG` and a configured PormG connection; without the extension loaded this
is a `MethodError`, exactly like `pormg_nitro_worker`.

This docstring is the only one for this function. The concrete method in `NitroPormGExt`
deliberately carries none, so there is one place to keep accurate — see `sync_pormg_env!`
below for the same arrangement.

## Example
```julia
using Nitro, PormG
PormG.Configuration.load("db"; env = something(sync_pormg_env!(), current_env()))

store = pormg_nitro_session()
serve(middleware=[SessionMiddleware(store=store)])
```
"""
function pormg_nitro_session end

"""
    sync_pormg_env!(; force::Bool = false) -> Union{String, Nothing}

Publish the environment set in `NITRO_ENV` (or its fallback `GENIE_ENV`, validated exactly as
[`current_env`](@ref) validates them) to `ENV["PORMG_ENV"]`, the variable PormG's own
configuration loader consults. Returns whatever `PORMG_ENV` holds afterwards, or `nothing` if it
is unset.

**Only a set environment is published.** With neither variable set, `current_env()` reports its
`"dev"` fallback, but nothing is written: that fallback is not a choice anyone made, and as
`PORMG_ENV` it would answer for every PormG `load` in the process. PormG then resolves its own
environment, and outside an interactive session it refuses a `load` or `register_connection`
that names none. A blank or whitespace-only `PORMG_ENV` counts as unset. It is overwritten when
there is an environment to publish, and removed when there is not.

**A default, never a force.** With `force = false` (the default) an existing `PORMG_ENV` is
left exactly as it is. PormG's precedence stays intact either way:

```
env= kwarg  >  ENV["PORMG_ENV"]  >  in a REPL only: `default_env:` in connection.yml, else "dev"
```

so an explicit `env=` at a `load` call site always wins regardless of this function. Pass
`force = true` only to deliberately overwrite a value already there. It still writes nothing
when neither `NITRO_ENV` nor `GENIE_ENV` is set.

`NitroPormGExt.__init__` calls this for you at `using PormG`, which is what lets a `load` with
no `env=` get the environment `NITRO_ENV` set. Its return value is what the boot `Nitro.newapp`
writes passes to PormG, with Nitro's fallback behind it:
`env = something(sync_pormg_env!(), current_env())` is a set `PORMG_ENV`, else `NITRO_ENV`
(or `GENIE_ENV`), else `"dev"`, so the `load` names an environment even with neither variable
set. Call it by hand, too, if you set `NITRO_ENV` *after* loading PormG — see the load-order
note in the environment docs.

Requires `using PormG`; without the extension loaded this is a `MethodError`, exactly like
`pormg_nitro_worker`.

## Example
```julia
using Nitro, PormG
# ENV["PORMG_ENV"] is already seeded from NITRO_ENV here, when NITRO_ENV is set. With neither
# variable set, this `load` is refused outside a REPL; name the environment instead:
#   PormG.Configuration.load_many(["db"]; env = something(sync_pormg_env!(), current_env()))
PormG.Configuration.load_many(["db"])
```
"""
function sync_pormg_env! end

"""
    pormg_nitro_worker(; db_key="db") -> PormGWorkerStore

One-call setup for PormG-backed workers: creates the `nitro_task` table and **four** indexes if
they do not already exist (`IF NOT EXISTS`), and returns a ready-to-use `PormGWorkerStore`.

Table setup is not purely additive. On a table created by an older Nitro, bootstrapping adds the
columns it lacks with `ALTER TABLE … ADD COLUMN`: `run_id` ([#108](https://github.com/PingoLee/Nitro.jl/issues/108))
and the claim columns `external`, `attempt`, `claimed_by` and `lease_expires_at`
([#514](https://github.com/PingoLee/Nitro.jl/issues/514)), each with the default an existing row
means. Each column is probed first and altered only when missing
([#366](https://github.com/PingoLee/Nitro.jl/issues/366)), so a boot on an up-to-date table runs no
`ALTER`; on PostgreSQL the boot that adds a column logs one missing-column message (LibPQ's
`UndefinedColumn` warning) for its probe.
The two claim indexes are plain `CREATE INDEX` statements, so on a large PostgreSQL table the boot
that creates them blocks writes to it while they build.

A task's return value is stored as JSON, and may nest at most **512** levels deep, the same
bound as request JSON (`MAX_JSON_DEPTH`). A deeper result makes the completing write throw an
`ArgumentError` before the row is touched. The value is walked before it is serialized, so this
holds even for a result deep enough to overflow `JSON.json`. The run then retries or fails like
any other attempt that throws, so the task ends `FAILED` rather than storing a result no read
could decode. `InMemoryWorkerStore` serializes nothing and has no such limit.

Requires `using PormG` and a configured PormG connection; without the extension loaded this
is a `MethodError`.

This docstring is the only one for this function — the concrete method in `NitroPormGExt`
deliberately carries none.

## Example
```julia
using Nitro, PormG
PormG.Configuration.load("db"; env = something(sync_pormg_env!(), current_env()))

app = App(mod = @__MODULE__)
store = pormg_nitro_worker(db_key="db")
serve(app; middleware=[worker_startup(app; queues=["reports"], store=store)])
# ...and the task calls take the same `app` first: submit_task(app, key, cb, Owner(uid))
```
"""
function pormg_nitro_worker end

"""
    pormg_nitro_pools(; keys, drain_seconds = 5.0) -> LifecycleMiddleware

Close the named PormG connection pools when the server stops (#161): pass it in
`serve(app; middleware = [...])`, and `terminate(app)` calls `PormG.Configuration.close_pool!`
on each key, in the **reverse** of the order given.

The close runs in the `on_stopped` phase of [`LifecycleMiddleware`](@ref Nitro.Core.Types.LifecycleMiddleware)
— after the listener has closed and the HTTP drain is over — not in `on_shutdown`, which runs
while requests are still being served. A pool closed there would cut off the queries the drain
is waiting for, and a request served during the drain would reopen it.

- `keys` is required and must be non-empty. Name the keys **this** app owns: several `App`s in
  one process share PormG's registry, so closing every loaded pool would cut another app's
  queries off. Each key must already be loaded (`load_many`, `load` or `register_connection`)
  when this is called, and a key that is not is an `ArgumentError` here, before `serve` starts.
  This is the fail-fast check: a throwing `on_startup` hook is logged and swallowed, so it could
  not stop `serve`. To check that a database is *reachable* at boot, call
  `PormG.Configuration.ping(key)` in `main()` yourself.
- `drain_seconds` is passed to each `close_pool!`: how long it waits for a leased connection to
  be returned before closing it anyway. After the HTTP drain, only work outside a request (a
  background task, a handler cut off by a forced close) can still hold one.

A closed pool is not a dead one: PormG reopens it on the next query, so
`serve(); terminate(); serve()` needs nothing more, and code that queries after `terminate`
reconnects. Let `terminate` return before serving again, though: the port is free once the drain
begins, so a `serve` that starts during it is running when these pools are closed, and a
connection it still holds `drain_seconds` later is closed under it. PormG's own `atexit` hook still closes every pool when the process exits; this is
for closing them at `terminate`, which is earlier, or not the end of the process at all.

Requires `using PormG`; without the extension loaded this is a `MethodError`, exactly like
`pormg_nitro_worker`. This docstring is the only one for this function.

## Example
```julia
using Nitro, PormG
PormG.Configuration.load_many(["db", "db_audit"]; root, env)

app = App(mod = @__MODULE__)
serve(app; middleware = [pormg_nitro_pools(keys = ["db", "db_audit"])])
# terminate(app) -> close_pool!("db_audit"), then close_pool!("db")
```
"""
function pormg_nitro_pools end

# `Nitro.newapp(name; pormg = true)`'s PormG half (#417), documented on `newapp` in
# `src/newapp.jl`. `NitroPormGExt` gives it its one method: it writes the app through the callback
# it is handed, then runs PormG's interactive `setup`. No method means PormG is not loaded.
function _newapp_pormg end
