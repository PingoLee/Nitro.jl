---
applyTo: "src/**/*.jl"
description: "Nitro.jl Migration Guide — Porting Genie.jl apps (like BI Server) to Nitro.jl"
---

# Nitro.jl Migration & App Bootstrap Instructions

This guide outlines the migration from the legacy BI Server at `/home/pingo03/app/bi_server` to the new Nitro project at `/home/pingo03/app/bi_server_nitro`.

## 1. Project Setup
- **Source Code**: Refer to `/home/pingo03/app/bi_server` for legacy business logic, routes, and model definitions.
- **Development Mode**: Always add Nitro.jl via `Pkg.develop(path="/home/pingo03/app/Nitro.jl")` during migration to allow simultaneous framework/app development.
- **Functional Parity**: The goal is 1:1 parity with the legacy `/home/pingo03/app/bi_server` implementation while moving to Nitro's Django-style routing and multi-threaded worker architecture.
- **Dependencies**: Explicitly add `HTTP`, `YAML`, `JSON`, `UUIDs`, and `PormG` to the migration project.
- **Project Folder Structure**:
    - `src/Config.jl` - Holds the `AppConfig` struct and YAML loading.
    - `src/Bootstrap.jl` - (Optional) Service startup (PormG, Workers) before `serve()`.

## 2. Configuration Pattern (AppConfig)
- **Layering**: Nitro core does NOT own app configuration. Define a typed `AppConfig` struct in the application layer.
- **Multi-Environment Loading**: Use `YAML.load_file` to read `db/connection.yml` and `config/all_sort.yml`, then map them to your typed `AppConfig`.
- **Structure**:
    ```julia
    struct AppConfig
        db::DatabaseConfig     # For PormG
        auth::AuthConfig       # For Nitro.Auth
        workers::WorkerConfig  # For Nitro.Workers
        server_host::String
        server_port::Int
    end
    ```
- **Injection**: Pass the config into Nitro via the `context` keyword in `serve()`. Access it in handlers via `Context{AppConfig}`.

## 3. PormG Integration
- **Initialization**: Call `PormG.Configuration.load()` in your app's bootstrap phase (before `serve()`).
- **Connection Management**:
    - **Single DB**: PormG handles its own global state.
    - **Multi-DB (e.g., db_sch, db_esus)**: Store the initialized `PormG` handles in `ctx.extensions[:pormg]` or as part of your `AppConfig` to ensure handlers can reach the correct schema.
- **Weak Dependency**: Remember any code that uses `PormG` should Ideally live in the app layer or a Nitro package extension, NEVER in Nitro.jl's `src/`.

## 4. Routing Migration (Genie -> Nitro)
- Replace Genie `@route` or `route()` with Nitro `path()` and `urlpatterns()`.
- **Path Converters**: 
    - Genie `:id` -> Nitro `<int:id>` or `<str:id>`.
    - Genie `:uuid` -> Nitro `<uuid:name>`.
- **Modularization**: Split routes into logical files and include them using `include_routes("/prefix", router_array)...`.
- **CORS & Preflight**: Nitro handles CORS via `CORSMiddleware`. You no longer need manual `OPTIONS` routes in your `urlpatterns`.

## 5. Background Workers (The BI System)
- **Porting**: Use `Nitro.Workers` to replace the custom `bi_server` Channel-based backend.
- **Sequential Queues**: 
    - In `bi_server`: `Workers.submit_sequential_task("agendamento", callback)`.
    - In Nitro: `Nitro.Workers.submit_sequential_task(ctx, "agendamento", callback)`.
- **World Age**: Nitro's worker already uses `Base.invokelatest` internally, so you don't need to wrap callbacks manually unless passing complex objects.
- **Thread Safety**: Nitro runs in parallel mode. The `Nitro.Workers` system uses `Threads.@spawn` and `ReentrantLock` specifically to prevent stalling the web server.

## 6. Authentication & Middleware
- **JWT Migration**: Replace `JwtAuth.jl` and `Security.jl` with Nitro's native `Nitro.Auth.JWT`.
- **Guards vs Logic**: Move any manual `Security.authorize_request(request)` calls out of your handlers and into Nitro **Guards** (`@guard login_required`).
- **Session Data**: Use `req.session` for stateful data and `req.user` for the authenticated identity.
