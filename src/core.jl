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
function getcontext end

include("handlers.jl");     @reexport using .Handlers
include("routerhof.jl");    @reexport using .RouterHOF
include("reflection.jl");   @reexport using .Reflection
include("extractors.jl");   @reexport using .Extractors
include("response.jl");     @reexport using .Res
include("middleware.jl");   @reexport using .Middleware
include("routing.jl");      @reexport using .Routing

export serve, terminate,
    internalrequest, staticfiles, dynamicfiles, spafiles,
    getparams, getquery, getsession, setsession!, getip, setip!, getcontext, payload

const REQUEST_JSON_CACHE_KEY = :__nitro_request_json
const REQUEST_FORM_CACHE_KEY = :__nitro_request_form
const REQUEST_INPUT_CACHE_KEY = :__nitro_request_input
const REQUEST_FILES_CACHE_KEY = :__nitro_request_files
const REQUEST_POST_CACHE_KEY = :__nitro_request_post
const REQUEST_CONTEXT_KEY = :__nitro_app_context

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
            return HTTP._request_context_metadata!(getfield(req, :context))
        elseif sym === :version
            return VersionNumber(Int(getfield(req, :proto_major)), Int(getfield(req, :proto_minor)))
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
    external_url=nothing,
    prefix=nothing,
    context=missing,
    revise=:none,
    secret_key=nothing,
    httponly=nothing,
    secure=nothing,
    samesite=nothing,
    kwargs...)::Server

    if revise ∉ (:none, :lazy, :eager)
        throw(ArgumentError("Invalid `revise` value $(repr(revise)). Expected one of :none, :lazy, or :eager."))
    end

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

    configured_middelware = setupmiddleware(ctx; middleware, serialize, catch_errors, show_errors, access_log)
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

function terminate(context::ServerContext)
    if isopen(context.service)
        shutdown.(context.service.lifecycle_middleware)
        empty!(context.service.lifecycle_middleware)
        empty!(context.service.middleware_cache)
        context.service.external_url[] = nothing
        close(context.service)
    end
end

# True once a handler has begun writing the response on the raw stream (e.g. a STREAM
# route that called `startwrite`, or a WebSocket upgrade). Used to decide whether the
# framework still needs to emit a serialized `Response`.
_response_started(stream::HTTP.Stream)::Bool = (@atomic :acquire stream.response_started)

# HTTP.jl v1's `Sockets.getpeername(::HTTP.Stream)` no longer works in v2 — server streams
# are not raw sockets. The peer address is reachable through the server connection that v2
# tracks on the stream (`stream.tracked.conn`, a Reseau `TCP.Conn`/`TLS.Conn`, whose `fd`
# carries `raddr`). Navigate that path defensively and fall back to loopback when the
# address is unavailable (e.g. a future internal layout change) so a request is never
# failed merely because the client IP couldn't be determined.
function _peer_ip(stream::HTTP.Stream)::IPAddr
    try
        conn = getfield(getfield(stream, :tracked), :conn)
        raddr = getfield(getfield(conn, :fd), :raddr)
        raddr === nothing && return Sockets.localhost
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
    catch
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
        req = HTTP._buffered_stream_request(stream)
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

function setupmiddleware(ctx::ServerContext; middleware::Vector=[], serialize::Bool=true, catch_errors::Bool=true, show_errors=true, access_log=false)::Function
    raw_middleware = reverse(middleware)
    processed_middleware = process_middleware(ctx, raw_middleware)

    custom_middleware = if !isempty(ctx.service.custommiddleware)
        [compose(ctx.service.router, ctx.service.middleware_cache_lock, processed_middleware, ctx.service.custommiddleware, ctx.service.middleware_cache)]
    else
        processed_middleware
    end

    global_prefix_middleware = !isnothing(ctx.service.prefix[]) ? [PrefixStripMiddleware(ctx.service.prefix[])] : []
    serializer = serialize ? [DefaultSerializer(catch_errors; show_errors)] : []
    # Accept `true` to enable; `nothing`/`false` (or the old logfmt value) disable it.
    access_log_middleware = access_log === true ? [AccessLogMiddleware()] : []

    return reduce(|>, [
        ctx.service.router,
        serializer...,
        custom_middleware...,
        global_prefix_middleware...,
        access_log_middleware...,
        _app_context_seed(ctx),
    ])
end

function startserver(ctx::ServerContext; host, port, show_banner=false, parallel=false, async=false, kwargs, start)::Server
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
    AccessLogMiddleware()

Logs one line per request once the response status is known, mirroring the old
HTTP.jl v1 `access_log` default (`\$time_iso8601 - \$remote_addr:\$remote_port - "\$request" \$status`).
HTTP.jl v2 removed the `logfmt`/`access_log` server kwargs, so request logging now
lives in the middleware chain.
"""
function AccessLogMiddleware()
    return function(handle)
        return function(req::HTTP.Request)
            response = handle(req)
            ip = Base.get(req.context, :ip, nothing)
            @info "$(Dates.format(now(), "yyyy-mm-ddTHH:MM:SS")) - $ip - \"$(req.method) $(req.target)\" $(response.status)"
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
        return parseparam(param.type, raw_pathparams[name])
    end

    function queryparam_strategy(lr::LazyRequest, param::Param{T}, name::String) where T
        raw_queryparams = Types.queryvars(lr)
        if !haskey(raw_queryparams, name) && param.hasdefault
            return param.default
        else
            return parseparam(param.type, raw_queryparams[name])
        end
    end

    function queryparam_strategy_no_default(lr::LazyRequest, param::Param{T}, name::String) where T
        raw_queryparams = Types.queryvars(lr)
        return parseparam(param.type, raw_queryparams[name])
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
