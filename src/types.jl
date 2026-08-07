module Types
"""
This module holds Structs that are used throughout the application
"""

using HTTP
using Sockets
using JSON
using Dates
using Base: @kwdef
using DataStructures: CircularDeque
using ..Util

export Server, Nullable, Context,
    LifecycleMiddleware, startup, shutdown,
    Param, isrequired, LazyRequest, headers, pathparams, queryvars, jsonbody, formbody, textbody, multipartbody,
    CookieConfig, Cookie, Session, SessionPayload,
    AbstractSessionStore, get_session, set_session!, delete_session!, cleanup_expired_sessions!,
    MemoryStore, Extractor,
    RouteDefinition, Principal

const Nullable{T} = Union{T, Nothing}
const Server = HTTP.Server

abstract type Extractor{T} end
abstract type AbstractSessionStore{K, V} end

"""
    Principal(claims; id=nothing, kid=nothing, source=:claim)

The normalized authenticated principal that Nitro auth middleware attaches at
`req.context[:user]` (readable as `req.user`).

Behaves as a **read-only** claims dictionary — `principal["sub"]`, `get`, `haskey`,
iteration, and JSON serialization all read through to the verified claims — with
normalized identity available as typed fields:

- `id::Nullable{String}` — the resolved identity: the configured identity claim
  (default `"sub"`), or the verified key id when identity derives from `kid`.
  `nothing` when the token carries no identity claim (e.g. service/capability
  tokens) — the request is still authenticated.
- `claims::Dict{String,Any}` — the verified token claims.
- `kid::Nullable{String}` — the **keyset-verified** key id, or `nothing`. Only ever
  populated when the token was verified against a keyset; a `kid` header on a
  single-secret token is an unverified label and is never exposed here.
- `source::Symbol` — where `id` came from: `:claim` or `:kid`.

A `Principal` is immutable: it is a verified security artifact. Use `Dict(principal)`
for a mutable copy, or a `user_validator` to build an enriched application user.
"""
struct Principal <: AbstractDict{String, Any}
    id::Nullable{String}
    claims::Dict{String, Any}
    kid::Nullable{String}
    source::Symbol
end

function Principal(claims::AbstractDict; id=nothing, kid=nothing, source::Symbol=:claim)
    normalized = claims isa Dict{String, Any} ? claims :
        Dict{String, Any}(string(key) => value for (key, value) in pairs(claims))
    return Principal(
        id === nothing ? nothing : string(id),
        normalized,
        kid === nothing ? nothing : String(kid),
        source,
    )
end

# Read-only dict interface, delegating to the verified claims. `get`/`haskey` have no
# generic AbstractDict fallback, so these delegations are load-bearing for the guards'
# `get(user, key, nothing)` calls. Deliberately no `setindex!`/`delete!`/`pop!`.
Base.iterate(principal::Principal) = iterate(getfield(principal, :claims))
Base.iterate(principal::Principal, state) = iterate(getfield(principal, :claims), state)
Base.length(principal::Principal) = length(getfield(principal, :claims))
Base.get(principal::Principal, key, default) = get(getfield(principal, :claims), key, default)
Base.get(f::Base.Callable, principal::Principal, key) = get(f, getfield(principal, :claims), key)
Base.getindex(principal::Principal, key) = getindex(getfield(principal, :claims), key)
Base.haskey(principal::Principal, key) = haskey(getfield(principal, :claims), key)
Base.keys(principal::Principal) = keys(getfield(principal, :claims))
Base.values(principal::Principal) = values(getfield(principal, :claims))

@kwdef struct Param{T}
    name::Symbol
    type::Type{T} = T
    default::Nullable{T} = nothing
    hasdefault::Bool = false
end

Param(name::Symbol, type::Type{T}, default, hasdefault::Bool) where {T} =
    Param{T}(name, type, default === missing ? nothing : default, hasdefault)

isrequired(param::Param) = !param.hasdefault

function get_session(store::AbstractSessionStore{K, V}, session_id::K) where {K, V}
    payload = Base.get(store, session_id, nothing)
    if isnothing(payload)
        return nothing
    end

    if payload isa SessionPayload{V}
        if payload.expires <= Dates.now(Dates.UTC)
            return nothing
        end
        return _copy_session_value(payload.data)
    end

    return payload
