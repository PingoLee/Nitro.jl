@testitem "Lifecycle middleware" tags=[:middleware] setup=[NitroCommon] begin
using Suppressor
using Nitro.Core
using Nitro

@testset "LifecycleMiddleware - startup/shutdown hooks" begin
    sflag = Ref(false)
    dflag = Ref(false)

    lf = LifecycleMiddleware(
        middleware = (req->req),
        on_startup  = () -> (sflag[] = true),
        on_shutdown = () -> (dflag[] = true)
    )

    @testset "startup sets on_startup flag" begin
        startup(lf)
        @test sflag[] == true
    end

    @testset "shutdown sets on_shutdown flag" begin
        shutdown(lf)
        @test dflag[] == true
    end
end

@testset "LifecycleMiddleware - error handling case" begin
    sflag2 = Ref(false)
    dflag2 = Ref(false)

    lf2 = LifecycleMiddleware(
        middleware = (req->req),
        on_startup  = () -> begin error("startup boom"); sflag2[] = true end,
        on_shutdown = () -> begin error("shutdown boom"); dflag2[] = true end
    )

    @testset "startup with throwing hook does not rethrow" begin
        try
            @suppress_err begin 
                startup(lf2)
                @test true  # no exception bubbled out
            end
        catch e
            @test false
        end
        @test sflag2[] == false
    end

    @testset "shutdown with throwing hook does not rethrow" begin
        try
            @suppress_err begin 
                shutdown(lf2)
                @test true  # no exception bubbled out
            end
        catch e
            @test false
        end
        @test dflag2[] == false
    end
end

end # @testitem


@testitem "Lifecycle middleware — only registration paths register" tags=[:middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core: LifecycleMiddleware, process_middleware
import Nitro: ServerContext, path, text

# Regression test for #68 item 2. `process_middleware` used to `push!` into the shared
# `ctx.service.lifecycle_middleware` Set, and `setupmiddleware` called it — from `serve`
# once, but from `internalrequest` ON EVERY CALL. That made a per-request path a concurrent
# writer to a Set that `startup.`/`shutdown.` broadcast over (src/core.jl).
#
# The fix is not a lock. `internalrequest` never reaches `startup.` — that lives only in
# `startserver` — so anything it registered got an `on_shutdown` at the next `terminate`
# whose paired `on_startup` had never run. The writer had no business existing, so
# `setupmiddleware` now calls the pure `normalize_middleware` and `serve` registers
# explicitly.

function counting_lifecycle()
    started, stopped, ran = Ref(0), Ref(0), Ref(0)
    lf = LifecycleMiddleware(
        middleware  = handler -> (req::HTTP.Request -> (ran[] += 1; handler(req))),
        on_startup  = () -> (started[] += 1),
        on_shutdown = () -> (stopped[] += 1))
    return lf, started, stopped, ran
end

@testset "internalrequest runs the middleware but registers nothing" begin
    lf, started, stopped, ran = counting_lifecycle()
    ctx = ServerContext()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/x", (req::HTTP.Request) -> text("ok"))
    ])
    for _ in 1:3
        Nitro.Core.internalrequest(ctx, HTTP.Request("GET", "/x");
                                   middleware = [lf], catch_errors = false)
    end
    @test isempty(ctx.service.lifecycle_middleware)
    # The assertion that stops this fix being "just delete the push": the middleware itself
    # must still run on every request, exactly as before.
    @test ran[] == 3
    @test started[] == 0
    @test stopped[] == 0
end

@testset "process_middleware still registers — its contract is unchanged" begin
    lf, _, _, _ = counting_lifecycle()
    ctx = ServerContext()
    processed = process_middleware(ctx, [lf])
    @test length(processed) == 1
    @test processed[1] === lf.middleware
    @test lf in ctx.service.lifecycle_middleware
end

@testset "route and HOF registration paths register" begin
    lf, _, _, _ = counting_lifecycle()
    ctx = ServerContext()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/y", (req::HTTP.Request) -> text("ok"), middleware = [lf])
    ])
    @test lf in ctx.service.lifecycle_middleware

    lf2, _, _, _ = counting_lifecycle()
    ctx2 = ServerContext()
    Nitro.Core.router(ctx2, "/hof"; middleware = [lf2])
    @test lf2 in ctx2.service.lifecycle_middleware
end

@testset "dedup holds — one shared instance across N routes registers once" begin
    # Load-bearing: a single `RateLimiter()` used by several routes must start its cleanup
    # task once, not once per route.
    lf, _, _, _ = counting_lifecycle()
    ctx = ServerContext()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/p", (req::HTTP.Request) -> text("ok"), middleware = [lf]),
        path("/q", (req::HTTP.Request) -> text("ok"), middleware = [lf]),
    ])
    @test length(ctx.service.lifecycle_middleware) == 1
end
end


@testitem "Lifecycle middleware — serve registers and terminate shuts down" tags=[:middleware, :network] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core: LifecycleMiddleware
import Nitro: ServerContext, path, text

# The other half of #68 item 2: moving registration out of `setupmiddleware` must not break
# the path that legitimately needs it. `serve` registers explicitly now, so `on_startup`
# must still fire once and `terminate` must still run `on_shutdown`.

started, stopped = Ref(0), Ref(0)
lf = LifecycleMiddleware(
    middleware  = handler -> (req::HTTP.Request -> handler(req)),
    on_startup  = () -> (started[] += 1),
    on_shutdown = () -> (stopped[] += 1))

ctx = ServerContext()
Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
    path("/health", (req::HTTP.Request) -> text("ok"))
])

port = get_free_port()
Nitro.Core.serve(ctx; middleware = [lf], host = HOST, port = port, async = true,
                 show_banner = false, show_errors = false, access_log = nothing)
@test timedwait(() -> Base.isopen(ctx.service), 10.0) === :ok

@test lf in ctx.service.lifecycle_middleware
@test started[] == 1
@test stopped[] == 0

Nitro.Core.terminate(ctx)
@test stopped[] == 1
@test isempty(ctx.service.lifecycle_middleware)
end
