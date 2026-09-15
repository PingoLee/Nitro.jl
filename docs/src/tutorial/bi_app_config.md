# BI App Config Example

Nitro should not own your application configuration. Keep the config struct, file loading,
and environment-variable resolution in the app layer, then pass the resulting object into
Nitro with `serve(context=...)`.

This is the right pattern for a BI-style app that uses Nitro for HTTP, `Nitro.Auth` for
authentication helpers, `Nitro.Workers` for in-process jobs, and `PormG` as an external
package dependency.

Every secret on this page is a [`SecretString`](secrets.md#Keeping-Secrets-Out-of-Logs-and-REPL-Output)
and is required from the environment rather than defaulted. [Managing Secrets](secrets.md) is the
canonical page for *why*; this one shows the shape a full `AppConfig` takes.

## Recommended Shape

Split the config by responsibility instead of using one large untyped dictionary.

```julia
module BIAppConfig

using Nitro: SecretString

export AppConfig, DatabaseConfig, AuthConfig, WorkerConfig, load_config, required_env

# Secrets are REQUIRED, never defaulted. A `get(ENV, "API_SECRET_KEY", "dev-secret")` ships a
# known key to production the first time the variable is missing there, and nothing reports it.
# This fails at boot instead. See `secrets.md`.
required_env(name::String) =
    get(ENV, name, nothing) === nothing ? error("$name must be set") : ENV[name]

struct DatabaseConfig
    adapter::String
    host::String
    port::Int
    database::String
    username::String
    password::SecretString
end

struct AuthConfig
    secret_key::SecretString
    api_keys::Dict{String, SecretString}
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
        SecretString(required_env("DB_PASS"))
    )

    api_secret = SecretString(required_env("API_SECRET_KEY"))

    auth = AuthConfig(
        api_secret,
        # The keyset holds the WRAPPER, not a revealed copy. Copying `reveal(...)` into a plain
        # `Dict` puts the raw secret straight back onto the display and JSON paths that
        # `SecretString` exists to close -- the field would be masked and the Dict entry would
        # not. Add one entry per key id as you rotate.
        Dict("default" => api_secret),
        ["default"],
        # NOT `env == "prod"`. A security flag must fail CLOSED: an environment variable
        # missing on a production box would silently drop the cookie `Secure` attribute,
        # and the environment name is exactly the value most likely to be absent.
        #
        # Note the polarity. The knob is named for the SECURE state and only the literal
        # "0" turns it off, so every misspelling of "off" -- `false`, `no`, `FALSE` -- still
        # leaves the cookie secure. A negatively-named `SESSION_INSECURE` would invert that:
        # anything that is not exactly "0" would disable the protection.
        get(ENV, "SESSION_SECURE", "1") != "0",
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

Note which values are defaulted and which are not. `DB_HOST`, `DB_PORT`, `HOST`, `PORT` and
`WORKER_CONCURRENCY` are ordinary configuration and carry sensible defaults. `API_SECRET_KEY` and
`DB_PASS` are secrets and go through `required_env`, so a missing one is a boot failure rather than
a silent fallback.

!!! danger "Never commit a fallback for a secret"
    `get(ENV, "API_SECRET_KEY", "dev-secret")` looks convenient and is the single most common way
    a known key reaches production: the variable is simply absent on one box and nothing reports
    it. [Managing Secrets](secrets.md) states the rule — for local development put a
    non-checked-in value in `.env`, never a literal in the source.

    This applies to CI too. A suite that needs the app to boot sets the variables in its own
    environment; it does not get them from a default baked into the config module.

!!! warning "Do not gate security on the environment name"
    `current_env()` selects *which config to load*. It must not decide whether a security
    control is on — note that `session_secure` above defaults to secure and takes an explicit
    `SESSION_SECURE=0` to relax, rather than testing `current_env() == "prod"`. An
    environment variable that is missing on a production box is the normal failure, and a
    control keyed off it fails open. See
    [What this is *not* for](environment.md#What-this-is-*not*-for).

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

config = load_config(current_env())
serve(host=config.server_host, port=config.server_port, context=config)
```

### Reading A Secret Back Out

`SecretString` is deliberately **not** an `AbstractString`, so it cannot flow into a string
operation or a log line unnoticed. Framework components that need the raw key — `CSRFMiddleware`,
`encode_jwt`, `jwt_validator`, `set_cookie!(..., encrypted=true)` — take a plain `String`, so
unwrap with `reveal` at the call itself rather than storing a revealed copy in the config:

```julia
serve(
    host=config.server_host,
    port=config.server_port,
    context=config,
    middleware=[
        SessionMiddleware(store=MemoryStore()),
        CSRFMiddleware(reveal(config.auth.secret_key)),
    ],
)
```

Because `reveal` is the only unwrap point, `grep -rn "reveal("` over the app audits every place the
raw secret is touched — which is why the revealed value should never be assigned to a config field
or copied into a `Dict`. The masking rules, and what they do and do not cover, are in
[Managing Secrets](secrets.md#Keeping-Secrets-Out-of-Logs-and-REPL-Output).

### Reaching The Config From `req` Alone

Declaring a `ctx::Context{AppConfig}` parameter, as above, is the preferred shape: the
type is written down, so the handler body infers concretely. When you only have the
request — inside middleware, or in a helper called from several handlers — use the
**typed** accessor:

```julia
cfg = getcontext(req, AppConfig)   # ::AppConfig — do this on the request path
cfg.server_host
```

not the untyped one:

```julia
cfg = getcontext(req)              # ::Any — every field access dispatches dynamically
```

Nitro stores the context payload in a `Ref{Any}` because `serve(context = ...)` can
reassign it after routes are registered, so its type is not known when a route is
built. The `::T` in `getcontext(req, T)` is a function barrier that recovers the type
for everything downstream of it. On a hot path that difference is one dynamic
`getfield` per access, per request.

## Recommended Bootstrap Order

1. Load YAML or TOML files in the app layer.
2. Apply environment variable overrides. Use [`current_env()`](environment.md) for the
   environment name itself — Nitro resolves and validates it, so the app does not need
   its own `get(ENV, "APP_ENV", "dev")`.
3. Build `AppConfig`.
4. Initialize external packages such as `PormG` from the app layer.
5. Build routes, middleware, and worker hooks.
6. If you use `Nitro.Workers`, attach `worker_startup(...)` in the `serve(middleware=[...])` list.
7. Start Nitro with `serve(context=config)`.

For example:

```julia
serve(
    host=config.server_host,
    port=config.server_port,
    context=config,
    middleware=[
        worker_startup(
            queues=["agendamento"],
            cleanup_interval_hours=24,
            cleanup_retain_days=7,
        ),
    ],
)
```

For the BI server migration, this config object is the bridge between the old Genie layout
and the new Nitro app bootstrap.