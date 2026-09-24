@testitem "Custom middleware table — registration publishes last-writer-wins" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core.Types: snapshot, RouteMiddleware
import Nitro: App, path, text

# Regression test for #68 item 1. `ctx.service.custommiddleware` maps a route key to that
# route's `(router middleware, route middleware)` pair. It used to be a plain `Dict` written
# with a bare `setindex!` — no lock on either side — while `buildmiddleware`
# (src/routerhof.jl) read it lock-free on the request path.
#
# It is now a `CopyOnWriteDict{RouteMiddleware}` written via `publish!` (the value type was
# narrowed from an abstract `Tuple` in #76). Its semantic is LAST-writer-wins: re-running
# `urlpatterns` for a path must install the NEW middleware. (The first-writer-wins
# `middleware_cache` that used to sit beside it became the per-pipeline `ChainCache` in #255.)
#
# Local `App` throughout — no global `CONTEXT[]`, so these items are
# order-independent within runtests.jl.

# `tag` MUST be captured. A factory returning `handler -> (req -> handler(req))` builds a
# closure with zero fields, so every call returns the same singleton instance and
# `mkmw("A") === mkmw("B")` is `true` — which silently turns every identity assertion below
# into a tautology. (That mistake shipped in an earlier draft of this file and hid a total
# absence of coverage on the HOF write site.) Referencing `tag` in the body gives each
# factory a distinct closure type and instance.
mkmw(tag) = handler -> (req::HTTP.Request -> Res.send(tag * "|" * text(handler(req))))

@testset "re-registering a path overwrites, and a held snapshot does not" begin
    mwA, mwB = mkmw("A"), mkmw("B")
    @test mwA !== mwB          # guards the tautology above; the rest is meaningless without it

    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/lww", (req::HTTP.Request) -> Res.send("h"), middleware = [mwA])
    ])
    held = snapshot(ctx.service.custommiddleware)
    @test held["GET|/lww"][2][1] === mwA

    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/lww", (req::HTTP.Request) -> Res.send("h"), middleware = [mwB])
    ])

    @test snapshot(ctx.service.custommiddleware)["GET|/lww"][2][1] === mwB   # LWW took effect
    @test held["GET|/lww"][2][1] === mwA        # the held snapshot was not mutated
    @test held !== snapshot(ctx.service.custommiddleware)

    # Behavioral confirmation, immune to closure-identity subtleties: the request must run
    # through B's middleware, not A's.
    body = text(Nitro.Core.internalrequest(ctx, HTTP.Request("GET", "/lww");
                                           middleware = [h -> (r::HTTP.Request -> h(r))],
                                           catch_errors = false))
    @test body == "B|h"
end

@testset "the HOF router path publishes too" begin
    mwA, mwB = mkmw("A"), mkmw("B")
    ctx = App()
    Nitro.Core.router(ctx, "/hof"; middleware = [mwA])("/x")("GET")
    @test snapshot(ctx.service.custommiddleware)["GET|/hof/x"][1][1] === mwA

    # The only coverage the HOF write site has anywhere in the suite. With a first-writer-wins
    # publish here the table would keep `mwA` forever and this assertion is what catches it.
    Nitro.Core.router(ctx, "/hof"; middleware = [mwB])("/x")("GET")
    @test snapshot(ctx.service.custommiddleware)["GET|/hof/x"][1][1] === mwB
end

@testset "an unsynchronized publish is unwritable" begin
    ctx = App()
    @test_throws ConcurrencyViolationError ctx.service.custommiddleware.entries = Dict{String, RouteMiddleware}()
end
end


@testitem "Custom middleware table — pipelines with global middleware" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
import Nitro: App, path, text

# The configuration the #68 bug lived in, so it gets its own item: global middleware plus
# per-route middleware — any `serve(middleware=[...])` (CORS, sessions, auth, rate limiting, the
# normal production shape) with route guards, and every `revise=:lazy|:eager` session, since
# `serve` injects `ReviseHandler`.
#
# Until #255 this shape cached nothing (`use_cache = isempty(globalmiddleware)`), so
# `buildmiddleware` and its read of `custommiddleware` ran on EVERY request, forever. Each
# pipeline now owns a `ChainCache`, so it builds once per route like every other shape.

const K = 8
mktag(tag) = handler -> (req::HTTP.Request -> Res.send(tag * "|" * text(handler(req))))

factory_calls = Ref(0)
counting_mw = handler -> (factory_calls[] += 1; req::HTTP.Request -> handler(req))
global_mw   = handler -> (req::HTTP.Request -> handler(req))

ctx = App()
Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
    path("/u/$i", (req::HTTP.Request) -> Res.send("h$i"), middleware = [mktag("r$i")])
    for i in 1:K
])

# Sequential on purpose — the point of this item is key→chain mapping and build counts, not
# concurrency (that is the third item). Both the per-call-pipeline (`internalrequest`) and the
# built-once (`serve`) shapes.
results = [text(Nitro.Core.internalrequest(ctx, HTTP.Request("GET", "/u/$i");
                                           middleware = [global_mw], catch_errors = false))
           for _ in 1:3 for i in 1:K]
served = Nitro.Core.setupmiddleware(ctx; middleware = [global_mw], catch_errors = false)
served_results = [text(served(HTTP.Request("GET", "/u/$i"))) for _ in 1:3 for i in 1:K]

@testset "every request got its own route's chain" begin
    expected = [ "r$i|h$i" for _ in 1:3 for i in 1:K ]
    @test results == expected
    @test served_results == expected
end

@testset "buildmiddleware runs once per route per pipeline, not once per request" begin
    ctx2 = App()
    Nitro.Core.Routing.urlpatterns(ctx2, "", Nitro.RouteDefinition[
        path("/counted", (req::HTTP.Request) -> Res.send("ok"), middleware = [counting_mw])
    ])
    # `serve`-shaped: one pipeline, five requests, one build. This assertion used to read
    # `== 5` — "uncached, forever" — and was flipped deliberately by #255, which is the change
    # it existed to make someone confront.
    factory_calls[] = 0
    pipeline = Nitro.Core.setupmiddleware(ctx2; middleware = [global_mw], catch_errors = false)
    for _ in 1:5
        pipeline(HTTP.Request("GET", "/counted"))
    end
    @test factory_calls[] == 1

    # `internalrequest` builds a new pipeline — and so a cold cache — per call. That is the
    # stated trade-off of a pipeline-owned cache: the ~12 µs pipeline rebuild dwarfs one fold.
    factory_calls[] = 0
    for _ in 1:5
        Nitro.Core.internalrequest(ctx2, HTTP.Request("GET", "/counted");
                                   middleware = [global_mw], catch_errors = false)
    end
    @test factory_calls[] == 5
end

@testset "a composed pipeline sees routes registered after it was composed" begin
    # Mutation guard, mirroring the one in test/middleware_cache_tests.jl. `compose` must
    # snapshot `custommiddleware` PER REQUEST. If a refactor hoists that snapshot to compose
    # time the table freezes for the life of the server and routes registered later — Revise
    # re-running `urlpatterns` — silently lose their middleware, with no error and no other
    # failing test.
    ctx3 = App()
    Nitro.Core.Routing.urlpatterns(ctx3, "", Nitro.RouteDefinition[
        path("/first", (req::HTTP.Request) -> Res.send("h1"), middleware = [mktag("r1")])
    ])
    # Route 1 exists BEFORE this call deliberately, and the reason changed with #71: the table
    # being non-empty is no longer what installs `compose` (it is always installed now), but it
    # is what gets requests PAST the per-request emptiness fast path and into `buildmiddleware`,
    # which is where the snapshot this item guards is actually read. The companion item
    # "composed against an EMPTY table" covers the other side.
    pipeline = Nitro.Core.setupmiddleware(ctx3; middleware = [global_mw], catch_errors = false)

    Nitro.Core.Routing.urlpatterns(ctx3, "", Nitro.RouteDefinition[
        path("/second", (req::HTTP.Request) -> Res.send("h2"), middleware = [mktag("r2")])
    ])

    @test text(pipeline(HTTP.Request("GET", "/second"))) == "r2|h2"
    @test text(pipeline(HTTP.Request("GET", "/first")))  == "r1|h1"
end
end


@testitem "Custom middleware table — lock-free readers under a concurrent publisher" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using Nitro.Core.Types: CopyOnWriteDict, snapshot, publish!, RouteMiddleware

# The #68 race itself, at the container level.
#
# What this proves: the table is safe with lock-free readers concurrent with a publisher.
# What it does NOT prove: that the framework path is race-free end to end. Driving a real
# `Revise.revise()` that re-evaluates `urlpatterns` concurrently with in-flight requests is
# not reproducible in a test item, and this does not attempt it.
#
# Measured against a faithful pre-fix reconstruction (plain `Dict`, bare `setindex!`, readers
# handed the live table), 200 trials per configuration at `-t 2`:
#     1 round   -> detected ~121-129/200 across runs (~62%), false positives 0/200
#     10 rounds -> detected 200/200,                         false positives 0/200
# (also 0/200 false positives at `-t 16`)
# Hence 10 rounds. Detection is far sharper than the #35 cache test because check (2) below
# is specific to last-writer-wins: a live table lets a held reference's value change under
# the reader, which a frozen snapshot cannot.
#
# `Threads.@spawn`, not `@async`: `@async` tasks are sticky to the spawning thread and can
# never overlap a writer. Gated on thread count so the non-yielding reader spin loop cannot
# starve the writer at `-t 1`; CI runs 1 and 2, so both branches execute in CI.

