module SessionMiddleware_

using HTTP
using Dates
using JSON
using UUIDs
using ...Types: AbstractSessionStore, MemoryStore, SessionPayload, Nullable, is_expired
using ...Types: CookieConfig, LifecycleMiddleware, require_fixed_period
using ...Cookies: get_cookie, set_cookie!, storesession!, prunesessions!, regenerate_session!
using ...Crypto: secure_uuid4
using ...Core: own_response_headers

export SessionMiddleware, SessionPruner

# There is deliberately NO default store (#171). A `const DEFAULT_STORE` used to live here, and
# every `SessionMiddleware()` built without `store=` shared that one process-wide instance --
# so two notionally-independent `App`s in one process shared a session table, and each
# activation spawned its own prune janitor over it. That is the same class of process-global
# #31 removed when `App` replaced the `CONTEXT[]` singleton. `store` is now required, and
# omitting it is an `UndefKeywordError` rather than a silent share.

# ── Background pruning (#36) ───────────────────────────────────────────────────────────────
#
# Pruning used to run INLINE on the request path: `rand() < prune_probability` (default 0.01)
# made roughly 1 request in 100 pay a full O(N) scan of the store, and `MemoryStore` runs that
# scan under the single lock every other session read and write also needs. At 100k live
# sessions every concurrent request blocked behind that scan — periodic p99 spikes and a
# throughput cliff, caused by the component that is on every stateful request.
#
# That design is PHP's `session.gc_probability`/`gc_divisor`, and PHP is where the evidence
# against it comes from too: Debian and Ubuntu ship PHP with `session.gc_probability=0` and a
# cron job instead, for exactly this reason. Django (`manage.py clearsessions`) and Rails
# (`rake db:sessions:trim`) never prune on the request path at all. Nitro can do better than
# an external cron because it already has `LifecycleMiddleware`: the prune becomes an
# in-process janitor tied to server startup and shutdown, which is the Go idiom (`go-cache`'s
# janitor goroutine).
#
# Note what this does NOT need to fix: expiry is already enforced lazily on the read path
# (`get_session` refuses a payload whose `expires` has passed, src/types.jl), so an unpruned
# store has never served a stale session. Pruning is purely about reclaiming memory.



# Builds the `(on_startup, on_shutdown)` pair for a store-pruning janitor.
#
# The per-activation stop-token discipline is `FixedRateLimiter`'s, verbatim and for the same
# reason (src/middleware/rate_limiter.jl): `on_shutdown` cannot wait for the task — it may be
# parked in `sleep(interval)`, up to a whole interval from its next check — so a
# `serve(); terminate(); serve()` cycle overlaps the old task with the new activation. A single
# shared `running` flag leaked one task per restart, because the stale task woke, read the flag
# the NEW activation had just set true, and kept looping. Giving each activation its own `Ref`
# means a stale task can only ever observe its own token, which `on_shutdown` already set false.
#
# `Threads.@spawn`, not `@async` — and this is where the janitor differs from the rate
# limiter's sweep. That sweep touches only the limiter's own in-memory Dict; this one calls
# `cleanup_expired_sessions!` on a store the CALLER supplied, and for `PormGSessionStore` that
# is a blocking SQL DELETE. Per src/Workers/api.jl, `@async` is acceptable only for a task that
# runs no user code, so a janitor over a user store must not share a thread with request
# handlers.
function _prune_janitor(store::AbstractSessionStore, interval::Period, label::String,
                       kwname::String)
    # `kwname`, not a hardcoded "prune_interval": `SessionPruner`'s keyword is `interval`, and
    # an error naming a keyword the caller's function does not have sends them hunting.
    require_fixed_period("$label: $kwname", interval)

    active = Ref{Union{Ref{Bool},Nothing}}(nothing)
    prune_task = Ref{Union{Task,Nothing}}(nothing)

    # Returns the `Task` it spawned, or `nothing` if one was already running. `startup` discards
    # it; tests call `lf.on_startup()` directly to observe that a stale task actually exits.
    on_startup = function ()
        isnothing(active[]) || return nothing      # idempotent across restarts
        token = Ref(true)
        active[] = token
        prune_task[] = errormonitor(Threads.@spawn while token[]
            sleep(interval)
            # Re-check AFTER the sleep: `on_shutdown` may have fired while we were parked, and
            # this is where a stale activation's task leaves for good.
            token[] || break
            try
                prunesessions!(store)
            catch e
                # A failing store must not kill the janitor — the next tick may well succeed,
                # and a dead janitor is a silent memory leak.
                @error "Nitro.$label: session prune failed" exception=(e, catch_backtrace())
            end
        end)
        return prune_task[]
    end

    # Signalling is all this can do; blocking `terminate` for up to a whole interval would be
    # worse than letting the task drain.
    on_shutdown = function ()
        token = active[]
        isnothing(token) || (token[] = false)
        stopped = prune_task[]
        active[] = nothing
        prune_task[] = nothing
        return stopped
    end

    return (on_startup, on_shutdown)
