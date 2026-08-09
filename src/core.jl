module Core

using Base: @kwdef
# HTTP.jl v2 newly exports top-level names (`Cookie`, `Form`, `Middleware`, ...) that
# collide with Nitro's. Import qualified-only and pull in just the bare names we rely on.
import HTTP
using HTTP: Router
using Sockets
using JSON
using Base
using Dates
using Reexport
using DataStructures: CircularDeque
import Base.Threads: lock, nthreads
import ..has_revise_hooks, ..revise_hooks

include("errors.jl");       @reexport using .Errors
include("util.jl");         @reexport using .Util
include("types.jl");        @reexport using .Types
using .Types: snapshot
include("crypto.jl");       @reexport using .Crypto
include("cookies.jl");      @reexport using .Cookies
include("constants.jl");    @reexport using .Constants
include("context.jl");      @reexport using .AppContext

function getparams end
function getquery end
function getsession end
function setsession! end
function getip end
function setip! end
function getpeerip end
function getcontext end

include("handlers.jl");     @reexport using .Handlers
include("routerhof.jl");    @reexport using .RouterHOF
using .RouterHOF: normalize_middleware, register_lifecycle!
include("reflection.jl");   @reexport using .Reflection
include("extractors.jl");   @reexport using .Extractors
include("response.jl");     @reexport using .Res
include("middleware.jl");   @reexport using .Middleware
include("routing.jl");      @reexport using .Routing

export serve, terminate,
    internalrequest, staticfiles, dynamicfiles, spafiles,
    getparams, getquery, getsession, setsession!, getip, setip!, getpeerip, getcontext, payload

const REQUEST_JSON_CACHE_KEY = :__nitro_request_json
const REQUEST_FORM_CACHE_KEY = :__nitro_request_form
const REQUEST_INPUT_CACHE_KEY = :__nitro_request_input
const REQUEST_FILES_CACHE_KEY = :__nitro_request_files
const REQUEST_POST_CACHE_KEY = :__nitro_request_post
const REQUEST_CONTEXT_KEY = :__nitro_app_context

# ── HTTP.jl v2 compatibility shim ───────────────────────────────────────────────
# The HTTP private/undocumented *functions* Nitro's request layer reaches into are
# wrapped here, so an HTTP upgrade that renames one is a single-line fix instead of
# a grep hunt. Guarded by the "HTTP internals contract" canary in
# test/http_internals_contract_tests.jl.
#
# Deliberately NOT centralized here: the `HTTP.EmptyBody`/`HTTP.BytesBody` body
# *types* (dispatched on inline in bodyparsers.jl / core.jl) and the `_peer_ip`
# stream-layout reach (below) — both carry their own canary coverage. Each wrapper
# uses `getfield` (not property access) so it never re-enters the overridden
# `getproperty` defined in `_install_request_getproperty!`.
_http_metadata(req::HTTP.Request)          = HTTP._request_context_metadata!(getfield(req, :context))
_http_version(req::HTTP.Request)           = VersionNumber(Int(getfield(req, :proto_major)), Int(getfield(req, :proto_minor)))
_http_stream_request(stream::HTTP.Stream)  = HTTP._buffered_stream_request(stream)

function request_cache!(builder::Function, req::HTTP.Request, key::Symbol)
    if haskey(req.context, key)
        return req.context[key]
    end

    value = builder()
    req.context[key] = value
    return value
end

function merge_request_input!(merged::Dict{String,Any}, source)
    if source isa AbstractDict
        for (key, value) in pairs(source)
            merged[string(key)] = value
        end
    end
    return merged
end

const REQUEST_MULTIPART_CACHE_KEY = :__nitro_request_multipart

"""
Parse the `multipart/form-data` body once per request and cache the raw result, so that
`req.files` and `req.post` can both read it without re-parsing (and re-reading) the body.
"""
function request_multipart(req::HTTP.Request)
    return request_cache!(req, REQUEST_MULTIPART_CACHE_KEY) do
        Types.multipartbody(req)
    end
end

function request_input(req::HTTP.Request) :: Dict{String,Any}
    return request_cache!(req, REQUEST_INPUT_CACHE_KEY) do
        merged = Dict{String,Any}()
        merge_request_input!(merged, req.query)
        merge_request_input!(merged, req.json)
        merge_request_input!(merged, req.form)
        merge_request_input!(merged, req.post)
        merge_request_input!(merged, req.params)
        merged
    end
end

"""
Extend HTTP.Request to provide DX-friendly shorthand access to common properties:
- `req.params`: Returns path parameters
- `req.query`: Returns query parameters 
- `req.session`: Returns the session dictionary from context (if present)
- `req.user`: Returns the authenticated user from context (if present)
- `req.ip`: Returns the caller's IP address from context
- `req.json`: Returns the parsed JSON body (cached per request)
- `req.form`: Returns parsed form data (cached per request)
- `req.files`: Returns the file parts of a multipart body, `Dict{String, Union{FormFile, Vector{FormFile}}}` (cached per request) — Django `request.FILES`
- `req.post`: Returns the text fields of a multipart body, `Dict{String, Union{String, Vector{String}}}` (cached per request) — Django `request.POST`
- `req.input`: Returns merged request input (params > post > form > json > query, where `post` is the multipart text fields)
"""
# HTTP.jl v2 defines its own `Base.getproperty(::Request, ::Symbol)` (special-casing
# `:context` and `:version`). Nitro extends this with DX shorthands, but a same-signature
# definition would *overwrite* HTTP's method — which Julia forbids during precompilation.
# We therefore install Nitro's version (a strict superset that still honors HTTP's
# `:context`/`:version` semantics) at load time from `__init__`.
function _install_request_getproperty!()
    @eval Core function Base.getproperty(req::HTTP.Request, sym::Symbol)
        if sym === :params
            return HTTP.getparams(req)
        elseif sym === :query
            return Types.queryvars(req)
        elseif sym === :json
            return request_cache!(req, REQUEST_JSON_CACHE_KEY) do
                Types.jsonbody(req)
            end
        elseif sym === :form
            return request_cache!(req, REQUEST_FORM_CACHE_KEY) do
                Types.formbody(req)
            end
        elseif sym === :input || sym === :data
            return request_input(req)
        elseif sym === :files
            # Django request.FILES — only the file parts of a multipart body, cached.
            return request_cache!(req, REQUEST_FILES_CACHE_KEY) do
                parsed = request_multipart(req)
                Dict{String, Union{FormFile, Vector{FormFile}}}(
                    k => v for (k, v) in parsed
                    if v isa FormFile || v isa Vector{FormFile}
                )
            end
        elseif sym === :post
            # Django request.POST for multipart — the text fields of a multipart body, cached.
            return request_cache!(req, REQUEST_POST_CACHE_KEY) do
                parsed = request_multipart(req)
                Dict{String, Union{String, Vector{String}}}(
                    k => v for (k, v) in parsed
                    if v isa String || v isa Vector{String}
                )
            end
        elseif sym === :session
            return Base.get(req.context, :session, nothing)
        elseif sym === :user
            return Base.get(req.context, :user, nothing)
        elseif sym === :ip
            return Base.get(req.context, :ip, nothing)
        elseif sym === :context
            # Preserve HTTP.jl v2 semantics: `.context` returns the metadata view.
            return _http_metadata(req)
        elseif sym === :version
            return _http_version(req)
        else
            return getfield(req, sym)
        end
    end
