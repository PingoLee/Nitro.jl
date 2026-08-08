@testitem "Custom middleware table — registration publishes last-writer-wins" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core.Types: snapshot
import Nitro: ServerContext, path, text

# Regression test for #68 item 1. `ctx.service.custommiddleware` maps a route key to that
# route's `(router middleware, route middleware)` pair. It used to be a plain `Dict` written
# with a bare `setindex!` — no lock on either side — while `buildmiddleware`
# (src/routerhof.jl) read it lock-free on the request path.
#
# It is now a `CopyOnWriteDict{Tuple}` written via `publish!`. The semantic that separates it
# from `middleware_cache` is LAST-writer-wins: re-running `urlpatterns` for a path must
# install the NEW middleware, whereas a cached chain must never change identity. A port that
# reached for `cache!` here passes every other test in the suite and fails this one.
#
# Local `ServerContext` throughout — no global `CONTEXT[]`, so these items are
# order-independent within runtests.jl.

# `tag` MUST be captured. A factory returning `handler -> (req -> handler(req))` builds a
# closure with zero fields, so every call returns the same singleton instance and
# `mkmw("A") === mkmw("B")` is `true` — which silently turns every identity assertion below
# into a tautology. (That mistake shipped in an earlier draft of this file and hid a total
# absence of coverage on the HOF write site.) Referencing `tag` in the body gives each
# factory a distinct closure type and instance.
mkmw(tag) = handler -> (req::HTTP.Request -> text(tag * "|" * text(handler(req))))

@testset "re-registering a path overwrites, and a held snapshot does not" begin
    mwA, mwB = mkmw("A"), mkmw("B")
    @test mwA !== mwB          # guards the tautology above; the rest is meaningless without it

    ctx = ServerContext()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/lww", (req::HTTP.Request) -> text("h"), middleware = [mwA])
    ])
    held = snapshot(ctx.service.custommiddleware)
    @test held["GET|/lww"][2][1] === mwA

    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/lww", (req::HTTP.Request) -> text("h"), middleware = [mwB])
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
    ctx = ServerContext()
    Nitro.Core.router(ctx, "/hof"; middleware = [mwA])("/x")("GET")
    @test snapshot(ctx.service.custommiddleware)["GET|/hof/x"][1][1] === mwA

    # The only coverage the HOF write site has anywhere in the suite. With a first-writer-wins
    # publish here the table would keep `mwA` forever and this assertion is what catches it.
    Nitro.Core.router(ctx, "/hof"; middleware = [mwB])("/x")("GET")
    @test snapshot(ctx.service.custommiddleware)["GET|/hof/x"][1][1] === mwB
end

@testset "an unsynchronized publish is unwritable" begin
    ctx = ServerContext()
    @test_throws ConcurrencyViolationError ctx.service.custommiddleware.entries = Dict{String, Tuple}()
end
end


@testitem "Custom middleware table — the uncached hot path (use_cache == false)" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core.Types: snapshot
import Nitro: ServerContext, path, text

# This is the configuration the #68 bug actually lives in, so it gets its own item.
#
# `compose` computes `use_cache = isempty(globalmiddleware)` once. When false, the cache is
# neither read nor written, so `buildmiddleware` — and its read of `custommiddleware` — runs
# on EVERY request, forever. `use_cache` is false for any `serve(middleware=[...])` (CORS,
# sessions, auth, rate limiting — the normal production shape) and for every
# `revise=:lazy|:eager` session, since `serve` injects `ReviseHandler`.

const K = 8
mktag(tag) = handler -> (req::HTTP.Request -> text(tag * "|" * text(handler(req))))

factory_calls = Ref(0)
counting_mw = handler -> (factory_calls[] += 1; req::HTTP.Request -> handler(req))
global_mw   = handler -> (req::HTTP.Request -> handler(req))

ctx = ServerContext()
Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
    path("/u/$i", (req::HTTP.Request) -> text("h$i"), middleware = [mktag("r$i")])
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
    ctx2 = ServerContext()
    Nitro.Core.Routing.urlpatterns(ctx2, "", Nitro.RouteDefinition[
        path("/counted", (req::HTTP.Request) -> text("ok"), middleware = [counting_mw])
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
    ctx3 = ServerContext()
    Nitro.Core.Routing.urlpatterns(ctx3, "", Nitro.RouteDefinition[
        path("/first", (req::HTTP.Request) -> text("h1"), middleware = [mktag("r1")])
    ])
    # Route 1 must exist BEFORE this call: `setupmiddleware` gates on the table being
    # non-empty, so composing against an empty table never installs `compose` at all. That
    # gate's staleness is a known, separately-tracked limitation.
    pipeline = Nitro.Core.setupmiddleware(ctx3; middleware = [global_mw], catch_errors = false)

    Nitro.Core.Routing.urlpatterns(ctx3, "", Nitro.RouteDefinition[
        path("/second", (req::HTTP.Request) -> text("h2"), middleware = [mktag("r2")])
    ])

    @test text(pipeline(HTTP.Request("GET", "/second"))) == "r2|h2"
    @test text(pipeline(HTTP.Request("GET", "/first")))  == "r1|h1"
end
end


@testitem "Custom middleware table — lock-free readers under a concurrent publisher" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using Nitro.Core.Types: CopyOnWriteDict, snapshot, publish!

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
        d = CopyOnWriteDict{Tuple}()
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
    d = CopyOnWriteDict{Tuple}()
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
