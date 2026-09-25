module NitroPormGExt

using Nitro
using PormG
using Dates
using JSON
using UUIDs

import Nitro.Auth: make_password, check_password, password_needs_upgrade
import Nitro.Core.Types: AbstractSessionStore, SessionPayload, get_session, set_session!, update_session!, delete_session!, cleanup_expired_sessions!, is_expired
import Nitro.Core.Cookies: storesession!, prunesessions!
import Nitro: pormg_nitro_session, sync_pormg_env!
# Stored JSON is read through the same depth bound as request JSON, and written only when it can
# be read back (#344). `is_unrecoverable` is the #254 catch policy every request-path site uses.
import Nitro.Core.Util.BodyParsers: _parse_json_bounded, _check_json_depth, _check_value_depth
import Nitro.Core.Errors: is_unrecoverable

import Nitro.Workers: AbstractWorkerStore, TaskInfo, TaskStatus, TaskOptions,
    PENDING, RUNNING, COMPLETED, FAILED, CANCELLED,
    TaskAuthority, Owner, System, UNSUPPLIED, owner_of, _is_authorized, TASK_KEY_DELIMITER,
    _check_page,
    get_task_info, set_task!, replace_task!, add_watcher!, try_transition!,
    delete_task!, cleanup_tasks!, get_all_tasks,
    list_running_task_refs, RunningTaskRef,
    get_queue_authorizer, set_queue_authorizer!,
    get_error_redactor, set_error_redactor!,
    get_watch_authorizer, set_watch_authorizer!,
    lock_tasks
import Nitro: pormg_nitro_worker

export PormGWorkerStore, pormg_nitro_worker

# ============================================================================
# SECTION 1: Password Field Hooks (existing)
# ============================================================================

"""
    hash_password_field(value) -> value

Hook for PormG's `normalize_field_value` on `PasswordField` with `auto_hash=true`.

- A non-blank string is **always** hashed with `make_password`, including one that already
  looks like an encoded hash (#311). The value comes from user input, and a pass-through keyed
  on the hash *prefix* let a user register the password `pbkdf2_sha256\$9223372036854775807\$s\$h`
  and have it stored verbatim, as a hash whose cost the next login would pay.
- To store a hash you computed yourself, declare the field `auto_hash=false`; PormG then stores
  the string as given. That is the explicit route for pre-hashed values — and an app that
  hashes with `make_password` before saving must declare it now, or once the seam lands its
  hashes get hashed again (PormG's default is `auto_hash=true`).
- A blank string, or a value that is not a string (e.g. `nothing`), passes through untouched:
  type validation is PormG's responsibility, not Nitro's.
- A password longer than `Nitro.Auth.MAX_PASSWORD_BYTES` (4096) bytes throws `ArgumentError`
  out of the save, as `make_password` does. Validate the length before assigning it.

Contract for PormG's side of the seam, which does not exist yet (PormG 0.6 has no
`register_field_hook`, so this hook is registered only when it appears): the hook must run on
values the **application assigns**, never on a value read back from the database, or saving
a loaded row would hash its hash.
"""
function hash_password_field(value)
    value isa AbstractString || return value
    isempty(strip(value)) && return value
    return make_password(value)
end

"""
    verify_password(raw::AbstractString, encoded::AbstractString) -> Bool

Convenience wrapper around `Nitro.Auth.check_password` for use in PormG model contexts.
"""
function verify_password(raw::AbstractString, encoded::AbstractString)
    return check_password(raw, encoded)
end

"""
    needs_rehash(encoded::AbstractString; kwargs...) -> Bool

Convenience wrapper around `Nitro.Auth.password_needs_upgrade` for use in PormG model contexts.
"""
function needs_rehash(encoded::AbstractString; kwargs...)
    return password_needs_upgrade(encoded; kwargs...)
end

# ============================================================================
# SECTION 2: Session Model
# ============================================================================

"""
    _bind_model!(model, db_key) -> model

Bind one of Nitro's infrastructure models (`nitro_session`, `nitro_task`) to a PormG
connection key, by assigning `connect_key` directly.

**Why not `set_models`.** That is PormG's documented binder, but it does far more than bind:
it writes the `REGISTERED_MODULES` global, `Core.eval`s a `const __pormg_init_path__` into
the calling module, may implicitly `Configuration.load(path)`, and wires reverse accessors
onto *other* models. None of that is wanted for two tables that
`register_ignore_tables!` deliberately keeps out of migrations. `set_models` itself binds by
doing exactly this assignment (`PormG/src/Models.jl`), and PormG's own `src/precompile.jl`
binds the same way, so this is the narrow half of a supported operation rather than a
workaround. It is migration-neutral: `makemigrations` reads `models.jl` from disk and never
consults `REGISTERED_MODULES`.

**Why bind at all, when `.db(key)` already routes the query.** PormG's
`ensure_model_transaction_scope` gates on the **model's** `connect_key` and never consults
the query's `.db()` override. Unbound, it throws `InvalidConfigurationError` for *every*
query issued while any transaction is open on the calling task — swallowed on the read paths
and rethrown on the writes, which is #202.

**Why the model is per store and never a process-wide singleton.** `connect_key` names
exactly one connection. Two stores on different keys sharing one model object would
overwrite each other's binding, and the loser would then throw `TransactionError` instead of
being fixed. Building a model is a handful of allocations and happens about twice per
application, so there is nothing to cache and no shared mutable state to lock.

The caller must pass the key the store will query on. On the path where a store *builds* its
own model — the factories, and either constructor called without `model=` — both this key and
the query's `.db(...)` come from the one `store.db_key` field, so they cannot diverge. That
matters: a model bound to `A` queried with `.db(B)` inside `run_in_transaction(A)` *passes*
the guard and then silently runs outside the transaction on B's pool, and PormG has no guard
for that direction.

Passing `model=` explicitly opts out of that coupling — the caller then owns keeping the
model's `connect_key` and the store's `db_key` in agreement, and nothing checks it. The test
doubles rely on this, since they carry no `connect_key` at all.
"""
function _bind_model!(model, db_key::String)
    model.connect_key = db_key
    return model
end

"""
PormG model for the `nitro_session` table, bound to `db_key`.

Columns:
- `session_key`  — VARCHAR(40), primary key (the session ID)
- `session_data` — TEXT (JSON-serialized session payload)
- `expires_at`   — TIMESTAMPTZ, indexed for efficient cleanup
"""
function _define_session_model(db_key::String)
    if isdefined(PormG, :Models)
        m = PormG.Models.Model("nitro_session",
            session_key  = PormG.Models.CharField(max_length=40, primary_key=true),
            session_data = PormG.Models.TextField(default="{}"),
            expires_at   = PormG.Models.DateTimeField(db_index=true),
        )
        _bind_model!(m, db_key)
        return m
    end
    return nothing
end

"""
    session_model(db_key="db")

A `nitro_session` model bound to `db_key`. One model per store, never a process-wide
singleton: `connect_key` names exactly one connection, so a shared model cannot serve two
stores on different keys — see `_bind_model!`.
"""
session_model(db_key::String="db") = _define_session_model(db_key)

# ============================================================================
# SECTION 3: PormGSessionStore
# ============================================================================