end

function __init__()
    # Only install at real load time. During precompilation (of Nitro itself or any
    # dependent package/extension), `jl_generating_output` is 1 — mutating the already
    # serialized `Core` module via `@eval` then would break incremental compilation.
    # The method is (re)installed every time Nitro is loaded into a live session.
    if ccall(:jl_generating_output, Cint, ()) == 0
        _install_request_getproperty!()
    end
end

"""
    getparams(req::HTTP.Request) -> Dict{String, String}

Returns the path parameters for the request.
"""
getparams(req::HTTP.Request) = HTTP.getparams(req)

"""
    getquery(req::HTTP.Request) -> Dict{String, String}

Returns the query parameters for the request.
"""
getquery(req::HTTP.Request) = Types.queryvars(req)

# HTTP.jl v1 shipped `queryparams(::Request)` / `queryparams(::Response)`; v2 only provides
# the URIs `queryparams(::AbstractString)` / `(::URI)`. Re-add the message overloads (which
# Nitro re-exports) so existing call sites keep working. A `Response` resolves its query
# from the linked request, returning `nothing` when there is none.
HTTP.queryparams(req::HTTP.Request) = Types.queryvars(req)
function HTTP.queryparams(res::HTTP.Response)
    linked = res.request
    return linked === nothing ? nothing : Types.queryvars(linked)
end

"""
    getsession(req::HTTP.Request) -> Union{Dict{String,Any}, Nothing}

Returns the session dictionary from the request context, if present.
"""
getsession(req::HTTP.Request) = Base.get(req.context, :session, nothing)

"""
    setsession!(req::HTTP.Request, val::Dict{String,Any})

Assigns the session dictionary to the request context.
"""
setsession!(req::HTTP.Request, val) = (req.context[:session] = val)

"""
    getip(req::HTTP.Request) -> Union{Sockets.IPAddr, Nothing}

Returns the caller's IP address from the request context, if present.
"""
getip(req::HTTP.Request) = Base.get(req.context, :ip, nothing)

"""
    setip!(req::HTTP.Request, val::Sockets.IPAddr)

Assigns the caller's IP address to the request context.
"""
setip!(req::HTTP.Request, val) = (req.context[:ip] = val)

"""
    getpeerip(req::HTTP.Request) -> Union{Sockets.IPAddr, Nothing}

Returns the address of the socket that actually connected, as opposed to the client address
`getip` reports.

The two differ only when `ExtractIP` resolved the client from a forwarding header: it records the
socket peer here before overwriting `getip(req)`. Without `ExtractIP` in the pipeline the two are
the same value, because `serve` seeds the request context from the real TCP connection.

Use it to tell a proxied request from a direct one when auditing — that distinction is what makes
an access log usable after an incident, since a forged forwarding header changes `getip` but can
never change the socket peer. Note that a custom middleware calling `setip!` directly, rather
than through `ExtractIP`, overwrites `getip` without recording a peer here.
"""
getpeerip(req::HTTP.Request) = Base.get(req.context, :peer_ip, getip(req))

"""
    getcontext(req::HTTP.Request) -> Union{Any, Nothing}

Returns the application context payload for the request — the object passed to
`serve(context = ...)` — or `nothing` when no context was configured.

This is the request-side counterpart to declaring a `Context{T}` handler parameter:
it lets handlers and the business logic they call reach the typed application config
from `req` alone, without threading a `Context` argument through every signature.

```julia
serve(context = AppConfig(...))

function handler(req)
    cfg = getcontext(req)        # ::AppConfig (untyped at the call site)
    cfg.host
end
```

Use [`getcontext(req, T)`](@ref) when you want the value statically typed as `T`.
"""
function getcontext(req::HTTP.Request)
    ctx = Base.get(req.context, REQUEST_CONTEXT_KEY, missing)
    return ctx isa Context ? ctx.payload : nothing
end

"""
    getcontext(req::HTTP.Request, ::Type{T}) -> T

Returns the application context payload typed as `T`, so field access is statically
typed (`getcontext(req, AppConfig).host`). Throws an `ArgumentError` when no context
was configured, and a `TypeError` when the payload is not a `T`.
"""
function getcontext(req::HTTP.Request, ::Type{T}) where {T}
    ctx = Base.get(req.context, REQUEST_CONTEXT_KEY, missing)
    ctx isa Context || throw(ArgumentError(
        "No application context on request; pass `context = ...` to `serve()`."))
    return ctx.payload::T
end

"""
    payload(req::HTTP.Request) -> Dict{String, Any}

Returns a merged dictionary containing the JSON body, form data, multipart text
fields, and query parameters from the incoming request.
"""
function payload(req::HTTP.Request)::Dict{String, Any}
    return req.input
end

function serverwelcome(external_url::String, prefix::Nullable{String}, parallel::Bool)
    server_url = Util.join_url_path(external_url, prefix)
    curr_time = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
    current_env = get(ENV, "NITRO_ENV", nothing)
    
    printstyled(" Nitro 1.10.0 ", color=:cyan, reverse=true, bold=true)
    if parallel
        printstyled(" (parallel mode: $(Threads.nthreads()) threads)", color=:light_black)
    end
    println("\n$curr_time")
    if !isnothing(current_env)
        println("Environment: $current_env")
    end
    
    if !isnothing(prefix)
        println("Global prefix: $prefix")
    end
    
    print("Starting server at ")
    printstyled("$server_url\n", color=:cyan, bold=true)
    println("Quit the server with CONTROL-C.")
end

function ReviseHandler()
    return function(handle)
        return function(req::HTTP.Request)
            hooks = revise_hooks()
            if hooks !== nothing && Base.invokelatest(hooks.has_pending_revisions)
                @info "🔴 Starting pre-request revision"
                Base.invokelatest(hooks.revise)
                @info "🟢 Pre-request revision finished"
            end
            invokelatest(handle, req)
        end
    end
end

