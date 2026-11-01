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
        for r in (HTTP.Request("GET", "/health"),
                  HTTP.Request("POST", "/items/validated", json, item),
                  HTTP.Request("POST", "/items/validated", json, replace(item, "3" => "-1")),
                  HTTP.Request("GET", "/search/tools?limit=5&min_qty=1"),
                  HTTP.Request("GET", "/me", ["Authorization" => "Bearer " * token]),
                  HTTP.Request("GET", "/bad"))
            Nitro.internalrequest(wapp, r)
        end
    end
end
