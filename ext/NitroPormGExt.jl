module NitroPormGExt

using Nitro
using PormG
using Dates
using JSON
using UUIDs

import Nitro.Auth: make_password, check_password, password_needs_upgrade, is_password_usable
import Nitro.Core.Types: AbstractSessionStore, SessionPayload, get_session, set_session!, delete_session!, cleanup_expired_sessions!
import Nitro.Core.Cookies: storesession!, prunesessions!
import Nitro: pormg_nitro_session

import Nitro.Workers: AbstractWorkerStore, TaskInfo, TaskStatus, TaskOptions, SequentialQueue, CleanupScheduler,
    PENDING, RUNNING, COMPLETED, FAILED, CANCELLED,
    TaskAuthority, Owner, System, UNSUPPLIED, owner_of, _is_authorized, TASK_KEY_DELIMITER,
    get_task_info, reload_task, set_task!, replace_task!, add_watcher!, try_transition!,
    delete_task!, cleanup_tasks!, get_all_tasks,
    get_active_task, register_active_task!, deregister_active_task!,
    get_active_task_info, register_active_task_info!, deregister_active_task_info!,
    get_queue_authorizer, set_queue_authorizer!,
    get_watch_authorizer, set_watch_authorizer!,
    get_sequential_queues, get_queue_lock, get_cleanup_scheduler, lock_tasks
import Nitro: pormg_nitro_worker

export PormGWorkerStore, pormg_nitro_worker

# ============================================================================
# SECTION 1: Password Field Hooks (existing)
# ============================================================================

"""
    hash_password_field(value) -> value

Hook for PormG's `normalize_field_value` on `PasswordField` with `auto_hash=true`.

- If `value` is a `String` that does not look like an already-encoded hash
  (checked via `is_password_usable`), hashes it with `make_password`.
- If `value` is already an encoded hash, passes it through unchanged.
- If `value` is not a `String` (e.g. `nothing`, numeric, etc.), passes it through
  untouched — type validation is PormG's responsibility, not Nitro's.
"""
function hash_password_field(value)
    value isa AbstractString || return value
    is_password_usable(value) && return value
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
PormG model for the `nitro_session` table.

Columns:
- `session_key`  — VARCHAR(40), primary key (the session ID)
- `session_data` — TEXT (JSON-serialized session payload)
- `expires_at`   — TIMESTAMPTZ, indexed for efficient cleanup
"""
function _define_session_model()
    if isdefined(PormG, :Models)
        return PormG.Models.Model("nitro_session",
            session_key  = PormG.Models.CharField(max_length=40, primary_key=true),
            session_data = PormG.Models.TextField(default="{}"),
            expires_at   = PormG.Models.DateTimeField(db_index=true),
        )
    end
    return nothing
end

# Lazily initialised after __init__
const _SESSION_MODEL = Ref{Any}(nothing)

function session_model()
    if isnothing(_SESSION_MODEL[])
        _SESSION_MODEL[] = _define_session_model()
    end
    return _SESSION_MODEL[]
end

# ============================================================================
# SECTION 3: PormGSessionStore
# ============================================================================

"""
    PormGSessionStore(; table_name="nitro_session")

A PormG-backed session store that implements Nitro's `AbstractSessionStore{String, Dict{String,Any}}`.

Sessions are stored as JSON text in the database and expire at a fixed timestamp
from the last write (no sliding expiry).

## Usage

