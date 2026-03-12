module SessionMiddleware_

using HTTP
using Dates
using JSON
using ...Types: MemoryStore, SessionPayload, Nullable, LifecycleMiddleware
using ...Cookies: storesession!, prunesessions!, format_cookie, get_cookie

export SessionMiddleware

# Default session store (shared across all requests)
const DEFAULT_STORE = MemoryStore{String, Dict{String,Any}}()

"""
    SessionMiddleware(; cookie_name, secret_key, max_age, store, prune_interval)

Creates a middleware that manages server-side sessions with cookie-based session IDs.

## How it works
1. **On request**: Reads the session cookie, loads session data from the store, 
   and injects it into `req.context[:session]` as a `Dict{String,Any}`.
2. **On response**: If session data was modified, saves it back to the store 
   and sets the session cookie on the response.

## Keyword Arguments
- `cookie_name::String`: Name of the session cookie (default: `"nitro_session"`).
- `secret_key::Union{String,Nothing}`: Secret key for cookie signing (default: `nothing`).
- `max_age::Int`: Session TTL in seconds (default: `86400` = 24 hours).
- `store::MemoryStore`: The session store backend (default: shared in-memory store).
- `prune_probability::Float64`: Probability of pruning expired sessions per request (default: `0.01`).

## Example
```julia
serve(middleware=[
    SessionMiddleware(;
        cookie_name = "my_session",
        max_age     = 3600,  # 1 hour
    )
])

@get "/login" function(req)
    req.context[:session]["user_id"] = 42
    return Dict("status" => "logged in")
end

@get "/dashboard" function(req)
    user_id = get(req.context[:session], "user_id", nothing)
    return Dict("user_id" => user_id)
end
```
"""
function SessionMiddleware(;
    cookie_name::String = "nitro_session",
    secret_key::Nullable{String} = nothing,
    max_age::Int = 86400,
    store::MemoryStore{String, Dict{String,Any}} = DEFAULT_STORE,
    prune_probability::Float64 = 0.01,
    secure::Bool = true,
    httponly::Bool = true,
    samesite::String = "Lax")

    return function(handle::Function)
        return function(req::HTTP.Request)
            # Probabilistic pruning of expired sessions
            if rand() < prune_probability
                prunesessions!(store)
            end

            # 1. Load or create session
            session_id = _get_session_id(req, cookie_name)
            session_data, is_new = _load_session(store, session_id)

            # Generate a new session ID if there's no existing valid one
            if is_new
                session_id = _generate_session_id()
            end

            # 2. Inject session into request context
            req.context[:session] = session_data
            req.context[:session_id] = session_id

            # Take a snapshot to detect modifications
            snapshot = copy(session_data)

            # 3. Call the handler
            response = handle(req)

            # 4. Check if session was modified and save if needed
            current_session = req.context[:session]
            if current_session != snapshot || is_new
                storesession!(store, session_id, current_session; ttl=max_age)

                # Set the session cookie on the response
                cookie_value = session_id
                cookie_str = format_cookie(
                    cookie_name, cookie_value;
                    path="/",
                    httponly=httponly,
                    secure=secure,
                    samesite=samesite,
                    maxage=max_age
                )
                push!(response.headers, "Set-Cookie" => cookie_str)
            end

            return response
        end
    end
end

# ─── Internal helpers ─────────────────────────────────────────────────

"""
Extract the session ID from the request cookie.
"""
function _get_session_id(req::HTTP.Request, cookie_name::String)::Nullable{String}
    val = get_cookie(req, cookie_name, nothing)
    return isnothing(val) ? nothing : String(val)
end

"""
Load session data from the store. Returns (data, is_new).
"""
function _load_session(store::MemoryStore{String, Dict{String,Any}}, session_id::Nullable{String})
    if isnothing(session_id)
        return (Dict{String,Any}(), true)
    end

    payload = Base.get(store, session_id, nothing)
    if isnothing(payload)
        return (Dict{String,Any}(), true)
    end

    # Check expiry
    if payload.expires <= Dates.now(Dates.UTC)
        return (Dict{String,Any}(), true)
    end

    return (copy(payload.data), false)
end

"""
Generate a cryptographically random session ID.
"""
function _generate_session_id()::String
    bytes = rand(UInt8, 32)
    return bytes2hex(bytes)
end

end # module
