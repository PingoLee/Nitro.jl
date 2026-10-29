module RealApp

using Nitro, PormG, LibPQ

const app = App(mod = @__MODULE__)

# Once db/models.jl defines models, import them here for the handlers (`import ..appM`):
#   PormG.@import_models "../db/models.jl" models
#   const appM = models

include("Handlers/HealthHandlers.jl")
include("Routes.jl")

"""
    main(; kwargs...)

Boot the app and serve it. Reads `PORT` (default 8000) and `API_SECRET_KEY` (at least
32 bytes); keyword arguments go to `serve` (tests pass `async = true`).
"""
function main(; kwargs...)
    sync_pormg_env!()  # NITRO_ENV -> PORMG_ENV, only when NITRO_ENV is set
    # PormG parses db/connection.yml, validates it and connects, from any working directory
    PormG.Configuration.load_many(["db"]; root = pkgdir(@__MODULE__))
    workers = worker_startup(app; queues = ["reports"], store = pormg_nitro_worker(db_key = "db"))
    urlpatterns(app, "", Routes.urlpatterns())
    serve(app; port = parse(Int, get(ENV, "PORT", "8000")), middleware = [workers],
          secret_key = SecretString(ENV["API_SECRET_KEY"]), kwargs...)
end

end # module