mkf(tag) = (req -> tag)
val(tag) = (nothing, Function[mkf(tag)])

if Threads.nthreads() > 1
    bad = Threads.Atomic{Int}(0)
    for _ in 1:10
        d = CopyOnWriteDict{RouteMiddleware}()
        for i in 1:8
            publish!(d, "GET|/seed$i", val("seed$i"))
        end
        publish!(d, "GET|/hot", val("hot0"))

        stop = Threads.Atomic{Bool}(false)
        readers = [Threads.@spawn begin
            try
                while !stop[]
                    t = snapshot(d)
                    # (1) keys the writer never touches must always resolve to their own
                    #     value — the missing/wrong/torn-lookup detector.
                    for i in 1:8
                        v = get(t, "GET|/seed$i", nothing)
                        if v === nothing || v[2][1](nothing) != "seed$i"
                            Threads.atomic_add!(bad, 1)
                        end
                    end
                    # (2) LWW-specific: a HELD snapshot's value for a hot key must not
                    #     change between two reads of that same snapshot.
                    h1 = get(t, "GET|/hot", nothing)
                    h2 = get(t, "GET|/hot", nothing)
                    if h1 === nothing || h1 !== h2
                        Threads.atomic_add!(bad, 1)
                    end
                end
            catch                       # a torn read throws out of the reader task
                Threads.atomic_add!(bad, 1)
            end
        end for _ in 1:max(1, Threads.nthreads() - 1)]

        writer = Threads.@spawn begin
            # `finally`: if `publish!` ever throws, `stop` must still be set or the reader
            # spin loops never exit and the item hangs to its timeout.
            try
                for i in 1:200
                    publish!(d, "GET|/w$i", val("w$i"))
                    publish!(d, "GET|/hot", val("hot$i"))
                end
            finally
                stop[] = true
            end
        end

        wait(writer)
        foreach(wait, readers)
        @test length(snapshot(d)) == 209        # 8 seeds + hot + 200 writes
    end
    @test bad[] == 0
else
    # `-t 1`: no parallelism to be had. Assert the same invariants sequentially so the item
    # is never vacuously green (cf. test/parallel_tests.jl's both-branches shape).
    d = CopyOnWriteDict{RouteMiddleware}()
    for i in 1:8
        publish!(d, "GET|/seed$i", val("seed$i"))
    end
    publish!(d, "GET|/hot", val("hot0"))
    held = snapshot(d)
    hot_before = held["GET|/hot"]
    for i in 1:200
        publish!(d, "GET|/w$i", val("w$i"))
        publish!(d, "GET|/hot", val("hot$i"))
    end
    @test length(held) == 9                                   # the held snapshot never grew
    @test held["GET|/hot"] === hot_before                     # nor changed a value
    @test all(held["GET|/seed$i"][2][1](nothing) == "seed$i" for i in 1:8)
    @test length(snapshot(d)) == 209
end
end


@testitem "Custom middleware — a pipeline composed against an EMPTY table (#71)" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core.Types: snapshot
import Nitro: App, path, text

# Regression test for #71. `setupmiddleware` used to decide ONCE whether to install
# `compose`, gated on `custommiddleware` being non-empty — and `serve` calls it once. So an
# app whose first per-route middleware was registered AFTER the server started (Revise
# re-running `urlpatterns`, a runtime `include_routes`) never got `compose` at all, and that
# middleware silently never ran. No error, no warning.
#
# `compose` is now installed unconditionally and the emptiness check moved inside it, per
# request, in front of the route lookup (and, since #291, inside the global middleware).
#
# ANTI-HOIST DUTY. Hoisting the emptiness check out of the per-request closure would freeze the
# verdict at compose time and reinstate #71 exactly. Verified by mutation: under that change
# this item fails while the guard in the item above — which composes against a NON-empty table —
# stays green, along with the rest of this file. Do not merge the two items.

mktag(tag) = handler -> (req::HTTP.Request -> Res.send(tag * "|" * text(handler(req))))
plain_global = handler -> (req::HTTP.Request -> handler(req))

@testset "middleware registered after composition runs" begin
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/plain", (req::HTTP.Request) -> Res.send("plain"))
    ])
    # Composed while the table is EMPTY — the exact situation #71 is about.
    @test isempty(snapshot(ctx.service.custommiddleware))
    pipeline = Nitro.Core.setupmiddleware(ctx; catch_errors = false)

    @test text(pipeline(HTTP.Request("GET", "/plain"))) == "plain"

    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/late", (req::HTTP.Request) -> Res.send("h"), middleware = [mktag("late")])
    ])

    # On unpatched main this returns "h" — the middleware never runs.
    @test text(pipeline(HTTP.Request("GET", "/late"))) == "late|h"
    @test text(pipeline(HTTP.Request("GET", "/plain"))) == "plain"
end

@testset "same with global middleware" begin
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/plain", (req::HTTP.Request) -> Res.send("plain"))
    ])
    pipeline = Nitro.Core.setupmiddleware(ctx; middleware = [plain_global], catch_errors = false)
    @test text(pipeline(HTTP.Request("GET", "/plain"))) == "plain"

    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/late", (req::HTTP.Request) -> Res.send("h"), middleware = [mktag("late")])
    ])
    @test text(pipeline(HTTP.Request("GET", "/late"))) == "late|h"
end

@testset "an explicit middleware=[] does not publish an entry" begin
    # `middleware=[]` contributes zero layers, but publishing an entry for it would make
    # `custommiddleware` permanently non-empty and kill the fast path above for EVERY request in
    # the application. Both registrars must gate on non-empty, not merely non-`nothing` — an
    # explicit `[]` normalizes to `Function[]`, which is not `nothing`.
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/a", (req::HTTP.Request) -> Res.send("a"), middleware = [])
    ])
    @test isempty(snapshot(ctx.service.custommiddleware))

    hof = App()
    Nitro.Core.router(hof, "/hof"; middleware = [])("/x")("GET")
    @test isempty(snapshot(hof.service.custommiddleware))

    inner = App()
    Nitro.Core.router(inner, "/hof")("/x"; middleware = [])("GET")
    @test isempty(snapshot(inner.service.custommiddleware))

    # ...and real middleware still publishes, through both registrars.
    real_mw = handler -> (req::HTTP.Request -> handler(req))
    r1 = App()
    Nitro.Core.Routing.urlpatterns(r1, "", Nitro.RouteDefinition[
        path("/a", (req::HTTP.Request) -> Res.send("a"), middleware = [real_mw])
    ])
    @test !isempty(snapshot(r1.service.custommiddleware))

    r2 = App()
    Nitro.Core.router(r2, "/hof"; middleware = [real_mw])("/x")("GET")
    @test !isempty(snapshot(r2.service.custommiddleware))
end

@testset "nothing is resolved while the table is empty" begin
    # The fast path returns before `gethandler`, so no route is looked up and no chain composed.
    #
    # This used to count folds of a GLOBAL factory, which `buildmiddleware` re-folded into every
    # route's chain. Since #291 global middleware wraps route selection and is folded exactly
    # once per pipeline whatever the table holds, so that count is 1 with or without the fast
    # path and asserted nothing. What still tells the two apart is the `RouteResolution` stash:
    # `compose` writes one on every lookup that matches, and the fast path performs none.
    folds = Ref(0)
    counting_global = handler -> (folds[] += 1; req::HTTP.Request -> handler(req))
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/a", (req::HTTP.Request) -> Res.send("a")),
        path("/b", (req::HTTP.Request) -> Res.send("b")),
    ])
    pipeline = Nitro.Core.setupmiddleware(ctx; middleware = [counting_global], catch_errors = false)
    for _ in 1:3, p in ("/a", "/b")
        req = HTTP.Request("GET", p)
        @test text(pipeline(req)) == p[2:end]
        @test !haskey(req.context, Nitro.Core.Types.ROUTE_RESOLUTION_KEY)
    end
    @test folds[] == 1
end
end


@testitem "Custom middleware — global middleware runs on unmatched requests (#71)" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core.Types: snapshot
import Nitro: App, path, text

# `compose`'s unmatched-route path used to `return handler(req)`, and `handler` is the fold
# accumulator — the serializer wrapping the router — which contains NO global middleware
# (that arrives sideways as `compose`'s `globalmiddleware` and is applied inside
# `buildmiddleware`). So installing `compose` silently exempted 404s from every global
# middleware: a global `Cors()` emitted no headers on unmatched paths, and a global
# `RateLimiter()` did not rate-limit 404 probes at all.
#
# Measured on unpatched main: with per-route middleware present, an unmatched request ran
# global middleware 0 times; the control app without per-route middleware ran it once.
#
# The assertions below pin PARITY between those two configurations rather than an isolated
# count — the invariant is that installing `compose` must not change whether global
# middleware runs.

