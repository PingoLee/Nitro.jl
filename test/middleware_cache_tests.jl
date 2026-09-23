@testitem "Copy-on-write dict — parametric container" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using Nitro.Core.Types: CopyOnWriteDict, snapshot, publish!, RouteMiddleware

# #68 generalized `MiddlewareCache` into `CopyOnWriteDict{V}`. Since #255 it backs one `Service`
# field, `custommiddleware :: CopyOnWriteDict{RouteMiddleware}` (LAST-writer-wins `publish!`);
# the chain cache that was its other instantiation became the per-pipeline `ChainCache` (items
# below). These assertions pin the container at `RouteMiddleware` AND at a second `V`, so its
# semantics are proven generic rather than accidentally correct for the one value type in use.

probe(d) = snapshot(d)                     # a call boundary, so @inferred/@allocated mean something
mkf(tag) = (req -> tag)

@testset "snapshot is type-stable and allocation-free at both V" begin
    cf = CopyOnWriteDict{Function}(); publish!(cf, "k", mkf("f"))
    ct = CopyOnWriteDict{RouteMiddleware}(); publish!(ct, "k", (nothing, Function[]))
    @test @inferred(probe(cf)) isa Dict{String, Function}
    @test @inferred(probe(ct)) isa Dict{String, RouteMiddleware}
    probe(cf); probe(ct)                   # warm up before measuring
    # The reader fast path is on every request that gets past `compose`'s emptiness test; if
    # this ever regresses we want to hear it.
    @test (@allocated probe(cf)) == 0
    @test (@allocated probe(ct)) == 0
end

@testset "publish! is last-writer-wins" begin
    for (V, v1, v2) in ((Function, mkf("a"), mkf("b")),
                        (RouteMiddleware, (nothing, Function[]), (Function[], nothing)))
        p = CopyOnWriteDict{V}()
        publish!(p, "k", v1); publish!(p, "k", v2)
        @test snapshot(p)["k"] === v2                  # LWW: overwritten
    end
end

@testset "publish! never mutates a held snapshot, and always moves the identity" begin
    # The first half is what makes lock-free reads safe. The second is what the chain cache's
    # generation check is built on (#255): a publish that reused the published `Dict` would
    # leave every pipeline serving chains composed from the old middleware.
    d = CopyOnWriteDict{RouteMiddleware}()
    v1, v2 = (nothing, Function[]), (Function[], nothing)
    publish!(d, "k", v1)
    reader = snapshot(d)
    publish!(d, "k", v2)
    @test reader["k"] === v1
    @test reader !== snapshot(d)
    @test snapshot(d)["k"] === v2

    # ...including a publish of the value already stored: "nothing changed" is not a reason to
    # keep the identity, and the chain cache does not need it to be.
    held = snapshot(d)
    publish!(d, "k", v2)
    @test snapshot(d) !== held
end

@testset "an unsynchronized publish is unwritable at V = RouteMiddleware" begin
    d = CopyOnWriteDict{RouteMiddleware}()
    @test_throws ConcurrencyViolationError d.entries = Dict{String, RouteMiddleware}()
end
end


@testitem "Chain cache — generation-checked, copy-on-write" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using Nitro.Core.Types: ChainCache, ChainCacheState, ChainKey, cached_chain, cache_chain!,
                        CopyOnWriteDict, snapshot, publish!, RouteMiddleware

# Unit coverage for `ChainCache` (src/types.jl, #255): one pipeline's composed chains, stamped
# with the `custommiddleware` snapshot they were built from. Two properties, tested separately:
#
#   * STALENESS — a chain is returned only to a caller holding the very snapshot it was built
#     from. That replaced #71's invalidating `delete!` and #81's lock-ordering proof, so it is
#     the property a regression would silently reopen: registered middleware that never runs.
#   * #35 — the published generation is never mutated under a lock-free reader.

mkf(tag) = (req -> tag)          # stand-in composed chain; only identity/result is checked
table() = (t = CopyOnWriteDict{RouteMiddleware}(); publish!(t, "GET|/a", (nothing, Function[])); t)