end

"""
    SessionPruner(store::AbstractSessionStore; interval::Period = Minute(10))

A `LifecycleMiddleware` that periodically removes expired sessions from `store` and does
nothing else to the request — a pass-through with a background janitor attached.

`SessionMiddleware` already installs one of these internally, so you only need `SessionPruner`
when you reach sessions **without** it: the `Session{T}` extractor and `storesession!` both
work against a store passed through the app context, and nothing on that path ever prunes. A
long-lived `MemoryStore` used that way grows until the process runs out of memory. (It never
serves a stale session — expiry is checked on read — so this is a memory concern, not a
correctness one.)

```julia
store = MemoryStore{String, Dict{String,Any}}()
serve(app, middleware = [SessionPruner(store; interval = Minute(5))], context = store)
```

The janitor starts on `serve()` and stops on `terminate()`. Its hooks are idempotent, so a
`serve(); terminate(); serve()` cycle does not leak a task.
"""
function SessionPruner(store::AbstractSessionStore; interval::Period = Minute(10))
    on_startup, on_shutdown = _prune_janitor(store, interval, "SessionPruner", "interval")
    return LifecycleMiddleware(;
        middleware = handle -> (req -> handle(req)),
        on_startup = on_startup,
        on_shutdown = on_shutdown)
end

"""
    SessionMiddleware(; store, cookie_name, secret_key, max_age, prune_interval,
                        rotate_on_auth, auth_key, validator, ...)

Creates a `LifecycleMiddleware` that manages server-side sessions with cookie-based session
IDs. The mutable session dictionary is read with `getsession(req)` (`req.context[:session]`).

# Required keyword

- `store::AbstractSessionStore{String, Dict{String,Any}}` — where sessions are persisted.
  [`MemoryStore()`](@ref) for in-process sessions, `pormg_nitro_session()` for a database.

  **There is no default, on purpose (#171).** A shared process-global store would be silently
  shared by every `App` in the process — several can coexist — and by every test that forgot to
  pass one. Omitting `store` is an `UndefKeywordError` at construction, never a silent share.
  Two apps that each want their own session table each call `MemoryStore()`.

Expired sessions are reclaimed by a background janitor that starts on `serve()` and stops on
`terminate()` — see `prune_interval` below and [`SessionPruner`](@ref). Nothing prunes on the
request path.

# Session fixation defense (`rotate_on_auth`, `auth_key`, `validator`)

When `rotate_on_auth=true` (the default), an existing session is assigned a **new** session
ID whenever its authenticated identity changes during a request — i.e. on login, logout, or
a user switch — so a pre-login session ID can never be replayed against the post-login
session. The identity is captured before the handler runs and compared after.

How that identity is resolved, in order:

- `auth_key::String = "user_id"` — the session key whose value *is* the identity. This is
  the common case: your login handler sets `getsession(req)["user_id"] = …` and logout clears
  it; the change triggers regeneration.
- `validator::Union{Function, Nothing} = nothing` — an optional **fallback identity
  resolver**, consulted *only* when `auth_key` is absent from the session (and a session ID
  exists). It is arity-dispatched — called as `validator(session_id, session_data)` if that
  method exists, else `validator(session_id)` — and its return value is the identity marker
  used for change detection.

The `validator` participates in fixation detection **only**; it never populates
`getuser(req)`. Authenticating a request (attaching a principal) is the job of `BearerAuth` /
`CookieAuthMiddleware`, and guards read `getuser(req)` / the raw session there. This separation
is deliberate: `SessionMiddleware` owns session *state and rotation*, not the auth identity
contract.

# Other keyword arguments

- `cookie_name::String = "nitro_session"`, `max_age::Int`.
- `prune_interval::Period = Minute(10)` — how often the background janitor removes expired
  sessions from `store`. Must be a positive fixed-length `Period`; calendar periods (`Month`,
  `Quarter`, `Year`) are rejected, since they cannot be slept on. This replaced a `prune_probability` that ran the prune inline on a
  fraction of requests; see the comment above `_prune_janitor` for why that had to go.
- Cookie attributes (`secure`, `httponly`, `samesite`, `path`, `domain`, `secret_key`) or a
  fully-formed `config::CookieConfig`.

# Returns
A `LifecycleMiddleware`. `serve()` and `urlpatterns()` accept it directly; if you are composing
the chain by hand, the request function is its `.middleware` field.
"""
function SessionMiddleware(;
    cookie_name::String = "nitro_session",
    secret_key::Nullable{String} = nothing,
    max_age::Int = 86400,
    store::AbstractSessionStore{String, Dict{String,Any}},
    prune_interval::Period = Minute(10),
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

    on_startup, on_shutdown = _prune_janitor(store, prune_interval, "SessionMiddleware",
                                             "prune_interval")

    middleware = function(handle::Function)
        return function(req::HTTP.Request)
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

    return LifecycleMiddleware(; middleware, on_startup, on_shutdown)
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
        if is_expired(payload)
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