# Nominal wrapper for the composed stream handler. Its only job is to give the handler
# stored in `HTTP.Server.handler` a *Nitro-owned* type, so we can attach a secret-safe
# `show` (below) without pirating `show` for every `HTTP.Server` in the session.
struct NitroStreamHandler{F} <: Function
    f::F
end
(h::NitroStreamHandler)(stream) = h.f(stream)

# SECURITY: `HTTP.Server` has no custom `show`, so Julia's default walks its fields —
# including `handler`, whose closures capture the cookie/JWT `secret_key`, DB creds, and
# API keys. Displaying a server (REPL auto-display, `@show`, a pasted session) would
# print all of them. Constrained to `NitroStreamHandler`, this override is *not* type
# piracy and never touches a non-Nitro `HTTP.Server`; it prints only the address.
# (`dump` bypasses `show` entirely and still walks raw fields — explicit introspection
# can't be, and isn't, prevented here.)
Base.show(io::IO, s::Server{<:NitroStreamHandler}) =
    print(io, "HTTP.Server(", something(s.bound_address, s.address), ")")
Base.show(io::IO, ::MIME"text/plain", s::Server{<:NitroStreamHandler}) = show(io, s)

"""
    serve(; middleware=[], host="127.0.0.1", port=8080, kwargs...) -> Union{Server, Nothing}

Start the Nitro HTTP server with the registered routes. Runs until `terminate()`
(or `Ctrl-C`); pass `async=true` to return immediately and serve in the background.

Returns the running `Server` in `async=true` mode; in blocking mode it returns
`nothing`, since the server has already shut down by the time control returns and a
shut-down handle is not useful. The returned handle is safe to display: Nitro gives
its servers a custom `show` that prints only the address (see `NitroStreamHandler`),
so secrets captured in the handler closures — cookie/JWT `secret_key`, API keys, DB
credentials — are never printed by an accidental REPL auto-display, `@show`, string
interpolation, or logging. (`dump` bypasses `show` and still walks raw fields; that
is explicit introspection, not accidental disclosure.)

# Keyword arguments
- `middleware=[]`: global middleware applied to every request, outermost first.
- `host="127.0.0.1"`, `port=8080`: listen address. Keep `host` on loopback when a
  reverse proxy terminates TLS in front of Nitro.
- `async=false`: when `true`, return the running `Server` instead of blocking.
- `parallel=true`: handle requests on the thread pool via `Threads.@spawn`.
- `serialize=true`: auto-format handler return values into responses (see `Res`).
- `catch_errors=true`: convert a thrown handler error into a generic
  `500 Internal Server Error`. **Stack traces are never sent to the client** —
  the body is always `{"message": "500: Internal Server Error"}`.
- `show_errors=true`: gate **server-side** error logging only (not the client
  response). Leave it `true` in production so failures are recorded in your logs;
  `false` merely silences those logs and does *not* harden the already-generic response.
- `access_log=true`: emit one log line per request. By default only the request
  **path** is logged — query strings are redacted so tokens, API keys, and OAuth
  `code`/`state` carried in URLs never reach the logs.
- `access_log_query=false`: set `true` to log the full target including the query
  string. Only enable when you are certain no secrets travel in query strings.
- `prefix=nothing`: strip a global URL prefix (e.g. `"/api"`) before routing.
- `revise=:none`: `:lazy`/`:eager` enable Revise-based hot reload (dev only).
- `secret_key`, `httponly`, `secure`, `samesite`: override cookie defaults for this run.
- `shutdown_timeout=10.0`: seconds `terminate` waits for in-flight requests to drain
  before force-closing what remains. `0` skips the graceful phase entirely.
- `reuseaddr`: forwarded to `HTTP.listen!`. Defaults to `true` on Linux/macOS, where it
  allows rebinding a port still in `TIME_WAIT`, and to **`false` on Windows**, where
  `SO_REUSEADDR` instead lets a second process bind a port another is actively listening
  on — turning a port conflict into two servers silently splitting the traffic.

Calling `serve` on a context that is **already serving** throws an `ArgumentError`: the
second call would overwrite the running server's handle and strand its port. Call
`terminate` first, or give the second listener its own context via `instance`.

IP-based controls (rate limiting, audit logging) key on the socket peer address,
resolved for both plain-HTTP and direct-TLS listeners. Behind a reverse proxy,
configure `ExtractIP`/`RateLimiter` with both `trusted_proxies` and the
`forwarded_header` your proxy writes so per-client limits work.

See also `terminate`, `RateLimiter`, and `ExtractIP`.
"""
function serve(ctx::ServerContext;
    middleware=[],
    handler=stream_handler,
    host="127.0.0.1",
    port=8080,
    async=false,
    parallel=true,
    serialize=true,
    catch_errors=true,
    show_errors=true,
    show_banner=true,
    access_log=true,
    access_log_query=false,
    external_url=nothing,
    prefix=nothing,
    context=missing,
    revise=:none,
    secret_key=nothing,
    httponly=nothing,
    secure=nothing,
    samesite=nothing,
    shutdown_timeout=SHUTDOWN_TIMEOUT_SECONDS,
    kwargs...)::Union{Server, Nothing}

    # FIRST, before any validation or context mutation, so a rejected call leaves the context
    # byte-for-byte untouched. `startserver` assigns `ctx.service.server[]` unconditionally, so
    # without this guard a second `serve()` would overwrite the handle of a *live* server —
    # leaving it unreachable and its port bound for the life of the process, with nothing left
    # to close it. That is a programming error, not something to paper over by silently killing
    # the first server's in-flight requests.
    if isopen(ctx.service)
        throw(ArgumentError(
            "This ServerContext is already serving on " *
            "$(something(ctx.service.external_url[], "an open listener")). A second `serve()` " *
            "would overwrite the running server's handle, leaving it unreachable and its port " *
            "bound until the process exits. Call `terminate()` first, or give the second " *
            "listener its own context (`instance()`, or `Nitro.Core.serve(ServerContext(); …)`)."))
    end

    if revise ∉ (:none, :lazy, :eager)
        throw(ArgumentError("Invalid `revise` value $(repr(revise)). Expected one of :none, :lazy, or :eager."))
    end

    # Validate HERE rather than only at shutdown. `_shutdown_server` also rejects a bad value,
    # but by then it is far too late: the stored timeout is read on every `terminate()`, so a
    # typo'd `shutdown_timeout` would make `terminate()` throw *before* it clears the handle —
    # leaving a running server that can never be stopped through the normal API. Rejecting the
    # value at the call site that contains the typo keeps the failure recoverable.
    # (`NaN >= 0` is false, so NaN is rejected here too.)
    shutdown_timeout >= 0 ||
        throw(ArgumentError("`shutdown_timeout` must be >= 0 seconds, got $shutdown_timeout"))

    if !ismissing(context)
        ctx.app_context[] = Context(context)
    end

    current = ctx.service.cookies[]
    ctx.service.cookies[] = CookieConfig(
        secret_key=isnothing(secret_key) ? current.secret_key : secret_key,
        httponly=isnothing(httponly) ? current.httponly : httponly,
        secure=isnothing(secure) ? current.secure : secure,
        samesite=isnothing(samesite) ? current.samesite : samesite,
        path=current.path,
        domain=current.domain,
        maxage=current.maxage,
        expires=current.expires,
        max_cookie_size=current.max_cookie_size,
    )

    ctx.service.external_url[] = external_url isa String ? external_url : "http://$host:$port"
    ctx.service.prefix[] = prefix isa String ? prefix : nothing
    # Stored rather than passed through, because the *blocking* `serve()` calls `terminate()`
    # from its own `finally` (the Ctrl-C path) with no way to hand it a keyword.
    ctx.service.shutdown_timeout[] = Float64(shutdown_timeout)

    if revise == :lazy || revise == :eager
        if parallel && Threads.nthreads() > 1
            @warn "You are attempting to use Revise with multiple threads. Please note that Revise 3.5.18 and earlier are not threadsafe."
        end
        if !has_revise_hooks()
            error("Revise support is unavailable. Load Revise.jl in your development session before using the `revise` option")
        end
        if ctx.mod === nothing
            @warn "You are trying to use the `revise` option, but no module was provided to track. Code in the `Main` module may not be tracked and revised."
        end
        middleware = convert(Vector{Any}, middleware)
        insert!(middleware, 1, ReviseHandler())
    end

    # Lifecycle registration lives HERE — once per server — not in `setupmiddleware`, which
    # `internalrequest` also calls, per request (#68). `startup.` runs only in `startserver`,
    # so a middleware registered from the request path got an `on_shutdown` at `terminate`
    # with no paired `on_startup` — deterministic, needing no race at all — and additionally
    # wrote to an unsynchronized `Set` that `startup.`/`shutdown.` broadcast over, which a
    # concurrent `internalrequest` could overlap.
    #
    # Placed after the `revise` block above so it operates on the final `middleware` vector.
    # (Inert today — `ReviseHandler()` is a plain closure, not a `LifecycleMiddleware`, so
    # the resulting `Set` is the same either way — but the ordering is the correct default.)
    register_lifecycle!(ctx, middleware)

    configured_middelware = setupmiddleware(ctx; middleware, serialize, catch_errors, show_errors, access_log, access_log_query)
    handle_stream = handler(configured_middelware)

    if parallel
        if Threads.nthreads() <= 1 && !is_test()
            @warn "serveparallel() only has 1 thread available to use, try launching julia like this: \"julia -t auto\" to leverage multiple threads"
        end

        if haskey(kwargs, :queuesize) && !is_test()
            @warn "Deprecated: The `queuesize` parameter is no longer used / supported in serveparallel()"
        end

        handle_stream = parallel_stream_handler(handle_stream)
    end

    # Wrap last, so the handler HTTP stores gets our secret-safe `show` (see NitroStreamHandler).
    handle_stream = NitroStreamHandler(handle_stream)

    if revise == :eager
        ctx.service.eager_revise[] = start_revise_service()
    end

    try
        return startserver(ctx; host, port, show_banner, parallel, async, kwargs, start=(kwargs) ->
            HTTP.listen!(handle_stream, host, port; kwargs...))
    finally
        if ctx.service.eager_revise[] !== nothing && async == false
            close(ctx.service.eager_revise[])
        end
    end