@testset "a fresh cache misses for every snapshot" begin
    c, t = ChainCache(), table()
    @test cached_chain(c, snapshot(t), ("GET", "/a")) === nothing
    @test cached_chain(c, Dict{String, RouteMiddleware}(), ("GET", "/a")) === nothing
end

@testset "publish then hit, within one generation" begin
    c, t = ChainCache(), table()
    snap, f = snapshot(t), mkf("a")
    @test cache_chain!(c, t, snap, ("GET", "/a"), f)
    @test cached_chain(c, snap, ("GET", "/a")) === f
    @test cached_chain(c, snap, ("GET", "/other")) === nothing
end

@testset "a registration makes every earlier chain unservable" begin
    # THE staleness property. No `delete!` runs anywhere: the registration's `publish!` allocates
    # a new table, and the old chain is simply not returned to anyone holding it.
    c, t = ChainCache(), table()
    snap0 = snapshot(t)
    cache_chain!(c, t, snap0, ("GET", "/a"), mkf("old"))

    publish!(t, "GET|/b", (nothing, Function[]))        # a DIFFERENT route is registered
    snap1 = snapshot(t)
    @test cached_chain(c, snap1, ("GET", "/a")) === nothing   # conservative: any write moves it

    @test cache_chain!(c, t, snap1, ("GET", "/a"), mkf("new"))
    @test cached_chain(c, snap1, ("GET", "/a"))(nothing) == "new"
    # The new generation starts empty — nothing is carried over from the old one.
    @test length((@atomic c.state).chains) == 1
    # A request still holding the old table now misses too, and rebuilds from what it holds.
    @test cached_chain(c, snap0, ("GET", "/a")) === nothing
end

@testset "the #81 straddle: built from the old table, published after the registration" begin
    # req: snapshot -> T0; reg: publish! -> T1; req: cache_chain!(…, T0, …)
    # The table has moved and T0 is not the stored generation, so this declines. Even if it had
    # published, the next request (holding T1) would not be served it — see the testset above.
    c, t = ChainCache(), table()
    snap0 = snapshot(t)
    publish!(t, "GET|/a", (nothing, Function[mkf("mw")]))
    @test cache_chain!(c, t, snap0, ("GET", "/a"), mkf("stale")) == false
    @test cached_chain(c, snapshot(t), ("GET", "/a")) === nothing
end

@testset "a slow request cannot replace a newer generation" begin
    c, t = ChainCache(), table()
    snap0 = snapshot(t)
    publish!(t, "GET|/b", (nothing, Function[]))
    snap1 = snapshot(t)
    cache_chain!(c, t, snap1, ("GET", "/a"), mkf("current"))
    current = @atomic c.state

    # Composed against T0, publishing after T1's generation is in: refused, state untouched.
    @test cache_chain!(c, t, snap0, ("GET", "/c"), mkf("slow")) == false
    @test (@atomic c.state) === current
    @test cached_chain(c, snap1, ("GET", "/a"))(nothing) == "current"
end

@testset "first writer wins within a generation, and publishes nothing" begin
    c, t = ChainCache(), table()
    snap = snapshot(t)
    f, g = mkf("first"), mkf("second")
    @test cache_chain!(c, t, snap, ("GET", "/a"), f)
    published = @atomic c.state
    @test cache_chain!(c, t, snap, ("GET", "/a"), g) == false
    @test cached_chain(c, snap, ("GET", "/a")) === f          # identity never changes under a reader
    @test (@atomic c.state) === published                # no pointless copy
end

@testset "a published generation is never mutated" begin
    # #35's invariant, carried over: a reader holding a generation sees it exactly as it was.
    c, t = ChainCache(), table()
    snap = snapshot(t)
    cache_chain!(c, t, snap, ("GET", "/a"), mkf("a"))
    held = @atomic c.state
    cache_chain!(c, t, snap, ("GET", "/b"), mkf("b"))
    @test length(held.chains) == 1
    @test !haskey(held.chains, ("GET", "/b"))
    @test held !== (@atomic c.state)
    @test length((@atomic c.state).chains) == 2
end

@testset "an unsynchronized publish is unwritable" begin
    # `state` is `@atomic`, so the plain field write that caused #35 is a runtime error rather
    # than a silent data race.
    c = ChainCache()
    @test_throws ConcurrencyViolationError c.state = ChainCacheState(Dict{String, RouteMiddleware}(),
                                                                       Dict{ChainKey, Function}())