counting(ref) = handler -> (req::HTTP.Request -> (ref[] += 1; handler(req)))

@testset "404 — parity with and without per-route middleware" begin
    hits = Ref(0)

    # compose IS installed (this ctx has per-route middleware)
    with_mw = App()
    Nitro.Core.Routing.urlpatterns(with_mw, "", Nitro.RouteDefinition[
        path("/has", (req::HTTP.Request) -> Res.send("ok"),
             middleware = [h -> (q::HTTP.Request -> h(q))])
    ])
    hits[] = 0
    r = Nitro.Core.internalrequest(with_mw, HTTP.Request("GET", "/nope");
                                   middleware = [counting(hits)], catch_errors = false)
    @test r.status == 404
    @test hits[] == 1          # 0 on unpatched main

    # control: no per-route middleware anywhere
    without_mw = App()
    Nitro.Core.Routing.urlpatterns(without_mw, "", Nitro.RouteDefinition[
        path("/has", (req::HTTP.Request) -> Res.send("ok"))
    ])
    hits[] = 0
    r2 = Nitro.Core.internalrequest(without_mw, HTTP.Request("GET", "/nope");
                                    middleware = [counting(hits)], catch_errors = false)
    @test r2.status == 404
    @test hits[] == 1
end

@testset "405 — same parity, and no chain composed for it" begin
    # `gethandler` returns `missing` (not `nothing`) for a method mismatch, and
    # `missing !== nothing`, so a 405 used to take the *matched* branch: it keyed on the
    # empty path, composed a chain, and cached it under a junk "POST|" key.
    hits = Ref(0)
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/only-get", (req::HTTP.Request) -> Res.send("ok"), method = "GET",
             middleware = [h -> (q::HTTP.Request -> h(q))])
    ])
    hits[] = 0
    r = Nitro.Core.internalrequest(ctx, HTTP.Request("POST", "/only-get");
                                   middleware = [counting(hits)], catch_errors = false)
    @test r.status == 405
    @test hits[] == 1

    # No chain composed: the per-route middleware factory is never called for a 405. The global
    # factory is folded once per pipeline whatever happens (#291), so its count is only a check
    # that nothing folds it twice; `route_folds` is the assertion that matters.
    route_folds, global_folds = Ref(0), Ref(0)
    keyctx = App()
    Nitro.Core.Routing.urlpatterns(keyctx, "", Nitro.RouteDefinition[
        path("/only-get", (req::HTTP.Request) -> Res.send("ok"), method = "GET",
             middleware = [h -> (route_folds[] += 1; q::HTTP.Request -> h(q))])
    ])
    p = Nitro.Core.setupmiddleware(keyctx; catch_errors = false,
                                   middleware = [h -> (global_folds[] += 1; q::HTTP.Request -> h(q))])
    @test p(HTTP.Request("POST", "/only-get")).status == 405
    @test route_folds[] == 0
    @test global_folds[] == 1
end

@testset "a matched request still works and runs the global middleware once" begin
    # Guards against the 404 assertion passing because the middleware runs somewhere twice.
    hits = Ref(0)
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/has", (req::HTTP.Request) -> Res.send("ok"),
             middleware = [h -> (q::HTTP.Request -> h(q))])
    ])
    hits[] = 0
    r = Nitro.Core.internalrequest(ctx, HTTP.Request("GET", "/has");
                                   middleware = [counting(hits)], catch_errors = false)
    @test r.status == 200
    @test text(r) == "ok"
    @test hits[] == 1
end

@testset "an unmatched request composes nothing and leaves no stash" begin
    # This used to count GLOBAL folds against a prebuilt unmatched-path chain. Since #291 there is
    # no such chain — global middleware wraps route selection, folded once per pipeline — so that
    # count was 1 whatever the 404 path did. A 404 that composed a route chain would call the
    # route factory; one that stashed a resolution would leave the key on the request.
    route_folds = Ref(0)
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/has", (req::HTTP.Request) -> Res.send("ok"),
             middleware = [h -> (route_folds[] += 1; q::HTTP.Request -> h(q))])
    ])
    p = Nitro.Core.setupmiddleware(ctx; catch_errors = false,
                                   middleware = [h -> (q::HTTP.Request -> h(q))])
    for _ in 1:3
        req = HTTP.Request("GET", "/nope")
        @test p(req).status == 404
        @test get(req.context, Nitro.Core.Types.ROUTE_RESOLUTION_KEY, nothing) === nothing
    end
    @test route_folds[] == 0
end
end


@testitem "Custom middleware — registering middleware reaches a cached chain (#71)" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
import Nitro: App, path, text

# The sibling of #71, one level down. A pipeline caches each route's composed chain, so once a
# route is warm, middleware registered for it afterwards must still take effect — otherwise it is
# the install-gate symptom again, reached through the cache.
#
# Before #255 this was an explicit `delete!` of the route's key from an `App`-wide cache,
# paired with the publish in `publish_route_middleware!`. Now nothing is deleted: the publish
# moves `custommiddleware` to a new table, and each pipeline's `ChainCache` serves a chain only
# to requests holding the table it was built from. Both shapes of pipeline are covered, since
# the global-middleware one did not cache at all before #255.

mktag(tag) = handler -> (req::HTTP.Request -> Res.send(tag * "|" * text(handler(req))))

@testset "a warmed route picks up middleware registered afterwards" begin
    # This used to observe "warm" through a counting GLOBAL factory, which every chain
    # composition re-folded. Since #291 global middleware wraps route selection and is folded
    # once per pipeline, so it no longer sees compositions; the late ROUTE factory below does.
    # The pipeline keeps a global layer so the global-middleware shape stays covered.
    late_folds = Ref(0)
    late = handler -> (late_folds[] += 1; mktag("late")(handler))
    plain_global = handler -> (req::HTTP.Request -> handler(req))
    ctx = App()
    # Two routes so the table is non-empty from the start: this exercises the CACHE path, not
    # the empty-table fast path covered by the item above.
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/other", (req::HTTP.Request) -> Res.send("o"), middleware = [mktag("other")]),
        path("/warm",  (req::HTTP.Request) -> Res.send("h")),
    ])
    pipeline = Nitro.Core.setupmiddleware(ctx; middleware = [plain_global], catch_errors = false)
    for _ in 1:2
        @test text(pipeline(HTTP.Request("GET", "/warm"))) == "h"
    end

    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/warm", (req::HTTP.Request) -> Res.send("h"), middleware = [late])
    ])

    # Were the warm bare chain still served, this would be "h".
    @test text(pipeline(HTTP.Request("GET", "/warm"))) == "late|h"
    @test text(pipeline(HTTP.Request("GET", "/warm"))) == "late|h"
    @test late_folds[] == 1          # composed once for the new table, then cached
end

@testset "a registration rebuilds every route, and each still gets its own chain" begin
    # Invalidation is by generation now, so a registration for ONE route rebuilds every route's
    # chain on its next request. That is the accepted cost — registrations are rare — and this
    # pins that the rebuild is correct, not just that it happens.
    builds = Ref(0)
    keep = handler -> (builds[] += 1; req::HTTP.Request -> Res.send("keep|" * text(handler(req))))
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/keep", (req::HTTP.Request) -> Res.send("k"), middleware = [keep]),
        path("/drop", (req::HTTP.Request) -> Res.send("d")),
    ])
    pipeline = Nitro.Core.setupmiddleware(ctx; catch_errors = false)
    pipeline(HTTP.Request("GET", "/keep")); pipeline(HTTP.Request("GET", "/drop"))
    @test builds[] == 1

    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/drop", (req::HTTP.Request) -> Res.send("d"), middleware = [mktag("new")])
    ])
    @test text(pipeline(HTTP.Request("GET", "/keep"))) == "keep|k"
    @test text(pipeline(HTTP.Request("GET", "/drop"))) == "new|d"
    @test builds[] == 2                  # /keep rebuilt once for the new generation...
    pipeline(HTTP.Request("GET", "/keep"))
    @test builds[] == 2                  # ...and is cached again after that
end
end


@testitem "Custom middleware — ordering is identical across all three compose paths (#71)" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
import Nitro: App, path, text

# Executable form of the ordering-equivalence argument behind #71: installing `compose`
# unconditionally must not move global middleware relative to anything else, on ANY of the
# three paths through it — the empty-table fast path, the matched path for a route with no
# per-route middleware, and the matched path for a route that has some.
#
# Unlike test/middleware_tests.jl (the canary), this uses a local App and is
# order-independent within runtests.jl.

invocation = Int[]
mk(i) = handler -> (req::HTTP.Request -> (push!(invocation, i); handler(req)))
route_mw = handler -> (req::HTTP.Request -> (push!(invocation, 99); handler(req)))
globals() = [mk(1), mk(2), mk(3)]

@testset "empty table — the fast path" begin
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/x", (req::HTTP.Request) -> Res.send("ok"))
    ])
    empty!(invocation)
    r = Nitro.Core.internalrequest(ctx, HTTP.Request("GET", "/x");
                                   middleware = globals(), catch_errors = false)
    @test r.status == 200
    @test invocation == [1, 2, 3]
end

