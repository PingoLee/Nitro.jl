module RealApp

# Postgres.jl in place of the LibPQ the scaffold adds: the driver is picked at run time with
# PORMG_POSTGRES_DRIVER=Postgres (#744).
using Nitro, PormG, Postgres

const app = App(mod = @__MODULE__)

# The app's directory, set by `main` (#744). Not the scaffold's `pkgdir(@__MODULE__)` alone: in a
# JuliaC executable `pkgdir` and `@__DIR__` name the temporary copy of the project JuliaC built
# from, which is gone at run time. REALAPP_ROOT names the real one; `pkgdir` is the fallback.
const ROOT = Ref{String}("")

# Included, not `@import_models`ed, as the scaffold says: PormG registers models only against a
# loaded folder (PormG #1226), and loading here would read db/connection.yml into the image.
# `main` binds them.
include("../db/models.jl")
const appM = models

include("Handlers/HealthHandlers.jl")
include("Handlers/ItemHandlers.jl")
include("Handlers/MiscHandlers.jl")
include("Routes.jl")
include("precompile.jl")

# Bench only (#744): the listener opens before the `startup` hooks run, so the socket is not
# readiness. This hook is registered after `worker_startup`'s, and hooks run in registration
# order, so `READY` on fd 2 means every start-up hook before it has returned. Straight to fd 2:
# a trimmed executable's `Base.stdout` is stale, and a buffered stream would print late.
_mark_ready() = (m = "READY\n"; ccall(:write, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), 2, m, sizeof(m)); nothing)
const ready = Nitro.LifecycleMiddleware(middleware = identity, on_startup = _mark_ready)

"""
    main(; kwargs...)

Boot the app and serve it. Reads `PORT` (default 8000), `API_SECRET_KEY` and `JWT_SECRET` (each
at least 32 bytes); keyword arguments go to `serve` (tests pass `async = true`).

`middleware_form` (bench only, #744) picks how `serve` gets the middleware: `Val(:vector)`, the
default, passes `[workers, ready]` as the scaffold does; `Val(:tuple)` passes `(workers, ready)`.
A `Vector` is converted to a `Tuple` at run time, so the listener's type does not infer from
`main`; the `Tuple` does. It is a type, not a `Bool`, so the branch folds and both forms compile
the same code otherwise (`main.jl` against `main_tuple.jl`). `Val(:ready_only)` still builds
`workers` but serves `(ready,)` alone (`main_ready_only.jl`): `worker_startup`'s return type does
not infer (its `on_startup` captures a `WorkerRuntime{S}` with `S` open), so with it in either form
the `serve` call is a dynamic one from `main`, and without it the call is static. The worker hook
then never runs, so nothing is submitted to a queue in that form; no route submits one anyway.
"""
function main(; middleware_form::Val = Val(:vector), kwargs...)
    # PormG reads db/connection.yml, from any working directory, in the environment
    # `PORMG_ENV` names, else `NITRO_ENV` (or `GENIE_ENV`), else "dev"
    ROOT[] = get(ENV, "REALAPP_ROOT", pkgdir(@__MODULE__))
    env = something(sync_pormg_env!(), current_env())
    PormG.Configuration.load_many(["db"]; root = ROOT[], env)
    PormG.Models.set_models(models, joinpath(ROOT[], "db"))
    workers = worker_startup(app; queues = ["reports"], store = pormg_nitro_worker(db_key = "db"))
    session = SessionMiddleware(store = pormg_nitro_session(db_key = "db"), secure = false)
    bearer = BearerAuth(Auth.jwt_validator(SecretString(ENV["JWT_SECRET"])))
    urlpatterns(app, "", Routes.urlpatterns(; session, bearer))
    middleware = middleware_form isa Val{:tuple} ? (workers, ready) :
                 middleware_form isa Val{:ready_only} ? (ready,) : [workers, ready]
    serve(app; port = parse(Int, get(ENV, "PORT", "8000")), middleware,
          secret_key = SecretString(ENV["API_SECRET_KEY"]), kwargs...)
end

end # module
