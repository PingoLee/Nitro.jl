@testitem "cache_if_current! — refuses a chain built from a superseded table" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using Nitro.Core.Types: CopyOnWriteDict, snapshot, cache!, cache_if_current!, publish!, delete!

# Unit half of #81. `middleware_cache` is first-writer-wins, so a chain published from a
# `custommiddleware` snapshot that route registration has since replaced is not merely stale —
# it is PERMANENT. `publish_route_middleware!`'s publish-then-invalidate ordering narrowed that
# window but could not close it, because the `delete!` no-ops on a key the racing request has
# not written yet:
#
#   req: cache read                        -> miss
#   req: snapshot(custommiddleware)        -> OLD table
#   reg: publish!(custommiddleware, ...)
#   reg: delete!(middleware_cache, key)    -> key absent, no-op
#   req: cache!(middleware_cache, key, ..) -> stale chain, first-writer-wins, permanent
#
# The generation stamp is the source table's own IDENTITY — every write release-stores a freshly
# allocated `Dict`, and the reader still holds the old one, so its address cannot be reused.

mkf(tag) = (req -> tag)

@testset "unchanged source publishes" begin
    src   = CopyOnWriteDict{Tuple}();    publish!(src, "GET|/a", (nothing, Function[]))
    cache = CopyOnWriteDict{Function}()
    snap  = snapshot(src)
    @test cache_if_current!(cache, "GET|/a", mkf("fresh"), src, snap)
    @test haskey(snapshot(cache), "GET|/a")
end

@testset "source moved between snapshot and publish — refuses" begin
    src   = CopyOnWriteDict{Tuple}();    publish!(src, "GET|/a", (nothing, Function[]))
    cache = CopyOnWriteDict{Function}()
    snap  = snapshot(src)                       # what the chain would have been built from

    publish!(src, "GET|/a", (nothing, Function[mkf("mw")]))   # registration lands here

    # Against `cache!` this publishes and first-writer-wins makes it permanent.
    @test cache_if_current!(cache, "GET|/a", mkf("stale"), src, snap) == false
    @test isempty(snapshot(cache))

    # ...and the next request, snapshotting afresh, caches the correct chain.
    @test cache_if_current!(cache, "GET|/a", mkf("fresh"), src, snapshot(src))
    @test snapshot(cache)["GET|/a"](nothing) == "fresh"
end

@testset "a delete! elsewhere in the source also counts as movement" begin
    # Conservative on purpose: any write to the source invalidates the stamp, not just a write
    # to this key. Refusing to cache is always safe; caching something stale never is.
    src   = CopyOnWriteDict{Tuple}()
    publish!(src, "GET|/a", (nothing, Function[]))
    publish!(src, "GET|/b", (nothing, Function[]))
    cache = CopyOnWriteDict{Function}()
    snap  = snapshot(src)
    delete!(src, "GET|/b")
    @test cache_if_current!(cache, "GET|/a", mkf("x"), src, snap) == false
end

@testset "first-writer-wins is preserved" begin
    src   = CopyOnWriteDict{Tuple}();    publish!(src, "GET|/a", (nothing, Function[]))
    cache = CopyOnWriteDict{Function}()
    snap  = snapshot(src)
    @test cache_if_current!(cache, "GET|/a", mkf("first"), src, snap)
    @test cache_if_current!(cache, "GET|/a", mkf("second"), src, snap) == false
    @test snapshot(cache)["GET|/a"](nothing) == "first"      # identity never changes under a reader
end

@testset "delete! takes the lock even when the key is absent" begin
    # The invariant #81's proof rests on. A lock-free `haskey` pre-check in `delete!` would
    # silently reopen the race with no symptom, so pin the observable consequence: a `delete!`
    # of an absent key must still serialize against a concurrent publish rather than skipping
    # the critical section entirely.
    cache = CopyOnWriteDict{Function}()
    lock(cache.lock)                                  # hold it from this task
    try
        t = Threads.@spawn delete!($cache, "GET|/never-present")
        # Started, so "not done" below means BLOCKED, not "never scheduled" — otherwise this
        # negative-within-a-timeout could pass for the wrong reason.
        @test timedwait(() -> istaskstarted(t), 5.0) === :ok
        # Blocked on the lock we hold: if `delete!` short-circuited before locking it would
        # already be done.
        @test timedwait(() -> istaskdone(t), 0.5) === :timed_out
    finally
        unlock(cache.lock)
    end
