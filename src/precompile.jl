using PrecompileTools

"""
    PrecompileRecord

The record shape the precompile workload binds and serializes. Internal and unexported —
it exists so the workload can exercise `Res.json` over a struct and the typed extractors
(`Query{T}`, `Path{T}`, `Json{T}`, `Form{T}`) over a *concrete* `T`, which is the only way
`struct_builder` and JSON's writer get specialized ahead of time.

It is a type definition, not a runtime side effect, so it is safe at module level: nothing
here runs when the cache is loaded.
"""
Base.@kwdef struct PrecompileRecord
    id::Int = 0
    name::String = ""
end

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
    # The auto-HEAD every GET route gets (#277): an `AutoHeadHandler` leaf, keyed on `GET` here.
    Core.internalrequest(ctx, Request("HEAD", "/precompile/cached"); catch_errors=false)

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

    # ── The JSON return shapes handlers actually build (#242) ──────────────────────────
    #
    # Every `Res.json` above builds a CONCRETELY-typed dict: `Dict("pong" => true)` is a
    # `Dict{String,Bool}` and `Dict("id" => id)` a `Dict{String,Int}`. No application returns
    # those. A handler returns a mixed-value record — `Dict{String,Any}` — a vector of them, a
    # struct, or a NamedTuple, and JSON's writer specializes per container type, so none of
    # those were warmed by anything above. Measured on #242 — Julia 1.12, one shape per FRESH
    # process, which is the only honest way to read a time-to-first-request number — a first
    # request returning `Dict{String,Any}` cost 1.50s against 0.09s for the `Dict{String,Int}`
    # already covered. That 16x is the whole cost of the one miss, and closing it is the
    # cheapest win in the file: it now costs 0.18s.
    Core.Routing.urlpatterns(ctx, "", RouteDefinition[
        path("/precompile/record/<int:id>", (req::Request, id::Int) ->
             Res.json(Dict{String,Any}("id" => id, "name" => "precompile", "ok" => true))),
        path("/precompile/records", (req::Request) ->
             Res.json([Dict{String,Any}("id" => i, "name" => "precompile") for i in 1:2])),
        path("/precompile/struct", (req::Request) -> Res.json(PrecompileRecord(1, "precompile"))),
        path("/precompile/namedtuple", (req::Request) -> Res.json((id = 1, name = "precompile"))),
    ])
    Core.internalrequest(ctx, Request("GET", "/precompile/record/1"); catch_errors=false)
    Core.internalrequest(ctx, Request("GET", "/precompile/records"); catch_errors=false)
    Core.internalrequest(ctx, Request("GET", "/precompile/struct"); catch_errors=false)
    Core.internalrequest(ctx, Request("GET", "/precompile/namedtuple"); catch_errors=false)

    # ── The typed extractors, which had NO coverage at all (#242) ──────────────────────
    #
    # `Json{T}`, `Query{T}`, `Path{T}` and `Form{T}` are the Spring Boot lineage and a headline
    # feature, and nothing above reached `extract`, `struct_builder`, or `validate`. On the same
    # fresh-process-per-shape basis as the block above, each kind cost 1.5–1.8s on first use and
    # now costs 0.37–0.49s. They are warmed here over one concrete `T`, which is what
    # specializes the generic binding machinery — `struct_builder`'s reflection, the
    # per-extractor `extract` methods, and the `Res.json`-of-a-struct return. An application's
    # own `T` still pays its own `struct_builder` specialization; the shared plumbing no longer
    # does, which is the same honest split the middleware-cache block above documents.
    Core.Routing.urlpatterns(ctx, "", RouteDefinition[
        path("/precompile/extract/query", (req::Request, q::Query{PrecompileRecord}) ->
             Res.json(q.payload)),
        path("/precompile/extract/path/<int:id>/<str:name>",
             (req::Request, p::Path{PrecompileRecord}) -> Res.json(p.payload)),
        path("/precompile/extract/json", (req::Request, j::Json{PrecompileRecord}) ->
             Res.json(j.payload), method="POST"),
        path("/precompile/extract/form", (req::Request, f::Form{PrecompileRecord}) ->
             Res.json(f.payload), method="POST"),
    ])
    Core.internalrequest(ctx, Request("GET", "/precompile/extract/query?id=1&name=p");
                         catch_errors=false)
    Core.internalrequest(ctx, Request("GET", "/precompile/extract/path/1/p"); catch_errors=false)
    Core.internalrequest(
        ctx,
        Request("POST", "/precompile/extract/json", ["Content-Type" => "application/json"],
                "{\"id\":1,\"name\":\"p\"}");
        catch_errors=false,
    )
    Core.internalrequest(
        ctx,
        Request("POST", "/precompile/extract/form",
                ["Content-Type" => "application/x-www-form-urlencoded"], "id=1&name=p");
        catch_errors=false,
    )

    # ── The error path, at the setting production actually runs (#242) ──────────────────
    #
    # Every block above passes `catch_errors=false`, but `catch_errors=true` is the default for
    # BOTH `internalrequest` and `serve()` — so `DefaultSerializer`'s catch branch, and the
    # 400-building code a failed bind reaches, were never executed and therefore never compiled.
    # A malformed body is the cheapest way in: `Json{PrecompileRecord}` cannot bind `"nope"` to
    # an `Int`, so the bind throws and the request lands on that branch as a 400.
    #
    # `name` is supplied even though only `id` is malformed. It has a `@kwdef` default, but
    # `JSON.parse(str, T)` does not honour those, so omitting it would 400 on the ABSENT field
    # instead and the sentence above would be describing the wrong failure.
    #
    # The kwarg is omitted rather than written out because `catch_errors=true` is the default;
    # spelling it would compile the identical branch, so this is about matching how `serve()`
    # is really called, not about reaching different code.
    Core.internalrequest(
        ctx,
        Request("POST", "/precompile/extract/json", ["Content-Type" => "application/json"],
                "{\"id\":\"nope\",\"name\":\"p\"}"),
    )

    # ── A middleware exception, caught by the pipeline's error boundary (#256) ────────────
    #
    # The block above reaches the SERIALIZER's catch. A throw out of middleware lands one layer
    # further out, in `ErrorBoundary`, whose catch branch calls `handlerequest(rethrow, …)` -- its
    # own method instance, reached by nothing else. Without this the first middleware failure in a
    # fresh process pays inference + codegen for it, on the request that is already failing.
    #
    # Built with `setupmiddleware` rather than `internalrequest` for `show_errors=false`:
    # `internalrequest` has no such kwarg, and the `@error` + backtrace it would otherwise print
    # would land in every precompile log. The branch compiled is identical either way.
    let boom = handler -> (req::Request -> error("precompile: middleware error boundary"))
        Core.setupmiddleware(ctx; middleware = [boom], show_errors = false)(
            Request("GET", "/precompile/ping"))
    end

    # ── The request-body parsers (#242) ────────────────────────────────────────────────
    #
    # `formdata` and `multipart` in `src/utilities/bodyparsers.jl`: an HTML form POST and a file
    # upload are the two shapes every app hits, and neither was reached above — the JSON POST
    # block goes through a different parser entirely. The multipart body is built inline rather
    # than read from disk — unlike the static-mount block above, which needs a real `mktempdir`,
    # nothing here requires one.
    Core.Routing.urlpatterns(ctx, "", RouteDefinition[
        path("/precompile/parse/form", (req::Request) ->
             Res.json(Dict{String,Any}("n" => length(formdata(req)))), method="POST"),
        path("/precompile/parse/multipart", (req::Request) ->
             Res.json(Dict{String,Any}("n" => length(multipart(req)))), method="POST"),
    ])
    Core.internalrequest(
        ctx,
        Request("POST", "/precompile/parse/form",
                ["Content-Type" => "application/x-www-form-urlencoded"], "a=1&b=2");
        catch_errors=false,
    )
    let boundary = "precompileboundary"
        body = string(
            "--", boundary, "\r\n",
            "Content-Disposition: form-data; name=\"field\"\r\n\r\nvalue\r\n",
            "--", boundary, "\r\n",
            "Content-Disposition: form-data; name=\"file\"; filename=\"p.txt\"\r\n",
            "Content-Type: text/plain\r\n\r\ncontents\r\n",
            "--", boundary, "--\r\n")
        Core.internalrequest(
            ctx,
            Request("POST", "/precompile/parse/multipart",
                    ["Content-Type" => "multipart/form-data; boundary=$boundary"], body);
            catch_errors=false,
        )
    end

    # NOTE: a live-server round-trip (serve! + loopback HTTP.get) is intentionally NOT added
    # here — but NOT for the reason this comment gave until #242, which measurement did not
    # support. It claimed the live request path "is specialized on the user's specific
    # handler/middleware closure types ... so the first real network request recompiles them
    # regardless". Two structurally identical routes with different anonymous closures say
    # otherwise: the first costs ~0.43s on its first request and the second ~0.014s. The
    # per-closure component is 14ms; the rest is generic machinery that warms once and carries
    # to every later route — exactly what a workload can cache, and what the blocks above now do.
    #
    # What survives is narrower and still decisive: everything here runs through
    # `internalrequest`, which is the same middleware chain and the same `Res`/serializer path a
    # live request takes, minus the socket. A loopback round-trip would add only
    # `NitroStreamHandler` and the transport read/write in `src/core/transport.jl` — and it would
    # add them at the cost of binding a real port inside the precompile worker, which is the one
    # thing in this file that could hang a build rather than merely slow it. The earlier
    # Reseau loopback deadlock (fixed in HTTP 2.3.0 / Reseau 1.3.1) is why that is not a
    # hypothetical. Warming the transport layer is worth doing; doing it with a socket is not.
    # If someone finds a socket-free way to drive `NitroStreamHandler`, that is the gap to close.
end