end

function start_revise_service()
    revise_task_done = Ref(false)
    revise_task = @async begin
        hooks = revise_hooks()
        if hooks === nothing
            return nothing
        end
        while true
            if revise_task_done[]
                break
            end
            Base.invokelatest(hooks.wait_for_revision_event)
            if revise_task_done[]
                break
            end
            @info "🗘  Starting eager revision"
            Base.invokelatest(hooks.revise)
            @info "👍 Eager revision finished"
        end
    end
    EagerReviseService(revise_task, revise_task_done)
end

"""
    terminate(context::ServerContext; timeout = nothing)
    terminate(; timeout = nothing)

Stop the running server: run every `LifecycleMiddleware` shutdown hook, drop the composed
middleware cache, and close the listener. A no-op when nothing is serving.

Shutdown is a **bounded graceful drain**, modeled on Go's `http.Server.Shutdown(ctx)`. The
listening socket is released immediately — the port is free as soon as `terminate` is entered
— then Nitro waits up to `timeout` seconds for in-flight requests to finish and force-closes
whatever remains.

`timeout` defaults to the server's own `serve(shutdown_timeout = …)`, itself defaulting to
`Nitro.Core.SHUTDOWN_TIMEOUT_SECONDS` (10 seconds). `timeout = 0` skips the graceful phase.

**Long-lived connections are always cut at the timeout.** A WebSocket, SSE, or STREAM handler
holds its connection for its whole lifetime, so the drain can never wait it out. If such a
handler has to finish cleanly, give it a shutdown signal of its own — an `Event` or `Channel`
notified from a `LifecycleMiddleware`'s `on_shutdown`, which runs *before* the drain begins.

!!! warning
    Do not call `terminate()` from inside a request handler. The handler's own connection is
    what the drain is waiting on, so the graceful phase is guaranteed to reach its timeout.

See also `serve`.
"""
function terminate(context::ServerContext; timeout::Nullable{Real} = nothing)
    if isopen(context.service)
        shutdown.(context.service.lifecycle_middleware)
        # NOTE(#82): this also drops *route-level* lifecycle middleware, which is registered at
        # `urlpatterns()` time rather than at `serve()` time — so `serve(); terminate(); serve()`
        # never re-runs those startup hooks. Fixing it properly means splitting the set into
        # route-owned and serve-owned halves; tracked separately.
        empty!(context.service.lifecycle_middleware)
        # Do NOT "symmetrize" this by also emptying `custommiddleware`: that table is route
        # *registration* state, not cache state. test/original_tests.jl re-serves after a
        # `terminate()` and expects the registered routes and their middleware to survive.
        # `empty!(::CopyOnWriteDict)`, not `empty!(::Dict)`: publishes a fresh table under
        # the cache's lock. Requests are still in `compose` here — the server is not closed
        # until the `close` a couple of lines below — so an in-flight reader must be able to
        # finish against a table nobody mutates.
        empty!(context.service.middleware_cache)
        context.service.external_url[] = nothing
        close(context.service; timeout = something(timeout, context.service.shutdown_timeout[]))
    end
    return nothing
end