end

function set_session!(store::AbstractSessionStore, session_id, data; ttl::Int = 3600)
    throw(MethodError(set_session!, (store, session_id, data)))
end

function delete_session!(store::AbstractSessionStore, session_id)
    throw(MethodError(delete_session!, (store, session_id)))
end

function cleanup_expired_sessions!(store::AbstractSessionStore)
    throw(MethodError(cleanup_expired_sessions!, (store,)))
end

# Generic cookie configuration
@kwdef struct CookieConfig
    secret_key::Nullable{String} = nothing
    httponly::Bool = true
    secure::Bool = true
    samesite::String = "Lax"
    path::String = "/"
    domain::Nullable{String} = nothing
    maxage::Nullable{Int} = nothing
    expires::Nullable{DateTime} = nothing
    max_cookie_size::Nullable{Int} = nothing
end

# Represents a cookie extractor
struct Cookie{T} <: Extractor{T}
    name::String
    value::Nullable{T}
    
    function Cookie(name::String, val_or_type::Any)
        if val_or_type isa Type
            return new{val_or_type}(name, nothing)
        else
            return new{typeof(val_or_type)}(name, val_or_type)
        end
    end

    # Also allow explicit type specification
    Cookie{T}(name::String, value::Nullable{T}=nothing) where T = new{T}(name, value)
end

# Represents a session extractor
struct Session{T} <: Extractor{T}
    name::String
    payload::Nullable{T}
    validate::Union{Function, Nothing}
    type::Type{T}

    function Session(name::String, val_or_type::Any)
        if val_or_type isa Type
            return new{val_or_type}(name, nothing, nothing, val_or_type)
        else
            return new{typeof(val_or_type)}(name, val_or_type, nothing, typeof(val_or_type))
        end
    end
    
    Session{T}(name::String, payload::Nullable{T}=nothing, validate::Union{Function, Nothing}=nothing) where T = new{T}(name, payload, validate, T)
end

# Represents a session with metadata (like discovery/expiry time)
struct SessionPayload{T}
    data::T
    expires::DateTime
end

# A thread-safe in-memory store for sessions
struct MemoryStore{K, V} <: AbstractSessionStore{K, V}
    data::Dict{K, SessionPayload{V}}
    lock::Base.ReentrantLock
    MemoryStore{K, V}() where {K, V} = new{K, V}(Dict{K, SessionPayload{V}}(), Base.ReentrantLock())
end

function Base.get(store::MemoryStore, key, default)
    lock(store.lock) do
        return Base.get(store.data, key, default)
    end
end

function _copy_session_value(value)
    if value isa AbstractDict || value isa AbstractArray
        return copy(value)
    end
    return value
end

function get_session(store::MemoryStore{K, V}, key::K) where {K, V}
    lock(store.lock) do
        payload = Base.get(store.data, key, nothing)
        if isnothing(payload)
            return nothing
        end

        if payload.expires <= Dates.now(Dates.UTC)
            return nothing
        end

        return _copy_session_value(payload.data)
    end
end

function set_session!(store::MemoryStore{K, V}, key::K, value::V; ttl::Int = 3600) where {K, V}
    lock(store.lock) do
        store.data[key] = SessionPayload(value, Dates.now(Dates.UTC) + Dates.Second(ttl))
    end
    return value
end

function delete_session!(store::MemoryStore{K, V}, key) where {K, V}
    lock(store.lock) do
        delete!(store.data, key)
    end
    return nothing
end

function cleanup_expired_sessions!(store::MemoryStore)
    current_time = Dates.now(Dates.UTC)
    lock(store.lock) do
        for (key, payload) in store.data
            if payload.expires <= current_time
                delete!(store.data, key)
            end
        end
    end
    return nothing
end

