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
# narrowed from an abstract `Tuple` in #76). The semantic that separates it
# from `middleware_cache` is LAST-writer-wins: re-running `urlpatterns` for a path must
# install the NEW middleware, whereas a cached chain must never change identity. A port that
# reached for `cache!` here passes every other test in the suite and fails this one.
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
    #
    # The per-call `middleware=` is future-proofing, not load-bearing today: no request runs
    # before the re-registration above, so the cache is cold either way. It keeps `use_cache`
    # false so this stays correct if a request is ever added between the two registrations —
    # with a warm cache the first-writer-wins chain from registration A would win and this
    # would read "A|h". Verified by construction: with the kwarg dropped AND a request
    # inserted between the registrations, this returns "A|h".
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


@testitem "Custom middleware table — the uncached hot path (use_cache == false)" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core.Types: snapshot
import Nitro: App, path, text

# This is the configuration the #68 bug actually lives in, so it gets its own item.
#
# `compose` computes `use_cache = isempty(globalmiddleware)` once. When false, the cache is
# neither read nor written, so `buildmiddleware` — and its read of `custommiddleware` — runs
# on EVERY request, forever. `use_cache` is false for any `serve(middleware=[...])` (CORS,
# sessions, auth, rate limiting — the normal production shape) and for every
# `revise=:lazy|:eager` session, since `serve` injects `ReviseHandler`.

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

# NO caching happens here, so requests may be driven sequentially — the point of this item
# is the per-request rebuild, not concurrency (that is the third item).
results = [text(Nitro.Core.internalrequest(ctx, HTTP.Request("GET", "/u/$i");
                                           middleware = [global_mw], catch_errors = false))
           for _ in 1:3 for i in 1:K]

@testset "every request got its own route's chain" begin
    expected = [ "r$i|h$i" for _ in 1:3 for i in 1:K ]
    @test results == expected
end

@testset "this configuration caches nothing at all" begin
    # Executable documentation of why the lock-free read here is a per-request-forever read
    # rather than a warmup-window one. If this ever starts failing, the cost model in
    # `CopyOnWriteDict`'s comment block changed and that comment needs revisiting.
    @test isempty(snapshot(ctx.service.middleware_cache))
end

@testset "buildmiddleware runs once per request, not once per route" begin
    ctx2 = App()
    Nitro.Core.Routing.urlpatterns(ctx2, "", Nitro.RouteDefinition[
        path("/counted", (req::HTTP.Request) -> Res.send("ok"), middleware = [counting_mw])
    ])
    factory_calls[] = 0
    for _ in 1:5
        Nitro.Core.internalrequest(ctx2, HTTP.Request("GET", "/counted");
                                   middleware = [global_mw], catch_errors = false)
    end
    # The positive form of "uncached, forever". A future "let's just cache it anyway" change
    # has to confront this assertion deliberately rather than silently flipping it.
    @test factory_calls[] == 5
end

@testset "a composed pipeline sees routes registered after it was composed" begin
    # Mutation guard, mirroring the one in test/middleware_cache_tests.jl. `buildmiddleware`
    # must snapshot `custommiddleware` PER CALL. If a refactor hoists that snapshot to
    # compose time the table freezes for the life of the server and routes registered later
    # — Revise re-running `urlpatterns` — silently lose their middleware, with no error and
    # no other failing test.
    ctx3 = App()
    Nitro.Core.Routing.urlpatterns(ctx3, "", Nitro.RouteDefinition[
        path("/first", (req::HTTP.Request) -> Res.send("h1"), middleware = [mktag("r1")])
    ])
    # Route 1 exists BEFORE this call deliberately, and the reason changed with #71: the table
    # being non-empty is no longer what installs `compose` (it is always installed now), but it
    # is what gets requests PAST the per-request emptiness fast path and into `buildmiddleware`,
    # which is where the per-call snapshot this item guards actually lives. The companion item
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
# request, in front of a prebuilt global-middleware-only chain.
#
# ANTI-HOIST DUTY. Hoisting the emptiness check out of the per-request closure would freeze the
# verdict at compose time and reinstate #71 exactly. Verified by mutation: under that change
# this item fails while the guard in the item above — which composes against a NON-empty table —
# stays green, along with the rest of this file. Do not merge the two items.