# True once a handler has begun writing the response on the raw stream (e.g. a STREAM
# route that called `startwrite`, or a WebSocket upgrade). Used to decide whether the
# framework still needs to emit a serialized `Response`.
_response_started(stream::HTTP.Stream)::Bool = (@atomic :acquire stream.response_started)

# Resolve the underlying Reseau `TCP.FD` (which carries `raddr`) from the server connection.
# The connection is transport-dependent: a plaintext `Reseau.TCP.Conn` exposes `:fd`
# directly, while a `Reseau.TLS.Conn` wraps the TCP connection under `:tcp` and has no `:fd`
# of its own. The earlier `conn.fd` shortcut therefore worked for HTTP but threw for *every*
# HTTPS connection, silently sending every TLS client's IP to loopback. We branch on field
# presence rather than importing Reseau (a transitive dep that must not leak into `src/`); an
# unrecognized layout raises, which `_peer_ip` turns into the structural-break alarm below.
function _conn_fd(conn)
    if hasfield(typeof(conn), :fd)        # Reseau.TCP.Conn
        return getfield(conn, :fd)
    elseif hasfield(typeof(conn), :tcp)   # Reseau.TLS.Conn wraps a TCP.Conn under :tcp
        return getfield(getfield(conn, :tcp), :fd)
    end
    error("Nitro: unrecognized Reseau connection type $(typeof(conn)) — no `:fd` or `:tcp` field")
end

# HTTP.jl v1's `Sockets.getpeername(::HTTP.Stream)` no longer works in v2 — server streams
# are not raw sockets. The peer address is reachable through the server connection that v2
# tracks on the stream (`stream.tracked.conn`, a Reseau `TCP.Conn`/`TLS.Conn`, whose backing
# `TCP.FD` carries `raddr`; see `_conn_fd`). Navigate that path defensively and fall back to
# loopback when the address is unavailable so a request is never failed merely because the
# client IP couldn't be determined — but make that fallback *loud*. Silently treating every
# client as loopback degrades IP-based controls (rate limiting keys collapse to one bucket,
# audit logs lose the source IP) and, combined with `ExtractIP(trusted_proxies=[loopback])`,
# would cause `X-Forwarded-For` to be trusted from every client. We distinguish two cases:
#   * `raddr === nothing` — a legitimate runtime condition for some connection types; warn.
#   * a thrown `getfield` — the HTTP/Reseau internal layout this reaches into has likely
#     changed; this is a structural break, so log it as an error with the exception.
# Both use `maxlog=1` so a persistent failure can't flood the log one line per request.
function _peer_ip(stream::HTTP.Stream)::IPAddr
    try
        conn = getfield(getfield(stream, :tracked), :conn)
        raddr = getfield(_conn_fd(conn), :raddr)
        if raddr === nothing
            @warn "Nitro: peer address unavailable on this connection; falling back to " *
                  "loopback. IP-based rate limiting, audit logging and trusted-proxy " *
                  "checks are degraded for affected requests." maxlog=1
            return Sockets.localhost
        end
        ip = getfield(raddr, :ip)
        if length(ip) == 4
            return IPv4(ip[1], ip[2], ip[3], ip[4])
        else
            acc = UInt128(0)
            for b in ip
                acc = (acc << 8) | UInt128(b)
            end
            return IPv6(acc)
        end
    catch err
        @error "Nitro: could not read the peer IP from HTTP stream internals — the " *
               "HTTP.jl/Reseau stream layout `_peer_ip` reaches into may have changed. " *
               "Falling back to loopback, which SILENTLY DEGRADES IP-based rate limiting " *
               "and audit logging, and (with `trusted_proxies` set) can cause " *
               "X-Forwarded-For to be trusted from every client. Pin HTTP.jl/Reseau and " *
               "verify `_peer_ip`." exception=(err, catch_backtrace()) maxlog=1
        return Sockets.localhost
    end
end

# Custom stream adapter (replaces `HTTP.streamhandler`, which unconditionally writes the
# handler's returned `Response`). Nitro's STREAM/WebSocket handlers take over the raw
# stream and write the response themselves, so we only emit the serialized `Response` when
# the handler hasn't already started one. The HTTP.jl v2 server loop closes the read/write
# sides and turns any thrown exception into a 500 after this returns.
# Write a response body to the stream WITHOUT consuming it. HTTP.jl v2's
# `_write_response_body_to_stream!` advances the `BytesBody` read cursor, which corrupts
# any Response object that is reused across requests — a common pattern in handler code
# (e.g. module-level `const` error responses). Reading `BytesBody.data` directly is
# cursor-independent, so a shared response can be written any number of times.
#
# The consume-and-close-on-write of a String→`BytesBody` body is *intentional* upstream
# behavior (HTTP.jl #1272), not a bug to wait on; `Vector{UInt8}` bodies are written
# non-destructively by HTTP itself (HTTP.jl #1254). Nitro depends on neither — it writes
# the bytes here. The `BytesBody.data` field this reaches into is an HTTP internal,
# canaried in test/http_internals_contract_tests.jl; the reuse-safety it buys is covered
# behaviorally in test/middleware/authmiddleware_tests.jl. Do not route response bodies
# back through HTTP's consuming writer.
_write_response_body!(stream::HTTP.Stream, ::HTTP.EmptyBody) = nothing
_write_response_body!(stream::HTTP.Stream, ::Nothing) = nothing
function _write_response_body!(stream::HTTP.Stream, body::HTTP.BytesBody)
    isempty(body.data) || write(stream, body.data)
    return nothing
end
function _write_response_body!(stream::HTTP.Stream, body::Union{AbstractVector{UInt8}, AbstractString})
    isempty(body) || write(stream, body)
    return nothing
end

function stream_handler(middleware::Function)
    return function(stream::HTTP.Stream)
        ip = _peer_ip(stream)
        req = _http_stream_request(stream)
        req.context[:ip] = ip
        req.context[:stream] = stream

        result = middleware(req)

        if !_response_started(stream)
            resp = result isa HTTP.Response ? result : HTTP.Response(200)
            resp.request = req
            stream.response = resp
            _write_response_body!(stream, resp.body)
        end
        return nothing
    end
end

function parallel_stream_handler(handle_stream::Function)
    function(stream::HTTP.Stream)
        task = Threads.@spawn begin
            handle = @async handle_stream(stream)
            wait(handle)
        end
        wait(task)
    end
end

# Outermost wrapper that seeds the per-request context with the application
# context (`serve(context = ...)`), so `getcontext(req)` works everywhere in the
# pipeline — global/custom middleware, per-route middleware, and handlers alike.
# Runs before any other middleware, so the app context is visible from the very
# first hook a request passes through.
function _app_context_seed(ctx::ServerContext)
    return function(handler::Function)
        return function(req::HTTP.Request)
            req.context[REQUEST_CONTEXT_KEY] = ctx.app_context[]
            return handler(req)
        end
    end
