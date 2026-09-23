# ── Route registration ──────────────────────────────────────────────────────────
# Handler introspection and `HTTP.register!` wiring for `path()`/`urlpatterns()`.
# Included into `module Core` by src/core.jl — not a submodule; see the hub for why.

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

function register(ctx::App, httpmethod::String, route::Union{String,HOFRouter}, func::Function; type_hints::Dict{Symbol, Type}=Dict{Symbol, Type}())
    route = parse_route(httpmethod, route)
    func_details = parse_func_params(route, func; type_hints)
    registerhandler(ctx, ctx.service.router, httpmethod, route, func, func_details)
end

function register_internal(ctx::App, router::Router, httpmethod::String, route::Union{String,HOFRouter}, func::Function; type_hints::Dict{Symbol, Type}=Dict{Symbol, Type}())
    route = parse_route(httpmethod, route)
    func_details = parse_func_params(route, func; type_hints)
    registerhandler(ctx, router, httpmethod, route, func, func_details)
end

function registerhandler(ctx::App, router::Router, httpmethod::String, route::String, func::Function, func_details::NamedTuple)
    method = first(methods(func))
    no_args = method.nargs == 1

    info = func_details.info
    has_req_kwarg = :request in Base.kwarg_decl(method)
    has_ctx_kwarg = :context in Base.kwarg_decl(method)
    has_path_params = !isempty(info.args)

    arg_type = first_arg_type(method, httpmethod)
    func_handle = select_handler(arg_type, has_ctx_kwarg, has_req_kwarg, has_path_params; no_args=no_args)
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

    # `HEAD` on the app's own router goes through the precedence table below (#277). Other
    # routers (the static mounts register `"*"` on theirs) keep the plain registration.
    owns_head = router === ctx.service.router
    if owns_head && httpmethod == HEAD
        _register_head!(ctx, router, route, handle, :explicit)
        return nothing
    end

    # No request carries `*`, `STREAM` or `WEBSOCKET`, so the leaf carries the declared method
    # for `compose` to key this route's middleware on (#282). See `DeclaredMethodHandler`.
    leaf = _is_declared_only(httpmethod) ? DeclaredMethodHandler(httpmethod, handle) : handle
    _check_keyable(ctx, router, httpmethod, route)

    for resolved_httpmethod in resolved_methods
        HTTP.register!(router, resolved_httpmethod, route, leaf)
    end

    # Literal `GET` only. `STREAM` and `WEBSOCKET` also resolve to `GET` above, but a handler
    # that writes to the raw stream or upgrades the connection has no meaningful `HEAD`.
    #
    # Not on a router built with HTTP.jl-level `middleware` either: `register!` wraps the handler
    # in it, the leaf then no longer `isa DeclaredMethodHandler`, and `compose` would key the
    # `HEAD` on `HEAD|…`, finding none of the `GET` route's guards. A `405` is the safe answer.
    if owns_head && httpmethod == GET && router.middleware === nothing
        _register_head!(ctx, router, route, DeclaredMethodHandler(GET, handle), :auto)
    elseif owns_head && (httpmethod == STREAM || httpmethod == WEBSOCKET)
        # These replace the `GET` leaf. An auto-`HEAD` left behind by an earlier `GET` at the same
        # path (Revise, a re-run `urlpatterns`) would keep serving that old handler.
        _register_head!(ctx, router, route, req::HTTP.Request -> router._405(req), :retired)
    end
    return nothing
end

# The declared methods no request carries. A leaf registered under one is reached by other
# methods, so it must say which method its middleware is keyed on.
_is_declared_only(httpmethod::String)::Bool =
    httpmethod == "*" || httpmethod == STREAM || httpmethod == WEBSOCKET

"""
    _check_keyable(ctx, router, httpmethod, route)

Refuse a `"*"`, `STREAM` or `WEBSOCKET` route that has middleware to key, on a router built with
HTTP.jl-level `middleware` (#282). `HTTP.register!` wraps the leaf in that middleware, which
hides the [`DeclaredMethodHandler`](@ref), so `compose` would key on `req.method`, find nothing,
and never run the route's guards. Failing here is the loud form of that outcome.

Only a route with published middleware is refused, so unguarded routes and the static mounts
(`"*"`, no middleware) register as before. Both publishers run before `registerhandler`:
`register_route` publishes, then registers, and `InnerRouter` publishes inside `parse_route`.
"""
function _check_keyable(ctx::App, router::Router, httpmethod::String, route::String)
    router.middleware === nothing && return nothing
    _is_declared_only(httpmethod) || return nothing
    haskey(snapshot(ctx.service.custommiddleware), genkey(httpmethod, route)) || return nothing
    throw(ArgumentError(
        "Middleware on the $httpmethod route $route would never run: this router wraps every " *
        "handler in HTTP.jl-level `middleware`, which hides the declared method Nitro keys " *
        "route middleware on. Register the route on a router without HTTP.jl-level " *
        "middleware, or, for \"*\", list the methods it serves with `methods = [...]`. " *
        "Removing the route's middleware takes a restart: published middleware is not unpublished."))
end

"""
    _route_shape(route) -> String

The identity HTTP.jl's route tree gives `route`'s leaf. A variable with no pattern is a wildcard
node there, the same as `*`, so `/a/{id}` and `/a/{x}` share one leaf. A variable with a pattern
is keyed on its pattern alone. Mirrors `HTTP.Handlers.register!`'s split and `VARREGEX`.
"""
function _route_shape(route::String)::String
    shape = map(split(route, '/'; keepempty = false)) do seg
        m = Base.match(r"^{([^:{}]+)(?::(.*))?}$", seg)
        m === nothing ? String(seg) : m.captures[2] === nothing ? "*" : string("{:", m.captures[2], "}")
    end
    return join(shape, '/')
end

"""
    _register_head!(ctx, router, route, handler, claim)

Register `handler` as `route`'s `HEAD` leaf, resolving who owns it (#277). `claim` is:

- `:explicit` — a `HEAD` route. It always wins, in either registration order.
- `:auto` — the [`DeclaredMethodHandler`](@ref) a `GET` route adds, keyed on `GET`. Skipped while
  an explicit `HEAD` owns the shape.
- `:retired` — a `STREAM`/`WEBSOCKET` route replaced the `GET` leaf. Only an auto `HEAD` is
  replaced, by the router's own `405`, since HTTP.jl has no way to remove a leaf.

HTTP.jl warns whenever a leaf is replaced. Replacing a leaf this table added itself (`:auto` or
`:retired`) is expected, so it is silenced; the `GET` replacement that triggers it has already
warned. Two explicit `HEAD` routes on one shape still warn, as before.
"""
function _register_head!(ctx::App, router::Router, route::String, handler::Function, claim::Symbol)
    shape = _route_shape(route)
    Base.lock(ctx.service.head_routes_lock) do
        owner = get(ctx.service.head_routes, shape, nothing)
        claim === :auto && owner === :explicit && return nothing
        claim === :retired && owner !== :auto && return nothing
        ctx.service.head_routes[shape] = claim
        if owner === :auto || owner === :retired
            Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
                HTTP.register!(router, HEAD, route, handler)
            end
        else
            HTTP.register!(router, HEAD, route, handler)
        end
        return nothing
    end
end
