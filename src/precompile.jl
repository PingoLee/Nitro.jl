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

    # ── Route with per-route middleware → the compose / middleware-cache path ───
    # `custommiddleware` being non-empty is what installs `compose` at all (see
    # `setupmiddleware` in src/core.jl), so this is the only block that reaches `genkey`,
    # `buildmiddleware`, `cache!` and `snapshot`. Two requests: the first takes the cache
    # miss + publish path, the second the cache-hit read path. Honest scope: only this
    # generic plumbing carries over — the composed chain itself specializes on the app's
    # own handler/middleware closure types, per the NOTE below.
    precompile_mw = handle -> (req::Request -> handle(req))
    Core.Routing.urlpatterns(ctx, "", RouteDefinition[
        path("/precompile/cached", (req::Request) -> Res.json(Dict("cached" => true)),
             middleware = [precompile_mw])
    ])
    Core.internalrequest(ctx, Request("GET", "/precompile/cached"); catch_errors=false)
    Core.internalrequest(ctx, Request("GET", "/precompile/cached"); catch_errors=false)

    # NOTE: a live-server round-trip (serve! + loopback HTTP.get) is intentionally NOT added
    # here. As of HTTP 2.3.0 / Reseau 1.3.1 it no longer hangs precompilation (the earlier
    # precompile-context Reseau loopback deadlock is fixed), but it gives no benefit: the
    # live request path is specialized on the user's *specific* handler/middleware closure
    # types, which only exist at runtime, so the first real network request recompiles them
    # regardless. A sample precompile route can't stand in for arbitrary user routes — first
    # request stayed ~3.9s with the live workload vs ~3.3s without it. Not worth the added
    # precompile cost.
end
