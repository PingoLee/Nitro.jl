using PrecompileTools

@compile_workload begin
    ctx = App()

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

    # ── GET → Res.html / Res.send (the string-body builders) ────────────
    # `Res.html` and `Res.send` are the markup/text sinks every migrating app reaches
    # for (#28); both land in the same `format_response`/write path as `Res.json`.
    Core.Routing.urlpatterns(ctx, "", RouteDefinition[
        path("/precompile/page", (req::Request) -> Res.html("<h1>ok</h1>")),
        path("/precompile/sheet", (req::Request) -> Res.send("a{}"; content_type="text/css")),
    ])
    Core.internalrequest(ctx, Request("GET", "/precompile/page"); catch_errors=false)
    Core.internalrequest(ctx, Request("GET", "/precompile/sheet"); catch_errors=false)

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
    # only one that gets past that check and reaches `gethandler`, `cachetag`, `genkey`,
    # `buildmiddleware`, `cache_if_current!`, the cache-hit read, and the `RouteResolution`
    # hand-off (#80) — the blocks above compile only `_dispatch_resolved`'s fall-through
    # branch, since nothing stashes a resolution for them. Two requests: the first
    # takes the cache miss + publish path, the second the cache-hit read path. Honest scope: only this generic plumbing
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

    # ── A static mount, end to end ──────────────────────────────────────────────
    #
    # Nothing above touches the file-serving stack at all (#41): not `mountable_files`, not
    # `mountfolder`, not `_route_encode`, not `mount_remainder`, not `servecontent`, and not the
    # router's `doublestar` branch — a mount is the only thing in Nitro that registers a `**`
    # route. A server whose main job is serving an SPA therefore paid full JIT latency on the very
    # first asset request, which is the *first page load*, after a package that was precompiled.
    #
    # This is cheap to warm because it goes through `internalrequest`, exactly like every block
    # above: no socket, no live-server round trip (see the NOTE at the end for why that stays out).
    #
    # The temp directory is created and removed INSIDE the workload. `@compile_workload` bodies run
    # in the precompile worker, which is the sanctioned place for this — a top-level `mktempdir`
    # would be a module-body side effect that never runs again when the cache is loaded.
    mktempdir() do dir
        write(joinpath(dir, "index.html"), "<!doctype html><title>precompile</title>")
        write(joinpath(dir, "app.js"), "console.log(1)")
        # A name that needs percent-encoding, so `_route_encode` and the decode side of
        # `mount_remainder` are both compiled rather than only the ASCII-clean fast paths.
        write(joinpath(dir, "café.txt"), "accented")

        staticfiles(ctx, dir, "precompile-static")
        # A hit, the bare mount route, an encoded name, and a miss — the four branches the mount
        # handler has.
        Core.internalrequest(ctx, Request("GET", "/precompile-static/app.js"); catch_errors=false)
        Core.internalrequest(ctx, Request("GET", "/precompile-static"); catch_errors=false)
        Core.internalrequest(ctx, Request("GET", "/precompile-static/caf%C3%A9.txt"); catch_errors=false)
        Core.internalrequest(ctx, Request("GET", "/precompile-static/none.txt"); catch_errors=false)
        # The conditional-GET short circuit (#40): a different `servecontent` exit than the 200s
        # above, and the one a warm client actually takes.
        Core.internalrequest(ctx, Request("GET", "/precompile-static/app.js",
                                          ["If-None-Match" => "W/\"x\""]); catch_errors=false)

        # `spafiles` shares the handler but takes the fallback branch, which is an SPA server's
        # hot path.
        spafiles(ctx, dir, "precompile-spa")
        Core.internalrequest(ctx, Request("GET", "/precompile-spa/deep/link"); catch_errors=false)
    end

    # NOTE: a live-server round-trip (serve! + loopback HTTP.get) is intentionally NOT added
    # here. As of HTTP 2.3.0 / Reseau 1.3.1 it no longer hangs precompilation (the earlier
    # precompile-context Reseau loopback deadlock is fixed), but it gives no benefit: the
    # live request path is specialized on the user's *specific* handler/middleware closure
    # types, which only exist at runtime, so the first real network request recompiles them
    # regardless. A sample precompile route can't stand in for arbitrary user routes — first
    # request stayed ~3.9s with the live workload vs ~3.3s without it. Not worth the added
    # precompile cost.
end
