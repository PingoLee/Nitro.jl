# BI App Config Example

Nitro should not own your application configuration. Keep the config struct, file loading,
and environment-variable resolution in the app layer, then pass the resulting object into
Nitro with `serve(context=...)`.

This is the right pattern for a BI-style app that uses Nitro for HTTP, `Nitro.Auth` for
authentication helpers, `Nitro.Workers` for in-process jobs, and `PormG` as an external
package dependency.

## Recommended Shape

Split the config by responsibility instead of using one large untyped dictionary.

```julia
module BIAppConfig

export AppConfig, DatabaseConfig, AuthConfig, WorkerConfig, load_config

struct DatabaseConfig
    adapter::String
    host::String
    port::Int
    database::String
    username::String
    password::String
end

struct AuthConfig
    secret_key::String
    api_keys::Dict{String, String}
    allowed_kids::Vector{String}
    session_secure::Bool
    session_timeout::Int
end

struct WorkerConfig
    max_concurrent_tasks::Int
    default_timeout::Int
    retry_limit::Int
end

struct AppConfig
    server_host::String
    server_port::Int
    db::DatabaseConfig
    db_sch::DatabaseConfig
    auth::AuthConfig
    workers::WorkerConfig
    env::String
end

function load_config(env::String="dev")
    db_default = DatabaseConfig(
        get(ENV, "DB_ADAPTER", "postgres"),
        get(ENV, "DB_HOST", "localhost"),
        parse(Int, get(ENV, "DB_PORT", "5432")),
        get(ENV, "DB_NAME", "bi_db"),
        get(ENV, "DB_USER", "postgres"),
        get(ENV, "DB_PASS", "")
    )

    auth = AuthConfig(
        get(ENV, "API_SECRET_KEY", "changeme"),
        Dict("default" => get(ENV, "API_SECRET_KEY", "changeme")),
        ["default"],
        env == "prod",
        3600
    )

    workers = WorkerConfig(
        parse(Int, get(ENV, "WORKER_CONCURRENCY", "4")),
        300,
        3
    )

    return AppConfig(
        get(ENV, "HOST", "127.0.0.1"),
        parse(Int, get(ENV, "PORT", "8000")),
        db_default,
        db_default,
        auth,
        workers,
        env
    )
end

end
```

## Why This Lives In The App

- Nitro stays framework-focused and does not accumulate app-specific config types.
- `PormG` remains external; Nitro does not need to know how your BI app names or groups databases.
- Each app can evolve its own config without forcing new public API into Nitro core.

## Mapping From A Genie BI App

Typical migration mapping:

- `db/connection.yml` -> `DatabaseConfig`
- `config/all_sort.yml` JWT keys -> `AuthConfig`
- worker tuning and retry limits -> `WorkerConfig`
- host, port, and environment -> top-level `AppConfig`

If your app has multiple databases such as `db`, `db_sch`, or `db_esus`, keep those as
separate typed fields or store them in a typed dictionary owned by the app.

## Using The Config With Nitro

Pass the config into Nitro as the typed context payload.

```julia
using HTTP
using Nitro
using .BIAppConfig

function health(req::HTTP.Request, ctx::Context{AppConfig})
    return Res.json(Dict(
        "env" => ctx.payload.env,
        "host" => ctx.payload.server_host,
        "port" => ctx.payload.server_port,
    ))
end

urlpatterns("",
    path("/health", health, method="GET"),
)

config = load_config(get(ENV, "APP_ENV", "dev"))
serve(host=config.server_host, port=config.server_port, context=config)
```

## Recommended Bootstrap Order

1. Load YAML or TOML files in the app layer.
2. Apply environment variable overrides.
3. Build `AppConfig`.
4. Initialize external packages such as `PormG` from the app layer.
5. Build routes, middleware, and worker hooks.
6. Start Nitro with `serve(context=config)`.

For the BI server migration, this config object is the bridge between the old Genie layout
and the new Nitro app bootstrap.