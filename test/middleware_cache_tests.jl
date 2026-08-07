@testitem "Middleware cache — copy-on-write publish" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using Nitro.Core.Types: MiddlewareCache, snapshot, cache!

# Regression test for #35. `MiddlewareCache` backs `compose`'s per-route chain lookup
# (src/routerhof.jl), which is read lock-free on every request while warmup writes are
# still landing. It used to be a plain `Dict` read outside the lock that guarded its
# writes — a `rehash!` under a concurrent reader yields a wrong lookup (one route's chain
# served for another), a `BoundsError`, or a segfault.
#
# Most of these assertions are deliberately deterministic and single-threaded: they do not
# test the race, they test the invariant that makes the race impossible — no `Dict` is
# mutated after a reader can reach it. Measured against a faithful reconstruction of the
# pre-fix shape, 6 assertions across testsets 2, 4 and 5 hard-fail. The last testset is the
# genuine race, and needs real parallelism to mean anything (see its own comment).

mk(tag) = (req -> tag)          # stand-in composed chain; only identity is ever checked

@testset "publish is visible and returns the winner" begin
    c = MiddlewareCache()
    @test isempty(snapshot(c))
    f = mk("a")
    @test cache!(c, "GET|/a", f) === f
    @test snapshot(c)["GET|/a"] === f
end

@testset "a published snapshot is never mutated" begin
    c = MiddlewareCache()
    f, g = mk("a"), mk("b")
    cache!(c, "GET|/a", f)
    reader = snapshot(c)          # what an in-flight request is holding
    cache!(c, "GET|/b", g)        # a warmup write lands underneath it

    # The whole safety argument. Against the pre-fix shared plain `Dict`, `reader` would
    # have gained the key in place — the exact reader-vs-`rehash!` window of #35.
    @test length(reader) == 1
    @test !haskey(reader, "GET|/b")
    @test reader["GET|/a"] === f
    @test reader !== snapshot(c)
    @test length(snapshot(c)) == 2
end

@testset "first writer wins; an already-cached key publishes nothing" begin
    c = MiddlewareCache()
    f, g = mk("first"), mk("second")
    cache!(c, "GET|/a", f)
    published = snapshot(c)
    @test cache!(c, "GET|/a", g) === f       # the loser is handed the winner
    @test snapshot(c)["GET|/a"] === f
    @test snapshot(c) === published          # no pointless copy on the already-cached path
end

@testset "empty! swaps a fresh table in — it does not clear the reader's" begin
    c = MiddlewareCache()
    cache!(c, "GET|/a", mk("a")); cache!(c, "GET|/b", mk("b"))
    reader = snapshot(c)                     # an in-flight request during shutdown
    @test empty!(c) === c
    @test isempty(snapshot(c))
    # `terminate` (src/core.jl) calls this while requests are still in `compose`. An
    # in-place `empty!(::Dict)` would have pulled the table out from under `reader`.
    @test length(reader) == 2
    @test reader["GET|/a"] isa Function
end

@testset "an unsynchronized publish is unwritable" begin
    c = MiddlewareCache()
    # `entries` is declared `@atomic`, so the plain field write that caused #35 is a
    # runtime error rather than a silent data race. This is the property that keeps the
    # bug from being reintroduced by someone reaching past `cache!`.
    @test_throws ConcurrencyViolationError c.entries = Dict{String, Function}()
end

@testset "concurrent writers lose nothing" begin
    c = MiddlewareCache()
    fs = Dict("GET|/r$i" => mk("r$i") for i in 1:64)
    # Scope note, honestly: this passes identically against the pre-fix shape, because the
    # pre-fix WRITE path was already correctly locked — #35 was a read bug. Keep it as a
    # `cache!` unit test (no lost updates, first-writer-wins holds under interleaving); do
    # not read it as a #35 regression test. The regression coverage is testsets 2/4/5 and
    # the race testset below.
    @sync for (k, f) in fs
        @async cache!(c, k, f)
    end
    final = snapshot(c)
    @test length(final) == 64
    @test all(final[k] === f for (k, f) in fs)
end

