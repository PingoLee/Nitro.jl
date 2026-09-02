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
# lifecycle Set, and `setupmiddleware` called it — from `serve`
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
    @test isempty(ctx.service.route_lifecycle)
    @test isempty(ctx.service.serve_lifecycle)
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
    # Route-owned: every caller of `process_middleware` is a route-registration path (#82).
    @test lf in ctx.service.route_lifecycle
    @test isempty(ctx.service.serve_lifecycle)
end

@testset "route and HOF registration paths register" begin
    lf, _, _, _ = counting_lifecycle()
    ctx = ServerContext()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/y", (req::HTTP.Request) -> text("ok"), middleware = [lf])
    ])
    @test lf in ctx.service.route_lifecycle

    lf2, _, _, _ = counting_lifecycle()
    ctx2 = ServerContext()
    Nitro.Core.router(ctx2, "/hof"; middleware = [lf2])
    @test lf2 in ctx2.service.route_lifecycle
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
    @test length(ctx.service.route_lifecycle) == 1
end

@testset "route ownership wins over serve ownership (#82)" begin
    # A single object handed both to a route and to `serve(middleware = ...)` must start
    # ONCE per cycle, not twice — and it must land on the half that survives `terminate`.
    lf, _, _, _ = counting_lifecycle()
    ctx = ServerContext()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/shared", (req::HTTP.Request) -> text("ok"), middleware = [lf]),
    ])
    Nitro.Core.RouterHOF.register_serve_lifecycle!(ctx, Any[lf])
    @test lf in ctx.service.route_lifecycle
    @test isempty(ctx.service.serve_lifecycle)
end

@testset "...and in the other direction too — serve first, then route" begin
    # The direction the guard above cannot see. `serve` runs first, then a runtime
    # `include_routes`/Revise re-registration claims the same object for a route. Without a
    # promoting guard on the route side it lands in BOTH halves, and `terminate` calls its
    # `on_shutdown` twice in a single cycle — once per half.
    lf, _, _, _ = counting_lifecycle()
    ctx = ServerContext()
    Nitro.Core.RouterHOF.register_serve_lifecycle!(ctx, Any[lf])
    @test lf in ctx.service.serve_lifecycle

    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/late", (req::HTTP.Request) -> text("ok"), middleware = [lf]),
    ])

    @test lf in ctx.service.route_lifecycle
    @test lf ∉ ctx.service.serve_lifecycle          # promoted out, not duplicated
    # The assertion that matters: exactly one registration across both halves, so exactly one
    # on_startup and one on_shutdown per cycle.
    @test count(==(lf), [ctx.service.route_lifecycle; ctx.service.serve_lifecycle]) == 1
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

@test lf in ctx.service.serve_lifecycle
@test started[] == 1
@test stopped[] == 0

Nitro.Core.terminate(ctx)
@test stopped[] == 1
@test isempty(ctx.service.serve_lifecycle)
end


@testitem "Lifecycle middleware — route-owned hooks survive a serve/terminate cycle" tags=[:middleware, :network] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core: LifecycleMiddleware
import Nitro: ServerContext, path, text

# Regression test for #82. `terminate()` used to `empty!` a single `lifecycle_middleware` Set
# that held two kinds of member with different lifetimes. Emptying is right for the
# serve-owned half (from `serve(middleware = ...)`, re-added on every `serve`) and wrong for
# the route-owned half (from `urlpatterns()`, added once and never re-added) — so after
# `serve(); terminate(); serve()` every route-level `on_startup` was silently skipped for the
# rest of the process's life. For a route-level `RateLimiter` that meant its bucket-pruning
# task never restarted while the limiter kept recording every request: an unbounded leak in
# the component whose entire job is to bound resource use.
#
# Against the unpatched code `started[] == 1` here, not 2.

function counting_lifecycle()
    started, stopped = Ref(0), Ref(0)
    lf = LifecycleMiddleware(
        middleware  = handler -> (req::HTTP.Request -> handler(req)),
        on_startup  = () -> (started[] += 1),
        on_shutdown = () -> (stopped[] += 1))
    return lf, started, stopped
end

_serve(ctx, port) = Nitro.Core.serve(ctx; host = HOST, port = port, async = true,
                                     show_banner = false, show_errors = false,
                                     access_log = nothing)

@testset "route-level on_startup re-fires on the second serve()" begin
    lf, started, stopped = counting_lifecycle()
    ctx = ServerContext()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/limited", (req::HTTP.Request) -> text("ok"), middleware = [lf])
    ])
    @test lf in ctx.service.route_lifecycle

    _serve(ctx, get_free_port())
    @test timedwait(() -> Base.isopen(ctx.service), 10.0) === :ok
    @test started[] == 1
    Nitro.Core.terminate(ctx)
    @test stopped[] == 1

    # The whole point: route registration is NOT repeated, so the entry has to have survived.
    @test lf in ctx.service.route_lifecycle

    _serve(ctx, get_free_port())
    @test timedwait(() -> Base.isopen(ctx.service), 10.0) === :ok
    @test started[] == 2
    Nitro.Core.terminate(ctx)
    @test stopped[] == 2
end