"""
    PormGSessionStore(; model=nothing, db_key="db")

A PormG-backed session store that implements Nitro's `AbstractSessionStore{String, Dict{String,Any}}`.

Sessions are stored as JSON text in the database and expire at a fixed timestamp
from the last write (no sliding expiry).

`db_key` is the PormG connection key **every** session query runs on — read, write, delete and
prune alike — and it must name the connection whose `nitro_session` table you bootstrapped.
Prefer `pormg_nitro_session(db_key=...)`, which creates the table and returns a store already
pointed at the same connection.

## Usage

```julia
using Nitro, PormG

# Preferred: creates the table and returns a store pointed at the same connection.
store = pormg_nitro_session()
serve(middleware=[SessionMiddleware(store=store, secure=false)])
```

Constructing the type directly skips the table bootstrap, so do it only when the
`nitro_session` table already exists on that connection. The type is not exported, so application
code reaches it through the extension module:

```julia
ext = Base.get_extension(Nitro, :NitroPormGExt)
store = ext.PormGSessionStore(db_key="sessions")
```
"""
struct PormGSessionStore <: AbstractSessionStore{String, Dict{String,Any}}
    model::Any  # PormG Model reference
    db_key::String
end

function PormGSessionStore(; model=nothing, db_key::String="db")
    # A SUPPLIED model is used exactly as given -- the caller owns its `connect_key`, and
    # the test doubles that pass one here are immutable structs that could not take the
    # assignment anyway. Only a model this constructor builds gets bound (#202).
    m = isnothing(model) ? session_model(db_key) : model
    if isnothing(m)
        error("PormGSessionStore requires PormG.Models to be available. Ensure PormG is properly loaded.")
    end
    return PormGSessionStore(m, db_key)
end

# Route every session query to the store's configured connection, exactly as `_task_objects`
# does for the worker store. Without this the query falls back to the model's own
# `connect_key`, and before #199 that was `nothing` -- PormG then either used the sole loaded
# connection or threw `InvalidConfigurationError` when several were loaded. Both outcomes
# ignored `db_key`, and the throw is swallowed by the read paths below, so sessions silently
# stopped persisting (#199).
#
# Since #202 the model carries `connect_key == store.db_key` too, so this call is redundant
# for ROUTING and is kept anyway, for two reasons. It is the only thing the mock in
# `test/extensions/pormg_worker_tests.jl` can pin (#203). And PormG reads the two keys from
# different places -- `ensure_model_transaction_scope` reads the model's, `get_settings` reads
# the query's -- so a model bound to A queried with `.db(B)` inside `run_in_transaction(A)`
# passes the guard and then silently runs OUTSIDE the transaction on B's pool, with no guard
# for that direction. Deriving both from the single `store.db_key` field is what makes that
# divergence unrepresentable.
_session_objects(store::PormGSessionStore) = store.model.objects.db(store.db_key)

# -- Serialization helpers --

# Stored JSON -- a session payload here, a task's `result` in the worker store below -- is read
# through the same 512-level bound as request JSON (#344). What the application stored is not
# attacker input, but reading it back recurses once per level on whatever task asked, often a
# request task (`get_task_info` from a handler, the session read in middleware), and #301 showed
# an overflow there can take a Windows process down rather than raise.
#
# Bounding only the read would make a value stored deeper than the bound permanently
# unreadable: the session would silently reset on every request, the task info would error on
# every read. So the WRITE refuses it instead, while the caller can still see why, before any row
# is touched. `max_fields = 0` on the read: the per-request key cap guards request bodies, and
# this is the app's own data.
#
# Twice, and the order is the point. `JSON.json` recurses once per level, so a value deep enough
# to overflow it -- thousands of levels, which only the app can build, since request JSON stops
# at 512 -- used to raise `StackOverflowError` from inside the serializer before any check of its
# output could run (#367). `_check_value_depth` walks the VALUE first, non-recursively and
# mirroring the writer, and refuses it with the same `ArgumentError`. The scan of the text stays
# as the final word: a `JSONText` is written verbatim, and only the text shows its depth.
function _json_for_storage(value)::String
    _check_value_depth(value)
    serialized = JSON.json(value)
    _check_json_depth(serialized)
    return serialized
end

_parse_stored(raw::AbstractString) = _parse_json_bounded(raw; max_fields = 0)

function _serialize_session(data::Dict{String,Any})::String
    return _json_for_storage(data)
end

function _deserialize_session(raw::AbstractString)::Dict{String,Any}
    parsed = _parse_stored(raw)
    return convert(Dict{String,Any}, parsed)
end

# -- Store interface implementation --

function Base.get(store::PormGSessionStore, session_id::String, default)
    # Both catches below follow #254: an interrupt, a stack overflow or an out-of-memory is not
    # "no session" -- reported as one, it would log the visitor out and carry on in a process
    # that may be corrupted. They propagate; everything else still reads as `default`.
    result = try
        _session_objects(store).filter("session_key" => session_id).first()
    catch e
        is_unrecoverable(e) && rethrow()
        @warn "PormGSessionStore: failed to read session" exception=(e, catch_backtrace())
        return default
    end
    isnothing(result) && return default
    # Decoding is a separate `try` so it can log differently from the query above (#267). A JSON
    # parse error quotes the stored text around the failure, and that text is a session payload,
    # so this warning carries the exception TYPE only. It never carries the session key either,
    # because the key is the credential. The query failure above keeps its full exception, since a
    # driver error quotes no payload and an outage needs its message to be diagnosed.
    try
        expires_at = _parse_db_datetime(result[:expires_at])
        data = _deserialize_session(result[:session_data])
        return SessionPayload(data, expires_at)
    catch e
        is_unrecoverable(e) && rethrow()
        @warn "PormGSessionStore: failed to read session: the stored session does not decode" exception_type=typeof(e)
        return default
    end
end

function _parse_db_datetime(val)::DateTime
    val isa DateTime && return val
    # PormG returns ZonedDateTime from PostgreSQL TIMESTAMPTZ and
    # from SQLite when the stored value contains a timezone offset.
    if val isa Dates.AbstractDateTime
        # To UTC, not merely stripped of its zone. Every `DateTime` Nitro compares these against
        # is UTC, and copying the wall-clock fields read a `ZonedDateTime` from a non-UTC session
        # as off by the offset. LibPQ pins the session to UTC by default, so this was latent, but
        # `PGTZ` or a session TimeZone option would shift every stored instant: session
        # `expires_at`, and the `started_at` that `zombie_min_age` judges a claim's age by (#239).
        # `utc_datetime` is TimeZones' field for exactly this, read here without importing
        # TimeZones into the ext. Whole seconds, as before, so a UTC session reads unchanged.
        u = hasproperty(val, :utc_datetime) ? getproperty(val, :utc_datetime) : val
        return DateTime(Dates.year(u), Dates.month(u), Dates.day(u),
                        Dates.hour(u), Dates.minute(u), Dates.second(u))
    end
    s = string(val)
    # Try common DB formats
    for fmt in (dateformat"yyyy-mm-dd\THH:MM:SS\Z",
                dateformat"yyyy-mm-dd\THH:MM:SS",
                dateformat"yyyy-mm-dd HH:MM:SS",
                dateformat"yyyy-mm-dd HH:MM:SS.s")
        try
            return Dates.DateTime(s, fmt)
        catch
            continue
        end
    end
    # Strip timezone suffix and retry. This branch ASSUMES the suffix is UTC: PormG writes
    # `+00:00`, and it hands SQLite DateTimeField columns back as `ZonedDateTime` (the branch
    # above), so only a hand-written TEXT value with another offset reaches here misread.
    clean = replace(s, r"[+-]\d{2}:?\d{2}$" => "")
    clean = replace(clean, r"\.\d+$" => "")
    return Dates.DateTime(clean, dateformat"yyyy-mm-dd\THH:MM:SS")