end

@testset "a hit allocates nothing, key included (#250)" begin
    # The hit path used to build `string(method, '|', path, tag)` per request — one `String`,
    # the only allocation a cache hit paid. The key is now a tuple of strings that already exist,
    # so building it AND looking it up must allocate nothing. Built inside the probe from two
    # separate strings, exactly as `compose` does from `req.method` and `Leaf.path`, so a key
    # type that joined them would show up here.
    c, t = ChainCache(), table()
    snap = snapshot(t)
    method, route = "GET", "/a"
    cache_chain!(c, t, snap, (method, route), mkf("a"))
    probe(c, snap, m, p) = cached_chain(c, snap, (m, p))
    @test probe(c, snap, method, route)(nothing) == "a"        # warm up, and it is a hit
    @test (@allocated probe(c, snap, method, route)) == 0
    @test @inferred(Union{Function, Nothing}, probe(c, snap, method, route)) isa Function
end

@testset "concurrent writers lose nothing" begin
    # A `cache_chain!` unit test (no lost updates under interleaving), not a #35 test — the
    # write path is locked either way. The race is the next testset.
    c, t = ChainCache(), table()
    snap = snapshot(t)
    fs = Dict(("GET", "/r$i") => mkf("r$i") for i in 1:64)
    @sync for (k, f) in fs
        @async cache_chain!(c, t, snap, k, f)
    end
    @test all(cached_chain(c, snap, k) === f for (k, f) in fs)
end

@testset "lock-free readers are not corrupted by a concurrent writer" begin
    # THE #35 race, against `ChainCache`. This needs REAL parallelism: `@async` produces sticky
    # tasks bound to the spawning thread, so an `@async` reader can never actually overlap a
    # writer. Hence `Threads.@spawn`, gated on thread count so the spin loop cannot starve the
    # writer at `-t 1`. CI runs 1 and 2, so the gated branch does execute in CI. 25 rounds, as the
    # `CopyOnWriteDict` version of this test measured: one round detects a reintroduced #35 only
    # ~13% of the time at `-t 2`, 25 rounds ~97%.
    if Threads.nthreads() > 1
        bad = Threads.Atomic{Int}(0)
        for _ in 1:25
            c, t = ChainCache(), table()
            snap = snapshot(t)
            for i in 1:8
                cache_chain!(c, t, snap, ("GET", "/seed$i"), mkf("seed$i"))
            end
            stop = Threads.Atomic{Bool}(false)
            readers = [Threads.@spawn begin
                try
                    while !stop[]
                        for i in 1:8
                            f = cached_chain(c, snap, ("GET", "/seed$i"))
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
                # `finally`: if the writer ever throws, `stop` must still be set or the reader
                # spin loops never exit and the item hangs to its timeout.
                try
                    for i in 1:200
                        cache_chain!(c, t, snap, ("GET", "/w$i"), mkf("w$i"))
                    end
                finally
                    stop[] = true
                end
            end

            wait(writer)
            foreach(wait, readers)
            @test length((@atomic c.state).chains) == 208
        end
        @test bad[] == 0
    else
        # `-t 1`: assert the same invariant sequentially so the testset is never vacuously green.
        c, t = ChainCache(), table()
        snap = snapshot(t)
        for i in 1:8
            cache_chain!(c, t, snap, ("GET", "/seed$i"), mkf("seed$i"))
        end
        held = @atomic c.state
        for i in 1:200
            cache_chain!(c, t, snap, ("GET", "/w$i"), mkf("w$i"))
        end
        @test length(held.chains) == 8                      # the held generation never grew
        @test all(held.chains[("GET", "/seed$i")](nothing) == "seed$i" for i in 1:8)
        @test length((@atomic c.state).chains) == 208
    end
end
end


@testitem "Chain cache — concurrent warmup through compose" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Random: randperm
using Nitro
import Nitro: App

# Drives the real `compose` (src/routerhof.jl) on a LOCAL App and ONE composed pipeline — the
# `serve` shape, where the pipeline and so its `ChainCache` live for the server's lifetime. Each
# `internalrequest` builds a new pipeline with a cold cache (#255), so it cannot show a warm one.
#
# The cache is observed through behavior, not by reaching into it: a chain is composed only on a
# cache miss, and composing calls each middleware FACTORY once — so factory calls count builds.
#
# Scope, stated accurately: a FUNCTIONAL test of the key→chain mapping and of the cache being
# reached — NOT a race test. `@async` tasks are sticky to the spawning thread, so no reader
# overlaps a writer here. The real race is in the unit item above, under `Threads.@spawn`.

const K = 24        # distinct routes — enough to exercise many keys, not a race parameter
const M = 4         # requests per route

builds = zeros(Int, K)
function tagging_middleware(i::Int)
    tag = "route-$i"
    return function (handler)
        builds[i] += 1
        yield()                                         # interleave misses during warmup
        return function (req::HTTP.Request)
            yield()
            inner = handler(req)                        # router + serializer for this route
            return Res.send(tag * "|" * text(inner))    # NEW response; never mutate `inner`
        end
    end
end

ctx = App()
Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
    path("/warm/$i", (req::HTTP.Request) -> Res.send("handler-$i"),
         middleware = [tagging_middleware(i)])
    for i in 1:K
])