```julia
using Nitro, PormG

store = PormGSessionStore()
serve(middleware=[SessionMiddleware(store=store, secure=false)])
```
"""
struct PormGSessionStore <: AbstractSessionStore{String, Dict{String,Any}}
    model::Any  # PormG Model reference
end

function PormGSessionStore(; model=nothing)
    m = isnothing(model) ? session_model() : model
    if isnothing(m)
        error("PormGSessionStore requires PormG.Models to be available. Ensure PormG is properly loaded.")
    end
    return PormGSessionStore(m)
end

# -- Serialization helpers --

function _serialize_session(data::Dict{String,Any})::String
    return JSON.json(data)
end

function _deserialize_session(raw::AbstractString)::Dict{String,Any}
    parsed = JSON.parse(raw)
    return convert(Dict{String,Any}, parsed)
end

# -- Store interface implementation --

function Base.get(store::PormGSessionStore, session_id::String, default)
    m = store.model
    try
        result = m.objects.filter("session_key" => session_id).first()
        if isnothing(result)
            return default
        end
        expires_at = _parse_db_datetime(result[:expires_at])
        data = _deserialize_session(result[:session_data])
        return SessionPayload(data, expires_at)
    catch e
        @warn "PormGSessionStore: failed to read session" exception=(e, catch_backtrace())
        return default
    end
end

function _parse_db_datetime(val)::DateTime
    val isa DateTime && return val
    # PormG returns ZonedDateTime from PostgreSQL TIMESTAMPTZ and
    # from SQLite when the stored value contains a timezone offset.
    if val isa Dates.AbstractDateTime
        return DateTime(Dates.year(val), Dates.month(val), Dates.day(val),
                        Dates.hour(val), Dates.minute(val), Dates.second(val))
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
    # Strip timezone suffix and retry
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
        if payload.expires <= Dates.now(Dates.UTC)
            return nothing
        end
        return copy(payload.data)
    end
    return payload
end

function set_session!(store::PormGSessionStore, session_id::String, data::Dict{String,Any}; ttl::Int=3600)
    m = store.model
    expires_at = Dates.now(Dates.UTC) + Dates.Second(ttl)
    serialized = _serialize_session(data)

    try
        existing = m.objects.filter("session_key" => session_id).first()
        if isnothing(existing)
            m.objects.create(
                "session_key"  => session_id,
                "session_data" => serialized,
                "expires_at"   => expires_at,
            )
        else
            m.objects.filter("session_key" => session_id).update(
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

function delete_session!(store::PormGSessionStore, session_id::String)
    m = store.model
    try
        m.objects.filter("session_key" => session_id).delete()
    catch e
        @warn "PormGSessionStore: failed to delete session" exception=(e, catch_backtrace())
        rethrow()
    end
    return nothing
end

function cleanup_expired_sessions!(store::PormGSessionStore)
    m = store.model
    now_utc = Dates.now(Dates.UTC)
    try
        m.objects.filter("expires_at__@lte" => now_utc).delete()
    catch e
        @warn "PormGSessionStore: failed to cleanup expired sessions" exception=(e, catch_backtrace())
    end
    return nothing
end

function storesession!(store::PormGSessionStore, key::String, value::Dict{String,Any}; ttl::Int=3600)
    return set_session!(store, key, value; ttl=ttl)
end

function prunesessions!(store::PormGSessionStore)
    return cleanup_expired_sessions!(store)
end

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

"""
    pormg_nitro_session(; db_key="db") -> PormGSessionStore

