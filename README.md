# Nitro.jl

Nitro is a Julia web framework built on top of HTTP.jl.

The current public routing contract is centered on `path()`, `urlpatterns()`, and `include_routes()`. `serve()` is the primary server entry point and runs in parallel by default.

## Installation

```julia
pkg> add Nitro
```

## Quick Start

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

## Routing

Nitro uses Django-style centralized route registration.

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

urlpatterns("/api",
    path("/users", list_users, method="GET"),
    path("/users/<int:id>", get_user, method="GET"),
    path("/keys/<uuid:key>", get_key, method="GET"),
)

serve()
```

Supported converters are `<int:name>`, `<str:name>`, `<float:name>`, `<bool:name>`, and `<uuid:name>`.

### Modular Routes

```julia
using Nitro

function profile(req)
    return Res.send("profile")
end

function settings(req)
    return Res.send("settings")
end

user_routes = [
    path("/profile", profile, method="GET"),
    path("/settings", settings, method="GET"),
]

urlpatterns("",
    include_routes("/user", user_routes)...,
)

serve()
```

## Request Ergonomics

Nitro adds shorthand accessors to `HTTP.Request`:

- `req.params` for path parameters
- `req.query` for query parameters
- `req.session` for session state injected by middleware
- `req.ip` for the caller IP

```julia
using HTTP
using Nitro

function show_request(req::HTTP.Request, id::Int)
    return Res.json(Dict(
        "id" => id,
        "params" => req.params,
        "query" => req.query,
        "session" => req.session,
        "ip" => string(req.ip),
    ))
end

urlpatterns("",
    path("/items/<int:id>", show_request, method="GET"),
)

serve()
```

## App Context

Application configuration belongs in your app, not in Nitro globals. Pass typed config through `serve(context=...)`.

```julia
using HTTP
using Nitro

struct AppConfig
    app_name::String
    environment::String
end

function health(req::HTTP.Request, ctx::Context{AppConfig})
    return Res.json(Dict(
        "app" => ctx.payload.app_name,
        "environment" => ctx.payload.environment,
    ))
end

urlpatterns("",
    path("/health", health, method="GET"),
)

config = AppConfig("nitro-app", "dev")
serve(context=config)
```

Recommended bootstrap flow:

1. Load config in your app.
2. Run app initializers.
3. Build route modules with `path()` and `urlpatterns()`.
4. Start Nitro with `serve(context=app_config)`.

## Session Middleware

`SessionMiddleware` manages server-side session state and now exposes cookie security settings directly.

```julia
using HTTP
using Nitro

function login(req::HTTP.Request)
    req.session["user_id"] = 42
    return Res.json(Dict("logged_in" => true))
end

function profile(req::HTTP.Request)
    user_id = isnothing(req.session) ? nothing : get(req.session, "user_id", nothing)
    return isnothing(user_id) ? Res.status(401, "Unauthorized") : Res.json(Dict("user_id" => user_id))
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

Use `secure=false` for local HTTP development only. Keep `secure=true` in production.

## Middleware Order

Nitro applies middleware in this order:

1. Global prefix middleware
2. Custom middleware
3. Default serializer/error middleware
4. Router dispatch

That order matters for auth, session loading, rate limiting, and any request mutation middleware.

## Response Helpers

Nitro exposes `Res` helpers for explicit response construction:

- `Res.json`
- `Res.send`
- `Res.status`

These are the preferred examples for new applications.

## Documentation

The docs site is built from the files in `docs/src`. The API reference in `docs/src/api.md` and the docs homepage in `docs/src/index.md` follow the same public contract as this README.