# `catch_errors=false` is deliberate: any error in the chain propagates instead of being
# laundered into a 500 that the body assertions would then (wrongly) explain.
pipeline = Nitro.Core.setupmiddleware(ctx; catch_errors=false)

targets  = [(i, "/warm/$i") for i in 1:K for _ in 1:M]
shuffled = targets[randperm(length(targets))]           # interleave misses with hits
results = Vector{String}(undef, length(shuffled))
@sync for (n, (_, target)) in enumerate(shuffled)
    @async begin
        r = pipeline(HTTP.Request("GET", target))
        results[n] = "$(r.status)|$(text(r))"
    end
end

@testset "every request got its own route's chain" begin
    # A mis-keyed read serves route A's chain for route B — visible here as a body mismatch.
    @test all(results[n] == "200|route-$(shuffled[n][1])|handler-$(shuffled[n][1])"
              for n in eachindex(shuffled))
end

@testset "warmup converges: every route built, and no further builds once warm" begin
    # Concurrent misses on one route may each build (the factory yields between the miss and the
    # publish), so the warmup count is at least one per route, not exactly one.
    @test all(>=(1), builds)
    warm = copy(builds)
    for _ in 1:M, i in 1:K
        @test text(pipeline(HTTP.Request("GET", "/warm/$i"))) == "route-$i|handler-$i"
    end
    @test builds == warm
end

@testset "one composed pipeline re-reads its cache on every request" begin
    # Guards `compose`'s NOTEs: the cache must be created per pipeline and consulted PER REQUEST.
    # A cache that is never read, or never written, has no functional symptom — just a permanent
    # rebuild on every request, which is #255's symptom.
    factory_calls = Ref(0)
    counting_mw = handler -> (factory_calls[] += 1; req -> handler(req))

    ctx2 = App()
    Nitro.Core.Routing.urlpatterns(ctx2, "", Nitro.RouteDefinition[
        path("/once", (req::HTTP.Request) -> Res.send("ok"), middleware = [counting_mw])
    ])
    p = Nitro.Core.setupmiddleware(ctx2; catch_errors=false)
    for _ in 1:5
        @test text(p(HTTP.Request("GET", "/once"))) == "ok"
    end
    @test factory_calls[] == 1
end

@testset "...and so does one WITH global middleware (#255)" begin
    # THE #255 assertion. Global middleware used to switch the cache off (`use_cache =
    # isempty(globalmiddleware)`), because the `App`-wide cache had no way to key on it, so this
    # pipeline composed its chain on every request, forever: 5 here, on unpatched main. That is
    # every `serve(middleware = [...])` app with per-route middleware, and every
    # `revise=:lazy|:eager` session (serve injects `ReviseHandler`).
    factory_calls = Ref(0)
    counting_mw = handler -> (factory_calls[] += 1; req -> handler(req))
    global_mw   = handler -> (req::HTTP.Request -> handler(req))

    ctx3 = App()
    Nitro.Core.Routing.urlpatterns(ctx3, "", Nitro.RouteDefinition[
        path("/g", (req::HTTP.Request) -> Res.send("ok"), middleware = [counting_mw])
    ])
    p = Nitro.Core.setupmiddleware(ctx3; middleware = [global_mw], catch_errors=false)
    for _ in 1:5
        @test text(p(HTTP.Request("GET", "/g"))) == "ok"
    end
    @test factory_calls[] == 1
