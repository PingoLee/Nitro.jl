@testitem "compose — a chain built from a superseded table is never served" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core.Types: snapshot, publish!
using Nitro.Core.RouterHOF: genkey
import Nitro: App, path, text

# Integration coverage for #81, driven through the real `compose` on a LOCAL App so the item is
# order-independent. The unit half — `cached_chain`'s generation check — is in
# test/middleware_cache_tests.jl.
#
# The window: a request composes its chain from one `custommiddleware` snapshot while a
# registration publishes a newer table. Before #81 that stale chain was cached first-writer-wins
# and served forever — registered middleware that silently never runs. #81 closed it with a
# lock-ordered re-check at publish time; #255 closes it at READ time instead, by serving a chain
# only to requests holding the exact table it was built from. Either way these must hold.
#
# Reproducing the interleaving with real threads would be a flake generator; the straddle is
# constructed DETERMINISTICALLY instead. `buildmiddleware` composes from the request's snapshot,
# and `foldlayers` *calls* each middleware factory while doing so — so a factory that performs
# the registration when invoked lands exactly inside the window:
#
#   req: custom_snap = snapshot(custommiddleware)   -> T0 (v1)
#   req: buildmiddleware -> folds -> CALLS the factory below
#   reg:     publish!(custommiddleware, key, v2)    -> T1     <- inside the window
#   req: cache_chain!(…, T0, …)                     -> built from T0, i.e. stale

# `global_mw` is `nothing` or one pass-through global layer, so the straddle runs on both
# pipeline shapes. The second was uncached before #255, so the window did not exist there; now it
# is cached, and must be exactly as safe.
function straddle(global_mw)
    ctx = App()
    key = genkey("GET", "/warm")
    v2_builds = Ref(0)
    v2_layer = function (handler)
        v2_builds[] += 1
        return (req::HTTP.Request -> Res.send("v2|" * text(handler(req))))
    end
    registered = Ref(false)
    v1_layer = function (handler)             # fires once, during chain construction
        if !registered[]
            registered[] = true
            publish!(ctx.service.custommiddleware, key, (nothing, Function[v2_layer]))
        end
        return (req::HTTP.Request -> Res.send("v1|" * text(handler(req))))
    end
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/warm", (req::HTTP.Request) -> Res.send("handler"), middleware = [v1_layer]),
    ])
    mw = isnothing(global_mw) ? [] : [global_mw]
    pipeline = Nitro.Core.setupmiddleware(ctx; middleware = mw, catch_errors = false)
    old_snap = snapshot(ctx.service.custommiddleware)
    r1 = text(pipeline(HTTP.Request("GET", "/warm")))
    return (; ctx, pipeline, r1, registered, v2_builds, moved = snapshot(ctx.service.custommiddleware) !== old_snap)
end

for (label, global_mw) in (("no global middleware", nothing),
                           ("with global middleware (#255)", h -> (req::HTTP.Request -> h(req))))
    @testset "$label" begin
        s = straddle(global_mw)
        @test s.registered[]                   # the straddle actually happened
        @test s.moved                          # ...and it moved the table
        # The in-flight request legitimately finishes against the generation it started with.
        @test s.r1 == "v1|handler"

        # THE assertion. Were the stale v1 chain served, every one of these would be "v1|handler".
        for _ in 1:3
            @test text(s.pipeline(HTTP.Request("GET", "/warm"))) == "v2|handler"
        end
        # ...and it converged: the v2 chain was composed once, then served from the cache.
        @test s.v2_builds[] == 1
    end
end

@testset "warmup still caches on the quiet path" begin
    # Guards the obvious over-correction: declining stale publishes must not become declining
    # every publish. With no concurrent registration the chain is built once.
    builds = Ref(0)
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/quiet", (req::HTTP.Request) -> Res.send("ok"),
             middleware = [handler -> (builds[] += 1; req::HTTP.Request -> handler(req))]),
    ])
    quiet = Nitro.Core.setupmiddleware(ctx; catch_errors = false)
    for _ in 1:3
        @test text(quiet(HTTP.Request("GET", "/quiet"))) == "ok"
    end
    @test builds[] == 1
end
end # @testitem