end

function setupmiddleware(ctx::ServerContext; middleware::Vector=[], serialize::Bool=true, catch_errors::Bool=true, show_errors=true, access_log=false, access_log_query::Bool=false)::Function
    raw_middleware = reverse(middleware)
    # `normalize_middleware`, NOT `process_middleware`: this runs once per `serve` but ONCE
    # PER CALL from `internalrequest`, so it must have no registration side effect. `serve`
    # registers explicitly, just before it calls this. (#68)
    processed_middleware = normalize_middleware(raw_middleware)

    global_prefix_middleware = !isnothing(ctx.service.prefix[]) ? [PrefixStripMiddleware(ctx.service.prefix[])] : []
    serializer = serialize ? [DefaultSerializer(catch_errors; show_errors)] : []
    # Accept `true` to enable; `nothing`/`false` (or the old logfmt value) disable it.
    access_log_middleware = access_log === true ? [AccessLogMiddleware(; log_query=access_log_query)] : []

    # `compose` is installed UNCONDITIONALLY (#71). The old gate here — install it only if
    # `custommiddleware` was already non-empty — was evaluated once, and `serve` calls this
    # once, so an app whose first per-route middleware was registered AFTER the server started
    # (Revise re-running `urlpatterns`, a runtime `include_routes`) never got `compose` at all
    # and that middleware silently never ran. The emptiness test now lives inside `compose`,
    # per request, where it also short-circuits to a prebuilt global-middleware-only chain
    # BEFORE `gethandler` — so an app with no per-route middleware does strictly less routing
    # work here than the old compose branch did (one `gethandler`, not two). Against the old
    # non-compose branch it costs one closure call, one acquire-load and an `isempty` per
    # request, and no extra allocation. (Deliberately no wall-clock figure: this comment already
    # carried one that went stale the moment `router_entry` was added below.)
    #
    # `processed_middleware` travels SIDEWAYS into `compose` rather than being spliced into the
    # list below: `compose` applies it inside `buildmiddleware` and inside that fast path,
    # which lands it outside route middleware and inside the serializer — the same effective
    # position it held in this list. Do NOT do both, or every global middleware runs twice.
    # `HTTP.Router` is a *callable struct*, not a `Function` — `HTTP.Handlers.Router <: Function`
    # is false. Three of the layers that can end up wrapping it are typed on `Function` and so
    # reject it outright: `_app_context_seed` below, and `foldlayers`/`buildmiddleware` in
    # src/routerhof.jl. (`DefaultSerializer`, `PrefixStripMiddleware` and user middleware are
    # untyped and accept it fine.) So start the fold from an adapter rather than the bare router.
    #
    # `serialize=false` is what exposes this, because the serializer is otherwise the thing that
    # wraps the router into a closure on the first fold step. On `serve` it used to survive by
    # luck — `access_log` defaults to true, and `AccessLogMiddleware` accepts the raw router —
    # while `internalrequest(...; serialize=false)`, which defaults `access_log` to false, threw
    # a `MethodError` out of `_app_context_seed` even before #71. Now that `compose` is always
    # installed it receives the accumulator directly, so without this adapter every
    # `serialize=false` app would fail at pipeline-construction time, before any request.
    #
    # `let`-bound rather than closing over `ctx`: `Service.router` is declared as the
    # unparameterized `Router` (an abstract UnionAll), so reading it per request would put a
    # dynamic dispatch at the innermost layer of every request. `Service` is immutable, so the
    # value is fixed at construction and hoisting it out is free.
    router_entry = let r = ctx.service.router
        (req::HTTP.Request) -> r(req)
    end

    return reduce(|>, [
        router_entry,
        serializer...,
        compose(ctx.service.router, processed_middleware,
                ctx.service.custommiddleware, ctx.service.middleware_cache),
        global_prefix_middleware...,
        access_log_middleware...,
        _app_context_seed(ctx),
    ])
end

function startserver(ctx::ServerContext; host, port, show_banner=false, parallel=false, async=false, kwargs, start)::Union{Server, Nothing}
    show_banner && serverwelcome(ctx.service.external_url[], ctx.service.prefix[], parallel)
    ctx.service.server[] = start(preprocesskwargs(kwargs))
    startup.(ctx.service.lifecycle_middleware)

    if !async
        try
            wait(ctx.service)
        catch error
            !isa(error, InterruptException) && @error "ERROR: " exception=(error, catch_backtrace())
        finally
            println()
        end
        # The blocking path only returns after shutdown (Ctrl-C), so a server handle here
        # would be useless. Return `nothing` to keep the REPL clean. (Secret disclosure via
        # the handle is handled separately by the `NitroStreamHandler` `show` override — that
        # covers the `async=true` handle too; this early return is just tidiness.)
        # The server stays reachable via `ctx.service.server[]` for `terminate`.
        return nothing
    end

    return ctx.service.server[]
end

function preprocesskwargs(kwargs)
    # HTTP.jl v2's `listen!` is already Stream-based, so the v1 `stream=true` flag is
    # gone. Access logging (the old `logfmt`/`access_log` default) is now handled by
    # `AccessLogMiddleware` in the middleware chain instead.
    kwargs_dict = Dict{Symbol,Any}(kwargs)
    # `listen!` rejects unknown keyword arguments. Drop v1-only server kwargs that Nitro
    # still tolerates for back-compat (a deprecation warning is emitted in `serve`).
    delete!(kwargs_dict, :queuesize)
    # `SO_REUSEADDR` means something fundamentally different on Windows. On POSIX it only lets
    # you bind over sockets in TIME_WAIT, which is load-bearing for restarting onto a port you
    # just shut down. On Windows it lets a second process bind a port another process is
    # *actively listening on*, with indeterminate delivery between the two — which is why
    # Microsoft had to add SO_EXCLUSIVEADDRUSE. HTTP.jl defaults it to `true` everywhere, so on
    # Windows an orphaned Nitro process turns "port already taken" from a loud bind failure into
    # a silent split-brain where some requests are answered by the corpse, out of *its* router.
    # `get!` writes only when the key is absent, so an explicit `serve(reuseaddr = …)` wins.
    Base.get!(kwargs_dict, :reuseaddr, !Sys.iswindows())
    return kwargs_dict
end

function internalrequest(ctx::ServerContext, req::HTTP.Request; middleware::Vector=[], serialize::Bool=true, catch_errors=true, context=missing)::HTTP.Response
    req.context[:ip] = IPv4("127.0.0.1")

    old_ctx = ctx.app_context[]
    if !ismissing(context)
        ctx.app_context[] = Context(context)
    end

    try
        return req |> setupmiddleware(ctx; middleware, serialize, catch_errors)
    finally
        if !ismissing(context)
            ctx.app_context[] = old_ctx
        end
    end