@testset "non-empty table, route without middleware — the gethandler path" begin
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/x",     (req::HTTP.Request) -> Res.send("ok")),
        path("/other", (req::HTTP.Request) -> Res.send("o"), middleware = [route_mw]),
    ])
    empty!(invocation)
    r = Nitro.Core.internalrequest(ctx, HTTP.Request("GET", "/x");
                                   middleware = globals(), catch_errors = false)
    @test r.status == 200
    @test invocation == [1, 2, 3]
end

@testset "serialize=false — the router is not a Function" begin
    # `HTTP.Router` is a callable struct, NOT `<: Function`, and every layer above it is typed
    # on `Function`. With `serialize=false` the serializer isn't there to wrap it, so the raw
    # router used to reach `_app_context_seed` (already a MethodError on internalrequest before
    # #71) and, once `compose` became unconditional, `foldlayers` — which would have thrown at
    # pipeline-construction time for every serialize=false app. `setupmiddleware` now starts the
    # fold from a Function adapter. All four combinations must work.
    for with_route_mw in (false, true)
        ctx = App()
        routes = with_route_mw ?
            Nitro.RouteDefinition[path("/x", (req::HTTP.Request) -> Res.send("ok"),
                                       middleware = [route_mw])] :
            Nitro.RouteDefinition[path("/x", (req::HTTP.Request) -> Res.send("ok"))]
        Nitro.Core.Routing.urlpatterns(ctx, "", routes)
        for serialize in (true, false)
            empty!(invocation)
            r = Nitro.Core.internalrequest(ctx, HTTP.Request("GET", "/x");
                                           middleware = globals(), serialize = serialize,
                                           catch_errors = false)
            @test r.status == 200
            @test invocation == (with_route_mw ? [1, 2, 3, 99] : [1, 2, 3])
        end
    end
end

@testset "route WITH middleware — globals stay outermost" begin
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/x", (req::HTTP.Request) -> Res.send("ok"), middleware = [route_mw])
    ])
    empty!(invocation)
    r = Nitro.Core.internalrequest(ctx, HTTP.Request("GET", "/x");
                                   middleware = globals(), catch_errors = false)
    @test r.status == 200
    # Route middleware runs INSIDE the globals — `compose` folds the globals around route
    # selection, so the chosen route's chain runs after all of them (#291).
    @test invocation == [1, 2, 3, 99]
end
end


@testitem "Route resolution — the terminal reuses compose's lookup (#80)" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core.Types: RouteResolution, ROUTE_RESOLUTION_KEY, RouteMiddleware, CopyOnWriteDict
import Nitro: App, path, text, getparams

# #80: `compose` (src/routerhof.jl) has to call `gethandler` before it can key the middleware
# cache, and used to throw the resolved handler and `Params()` away — so `(r::Router)(req)` at
# the bottom of the chain resolved the same request a second time. It now leaves a
# `RouteResolution` on the request and `_dispatch_resolved` (src/core/pipeline.jl) consumes it.
#
# A `gethandler` call count is not observable from a handler, so the load-bearing assertions
# here are UNIT tests of `_dispatch_resolved` against a router registered with a DIFFERENT
# handler than the stash names. If the terminal re-resolved, the router's handler would answer;
# only a terminal that honours the hand-off returns the stash's. Those three assertions fail
# against the unpatched code. The pipeline-level testsets below are guards on the semantics the
# hand-off must not change — they pass either way, by design.

const DISPATCH = Nitro.Core._dispatch_resolved

function router_with(body::String)
    r = HTTP.Router()
    HTTP.register!(r, "GET", "/x", (::HTTP.Request) -> HTTP.Response(200, body))
    return r
end

stash_handler(body::String) = (::HTTP.Request) -> HTTP.Response(200, body)

# Builds a stash that legitimately matches: THIS router, and this request's own method and
# target objects. Each testset below then perturbs exactly one of the three guarded inputs, so
# a failure names which part of the guard moved.
#
# The middleware table is EMPTY, so no route here has middleware of its own and a rerouted
# request may run any leaf (#291). The guard-bearing reroute cases are in the #291 item below.
stash!(req, router; handler, route = "/stashroute", params = Dict{String,String}()) =
    req.context[ROUTE_RESOLUTION_KEY] =
        RouteResolution(router, req.method, req.target, handler, route, params,
                        req.method, Dict{String,RouteMiddleware}(),
                        CopyOnWriteDict{RouteMiddleware}())

@testset "a matching stash is used, and the router is not consulted" begin
    router = router_with("ROUTER")
    req = HTTP.Request("GET", "/x")
    stash!(req, router; handler = stash_handler("STASH"))

    @test text(DISPATCH(router, req)) == "STASH"
    # `:route` comes from the stash too — this is `(r::Router)(req)`'s matched branch,
    # relocated, not merely a shortcut around the lookup.
    @test req.context[:route] == "/stashroute"
    # Empty params must leave `:params` ABSENT, exactly as HTTP.jl does. `pathparams`
    # (src/types.jl) distinguishes "no path variables" from "not routed yet" on this.
    @test !haskey(req.context, :params)
end

@testset "non-empty params land on the request" begin
    router = router_with("ROUTER")
    req = HTTP.Request("GET", "/x")
    stash!(req, router; handler = stash_handler("STASH"), route = "/p/{id}",
           params = Dict("id" => "7"))

    @test text(DISPATCH(router, req)) == "STASH"
    @test req.context[:params] == Dict("id" => "7")
    @test HTTP.getparams(req) == Dict("id" => "7")
end

@testset "a rewritten target declines the stash and re-resolves" begin
    router = router_with("ROUTER")
    req = HTTP.Request("GET", "/y")
    stash!(req, router; handler = stash_handler("STASH"))

    # The rewrite `PrefixStripMiddleware` performs: assign a different target. The guard is a
    # VALUE comparison (Julia strings are egal by contents, so `===` is not an address test),
    # which is what makes this a decline rather than an accident of allocation.
    req.target = "/x"
    @test text(DISPATCH(router, req)) == "ROUTER"
    @test req.context[:route] == "/x"
end

@testset "a rewrite to a byte-identical target keeps the hand-off" begin
    # The flip side of the guard being a value comparison, asserted rather than left implicit:
    # a middleware that reassigns an equal target has not changed the route, so re-resolving
    # would be pure waste. A freshly built object is used so this is not testing `x === x`.
    router = router_with("ROUTER")
    req = HTTP.Request("GET", "/x")
    stash!(req, router; handler = stash_handler("STASH"))

    suffix = "x"
    req.target = "/" * suffix
    @test text(DISPATCH(router, req)) == "STASH"
end

@testset "a rewritten method declines the stash and re-resolves" begin
    # `gethandler` matches on `req.method` as well as the target, and `Request.method` is a
    # mutable field — the `X-HTTP-Method-Override` rewrite is the shape that hits this. Before
    # #80 the router resolved after every middleware layer, so such a rewrite changed which
    # handler ran; guarding on the method is what keeps that true.
    router = HTTP.Router()
    HTTP.register!(router, "GET",  "/x", (::HTTP.Request) -> HTTP.Response(200, "GET-ROUTER"))
    HTTP.register!(router, "POST", "/x", (::HTTP.Request) -> HTTP.Response(200, "POST-ROUTER"))

    req = HTTP.Request("GET", "/x")
    stash!(req, router; handler = stash_handler("STASH"))
    req.method = "POST"

    @test text(DISPATCH(router, req)) == "POST-ROUTER"
end

@testset "a stash from another App's router is declined" begin
    # REGRESSION, found in review. The stash rides on `req.context`, which belongs to the
    # REQUEST; the "tables only ever grow" argument that makes reuse safe belongs to the App.
    # A request object handed to a second `App` — `internalrequest` is public — therefore
    # arrives carrying the first App's resolution. Without the router in the guard, App B
    # serves App A's handler.
    router_a = router_with("A-ROUTER")
    router_b = router_with("B-ROUTER")

    req = HTTP.Request("GET", "/x")
    stash!(req, router_a; handler = stash_handler("A-STASH"))

    @test text(DISPATCH(router_a, req)) == "A-STASH"     # its own router still honours it
    @test text(DISPATCH(router_b, req)) == "B-ROUTER"    # a foreign one must not
end

@testset "a stash from another App cannot resurrect a route that App never had" begin
    # The sharper half of the same defect: the foreign App 404s, so honouring the stash turns
    # a 404 into a 200 serving a handler from an application this request never reached.
    router_a = router_with("A-ROUTER")
    empty_router = HTTP.Router()

    req = HTTP.Request("GET", "/x")
    stash!(req, router_a; handler = stash_handler("A-STASH"))

    @test DISPATCH(empty_router, req).status == 404
end

@testset "no stash at all falls through to the router" begin
    router = router_with("ROUTER")
    @test text(DISPATCH(router, HTTP.Request("GET", "/x"))) == "ROUTER"
    # And an unmatched target still reaches the router's own 404.
    @test DISPATCH(router, HTTP.Request("GET", "/nope")).status == 404
end

