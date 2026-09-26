"""
This module holds all the partial function & struct definitions for all package extensions
"""

export ProtoBuffer, protobuf
export mustache, otera
export png, svg, pdf
export pormg_nitro_session, pormg_nitro_worker, sync_pormg_env!

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
    pormg_nitro_session(; db_key="db") -> PormGSessionStore

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

`db_key` names the PormG connection, defaulting to `"db"`. It governs **both** halves: the
table is created on that connection, and the returned store routes every session query — read,
write, delete and prune — to the same one. Pass a different key when your session database uses
another PormG connection, for example `db_key="sessions"`.

Requires `using PormG` and a configured PormG connection; without the extension loaded this
is a `MethodError`, exactly like `pormg_nitro_worker`.

This docstring is the only one for this function. The concrete method in `NitroPormGExt`
deliberately carries none, so there is one place to keep accurate — see `sync_pormg_env!`
below for the same arrangement.

## Example
```julia
using Nitro, PormG
PormG.Configuration.load("db")

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
`PORMG_ENV` it would outrank one someone did make, `default_env:` in `connection.yml`. PormG
then resolves its own environment. A blank or whitespace-only `PORMG_ENV` counts as unset. It is
overwritten when there is an environment to publish, and removed when there is not, so PormG
never looks up a `""` section.

**A default, never a force.** With `force = false` (the default) an existing `PORMG_ENV` is
left exactly as it is. PormG's documented precedence stays intact either way:

```
env= kwarg  >  ENV["PORMG_ENV"]  >  `default_env:` in connection.yml  >  "dev"
```

so an explicit `env=` at a `load` call site always wins regardless of this function. Pass
`force = true` only to deliberately overwrite a value already there. It still writes nothing
when neither `NITRO_ENV` nor `GENIE_ENV` is set.

`NitroPormGExt.__init__` calls this for you at `using PormG`, which is what lets an app write
`PormG.Configuration.load_many(["db"])` with no `env=` and still get the environment it set.
Call it by hand only if you set `NITRO_ENV` *after* loading PormG — see the load-order note in
the environment docs.

Requires `using PormG`; without the extension loaded this is a `MethodError`, exactly like
`pormg_nitro_worker`.

## Example
```julia
using Nitro, PormG
# ENV["PORMG_ENV"] is already seeded from NITRO_ENV here.
PormG.Configuration.load_many(["db"])
```
"""
function sync_pormg_env! end

"""
    pormg_nitro_worker(; db_key="db") -> PormGWorkerStore

One-call setup for PormG-backed workers: creates the `nitro_task` table and **two** indexes if
they do not already exist (`IF NOT EXISTS`), and returns a ready-to-use `PormGWorkerStore`.

Table setup is not purely additive. Bootstrapping also issues an unconditional
`ALTER TABLE … ADD COLUMN run_id` against a pre-existing table that predates the run-id
column, and tolerates the error when the column is already there.

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
PormG.Configuration.load("db")

app = App(mod = @__MODULE__)
store = pormg_nitro_worker(db_key="db")
serve(app; middleware=[worker_startup(app; queues=["reports"], store=store)])
# ...and the task calls take the same `app` first: submit_task(app, key, cb, Owner(uid))
```
"""
function pormg_nitro_worker end