end

function get_session(store::PormGSessionStore, session_id::String)
    payload = Base.get(store, session_id, nothing)
    if isnothing(payload)
        return nothing
    end
    if payload isa SessionPayload
        if is_expired(payload)
            return nothing
        end
        return copy(payload.data)
    end
    return payload
end

function set_session!(store::PormGSessionStore, session_id::String, data::Dict{String,Any}; ttl::Int=3600)
    expires_at = Dates.now(Dates.UTC) + Dates.Second(ttl)
    # Outside the `try` on purpose: a payload nested past the JSON depth bound throws its
    # `ArgumentError` here, before the row is touched, rather than being stored unreadable (#344).
    serialized = _serialize_session(data)

    try
        existing = _session_objects(store).filter("session_key" => session_id).first()
        if isnothing(existing)
            _session_objects(store).create(
                "session_key"  => session_id,
                "session_data" => serialized,
                "expires_at"   => expires_at,
            )
        else
            _session_objects(store).filter("session_key" => session_id).update(
                "session_data" => serialized,
                "expires_at"   => expires_at,
            )
        end
    catch e
        @warn "PormGSessionStore: failed to write session" exception=(e, catch_backtrace())
        rethrow()
    end
    return data
end

# One `UPDATE ... WHERE session_key = ? AND expires_at > now`, never a read followed by a write:
# the WHERE is the existence check, so a row a concurrent logout deleted -- or one that expired --
# matches nothing and is NOT re-created (#318). `update()` returns the matched-row count (Django
# semantics). `__@gt` is the exact complement of the prune's inclusive `__@lte` and of
# `is_expired`, so the boundary instant counts as expired here too.
function update_session!(store::PormGSessionStore, session_id::String, data::Dict{String,Any}; ttl::Int=3600)
    now_utc = Dates.now(Dates.UTC)
    serialized = _serialize_session(data)

    matched = try
        _session_objects(store).filter("session_key" => session_id,
                                       "expires_at__@gt" => now_utc).update(
            "session_data" => serialized,
            "expires_at"   => now_utc + Dates.Second(ttl),
        )
    catch e
        @warn "PormGSessionStore: failed to write session" exception=(e, catch_backtrace())
        rethrow()
    end
    return matched > 0
end

function delete_session!(store::PormGSessionStore, session_id::String)
    try
        _session_objects(store).filter("session_key" => session_id).delete()
    catch e
        @warn "PormGSessionStore: failed to delete session" exception=(e, catch_backtrace())
        rethrow()
    end
    return nothing
end

function cleanup_expired_sessions!(store::PormGSessionStore)
    now_utc = Dates.now(Dates.UTC)
    try
        _session_objects(store).filter("expires_at__@lte" => now_utc).delete()
    catch e
        @warn "PormGSessionStore: failed to cleanup expired sessions" exception=(e, catch_backtrace())
    end
    return nothing
end

function storesession!(store::PormGSessionStore, key::String, value::Dict{String,Any}; ttl::Int=3600)
    return set_session!(store, key, value; ttl=ttl)
end

# No `prunesessions!` override: the generic `AbstractSessionStore` method in `src/cookies.jl` is
# now exactly this body, so a copy here is duplication that can only drift.

# ============================================================================
# SECTION 4: Table Bootstrap & Convenience Constructor
# ============================================================================

"""
    _ensure_session_table!(conn, model)

Execute `CREATE TABLE IF NOT EXISTS` and `CREATE INDEX IF NOT EXISTS` for the
session model.  Safe to call on every startup — the IF NOT EXISTS guard makes
it a no-op when the table already exists.
"""
function _ensure_session_table!(conn, model)
    create_table_sql = PormG.Dialect.create_table(conn, model)
    PormG.ConnectionPool.fetch(conn, create_table_sql)

    create_index_sql = PormG.Dialect.create_index(
        conn,
        "\"nitro_session_expires_at_idx\"",
        "\"nitro_session\"",
        ["\"expires_at\""],
    )
    PormG.ConnectionPool.fetch(conn, create_index_sql)
    return nothing
end

# Deliberately no docstring: the authoritative one is on the weakdep stub in `src/exts.jl`, which
# is also what `?pormg_nitro_session` resolves to. Two docstrings on one function render as two
# conflicting help entries and drift apart independently (#33).
function pormg_nitro_session(; db_key::String="db")
    model = session_model(db_key)
    if isnothing(model)
        error("pormg_nitro_session: PormG.Models is not available. Ensure PormG is properly loaded.")
    end
    conn = PormG.connection(key=db_key)
    _ensure_session_table!(conn, model)
    return PormGSessionStore(model=model, db_key=db_key)
end

# ============================================================================
# SECTION 6: Task Model
# ============================================================================

"""
PormG model for the `nitro_task` table, bound to `db_key`.

Columns:
- `id`           — VARCHAR(255), primary key. Holds the *scoped* task id, which under
                   the default `:user` scope is `"<user_id>::<task_key>"`, so it needs
                   room for both halves. `_ensure_task_table!` only issues
                   `CREATE TABLE IF NOT EXISTS`: a database created before this column
                   was widened keeps its old width and needs a manual `ALTER TABLE`
                   (SQLite ignores `VARCHAR` lengths, so only Postgres/MySQL care).
- `run_id`       — VARCHAR(36), the identity of one *run* of this task. Fenced against in
                   `try_transition!`'s WHERE clause so a previous run's terminal write cannot
                   land on the record that replaced it
                   ([#108](https://github.com/PingoLee/Nitro.jl/issues/108)). Deliberately
                   **not** indexed: it only ever appears as an extra `AND` term beside the
                   primary key, which the PK index already resolves. Added after the table
                   shipped, so `_ensure_run_id_column!` backfills it on boot.
- `status`       — VARCHAR(20)
- `progress`     — FLOAT
- `result`       — TEXT (JSON-serialized task results)
- `error`        — TEXT
- `created_at`   — TIMESTAMPTZ
- `started_at`   — TIMESTAMPTZ, indexed for efficient querying/pruning
- `completed_at` — TIMESTAMPTZ, indexed for efficient querying/pruning
- `watchers`     — TEXT (JSON-serialized list of watchers)
- `queue_name`   — VARCHAR(100)
"""
function _define_task_model(db_key::String)
    if isdefined(PormG, :Models)
        m = PormG.Models.Model("nitro_task",
            id           = PormG.Models.CharField(max_length=255, primary_key=true),
            run_id       = PormG.Models.CharField(max_length=36, default=""),
            status       = PormG.Models.CharField(max_length=20),
            progress     = PormG.Models.FloatField(default=0.0),
            result       = PormG.Models.TextField(default=""),
            error        = PormG.Models.TextField(default=""),
            created_at   = PormG.Models.DateTimeField(),
            started_at   = PormG.Models.DateTimeField(null=true, blank=true, db_index=true),
            completed_at = PormG.Models.DateTimeField(null=true, blank=true, db_index=true),
            watchers     = PormG.Models.TextField(default="[]"),
            queue_name   = PormG.Models.CharField(max_length=100),
        )
        _bind_model!(m, db_key)
        return m
    end
    return nothing