mktag(tag) = handler -> (req::HTTP.Request -> Res.send(tag * "|" * text(handler(req))))
plain_global = handler -> (req::HTTP.Request -> handler(req))

@testset "middleware registered after composition runs (use_cache == true)" begin
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/plain", (req::HTTP.Request) -> Res.send("plain"))
    ])
    # Composed while the table is EMPTY — the exact situation #71 is about.
    @test isempty(snapshot(ctx.service.custommiddleware))
    pipeline = Nitro.Core.setupmiddleware(ctx; catch_errors = false)

    @test text(pipeline(HTTP.Request("GET", "/plain"))) == "plain"
    # Nothing may be cached while the table is empty. This is what makes the flip below
    # clean: `cache!` is first-writer-wins, so a bare chain cached now would beat the
    # middleware registered later and #71 would reappear one level down.
    @test isempty(snapshot(ctx.service.middleware_cache))

    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/late", (req::HTTP.Request) -> Res.send("h"), middleware = [mktag("late")])
    ])

    # On unpatched main this returns "h" — the middleware never runs.
    @test text(pipeline(HTTP.Request("GET", "/late"))) == "late|h"
    @test text(pipeline(HTTP.Request("GET", "/plain"))) == "plain"
end

@testset "same at use_cache == false" begin
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
    @test isempty(snapshot(ctx.service.middleware_cache))   # use_cache == false caches nothing
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

@testset "nothing is cached while the table is empty" begin
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/a", (req::HTTP.Request) -> Res.send("a")),
        path("/b", (req::HTTP.Request) -> Res.send("b")),
    ])
    pipeline = Nitro.Core.setupmiddleware(ctx; catch_errors = false)
    for _ in 1:3, p in ("/a", "/b")
        pipeline(HTTP.Request("GET", p))
    end
    @test isempty(snapshot(ctx.service.middleware_cache))
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

@testset "405 — same parity, and no degenerate cache key" begin
    # `gethandler` returns `missing` (not `nothing`) for a method mismatch, and
    # `missing !== nothing`, so a 405 used to take the *matched* branch: it keyed on the
    # empty path and wrote a junk "POST|" entry into the middleware cache.
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

    # The junk-key check needs its OWN context with NO per-call middleware: passing
    # `middleware=` sets `use_cache = false`, so nothing is cached at all and the assertion
    # could never fail. Measured on unpatched main, this context ends up holding "POST|".
    keyctx = App()
    Nitro.Core.Routing.urlpatterns(keyctx, "", Nitro.RouteDefinition[
        path("/only-get", (req::HTTP.Request) -> Res.send("ok"), method = "GET",
             middleware = [h -> (q::HTTP.Request -> h(q))])
    ])
    r2 = Nitro.Core.internalrequest(keyctx, HTTP.Request("POST", "/only-get"); catch_errors = false)
    @test r2.status == 405
    @test !any(startswith(k, "POST|") for k in keys(snapshot(keyctx.service.middleware_cache)))
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

@testset "an unmatched request caches nothing (use_cache == true)" begin
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/has", (req::HTTP.Request) -> Res.send("ok"),
             middleware = [h -> (q::HTTP.Request -> h(q))])
    ])
    Nitro.Core.internalrequest(ctx, HTTP.Request("GET", "/nope"); catch_errors = false)
    @test isempty(snapshot(ctx.service.middleware_cache))
end
end


@testitem "Custom middleware — registering middleware invalidates the cached chain (#71)" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core.Types: CopyOnWriteDict, snapshot, cache!, publish!
using Nitro.Core.RouterHOF: cachetag
import Nitro: App, path, text

const TAG = cachetag(false, true, true)   # catch_errors=false, show_errors/serialize default

# The sibling of #71, one level down. `middleware_cache` is first-writer-wins, so once a
# route's composed chain is cached, registering middleware for that route afterwards could
# never take effect — the same symptom as the install gate, reached through the cache.
#
# Route middleware is now published via `publish_route_middleware!`, which pairs the
# `publish!` with a `delete!` of the same cache key.

