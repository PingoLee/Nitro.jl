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
    json(Dict("users" => []))
end

function get_user(req, id::Int)
    json(Dict("id" => id))
end

# Register routes
urlpatterns(CONTEXT[], "/api/v1",
    path("/users", list_users, method=GET),
    path("/users/<int:id>", get_user, method=GET),
)
```
"""

using HTTP

using ..AppContext: ServerContext
using ..Types: Nullable, RouteDefinition
using ..Util: join_url_path
using ..RouterHOF: genkey, process_middleware

export path, urlpatterns, include_routes, convert_django_path

# ─── Path Converter Registry ─────────────────────────────────────────

const CONVERTERS = Dict{String, Type}(
    "int"   => Int,
    "str"   => String,
    "float" => Float64,
    "bool"  => Bool,
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

Path converters: `<int:name>`, `<str:name>`, `<float:name>`, `<bool:name>`.
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

"""
    urlpatterns(ctx, prefix, routes...)

Register a group of `RouteDefinition`s under a common URL prefix.
"""
function urlpatterns(ctx::ServerContext, prefix::String, routes::RouteDefinition...)
    for route_def in routes
        register_route(ctx, prefix, route_def)
    end
end

function urlpatterns(ctx::ServerContext, prefix::String, routes::Vector{RouteDefinition})
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


# ─── Internal: Register a single RouteDefinition ─────────────────────

"""
Register a single RouteDefinition by calling the parent Core.register().
We use `parentmodule` to late-bind to the `register` function, avoiding
circular dependency issues at include-time.
"""
function register_route(ctx::ServerContext, prefix::String, route_def::RouteDefinition)
    full_path = join_url_path(prefix, route_def.pattern)
    
    # Set up per-route middleware if defined
    if !isnothing(route_def.middleware)
        processed_mw = process_middleware(ctx, route_def.middleware)
        for method in route_def.methods
            key = genkey(method, full_path)
            ctx.service.custommiddleware[key] = (nothing, processed_mw)
        end
    end
    
    # Call Core.register via the parent module
    core = parentmodule(Routing)
    for method in route_def.methods
        core.register(ctx, method, full_path, route_def.handler)
    end
end


end # module Routing