end

"""
    task_model(db_key="db")

A `nitro_task` model bound to `db_key`. One model per store, never a process-wide
singleton — see `_bind_model!`.
"""
task_model(db_key::String="db") = _define_task_model(db_key)

# ============================================================================
# SECTION 7: PormGWorkerStore
# ============================================================================

"""
    PormGWorkerStore(; model=nothing, db_key="db")

A PormG-backed worker store that implements Nitro's `AbstractWorkerStore`.

`db_key` is the PormG connection key **every** task query runs on — read, write, transition,
delete and retention sweep alike — and it must name the connection whose `nitro_task` table
you bootstrapped. Prefer `pormg_nitro_worker(db_key=...)`, which creates the table and
returns a store pointed at the same connection.

A `model` passed explicitly is used as given, including its `connect_key`; omit it and the
store builds one bound to `db_key` (see `_bind_model!`).
"""
struct PormGWorkerStore <: AbstractWorkerStore
    model::Any
    db_key::String
    task_lock::ReentrantLock
    queue_authorizer::Ref{Any}
    watch_authorizer::Ref{Any}
    error_redactor::Ref{Any}
end

function PormGWorkerStore(; model=nothing, db_key::String="db")
    # A supplied model is used as given -- see the note in `PormGSessionStore` (#202).
    m = isnothing(model) ? task_model(db_key) : model
    if isnothing(m)
        error("PormGWorkerStore requires PormG.Models to be available. Ensure PormG is properly loaded.")
    end
    return PormGWorkerStore(
        m,
        db_key,
        ReentrantLock(),
        Ref{Any}(nothing),
        Ref{Any}(nothing),
        Ref{Any}(nothing),
    )
end

# Route every task query to the store's configured connection. PormG's query manager always
# supports `.db(key)`, so we call it directly rather than silently falling back to the model's
# default connection (which would write tasks to the wrong database). Since #202 the model is
# bound to the same key, and the reasoning for keeping both -- one field, two readers -- is on
# `_session_objects` above.
_task_objects(store::PormGWorkerStore) = store.model.objects.db(store.db_key)

# -- Serialization Helpers --

function _to_db_record(task::TaskInfo)
    # A result nested past the JSON depth bound throws here, before the row is touched, instead
    # of being stored where no read could decode it (#344; `_json_for_storage`). The watcher list
    # is a flat `Vector{String}` and cannot nest.
    result_str = isnothing(task.result) ? "" : _json_for_storage(task.result)
    watchers_str = JSON.json(task.watchers)
    return Dict{String, Any}(
        "id" => task.id,
        "run_id" => string(task.run_id),
        "status" => string(task.status),
        "progress" => task.progress,
        "result" => result_str,
        "error" => isnothing(task.error) ? "" : task.error,
        "created_at" => task.created_at,
        "started_at" => task.started_at,
        "completed_at" => task.completed_at,
        "watchers" => watchers_str,
        "queue_name" => isnothing(task.queue_name) ? "" : task.queue_name,
    )
end

function _parse_optional_db_datetime(val)
    if val === nothing || val === missing
        return nothing
    end
    if val isa AbstractString && isempty(strip(val))
        return nothing
    end
    return _parse_db_datetime(val)
end

"""
The `id` of a raw row, without parsing the rest of it.

Same symbol-or-string key handling as `_from_db_record`, so it works against both PormG
rows and the test mocks — but it exists to let `_authority_rows` dedupe *before* paying
for a full `_from_db_record`, which JSON-parses the `watchers` blob.
"""
function _row_task_id(row)
    haskey(row, :id) && return string(row[:id])
    haskey(row, "id") && return string(row["id"])
    return nothing
end

# Refuse a row from a table that predates the `run_id` column (#108). Its own function because
# `_listed_task` must run it OUTSIDE its per-row catch: a missing column is table-wide, and
# skipping every row over it would rebuild the empty listing #267 removed.
function _check_run_id_column(row, id::String)
    if !(haskey(row, :run_id) || haskey(row, "run_id"))
        error("PormGWorkerStore: task row '$(id)' has no `run_id` column — this nitro_task " *
              "table predates #108. Boot through `pormg_nitro_worker`, which adds it, or run " *
              "the ALTER TABLE from the #108 entry — `Nitro.upgrade_guide(from = v\"<your pin>\")`.")
    end
    return nothing
end

function _from_db_record(row)::TaskInfo
    # Support both symbol lookup (PormG DB rows) and string dict (for mocks)
    get_val = (key_sym, key_str) -> haskey(row, key_sym) ? row[key_sym] : row[key_str]

    id = string(get_val(:id, "id"))
    task = TaskInfo(id)

    # The single most dangerous line in this file. `TaskInfo(id)` above MINTS a fresh `run_id`,
    # so a deserializer that forgets to overwrite it from the row invents a new run on every
    # read — and then no worker can ever finish its own task, because every `try_transition!`
    # fence compares against an id nothing holds. Assign explicitly, and refuse a row that
    # predates the column rather than silently keeping the invented one (#108).
    _check_run_id_column(row, id)
    task.run_id = UUIDs.UUID(string(get_val(:run_id, "run_id")))

    status_str = string(get_val(:status, "status"))
    if status_str == "PENDING"
        task.status = PENDING
    elseif status_str == "RUNNING"
        task.status = RUNNING
    elseif status_str == "COMPLETED"
        task.status = COMPLETED
    elseif status_str == "FAILED"
        task.status = FAILED
    elseif status_str == "CANCELLED"
        task.status = CANCELLED
    else
        error("PormGWorkerStore: unknown task status '$(status_str)' for task '$(id)'")
    end

    @atomic task.progress = Float64(get_val(:progress, "progress"))

    result_str = string(get_val(:result, "result"))
    task.result = isempty(result_str) ? nothing : _parse_stored_json(identity, result_str, "result", id)

    err_str = string(get_val(:error, "error"))
    task.error = isempty(err_str) ? nothing : err_str

    task.created_at = _parse_db_datetime(get_val(:created_at, "created_at"))

    task.started_at = _parse_optional_db_datetime(get_val(:started_at, "started_at"))

    task.completed_at = _parse_optional_db_datetime(get_val(:completed_at, "completed_at"))

    watchers_str = string(get_val(:watchers, "watchers"))
    task.watchers = isempty(watchers_str) ? String[] :
        _parse_stored_json(v -> convert(Vector{String}, v), watchers_str, "watchers", id)

    qn_str = string(get_val(:queue_name, "queue_name"))
    task.queue_name = isempty(qn_str) ? nothing : qn_str

    return task
end

