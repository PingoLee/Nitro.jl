module SessionMiddleware_

using HTTP
using Dates
using JSON
using ...Types: AbstractSessionStore, MemoryStore, SessionPayload, Nullable
using ...Types: get_session, set_session!, delete_session!, cleanup_expired_sessions!
using ...Types: CookieConfig
using ...Cookies: format_cookie, get_cookie

export SessionMiddleware

# Default session store (shared across all requests)
const DEFAULT_STORE = MemoryStore{String, Dict{String,Any}}()

"""
    SessionMiddleware(; cookie_name, secret_key, max_age, store, prune_interval)

Creates a middleware that manages server-side sessions with cookie-based session IDs.
"""
function SessionMiddleware(;
    cookie_name::String = "nitro_session",
    secret_key::Nullable{String} = nothing,
    max_age::Int = 86400,
    store::AbstractSessionStore = DEFAULT_STORE,
    prune_probability::Float64 = 0.01,
    secure::Bool = true,
    httponly::Bool = true,
    samesite::String = "Lax",
    path::String = "/",
    domain::Nullable{String} = nothing,
    config::CookieConfig = CookieConfig(
        secret_key = secret_key,
        httponly = httponly,
        secure = secure,
        samesite = samesite,
        path = path,
        domain = domain,
        maxage = max_age,
    ),
    validator::Union{Function, Nothing} = nothing)

    return function(handle::Function)
        return function(req::HTTP.Request)
            # Probabilistic pruning of expired sessions
            if rand() < prune_probability
                cleanup_expired_sessions!(store)
            end

            # 1. Load or create session
            session_id = _get_session_id(req, cookie_name)
            session_data, is_new = _load_session(store, session_id)

            # Generate a new session ID if there's no existing valid one
            if is_new
                session_id = _generate_session_id()
            end

            # 2. Inject session into request
            req.context[:session] = session_data
            req.context[:session_id] = session_id

            # 3. Call next handler
            response = handle(req)

            # 4. Save session and set cookie
            _save_session(store, session_id, req.context[:session], max_age)
            
            # Add Set-Cookie header to response
            HTTP.setheader(response, "Set-Cookie" => format_cookie(cookie_name, session_id, config))

            return response
        end
    end
end

function _get_session_id(req::HTTP.Request, cookie_name::String)
    return get_cookie(req, cookie_name)
end

function _generate_session_id()
    return Base.UUIDs.uuid4() |> string
end

function _load_session(store::AbstractSessionStore, session_id::Nullable{String})
    if isnothing(session_id)
        return Dict{String,Any}(), true
    end

    data = get_session(store, session_id)
    if isnothing(data)
        return Dict{String,Any}(), true
    end

    return data, false
end

function _save_session(store::AbstractSessionStore, session_id::String, data::Dict{String,Any}, max_age::Int)
    set_session!(store, session_id, data; ttl=max_age)
end

end # module SessionMiddleware_