@testset "a middleware that rewrites req.target still reaches the rewritten route" begin
    # Route middleware folds OUTSIDE the terminal, so it runs between compose's lookup and the
    # dispatch. Before #80 the router resolved after it and the rewrite won; the target guard
    # is what keeps that true. Since #291 that holds only because `/b` has no middleware of its
    # own; a reroute onto a guarded route is refused, see the #291 item.
    ctx = App()
    rewrite = handler -> (req::HTTP.Request -> begin
        suffix = "b"
        req.target = "/" * suffix
        handler(req)
    end)
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/a", (req::HTTP.Request) -> Res.send("A"), middleware = [rewrite]),
        path("/b", (req::HTTP.Request) -> Res.send("B")),
    ])

    r = Nitro.Core.internalrequest(ctx, HTTP.Request("GET", "/a"); catch_errors = false)
    @test r.status == 200
    @test text(r) == "B"
end

@testset "params and route are unchanged on a parametrized route with per-route middleware" begin
    ctx = App()
    passthrough = handler -> (req::HTTP.Request -> handler(req))
    seen = Dict{String,Any}()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/p/<int:id>", function (req::HTTP.Request, id::Int)
            seen["id"] = id
            seen["route"] = HTTP.getroute(req)
            seen["raw"] = HTTP.getparams(req)
            seen["decoded"] = getparams(req)
            return Res.send("ok")
        end, method = "GET", middleware = [passthrough]),
    ])

    r = Nitro.Core.internalrequest(ctx, HTTP.Request("GET", "/p/42"); catch_errors = false)
    @test r.status == 200
    @test seen["id"] == 42
    @test seen["route"] == "/p/{id}"
    @test seen["raw"] == Dict("id" => "42")
    @test seen["decoded"]["id"] == "42"
end

@testset "route middleware still sees params as absent — the stash does not move that" begin
    # `request_input` (src/core/request.jl) invalidates its cache exactly once, on the
    # transition from "no path params" to "path params present", and that transition happens at
    # the terminal. Writing the stash earlier must NOT make params visible to middleware, or
    # that rule fires at the wrong moment.
    ctx = App()
    params_in_mw = Ref{Any}(:unset)
    probe = handler -> (req::HTTP.Request -> begin
        params_in_mw[] = HTTP.getparams(req)
        handler(req)
    end)
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/q/<int:id>", (req::HTTP.Request, id::Int) -> Res.send(string(id)),
             method = "GET", middleware = [probe]),
    ])

    r = Nitro.Core.internalrequest(ctx, HTTP.Request("GET", "/q/9"); catch_errors = false)
    @test text(r) == "9"
    @test params_in_mw[] === nothing
end

@testset "a reused request object picks up a handler registered between passes" begin
    # The hand-off carries a per-request LOOKUP, never a cached handler: a pipeline's cached
    # chain still bottoms out in a live resolution. Re-registering `/x` WITHOUT a
    # `middleware=` kwarg skips `publish_route_middleware!`, so `custommiddleware` does not move
    # and the cached chain stays valid — and the second call must still reach the new handler.
    # A design that baked the resolved handler into the cached chain returns "v1" here.
    ctx = App()
    passthrough = handler -> (req::HTTP.Request -> handler(req))
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/x", (req::HTTP.Request) -> Res.send("v1"), middleware = [passthrough]),
    ])

    req = HTTP.Request("GET", "/x")
    @test text(Nitro.Core.internalrequest(ctx, req; catch_errors = false)) == "v1"

    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/x", (req::HTTP.Request) -> Res.send("v2")),
    ])
    # Same request OBJECT, so it still carries the first pass's stash on entry.
    @test text(Nitro.Core.internalrequest(ctx, req; catch_errors = false)) == "v2"
end

@testset "the same request object through two Apps gets each App's own handler" begin
    # The end-to-end form of the cross-App regression above, through public `internalrequest`.
    # App A has per-route middleware (so it stashes); App B registers the same path with a
    # different handler and no per-route middleware anywhere; App C never registers it.
    passthrough = handler -> (req::HTTP.Request -> handler(req))

    a = App()
    Nitro.Core.Routing.urlpatterns(a, "", Nitro.RouteDefinition[
        path("/shared", (req::HTTP.Request) -> Res.send("A-HANDLER"), middleware = [passthrough]),
    ])
    b = App()
    Nitro.Core.Routing.urlpatterns(b, "", Nitro.RouteDefinition[
        path("/shared", (req::HTTP.Request) -> Res.send("B-HANDLER")),
    ])
    c = App()
    Nitro.Core.Routing.urlpatterns(c, "", Nitro.RouteDefinition[
        path("/elsewhere", (req::HTTP.Request) -> Res.send("C-HANDLER")),
    ])

    req = HTTP.Request("GET", "/shared")
    @test text(Nitro.Core.internalrequest(a, req; catch_errors = false)) == "A-HANDLER"
    @test haskey(req.context, ROUTE_RESOLUTION_KEY)          # A really did stash

    @test text(Nitro.Core.internalrequest(b, req; catch_errors = false)) == "B-HANDLER"
    # 404, not 200 with A's body. This is the assertion that was red before the review fix.
    @test Nitro.Core.internalrequest(c, req; catch_errors = false).status == 404

    # The `resetstate()` variant — reuse a request across a replacement of the global
    # `CONTEXT[]` — is deliberately NOT added here. It is the same mechanism (the dispatching
    # router is no longer the one that stashed) and the router-identity guard above covers it
    # directly, whereas mutating `CONTEXT[]` would make this file order-dependent, which its
    # header comment explicitly relies on it not being.
end

@testset "a request that took the empty-table fast path writes no stash" begin
    # The fast path returns before `gethandler`, so nothing is stashed; a later pass on the
    # same object, after the table has become non-empty, must resolve normally.
    ctx = App()
    passthrough = handler -> (req::HTTP.Request -> handler(req))
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/r", (req::HTTP.Request) -> Res.send("r")),
    ])

    req = HTTP.Request("GET", "/r")
    @test text(Nitro.Core.internalrequest(ctx, req; catch_errors = false)) == "r"
    @test !haskey(req.context, ROUTE_RESOLUTION_KEY)

    # Publishing on a DIFFERENT route is enough to make the table non-empty app-wide.
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/other", (req::HTTP.Request) -> Res.send("o"), middleware = [passthrough]),
    ])
    @test text(Nitro.Core.internalrequest(ctx, req; catch_errors = false)) == "r"
    @test haskey(req.context, ROUTE_RESOLUTION_KEY)
end

@testset "a route that stops matching does not leave a stash behind" begin
    # REGRESSION. The first version of this argued that a pass writing no stash is unreachable
    # after a match, because `HTTP.register!` replaces a leaf rather than removing one. Upstream
    # `insert!` matches with `eq = (x, y) -> x == "*" || x == y`, so a method-specific
    # registration REPLACES a wildcard-method one — removing the route for every other method —
    # and `path(…; method = "*")` reaches that from ordinary Nitro code. `compose` therefore
    # clears the stash on the 404/405 path rather than relying on the argument.
    passthrough = handler -> (req::HTTP.Request -> handler(req))
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/w", (req::HTTP.Request) -> Res.send("WILDCARD"), method = "*",
             middleware = [passthrough]),
    ])

    req = HTTP.Request("POST", "/w")
    @test text(Nitro.Core.internalrequest(ctx, req; catch_errors = false)) == "WILDCARD"
    @test haskey(req.context, ROUTE_RESOLUTION_KEY)

    # Replaces the "*" leaf, so POST is no longer routed. (HTTP.jl warns on the replacement.)
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/w", (req::HTTP.Request) -> Res.send("GET-ONLY"), method = "GET",
             middleware = [passthrough]),
    ])

    fresh = Nitro.Core.internalrequest(ctx, HTTP.Request("POST", "/w"); catch_errors = false)
    reused = Nitro.Core.internalrequest(ctx, req; catch_errors = false)
    # The reused object must agree with the fresh one. Before the clear it answered 200
    # "WILDCARD" — the old handler — while a fresh request correctly got 405.
    @test fresh.status == 405
    @test reused.status == fresh.status
    @test text(reused) == text(fresh)
end

@testset "404 and 405 write no stash" begin
    ctx = App()
    passthrough = handler -> (req::HTTP.Request -> handler(req))
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/only", (req::HTTP.Request) -> Res.send("ok"), method = "GET",
             middleware = [passthrough]),
    ])

    miss = HTTP.Request("GET", "/absent")
    @test Nitro.Core.internalrequest(ctx, miss; catch_errors = false).status == 404
    @test !haskey(miss.context, ROUTE_RESOLUTION_KEY)

    # `missing` is the method-mismatch sentinel and carries an EMPTY path — stashing it would
    # hand the terminal a resolution for the route registered at "".
    mismatch = HTTP.Request("POST", "/only")
    @test Nitro.Core.internalrequest(ctx, mismatch; catch_errors = false).status == 405
    @test !haskey(mismatch.context, ROUTE_RESOLUTION_KEY)
end
end


@testitem "Custom middleware table — the value type is a concrete pair (#76)" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core.Types: CopyOnWriteDict, snapshot, publish!, RouteMiddleware, NO_ROUTE_MIDDLEWARE
using Nitro.Core.RouterHOF: publish_route_middleware!, genkey, router
import Nitro: App, path, text

