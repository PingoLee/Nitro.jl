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
    # `compose` is installed unconditionally (#71), so the blocks above already exercise its
    # empty-table fast path (`snapshot` + `isempty` + the prebuilt chain). THIS block is the
    # only one that gets past that check and reaches `gethandler`, `genkey`, `buildmiddleware`,
    # `cache!` and the cache-hit read. Two requests: the first takes the cache miss + publish
    # path, the second the cache-hit read path. Honest scope: only this generic plumbing
    # carries over — the composed chain itself specializes on the app's own handler/middleware
    # closure types, per the NOTE below.
    precompile_mw = handle -> (req::Request -> handle(req))
    Core.Routing.urlpatterns(ctx, "", RouteDefinition[
        path("/precompile/cached", (req::Request) -> Res.json(Dict("cached" => true)),
             middleware = [precompile_mw])
    ])
    Core.internalrequest(ctx, Request("GET", "/precompile/cached"); catch_errors=false)
    Core.internalrequest(ctx, Request("GET", "/precompile/cached"); catch_errors=false)

    # A third request WITH per-call global middleware: `use_cache` is false, so this is the
    # `compose` branch that skips the cache entirely and rebuilds through `buildmiddleware`
    # on every request. That is the production shape — `serve(middleware=[...])`, and every
    # `revise=:lazy|:eager` session via `ReviseHandler` — and nothing above compiles it.
    # Honest scope: `buildmiddleware` and `snapshot` are already reached by the first
    # request's cache miss; what is new here is `compose`'s `use_cache == false` branch and
    # `normalize_middleware` over a non-empty vector.
    Core.internalrequest(ctx, Request("GET", "/precompile/cached");
                         middleware=[precompile_mw], catch_errors=false)

    # An unmatched request, with the table non-empty so it gets past the fast path: the only
    # branch #71 added that nothing above reaches. Returns a plain 404 `Response`; with
    # `catch_errors=false` nothing is thrown.
    Core.internalrequest(ctx, Request("GET", "/precompile/missing"); catch_errors=false)

    # NOTE: a live-server round-trip (serve! + loopback HTTP.get) is intentionally NOT added
    # here. As of HTTP 2.3.0 / Reseau 1.3.1 it no longer hangs precompilation (the earlier
    # precompile-context Reseau loopback deadlock is fixed), but it gives no benefit: the
    # live request path is specialized on the user's *specific* handler/middleware closure
    # types, which only exist at runtime, so the first real network request recompiles them
    # regardless. A sample precompile route can't stand in for arbitrary user routes — first
    # request stayed ~3.9s with the live workload vs ~3.3s without it. Not worth the added
    # precompile cost.
end