One-call setup for PormG-backed sessions.  Creates the `nitro_session` table
(if it doesn't exist), creates the expiry index, and returns a ready-to-use
`PormGSessionStore`.

## Example
```julia
using Nitro, PormG
PormG.Configuration.load("db")

store = pormg_nitro_session()
serve(middleware=[SessionMiddleware(store=store)])
```
"""
function pormg_nitro_session(; db_key::String="db")
    model = session_model()
    if isnothing(model)
        error("pormg_nitro_session: PormG.Models is not available. Ensure PormG is properly loaded.")
    end
    conn = PormG.connection(key=db_key)
    _ensure_session_table!(conn, model)
    return PormGSessionStore(model=model)
end

# ============================================================================
# SECTION 6: Task Model
# ============================================================================

"""
PormG model for the `nitro_task` table.

Columns:
- `id`           — VARCHAR(255), primary key. Holds the *scoped* task id, which under
                   the default `:user` scope is `"<user_id>::<task_key>"`, so it needs
                   room for both halves. `_ensure_task_table!` only issues
                   `CREATE TABLE IF NOT EXISTS`: a database created before this column
                   was widened keeps its old width and needs a manual `ALTER TABLE`
                   (SQLite ignores `VARCHAR` lengths, so only Postgres/MySQL care).
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
function _define_task_model()
    if isdefined(PormG, :Models)
        return PormG.Models.Model("nitro_task",
            id           = PormG.Models.CharField(max_length=255, primary_key=true),
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
    end
    return nothing
end

# Lazily initialised after __init__
const _TASK_MODEL = Ref{Any}(nothing)

function task_model()
    if isnothing(_TASK_MODEL[])
        _TASK_MODEL[] = _define_task_model()
    end
    return _TASK_MODEL[]
end

# ============================================================================
# SECTION 7: PormGWorkerStore
# ============================================================================

"""
    PormGWorkerStore(; model=nothing)

A PormG-backed worker store that implements Nitro's `AbstractWorkerStore`.
"""
struct PormGWorkerStore <: AbstractWorkerStore
    model::Any
    db_key::String
    active_tasks::Dict{String, Task}
    active_task_infos::Dict{String, TaskInfo}
    active_lock::ReentrantLock
    task_lock::ReentrantLock
    sequential_queues::Dict{String, SequentialQueue}
    queue_lock::ReentrantLock
    cleanup_scheduler::Ref{Union{Nothing, CleanupScheduler}}
    queue_authorizer::Ref{Any}
    watch_authorizer::Ref{Any}
end

function PormGWorkerStore(; model=nothing, db_key::String="db")
    m = isnothing(model) ? task_model() : model
    if isnothing(m)
        error("PormGWorkerStore requires PormG.Models to be available. Ensure PormG is properly loaded.")
    end
    return PormGWorkerStore(
        m,
        db_key,
        Dict{String, Task}(),
        Dict{String, TaskInfo}(),
        ReentrantLock(),
        ReentrantLock(),
        Dict{String, SequentialQueue}(),
        ReentrantLock(),
        Ref{Union{Nothing, CleanupScheduler}}(nothing),
        Ref{Any}(nothing),
        Ref{Any}(nothing),
    )
end

# Route every task query to the store's configured connection. PormG's query
# manager always supports `.db(key)`, so we call it directly rather than
# silently falling back to the model's default connection (which would write
# tasks to the wrong database).
_task_objects(store::PormGWorkerStore) = store.model.objects.db(store.db_key)

# -- Serialization Helpers --

function _to_db_record(task::TaskInfo)
    result_str = isnothing(task.result) ? "" : JSON.json(task.result)
    watchers_str = JSON.json(task.watchers)
    return Dict{String, Any}(
        "id" => task.id,
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

function _from_db_record(row)::TaskInfo
    # Support both symbol lookup (PormG DB rows) and string dict (for mocks)
    get_val = (key_sym, key_str) -> haskey(row, key_sym) ? row[key_sym] : row[key_str]

    id = string(get_val(:id, "id"))
    task = TaskInfo(id)

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
    task.result = isempty(result_str) ? nothing : JSON.parse(result_str)

    err_str = string(get_val(:error, "error"))
    task.error = isempty(err_str) ? nothing : err_str

    task.created_at = _parse_db_datetime(get_val(:created_at, "created_at"))

    task.started_at = _parse_optional_db_datetime(get_val(:started_at, "started_at"))

    task.completed_at = _parse_optional_db_datetime(get_val(:completed_at, "completed_at"))

    watchers_str = string(get_val(:watchers, "watchers"))
    task.watchers = isempty(watchers_str) ? String[] : convert(Vector{String}, JSON.parse(watchers_str))

    qn_str = string(get_val(:queue_name, "queue_name"))
    task.queue_name = isempty(qn_str) ? nothing : qn_str

    return task
end

# -- AbstractWorkerStore Interface Methods --

function get_task_info(store::PormGWorkerStore, task_id::String)
    # Return the live in-memory info for an active task so callers see fresh
    # progress (the field is atomic, so concurrent reads are race-free). We do
    # NOT write `sys_task` back onto this shared object: nothing reads that field
    # (cancellation resolves the running task via `get_active_task`), and writing
    # it from a reader thread would mutate the worker's own task object.
    active_info = get_active_task_info(store, task_id)
    if active_info !== nothing
        return active_info
    end

    # Log and rethrow, matching `set_task!`. Returning `nothing` here would make a
    # failed read indistinguishable from an absent row, and `_register_or_watch!`
    # reads absence as "this key is free" — so one swallowed connection blip would
    # skip the cross-user authorization gate and let a caller take over someone
    # else's task. It also swallowed `_from_db_record`'s deliberate schema-drift
    # error, defeating the check that raises it.
    try
        result = _task_objects(store).filter("id" => task_id).first()
        if isnothing(result)
            return nothing
        end
        return _from_db_record(result)
    catch e
        @warn "PormGWorkerStore: failed to read task" exception=(e, catch_backtrace())
        rethrow()
    end
end

function _write_task!(store::PormGWorkerStore, task_id::String, task_info::TaskInfo, replace_watchers::Bool)
    record = _to_db_record(task_info)
    try
        existing = _task_objects(store).filter("id" => task_id).first()
        if isnothing(existing)
            # A fresh row has no watchers to preserve, so the create branch always
            # writes them whichever entry point we came through.
            _task_objects(store).create(
                "id" => record["id"],
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
            # `watchers` rides along ONLY for `replace_task!`. Including it on every
            # save is what made ordinary state transitions clobber grants appended by
            # another process since this one last read the row (#88) — and transitions
            # are far more frequent than appends, so that was the dominant loss path.
            replace_watchers && push!(columns, "watchers" => record["watchers"])
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

# Read the ROW, never the live in-memory object. `get_task_info` serves the live
# `active_task_info` for a running task, whose watchers may already differ from what is
# stored — and a compare-and-set has to compare against the value the UPDATE will match.
function _read_db_task(store::PormGWorkerStore, task_id::String)
    row = _task_objects(store).filter("id" => task_id).first()
    return isnothing(row) ? nothing : _from_db_record(row)
end

# Keep a running task's live object in step with a grant written to the row. Without
# this, `get_task_info` and `get_all_tasks` would serve the live object and the new
# watcher would stay invisible until the task terminated.
function _sync_live_watcher!(store::PormGWorkerStore, task_id::String, user_id::String)
    lock(store.active_lock) do
        live = Base.get(store.active_task_infos, task_id, nothing)
        if live !== nothing && !(user_id in live.watchers)
            push!(live.watchers, user_id)
        end
    end
    return nothing
end

function add_watcher!(store::PormGWorkerStore, task_id::String, user_id::String)
    for _ in 1:_WATCHER_CAS_ATTEMPTS
        task = _read_db_task(store, task_id)
        task === nothing && return false

        if user_id in task.watchers
            _sync_live_watcher!(store, task_id, user_id)
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
            # Durable record first: a crash between the two leaves the row correct, and
            # the row is what `get_all_tasks` reads watchers from.
            _sync_live_watcher!(store, task_id, user_id)
            return true
        end
    end

    error("PormGWorkerStore: could not append watcher '$user_id' to task '$task_id' after " *
          "$(_WATCHER_CAS_ATTEMPTS) attempts — either the row is under heavy contention, or its " *
          "`watchers` column is not in the canonical JSON form this store writes")
end

reload_task(store::PormGWorkerStore, task_id::String) = _read_db_task(store, task_id)

function try_transition!(store::PormGWorkerStore, task_id::String, from, to::TaskStatus;
                         error::Union{Nothing, String}=nothing,
                         completed_at::Union{Nothing, DateTime}=nothing,
                         result=UNSUPPLIED,
                         progress::Union{Nothing, Real}=nothing)
    columns = Pair{String, Any}["status" => string(to)]
    error === nothing || push!(columns, "error" => error)
    completed_at === nothing || push!(columns, "completed_at" => completed_at)
    result === UNSUPPLIED ||
        push!(columns, "result" => isnothing(result) ? "" : JSON.json(result))
    progress === nothing || push!(columns, "progress" => Float64(progress))

    # The status precondition lives in the WHERE clause, so the compare and the write are
    # one statement. Zero rows affected means the task was absent or had already left
    # `from` — and, crucially, that nothing was written.
    matched = _task_objects(store).filter("id" => task_id, "status__@in" => [string(s) for s in from])
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

- `id__startswith "<owner>::"` — the owned tasks. `owner_of(id) == u` is equivalent to
  `startswith(id, u * "::")` for any constructible `Owner`, because `u` contains no
  `"::"` and `Owner("")` cannot exist.
- `watchers__contains` the **JSON-quoted** id — the granted ones, which have no id
  prefix, and every `:global` task, which is watcher-only. Quoting matters: searching
  for `"bob"` with its quotes cannot match `["bobby"]`.

Two Pair-only queries rather than one `Qor`, so the shape stays inside what a
`Pair`-typed query mock can express.

The win is rows fetched and `watchers` blobs JSON-parsed, not index usage: on
PostgreSQL a `LIKE 'x%'` uses the primary-key index only under a C collation or a
`text_pattern_ops` opclass, which `PormG.Dialect.create_index` cannot express. Do not
add an index for this.
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

function get_all_tasks(store::PormGWorkerStore, authority::TaskAuthority; status::Union{Nothing, TaskStatus}=nothing, queue_name::Union{Nothing, String}=nothing)
    try
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

        # Snapshot the live in-memory infos so running tasks report fresh
        # progress/status instead of the last value flushed to the database
        # (the worker only writes to the DB at RUNNING-start and on completion).
        active = lock(store.active_lock) do
            copy(store.active_task_infos)
        end

        tasks = TaskInfo[]
        for row in _authority_rows(make_base, authority)
            task_info = _from_db_record(row)
            live = get(active, task_info.id, nothing)
            if live !== nothing
                # Overlay volatile fields only; keep the DB-derived object so
                # we never leak the running `sys_task` into serialized output.
                task_info.status = live.status
                @atomic task_info.progress = live.progress
                task_info.result = live.result
                task_info.error = live.error
                task_info.started_at = live.started_at
                task_info.completed_at = live.completed_at
            end
            # The gate. `_authority_rows` above only narrowed what was fetched; note the
            # overlay has already run, so a live task cannot slip past this.
            _is_authorized(authority, task_info) || continue
            push!(tasks, task_info)
        end
        return tasks
    catch e
        @warn "PormGWorkerStore: failed to list tasks" exception=(e, catch_backtrace())
        return TaskInfo[]
    end
end

function get_active_task(store::PormGWorkerStore, task_id::String)
    lock(store.active_lock) do
        return get(store.active_tasks, task_id, nothing)
    end
end

function register_active_task!(store::PormGWorkerStore, task_id::String, task::Task)
    lock(store.active_lock) do
        store.active_tasks[task_id] = task
    end
    return task
end

function get_active_task_info(store::PormGWorkerStore, task_id::String)
    lock(store.active_lock) do
        return get(store.active_task_infos, task_id, nothing)
    end
end

function register_active_task_info!(store::PormGWorkerStore, task_id::String, task_info::TaskInfo)
    lock(store.active_lock) do
        store.active_task_infos[task_id] = task_info
    end
    return task_info
end

function deregister_active_task!(store::PormGWorkerStore, task_id::String)
    lock(store.active_lock) do
        delete!(store.active_tasks, task_id)
    end
    return nothing
end

function deregister_active_task_info!(store::PormGWorkerStore, task_id::String)
    lock(store.active_lock) do
        delete!(store.active_task_infos, task_id)
    end
    return nothing
end

function get_queue_authorizer(store::PormGWorkerStore)
    return store.queue_authorizer[]
end

function set_queue_authorizer!(store::PormGWorkerStore, authorizer)
    store.queue_authorizer[] = authorizer
    return authorizer
end

function get_watch_authorizer(store::PormGWorkerStore)
    return store.watch_authorizer[]
end

function set_watch_authorizer!(store::PormGWorkerStore, authorizer)
    store.watch_authorizer[] = authorizer
    return authorizer
end

function get_sequential_queues(store::PormGWorkerStore)
    return store.sequential_queues
end

function get_queue_lock(store::PormGWorkerStore)
    return store.queue_lock
end

function get_cleanup_scheduler(store::PormGWorkerStore)
    return store.cleanup_scheduler
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
    _ensure_task_table!(conn, model)

Execute `CREATE TABLE IF NOT EXISTS` and index creations for the `nitro_task` table.
"""
function _ensure_task_table!(conn, model)
    create_table_sql = PormG.Dialect.create_table(conn, model)
    PormG.ConnectionPool.fetch(conn, create_table_sql)

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

"""
    pormg_nitro_worker(; db_key="db") -> PormGWorkerStore

One-call setup for PormG-backed workers. Creates the `nitro_task` table (if it doesn't exist),
creates indexes, and returns a ready-to-use `PormGWorkerStore`.
"""
function pormg_nitro_worker(; db_key::String="db")
    model = task_model()
    if isnothing(model)
        error("pormg_nitro_worker: PormG.Models is not available. Ensure PormG is properly loaded.")
    end
    conn = PormG.connection(key=db_key)
    _ensure_task_table!(conn, model)
    return PormGWorkerStore(model=model, db_key=db_key)
end

# ============================================================================
# SECTION 9: Initialization
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

    # Pre-initialize the models so they're ready when needed
    _SESSION_MODEL[] = _define_session_model()
    _TASK_MODEL[] = _define_task_model()
end

end # module NitroPormGExt
