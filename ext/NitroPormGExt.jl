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
        m.objects.filter("expires_at__lte" => now_utc).delete()
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
# SECTION 5: Initialization
# ============================================================================

function __init__()
    # Register the password field hook with PormG when the normalize_field_value
    # seam is available (Phase 3 upstream dependency).
    # Until Phase 3 lands in PormG, this is a no-op skeleton.
    if isdefined(PormG, :register_field_hook)
        PormG.register_field_hook(:PasswordField, :auto_hash, hash_password_field)
    end

    # Pre-initialize the session model so it's ready when needed
    _SESSION_MODEL[] = _define_session_model()
end

end # module NitroPormGExt