# #76: the field was `CopyOnWriteDict{Tuple}`. Unparameterized `Tuple` is abstract, so
# `buildmiddleware`'s destructure (src/routerhof.jl) inferred `Any` in both slots — and until
# #255 that ran on EVERY request of any pipeline with global middleware
# (`serve(middleware=[...])`, every `revise=:lazy|:eager` session), not once per route.

@testset "the Service field and its snapshot carry the narrowed type" begin
    ctx = App()
    @test ctx.service.custommiddleware isa CopyOnWriteDict{RouteMiddleware}
    @test valtype(snapshot(ctx.service.custommiddleware)) === RouteMiddleware
end

@testset "the lookup infers the optional pair, where it used to infer Any" begin
    # The assertion the issue is actually about — and it is asserted against BOTH shapes, so
    # it records the size of the change rather than just the end state. The pre-#76 line is
    # the one that would go green again if the field were ever widened back.
    probe(d, key::String) = get(snapshot(d), key, NO_ROUTE_MIDDLEWARE)
    slots(d, key::String) = (probe(d, key)[1], probe(d, key)[2])
    OPTIONAL = Union{Nothing, Vector{Function}}

    @test Base.infer_return_type(probe, (CopyOnWriteDict{RouteMiddleware}, String)) ===
          Tuple{OPTIONAL, OPTIONAL}
    @test Base.infer_return_type(slots, (CopyOnWriteDict{RouteMiddleware}, String)) ===
          Tuple{OPTIONAL, OPTIONAL}

    # Pre-#76: abstract `Tuple` value type, so the destructure handed `buildmiddleware` two
    # values of static type `Any` — per request, before #255, whenever global middleware was set.
    @test Base.infer_return_type(probe, (CopyOnWriteDict{Tuple}, String)) === Tuple
    @test Base.infer_return_type(slots, (CopyOnWriteDict{Tuple}, String)) === Tuple{Any, Any}

    # NOT asserted, because it is false and #76's issue body says otherwise: that a
    # `(nothing, nothing)` literal default would infer a `Union` here. Julia's tuple types are
    # covariant, so `Tuple{Nothing,Nothing} <: RouteMiddleware` and the literal infers exactly
    # the same thing. `NO_ROUTE_MIDDLEWARE` earns its place for a different reason — see its
    # docstring — and this line is the receipt for that correction.
    lit(d, key::String) = get(snapshot(d), key, (nothing, nothing))
    @test Base.infer_return_type(lit, (CopyOnWriteDict{RouteMiddleware}, String)) ===
          Base.infer_return_type(probe, (CopyOnWriteDict{RouteMiddleware}, String))
end

@testset "both real write sites produce a value of that type" begin
    mw = handler -> (req::HTTP.Request -> handler(req))

    # Declarative: `register_route` stores `(nothing, processed)`.
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/d", (req::HTTP.Request) -> Res.send("d"), middleware = [mw]),
    ])
    @test snapshot(ctx.service.custommiddleware)[genkey("GET", "/d")] isa RouteMiddleware

    # HOF: `(inner::InnerRouter)` stores `(outer.middleware, inner.middleware)`. Both halves
    # are `Nullable{Vector{Function}}` FIELDS now, which is what lets this land in the
    # narrowed table without a conversion at the publish site.
    hctx = App()
    outer = router(hctx, "/h"; middleware = [mw])
    inner = outer("/x"; middleware = [mw])
    inner("GET")
    @test snapshot(hctx.service.custommiddleware)[genkey("GET", "/h/x")] isa RouteMiddleware
    @test fieldtype(Nitro.Core.RouterHOF.OuterRouter, :middleware) === Union{Nothing, Vector{Function}}
    @test fieldtype(Nitro.Core.RouterHOF.InnerRouter, :middleware) === Union{Nothing, Vector{Function}}
end

@testset "a wrong-arity or wrong-element pair is rejected at the publish site" begin
    # The correctness half of the narrowing, and the reason it is worth landing regardless of
    # what the benchmark says: `Tuple` left the 2-arity completely unchecked, so a bad write
    # surfaced as a `MethodError` inside `buildmiddleware`'s destructure on some later
    # request — far from the registration that caused it.
    ctx = App()
    # The `err.f` check is not ceremony: a bare `@test_throws MethodError` would also pass if
    # the call were misspelled, making the assertion vacuous.
    # Each value below IS a `Tuple`, so each published successfully under the old
    # `value::Tuple` signature — that is what makes these rejections the actual change.
    for bad in ((nothing, Function[], Function[]),      # wrong arity, too many
                (nothing,),                             # wrong arity, too few
                ("not middleware", nothing))            # right arity, wrong element type
        err = try
            publish_route_middleware!(ctx, "GET|/bad", bad)
            nothing
        catch e
            e
        end
        @test err isa MethodError
        @test err.f === publish_route_middleware!
    end
    # Nothing was published by any of the three.
    @test isempty(snapshot(ctx.service.custommiddleware))
end

@testset "behavior is unchanged: both slots still compose, in the same order" begin
    ctx = App()
    order = Int[]
    mk(i) = handler -> (req::HTTP.Request -> (push!(order, i); handler(req)))
    outer = router(ctx, "/h"; middleware = [mk(1)])
    inner = outer("/x"; middleware = [mk(2)])
    route = inner("GET")
    Nitro.Core.register(ctx, "GET", route, (req::HTTP.Request) -> Res.send("ok"))

    r = Nitro.Core.internalrequest(ctx, HTTP.Request("GET", "/h/x"); catch_errors = false)
    @test text(r) == "ok"
    # Router-level outside route-level — `buildmiddleware` passes router first, and
    # `foldlayers` runs its arguments outermost first (#312).
    @test order == [1, 2]
end
end

@testitem "Route middleware — '*', STREAM and WEBSOCKET routes run their guards (#282)" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core: DeclaredMethodHandler, internalrequest, Service
using Nitro.Core.RouterHOF: router
using Nitro.Core.Routing: urlpatterns
import Nitro: App, path, text

# REGRESSION for #282, an authorization bypass. Route middleware is published under the
# DECLARED method (`"*|/w"`, `"STREAM|/sse"`) and `compose` looked it up under `req.method`.
# No request carries `*`, and `STREAM`/`WEBSOCKET` are registered as `GET`/`POST`, so the lookup
# never matched and a guard on such a route was skipped without an error. The leaf now carries its
# declared method (`DeclaredMethodHandler`) and `compose` keys on that.
#
# In-process throughout. `deny` never calls the handler, so the STREAM and WEBSOCKET handlers
# are never reached and need no stream. The wire half, where a passing middleware wraps a live
# STREAM handler, is in test/streaming_tests.jl.

status(ctx, method, target) = internalrequest(ctx, HTTP.Request(method, target)).status
leaf(ctx, method, target) = first(HTTP.Handlers.gethandler(ctx.service.router, HTTP.Request(method, target)))

deny = handle -> (req -> HTTP.Response(403))
# `value` is captured, so every `tag(...)` is a distinct closure.
tag(value) = handle -> (req -> Nitro.Core.Util.add_response_headers(handle(req), "X-Tag" => value))
ok(req::HTTP.Request) = Res.send("ran")

@testset "a guard on a method=\"*\" route runs for every method" begin
    ctx = App()
    urlpatterns(ctx, "", path("/w", ok; method = "*", middleware = [deny]))
    for m in ("GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS")
        @test status(ctx, m, "/w") == 403
    end
    @test leaf(ctx, "POST", "/w") isa DeclaredMethodHandler
    @test leaf(ctx, "POST", "/w").method == "*"
end

@testset "a guard on a STREAM route runs for GET and POST, on a WEBSOCKET route for GET" begin
    ctx = App()
    urlpatterns(ctx, "",
        path("/sse", (s::HTTP.Stream) -> nothing; method = "STREAM", middleware = [deny]),
        path("/ws", (ws::HTTP.WebSockets.WebSocket) -> nothing; method = "WEBSOCKET", middleware = [deny]),
    )
    @test status(ctx, "GET", "/sse") == 403
    @test status(ctx, "POST", "/sse") == 403
    @test status(ctx, "GET", "/ws") == 403
    @test leaf(ctx, "GET", "/sse").method == "STREAM"
    @test leaf(ctx, "POST", "/sse").method == "STREAM"
    @test leaf(ctx, "GET", "/ws").method == "WEBSOCKET"
end

@testset "router-level middleware gates the same three methods" begin
    ctx = App()
    guarded = router(ctx, "/r"; middleware = [deny])
    Nitro.Core.register(ctx, "*", guarded("/w"), ok)
    Nitro.Core.register(ctx, "STREAM", guarded("/sse"), (s::HTTP.Stream) -> nothing)
    Nitro.Core.register(ctx, "WEBSOCKET", guarded("/ws"), (ws::HTTP.WebSockets.WebSocket) -> nothing)
    @test status(ctx, "GET", "/r/w") == 403
    @test status(ctx, "PUT", "/r/w") == 403
    @test status(ctx, "GET", "/r/sse") == 403
    @test status(ctx, "POST", "/r/sse") == 403
    @test status(ctx, "GET", "/r/ws") == 403
end

