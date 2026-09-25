module Routing

"""
Django-style centralized URL dispatch for Nitro/Nitro.

Provides `path()`, `urlpatterns()`, and `include_routes()` for centralized,
declarative route definition with typed path converters.

## Example

```julia
using Nitro

# Define handlers
function list_users(req)
    Res.json(Dict("users" => []))
end

function get_user(req, id::Int)
    Res.json(Dict("id" => id))
end

# Register routes
urlpatterns(CONTEXT[], "/api/v1",
    path("/users", list_users, method=GET),
    path("/users/<int:id>", get_user, method=GET),
)
```
"""

using HTTP
using UUIDs: UUID

using ..AppContext: App
using ..Types: Nullable, RouteDefinition, NamedRoute
using ..Util: join_url_path, parseparam
using ..Errors: is_unrecoverable
using ..RouterHOF: genkey, process_middleware, publish_route_middleware!, _has_layers

export path, urlpatterns, include_routes, convert_django_path

const ROUTE_PARAM_REGEX = r"{(\w+)}"

# ─── Path Converter Registry ─────────────────────────────────────────

const CONVERTERS = Dict{String, Type}(
    "int"   => Int,
    "str"   => String,
    "float" => Float64,
    "bool"  => Bool,
    "uuid"  => UUID,
)

# ─── Path Converter Parser ───────────────────────────────────────────

"""
    convert_django_path(pattern::String) -> (nitro_path, type_hints)

Convert a Django-style path pattern (`<int:id>`) into Nitro's `{id}` format,
returning the converted path and a `Dict{Symbol,Type}` of type hints.
"""
function convert_django_path(pattern::String)
    type_hints = Dict{Symbol, Type}()
    converter_regex = r"<(\w+):(\w+)>"
    
    nitro_path = replace(pattern, converter_regex => function(match)
        m = Base.match(converter_regex, match)
        converter_name = m.captures[1]
        param_name = m.captures[2]
        
        if haskey(CONVERTERS, converter_name)
            type_hints[Symbol(param_name)] = CONVERTERS[converter_name]
        else
            throw(ArgumentError(
                "Unknown path converter: '$converter_name'. " *
                "Available: $(join(keys(CONVERTERS), ", "))"
            ))
        end
        
        return "{$param_name}"
    end)
    
    return (nitro_path, type_hints)
end

# ─── path() — Define a single route ──────────────────────────────────

"""
    path(pattern, handler; method="GET", methods=nothing, name=nothing, middleware=nothing)

Define a single route using Django-style path syntax.

Path converters: `<int:name>`, `<str:name>`, `<float:name>`, `<bool:name>`, `<uuid:name>`.

A `"GET"` route also answers `HEAD` through the same handler and middleware, unless a `HEAD` route
is registered explicitly for the same path. That route wins whatever the registration order.

`middleware` runs top-down in list order, after global and router middleware, so authenticate
before you authorize: `middleware = [BearerAuth(validator), GuardMiddleware(login_required())]`.
"""
function path(pattern::String, handler::Function; 
    method::String = "GET",
    methods::Nullable{Vector{String}} = nothing,
    name::Nullable{String} = nothing,
    middleware::Nullable{Vector} = nothing)
    
    nitro_path, type_hints = convert_django_path(pattern)
    http_methods = !isnothing(methods) ? methods : [method]
    
    return RouteDefinition(nitro_path, handler, http_methods, name, middleware, type_hints)
end

# ─── urlpatterns() — Group routes under a prefix ─────────────────────

# Documented on the public `Nitro.urlpatterns` (src/methods.jl), which shadows this one (#186).
function urlpatterns(ctx::App, prefix::String, routes::RouteDefinition...)
    for route_def in routes
        register_route(ctx, prefix, route_def)
    end
end

function urlpatterns(ctx::App, prefix::String, routes::Vector{RouteDefinition})
    for route_def in routes
        register_route(ctx, prefix, route_def)
    end
end

# ─── include_routes() — Modular route inclusion ──────────────────────

"""
    include_routes(prefix, routes) -> Vector{RouteDefinition}

Prepend a sub-prefix to each route for modular URL inclusion.
"""
function include_routes(prefix::String, routes::Vector{RouteDefinition})
    return [
        RouteDefinition(
            join_url_path(prefix, r.pattern),
            r.handler, r.methods, r.name, r.middleware, r.type_hints
        )
        for r in routes
    ]
end

function include_routes(prefix::String, routes::RouteDefinition...)
    return include_routes(prefix, collect(routes))
end


function register_named_route!(ctx::App, name::String, full_path::String,
                               type_hints::Dict{Symbol, Type} = Dict{Symbol, Type}())
    route = NamedRoute(full_path, copy(type_hints))
    return Base.lock(ctx.service.named_routes_lock) do
        existing = get(ctx.service.named_routes, name, nothing)
        if isnothing(existing)
            ctx.service.named_routes[name] = route
        elseif existing.path != full_path
            throw(ArgumentError(
                "Duplicate route name: '$name' is already registered for '$(existing.path)'"
            ))
        elseif existing != route
            # Same path, different converters (`<int:id>` for GET, `{id}` for POST): `url` could
            # not know which rule a value must satisfy, so one name cannot reverse both.
            throw(ArgumentError(
                "Duplicate route name: '$name' is already registered for '$full_path' " *
                "with different path converters"
            ))
        end

        return full_path
    end
