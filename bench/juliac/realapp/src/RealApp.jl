module RealApp

# Postgres.jl in place of the LibPQ the scaffold adds: the driver is picked at run time with
# PORMG_POSTGRES_DRIVER=Postgres (#744).
using Nitro, PormG, Postgres

const app = App(mod = @__MODULE__)

PormG.@import_models "../db/models.jl" models
const appM = models

include("Handlers/HealthHandlers.jl")
include("Handlers/ItemHandlers.jl")
include("Handlers/MiscHandlers.jl")
include("Routes.jl")

"""
    main(; kwargs...)

Boot the app and serve it. Reads `PORT` (default 8000), `API_SECRET_KEY` and `JWT_SECRET` (each
at least 32 bytes); keyword arguments go to `serve` (tests pass `async = true`).
"""
function main(; kwargs...)
    sync_pormg_env!()  # NITRO_ENV -> PORMG_ENV, only when NITRO_ENV is set
    # PormG parses db/connection.yml, validates it and connects, from any working directory
    PormG.Configuration.load_many(["db"]; root = pkgdir(@__MODULE__))
    workers = worker_startup(app; queues = ["reports"], store = pormg_nitro_worker(db_key = "db"))
    session = SessionMiddleware(store = pormg_nitro_session(db_key = "db"), secure = false)
    bearer = BearerAuth(Auth.jwt_validator(SecretString(ENV["JWT_SECRET"])))
    urlpatterns(app, "", Routes.urlpatterns(; session, bearer))
    serve(app; port = parse(Int, get(ENV, "PORT", "8000")), middleware = [workers],
          secret_key = SecretString(ENV["API_SECRET_KEY"]), kwargs...)
end

end # module