# Parse a stored JSON column, and on failure throw an error that names the task and the column
# but carries NONE of the stored text (#267). JSON.jl's own error quotes the text around the
# failure position, which is a task's `result`. A warning that redacts it is not enough, because
# `get_task_info` rethrows to its caller and a request handler's error logger prints the message
# in full.
#
# The replacement is thrown AFTER the `catch` block closes, not inside it. Thrown inside, the
# original error would stay on the exception stack as its cause, and anything that prints the
# stack (`current_exceptions()`, an uncaught task failure) would quote the text anyway.
#
# The parse is depth-bounded (see `_json_for_storage`), so a value nested past the bound is one
# more thing that "does not decode". An interrupt, overflow or OOM is not: relabelled as a decode
# error it would hide a process that may be corrupted (#254, #344), so those propagate.
function _parse_stored_json(shape::Function, raw::AbstractString, column::String, id::String)
    parsed = try
        Some(shape(_parse_stored(raw)))
    catch e
        is_unrecoverable(e) && rethrow()
        nothing
    end
    parsed === nothing &&
        # "does not decode", not "is not valid JSON": `shape` failing on valid JSON of the wrong
        # shape (a `null` or `[1]` watcher list) lands here too.
        error("PormGWorkerStore: task '$(id)' has a stored `$(column)` that does not decode")
    return something(parsed)
end

# -- AbstractWorkerStore Interface Methods --

# The DURABLE read, and only that. This used to prefer a process-local live-`TaskInfo`
# cache, which made it the wrong function for run-start: re-running a key whose record was
# terminal while its previous run still executed handed the new run its predecessor's object,
# so the new run failed its own `run_id` fence forever (#167). Serving a running callback's
# object to a reader is `WorkerRuntime`'s job now, and it does it for every backend.
function get_task_info(store::PormGWorkerStore, task_id::String)
    # Log and rethrow, matching `set_task!`. Returning `nothing` here would make a
    # failed read indistinguishable from an absent row, and `_register_or_watch!`
    # reads absence as "this key is free" — so one swallowed connection blip would
    # skip the cross-user authorization gate and let a caller take over someone
    # else's task. It also swallowed `_from_db_record`'s deliberate schema-drift
    # error, defeating the check that raises it.
    #
    # The warning carries the exception's TYPE, never its message (#267). `_from_db_record` no
    # longer raises a message that quotes a stored blob (see `_parse_stored_json`), so this is a
    # second guarantee and not the only one. The caller gets the whole exception from the
    # rethrow, and that exception is value-free for the same reason.
    try
        result = _task_objects(store).filter("id" => task_id).first()
        if isnothing(result)
            return nothing
        end
        return _from_db_record(result)
    catch e
        @warn "PormGWorkerStore: failed to read task" task_id exception_type=typeof(e)
        rethrow()
    end
end

function _write_task!(store::PormGWorkerStore, task_id::String, task_info::TaskInfo, full_record::Bool)
    record = _to_db_record(task_info)
    try
        existing = _task_objects(store).filter("id" => task_id).first()
        if isnothing(existing)
            # A fresh row has no watchers to preserve, so the create branch always
            # writes them whichever entry point we came through.
            _task_objects(store).create(
                "id" => record["id"],
                "run_id" => record["run_id"],
                "status" => record["status"],
                "progress" => record["progress"],
                "result" => record["result"],
                "error" => record["error"],
                "created_at" => record["created_at"],
                "started_at" => record["started_at"],
                "completed_at" => record["completed_at"],
                "watchers" => record["watchers"],
                "queue_name" => record["queue_name"],
            )
        else
            columns = Pair{String, Any}[
                "status" => record["status"],
                "progress" => record["progress"],
                "result" => record["result"],
                "error" => record["error"],
                "created_at" => record["created_at"],
                "started_at" => record["started_at"],
                "completed_at" => record["completed_at"],
                "queue_name" => record["queue_name"],
            ]
            # `watchers` and `run_id` ride along ONLY for `replace_task!`. Including
            # `watchers` on every save is what made ordinary state transitions clobber grants
            # appended by another process since this one last read the row (#88) — and
            # transitions are far more frequent than appends, so that was the dominant loss
            # path. `run_id` is excluded for a sharper reason: it is the value
            # `try_transition!` fences on, so a state save that carried it would let whichever
            # run wrote last adopt the record's identity and defeat the fence (#108).
            if full_record
                push!(columns, "watchers" => record["watchers"])
                push!(columns, "run_id" => record["run_id"])
            end
            _task_objects(store).filter("id" => task_id).update(columns...)
        end
    catch e
        @warn "PormGWorkerStore: failed to write task" exception=(e, catch_backtrace())
        rethrow()
    end
    return task_info
end

set_task!(store::PormGWorkerStore, task_id::String, task_info::TaskInfo) =
    _write_task!(store, task_id, task_info, false)

replace_task!(store::PormGWorkerStore, task_id::String, task_info::TaskInfo) =
    _write_task!(store, task_id, task_info, true)

# How many attempts the watcher compare-and-set gets before giving up. Contention on one
# task row is bounded by the number of processes appending to it, so this is generous.
const _WATCHER_CAS_ATTEMPTS = 8

# `get_task_info` is the ROW read, which is what a compare-and-set needs: it has to compare
# against the value the UPDATE will match. It used to serve a live in-memory object for a
# running task, whose watchers could already differ from what was stored, so this comment used
# to be a warning rather than a statement of fact (#167).
function add_watcher!(store::PormGWorkerStore, task_id::String, user_id::String)
    for _ in 1:_WATCHER_CAS_ATTEMPTS
        task = get_task_info(store, task_id)
        task === nothing && return false

        if user_id in task.watchers
            return true
        end

        expected = JSON.json(task.watchers)
        updated = JSON.json(vcat(task.watchers, user_id))

        # The `watchers` term in the filter is the *compare* half of the CAS: if another
        # process wrote between our read and this statement, zero rows match and we retry
        # against the value they left. So we can never overwrite an append we did not see.
        matched = _task_objects(store).filter("id" => task_id, "watchers" => expected)
        changed = matched.update("watchers" => updated)

        if changed isa Integer && changed >= 1
            return true
        end
    end

    error("PormGWorkerStore: could not append watcher '$user_id' to task '$task_id' after " *
          "$(_WATCHER_CAS_ATTEMPTS) attempts — either the row is under heavy contention, or its " *
          "`watchers` column is not in the canonical JSON form this store writes")
end

function try_transition!(store::PormGWorkerStore, task_id::String, from, to::TaskStatus;
                         run_id::Union{Nothing, UUIDs.UUID},
                         error::Union{Nothing, String}=nothing,
                         completed_at::Union{Nothing, DateTime}=nothing,
                         started_at::Union{Nothing, DateTime}=nothing,
                         result=UNSUPPLIED,
                         progress::Union{Nothing, Real}=nothing)
    columns = Pair{String, Any}["status" => string(to)]
    error === nothing || push!(columns, "error" => error)
    completed_at === nothing || push!(columns, "completed_at" => completed_at)
    started_at === nothing || push!(columns, "started_at" => started_at)
    # The completing write of a callback's return value. Too deep to read back, it throws before
    # the UPDATE (#344): the run's retry/failure path records it, the same as any other result
    # that cannot be stored.
    result === UNSUPPLIED ||
        push!(columns, "result" => isnothing(result) ? "" : _json_for_storage(result))
    progress === nothing || push!(columns, "progress" => Float64(progress))

    # The status precondition lives in the WHERE clause, so the compare and the write are
    # one statement. Zero rows affected means the task was absent or had already left
    # `from` — and, crucially, that nothing was written.
    #
    # `run_id` joins the same WHERE clause, so "is this still my run?" is answered by the very
    # statement that writes — not by a read the answer could go stale between (#108). `nothing`
    # is the named opt-out and omits the term entirely.
    matched = run_id === nothing ?
        _task_objects(store).filter("id" => task_id,
                                    "status__@in" => [string(s) for s in from]) :
        _task_objects(store).filter("id" => task_id,
                                    "run_id" => string(run_id),
                                    "status__@in" => [string(s) for s in from])
    changed = matched.update(columns...)

    return changed isa Integer && changed >= 1
