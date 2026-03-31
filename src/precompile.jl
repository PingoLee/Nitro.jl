using PrecompileTools

@compile_workload begin
    ctx = ServerContext()

    # ── GET → Res.json (no path params) ─────────────────────────────────
    Core.Routing.urlpatterns(ctx, "", RouteDefinition[
        path("/precompile/ping", (req::Request) -> Res.json(Dict("pong" => true)))
    ])
    Core.internalrequest(ctx, Request("GET", "/precompile/ping"); catch_errors=false)

    # ── GET with Int path param → Res.json ──────────────────────────────
    Core.Routing.urlpatterns(ctx, "", RouteDefinition[
        path("/precompile/items/<int:id>", (req::Request, id::Int) -> Res.json(Dict("id" => id)))
    ])
    Core.internalrequest(ctx, Request("GET", "/precompile/items/42"); catch_errors=false)

    # ── POST with JSON body → Res.status(201) ───────────────────────────
    Core.Routing.urlpatterns(ctx, "", RouteDefinition[
        path("/precompile/items", (req::Request) -> Res.status(201), method="POST")
    ])
    Core.internalrequest(
        ctx,
        Request("POST", "/precompile/items", ["Content-Type" => "application/json"], "{\"name\":\"test\"}");
        catch_errors=false,
    )
end