@testset "lock-free readers are not corrupted by a concurrent writer" begin
    # THE #35 race itself. This needs REAL parallelism: `@async` produces sticky tasks bound
    # to the spawning thread, so an `@async` reader can never actually overlap a writer —
    # cooperative scheduling has no yield point inside a `Dict` lookup. Hence
    # `Threads.@spawn`, gated on thread count so the spin loop cannot starve the writer at
    # `-t 1`. CI runs 1 and 2, so the gated branch does execute in CI.
    c = MiddlewareCache()
    for i in 1:8
        cache!(c, "GET|/seed$i", mk("seed$i"))
    end

    if Threads.nthreads() > 1
        bad = Threads.Atomic{Int}(0)
        # ROUNDS, not one pass: a single round detects a reintroduced #35 only ~13% of the
        # time at `-t 2` (measured, 200 trials). A round costs ~0.5 ms, so 25 of them buy
        # ~97% detection for ~12 ms. Measured false-positive rate on correct code: 0/600.
        for _ in 1:25
            c = MiddlewareCache()
            for i in 1:8
                cache!(c, "GET|/seed$i", mk("seed$i"))
            end
            stop = Threads.Atomic{Bool}(false)
            readers = [Threads.@spawn begin
                try
                    while !stop[]
                        t = snapshot(c)      # one acquire-load, then read it repeatedly
                        for i in 1:8
                            f = get(t, "GET|/seed$i", nothing)
                            if f === nothing || f(nothing) != "seed$i"
                                Threads.atomic_add!(bad, 1)
                            end
                        end
                    end
                catch                        # a torn read throws out of the reader task
                    Threads.atomic_add!(bad, 1)
                end
            end for _ in 1:max(1, Threads.nthreads() - 1)]

            writer = Threads.@spawn begin
                # `finally`: if `cache!` ever throws, `stop` must still be set or the
                # reader spin loops never exit and the item hangs to its 600 s timeout.
                try
                    for i in 1:200
                        cache!(c, "GET|/w$i", mk("w$i"))
                    end
                finally
                    stop[] = true
                end
            end

            wait(writer)
            foreach(wait, readers)
            @test length(snapshot(c)) == 208
        end

        # Against the pre-fix plain `Dict` this trips: a `rehash!` under a lock-free reader
        # gives a missing or wrong lookup, or throws out of the reader.
        @test bad[] == 0
    else
        # `-t 1`: no parallelism to be had. Assert the same invariant sequentially so the
        # testset is never vacuously green (cf. test/parallel_tests.jl's both-branches shape).
        held = snapshot(c)
        for i in 1:200
            cache!(c, "GET|/w$i", mk("w$i"))
        end
        @test length(held) == 8                      # the held snapshot never grew
        @test all(held["GET|/seed$i"](nothing) == "seed$i" for i in 1:8)
        @test length(snapshot(c)) == 208
    end
end
end


@testitem "Middleware cache — concurrent warmup through compose" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Random: randperm
using Nitro
using Nitro.Core.Types: snapshot
import Nitro: ServerContext

# Companion to the unit item above: drives the real `compose` fast path (src/routerhof.jl)
# on a LOCAL ServerContext, so this item touches no global CONTEXT[] router state and is
# order-independent within runtests.jl.
#
# Two preconditions must BOTH hold to reach the cache at all:
#   * `compose` is only installed when `custommiddleware` is non-empty (`setupmiddleware`,
#     src/core.jl) → every route below is registered with `middleware=`;
#   * caching is only on when there is no per-call global middleware
#     (`use_cache = isempty(globalmiddleware)`, src/routerhof.jl)
#     → `internalrequest` is called with NO `middleware=` kwarg.
#
# `terminate()` is deliberately not exercised end-to-end: it requires `isopen(service)`,
# i.e. a live `serve(async=true)`, which buys a `:network` flake risk for no signal over
# the direct `empty!` assertions in the last testset.

const K = 24        # distinct routes — enough to exercise many keys, not a race parameter
const M = 4         # requests per route

