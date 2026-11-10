# Bench only (#744, step 3): the first request of every route that needs no database, compiled
# into RealApp's package image. A throwaway App carries the same handlers and extractors, and
# `internalrequest` runs the request through the same route chain `serve` builds, minus the
# socket. No database, no ENV, no file under db/: the bearer key is random and never leaves the
# precompile worker. The PormG routes (list, by_id, write, session) stay out, because their
# first request needs a connection.
using HTTP
using PrecompileTools: @setup_workload, @compile_workload

@setup_workload begin
    item = """{"name":"widget","category":"tools","quantity":3}"""
    json = ["Content-Type" => "application/json"]
    @compile_workload begin
        key = SecretString(bytes2hex(Nitro.secure_random_bytes(32)))
        token = Auth.encode_jwt(Dict("sub" => "workload"), key; expires_in = 60)
        bearer = BearerAuth(Auth.jwt_validator(key))
        wapp = App(mod = @__MODULE__)
        urlpatterns(wapp, "", RouteDefinition[
            path("/health", HealthHandlers.health, method = "GET"),
            path("/items/validated", ItemHandlers.validated, method = "POST"),
            path("/search/<str:category>", ItemHandlers.search, method = "GET"),
            path("/me", MiscHandlers.me, method = "GET", middleware = [bearer]),
            path("/bad", MiscHandlers.bad, method = "GET"),
        ])
        # The POSTs are built with `Nitro.precompile_request`, so their body is held as a socket's
        # request holds it (#921). `HTTP.Request(…, ::String)` is a `BytesBody{CodeUnits}`
        # request, and the first served POST compiled the `Json{ItemIn}` binder and the route's
        # leaf again for the served type. The GETs carry no body and are that type already.
        for r in (HTTP.Request("GET", "/health"),
                  Nitro.precompile_request("POST", "/items/validated"; headers = json, body = item),
                  Nitro.precompile_request("POST", "/items/validated"; headers = json,
                                           body = replace(item, "3" => "-1")),
                  HTTP.Request("GET", "/search/tools?limit=5&min_qty=1"),
                  HTTP.Request("GET", "/me", ["Authorization" => "Bearer " * token]),
                  HTTP.Request("GET", "/bad"))
            Nitro.internalrequest(wapp, r)
        end

        # The listener `main` serves (#827): `Nitro.precompile_server` with `main`'s middleware,
        # so HTTP.jl's connection loop for this app's server type is in the package image. The
        # real worker store is built by `pormg_nitro_worker`, which opens a connection; this one
        # has the same type, `PormGWorkerStore`, and a placeholder model, so nothing connects.
        # `wapp` stands in for `app`: the listener's type does not depend on which `App` it is.
        store = Base.get_extension(Nitro, :NitroPormGExt).PormGWorkerStore(;
            model = :workload, db_key = "db")
        workers = worker_startup(wapp; queues = ["reports"], store)
        Nitro.precompile_server(wapp; middleware = (workers, ready)) ||
            error("Nitro.precompile_server: a signature no longer applies (#827)")
    end
end
