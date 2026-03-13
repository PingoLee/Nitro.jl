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
    Param, isrequired, LazyRequest, headers, pathparams, queryvars, jsonbody, formbody, textbody,
    CookieConfig, Cookie, Session, SessionPayload,
    AbstractSessionStore, get_session, set_session!, delete_session!, cleanup_expired_sessions!,
    MemoryStore, Extractor,
    RouteDefinition

const Nullable{T} = Union{T, Nothing}

abstract type Extractor{T} end
abstract type AbstractSessionStore end

function get_session(store::AbstractSessionStore, session_id)
    throw(MethodError(get_session, (store, session_id)))
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
struct MemoryStore{K, V} <: AbstractSessionStore
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
            delete!(store.data, key)
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

pathparams(req::HTTP.Request) = HTTP.getparams(req)
queryvars(req::HTTP.Request)  = HTTP.queryparams(req)
headers(req::HTTP.Request)   = HTTP.headers(req)

jsonbody(req::HTTP.Request; kwargs...) = json(req; kwargs...)
formbody(req::HTTP.Request)           = formdata(req)
textbody(req::HTTP.Request)           = text(req)

# ─── Routing ──────────────────────────────────────────────────────────

@kwdef struct RouteDefinition
    path::String
    method::String
    handler::Function
    middleware::Vector{Function} = Function[]
    name::Nullable{String} = nothing
end

end # module Types
