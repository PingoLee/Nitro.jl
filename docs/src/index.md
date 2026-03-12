# Nitro.jl

Nitro is a Julia web framework built on HTTP.jl.

The public API documented here is:

- `serve()` for starting the server
- `path()`, `urlpatterns()`, and `include_routes()` for route registration
- `req.params`, `req.query`, `req.session`, and `req.ip` for request ergonomics
- `serve(context=...)` for typed application configuration

## Minimal Example

```julia
using HTTP
using Nitro

function greet(req::HTTP.Request)
    return Res.json(Dict("message" => "hello world"))
end

urlpatterns("",
    path("/greet", greet, method="GET"),
)

serve()
```

## Centralized Routing

```julia
using HTTP
using Nitro
using UUIDs

function list_users(req::HTTP.Request)
    return Res.json(Dict("users" => ["alice", "bob"]))
end

function get_user(req::HTTP.Request, id::Int)
    return Res.json(Dict("id" => id))
end

function get_key(req::HTTP.Request, key::UUID)
    return Res.json(Dict("key" => string(key)))
end

api_routes = [
    path("/users", list_users, method="GET"),
    path("/users/<int:id>", get_user, method="GET"),
    path("/keys/<uuid:key>", get_key, method="GET"),
]

urlpatterns("/api", api_routes)
serve()
```

Supported converters are `<int:name>`, `<str:name>`, `<float:name>`, `<bool:name>`, and `<uuid:name>`.

### Modular Route Inclusion

```julia
using Nitro

function dashboard(req)
    return Res.send("dashboard")
end

function admin(req)
    return Res.send("admin")
end

admin_routes = [
    path("/dashboard", dashboard, method="GET"),
    path("/admin", admin, method="GET"),
]

urlpatterns("",
    include_routes("/panel", admin_routes)...,
)

serve()
```

## Request Accessors

Nitro extends `HTTP.Request` with common accessors:

```julia
using HTTP
using Nitro

function inspect_request(req::HTTP.Request, id::Int)
    return Res.json(Dict(
        "id" => id,
        "params" => req.params,
        "query" => req.query,
        "session" => req.session,
        "ip" => string(req.ip),
    ))
end

urlpatterns("",
    path("/items/<int:id>", inspect_request, method="GET"),
)

serve()
```

## App Context Pipeline

Keep config in the application layer and pass it into Nitro at startup.

```julia
using HTTP
using Nitro

struct AppConfig
    app_name::String
    environment::String
end

function config_handler(req::HTTP.Request, ctx::Context{AppConfig})
    return Res.json(Dict(
        "app" => ctx.payload.app_name,
        "environment" => ctx.payload.environment,
    ))
end

urlpatterns("",
    path("/config", config_handler, method="GET"),
)

config = AppConfig("nitro-docs", "dev")
serve(context=config)
```

Recommended bootstrap pattern:

1. Load config in the app layer.
2. Resolve environment variables and secrets.
3. Build routes and middleware.
4. Start Nitro with `serve(context=...)`.

## Session Middleware

```julia
using HTTP
using Nitro

function login(req::HTTP.Request)
    req.session["user_id"] = 42
    return Res.json(Dict("logged_in" => true))
end

function profile(req::HTTP.Request)
    session = req.session
    if isnothing(session) || !haskey(session, "user_id")
        return Res.status(401, "Unauthorized")
    end
    return Res.json(Dict("user_id" => session["user_id"]))
end

urlpatterns("",
    path("/login", login, method="POST"),
    path("/profile", profile, method="GET"),
)

serve(middleware=[
    SessionMiddleware(
        cookie_name="nitro_session",
        max_age=3600,
        secure=false,
        httponly=true,
        samesite="Lax",
    ),
])
```

`secure=false` is useful for local HTTP development. Production deployments should keep `secure=true`.

## Middleware Execution Order

Middleware runs in this order:

1. Global prefix middleware
2. Custom middleware
3. Default serializer/error middleware
4. Router dispatch

Place IP extraction before rate limiting and session/auth middleware before guards that rely on `req.session`.