end

function delete_task!(store::PormGWorkerStore, task_id::String)
    try
        _task_objects(store).filter("id" => task_id).delete()
    catch e
        @warn "PormGWorkerStore: failed to delete task" exception=(e, catch_backtrace())
        rethrow()
    end
    return nothing
end

function cleanup_tasks!(store::PormGWorkerStore, retain_days::Int)
    cutoff = Dates.now(Dates.UTC) - Dates.Day(retain_days)
    try
        total_deleted, _ = _task_objects(store).filter(
            "completed_at__@lte" => cutoff,
            "completed_at__@isnull" => false,
            "status__@in" => string.((COMPLETED, FAILED, CANCELLED)),
        ).delete()
        return total_deleted
    catch e
        @warn "PormGWorkerStore: failed to cleanup old tasks" exception=(e, catch_backtrace())
        return 0
    end
end

"""
Rows an authority could possibly be entitled to, as a **superset**.

This narrows the query; it is not the gate. The exact predicate still runs in Julia
below, so both filters here must be supersets — the post-filter cannot recover a row
SQL dropped, but it can discard an extra one.

`System` fetches everything. An `Owner` fetches two sets, unioned:

- `id__@startswith "<owner>::"` — the owned tasks. `owner_of(id) == u` is equivalent to
  `startswith(id, u * "::")` for any constructible `Owner`, because `u` contains no
  `"::"` and `Owner("")` cannot exist.
- `watchers__@contains` the **JSON-quoted** id — the granted ones, which have no id
  prefix, and every `:global` task, which is watcher-only. Quoting matters: searching
  for `"bob"` with its quotes cannot match `["bobby"]`.

Two Pair-only queries rather than one `Qor`, so the shape stays inside what a
`Pair`-typed query mock can express.

The win is rows fetched and `watchers` blobs JSON-parsed, not index usage: on
PostgreSQL a `LIKE 'x%'` uses the primary-key index only under a C collation or a
`text_pattern_ops` opclass, which `PormG.Dialect.create_index` cannot express. Do not
add an index for this.

**Unpaged listings only.** Two legs merged in Julia are a correct union only while nothing
depends on their order, and a paged listing depends on nothing else. `get_all_tasks` with `after`
or `limit` therefore asks for the same superset as ONE `Qor` query (`_authority_query`) and lets
the database order it. See *Keyset paging* below ([#237](https://github.com/PingoLee/Nitro.jl/issues/237)).
"""
_authority_rows(make_base::Function, ::System) = make_base().list()

function _authority_rows(make_base::Function, authority::Owner)
    # `make_base()` must mint a FRESH queryset per leg. PormG's `filter` accumulates onto
    # the object and returns it (`push!(q.filter, …)`), so filtering one shared base twice
    # ANDs the two legs together — `watched` would become `owned ∩ watched`, and every
    # watcher-only task (all `:global` ones, and every `watchers=` grant) would silently
    # vanish from the listing. That is an intersection where a union is required.
    owned = make_base().filter("id__@startswith" => authority.user_id * TASK_KEY_DELIMITER).list()
    watched = make_base().filter("watchers__@contains" => JSON.json(authority.user_id)).list()

    rows = Any[]
    seen = Set{String}()
    for row in Iterators.flatten((owned, watched))
        # Dedupe on the raw row, before `_from_db_record`: under `:user` scope the owner
        # is also a watcher, so most rows appear in both sets and parsing twice would
        # spend exactly the JSON work this narrowing exists to avoid.
        id = _row_task_id(row)
        id === nothing && continue
        id in seen && continue
        push!(seen, id)
        push!(rows, row)
    end
    return rows
end

# -- Keyset paging (#237) --
#
# The shape `_authority_rows` above does not have: a page is `id > after ORDER BY id LIMIT n`,
# and ALL of it runs in SQL. The database orders and compares under one collation, the column's.
# On an `en_US` PostgreSQL database that is not Julia's codepoint order, so any Julia-side sort or
# merge on a paged path would disagree with the next page's `id > after` and skip rows. That is
# also why the paged Owner listing is ONE `Qor` query rather than `_authority_rows`' two legs.
# Merging two separately-limited legs is a correct union only under an order Julia can reproduce.

function _keyset!(qs, after, limit)
    after === nothing || (qs = qs.filter("id__@gt" => after))
    qs = qs.order_by("id")
    limit === nothing || (qs = qs.limit(limit))
    return qs
end

# Up to `limit` KEPT rows past `after`, in the database's id order. `keep!(out, row)` decides per
# row. A row it drops is made up from past the cursor, so the result is short of `limit` only when
# the query ran out of rows. That is the contract both paged methods publish, and a caller reads a
# short page as the end. With `limit === nothing` this is one unbounded query past `after`.
function _keyset_collect!(keep!::Function, out::AbstractVector, query::Function, after, limit)
    cursor = after
    while true
        want = limit === nothing ? nothing : limit - length(out)
        rows = _keyset!(query(), cursor, want).list()
        for row in rows
            keep!(out, row)
        end
        (want === nothing || length(rows) < want || length(out) >= limit) && return out
        cursor = _row_task_id(last(rows))
    end
end

# The same superset `_authority_rows` fetches, as one query.
_authority_query(make_base::Function, ::System) = make_base()
_authority_query(make_base::Function, authority::Owner) = make_base().filter(PormG.Qor(
    "id__@startswith" => authority.user_id * TASK_KEY_DELIMITER,
    "watchers__@contains" => JSON.json(authority.user_id),
))

function get_all_tasks(store::PormGWorkerStore, authority::TaskAuthority;
                       status::Union{Nothing, TaskStatus}=nothing, queue_name::Union{Nothing, String}=nothing,
                       after::Union{Nothing, String}=nothing, limit::Union{Nothing, Int}=nothing)
    # A factory, not a queryset: see `_authority_rows` on why each leg needs its own.
    make_base = function()
        qs = _task_objects(store)
        if status !== nothing
            qs = qs.filter("status" => string(status))
        end
        if queue_name !== nothing
            qs = qs.filter("queue_name" => queue_name)
        end
        return qs
    end

    # Both paths RETHROW a failed read. A caller reads an empty listing as "no tasks" and an empty
    # page as "no more rows", so a swallowed error would pass for either. The unpaged path used to
    # swallow into `TaskInfo[]`, so one undecodable row emptied the whole listing (#267). A row
    # that does not decode is now skipped on its own by `_listed_task`, and a read failure
    # propagates. Both warnings carry the exception TYPE only: see `_listed_task` on why the
    # message is not safe to log.
    if _check_page(after, limit)
        try
            return _keyset_collect!(TaskInfo[], () -> _authority_query(make_base, authority), after, limit) do out, row
                task_info = _listed_task(row)
                task_info === nothing && return
                # The gate, after the fetch as always. Rows it drops, and rows that did not
                # decode, are made up by `_keyset_collect!`, so a page is short only when the
                # listing is exhausted.
                _is_authorized(authority, task_info) && push!(out, task_info)
            end
        catch e
            @warn "PormGWorkerStore: failed to list a page of tasks" exception_type=typeof(e)
            rethrow()
        end
    end

    try
        # Durable rows only. Overlaying live progress onto them is `WorkerRuntime`'s job
        # and is now done for every backend rather than this one (#167).
        tasks = TaskInfo[]
        for row in _authority_rows(make_base, authority)
            task_info = _listed_task(row)
            task_info === nothing && continue
            # The gate. `_authority_rows` above only narrowed what was fetched.
            _is_authorized(authority, task_info) || continue
            push!(tasks, task_info)
        end
        return tasks
    catch e
        @warn "PormGWorkerStore: failed to list tasks" exception_type=typeof(e)
        rethrow()
    end