end

@testset "two pipelines on one App do not share chains" begin
    # Each pipeline's chains close over its own global middleware. Sharing a cache between these
    # two would serve one pipeline's global layer to the other — the key-completeness failure
    # #79 was, with global middleware in place of the serializer settings.
    ctx4 = App()
    Nitro.Core.Routing.urlpatterns(ctx4, "", Nitro.RouteDefinition[
        path("/s", (req::HTTP.Request) -> Res.send("h"),
             middleware = [h -> (req::HTTP.Request -> h(req))])
    ])
    wrap(tag) = h -> (req::HTTP.Request -> Res.send(tag * "|" * text(h(req))))
    pa = Nitro.Core.setupmiddleware(ctx4; middleware = [wrap("A")], catch_errors=false)
    pb = Nitro.Core.setupmiddleware(ctx4; middleware = [wrap("B")], catch_errors=false)
    for _ in 1:2
        @test text(pa(HTTP.Request("GET", "/s"))) == "A|h"
        @test text(pb(HTTP.Request("GET", "/s"))) == "B|h"
    end
end
end


@testitem "Chain cache — a client-chosen method cannot grow the cache" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
import Nitro: App, path, text

# Found in review of #255. The chain key carries a method, and some leaves match ANY method
# token. Caching under every token a client sends would grow a pipeline's cache without bound,
# each insert copying the whole generation. So the key's method must be one the client cannot
# choose:
#
#   * a `"*"` route is a `DeclaredMethodHandler` leaf (#282) and keys on `"*"` — one chain,
#     whatever the request says;
#   * a bare leaf that matches any token keys on `req.method`, so only methods Nitro knows are
#     cached, and anything else is composed for that one request.
#
# Observed through a counting GLOBAL factory: `compose` calls it once to prebuild the unmatched
# chain, then once per chain composition.

folds = Ref(0)
counting_global = handler -> (folds[] += 1; req::HTTP.Request -> handler(req))

ctx = App()
Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
    path("/any", (req::HTTP.Request) -> Res.send("any"), method = "*"),
    # Some route must carry middleware, or every request takes the empty-table fast path.
    path("/mw", (req::HTTP.Request) -> Res.send("mw"), middleware = [h -> (r::HTTP.Request -> h(r))]),
])
# A bare any-method leaf, registered on the router directly so no `DeclaredMethodHandler` wraps
# it — the shape the method guard exists for.
HTTP.register!(ctx.service.router, "*", "/raw", (req::HTTP.Request) -> HTTP.Response(200, "raw"))
p = Nitro.Core.setupmiddleware(ctx; middleware = [counting_global], catch_errors = false)
@test folds[] == 1

@testset "a \"*\" route caches ONE chain for every method token" begin
    for _ in 1:2, i in 1:5
        @test text(p(HTTP.Request("X-JUNK-$i", "/any"))) == "any"
    end
    @test text(p(HTTP.Request("POST", "/any"))) == "any"
    @test folds[] == 1 + 1              # keyed on the declared "*", not on what was sent
end

@testset "a bare any-method leaf never caches an unknown method" begin
    before = folds[]
    for _ in 1:2, i in 1:5
        @test text(p(HTTP.Request("X-JUNK-$i", "/raw"))) == "raw"
    end
    @test folds[] == before + 10        # composed per request, never retained
end

@testset "...but still caches a known one" begin
    before = folds[]
    for _ in 1:3
        @test text(p(HTTP.Request("POST", "/raw"))) == "raw"
    end
    @test folds[] == before + 1
end
end


@testitem "Chain cache — pipeline settings stay with their pipeline (#79)" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
import Nitro: App, path, text