end

"""
    AccessLogMiddleware(; log_query::Bool=false)

Logs one line per request once the response status is known, mirroring the old
HTTP.jl v1 `access_log` default (`\$time_iso8601 - \$remote_addr:\$remote_port - "\$request" \$status`).
HTTP.jl v2 removed the `logfmt`/`access_log` server kwargs, so request logging now
lives in the middleware chain.

Security: by default only the request **path** is logged, not the query string.
Query strings routinely carry secrets (password-reset tokens, API keys, OAuth
`code`/`state`, signed-URL signatures), and access logs are frequently shipped to
third-party aggregators. Pass `log_query=true` to log the full target including the
query when you are sure no sensitive data travels in URLs.
"""
function AccessLogMiddleware(; log_query::Bool=false)
    return function(handle)
        return function(req::HTTP.Request)
            response = handle(req)
            ip = Base.get(req.context, :ip, nothing)
            target = log_query ? req.target : HTTP.URI(req.target).path
            @info "$(Dates.format(now(), "yyyy-mm-ddTHH:MM:SS")) - $ip - \"$(req.method) $target\" $(response.status)"
            return response
        end
    end
end

function PrefixStripMiddleware(prefix::String)
    plen = length(prefix)
    NOT_FOUND = HTTP.Response(404, "Not Found")
    return function(handler)
        return function(req::HTTP.Request)
            if startswith(req.target, prefix)
                newtarget = req.target[plen+1:end]
                req.target = isempty(newtarget) ? "/" : newtarget
                return handler(req)
            else
                return NOT_FOUND
            end
        end
    end
end

function DefaultSerializer(catch_errors::Bool; show_errors::Bool)
    return function(handle)
        return function(req::HTTP.Request)
            return handlerequest(catch_errors; show_errors) do
                format_response(handle(req))
            end
        end
    end
end

function parse_route(::String, route::String)::String
    return route
end

function parse_route(http_method::String, router::OuterRouter)::String
    inner_router::InnerRouter = router()
    return inner_router(http_method)
end

function parse_route(http_method::String, router::InnerRouter)::String
    return router(http_method)
end

function pathparam_type(route::String, param::Param, type_hints::Dict{Symbol, Type})::Type
    hinted_type = get(type_hints, param.name, nothing)

    if isnothing(hinted_type)
        return param.type
    elseif param.type == Any
        return hinted_type
    elseif param.type <: hinted_type || hinted_type <: param.type
        return Reflection.select_type(param.type, hinted_type)
    elseif hinted_type == Int && param.type <: Integer && param.type != Bool
        return param.type
    elseif hinted_type == Float64 && param.type <: AbstractFloat
        return param.type
    elseif hinted_type == String && param.type <: AbstractString
        return param.type
    else
        throw(ArgumentError(
            "Path parameter $(param.name) uses route converter type $(hinted_type), " *
            "but the handler declares $(param.type) for route: $route"
        ))
    end
end

function merge_pathparam_type_hints(route::String, info::NamedTuple, route_params::Vector{Symbol}, type_hints::Dict{Symbol, Type})
    if isempty(route_params) || isempty(type_hints)
        return info
    end

    route_param_names = Set(route_params)

    function resolve_param(param::Param)
        if !(param.name in route_param_names)
            return param
        end

        resolved_type = pathparam_type(route, param, type_hints)
        if resolved_type == param.type
            return param
        end

        default_value = if !isnothing(param.default) && !(param.default isa resolved_type)
            convert(resolved_type, param.default)
        else
            param.default
        end

        return Param(
            name=param.name,
            type=resolved_type,
            default=default_value,
            hasdefault=param.hasdefault,
        )
    end

    args = [resolve_param(param) for param in info.args]
    sig = [resolve_param(param) for param in info.sig]
    sig_map = Dict{Symbol, Param}(param.name => param for param in sig)

    return (
        name=info.name,
        args=args,
        kwargs=info.kwargs,
        sig=sig,
        sig_map=sig_map,
    )
end

function parse_func_params(route::String, func::Function; type_hints::Dict{Symbol, Type}=Dict{Symbol, Type}())
    info = splitdef(func, start=2)

    hasBraces = r"({)|(})"
    route_params = Vector{Symbol}()
    for value in HTTP.URIs.splitpath(route)
        if contains(value, hasBraces)
            variable = replace(value, hasBraces => "") |> strip
            push!(route_params, Symbol(variable))
        end
    end

    info = merge_pathparam_type_hints(route, info, route_params, type_hints)

    pathnames = Vector{Symbol}()
    querynames = Vector{Symbol}()
    headernames = Vector{Symbol}()
    cookienames = Vector{Symbol}()
    bodynames = Vector{Symbol}()

    path_params = []
    query_params = []
    header_params = []
    cookie_params = []
    body_params = []

    for param in info.args
        if param.type <: Context
            continue
        elseif param.type <: Extractor
            innner_type = extracttype(param.type)
            if param.type <: Path
                append!(pathnames, fieldnames(innner_type))
                push!(path_params, param)
            elseif param.type <: Query
                append!(querynames, fieldnames(innner_type))
                push!(query_params, param)
            elseif param.type <: Header
                append!(headernames, fieldnames(innner_type))
                push!(header_params, param)
            elseif param.type <: Session
                push!(cookienames, param.name)
                push!(cookie_params, param)
            elseif param.type <: Cookie
                push!(cookienames, param.name)
                push!(cookie_params, param)
            else
                append!(bodynames, fieldnames(innner_type))
                push!(body_params, param)
            end
        elseif param.name in route_params
            push!(pathnames, param.name)
            push!(path_params, param)
        else
            push!(querynames, param.name)
            push!(query_params, param)
        end
    end

    if !isempty(route_params)
        missing_params = [
            route_param
            for route_param in route_params
            if !any(path_param -> path_param == route_param, pathnames)
        ]
        if !isempty(missing_params)
            throw(ArgumentError("Your request handler is missing path parameters: {$(join(missing_params, ", "))} defined in this route: $route"))
        end
    end

    return (
        info=info, pathparams=path_params,
        pathnames=pathnames, queryparams=query_params,
        querynames=querynames, headers=header_params,
        headernames=headernames, cookies=cookie_params,
        cookienames=cookienames, bodyargs=body_params,
        bodynames=bodynames,
    )
end

function register(ctx::ServerContext, httpmethod::String, route::Union{String,HOFRouter}, func::Function; type_hints::Dict{Symbol, Type}=Dict{Symbol, Type}())
    route = parse_route(httpmethod, route)
    func_details = parse_func_params(route, func; type_hints)
    registerhandler(ctx, ctx.service.router, httpmethod, route, func, func_details)