end

# One listed row -> its `TaskInfo`, or `nothing` for a row that does not decode (#267).
#
# Skipped, so one hand-edited or app-written row costs the listing that row and not every row.
# That matches how `_running_ref_from_row` treats an unfenceable one. A skipped row is dropped
# BEFORE the authority gate, which cannot be evaluated without a parsed watcher list, so it fails
# closed. Schema drift is checked outside the catch: it is table-wide, never a single bad row.
#
# The warning carries the id and the exception TYPE, never the message. `_parse_stored_json`
# already keeps the blob out of the JSON failures, so this is the second guarantee: it also covers
# whatever else `_from_db_record` can throw.
#
# What a per-row skip cannot tell apart is one bad row and a SYSTEMIC decode failure. A driver
# value type `_parse_db_datetime` rejects (the #239 class), or a PormG change that breaks every
# row, skips them all, and the listing is empty again with one warning per row. Those warnings,
# all naming the same exception type, are the signal. It also warns on every listing call until
# the row is repaired, so a polling UI repeats the line.
function _listed_task(row)::Union{Nothing, TaskInfo}
    id = _row_task_id(row)
    _check_run_id_column(row, something(id, "<no id>"))
    try
        return _from_db_record(row)
    catch e
        # Same #254 line as `_parse_stored_json`, which now rethrows these: skipping the row here
        # would swallow them again one frame up (#344).
        is_unrecoverable(e) && rethrow()
        @warn "PormGWorkerStore: skipping a task row that does not decode" task_id=id exception_type=typeof(e)
        return nothing
    end
end

# One projected row -> a ref, or `nothing` for a row that cannot be fenced. Same symbol-or-string
# key handling as `_from_db_record`, and deliberately none of its parsing.
function _running_ref_from_row(row)
    get_val = (key_sym, key_str) -> haskey(row, key_sym) ? row[key_sym] : row[key_str]
    id = string(get_val(:id, "id"))
    run_id = tryparse(UUIDs.UUID, string(get_val(:run_id, "run_id")))
    if run_id === nothing
        # Skipped, not guessed at. A fenced transition needs the row's real run id, and inventing
        # one is the #108 defect `_from_db_record` refuses loudly. Ids only -- never row contents.
        #
        # Skipped FOREVER, by decision (#267): retention never retires it and the key stays taken
        # until an operator repairs the row. Only a hand edit or an app-side write reaches here,
        # since pre-#108 rows were backfilled with the nil UUID, which parses. An unfenced
        # (`run_id = nothing`) FAILED write was considered and declined. `lock_tasks` is
        # process-local, so if another process has already failed the row and the key was re-run,
        # a stale unfenced write would fail the live successor, which is #108's own shape.
        @warn "PormGWorkerStore: skipping a RUNNING task whose run_id does not parse; zombie recovery cannot fence it" task_id=id
        return nothing
    end
    # An unreadable timestamp must not fail the whole scan: `list_running_task_refs` rethrows, so
    # one hand-edited row would stop the sweep at its page on every boot, which is #236's poison
    # pill again. Read as "no start time", the case the sweep already treats as always eligible.
    started_at = try
        _parse_optional_db_datetime(get_val(:started_at, "started_at"))
    catch e
        e isa InterruptException && rethrow()
        @warn "PormGWorkerStore: a RUNNING task's started_at does not parse; treating it as unstamped" task_id=id
        nothing
    end
    return RunningTaskRef((id, run_id, started_at))
end

# Zombie recovery's scan (#236): a projection of exactly the three columns it reads. No row's
# `result` or `watchers` blob is fetched, let alone parsed, and `_from_db_record` is never called.
# Its full parse, behind what was then `get_all_tasks`'s swallow-into-empty, is what let one
# malformed row blind the whole sweep. The listing now skips such a row (#267), but a skipped
# row is still a zombie it cannot see, so the sweep keeps its own projection.
#
# Logs and RETHROWS, like `get_task_info` and, since #267, the listing above. An empty result here
# reads as "nothing to recover", so a swallowed read error would be indistinguishable from a
# clean sweep, which is the silence #238 is about.
#
# Paged by keyset like the listing (#237). A skipped row is made up from past the cursor by
# `_keyset_collect!`, so recovery never mistakes a page an unfenceable row shortened for the end.
function list_running_task_refs(store::PormGWorkerStore; after::Union{Nothing, String}=nothing,
                                limit::Union{Nothing, Int}=nothing)
    _check_page(after, limit)
    query = () -> _task_objects(store).filter("status" => string(RUNNING)).values("id", "run_id", "started_at")
    try
        return _keyset_collect!(RunningTaskRef[], query, after, limit) do refs, row
            ref = _running_ref_from_row(row)
            ref === nothing || push!(refs, ref)
        end
    catch e
        @warn "PormGWorkerStore: failed to list running tasks" exception=(e, catch_backtrace())
        rethrow()
    end
end

function get_queue_authorizer(store::PormGWorkerStore)
    return store.queue_authorizer[]
end

function set_queue_authorizer!(store::PormGWorkerStore, authorizer)
    store.queue_authorizer[] = authorizer
    return authorizer
end

function get_error_redactor(store::PormGWorkerStore)
    return store.error_redactor[]
end

function set_error_redactor!(store::PormGWorkerStore, redactor)
    store.error_redactor[] = redactor
    return redactor
end

function get_watch_authorizer(store::PormGWorkerStore)
    return store.watch_authorizer[]
end

function set_watch_authorizer!(store::PormGWorkerStore, authorizer)
    store.watch_authorizer[] = authorizer
    return authorizer
end

function lock_tasks(callback::Function, store::PormGWorkerStore)
    return lock(store.task_lock) do
        callback()
    end
end

# ============================================================================
# SECTION 8: Table Bootstrap & Convenience Constructor
# ============================================================================

"""
The `run_id` a pre-#108 row is backfilled with: the nil UUID.

Portable as a literal `DEFAULT` on every dialect, and semantically exact — a row written before
run ids existed belongs to no live run. `uuid4()` never produces the nil UUID, so no running
task can ever hold it, and a legacy row therefore cannot be adopted by a live run's fence.
"""
const _LEGACY_RUN_ID = "00000000-0000-0000-0000-000000000000"