# Regression test for #79. A cached chain closes over `handler` — the fold accumulator, which is
# `DefaultSerializer(catch_errors; show_errors)` wrapping the router — so those settings are baked
# into it. When the cache lived on `ctx.service` and was keyed on the route alone, the FIRST
# pipeline to warm a route won permanently and every later pipeline's kwargs were silently
# ignored. #79 put the settings in the key (`cachetag`); #255 made the cache per pipeline, so a
# chain can only ever be served to the pipeline whose settings it baked in. The assertions below
# are about behavior and hold for either mechanism.

mw() = handler -> (req::HTTP.Request -> handler(req))

@testset "a later internalrequest's catch_errors is honoured" begin
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/boom", (req::HTTP.Request) -> error("kaboom"), middleware = [mw()]),
    ])
    # Warm the route with catch_errors = true: the thrown error is laundered into a 500.
    r = Nitro.Core.internalrequest(ctx, HTTP.Request("GET", "/boom"); catch_errors = true)
    @test r.status == 500
    # Against the pre-#79 code this returns a 500 too: the first call's chain was reused.
    @test_throws Exception Nitro.Core.internalrequest(ctx, HTTP.Request("GET", "/boom");
                                                      catch_errors = false)
end

@testset "two warm pipelines with different settings keep their own" begin
    # The `serve`-shaped form: both pipelines are built once and warmed, then interleaved.
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/boom", (req::HTTP.Request) -> error("kaboom"), middleware = [mw()]),
    ])
    catching = Nitro.Core.setupmiddleware(ctx; catch_errors = true)
    raising  = Nitro.Core.setupmiddleware(ctx; catch_errors = false)
    for _ in 1:2
        @test catching(HTTP.Request("GET", "/boom")).status == 500
        @test_throws Exception raising(HTTP.Request("GET", "/boom"))
    end
end

@testset "registration reaches every pipeline's cached chain" begin
    # #250's acceptance: invalidation must reach a route's chain in EVERY pipeline, with a test
    # that fails if it silently reaches none. Two warm pipelines with different settings, one
    # re-registration, and both must run the new middleware — against an invalidation that
    # matched nothing, both keep answering "h".
    builds = Ref(0)
    counted = handler -> (builds[] += 1; req::HTTP.Request -> handler(req))
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/other", (req::HTTP.Request) -> Res.send("o"), middleware = [mw()]),
        path("/v", (req::HTTP.Request) -> Res.send("h"), middleware = [counted]),
    ])
    p1 = Nitro.Core.setupmiddleware(ctx; catch_errors = true)
    p2 = Nitro.Core.setupmiddleware(ctx; catch_errors = false)
    for _ in 1:2
        @test text(p1(HTTP.Request("GET", "/v"))) == "h"
        @test text(p2(HTTP.Request("GET", "/v"))) == "h"
    end
    @test builds[] == 2              # one per pipeline: both are warm before the registration

    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/v", (req::HTTP.Request) -> Res.send("h"),
             middleware = [handler -> (req::HTTP.Request -> Res.send("late|" * text(handler(req))))]),
    ])
    @test text(p1(HTTP.Request("GET", "/v"))) == "late|h"
    @test text(p2(HTTP.Request("GET", "/v"))) == "late|h"
    @test text(p1(HTTP.Request("GET", "/other"))) == "o"     # other routes still resolve
end

@testset "routes whose paths share a prefix never share a chain" begin
    # Security-relevant: a route path may itself contain `|`, the separator in the route key. If
    # `/a` and `/a|x` ever shared a cache entry, one route's chain — and so its guards — would be
    # served for the other.
    ctx = App()
    tagged(tag) = h -> (req::HTTP.Request -> Res.send(tag * "|" * text(h(req))))
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/a", (req::HTTP.Request) -> Res.send("plain"), middleware = [tagged("A")]),
        path("/a|x", (req::HTTP.Request) -> Res.send("pipe"), middleware = [tagged("AX")]),
    ])
    p = Nitro.Core.setupmiddleware(ctx; catch_errors = false)
    for _ in 1:2
        @test text(p(HTTP.Request("GET", "/a"))) == "A|plain"
        @test text(p(HTTP.Request("GET", "/a|x"))) == "AX|pipe"
    end
end
end # @testitem