# ── Middleware-chain cache (copy-on-write) ──────────────────────────────────────
# Maps a route key ("METHOD|path", see `genkey`) to that route's fully-composed middleware
# chain. Read on the request hot path (`compose`, src/routerhof.jl); written only during
# cache warmup — once per route, then never again.
#
# Shape: copy-on-write behind an atomic reference, NOT a lock around the read. A reader
# takes one acquire-load of `entries` and works on that snapshot; a writer copies the
# current table under `lock`, inserts, and release-stores the copy. No `Dict` reachable by
# a reader is ever mutated by *this module* — that is the entire safety argument. Julia's
# `Dict` tolerates concurrent *readers*, but never a reader concurrent with `setindex!`: a
# `rehash!` swaps the backing `slots`/`keys`/`vals` arrays underneath the reader, yielding
# a wrong lookup (one route's chain served for another), a `BoundsError`, or a segfault.
#
# Scope of the guarantee, stated honestly: `@atomic` makes the *publish* unwritable, but
# nothing makes a returned *snapshot* unwritable. `ServerContext` is public, so app code
# can reach `ctx.service.middleware_cache` and `setindex!` a snapshot, reintroducing this
# bug with no error. `snapshot`'s "immutable by convention" is a convention, enforced by
# review rather than by the type.
#
# Why not simply lock the read: every request on an already-cached route would then
# serialize through one `ReentrantLock`. Every request runs on `Threads.@spawn`, so that is
# a permanent hot-path cost paid to close a window that only exists during warmup. The
# steady state here is pure lock-free reads instead.
#
# Cost of the trade: each write copies the whole table, so warming R routes is O(R^2)
# insertions in aggregate and discards R intermediate tables. One-time and off the
# steady-state path, but it does mean a burst of garbage proportional to the route table.
# The O(R^2) shape is the durable fact; a wall-clock number here would only rot. If a route
# table ever gets big enough for this to matter, the answer is to build the table once at
# route-registration time, not to abandon copy-on-write.
#
# `entries` is `@atomic`, so a plain `cache.entries = ...` raises ConcurrencyViolationError:
# the type makes the unsynchronized publish that caused this bug unwritable. Bare *reads*
# are still legal (and only `:monotonic`) — always go through `snapshot`.
#
# Relation to `_Writer`/`_Run` in src/middleware/access_log.jl: same generation-swap idea,
# specialized rather than departed from. `access_log` publishes a plain `run` field via the
# separate `active` atomic the reader must load anyway, so its publish rides free. Here
# there is one reference and no gate, so atomicizing that reference directly is the whole
# mechanism.
#
# The value type is abstract on purpose: each route's chain is a distinct closure type
# produced by `reduce(|>, layers)` in `buildmiddleware`, so no concrete type spans the
# table. Narrowing it would need FunctionWrappers, which pins the return type and breaks
# `serialize=false` (where a handler's raw return value flows out through `compose`).
mutable struct MiddlewareCache
    @atomic entries :: Dict{String, Function}
    const lock      :: Base.ReentrantLock
end

MiddlewareCache() = MiddlewareCache(Dict{String, Function}(), Base.ReentrantLock())

"""
    snapshot(cache::MiddlewareCache) -> Dict{String, Function}

Reader fast path: one acquire-load, allocation-free. The returned `Dict` is immutable by
convention — never `setindex!`/`delete!` it. The `:acquire` pairs with the `:release` in
[`cache!`](@ref) / `empty!`, so a chain is fully constructed by the time a reader can
observe it.
"""
@inline snapshot(cache::MiddlewareCache) = @atomic :acquire cache.entries

"""
    cache!(cache::MiddlewareCache, key::String, chain::Function) -> Function

Publish `key => chain` unless `key` is already cached; return the chain now in force.
First writer wins, so a route's cached chain never changes identity underneath a reader.
Warmup path only — takes the lock and copies the whole table.
"""
function cache!(cache::MiddlewareCache, key::String, chain::Function)
    return lock(cache.lock) do
        # `:monotonic` suffices: the lock's own acquire/release edges already order this
        # read against every other writer's publish and that publish's `Dict` contents.
        current  = @atomic :monotonic cache.entries
        existing = get(current, key, nothing)
        isnothing(existing) || return existing
        updated = copy(current)
        # Not a rehash-avoidance trick — the rehash happens either way. This forces a
        # tighter growth curve (16→32→64→…) than `setindex!`'s own policy (16→64→256…),
        # so each generation's backing array stays right-sized: cheaper copies and
        # measurably less garbage across a warmup. It also right-sizes the odd generation
        # where `copy` preserved an over-large capacity.
        sizehint!(updated, length(current) + 1)
        updated[key] = chain
        @atomic :release cache.entries = updated
        return chain
    end