@testset "serve-owned hooks do NOT accumulate across cycles" begin
    # The other half, and why "just delete the empty!" is the wrong fix: a serve-owned entry
    # belongs to its own `serve()` call, so a later `serve(middleware=[B])` must not also
    # start `A`.
    lfa, started_a, _ = counting_lifecycle()
    lfb, started_b, _ = counting_lifecycle()
    ctx = ServerContext()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/health", (req::HTTP.Request) -> text("ok"))
    ])

    Nitro.Core.serve(ctx; middleware = [lfa], host = HOST, port = get_free_port(),
                     async = true, show_banner = false, show_errors = false,
                     access_log = nothing)
    @test timedwait(() -> Base.isopen(ctx.service), 10.0) === :ok
    @test started_a[] == 1
    Nitro.Core.terminate(ctx)
    @test isempty(ctx.service.serve_lifecycle)

    Nitro.Core.serve(ctx; middleware = [lfb], host = HOST, port = get_free_port(),
                     async = true, show_banner = false, show_errors = false,
                     access_log = nothing)
    @test timedwait(() -> Base.isopen(ctx.service), 10.0) === :ok
    @test started_b[] == 1
    @test started_a[] == 1          # NOT 2 — A belonged to the previous run
    Nitro.Core.terminate(ctx)
end

@testset "shutdown unwinds the reverse of startup" begin
    # startserver runs route-owned then serve-owned; terminate must unwind serve-owned first.
    order = String[]
    mk(name) = LifecycleMiddleware(
        middleware  = handler -> (req::HTTP.Request -> handler(req)),
        on_startup  = () -> push!(order, "up:$name"),
        on_shutdown = () -> push!(order, "down:$name"))

    route_lf, serve_lf = mk("route"), mk("serve")
    ctx = ServerContext()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/o", (req::HTTP.Request) -> text("ok"), middleware = [route_lf])
    ])
    Nitro.Core.serve(ctx; middleware = [serve_lf], host = HOST, port = get_free_port(),
                     async = true, show_banner = false, show_errors = false,
                     access_log = nothing)
    @test timedwait(() -> Base.isopen(ctx.service), 10.0) === :ok
    Nitro.Core.terminate(ctx)

    @test order == ["up:route", "up:serve", "down:serve", "down:route"]
end
end # @testitem


@testitem "RateLimiter — a restart does not leak the previous cleanup task" tags=[:middleware, :slow] setup=[NitroCommon] begin
using Test
using Dates
using Nitro
import Nitro: RateLimiter

# Companion to #82, and a defect the issue body explicitly (and wrongly) ruled out: it claims
# `RateLimiter`'s hooks "are idempotent across cycles". They were not.
#
# `on_shutdown` cannot wait for the cleanup task — it is parked in `sleep(cleanup_period)`,
# up to 10 minutes from its next flag check by default. With a single shared `running` flag:
#
#   on_shutdown : running[] = false ; cleanup_task[] = nothing   (old task still sleeping)
#   on_startup  : running[] = true  ; isnothing(cleanup_task[]) -> spawns a SECOND task
#   old task    : wakes, reads running[] == true, keeps looping
#
# One extra task leaked per restart, unbounded. Before #82 this only bit serve-owned
# limiters; fixing #82 made route-owned ones restart too, which widened it.
#
# The fix is a per-activation token, so a stale task can only ever observe its OWN flag.
# `on_startup`/`on_shutdown` return the `Task` so this is observable at all — against the
# unpatched code `t1` never finishes and the first `timedwait` below times out.

lf = RateLimiter(rate_limit = 5, window = Second(1),
                 cleanup_period = Millisecond(50), cleanup_threshold = Millisecond(50))

t1 = lf.on_startup()
@test t1 isa Task
@test lf.on_startup() === nothing            # idempotent: no second task while one is live

lf.on_shutdown()
t2 = lf.on_startup()
@test t2 isa Task
@test t2 !== t1

# The assertion that fails on the unpatched code: the previous activation's task must exit on
# its next wake, regardless of the new activation having set the flag back to true.
@test timedwait(() -> istaskdone(t1), 10.0) === :ok
@test !istaskdone(t2)                        # ...and the current one is still doing its job

lf.on_shutdown()
@test timedwait(() -> istaskdone(t2), 10.0) === :ok
@test lf.on_shutdown() === nothing            # idempotent: nothing left to stop
end # @testitem