end

function register_internal(ctx::ServerContext, router::Router, httpmethod::String, route::Union{String,HOFRouter}, func::Function; type_hints::Dict{Symbol, Type}=Dict{Symbol, Type}())
    route = parse_route(httpmethod, route)
    func_details = parse_func_params(route, func; type_hints)
    registerhandler(ctx, router, httpmethod, route, func, func_details)
end

function create_param_parser(ctx::ServerContext, func_details)
    info = func_details.info
    pathparams = func_details.pathnames
    queryparams = func_details.querynames

    strategies = Vector{Function}()

    function context_strategy(_::LazyRequest)
        return ctx.app_context[]
    end

    function extractor_strategy(lr::LazyRequest, param::Param{T}) where T
        return extract(param, lr)
    end

    function cookie_strategy(lr::LazyRequest, param::Param{T}) where T
        return extract(param, lr, ctx.service.cookies[].secret_key)
    end

    function session_strategy(lr::LazyRequest, param::Param{T}) where T
        return extract(param, lr, ctx.service.cookies[].secret_key, ctx.app_context[])
    end

    function pathparam_strategy(lr::LazyRequest, param::Param{T}, name::String) where T
        raw_pathparams = Types.pathparams(lr)
        # The lookup is deliberately OUTSIDE the guard. A route brace always has a matching
        # handler parameter (enforced at registration, see `parse_func_params` above) and the
        # router always populates it, so a miss here is a framework bug rather than client
        # input — it must stay a 500 with a real stack trace, not be laundered into a 400.
        return parseparam_checked(param.type, raw_pathparams[name], name, :path)
    end

    function queryparam_strategy(lr::LazyRequest, param::Param{T}, name::String) where T
        raw_queryparams = Types.queryvars(lr)
        # Only selected when `param.hasdefault` (see the dispatch loop below), so an absent
        # key means "use the declared default".
        haskey(raw_queryparams, name) || return param.default
        return parseparam_checked(param.type, raw_queryparams[name], name, :query)
    end

    function queryparam_strategy_no_default(lr::LazyRequest, param::Param{T}, name::String) where T
        raw_queryparams = Types.queryvars(lr)
        # A required query parameter that was not sent is a client error. This used to be a
        # bare `raw_queryparams[name]`, whose `KeyError` surfaced as a 500.
        haskey(raw_queryparams, name) ||
            throw(ValidationError("Missing required query parameter '$name'"))
        return parseparam_checked(param.type, raw_queryparams[name], name, :query)
    end

    for param in info.sig
        name = param.name
        str_name = String(name)
        if param.type <: Context
            push!(strategies, context_strategy)
        elseif param.type <: Session
            push!(strategies, lr -> session_strategy(lr, param))
        elseif param.type <: Cookie
            push!(strategies, lr -> cookie_strategy(lr, param))
        elseif param.type <: Extractor
            push!(strategies, lr -> extractor_strategy(lr, param))
        elseif name in pathparams
            push!(strategies, lr -> pathparam_strategy(lr, param, str_name))
        elseif name in queryparams
            query_parsing_strat = param.hasdefault ? queryparam_strategy : queryparam_strategy_no_default
            push!(strategies, lr -> query_parsing_strat(lr, param, str_name))
        end
    end

    strat_length = length(strategies)
    return function(req::HTTP.Request)
        lr = LazyRequest(request=req)
        results = Vector{Any}(undef, strat_length)
        @inbounds for i in 1:strat_length
            results[i] = strategies[i](lr)
        end
        return results
    end
end

function registerhandler(ctx::ServerContext, router::Router, httpmethod::String, route::String, func::Function, func_details::NamedTuple)
    method = first(methods(func))
    no_args = method.nargs == 1

    info = func_details.info
    has_req_kwarg = :request in Base.kwarg_decl(method)
    has_ctx_kwarg = :context in Base.kwarg_decl(method)
    has_path_params = !isempty(info.args)

    arg_type = first_arg_type(method, httpmethod)
    func_handle = select_handler(arg_type, has_ctx_kwarg, has_req_kwarg, has_path_params, ctx; no_args=no_args)
    parse_params = create_param_parser(ctx, func_details)

    if isempty(info.sig)
        handle = function(req::HTTP.Request)
            func_handle(req, func)
        end
    else
        handle = function(req::HTTP.Request)
            params = parse_params(req)
            func_handle(req, func; parameters=params)
        end
    end

    resolved_methods = if httpmethod == STREAM
        [GET, POST]
    else
        [get(METHOD_ALIASES, httpmethod, httpmethod)]
    end

    for resolved_httpmethod in resolved_methods
        HTTP.register!(router, resolved_httpmethod, route, handle)
    end
end

function staticfiles(
    ctx::ServerContext,
    router::HTTP.Router,
    folder::String,
    mountdir::String="static";
    headers::Vector=[],
    loadfile::Nullable{Function}=nothing,
)
    if first(mountdir) == '/'
        mountdir = mountdir[2:end]
    end
    function addroute(currentroute, filepath)
        resp = file(filepath; loadfile=loadfile, headers=headers)
        register_internal(ctx, router, GET, currentroute, () -> resp)
    end
    mountfolder(folder, mountdir, addroute)
end

function spafiles(
    ctx::ServerContext,
    router::HTTP.Router,
    folder::String,
    mountdir::String="static";
    headers::Vector=[],
    loadfile::Nullable{Function}=nothing,
)
    if first(mountdir) == '/'
        mountdir = mountdir[2:end]
    end

    function addroute(currentroute, filepath)
        resp = file(filepath; loadfile=loadfile, headers=headers)
        register_internal(ctx, router, GET, currentroute, () -> resp)
    end
    mountfolder(folder, mountdir, addroute)

    index_path = joinpath(folder, "index.html")
    if isfile(index_path)
        fallback_route = mountdir == "" ? "/**" : "/$mountdir/**"
        register_internal(ctx, router, GET, fallback_route, (req::HTTP.Request) -> file(index_path; loadfile=loadfile, headers=headers))
    else
        @warn "spafiles: No 'index.html' found in $folder. History mode fallback will not work."
    end
end

function dynamicfiles(
    ctx::ServerContext,
    router::Router,
    folder::String,
    mountdir::String="static";
    headers::Vector=[],
    loadfile::Nullable{Function}=nothing,
)
    if first(mountdir) == '/'
        mountdir = mountdir[2:end]
    end
    function addroute(currentroute, filepath)
        register_internal(ctx, router, GET, currentroute, () -> file(filepath; loadfile=loadfile, headers=headers))
    end
    mountfolder(folder, mountdir, addroute)
end

end # module Core