end

"""
    check_route_value(pattern, param_name, raw, type_hints)

Refuse a value `url` must not substitute into `pattern` (#328), with the rule Django's `reverse()`
applies: a value the route itself would not accept.

- `""`, `"."` and `".."` are never a path segment. `/`, `?` and `#` are percent-escaped, but these
  pass through escaping unchanged: an empty value at the front turned `/{org}/{page}` into
  `//evil.example`, a scheme-relative URL and so an open redirect once handed to `Res.redirect`,
  and `..` produced a dot-segment that a client or proxy resolves away.
- Under a converter (`<int:id>`), the value must parse through `parseparam` as the converter's
  type — the parser the router binds that segment with. It is the *converter* that is checked,
  not the handler's annotation: a handler that narrows `<int:id>` to `id::UInt8`, or types a
  converter-less `{id}` as `Int`, can still answer a URL `url` built with a 400. A plain
  `{param}` has no converter, so only the first rule applies.

The value is left out of the message, as `parseparam`'s own errors leave it out.
"""
function check_route_value(pattern::String, param_name::AbstractString, raw::String, type_hints::Dict{Symbol, Type})
    if raw in ("", ".", "..")
        throw(ArgumentError(
            "Route parameter '$param_name' for route '$pattern' cannot be empty, '.' or '..'"
        ))
    end

    T = get(type_hints, Symbol(param_name), String)
    T === String && return nothing
    try
        parseparam(T, raw)
    catch e
        is_unrecoverable(e) && rethrow()
        throw(ArgumentError(
            "Route parameter '$param_name' for route '$pattern' does not match its $(nameof(T)) converter"
        ))
    end
    return nothing
end

function build_named_route(pattern::String, type_hints::Dict{Symbol, Type}, kwargs)
    provided = Dict{String, String}(string(key) => string(value) for (key, value) in kwargs)
    consumed = Set{String}()

    route = replace(pattern, ROUTE_PARAM_REGEX => function(match)
        captures = Base.match(ROUTE_PARAM_REGEX, match).captures
        param_name = captures[1]
        if !haskey(provided, param_name)
            throw(ArgumentError("Missing route parameter '$param_name' for route '$pattern'"))
        end

        raw = provided[param_name]
        check_route_value(pattern, param_name, raw, type_hints)
        push!(consumed, param_name)
        return HTTP.escapeuri(raw)
    end)

    extra_params = sort!(collect(setdiff(Set(keys(provided)), consumed)))
    if !isempty(extra_params)
        throw(ArgumentError(
            "Unknown route parameters for route '$pattern': $(join(extra_params, ", "))"
        ))
    end

    return route
end

"""
    url(ctx, name; kwargs...)

Build a URL path for a named route by substituting `{param}` placeholders from
the registered route pattern. Each value is checked by `check_route_value` first.
"""
function url(ctx::App, name::String; kwargs...)
    route = Base.lock(ctx.service.named_routes_lock) do
        get(ctx.service.named_routes, name, nothing)
    end

    if isnothing(route)
        throw(ArgumentError("Unknown route name: '$name'"))
    end

    return build_named_route(route.path, route.type_hints, kwargs)
end


# ─── Internal: Register a single RouteDefinition ─────────────────────

"""
Register a single RouteDefinition by calling the parent Core.register().
We use `parentmodule` to late-bind to the `register` function, avoiding
circular dependency issues at include-time.
"""
function register_route(ctx::App, prefix::String, route_def::RouteDefinition)
    full_path = join_url_path(prefix, route_def.pattern)

    if !isnothing(route_def.name)
        register_named_route!(ctx, route_def.name, full_path, route_def.type_hints)
    end
    
    # Set up per-route middleware if defined.
    #
    # `!isempty` matters as much as `!isnothing`: publishing a `(nothing, Function[])` entry for
    # `middleware=[]` contributes zero layers but makes `custommiddleware` permanently non-empty,
    # which disables `compose`'s per-request emptiness fast path for the WHOLE application —
    # every request would then pay a `gethandler` and a chain-cache lookup for nothing — plus,
    # on the first request for each route, the chain fold. (Before #80 it also paid a SECOND
    # `gethandler`; the fast path is still worth defending without it.)
    # `middleware=[]` means "this
    # route adds none of its own", which is indistinguishable from omitting the kwarg.
    if _has_layers(route_def.middleware)
        processed_mw = process_middleware(ctx, route_def.middleware)
        for method in route_def.methods
            key = genkey(method, full_path)
            publish_route_middleware!(ctx, key, (nothing, processed_mw))
        end
    end
    
    # Call Core.register via the parent module
    core = parentmodule(Routing)
    for method in route_def.methods
        core.register(ctx, method, full_path, route_def.handler; type_hints=route_def.type_hints)
    end
end


end # module Routing
