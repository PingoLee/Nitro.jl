module SessionMiddleware_

using HTTP
using Dates
using JSON
using UUIDs
using ...Types: AbstractSessionStore, MemoryStore, SessionPayload, Nullable
using ...Types: CookieConfig
using ...Cookies: get_cookie, set_cookie!, storesession!, prunesessions!, regenerate_session!
using ...Crypto: secure_uuid4
using ...Core: own_response_headers

export SessionMiddleware

const DEFAULT_STORE = MemoryStore{String, Dict{String,Any}}()

"""
    SessionMiddleware(; cookie_name, secret_key, max_age, store, prune_probability,
                        rotate_on_auth, auth_key, validator, ...)

Creates a middleware that manages server-side sessions with cookie-based session IDs. The
mutable session dictionary is exposed as `req.session` (`req.context[:session]`).

# Session fixation defense (`rotate_on_auth`, `auth_key`, `validator`)

When `rotate_on_auth=true` (the default), an existing session is assigned a **new** session
ID whenever its authenticated identity changes during a request — i.e. on login, logout, or
a user switch — so a pre-login session ID can never be replayed against the post-login
session. The identity is captured before the handler runs and compared after.

How that identity is resolved, in order:

- `auth_key::String = "user_id"` — the session key whose value *is* the identity. This is
  the common case: your login handler sets `req.session["user_id"] = …` and logout clears
  it; the change triggers regeneration.
- `validator::Union{Function, Nothing} = nothing` — an optional **fallback identity
  resolver**, consulted *only* when `auth_key` is absent from the session (and a session ID
  exists). It is arity-dispatched — called as `validator(session_id, session_data)` if that
  method exists, else `validator(session_id)` — and its return value is the identity marker
  used for change detection.

The `validator` participates in fixation detection **only**; it never populates
`req.user`. Authenticating a request (attaching a principal) is the job of `BearerAuth` /
`CookieAuthMiddleware`, and guards read `req.user` / the raw session there. This separation
is deliberate: `SessionMiddleware` owns session *state and rotation*, not the auth identity
contract.

# Other keyword arguments

- `cookie_name::String = "nitro_session"`, `store`, `max_age::Int`, `prune_probability::Float64`.
- Cookie attributes (`secure`, `httponly`, `samesite`, `path`, `domain`, `secret_key`) or a
  fully-formed `config::CookieConfig`.
"""
function SessionMiddleware(;
    cookie_name::String = "nitro_session",
    secret_key::Nullable{String} = nothing,
    max_age::Int = 86400,
    store::AbstractSessionStore{String, Dict{String,Any}} = DEFAULT_STORE,
    prune_probability::Float64 = 0.01,
    secure::Bool = true,
    httponly::Bool = true,
    samesite::String = "Lax",
    path::String = "/",
    domain::Nullable{String} = nothing,
    rotate_on_auth::Bool = true,
    auth_key::String = "user_id",
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
            # Keep pruning cheap by only cleaning expired sessions occasionally.
            if rand() < prune_probability
                prunesessions!(store)
            end

            # Load the current payload and remember the auth marker before the handler runs.
            session_id = _get_session_id(req, cookie_name)
            session_data, is_new = _load_session(store, session_id)
            original_session = deepcopy(session_data)
            original_auth_marker = _auth_marker(session_data, session_id, auth_key, validator)

            # New visitors start with a fresh random session identifier.
            if is_new
                session_id = _generate_session_id()
            end

            # Expose the mutable session dictionary through the request context.
            req.context[:session] = session_data
            req.context[:session_id] = session_id

            # Let downstream middleware and the handler read or mutate the session.
            response = handle(req)

            current_session = req.context[:session]
            final_session_id = get(req.context, :session_id, session_id)

            # Retire the previous ID when an existing session crosses an auth boundary.
            if rotate_on_auth && !is_new && final_session_id == session_id
                current_auth_marker = _auth_marker(current_session, final_session_id, auth_key, validator)
                if _auth_marker_changed(original_auth_marker, current_auth_marker)
                    regenerate_session!(req, store; ttl=max_age)
                    final_session_id = req.context[:session_id]
                end
            end

            session_changed = is_new || final_session_id != session_id || current_session != original_session
            if session_changed
                _save_session(store, final_session_id, current_session, max_age)

                # Own the headers before adding Set-Cookie: `response` may be a shared/`const`
                # object (e.g. an auth-rejection response). Mutating it in place would attach
                # this visitor's session cookie to every later request that returns the same
                # object — a cross-request session leak — and races other threads.
                response = own_response_headers(response)
                # Append the session cookie without clobbering any sibling Set-Cookie headers.
                set_cookie!(response, cookie_name, final_session_id; config=config, encrypted=false, maxage=max_age)
            end

            return response
        end
    end
end

function _get_session_id(req::HTTP.Request, cookie_name::String)
    return get_cookie(req, cookie_name)
end

function _generate_session_id()
    return string(secure_uuid4())
end

function _load_session(store::AbstractSessionStore{String, Dict{String,Any}}, session_id::Nullable{String})
    if isnothing(session_id)
        return Dict{String,Any}(), true
    end

    payload = Base.get(store, session_id, nothing)
    if isnothing(payload)
        return Dict{String,Any}(), true
    end

    if payload isa SessionPayload
        if payload.expires <= Dates.now(Dates.UTC)
            return Dict{String,Any}(), true
        end
        return copy(payload.data), false
    end

    data = payload isa AbstractDict ? copy(payload) : payload
    return data, false
end

function _auth_marker(session_data::Dict{String,Any}, session_id::Nullable{String}, auth_key::String, validator::Union{Function, Nothing})
    # Prefer the explicit session key and fall back to a validator-derived identity.
    auth_marker = _auth_marker_for_key(session_data, auth_key)
    if !isnothing(auth_marker) || isnothing(validator) || isnothing(session_id)
        return auth_marker
    end

    if applicable(validator, session_id, session_data)
        return validator(session_id, session_data)
    end

    if applicable(validator, session_id)
        return validator(session_id)
    end

    return nothing
end

function _auth_marker_for_key(session_data::Dict{String,Any}, auth_key::String)
    if haskey(session_data, auth_key)
        return session_data[auth_key]
    end

    auth_sym = Symbol(auth_key)
    if haskey(session_data, auth_sym)
        return session_data[auth_sym]
    end

    return nothing
end

function _auth_marker_changed(original_auth_marker, current_auth_marker)
    return !isequal(original_auth_marker, current_auth_marker)
end

function _save_session(store::AbstractSessionStore{String, Dict{String,Any}}, session_id::String, data::Dict{String,Any}, max_age::Int)
    storesession!(store, session_id, data; ttl=max_age)
end

end # module SessionMiddleware_