@testset "a \"*\" leaf and a GET leaf at one path keep their own middleware" begin
    # GET first, so both leaves exist. Registered the other way round, the GET leaf would replace
    # the "*" one (HTTP.jl's `insert!` matches an existing "*" leaf for any method).
    guard_star = App()
    urlpatterns(guard_star, "",
        path("/p", ok),
        path("/p", ok; method = "*", middleware = [deny]),
    )
    @test status(guard_star, "GET", "/p") == 200
    @test status(guard_star, "POST", "/p") == 403

    guard_get = App()
    urlpatterns(guard_get, "",
        path("/p", ok; middleware = [deny]),
        path("/p", ok; method = "*"),
    )
    @test status(guard_get, "GET", "/p") == 403
    @test status(guard_get, "POST", "/p") == 200
end

@testset "the cached chain is shared across methods and follows a re-publish" begin
    ctx = App()
    urlpatterns(ctx, "", path("/w", ok; method = "*", middleware = [tag("one")]))
    # The first request warms the chain under `*|/w`; the second method hits the cache.
    @test HTTP.header(internalrequest(ctx, HTTP.Request("GET", "/w")), "X-Tag") == "one"
    @test HTTP.header(internalrequest(ctx, HTTP.Request("POST", "/w")), "X-Tag") == "one"

    # Re-registering (what Revise does) re-publishes `*|/w` and must invalidate that cached chain
    # for every method, not only the one that warmed it.
    urlpatterns(ctx, "", path("/w", ok; method = "*", middleware = [tag("two")]))
    @test HTTP.header(internalrequest(ctx, HTTP.Request("GET", "/w")), "X-Tag") == "two"
    @test HTTP.header(internalrequest(ctx, HTTP.Request("POST", "/w")), "X-Tag") == "two"
end

@testset "a router with HTTP.jl-level middleware refuses a guarded route it cannot key" begin
    # `register!` wraps the leaf in the router's own middleware, which hides the declared method.
    # The guard would silently never run, so registration fails instead.
    wrapped() = App(service = Service(router = HTTP.Router(HTTP.Handlers.default404,
                                                           HTTP.Handlers.default405,
                                                           h -> (req -> h(req)))))
    for (method, handler) in (("*", ok),
                              ("STREAM", (s::HTTP.Stream) -> nothing),
                              ("WEBSOCKET", (ws::HTTP.WebSockets.WebSocket) -> nothing))
        err = try
            urlpatterns(wrapped(), "", path("/g", handler; method = method, middleware = [deny]))
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("would never run", sprint(showerror, err))
    end

    # With no middleware to key there is nothing to lose, so the route registers and is served.
    ctx = wrapped()
    urlpatterns(ctx, "", path("/g", ok; method = "*"))
    @test status(ctx, "POST", "/g") == 200
    # A concrete method keys on `req.method` and needs no tag, so it is not refused either.
    urlpatterns(ctx, "", path("/c", ok; method = "POST", middleware = [deny]))
    @test status(ctx, "POST", "/c") == 403
end
end


@testitem "Route middleware — a rerouting middleware cannot skip the new route's guards (#291)" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core: internalrequest
using Nitro.Core.RouterHOF: router
using Nitro.Core.Routing: urlpatterns
import Nitro: App, path, text

# REGRESSION for #291, an authorization bypass. `compose` chose the middleware chain from the
# request as it arrived, and global middleware ran inside that chain. A layer that rewrote
# `req.method` or `req.target` then reached the terminal, which re-resolved the rewritten
# request to a leaf whose guards were never chosen. A guarded `DELETE` answered a `GET` or a
# `POST` carrying `X-HTTP-Method-Override`, and a global path alias turned a 404 into a guarded
# route's 200. The 404/405 cases are the ones the issue itself thought were safe.
#
# Global middleware now wraps route selection, so its rewrites pick up the new route's guards.
# A router- or route-level layer runs after selection; rerouting from there onto a route with
# different middleware is refused with a 500.

deleted = Ref(false)
deny = handle -> (req -> HTTP.Response(403))
override = handle -> function (req::HTTP.Request)
    m = HTTP.header(req, "X-HTTP-Method-Override", "")
    isempty(m) || (req.method = uppercase(m))
    return handle(req)
end
alias(from, to) = handle -> function (req::HTTP.Request)
    startswith(req.target, from) && (req.target = replace(req.target, from => to; count = 1))
    return handle(req)
end
read_item(req::HTTP.Request, id::Int) = Res.send("read $id")
delete_item(req::HTTP.Request, id::Int) = (deleted[] = true; Res.send("DELETED $id"))

# The issue's app: a public GET and a guarded DELETE at one path.
function items_app(; get_mw = Function[])
    app = App()
    urlpatterns(app, "",
        path("/items/<int:id>", read_item; middleware = get_mw),
        path("/items/<int:id>", delete_item; method = "DELETE", middleware = [deny]),
    )
    return app
end
hit(app, method, target, headers = Pair{String,String}[]; middleware = Function[]) =
    internalrequest(app, HTTP.Request(method, target, headers); middleware)

OVERRIDE_DELETE = ["X-HTTP-Method-Override" => "DELETE"]

# A router leaf that is callable but not a `Function`.
struct CallableLeaf end
(::CallableLeaf)(req::HTTP.Request) = HTTP.Response(200, "raw")

@testset "global method override gets the overridden route's guard" begin
    app = items_app()
    deleted[] = false
    # A GET that matched the public route, then was rewritten. 200 "DELETED 1" before #291.
    @test hit(app, "GET", "/items/1", OVERRIDE_DELETE; middleware = [override]).status == 403
    # A POST, which no route declares, so `compose` took its 405 path and chose no chain at all.
    # The HTML-form shape, and the one the issue called safe. 200 "DELETED 1" before #291.
    @test hit(app, "POST", "/items/1", OVERRIDE_DELETE; middleware = [override]).status == 403
    @test !deleted[]

    # Without the header the same layer changes nothing.
    r = hit(app, "GET", "/items/1"; middleware = [override])
    @test r.status == 200 && text(r) == "read 1"
    r = hit(app, "POST", "/items/1"; middleware = [override])
    @test r.status == 405
    @test HTTP.header(r, "Allow") == "DELETE, GET, HEAD"
end

@testset "global path alias gets the aliased route's guard" begin
    app = items_app()
    deleted[] = false
    legacy = alias("/legacy/", "/items/")
    # `/legacy/1` matches nothing, so this came through the 404 path. 200 before #291.
    @test hit(app, "DELETE", "/legacy/1"; middleware = [legacy]).status == 403
    @test !deleted[]
    # An alias onto a public route still works.
    r = hit(app, "GET", "/legacy/1"; middleware = [legacy])
    @test r.status == 200 && text(r) == "read 1"
end

@testset "route-level method override onto a guarded route is refused" begin
    app = items_app(get_mw = [override])
    deleted[] = false
    logger = Test.TestLogger(min_level = Base.CoreLogging.Error)
    r = Base.CoreLogging.with_logger(logger) do
        hit(app, "GET", "/items/1?token=s3cret", OVERRIDE_DELETE)
    end
    @test r.status == 500
    @test !deleted[]

    # One error, naming both routes by pattern, and nothing from the request's query string.
    @test length(logger.logs) == 1
    entry = only(logger.logs)
    @test occursin("rerouted", entry.message)
    @test entry.kwargs[:from] == "GET /items/{id}"
    @test entry.kwargs[:to] == "DELETE /items/{id}"
    @test !occursin("s3cret", sprint(show, entry.kwargs))

    # The layer is harmless when it does not reroute.
    r = hit(app, "GET", "/items/1")
    @test r.status == 200 && text(r) == "read 1"
end

@testset "route-level target rewrite: refused onto a guarded route, allowed onto an open one" begin
    app = App()
    urlpatterns(app, "",
        path("/old-admin", (req::HTTP.Request) -> Res.send("old"); middleware = [alias("/old-admin", "/admin")]),
        path("/admin", (req::HTTP.Request) -> Res.send("ADMIN"); middleware = [deny]),
        path("/old-page", (req::HTTP.Request) -> Res.send("old"); middleware = [alias("/old-page", "/page")]),
        path("/page", (req::HTTP.Request) -> Res.send("page")),
    )
    r = Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
        hit(app, "GET", "/old-admin")
    end
    @test r.status == 500
    @test text(r) != "ADMIN"

    # `/page` has no middleware of its own, so the chain that already ran covers it.
    r = hit(app, "GET", "/old-page")
    @test r.status == 200 && text(r) == "page"
end

