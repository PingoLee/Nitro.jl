@testitem "compose — a request never runs a half-built chain" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core.Types: snapshot, publish!, RouteChainRecord, RouteEndpoint, ROUTE_RESOLUTION_KEY
using Nitro.Core.RouterHOF: genkey
import Nitro: App, path, text

# Integration coverage for #81, driven through the real `compose` on a LOCAL App so the item is
# order-independent. The unit half — `cached_chain`'s generation check — is in
# test/middleware_cache_tests.jl.
#
# What #81 guards: a request racing a registration runs either the route's old chain or its new
# one, whole, and never a chain that disagrees with the middleware entry it was served under.
# Before #81 a chain composed from a superseded table was cached and served forever; #255 closed
# that at read time, by serving a chain only to requests holding the exact table it was built
# from.
#
# Since #718 a route's chain is folded once, AT REGISTRATION (`publish_route_middleware!`), so
# the window moved there. A registration folds the chain, then publishes it to `route_chains` and
# the entry to `custommiddleware`, both under `route_chains_lock`. That leaves two windows, and
# each is straddled DETERMINISTICALLY below rather than raced with real threads, which would be a
# flake generator:
#
#   1. inside the fold, before either publish: a factory of the NEW chain serves a request;
#   2. between the two publishes: the test holds the lock with the chain published and the entry
#      not yet, and a request must wait for the entry rather than run the chain without it.

key = genkey("GET", "/warm")
tagged(tag) = handler -> (req::HTTP.Request -> Res.send(tag * "|" * text(handler(req))))

# `global_mw` is `nothing` or one pass-through global layer, so each straddle runs on both
# pipeline shapes, which cached differently before #255.
for (label, global_mw) in (("no global middleware", nothing),
                           ("with global middleware (#255)", h -> (req::HTTP.Request -> h(req))))
    @testset "$label: a request inside a registration's fold runs the old chain, whole" begin
        ctx = App()
        Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
            path("/warm", (req::HTTP.Request) -> Res.send("handler"), middleware = [tagged("v1")]),
        ])
        mw = isnothing(global_mw) ? [] : [global_mw]
        pipeline = Nitro.Core.setupmiddleware(ctx; middleware = mw, catch_errors = false)
        @test text(pipeline(HTTP.Request("GET", "/warm"))) == "v1|handler"

        # The v2 factory serves requests while registration is folding v2: neither table has moved
        # yet, so each is a v1 request from start to end. Through the warm pipeline (a cache hit)
        # and through a cold one, which has to look the chain up and so reads both tables.
        cold = Nitro.Core.setupmiddleware(ctx; middleware = mw, catch_errors = false)
        inside, inside_cold = Ref(""), Ref("")
        v2_folds = Ref(0)
        v2 = function (handler)
            v2_folds[] += 1
            inside[] = text(pipeline(HTTP.Request("GET", "/warm")))
            inside_cold[] = text(cold(HTTP.Request("GET", "/warm")))
            return tagged("v2")(handler)
        end
        Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
            path("/warm", (req::HTTP.Request) -> Res.send("handler"), middleware = [v2]),
        ])
        @test inside[] == "v1|handler"
        @test inside_cold[] == "v1|handler"

        # Once registration returns, every request runs v2, from this pipeline's cache or not.
        for _ in 1:3
            @test text(pipeline(HTTP.Request("GET", "/warm"))) == "v2|handler"
        end
        @test v2_folds[] == 1                  # folded once, at registration, never per request
    end

    @testset "$label: a request between the two publishes waits for the entry" begin
        ctx = App()
        Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
            path("/warm", (req::HTTP.Request) -> Res.send("handler"), middleware = [tagged("v1")]),
        ])
        mw = isnothing(global_mw) ? [] : [global_mw]
        # A cold pipeline, so the request has to look its chain up rather than take a cached one.
        pipeline = Nitro.Core.setupmiddleware(ctx; middleware = mw, catch_errors = false)

        # `publish_route_middleware!`'s critical section, cut in half: the v2 chain is published,
        # its entry is not, and the lock is held, as a registration would hold it.
        v2_entry = (nothing, Function[tagged("v2")])
        v2_chain = RouteEndpoint(Nitro.Core.RouterHOF.buildmiddleware(v2_entry,
                                     Nitro.Core.Types.RouteNext(ctx.service.router)))
        lock(ctx.service.route_chains_lock)
        req = HTTP.Request("GET", "/warm")
        local served
        try
            publish!(ctx.service.route_chains, key, RouteChainRecord(v2_entry, v2_chain))
            served = @async text(pipeline(req))
            # It reaches the lock and waits there. (Running the v2 chain under the v1 entry, or v1's
            # under v2's, would instead have finished.) The waiter count makes the wait observable,
            # so this cannot pass by the task simply not having run yet.
            lk = ctx.service.route_chains_lock
            @test timedwait(() -> !isempty(lk.cond_wait.waitq), 10.0) === :ok
            @test !istaskdone(served)
            publish!(ctx.service.custommiddleware, key, v2_entry)
        finally
            unlock(ctx.service.route_chains_lock)
        end
        @test fetch(served) == "v2|handler"
        # ...and the stash it ran under names the same generation as the chain.
        @test req.context[ROUTE_RESOLUTION_KEY].table[key] === v2_entry
    end
end

@testset "an entry published without its chain is refused, not spun on" begin
    # Point 6 of #718's review: `publish!` straight into `custommiddleware` skips the chain table.
    # The first version of the lookup retried forever on that; it is refused with a 500 now.
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/warm", (req::HTTP.Request) -> Res.send("handler"), middleware = [tagged("v1")]),
    ])
    publish!(ctx.service.custommiddleware, key, (nothing, Function[tagged("raw")]))
    pipeline = Nitro.Core.setupmiddleware(ctx; catch_errors = false)
    served = @async Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
        pipeline(HTTP.Request("GET", "/warm"))
    end
    @test timedwait(() -> istaskdone(served), 30.0) === :ok
    @test fetch(served).status == 500
end

@testset "warmup still caches on the quiet path" begin
    # Guards the obvious over-correction: with no concurrent registration, nothing folds again.
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