end

"""
    empty!(cache::MiddlewareCache) -> MiddlewareCache

Drop every cached chain by publishing a fresh table. Deliberately NOT an in-place
`empty!` of the live `Dict`: `terminate` (src/core.jl) calls this with requests still in
`compose`, and an in-flight reader must be able to finish against a table nobody mutates.
"""
function Base.empty!(cache::MiddlewareCache)
    lock(cache.lock) do
        @atomic :release cache.entries = Dict{String, Function}()
    end
    return cache
end

# Represents the application context
struct Context{T}
    payload::T
end


@kwdef struct LifecycleMiddleware 
    # The middleware function itself (handles incoming requests)
    middleware :: Function
    # A hook that's called when the server starts up (optional)
    on_startup :: Union{Function,Nothing} = nothing
    # A hook that's called when the server is shutdown (optional)
    on_shutdown :: Union{Function,Nothing} = nothing
end

function startup(lf::LifecycleMiddleware)
    if !isnothing(lf.on_startup)
        try 
            lf.on_startup()
        catch error
            @error "Error in LifecycleMiddleware.on_startup: " exception=(error, catch_backtrace())
        end
    end
end

function shutdown(lf::LifecycleMiddleware)
    if !isnothing(lf.on_shutdown)
        try
            lf.on_shutdown()
        catch error
            @error "Error in LifecycleMiddleware.on_shutdown: " exception=(error, catch_backtrace())
        end
    end
end


# ─── Lazy Request Accessors ───────────────────────────────────────────

struct LazyRequest
    req::HTTP.Request
end

LazyRequest(; request::HTTP.Request) = LazyRequest(request)

function Base.getproperty(request::LazyRequest, sym::Symbol)
    if sym === :request
        return getfield(request, :req)
    end
    return getfield(request, sym)
end

pathparams(req::HTTP.Request) = HTTP.getparams(req)
queryvars(req::HTTP.Request)  = HTTP.queryparams(HTTP.URI(req.target).query)
# HTTP.jl v2 canonicalizes header field names to Title-Case (e.g. "Content-Type").
# Header names are case-insensitive per RFC 9110, and downstream consumers (the
# `Header` extractor's `struct_builder`, cookie lookups) match against lowercase
# keys, so normalize to lowercase here for stable, case-insensitive access.
headers(req::HTTP.Request)   = Dict(lowercase(String(k)) => String(v) for (k, v) in req.headers)

jsonbody(req::HTTP.Request; kwargs...) = json(req; kwargs...)
formbody(req::HTTP.Request)           = formdata(req)
textbody(req::HTTP.Request)           = text(req)
multipartbody(req::HTTP.Request)      = multipart(req)

pathparams(request::LazyRequest) = pathparams(request.req)
queryvars(request::LazyRequest) = queryvars(request.req)
headers(request::LazyRequest) = headers(request.req)

jsonbody(request::LazyRequest; kwargs...) = jsonbody(request.req; kwargs...)
formbody(request::LazyRequest) = formbody(request.req)
textbody(request::LazyRequest) = textbody(request.req)
multipartbody(request::LazyRequest) = multipartbody(request.req)

# ─── Routing ──────────────────────────────────────────────────────────

@kwdef struct RouteDefinition
    pattern::String
    handler::Function
    methods::Vector{String} = String[]
    name::Nullable{String} = nothing
    middleware::Nullable{Vector} = nothing
    type_hints::Dict{Symbol, Type} = Dict{Symbol, Type}()
end

RouteDefinition(pattern::String, handler::Function, methods::Vector{String}, name, middleware, type_hints) =
    RouteDefinition(; pattern, handler, methods, name, middleware, type_hints)

RouteDefinition(path::String, method::String, handler::Function, middleware::Vector{Function}, name::Nullable{String}) =
    RouteDefinition(; pattern=path, handler, methods=[method], name, middleware, type_hints=Dict{Symbol, Type}())

end # module Types