mktag(tag) = handler -> (req::HTTP.Request -> Res.send(tag * "|" * text(handler(req))))

@testset "a warmed route picks up middleware registered afterwards" begin
    ctx = App()
    # Two routes so the table is non-empty from the start: this exercises the CACHE path, not
    # the empty-table fast path covered by the item above.
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/other", (req::HTTP.Request) -> Res.send("o"), middleware = [mktag("other")]),
        path("/warm",  (req::HTTP.Request) -> Res.send("h")),
    ])
    pipeline = Nitro.Core.setupmiddleware(ctx; catch_errors = false)

    @test text(pipeline(HTTP.Request("GET", "/warm"))) == "h"
    # Cache keys carry the pipeline's serializer settings since #79; this pipeline is
    # `catch_errors=false` with the other two defaulted, i.e. "|cES".
    @test haskey(snapshot(ctx.service.middleware_cache), "GET|/warm" * TAG)   # warmed

    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/warm", (req::HTTP.Request) -> Res.send("h"), middleware = [mktag("late")])
    ])

    # Without the invalidation the cached bare chain wins and this is "h".
    @test !haskey(snapshot(ctx.service.middleware_cache), "GET|/warm" * TAG)  # invalidated
    @test text(pipeline(HTTP.Request("GET", "/warm"))) == "late|h"
end

@testset "invalidation drops only the affected key" begin
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/keep", (req::HTTP.Request) -> Res.send("k"), middleware = [mktag("keep")]),
        path("/drop", (req::HTTP.Request) -> Res.send("d")),
    ])
    pipeline = Nitro.Core.setupmiddleware(ctx; catch_errors = false)
    pipeline(HTTP.Request("GET", "/keep"))
    pipeline(HTTP.Request("GET", "/drop"))
    @test haskey(snapshot(ctx.service.middleware_cache), "GET|/keep" * TAG)

    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/drop", (req::HTTP.Request) -> Res.send("d"), middleware = [mktag("new")])
    ])
    entries = snapshot(ctx.service.middleware_cache)
    @test haskey(entries, "GET|/keep" * TAG)        # untouched
    @test !haskey(entries, "GET|/drop" * TAG)       # invalidated
end

@testset "delete! is copy-on-write" begin
    d = CopyOnWriteDict{Function}()
    f = req -> "f"
    cache!(d, "GET|/x", f)
    held = snapshot(d)

    delete!(d, "GET|/x")
    @test isempty(snapshot(d))
    @test held["GET|/x"] === f          # the held snapshot still has it
    @test length(held) == 1

    # Absent key: no publish at all, so the table object is unchanged.
    before = snapshot(d)
    delete!(d, "GET|/never")
    @test snapshot(d) === before
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
    # Route middleware runs INSIDE the globals — it is appended first, so it ends up innermost.
    @test invocation == [1, 2, 3, 99]
end
end


@testitem "Route resolution — the terminal reuses compose's lookup (#80)" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core.Types: RouteResolution, ROUTE_RESOLUTION_KEY
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
stash!(req, router; handler, route = "/stashroute", params = Dict{String,String}()) =
    req.context[ROUTE_RESOLUTION_KEY] =
        RouteResolution(router, req.method, req.target, handler, route, params)

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
    # is what keeps that true.
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
    # The hand-off carries a per-request LOOKUP, never a cached handler: the chain in
    # `middleware_cache` still bottoms out in a live resolution. Re-registering `/x` WITHOUT a
    # `middleware=` kwarg skips `publish_route_middleware!`, so the cached chain is NOT
    # invalidated — and the second call must still reach the new handler. A design that baked
    # the resolved handler into the cached chain returns "v1" here.
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
# `buildmiddleware`'s destructure (src/routerhof.jl) inferred `Any` in both slots — and that
# runs on EVERY request whenever `use_cache == false` (`serve(middleware=[...])`, every
# `revise=:lazy|:eager` session), not once per route.

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
    # values of static type `Any` — and that runs per request whenever `use_cache` is false.
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
    # Router-level outside route-level — `buildmiddleware` appends route first, so it lands
    # innermost after the fold.
    @test order == [1, 2]
end
end
