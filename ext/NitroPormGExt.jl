module NitroPormGExt

using Nitro
using PormG
using Dates
using JSON
using UUIDs

import Nitro.Auth: make_password, check_password, password_needs_upgrade
import Nitro.Core.Types: AbstractSessionStore, SessionPayload, get_session, set_session!, update_session!, rotate_session!, delete_session!, cleanup_expired_sessions!, session_store_full, is_expired, Nullable
using Nitro.Core.Types: _store_call
import Nitro.Core.Cookies: storesession!, prunesessions!
import Nitro: pormg_nitro_session, sync_pormg_env!
# Stored JSON is read through the same depth bound as request JSON, and written only when it can
# be read back (#344). `is_unrecoverable` is the #254 catch policy every request-path site uses.
import Nitro.Core.Util.BodyParsers: _parse_json_bounded, _json_for_storage
import Nitro.Core.Errors: is_unrecoverable, ClaimPoisonedError, loggable

import Nitro.Workers: AbstractWorkerStore, TaskInfo, TaskStatus, TaskOptions,
    PENDING, RUNNING, COMPLETED, FAILED, CANCELLED,
    TaskAuthority, Owner, System, UNSUPPLIED, owner_of, _is_authorized, _owns, _may_read_durable,
    TASK_KEY_DELIMITER,
    _check_page,
    get_task_info, set_task!, replace_task!, add_watcher!, try_transition!,
    delete_task!, try_delete_task!, cleanup_tasks!, get_all_tasks,
    list_running_task_refs, RunningTaskRef,
    # The optional claim capability (#514) and the helpers both backends share.
    claim_next!, renew_leases!, release_claim!, requeue_expired!, count_external_runs,
    LeaseRenewal, LeasePolicy,
    _successor_run, _lease_period, _check_consumer_id, _check_claim_queue, _lease_expiry_error, _lease_policy,
    _release_bound_error, _check_on_unknown_queue,
    _ExpiryTally, current_time_utc,
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

Contract for PormG's side of the seam, which does not exist yet (PormG, as of 0.8, has no
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