@testset "a rewrite that stays on the same chain is served" begin
    strip_slash = handle -> function (req::HTTP.Request)
        endswith(req.target, "/") && (req.target = chop(req.target))
        return handle(req)
    end
    head_as_get = handle -> function (req::HTTP.Request)
        req.method == "HEAD" && (req.method = "GET")
        return handle(req)
    end
    app = App()
    urlpatterns(app, "",
        path("/s", (req::HTTP.Request) -> Res.send("s"); middleware = [strip_slash]),
        path("/h", (req::HTTP.Request) -> Res.send(req.method); middleware = [head_as_get]),
    )
    # Same leaf, different target string.
    r = hit(app, "GET", "/s/")
    @test r.status == 200 && text(r) == "s"
    # The auto-HEAD leaf keys on GET (#277), so HEAD rewritten to GET stays on that chain.
    r = hit(app, "HEAD", "/h")
    @test r.status == 200 && text(r) == "GET"

    # Two routes under one `router(...; middleware)` share their entry, so a reroute between them
    # has already run everything the target requires.
    shared = App()
    admin = router(shared, "/r"; middleware = [override])
    Nitro.Core.register(shared, "GET", admin("/x"), (req::HTTP.Request) -> Res.send("get"))
    Nitro.Core.register(shared, "DELETE", admin("/x"), (req::HTTP.Request) -> Res.send("delete"))
    r = hit(shared, "GET", "/r/x", OVERRIDE_DELETE)
    @test r.status == 200 && text(r) == "delete"
end

@testset "a router-level override onto a differently guarded route is refused" begin
    app = App()
    open_r = router(app, "/r"; middleware = [override])
    Nitro.Core.register(app, "GET", open_r("/x"), (req::HTTP.Request) -> Res.send("get"))
    Nitro.Core.register(app, "DELETE", open_r("/x"; middleware = [deny]),
                        (req::HTTP.Request) -> Res.send("delete"))
    r = Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
        hit(app, "GET", "/r/x", OVERRIDE_DELETE)
    end
    @test r.status == 500
end

@testset "a reroute onto a declared-method leaf keys on its declared method" begin
    # The new leaf's entry must be looked up under the method it was DECLARED with, exactly as
    # `compose` does. Keyed on `req.method` instead, both lookups below miss, read as "no
    # middleware", and serve the guarded handler. Found in review.
    guarded = Ref(false)
    to_star = handle -> (req::HTTP.Request -> (req.target = "/star"; handle(req)))
    to_head = handle -> (req::HTTP.Request -> (req.method = "HEAD"; req.target = "/g"; handle(req)))
    app = App()
    urlpatterns(app, "",
        path("/star", (req::HTTP.Request) -> (guarded[] = true; Res.send("STAR"));
             method = "*", middleware = [deny]),
        path("/g", (req::HTTP.Request) -> (guarded[] = true; Res.send("G")); middleware = [deny]),
        path("/to-star", (req::HTTP.Request) -> Res.send("open"); middleware = [to_star]),
        path("/to-head", (req::HTTP.Request) -> Res.send("open"); middleware = [to_head]),
    )
    Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
        @test hit(app, "GET", "/to-star").status == 500        # "*|/star", not "GET|/star"
        @test hit(app, "GET", "/to-head").status == 500        # auto-HEAD keys on "GET|/g"
    end
    @test !guarded[]
end

@testset "a reroute from a non-Function leaf is judged like any other" begin
    # A callable struct registered on the router directly is not a `Function`. Its match used to
    # CLEAR the stash, which the terminal read as "no chain was chosen", so its route middleware
    # could reroute onto a guarded leaf unchecked. Found in review.
    guarded = Ref(false)
    app = App()
    urlpatterns(app, "",
        path("/g", (req::HTTP.Request) -> (guarded[] = true; Res.send("GUARDED")); middleware = [deny]))
    HTTP.register!(app.service.router, "GET", "/raw", CallableLeaf())
    Nitro.Core.RouterHOF.publish_route_middleware!(app, "GET|/raw",
        (nothing, Function[handle -> (req::HTTP.Request -> (req.target = "/g"; handle(req)))]))
    r = Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
        hit(app, "GET", "/raw")
    end
    @test r.status == 500
    @test !guarded[]
    # Without the reroute it is served through the stash, wrapper and all.
    Nitro.Core.RouterHOF.publish_route_middleware!(app, "GET|/raw",
        (nothing, Function[handle -> (req::HTTP.Request -> handle(req))]))
    req = HTTP.Request("GET", "/raw")
    r = internalrequest(app, req)
    @test r.status == 200 && text(r) == "raw"
    @test req.context[Nitro.Core.Types.ROUTE_RESOLUTION_KEY] isa Nitro.Core.Types.RouteResolution
end

@testset "a route registered after selection is judged against the live table" begin
    # The stash's snapshot predates a route registered while the request sat in route middleware
    # (Revise, a runtime `include_routes`). Read from that snapshot the new route has no entry and
    # would be served unguarded. Made deterministic by registering from inside the middleware.
    guarded = Ref(false)
    app = App()
    register_then_go = handle -> function (req::HTTP.Request)
        urlpatterns(app, "",
            path("/late", (r::HTTP.Request) -> (guarded[] = true; Res.send("LATE")); middleware = [deny]))
        req.target = "/late"
        return handle(req)
    end
    urlpatterns(app, "", path("/early", (req::HTTP.Request) -> Res.send("early"); middleware = [register_then_go]))
    r = Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
        hit(app, "GET", "/early")
    end
    @test r.status == 500
    @test !guarded[]
end
end

@testitem "Route middleware — every list runs top-down, in the order written (#312)" tags=[:core, :middleware, :auth] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core: internalrequest
using Nitro.Core.RouterHOF: router
import Nitro: App, path, text

# REGRESSION for #312. The global list was `reverse`d before folding and ran top-down; route
# and router lists were folded as written, and the fold made the LAST element outermost, so
# `path(...; middleware = [A, B])` ran B, then A. The documented
# `[BearerAuth(v), GuardMiddleware(...)]` therefore guarded before it authenticated. None of
# the existing tests used a list with two entries, so none of them saw it.

tag(order, name) = handle -> (req::HTTP.Request -> (push!(order, name); handle(req)))

@testset "a route list runs in list order — the issue's reproduction" begin
    app = App(mod = @__MODULE__)
    order = String[]
    urlpatterns(app, "", path("/x", req -> "ok"; middleware = [tag(order, "route1"), tag(order, "route2")]))
    r = internalrequest(app, HTTP.Request("GET", "/x");
                        middleware = [tag(order, "global1"), tag(order, "global2")])
    @test r.status == 200
    @test order == ["global1", "global2", "route1", "route2"]
end

@testset "global → router → route, each list top-down" begin
    ctx = App()
    order = String[]
    outer = router(ctx, "/h"; middleware = [tag(order, "router1"), tag(order, "router2")])
    inner = outer("/x"; middleware = [tag(order, "route1"), tag(order, "route2")])
    Nitro.Core.register(ctx, "GET", inner("GET"), (req::HTTP.Request) -> Res.send("ok"))
    r = internalrequest(ctx, HTTP.Request("GET", "/h/x");
                        middleware = [tag(order, "global1"), tag(order, "global2")], catch_errors = false)
    @test text(r) == "ok"
    @test order == ["global1", "global2", "router1", "router2", "route1", "route2"]

    # A cache hit replays the same chain, so the order is not a property of the first build.
    empty!(order)
    internalrequest(ctx, HTTP.Request("GET", "/h/x");
                    middleware = [tag(order, "global1"), tag(order, "global2")], catch_errors = false)
    @test order == ["global1", "global2", "router1", "router2", "route1", "route2"]
end

# The shape the `GuardMiddleware` docstring and the auth tutorial teach, end to end.
@testset "[BearerAuth, GuardMiddleware] authenticates first, then authorizes" begin
    app = App(mod = @__MODULE__)
    validator(t) = t == "admin-token" ? Dict("sub" => "1", "role" => "admin") :
                   t == "user-token"  ? Dict("sub" => "2", "role" => "user")  : nothing
    urlpatterns(app, "",
        path("/admin", req -> "welcome"; middleware = [
            BearerAuth(validator), GuardMiddleware(login_required(), role_required("admin"))]),
        path("/role-only", req -> "welcome"; middleware = [
            BearerAuth(validator), GuardMiddleware(role_required("admin"))]))
    bearer(t) = ["Authorization" => "Bearer $t"]

    # Before #312 the guard ran first, on no principal: 302 here, 403 on /role-only.
    @test internalrequest(app, HTTP.Request("GET", "/admin", bearer("admin-token"))).status == 200
    @test internalrequest(app, HTTP.Request("GET", "/role-only", bearer("admin-token"))).status == 200
    # Authenticated but not authorized is the guard's 403.
    @test internalrequest(app, HTTP.Request("GET", "/admin", bearer("user-token"))).status == 403
    # Unauthenticated is the auth layer's 401 — it runs first now, so it answers.
    @test internalrequest(app, HTTP.Request("GET", "/admin")).status == 401
    @test internalrequest(app, HTTP.Request("GET", "/admin", bearer("bogus"))).status == 401
end

# Why #312 had to land with #313: once the auth layer runs first, `login_required` is the only
# thing between a predicate validator's `false` and the handler. It must be the 401.
@testset "a predicate validator's wrong key is a 401 even with login_required behind it" begin
    app = App(mod = @__MODULE__)
    reached = Ref(false)
    urlpatterns(app, "", path("/c", req -> (reached[] = true; "in");
        middleware = [BearerAuth(t -> t == "s3cr3t"), GuardMiddleware(login_required())]))
    r = internalrequest(app, HTTP.Request("GET", "/c", ["Authorization" => "Bearer WRONG"]))
    @test r.status == 401
    @test !reached[]
end
end