end
end # @testitem


@testitem "compose — a chain built from a superseded table is never cached" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core.Types: snapshot, publish!
using Nitro.Core.RouterHOF: genkey, cachetag
import Nitro: ServerContext, path, text

const TAG = cachetag(false, true, true)   # catch_errors=false, show_errors/serialize default

# Integration half of #81, driven through the real `compose` on a LOCAL ServerContext so the
# item is order-independent. Reproducing the interleaving with real threads would be a flake
# generator; instead the straddle is constructed DETERMINISTICALLY, by exploiting where the
# window actually is.
#
# `buildmiddleware` snapshots `custommiddleware`, then `foldlayers` *calls* each middleware
# factory to build the chain. A factory that performs the registration when it is invoked
# therefore lands exactly inside the window: after this request's snapshot, before its publish.
#
#   req: custom_snap = snapshot(custommiddleware)   -> T0 (v1)
#   req: buildmiddleware -> folds -> CALLS the factory below
#   reg:     publish!(custommiddleware, key, v2)    -> T1     <- inside the window
#   reg:     delete!(middleware_cache, key)         -> absent, no-op
#   req: publish the chain                          -> built from T0, i.e. stale
#
# With `cache!` that stale v1 chain wins forever (first-writer-wins) and the v2 middleware
# never runs again — #71's symptom, reached through the cache. `cache_if_current!` sees T1 !== T0
# and declines, so the next request rebuilds and caches v2.
#
# Reachability preconditions, both required and both satisfied here: `use_cache` must be true
# (no global middleware at all, hence no `middleware=` kwarg) and registration must race a live
# request.

ctx = ServerContext()
key = genkey("GET", "/warm")

v2_layer = handler -> (req::HTTP.Request -> text("v2|" * text(handler(req))))

# Fires once, during chain construction — this IS the racing registration.
registered = Ref(false)
v1_layer = function (handler)
    if !registered[]
        registered[] = true
        publish!(ctx.service.custommiddleware, key, (nothing, Function[v2_layer]))
    end
    return (req::HTTP.Request -> text("v1|" * text(handler(req))))
end

Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
    path("/warm", (req::HTTP.Request) -> text("handler"), middleware = [v1_layer]),
])

pipeline = Nitro.Core.setupmiddleware(ctx; catch_errors = false)
@test isempty(snapshot(ctx.service.middleware_cache))     # cold going in

old_snap = snapshot(ctx.service.custommiddleware)
r1 = text(pipeline(HTTP.Request("GET", "/warm")))
@test registered[]                                        # the straddle actually happened
@test snapshot(ctx.service.custommiddleware) !== old_snap # ...and it moved the table

# The in-flight request legitimately finishes against the generation it started with.
@test r1 == "v1|handler"

@testset "the freshly registered middleware runs, and keeps running" begin
    # THE assertion. Against `cache!` the stale v1 chain is stranded first-writer-wins and every
    # one of these returns "v1|handler" forever.
    for _ in 1:3
        @test text(pipeline(HTTP.Request("GET", "/warm"))) == "v2|handler"
    end
    # Cache keys carry the pipeline's serializer settings since #79 ("|cES" here).
    # `haskey`, not `isa Function`: the table is a `CopyOnWriteDict{Function}`, so an `isa`
    # check on the value is true of anything it could possibly hold.
    @test haskey(snapshot(ctx.service.middleware_cache), key * TAG)   # it did converge
end

@testset "warmup still caches on the quiet path" begin
    # Guards the obvious over-correction: refusing to publish whenever anything raced must not
    # become refusing to publish at all. With no concurrent registration the cache fills.
    ctx2 = ServerContext()
    Nitro.Core.Routing.urlpatterns(ctx2, "", Nitro.RouteDefinition[
        path("/quiet", (req::HTTP.Request) -> text("ok"),
             middleware = [handler -> (req::HTTP.Request -> handler(req))]),
    ])
    quiet = Nitro.Core.setupmiddleware(ctx2; catch_errors = false)
    quiet(HTTP.Request("GET", "/quiet"))
    @test haskey(snapshot(ctx2.service.middleware_cache), genkey("GET", "/quiet") * TAG)
end
end # @testitem
