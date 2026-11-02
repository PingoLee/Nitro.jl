# The smallest Nitro app `juliac` can be pointed at (#570): one exact route, no middleware, no
# access log, no banner. `FILLER_ROUTES`/`ROUTE_MW` grow it for #718's measurements, and
# `LIFECYCLE` adds lifecycle hooks (#719).
#
# Routes are registered at TOP LEVEL on purpose. Under `juliac` this file is `include`d into the
# build process, so registration -- and the reflection `parse_func_params` needs -- runs at build
# time, and the router is a value in the image; `main` only serves. That is the placement #570
# proposes for every compiled app, and this file is the first test of it. Run as a script
# (`julia --project=bench/juliac bench/juliac/app.jl`) the same file is the JIT baseline: `@main`
# runs when the file is the program.
using Nitro

const PLAINTEXT = "Hello, World!"
const app = App()

urlpatterns(app, "", path("/plaintext", req -> Res.send(PLAINTEXT); method = "GET"))
# FILLER_ROUTES / ROUTE_MW (#718): a larger table with mixed middleware stacks, read here at
# build time; both default off, and then the app is the minimal one above. See the file.
include(joinpath(@__DIR__, "..", "route_table.jl"))
bench_routes!(app)

# LIFECYCLE=1 (#719): one route-owned and one serve-owned lifecycle middleware, so the trimmed app
# runs its hooks, each through the pointer its half takes. Read here at build time; off by default,
# and then the app is the minimal one above. Each hook prints one line to `Core.stdout`.
const LIFECYCLE = get(ENV, "LIFECYCLE", "0") == "1"
announce(what::String) = () -> println(Core.stdout, "lifecycle: ", what)
const ROUTE_LIFECYCLE = Nitro.LifecycleMiddleware(middleware = handler -> handler,
    on_startup = announce("route-owned up"), on_shutdown = announce("route-owned down"))
const SERVE_LIFECYCLE = Nitro.LifecycleMiddleware(middleware = handler -> handler,
    on_startup = announce("serve-owned up"), on_shutdown = announce("serve-owned down"))
LIFECYCLE && urlpatterns(app, "", path("/lifecycle", req -> Res.send("lifecycle"); method = "GET",
                                       middleware = [ROUTE_LIFECYCLE]))

# The listener-closure ladder (#744): each knob moves the served shape one step toward what
# bench/juliac/realapp passes to `serve`, so a first request's `--trace-compile` window says which
# serve-level layer HTTP.jl's `_serve_listener!` closure is specialized on. Read at top level, as
# `LIFECYCLE` is: under `juliac` that is build time, so with all three off (the default) the
# branches below are dead and the app is the minimal one above. What they build is built in
# `main`: `WORKERS_MW` installs a worker runtime, which must not happen at build time.
#   ACCESS_LOG=1  `serve`'s default `access_log` and `show_banner` (the shape Nitro's workload warms)
#   SECRET_KEY=1  a `secret_key`, 32 random bytes generated in `main` and never printed
#   WORKERS_MW=1  the Workers middleware over an in-memory store, ahead of the serve-owned
#                 lifecycle layer: the realapp's `[workers, ready]`, passed as a `Tuple`
const ACCESS_LOG = get(ENV, "ACCESS_LOG", "0") == "1"
const SECRET_KEY = get(ENV, "SECRET_KEY", "0") == "1"
const WORKERS_MW = get(ENV, "WORKERS_MW", "0") == "1"

function (@main)(args::Vector{String})::Cint
    port = parse(Int, get(ENV, "PORT", "8080"))
    secret_key = SECRET_KEY ? SecretString(bytes2hex(Nitro.Crypto.secure_random_bytes(32))) : nothing
    middleware = if WORKERS_MW
        (worker_startup(app; queues = ["reports"], store = Nitro.Workers.InMemoryWorkerStore()),
         SERVE_LIFECYCLE)
    elseif LIFECYCLE
        (SERVE_LIFECYCLE,)
    else
        ()
    end
    serve(app; host = "127.0.0.1", port, async = false, show_banner = ACCESS_LOG,
          access_log = ACCESS_LOG, secret_key, middleware)
    return Cint(0)
end