# Scope, stated accurately: this item is a FUNCTIONAL regression test for the key→chain
# mapping and for the cache actually being reached — it is NOT a race test. `@async` tasks
# are sticky to the spawning thread, and the factory `yield()` below fires inside
# `buildmiddleware`, i.e. after the cache read-miss and before the publish. Reads and writes
# therefore phase-separate cleanly and no reader ever overlaps a writer here. The real race
# lives in the unit item above, under `Threads.@spawn`.
function tagging_middleware(tag::String)
    return function (handler)
        yield()
        return function (req::HTTP.Request)
            yield()
            inner = handler(req)                        # router + serializer for this route
            return text(tag * "|" * text(inner))        # NEW response; never mutate `inner`
        end
    end
end

ctx = ServerContext()
Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
    path("/warm/$i", (req::HTTP.Request) -> text("handler-$i"),
         middleware = [tagging_middleware("route-$i")])
    for i in 1:K
])

targets  = [(i, "/warm/$i") for i in 1:K for _ in 1:M]
shuffled = targets[randperm(length(targets))]           # interleave misses with hits

# `catch_errors=false` is deliberate: any error in the chain propagates instead of being
# laundered into a 500 that the body assertion below would then (wrongly) explain.
results = Vector{String}(undef, length(shuffled))
@sync for (n, (_, target)) in enumerate(shuffled)
    @async begin
        r = Nitro.Core.internalrequest(ctx, HTTP.Request("GET", target); catch_errors=false)
        results[n] = "$(r.status)|$(text(r))"
    end
end

@testset "every request got its own route's chain" begin
    # A stale or mis-keyed cache read serves route A's chain for route B — visible here as
    # a body mismatch. This is deterministic key→chain coverage, not race coverage: per the
    # header, no reader overlaps a writer in this item.
    @test all(results[n] == "200|route-$(shuffled[n][1])|handler-$(shuffled[n][1])"
              for n in eachindex(shuffled))
end

@testset "warmup converged to exactly one entry per route" begin
    entries = snapshot(ctx.service.middleware_cache)
    @test length(entries) == K
    @test all(haskey(entries, "GET|/warm/$i") for i in 1:K)
end

@testset "cache-hit path returns the right chain" begin
    for i in 1:K
        r = Nitro.Core.internalrequest(ctx, HTTP.Request("GET", "/warm/$i"); catch_errors=false)
        @test r.status == 200
        @test text(r) == "route-$i|handler-$i"
    end
end

@testset "empty! re-warms cleanly — the terminate path" begin
    empty!(ctx.service.middleware_cache)
    @test isempty(snapshot(ctx.service.middleware_cache))
    r = Nitro.Core.internalrequest(ctx, HTTP.Request("GET", "/warm/1"); catch_errors=false)
    @test text(r) == "route-1|handler-1"
    @test haskey(snapshot(ctx.service.middleware_cache), "GET|/warm/1")
end

@testset "one composed pipeline re-reads the cache on every request" begin
    # Guards the `compose` NOTE: the cache object must be captured by the closure and
    # `snapshot` called PER REQUEST. Hoisting `snapshot` to compose time freezes an empty
    # table and silently disables the cache — no functional symptom at all, just a
    # permanent rebuild on every request.
    #
    # Nothing above catches that, because `internalrequest` calls `setupmiddleware` (hence
    # `compose`) per request, so a hoisted snapshot is refreshed every call. `serve()` calls
    # it exactly ONCE for the server's lifetime. So compose once and reuse the pipeline,
    # which is what production actually does.
    factory_calls = Ref(0)
    counting_mw = handler -> (factory_calls[] += 1; req -> handler(req))

    ctx2 = ServerContext()
    Nitro.Core.Routing.urlpatterns(ctx2, "", Nitro.RouteDefinition[
        path("/once", (req::HTTP.Request) -> text("ok"), middleware = [counting_mw])
    ])

    pipeline = Nitro.Core.setupmiddleware(ctx2; catch_errors=false)
    for _ in 1:5
        @test text(pipeline(HTTP.Request("GET", "/once"))) == "ok"
    end

    # `buildmiddleware` — and so the factory — runs only on a cache MISS. One call means
    # requests 2-5 took the cached chain. Under a hoisted `snapshot` this is 5.
    @test factory_calls[] == 1
end
end