"""
    _ensure_run_id_column!(conn)

Add the `run_id` column to an existing `nitro_task` table, idempotently.

`CREATE TABLE IF NOT EXISTS` cannot add a column to a table that already exists, and **every**
read path goes through `_from_db_record`, so a table missing this column is unreadable rather
than merely degraded — `get_task_info` and `get_all_tasks` both stop working. Bootstrapping the
schema on boot is what this file already does for the table and its indexes, so extending that
to one `ALTER` keeps the upgrade automatic instead of silently fatal
([#108](https://github.com/PingoLee/Nitro.jl/issues/108)).

Idempotency is established by **proving the column is there**, not by matching the error text of
a duplicate-column failure: SQLite says "duplicate column name", Postgres "column ... already
exists" (SQLSTATE 42701) and MySQL error 1060, and a `catch`-all broad enough to cover the three
would also swallow a genuine failure. So: attempt the `ALTER`; if it throws, `SELECT` the column.
Success means it already existed and the error was benign; failure rethrows the original.
"""
function _ensure_run_id_column!(conn)
    try
        PormG.ConnectionPool.fetch(conn,
            "ALTER TABLE \"nitro_task\" ADD COLUMN \"run_id\" VARCHAR(36) NOT NULL DEFAULT '$(_LEGACY_RUN_ID)'")
    catch e
        try
            PormG.ConnectionPool.fetch(conn, "SELECT \"run_id\" FROM \"nitro_task\" LIMIT 1")
        catch
            rethrow(e)
        end
    end
    return nothing
end

"""
    _ensure_task_table!(conn, model)

Execute `CREATE TABLE IF NOT EXISTS` and index creations for the `nitro_task` table.
"""
function _ensure_task_table!(conn, model)
    create_table_sql = PormG.Dialect.create_table(conn, model)
    PormG.ConnectionPool.fetch(conn, create_table_sql)

    # A table created before #108 does not get `run_id` from the statement above.
    _ensure_run_id_column!(conn)

    create_index_sql1 = PormG.Dialect.create_index(
        conn,
        "\"nitro_task_started_at_idx\"",
        "\"nitro_task\"",
        ["\"started_at\""],
    )
    PormG.ConnectionPool.fetch(conn, create_index_sql1)

    create_index_sql2 = PormG.Dialect.create_index(
        conn,
        "\"nitro_task_completed_at_idx\"",
        "\"nitro_task\"",
        ["\"completed_at\""],
    )
    PormG.ConnectionPool.fetch(conn, create_index_sql2)
    return nothing
end

# Deliberately no docstring -- see the note on `pormg_nitro_session` above; `src/exts.jl` owns it.
function pormg_nitro_worker(; db_key::String="db")
    model = task_model(db_key)
    if isnothing(model)
        error("pormg_nitro_worker: PormG.Models is not available. Ensure PormG is properly loaded.")
    end
    conn = PormG.connection(key=db_key)
    _ensure_task_table!(conn, model)
    return PormGWorkerStore(model=model, db_key=db_key)
end

# ============================================================================
# SECTION 9: Environment bridge
# ============================================================================

function sync_pormg_env!(; force::Bool = false)::Union{String, Nothing}
    # Blank counts as UNSET, matching how `current_env` treats `NITRO_ENV` -- and here it
    # matters more, because PormG's `_effective_env` returns `""` on a bare `haskey` and then
    # looks up a `""` section in connection.yml. Honouring an empty `PORMG_ENV` as if it were
    # a deliberate choice would make the bridge worse than not existing.
    current = get(ENV, "PORMG_ENV", nothing)
    blank = current !== nothing && isempty(strip(current))
    if force || current === nothing || blank
        # Only an environment someone SET is published (#331). Nitro's `"dev"` fallback is not
        # a choice, and published as one it outranked a choice someone did make: `default_env:`
        # in connection.yml sits below `PORMG_ENV` in PormG's precedence, so a prod box relying
        # on it silently connected to dev. With neither `NITRO_ENV` nor `GENIE_ENV` set, PormG
        # resolves its own environment -- which is also why `force` then has nothing to write.
        #
        # Resolved only here, as before: a typo in `NITRO_ENV` does not throw while a set
        # `PORMG_ENV` means there is nothing to publish.
        env = Nitro.Core.Environment._explicit_env()
        if env !== nothing
            ENV["PORMG_ENV"] = env
        elseif blank
            # Nothing to publish over the blank, and left in place PormG would read it as a
            # `""` environment. Removing it is what "blank counts as unset" means to PormG.
            delete!(ENV, "PORMG_ENV")
        end
    end
    return get(ENV, "PORMG_ENV", nothing)
end

# ============================================================================
# SECTION 10: Initialization
# ============================================================================

function __init__()
    # Register the password field hook with PormG when the normalize_field_value
    # seam is available (Phase 3 upstream dependency).
    # Until Phase 3 lands in PormG, this is a no-op skeleton.
    if isdefined(PormG, :register_field_hook)
        PormG.register_field_hook(:PasswordField, :auto_hash, hash_password_field)
    end

    # Tell PormG to skip Nitro's own infrastructure tables (`nitro_session`, `nitro_task`)
    # during schema introspection / makemigrations, so a consumer's `import_models` never
    # reverse-engineers them into user models. The knowledge lives here — next to the model
    # definitions above — rather than being hardcoded into PormG itself.
    if isdefined(PormG, :register_ignore_tables!)
        PormG.register_ignore_tables!(["nitro_session", "nitro_task"])
    end

    # There is no model priming here any more. Both models carry a `connect_key` since #202,
    # and the key is only known when a store is constructed -- so a model built at load time
    # could not be bound, and one process-wide model could not serve two stores on different
    # keys. `session_model(db_key)` / `task_model(db_key)` build a bound model per store
    # instead, which is a handful of allocations about twice per application.

    # Bridge the environment set in `NITRO_ENV`/`GENIE_ENV` to PormG's, so an app can call
    # `PormG.Configuration.load_many([...])` with no `env=` and get the environment Nitro
    # resolved (#55). A DEFAULT, never a force: a pre-set `PORMG_ENV` and an explicit `env=`
    # both still win -- and with neither variable set nothing is published, so PormG's own
    # `default_env:` still decides (#331).
    #
    # Guarded, unlike the registration above, because this is the only side effect here that
    # ESCAPES THE MODULE: it mutates the OS process environment, which is inherited by any
    # subprocess. The reason is NOT cache poisoning -- `ENV` is not serialized into a `.ji`,
    # and PormG reads `PORMG_ENV` only inside function bodies. It is that a compile-only
    # worker must not act on the world (the module-body/`__init__` non-negotiable), and that
    # a package precompiled with `PORMG_ENV` seeded from whatever the build machine exported
    # is a build whose behaviour depended on the builder's shell.
    if ccall(:jl_generating_output, Cint, ()) == 0
        try
            sync_pormg_env!()
        catch err
            # Warn, never throw. An `__init__` that throws makes `using PormG` an `InitError`,
            # so a typo in a shell variable would render the application -- and the REPL
            # session you would diagnose it from -- unloadable. The authoritative, fatal check
            # lives in `serve()`, which is where the process commits to being a server.
            @warn "Nitro could not bridge its environment to PormG: " *
                  sprint(showerror, err) *
                  "\n`PORMG_ENV` is left as it was, so PormG falls back to its own " *
                  "resolution (`env=` kwarg, then `PORMG_ENV`, then `default_env:` in " *
                  "connection.yml, then \"dev\").\nFix the variable and call " *
                  "`sync_pormg_env!()`, or pass `env=` explicitly."
        end
    end
end

end # module NitroPormGExt