**Why bind at all, when `.db(key)` already routes the query.** Because every store query
starts with `model.objects`, and PormG resolves that property by the model *before* `.db()`
is ever reached: `Base.getproperty(::Model_Type, :objects)` calls
`Models.ensure_model_initialized(model)` first. Its fast path is a set `connect_key` that names
a loaded connection. An unbound model misses it and runs the self-heal path on **every**
session and task query — scanning `REGISTERED_MODULES` and `Base.loaded_modules`, and, for any
loaded package carrying a `__pormg_init_path__` marker (what `@models_module` injects), logging
an `@info "Self-healing: …"` and re-running `set_models` on that package. It then returns
`false`, which `getproperty` ignores, so nothing fails and the query still runs; it is just a
per-request log line and model re-registration nobody asked for (#532) — on PormG 0.8 it costs
milliseconds per query where the bound fast path is effectively free.

The binding was introduced for a different reason, which no longer holds. Before PormG 0.8 the
transaction-scope check gated on the **model's** `connect_key` and never consulted the query's
`.db()` override, so an unbound model threw `InvalidConfigurationError` for every query issued
while any transaction was open on the calling task (#202). PormG 0.8 (PormG#838) checks the
pool the query *runs* on, which for the stores is what `.db(store.db_key)` resolves.

**Why the model is per store and never a process-wide singleton.** `connect_key` names
exactly one connection. Two stores on different keys sharing one model object would
overwrite each other's binding, and the loser's model would then name the other store's
connection. Building a model is a handful of allocations and happens about twice per
application, so there is nothing to cache and no shared mutable state to lock.

The caller must pass the key the store will query on. On the path where a store *builds* its
own model — the factories, and either constructor called without `model=` — both this key and
the query's `.db(...)` come from the one `store.db_key` field, so they cannot diverge.

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
- `created_at`   — TIMESTAMPTZ, when the session was first stored; kept by every update and
                   rotation, and what `SessionMiddleware(absolute_max_age = …)` measures from
                   ([#362](https://github.com/PingoLee/Nitro.jl/issues/362)). Added after the
                   table shipped, so `_ensure_session_created_at_column!` adds it on boot.
"""
function _define_session_model(db_key::String)
    if isdefined(PormG, :Models)
        m = PormG.Models.Model("nitro_session",
            session_key  = PormG.Models.CharField(max_length=40, primary_key=true),
            session_data = PormG.Models.TextField(default="{}"),
            expires_at   = PormG.Models.DateTimeField(db_index=true),
            created_at   = PormG.Models.DateTimeField(),
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
    PormGSessionStore(; model=nothing, db_key="db", max_sessions=nothing)

A PormG-backed session store that implements Nitro's `AbstractSessionStore{String, Dict{String,Any}}`.

Sessions are stored as JSON text in the database and expire at a fixed timestamp
from the last write (no sliding expiry).

`max_sessions` bounds the table against a flood of anonymous sessions (#440). Once the store holds
that many rows, [`session_store_full`](@ref Nitro.Core.Types.session_store_full) answers `true` and
`SessionMiddleware` stops saving **new anonymous** sessions; sessions that end signed in, existing
sessions and rotations are never refused. A visitor with no cookie can still be kept from signing in
through a form whose CSRF token is bound to the session, since that token needs an anonymous
session first. `nothing`, the default, is unbounded and costs nothing. The count is not a query per
request: it is read once at construction, kept up to date by this store's own inserts and deletes,
and re-read exactly on every prune tick, which also corrects drift from other processes sharing the
table. Between ticks each process sees only its own inserts, so several processes on one table can
overshoot the bound by roughly what each inserts in one `prune_interval`. Expired rows count until
the janitor deletes them, since they hold the disk until then.

`db_key` is the PormG connection key **every** session query runs on — read, write, delete and
prune alike — and it must name the connection whose `nitro_session` table you bootstrapped.
Prefer `pormg_nitro_session(db_key=...)`, which creates the table and returns a store already
pointed at the same connection.

A `model` passed explicitly is used as given, including its `connect_key`; omit it and the
store builds one bound to `db_key` (see `_bind_model!`). A supplied model whose `connect_key`
is unset still routes correctly through `db_key`, but pays PormG's self-heal scan on every
query — bind it to `db_key` first.

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
    max_sessions::Nullable{Int}
    # Rows in the table as this process last knew it -- see `max_sessions` above. Kept only when
    # `max_sessions` is set; an unbounded store never touches it.
    count::Threads.Atomic{Int}
end

# Refused before anything touches the database: `pormg_nitro_session` calls this ahead of its
# table bootstrap, so a bad bound never half-configures a connection.
function _check_max_sessions(max_sessions::Nullable{Integer})
    max_sessions === nothing || max_sessions > 0 || throw(ArgumentError(
        "PormGSessionStore: `max_sessions` must be positive, or `nothing` for no bound; got " *
        "$max_sessions (#440)."))
    return nothing
end

function PormGSessionStore(; model=nothing, db_key::String="db",
                           max_sessions::Nullable{Integer}=nothing)
    _check_max_sessions(max_sessions)
    # A SUPPLIED model is used exactly as given -- the caller owns its `connect_key`, and
    # the test doubles that pass one here are immutable structs that could not take the
    # assignment anyway. Only a model this constructor builds gets bound (#202).
    m = isnothing(model) ? session_model(db_key) : model
    if isnothing(m)
        error("PormGSessionStore requires PormG.Models to be available. Ensure PormG is properly loaded.")
    end
    store = PormGSessionStore(m, db_key, max_sessions === nothing ? nothing : Int(max_sessions),
                              Threads.Atomic{Int}(0))
    _capped(store) && _recount_sessions!(store)
    return store
end

_capped(store::PormGSessionStore) = store.max_sessions !== nothing

# The exact row count, read into `store.count` (#440). Expired rows included: they hold the disk
# until the janitor deletes them. Called at construction and on every prune tick, never per request.
function _recount_sessions!(store::PormGSessionStore)
    store.count[] = Int(_session_objects(store).count())
    return nothing
end

# Called on the request path, before every anonymous insert: an atomic read, never a query.
session_store_full(store::PormGSessionStore) =
    _capped(store) && store.count[] >= something(store.max_sessions)

# Route every session query to the store's configured connection, exactly as `_task_objects`
# does for the worker store. Without this the query falls back to the model's own
# `connect_key`, and before #199 that was `nothing` -- PormG then either used the sole loaded
# connection or threw `InvalidConfigurationError` when several were loaded. Both outcomes
# ignored `db_key`, and the throw is swallowed by the read paths below, so sessions silently
# stopped persisting (#199).
#
# Since #202 a model the store builds carries `connect_key == store.db_key` too (see
# `_bind_model!` for what that binding is for now), so this call is redundant for ROUTING on that
# path and is kept anyway. A `model=` the caller supplies is used as given and need not be
# bound. It is the only thing the mock in `test/extensions/pormg_worker_tests.jl` can pin
# (#203). And since PormG 0.8 (PormG#838) the `.db()` key is the one PormG's transaction-scope
# check reads: inside a transaction, a query whose pool has none open raises `TransactionError`
# instead of running in autocommit. A source guard in `test/extensions/pormg_session_tests.jl`
# pins that every `.objects` in this file goes through `.db(` (#532).
_session_objects(store::PormGSessionStore) = store.model.objects.db(store.db_key)

# -- Serialization helpers --

# Stored JSON -- a session payload, a task's `result` -- is written by `_json_for_storage`
# (`src/utilities/bodyparsers.jl`, where the reasoning lives) and read back through the same
# 512-level bound as request JSON (#344). `max_fields = 0` on the read: the per-request key cap
# guards request bodies, and this is the app's own data.

_parse_stored(raw::AbstractString) = _parse_json_bounded(raw; max_fields = 0)

function _serialize_session(data::Dict{String,Any})::String
    return _json_for_storage(data)
end

function _deserialize_session(raw::AbstractString)::Dict{String,Any}
    parsed = _parse_stored(raw)
    return convert(Dict{String,Any}, parsed)
end

# -- Store interface implementation --

# What a store's warning may say about a failed query (#646). Never the live exception: on
# PostgreSQL the driver's error carries the server's DETAIL line, and a constraint violation's
# DETAIL quotes the row -- `Key (session_key)=(<the id>) already exists`, `Failing row contains
# (<key>, <data>, …)`. The id is a bearer credential; a task row carries its owner and arguments.
#
# PormG's `DatabaseError` keeps that text only in `.cause`, and renders itself from value-free
# fields: SQLSTATE, constraint, table, and the server's primary message. So it is logged through
# `loggable`, which keeps that rendering and drops the object and its `.cause`, and an outage
# stays diagnosable. Anything else is logged by its type NAME only: its message is unknown text,
# and a full type can carry a value as a parameter.
#
# Out of Nitro's reach: LibPQ logs the failed statement itself (`[warn | LibPQ]`, DETAIL
# included) before PormG wraps it. An app that needs that line silent sets the level of LibPQ's
# Memento logger.
function _db_fault(e)
    e isa PormG.DatabaseError && return (exception = loggable(e), sqlstate = e.sqlstate)
    return (exception_type = nameof(typeof(e)),)
end

function Base.get(store::PormGSessionStore, session_id::String, default)
    # Both catches below follow #254: an interrupt, a stack overflow or an out-of-memory is not
    # "no session" -- reported as one, it would log the visitor out and carry on in a process
    # that may be corrupted. They propagate; everything else still reads as `default`.
    result = try
        _session_objects(store).filter("session_key" => session_id).first()
    catch e
        is_unrecoverable(e) && rethrow()
        @warn "PormGSessionStore: failed to read session" _db_fault(e)...
        return default
    end
    isnothing(result) && return default
    # Decoding is a separate `try` so it can log differently from the query above (#267). A JSON
    # parse error quotes the stored text around the failure, and that text is a session payload,
    # so this warning carries the exception TYPE only. It never carries the session key either,
    # because the key is the credential. The query failure above used to keep its full exception,
    # on the belief that a driver error quotes no payload. On PostgreSQL it can (#646), so it logs
    # through `_db_fault`, which keeps PormG's value-free text for diagnosing an outage.
    try
        expires_at = _parse_db_datetime(result[:expires_at])
        created_at = _parse_db_datetime(result[:created_at])
        data = _deserialize_session(result[:session_data])
        return SessionPayload(data, expires_at, created_at)
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
    # Guarded like the generic `get_session`: the call is handed the session id (#612).
    payload = _store_call(Base.get, store, session_id, nothing)
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

# Stores a FRESH session: `created_at` is now on both branches, the overwrite included (#362).
# `SessionMiddleware` only ever calls this for an id minted in the request; a loaded session is
# written with `update_session!` and moved with `rotate_session!`, which both keep `created_at`.
function set_session!(store::PormGSessionStore, session_id::String, data::Dict{String,Any}; ttl::Int=3600)
    now_utc = Dates.now(Dates.UTC)
    expires_at = now_utc + Dates.Second(ttl)
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
                "created_at"   => now_utc,
            )
            _capped(store) && Threads.atomic_add!(store.count, 1)
        else
            _session_objects(store).filter("session_key" => session_id).update(
                "session_data" => serialized,
                "expires_at"   => expires_at,
                "created_at"   => now_utc,
            )
        end
    catch e
        @warn "PormGSessionStore: failed to write session" _db_fault(e)...
        rethrow()
    end
    return data
end

# One `UPDATE ... WHERE session_key = ? AND expires_at > now`, never a read followed by a write:
# the WHERE is the existence check, so a row a concurrent logout deleted -- or one that expired --
# matches nothing and is NOT re-created (#318). `update()` returns the matched-row count (Django
# semantics). `__@gt` is the exact complement of the prune's inclusive `__@lte` and of
# `is_expired`, so the boundary instant counts as expired here too. `created_at` is not in the SET:
# an update slides the expiry, never the absolute lifetime (#362).
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
        @warn "PormGSessionStore: failed to write session" _db_fault(e)...
        rethrow()
    end
    return matched > 0
end

# Moves a session to a new key only while the old one is live (#361). This cannot be one
# `UPDATE ... SET session_key = new WHERE session_key = old AND expires_at > now`, the shape
# `update_session!` uses: PormG refuses a primary key in `update()`'s SET (`InvalidValueError`).
#
# So the guarded DELETE decides. Its WHERE is the liveness check, and its row count says whether
# THIS call removed the row: of a rotation and a concurrent logout, exactly one deletes it, and the
# loser sees 0. Only the winner inserts the new key, so a logged-out session is never copied into
# one. A read followed by an unguarded delete would re-open exactly that window.
#
# The new row carries the old one's `created_at` (#362), read first. The read decides nothing: a
# logout that lands between it and the DELETE makes the DELETE match 0 rows, and nothing is
# inserted. `created_at` itself never changes after insert, so the value read is the value to carry.
# It comes back through `_parse_db_datetime`, which keeps whole seconds as it does for
# `expires_at`: each rotation can move `created_at` earlier by under a second, never later, so it
# can only shorten a session's absolute lifetime, never extend it.
#
# There is deliberately no transaction around the DELETE and the INSERT. It would buy only crash
# atomicity, and a failure between the two already fails closed: the INSERT throws, the old row is
# gone, and the visitor is logged out rather than left holding a session nobody authorized.
function rotate_session!(store::PormGSessionStore, old_id::String, new_id::String,
                         data::Dict{String,Any}; ttl::Int=3600)
    now_utc = Dates.now(Dates.UTC)
    # Outside the `try`, as in `set_session!`: a payload too deep to store throws its
    # `ArgumentError` before the old row is touched, so the session is not lost to it (#344).
    serialized = _serialize_session(data)

    try
        live = _session_objects(store).filter("session_key" => old_id,
                                              "expires_at__@gt" => now_utc).first()
        live === nothing && return false
        created_at = _parse_db_datetime(live[:created_at])

        # PormG's `delete()` returns `(total, per-table breakdown)`.
        deleted = first(_session_objects(store).filter("session_key" => old_id,
                                                       "expires_at__@gt" => now_utc).delete())
        deleted > 0 || return false
        _session_objects(store).create(
            "session_key"  => new_id,
            "session_data" => serialized,
            "expires_at"   => now_utc + Dates.Second(ttl),
            "created_at"   => created_at,
        )
    catch e
        @warn "PormGSessionStore: failed to rotate session" _db_fault(e)...
        rethrow()
    end
    return true
end

function delete_session!(store::PormGSessionStore, session_id::String)
    try
        # PormG's `delete()` returns `(total, per-table breakdown)`.
        deleted = first(_session_objects(store).filter("session_key" => session_id).delete())
        _capped(store) && Threads.atomic_sub!(store.count, Int(deleted))
    catch e
        @warn "PormGSessionStore: failed to delete session" _db_fault(e)...
        rethrow()
    end
    return nothing
end

function cleanup_expired_sessions!(store::PormGSessionStore)
    now_utc = Dates.now(Dates.UTC)
    try
        _session_objects(store).filter("expires_at__@lte" => now_utc).delete()
        # Re-read rather than subtract: the exact count also absorbs inserts and deletes made by
        # other processes on the same table since the last tick (#440).
        _capped(store) && _recount_sessions!(store)
    catch e
        @warn "PormGSessionStore: failed to cleanup expired sessions" _db_fault(e)...
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

    # A table created before #362 does not get `created_at` from the statement above.
    _ensure_session_created_at_column!(conn)

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
    _ensure_session_created_at_column!(conn)

Add the `created_at` column ([#362](https://github.com/PingoLee/Nitro.jl/issues/362)) to an
existing `nitro_session` table, idempotently. `Base.get` reads it on every session load, so a table
without it cannot serve a session at all. It follows the same probe-first discipline as
`_ensure_run_id_column!` (#366), whose docstring explains why: probe, `ALTER` only when the column
is missing, and probe again before rethrowing a failed `ALTER` that another process may have beaten.

Existing rows are backfilled through a **constant** `DEFAULT` holding the migration instant, for
three reasons:

- Each live session gets a full `absolute_max_age` from the upgrade, instead of being logged out
  by it.
- SQLite refuses a non-constant default such as `CURRENT_TIMESTAMP` in `ADD COLUMN`.
- The default also stamps any row a process still on the old code inserts during a rolling deploy.
  The column therefore never holds `NULL`, so no reader has a case for one.

The literal is in PormG's canonical UTC form (`yyyy-mm-ddTHH:MM:SS.sss+00:00`), so it reads back
exactly like a value PormG wrote. On SQLite that same text is what makes the prune's string
comparison agree with an instant comparison.
"""
_ensure_session_created_at_column!(conn) = _ensure_column!(conn, "nitro_session", "created_at",
    "$(_datetime_column_type(conn)) NOT NULL DEFAULT '$(_canonical_utc(Dates.now(Dates.UTC)))'")

# What `PormG.Dialect.create_table` emits for a `DateTimeField` on each backend (PormG
# `constants.jl`), so a column added by `ALTER` matches one created with the table.
_datetime_column_type(::PormG.PormGSQLite) = "DATETIME"
_datetime_column_type(::PormG.PormGPostgres) = "TIMESTAMPTZ"

# PormG's canonical `DateTimeField` text for a naive UTC `DateTime` (`format_timezone_sql`).
_canonical_utc(t::DateTime) = Dates.format(t, dateformat"yyyy-mm-ddTHH:MM:SS.sss") * "+00:00"

# Deliberately no docstring: the authoritative one is on the weakdep stub in `src/exts.jl`, which
# is also what `?pormg_nitro_session` resolves to. Two docstrings on one function render as two
# conflicting help entries and drift apart independently (#33).
function pormg_nitro_session(; db_key::String="db", max_sessions::Nullable{Integer}=nothing)
    _check_max_sessions(max_sessions)
    model = session_model(db_key)
    if isnothing(model)
        error("pormg_nitro_session: PormG.Models is not available. Ensure PormG is properly loaded.")
    end
    conn = PormG.connection(key=db_key)
    _ensure_session_table!(conn, model)
    return PormGSessionStore(model=model, db_key=db_key, max_sessions=max_sessions)
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
- `external`, `claimed_by`, `lease_expires_at`, `attempt` — the claim columns
                   ([#514](https://github.com/PingoLee/Nitro.jl/issues/514)): whether the
                   submission was queued for a consumer process (BOOLEAN), which consumer holds
                   its current run (VARCHAR(255), NULL when none), until when (TIMESTAMPTZ), and
                   how many times it has been claimed (INTEGER). Written only by `replace_task!`
                   and the claim operations, never by `set_task!`. Added after the table shipped,
                   so `_ensure_task_table!` adds them on boot; the two claim indexes
                   (`nitro_task_claim_idx`, `nitro_task_lease_idx`) serve `claim_next!` and
                   `requeue_expired!`.
- `job_name`, `job_args` — a named job's registered name (VARCHAR(255)) and its arguments as JSON
                   (TEXT), both NULL for a closure ([#514](https://github.com/PingoLee/Nitro.jl/issues/514)).
                   Submission identity: written by `replace_task!`, carried by the claim
                   operations, never written by `set_task!`. Added on boot like the claim columns.
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
            external         = PormG.Models.BooleanField(default=false),
            claimed_by       = PormG.Models.CharField(max_length=255, null=true, blank=true),
            lease_expires_at = PormG.Models.DateTimeField(null=true, blank=true),
            attempt          = PormG.Models.IntegerField(default=0),
            job_name         = PormG.Models.CharField(max_length=255, null=true, blank=true),
            job_args         = PormG.Models.TextField(null=true, blank=true),
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
store builds one bound to `db_key` (see `_bind_model!`). A supplied model whose `connect_key`
is unset still routes correctly through `db_key`, but pays PormG's self-heal scan on every
query — bind it to `db_key` first.
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
# bound to the same key, and the reasoning for keeping both is on `_session_objects` above.
_task_objects(store::PormGWorkerStore) = store.model.objects.db(store.db_key)

# -- Serialization Helpers --

# PormG refuses a NUL in any bound text parameter since 0.8 (PormG#951): PostgreSQL text cannot
# hold one, and SQLite cannot read a value back past it. The `error` column is the one place free
# text reaches this store unescaped -- a task's own exception message, which can quote request
# data -- so a NUL there would make the terminal write raise and lose the failure record. It is
# diagnostic text: a visible U+FFFD beats a dropped write. `result` and `watchers` are JSON, whose
# encoder already escapes a NUL.
_storable_text(s::AbstractString) = '\0' in s ? replace(s, '\0' => '�') : s

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
        "error" => isnothing(task.error) ? "" : _storable_text(task.error),
        "created_at" => task.created_at,
        "started_at" => task.started_at,
        "completed_at" => task.completed_at,
        "watchers" => watchers_str,
        "queue_name" => isnothing(task.queue_name) ? "" : task.queue_name,
        "external" => task.external,
        "claimed_by" => task.claimed_by,
        "lease_expires_at" => task.lease_expires_at,
        "attempt" => task.attempt,
        "job_name" => task.job_name,
        "job_args" => task.job_args,
    )
end

# The claim columns (#514), read with the value a pre-#514 row was backfilled with when a row
# does not carry them. SQLite hands a BOOLEAN back as an integer.
function _row_or(row, key_sym::Symbol, key_str::String, default)
    haskey(row, key_sym) && return row[key_sym]
    haskey(row, key_str) && return row[key_str]
    return default
end

_db_bool(v::Bool) = v
_db_bool(v::Integer) = !iszero(v)
_db_bool(v::AbstractString) = v in ("1", "t", "true", "TRUE")
_db_bool(::Union{Nothing, Missing}) = false

function _db_optional_string(v)
    (v === nothing || v === missing) && return nothing
    s = string(v)
    return isempty(s) ? nothing : s
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

    task.external = _db_bool(_row_or(row, :external, "external", false))
    task.claimed_by = _db_optional_string(_row_or(row, :claimed_by, "claimed_by", nothing))
    task.lease_expires_at = _parse_optional_db_datetime(_row_or(row, :lease_expires_at, "lease_expires_at", nothing))
    task.attempt = Int(_row_or(row, :attempt, "attempt", 0))
    task.job_name = _db_optional_string(_row_or(row, :job_name, "job_name", nothing))
    task.job_args = _db_optional_string(_row_or(row, :job_args, "job_args", nothing))

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

# The authorization read `_visible_record` makes before the full one (#565): the `watchers` column
# alone, so a caller who may not see the task never fetches or decodes its `result`. The owner
# needs no read at all, since the id names them. `System` is authorized by definition. Logs and
# rethrows like `get_task_info`, for the same reason: a failed read is not "not yours".
_may_read_durable(::PormGWorkerStore, ::System, ::String) = true
function _may_read_durable(store::PormGWorkerStore, authority::Owner, task_id::String)
    _owns(authority, task_id) && return true
    row = try
        _task_objects(store).filter("id" => task_id).values("watchers").first()
    catch e
        @warn "PormGWorkerStore: failed to read task" task_id exception_type=typeof(e)
        rethrow()
    end
    row === nothing && return false
    watchers_str = string(_row_or(row, :watchers, "watchers", ""))
    isempty(watchers_str) && return false
    watchers = _parse_stored_json(v -> convert(Vector{String}, v), watchers_str, "watchers", task_id)
    return authority.user_id in watchers
end

# A fresh row has no watchers to preserve, so a create always writes them, whichever entry point
# it came through.
function _create_task_row!(store::PormGWorkerStore, record)
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
        "external" => record["external"],
        "claimed_by" => record["claimed_by"],
        "lease_expires_at" => record["lease_expires_at"],
        "attempt" => record["attempt"],
        "job_name" => record["job_name"],
        "job_args" => record["job_args"],
    )
    return nothing
end

# Rows written by an UPDATE of an existing record.
function _update_task_row!(store::PormGWorkerStore, task_id::String, record, full_record::Bool)
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
    #
    # The claim columns (#514) follow `run_id`, for the same reason: they describe the current
    # claim, which only the claim operations write, and `replace_task!` publishing a new
    # submission resets them. `external` is identity of the submission, and so are `job_name` and
    # `job_args`: a state save never carries them.
    if full_record
        push!(columns, "watchers" => record["watchers"])
        push!(columns, "run_id" => record["run_id"])
        push!(columns, "external" => record["external"])
        push!(columns, "claimed_by" => record["claimed_by"])
        push!(columns, "lease_expires_at" => record["lease_expires_at"])
        push!(columns, "attempt" => record["attempt"])
        push!(columns, "job_name" => record["job_name"])
        push!(columns, "job_args" => record["job_args"])
    end
    changed = _task_objects(store).filter("id" => task_id).update(columns...)
    return changed isa Integer ? Int(changed) : 0
end

# How many read -> write rounds `replace_task!` gets. A round is lost only when another process
# deletes or creates this one row between our read and our write, so this is generous.
const _REPLACE_ATTEMPTS = 8

function _write_task!(store::PormGWorkerStore, task_id::String, task_info::TaskInfo, full_record::Bool)
    record = _to_db_record(task_info)
    try
        full_record && return _replace_task_row!(store, task_id, record, task_info)
        existing = _task_objects(store).filter("id" => task_id).first()
        if isnothing(existing)
            _create_task_row!(store, record)
        else
            # A 0-row UPDATE is deliberately a no-op HERE, and only here. It means the record
            # was deleted after our read -- released, pruned, or deleted in another process --
            # and a state save must not resurrect it: a released run's own terminal write
            # "finds no record and stores nothing" (`release_task!`). `replace_task!` is the
            # opposite case, below.
            _update_task_row!(store, task_id, record, false)
        end
    catch e
        @warn "PormGWorkerStore: failed to write task" _db_fault(e)...
        rethrow()
    end
    return task_info
end

# `replace_task!` writes the record "replacing whatever is stored" -- including nothing. Its one
# caller is a re-run publishing its new run, and a 0-row UPDATE there used to be ignored: a record
# deleted between our read and our write (by `release_task!`, retention, or `delete_task!` in
# another process) left the re-run with no record, `_claim_run!` declined it, and the submit
# returned normally for a task that never ran (#379). So each lost round goes around again:
# vanished -> create it; a concurrent creator won the insert -> update what it wrote. That is the
# upsert `InMemoryWorkerStore.replace_task!` already is.
function _replace_task_row!(store::PormGWorkerStore, task_id::String, record, task_info::TaskInfo)
    for _ in 1:_REPLACE_ATTEMPTS
        existing = _task_objects(store).filter("id" => task_id).first()
        if isnothing(existing)
            try
                _create_task_row!(store, record)
                return task_info
            catch e
                # Only a row that now exists explains an integrity failure here. Anything else
                # is a real constraint problem, and it propagates. Inside an app's own open
                # PostgreSQL transaction the failed INSERT has already aborted that transaction,
                # so the re-read below throws instead and the submit fails loudly -- the app's
                # transaction was lost either way.
                e isa PormG.IntegrityError || rethrow()
                isnothing(_task_objects(store).filter("id" => task_id).first()) && rethrow()
            end
        elseif _update_task_row!(store, task_id, record, true) >= 1
            return task_info
        end
    end
    error("PormGWorkerStore: could not write task '$task_id' after $(_REPLACE_ATTEMPTS) " *
          "attempts -- another process kept deleting or creating the row between this " *
          "store's read and its write")
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
    error === nothing || push!(columns, "error" => _storable_text(error))
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
        @warn "PormGWorkerStore: failed to delete task" _db_fault(e)...
        rethrow()
    end
    return nothing
end

# -- Guarded deletes (#379, #398) --
#
# A delete whose filter is a GUARD rather than a selection -- `try_delete_task!`'s status and run
# preconditions, a retention sweep's eligibility -- is only a guard because PormG >= 0.7 writes
# those filters on the row it deletes (PormG#765). Under READ COMMITTED, PostgreSQL re-checks a
# waiting statement's own WHERE clause against the row a concurrent UPDATE left, and only that
# clause. PormG 0.6 wrapped the filters in `WHERE "id" IN (SELECT "id" ... WHERE <filters>)`, which
# is evaluated once, on the old snapshot: a key re-run committing while the DELETE waited on its
# lock had its fresh PENDING row deleted (#379), so this was a hand-written DELETE until #398. The
# `[compat]` bound is what keeps it closed -- an older PormG re-opens it. No mock can stage the
# race; the rendered shape is pinned in `test/extensions/pormg_worker_tests.jl` instead.
# SQLite serializes writers and never had the gap.

# The delete counterpart of `try_transition!` (#323): the status and run preconditions sit in the
# statement's own WHERE clause, so a record another process re-ran since the caller read it is
# not matched and survives.
function try_delete_task!(store::PormGWorkerStore, task_id::String, from;
                          run_id::Union{Nothing, UUIDs.UUID})
    statuses = String[string(s) for s in from]
    isempty(statuses) && return false
    matched = run_id === nothing ?
        _task_objects(store).filter("id" => task_id, "status__@in" => statuses) :
        _task_objects(store).filter("id" => task_id, "run_id" => string(run_id),
                                    "status__@in" => statuses)
    deleted, _ = matched.delete()
    return deleted isa Integer && deleted >= 1
end

# Retention reads the old-enough ids a keyset page at a time and deletes each page before reading
# the next. Paged because a sweep can meet a large backlog -- the first working one after #379 met
# every terminal row the table ever held -- and one unbounded DELETE over it would hold its row
# locks for as long as it ran.
const _CLEANUP_PAGE = 500

# Which rows are old enough is a read; each page's delete then re-applies that same eligibility to
# the rows it writes, scoped to the ids read. The fence is "still eligible", not "still the same
# run": a key re-run between the read and the delete is PENDING with no `completed_at`, or already
# finished with a `completed_at` newer than `cutoff`, and fails the re-checked predicate either way.
# That is the eligibility `InMemoryWorkerStore` evaluates under its lock (it compares the cutoff
# with `<` where this has `<=`, a boundary older than #398). (#379 fenced each row on
# the `run_id` it read instead, which needed one OR-leg per row and a NULL `run_id` special case.)
#
# `status__@in` takes a Vector. PormG has no method for a Tuple, and the mocks refuse one too: the
# Tuple this used to pass made every real sweep throw into the `catch` below and delete nothing.
function cleanup_tasks!(store::PormGWorkerStore, retain_days::Int)
    cutoff = Dates.now(Dates.UTC) - Dates.Day(retain_days)
    eligible = ("completed_at__@lte" => cutoff,
                "completed_at__@isnull" => false,
                "status__@in" => String[string(s) for s in (COMPLETED, FAILED, CANCELLED)])
    deleted = 0
    after = nothing
    try
        while true
            query = _task_objects(store).filter(eligible...).values("id")
            rows = _keyset!(query, after, _CLEANUP_PAGE).list()
            isempty(rows) && break
            ids = String[_row_task_id(row) for row in rows]
            n, _ = _task_objects(store).filter("id__@in" => ids, eligible...).delete()
            deleted += n
            length(rows) < _CLEANUP_PAGE && break
            # Past the last id READ, not the last deleted: a row the fence spared (a re-run) stays
            # behind the cursor instead of being read again forever.
            after = last(ids)
        end
        return deleted
    catch e
        # A Ctrl-C leaves BARE: the retention scheduler recognises `e isa InterruptException` and
        # nothing else, and PormG hands it back wrapped in a `DatabaseError` (`_interrupted`).
        # Swallowed into the warning below, it made Ctrl-C during a sweep a no-op.
        _interrupted(e) && throw(InterruptException())
        # What earlier pages already deleted is gone either way, so it is what this reports.
        @warn "PormGWorkerStore: failed to cleanup old tasks" deleted _db_fault(e)...
        return deleted
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
    # A leased run is skipped by the sweep (#514), so this is what keeps it out of the zombie path.
    claimed_by = _db_optional_string(_row_or(row, :claimed_by, "claimed_by", nothing))
    return RunningTaskRef((id, run_id, started_at, claimed_by))
end

# Zombie recovery's scan (#236): a projection of exactly the columns it reads -- three, and
# `claimed_by` since #514. No row's
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
    query = () -> _task_objects(store).filter("status" => string(RUNNING)).values("id", "run_id", "started_at", "claimed_by")
    try
        return _keyset_collect!(RunningTaskRef[], query, after, limit) do refs, row
            ref = _running_ref_from_row(row)
            ref === nothing || push!(refs, ref)
        end
    catch e
        @warn "PormGWorkerStore: failed to list running tasks" _db_fault(e)...
        rethrow()
    end
end

# -- The claim capability (#514) --
#
# Every write below is one statement fenced on the run it read, in the statement's own WHERE --
# the same shape as `try_transition!`, and for the same reason: `lock_tasks` is process-local, and
# the processes that claim are, by construction, not this one. A claim mints a fresh `run_id` in
# the fenced UPDATE that takes the row, so whatever held the previous run fails every fence from
# then on (#108).
#
# The candidate read is ORM, not a hand-written `UPDATE ... RETURNING`: reading a raw RETURNING row
# needs `Tables`, which Nitro does not depend on; PormG avoids RETURNING on SQLite; and a statement
# the mock cannot see is a statement no test runs. The cost is a read and an UPDATE instead of one
# round trip, next to a job heavy enough to need its own process.

# The rows `claim_next!` takes from, oldest first. Its own function so the shape test renders
# exactly what runs: on PostgreSQL it carries `FOR UPDATE SKIP LOCKED`, so two consumers reading
# at once take different rows instead of queueing on the head; on SQLite it renders without it,
# and the transaction's `BEGIN IMMEDIATE` makes the claim exclusive instead. `id` breaks ties
# between rows submitted within one clock tick, so the order is total.
_claim_candidates(objects, queue_name::String) =
    objects.filter("queue_name" => queue_name, "external" => true, "status" => string(PENDING)
        ).order_by("created_at", "id").select_for_update(skip_locked = true)

# The transaction a claim runs in: on PostgreSQL it holds the `FOR UPDATE` lock from the read to
# the claiming write. A seam on the model so the test mock -- which has no transactions -- runs the
# body directly; a production fallback that silently dropped the transaction would be worse.
_store_transaction(f::Function, model, db_key::String) = PormG.run_in_transaction(f, db_key)

# How many lost races a claim survives before it throws rather than answer "empty". A race is lost
# only when another claimer took the row between our read and our write, which `SKIP LOCKED`
# already makes rare on PostgreSQL.
const _CLAIM_ATTEMPTS = 8

function claim_next!(store::PormGWorkerStore, queue_name::String, consumer_id::String;
                     lease_seconds::Real, now::DateTime=current_time_utc())
    _check_claim_queue(queue_name)
    _check_consumer_id(consumer_id)
    lease = _lease_period(lease_seconds)
    lost = 0
    poisoned = false
    while lost < _CLAIM_ATTEMPTS
        # Bound once per iteration, so the closure captures a value, not the reassigned
        # `poisoned` itself, which would be a `Core.Box` (#364).
        may_poison = !poisoned
        outcome = _store_transaction(store.model, store.db_key) do
            row = _claim_candidates(_task_objects(store), queue_name).first()
            isnothing(row) && return :empty
            return _claim_row!(store, row, queue_name, consumer_id, now, now + lease; may_poison)
        end
        outcome === :empty && return nothing
        outcome isa TaskInfo && return outcome
        # `:lost`, or `:poisoned` -- a head row that did not decode and was failed out of the way.
        # Only a lost race counts toward the bound: a poisoned row is gone, so it cannot loop. At
        # most ONE is failed per call, though: see `_claim_row!`.
        outcome === :poisoned && (poisoned = true)
        outcome === :lost && (lost += 1)
    end
    error("PormGWorkerStore: could not claim from queue '$queue_name' after $(_CLAIM_ATTEMPTS) " *
          "lost races -- other consumers kept taking the head row between this one's read and " *
          "its write")
end

function _claim_row!(store::PormGWorkerStore, row, queue_name::String, consumer_id::String,
                     now::DateTime, expires::DateTime; may_poison::Bool)
    task = try
        _from_db_record(row)
    catch e
        is_unrecoverable(e) && rethrow()
        # A SECOND head row that does not decode, in one call, says the cause is not the rows: a
        # decode regression, or stored timestamps a new PormG reads differently. Failing every
        # row in the queue would make that irreversible, so stop and say so instead. The type
        # only: a decode error may have been about `result`, which is application data. Its own
        # type, so a consumer stops claiming from this queue on it rather than retrying.
        may_poison || throw(ClaimPoisonedError(queue_name, typeof(e)))
        return _fail_undecodable_head!(store, row, now, typeof(e))
    end
    run = _successor_run(task)       # the new run: a fresh `run_id`, minted here
    run.status = RUNNING
    run.claimed_by = consumer_id
    run.lease_expires_at = expires
    run.attempt = task.attempt + 1
    run.started_at = now
    # Fenced on the run we READ. `attempt` is written as a literal, not `attempt + 1` in SQL: every
    # writer of `attempt` also changes `run_id`, so the fence proves the value we read is current.
    changed = _task_objects(store).filter(
        "id" => task.id, "run_id" => string(task.run_id), "status" => string(PENDING),
    ).update(
        "status" => string(RUNNING),
        "run_id" => string(run.run_id),
        "claimed_by" => consumer_id,
        "lease_expires_at" => expires,
        "attempt" => run.attempt,
        "started_at" => now,
    )
    return (changed isa Integer && changed >= 1) ? run : :lost
end

# A head row that does not decode would be the head on every claim, so the queue would never move.
# It is failed out of the way, fenced on the raw `run_id` it carries (no parse needed to compare),
# with a value-free error: the decode failure may have been in `result`, which is application data.
function _fail_undecodable_head!(store::PormGWorkerStore, row, now::DateTime, exception_type::Type)
    id = something(_row_task_id(row), "")
    raw_run_id = string(_row_or(row, :run_id, "run_id", ""))
    @warn "PormGWorkerStore: failing an external task whose stored record does not decode, so its queue can move" task_id=id exception_type
    changed = _task_objects(store).filter(
        "id" => id, "run_id" => raw_run_id, "status" => string(PENDING),
    ).update(
        "status" => string(FAILED),
        "error" => "Stored task record does not decode; failed by a consumer's claim",
        "completed_at" => now,
    )
    return (changed isa Integer && changed >= 1) ? :poisoned : :lost
end

function renew_leases!(store::PormGWorkerStore, consumer_id::String,
                       runs::AbstractVector{LeaseRenewal};
                       lease_seconds::Real, now::DateTime=current_time_utc())
    _check_consumer_id(consumer_id)
    expires = now + _lease_period(lease_seconds)
    renewed = UUIDs.UUID[]
    # One statement per run, so the answer says WHICH runs are still this consumer's -- a batched
    # UPDATE returns only a count. Addressed by `id`, the primary key: `run_id` is not indexed.
    for r in runs
        changed = _task_objects(store).filter(
            "id" => r.id, "run_id" => string(r.run_id), "status" => string(RUNNING),
            "claimed_by" => consumer_id,
        ).update("lease_expires_at" => expires, "progress" => r.progress)
        changed isa Integer && changed >= 1 && push!(renewed, r.run_id)
    end
    return renewed
end

# The columns that hand a claimed run back to the queue as a new run of the same submission.
_back_to_pending_columns() = Pair{String, Any}[
    "status" => string(PENDING),
    "run_id" => string(UUIDs.uuid4()),
    "claimed_by" => nothing,
    "lease_expires_at" => nothing,
    "started_at" => nothing,
    "progress" => 0.0,
]

function release_claim!(store::PormGWorkerStore, task_id::String, run_id::UUIDs.UUID;
                        policy::LeasePolicy, now::DateTime=current_time_utc())
    fence = ("id" => task_id, "run_id" => string(run_id), "status" => string(RUNNING), "external" => true)
    # The attempt count decides which columns the write sets, so it is read first -- under the
    # same fence the write repeats. The read cannot go stale unnoticed: every writer of `attempt`
    # also changes `run_id`, so a write that lands between the two makes the fenced write below
    # match nothing.
    row = _task_objects(store).filter(fence...).values("queue_name", "attempt").first()
    isnothing(row) && return false
    queue = _db_optional_string(_row_or(row, :queue_name, "queue_name", nothing))
    err = _release_bound_error(queue, policy, Int(_row_or(row, :attempt, "attempt", 0)))
    columns = err === nothing ? _back_to_pending_columns() :
        Pair{String, Any}["status" => string(FAILED), "error" => err, "completed_at" => now]
    changed = _task_objects(store).filter(fence...).update(columns...)
    return changed isa Integer && changed >= 1
end

function count_external_runs(store::PormGWorkerStore, statuses::AbstractVector{TaskStatus};
                             queue_name::Union{Nothing, String}=nothing,
                             submitter::Union{Nothing, String}=nothing)
    terms = Pair{String, Any}["external" => true, "status__@in" => String[string(s) for s in statuses]]
    queue_name === nothing || push!(terms, "queue_name" => queue_name)
    query = _task_objects(store).filter(terms...)
    submitter === nothing && return Int(query.count())
    # The FIRST element of the serialized watcher list, which every writer produces with
    # `JSON.json`: the whole list is `["u"]`, or it starts `["u",`. The id is JSON-quoted, so
    # `"bob"` cannot match `"bobby"`, and PormG renders `@startswith` with an ESCAPE clause, so a
    # `%` or `_` in an id is matched literally.
    quoted = JSON.json(submitter)
    return Int(query.filter(PormG.Qor(
        "watchers" => "[" * quoted * "]",
        "watchers__@startswith" => "[" * quoted * ",",
    )).count())
end

# A page of expired leases at a time, by keyset on the id, like retention. No wrapping
# transaction: each outcome is its own fenced statement, which is what makes it correct, and a
# transaction would hold every adjudicated row's lock -- and on SQLite the database's write lock --
# until the whole sweep ended, blocking the very renewals it races with.
const _EXPIRY_PAGE = 500

function requeue_expired!(store::PormGWorkerStore, now::DateTime;
                          policies::AbstractDict{String, LeasePolicy}, on_unknown_queue::Symbol = :fail)
    requeued = failed = unknown = lost = 0
    expired = ("status" => string(RUNNING), "lease_expires_at__@lt" => now)
    # Under `:skip`, the scan reads only the policies' queues, so another app's rows are never read.
    scan = if _check_on_unknown_queue(on_unknown_queue) === :skip
        isempty(policies) && return _ExpiryTally((0, 0, 0, 0))
        (expired..., "queue_name__@in" => collect(String, keys(policies)))
    else
        expired
    end
    after = nothing
    while true
        query = _task_objects(store).filter(scan...).values("id", "run_id", "queue_name", "attempt")
        rows = _keyset!(query, after, _EXPIRY_PAGE).list()
        isempty(rows) && break
        for row in rows
            id = _row_task_id(row)
            queue = _db_optional_string(_row_or(row, :queue_name, "queue_name", nothing))
            attempt = Int(_row_or(row, :attempt, "attempt", 0))
            policy = _lease_policy(policies, queue)
            err = _lease_expiry_error(queue, policy, attempt)
            columns = err === nothing ? _back_to_pending_columns() :
                Pair{String, Any}["status" => string(FAILED), "error" => err, "completed_at" => now]
            # The expiry is re-checked in the write's own WHERE, beside the run it read: a renew
            # that committed since the read moved the lease past `now`, and this row is then not
            # matched (PostgreSQL re-evaluates a waiting statement's WHERE on the row it finds).
            changed = _task_objects(store).filter(
                "id" => id, "run_id" => string(_row_or(row, :run_id, "run_id", "")), expired...,
            ).update(columns...)
            if !(changed isa Integer && changed >= 1)
                lost += 1
            elseif err === nothing
                requeued += 1
            else
                failed += 1
                policy === nothing && (unknown += 1)
            end
        end
        length(rows) < _EXPIRY_PAGE && break
        after = _row_task_id(last(rows))
    end
    return _ExpiryTally((requeued, failed, unknown, lost))
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
would also swallow a genuine failure.

**The probe runs first, because it is the statement that succeeds on the common path**
([#366](https://github.com/PingoLee/Nitro.jl/issues/366)). `CREATE TABLE` has emitted the
column since #108, so an `ALTER`-first order failed on every boot, the very first one included.
Nitro caught that, but LibPQ logs a failed statement at `error` level *before* it throws, so
every Postgres boot printed a `DuplicateColumn` error that no `catch` can take back. A probe that
answers by success or failure alone has to fail in one of the two cases, so it fails in the rare
one: a pre-#108 table logs one missing-column error, on the boot that migrates it. Reading the
column list instead would fail in neither case, but the drivers return different result types
and reading them generically needs `Tables`, which Nitro does not depend on.

A failed `ALTER` is probed again before it is rethrown. Two processes booting on one pre-#108
database both see the column missing, and the one that loses the race gets a duplicate-column
error for a column that is now there.

Called inside an open Postgres transaction on a pre-#108 table, the failed probe aborts that
transaction, so the `ALTER` then fails with `InFailedSqlTransaction` and that is what surfaces.
Boot outside a transaction; before #366 this path failed on every boot.
"""
_ensure_run_id_column!(conn) = _ensure_column!(conn, "nitro_task", "run_id",
    "VARCHAR(36) NOT NULL DEFAULT '$(_LEGACY_RUN_ID)'")

# Add `table.column` with `definition` (everything after the column name in `ADD COLUMN`), unless
# it is already there: probe first, then ALTER, then probe again before rethrowing a failed ALTER.
# The reasoning for each of the three is on `_ensure_run_id_column!` above, and it is the same for
# every column a boot adds -- which is why they all go through this.
function _ensure_column!(conn, table::String, column::String, definition::String)
    _has_column(conn, table, column) && return nothing
    try
        PormG.ConnectionPool.fetch(conn,
            "ALTER TABLE \"$table\" ADD COLUMN \"$column\" $definition")
    catch e
        _interrupted(e) && rethrow()
        _has_column(conn, table, column) || rethrow(e)
    end
    return nothing
end

# The claim columns (#514), on a table created before them. Each default is what a pre-#514 row
# means: queued for this process (`external` false), never claimed. `FALSE`, not `0`: PostgreSQL
# refuses an integer default on a BOOLEAN, and SQLite reads `FALSE` as 0.
function _ensure_claim_columns!(conn)
    _ensure_column!(conn, "nitro_task", "external", "BOOLEAN NOT NULL DEFAULT FALSE")
    _ensure_column!(conn, "nitro_task", "attempt", "INTEGER NOT NULL DEFAULT 0")
    _ensure_column!(conn, "nitro_task", "claimed_by", "VARCHAR(255)")
    _ensure_column!(conn, "nitro_task", "lease_expires_at", _datetime_column_type(conn))
    return nothing
end

# The named-job columns (#514, step 2), on a table created before them. NULL is what a row
# written before them means: a closure, which no other process could run anyway.
function _ensure_job_columns!(conn)
    _ensure_column!(conn, "nitro_task", "job_name", "VARCHAR(255)")
    _ensure_column!(conn, "nitro_task", "job_args", "TEXT")
    return nothing
end

# Whether `table` has `column`, answered by whether a statement naming it runs. Shared by every
# add-a-column-on-boot migration: `nitro_task.run_id` (#108) and `nitro_session.created_at` (#362).
#
# The column is QUALIFIED on purpose, and the probe is wrong without it. By SQLite's default
# double-quoted-string fallback, which the SQLite that SQLite.jl bundles keeps, a double-quoted
# identifier that names no column is read as a string LITERAL: `SELECT "run_id" FROM
# "nitro_task"` succeeds on a table without the column and returns the text 'run_id'. Probing
# first with that form would skip the migration on exactly the table that needs it; as the old
# after-the-ALTER check it swallowed every genuine ALTER failure on SQLite (#366).
# `"nitro_task"."run_id"` cannot be read as a literal, so it throws on both dialects.
#
# `LIMIT 0` because the question is about the schema, not the rows: both dialects resolve the
# column before they read anything.
function _has_column(conn, table::String, column::String)::Bool
    try
        PormG.ConnectionPool.fetch(conn, "SELECT \"$table\".\"$column\" FROM \"$table\" LIMIT 0")
        return true
    catch e
        # A Ctrl-C during the probe is not an answer: read as "missing", it would run the ALTER.
        _interrupted(e) && rethrow()
        return false
    end
end

# A Ctrl-C, as it comes out of PormG's `fetch`. `fetch` hands every driver failure back through
# PormG's error taxonomy, an interrupt included, so it arrives as a `DatabaseError` whose `cause`
# is the `InterruptException` -- a bare `e isa InterruptException` never matches it.
_interrupted(e) = e isa InterruptException ||
    (e isa PormG.DatabaseError && e.cause isa InterruptException)

"""
    _ensure_task_table!(conn, model)

Execute `CREATE TABLE IF NOT EXISTS` and index creations for the `nitro_task` table.
"""
function _ensure_task_table!(conn, model)
    create_table_sql = PormG.Dialect.create_table(conn, model)
    PormG.ConnectionPool.fetch(conn, create_table_sql)

    # A table created before #108 does not get `run_id` from the statement above, nor one created
    # before #514 the claim and named-job columns.
    _ensure_run_id_column!(conn)
    _ensure_claim_columns!(conn)
    _ensure_job_columns!(conn)

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

    # `claim_next!`'s read: equality on the first three, then its ORDER BY (#514). Plain, not
    # partial: the ORM binds `external` and `status` as parameters, and SQLite cannot use a partial
    # index whose condition a query meets only through a parameter.
    PormG.ConnectionPool.fetch(conn, PormG.Dialect.create_index(
        conn,
        "\"nitro_task_claim_idx\"",
        "\"nitro_task\"",
        ["\"queue_name\"", "\"status\"", "\"external\"", "\"created_at\""],
    ))
    # `requeue_expired!`'s scan: RUNNING rows whose lease is past.
    PormG.ConnectionPool.fetch(conn, PormG.Dialect.create_index(
        conn,
        "\"nitro_task_lease_idx\"",
        "\"nitro_task\"",
        ["\"status\"", "\"lease_expires_at\""],
    ))
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

    # There is no model priming here any more. Both models carry a `connect_key` since #202
    # (what it is for now is on `_bind_model!`, #532), and the key is only known when a store
    # is constructed -- so a model built at load time could not be bound, and one process-wide
    # model could not serve two stores on different keys. `session_model(db_key)` /
    # `task_model(db_key)` build a bound model per store instead, which is a handful of
    # allocations about twice per application.

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

# `Nitro.newapp(name; pormg = true)` (#417). The template lives in `src/newapp.jl`; this supplies
# its PormG half and hands `db/` to PormG's own interactive writer. PormG's drivers are weak
# dependencies of PormG, so the adapter `setup` recorded decides which one the app loads, and the
# app is written again once it is known.
function Nitro._newapp_pormg(write_app::Function, root::String)
    # The commit and compat Nitro itself pins: a tag can move (CONTRIBUTING, *Bumping the PormG
    # pin*), and Nitro is tested against this commit, not whichever PormG happens to be loaded.
    pin = Nitro._newapp_pormg_pin()
    # name => (uuid, compat). Kept equal to PormG's own `[weakdeps]`/`[compat]` by
    # `test/extensions/newapp_pormg_tests.jl`.
    drivers = Dict("SQLite" => ("0aa819cd-b072-5ff4-a722-6bc24af294d9", "1.6.1"),
                   "LibPQ" => ("194296ae-ab2e-5f79-8cd4-7183a0a5a0d1", "1"))
    db(names) = Nitro._NewappDB(
        usings = join(["using Nitro", "PormG", names...], ", "),
        module_note = [
            "# Once db/models.jl defines models, import them here for the handlers (`import ..appM`):",
            "#   PormG.@import_models \"../db/models.jl\" models",
            "#   const appM = models",
        ],
        boot = [
            "sync_pormg_env!()  # NITRO_ENV -> PORMG_ENV, only when NITRO_ENV is set",
            "# PormG parses db/connection.yml, validates it and connects, from any working directory",
            "PormG.Configuration.load_many([\"db\"]; root = pkgdir(@__MODULE__))",
        ],
        store = "pormg_nitro_worker(db_key = \"db\")",
        deps = ["PormG" => string(Base.PkgId(PormG).uuid); [n => drivers[n][1] for n in names]],
        sources = ["PormG" => "{url = \"$(pin.url)\", rev = \"$(pin.rev)\"}"],
        compat = ["PormG" => pin.compat; [n => drivers[n][2] for n in names]],
        gitignore = ["db/connection.yml"],
    )
    # Nitro's files first, so an abandoned prompt still leaves a complete app.
    write_app(db(String[]))
    # `setup` offers to install PormG's AI skills into `pwd()`, not next to the folder it was
    # given, so run it from the app root or a "yes" puts them wherever the REPL happens to be.
    cd(() -> PormG.setup(joinpath(root, "db")), root)

    yml = joinpath(root, "db", "connection.yml")
    isfile(yml) || return nothing
    names = String[]
    for m in eachmatch(r"(?m)^\s*adapter:\s*['\"]?([A-Za-z]+)", read(yml, String))
        adapter = lowercase(m[1])
        driver = startswith(adapter, "sqlite") ? "SQLite" :
                 startswith(adapter, "postgres") ? "LibPQ" : nothing
        if driver === nothing
            @warn "newapp: no database driver added for this adapter; add the package it needs " *
                  "to Project.toml and the app's `using` line" adapter = m[1]
        elseif !(driver in names)
            push!(names, driver)
        end
    end
    isempty(names) || write_app(db(sort!(names)))
    return nothing
end

end # module NitroPormGExt