@testitem "Lifecycle middleware — order is registration order, teardown is LIFO" tags=[:middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core: LifecycleMiddleware, startup, shutdown
using Nitro.Core.RouterHOF: register_route_lifecycle!, register_serve_lifecycle!,
                            lifecycle_snapshot
import Nitro: ServerContext, path, text

# Regression test for #74 item 1. `startup.`/`shutdown.` broadcast over a `Set`, which collects
# in HASH order — and `LifecycleMiddleware` is an immutable struct whose fields are closures,
# i.e. heap objects, so the order varied run to run. Nothing depended on it yet, which is
# exactly why it had to be pinned before something did: the first shared resource between two
# lifecycle middlewares (an `AccessLog` sink flushing into something another lifecycle owns)
# makes teardown order decide whether the flush succeeds.
#
# The contract is now LIFO — startup in registration order, shutdown in its exact reverse —
# matching Spring's `SmartLifecycle`, ASP.NET Core's `IHostedService`, OTP supervisors, ASGI
# lifespan, and `defer`/`atexit`.

function recorder()
    order = String[]
    mk(name) = LifecycleMiddleware(
        middleware  = handler -> (req::HTTP.Request -> handler(req)),
        on_startup  = () -> push!(order, "up:$name"),
        on_shutdown = () -> push!(order, "down:$name"))
    return order, mk
end

# NOTE on scope. The two testsets below pin the CONTAINER — that it is ordered, and that the
# order is reproducible — which is #74 item 1's root cause. They do NOT pin `terminate`'s
# reversal, because they supply the `Iterators.reverse` themselves; swapping `src/core.jl` to
# FIFO leaves them green. The assertion that actually pins the teardown contract is
# `order == ["up:route", "up:serve", "down:serve", "down:route"]` in the
# "route-owned hooks survive a serve/terminate cycle" item above, which drives the real
# `serve`/`terminate` — and it is tagged `:network`, so a run filtered away from `:network`
# does not check the teardown order at all.
@testset "the container preserves registration order" begin
    order, mk = recorder()
    a, b, c = mk("a"), mk("b"), mk("c")
    ctx = ServerContext()
    register_route_lifecycle!(ctx, Any[a, b, c])

    route_lf, _ = lifecycle_snapshot(ctx)
    @test route_lf == [a, b, c]                  # a Vector now, and in the order given

    startup.(route_lf)
    shutdown.(Iterators.reverse(route_lf))
    @test order == ["up:a", "up:b", "up:c", "down:c", "down:b", "down:a"]
end

@testset "the order is reproducible across contexts" begin
    # The property a `Set` could not give: hash order depends on object identity, so two
    # structurally-identical runs disagreed. Build the same registration twice and compare.
    runs = map(1:2) do _
        order, mk = recorder()
        ctx = ServerContext()
        register_route_lifecycle!(ctx, Any[mk("a"), mk("b"), mk("c")])
        route_lf, _ = lifecycle_snapshot(ctx)
        startup.(route_lf)
        shutdown.(Iterators.reverse(route_lf))
        order
    end
    @test runs[1] == runs[2]
end

@testset "dedup survives the container change" begin
    # Load-bearing, and the thing a naive Set -> Vector swap regresses silently: one shared
    # `RateLimiter()` on N routes must start its cleanup task once, not N times.
    _, mk = recorder()
    lf = mk("shared")
    ctx = ServerContext()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/p", (req::HTTP.Request) -> text("ok"), middleware = [lf]),
        path("/q", (req::HTTP.Request) -> text("ok"), middleware = [lf]),
        path("/r", (req::HTTP.Request) -> text("ok"), middleware = [lf]),
    ])
    route_lf, _ = lifecycle_snapshot(ctx)
    @test length(route_lf) == 1

    # ...and on the serve-owned side too, including across repeated registration.
    ctx2 = ServerContext()
    register_serve_lifecycle!(ctx2, Any[lf])
    register_serve_lifecycle!(ctx2, Any[lf])
    _, serve_lf = lifecycle_snapshot(ctx2)
    @test length(serve_lf) == 1
end

@testset "concurrent registration neither loses nor duplicates" begin
    # #74 item 2. `register_lifecycle!` did a bare `push!` into a `Set` with no lock on either
    # side, while `startup.`/`shutdown.` broadcast over it. "Registration time" is not a synonym
    # for "single-threaded startup": under `revise=:lazy`, `Revise.revise()` runs on a
    # request-handling task and re-running user top-level code re-enters `urlpatterns` ->
    # `register_route` -> here. Same defect class as #68 item 1.
    _, mk = recorder()
    entries = [mk("m$i") for i in 1:64]
    ctx = ServerContext()

    @sync for e in entries
        Threads.@spawn register_route_lifecycle!(ctx, Any[e])
    end

    route_lf, _ = lifecycle_snapshot(ctx)
    @test length(route_lf) == 64                 # no lost update
    @test Set(route_lf) == Set(entries)
    @test allunique(route_lf)                    # ...and no duplicate

    # Registering the same objects again, concurrently, must still be a no-op.
    @sync for e in entries
        Threads.@spawn register_route_lifecycle!(ctx, Any[e])
    end
    route_lf2, _ = lifecycle_snapshot(ctx)
    @test length(route_lf2) == 64
end

@testset "iteration is taken over a snapshot, not the live vector" begin
    # Guards the other half of the fix: broadcasting over `ctx.service.route_lifecycle`
    # directly would let a concurrent `push!` mutate the array mid-iteration.
    _, mk = recorder()
    ctx = ServerContext()
    register_route_lifecycle!(ctx, Any[mk("a")])
    snap, _ = lifecycle_snapshot(ctx)
    register_route_lifecycle!(ctx, Any[mk("b")])
    @test length(snap) == 1                      # the copy did not grow underneath us
    @test length(lifecycle_snapshot(ctx)[1]) == 2
end
end # @testitem
