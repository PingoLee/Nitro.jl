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

    # Both hooks throw an ORDINARY `ErrorException`, which is still logged and swallowed after
    # #185 — only `InterruptException` is deferred. The titles say "ordinary" so they stop
    # implying a claim about every throw; the assertions are unchanged.
    @testset "startup with an ordinary throwing hook does not rethrow" begin
        try
            @suppress_err begin
                startup(lf2)
                @test true  # no exception bubbled out
            end
        catch e
            @test false
        end
        @test sflag2[] == false
        # An ordinary failure must NOT be reported as a deferred interrupt: `catch e; return e`
        # without the `isa` check would turn every failing hook into an aborted server (#185).
        @suppress_err @test startup(lf2) === nothing
    end

    @testset "shutdown with an ordinary throwing hook does not rethrow" begin
        try
            @suppress_err begin
                shutdown(lf2)
                @test true  # no exception bubbled out
            end
        catch e
            @test false
        end
        @test dflag2[] == false
        @suppress_err @test shutdown(lf2) === nothing
    end
end

end # @testitem


@testitem "Lifecycle middleware — only registration paths register" tags=[:middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core: LifecycleMiddleware, process_middleware
import Nitro: App, path, text

# Regression test for #68 item 2. `process_middleware` used to `push!` into the shared
# lifecycle Set, and `setupmiddleware` called it — from `serve`
# once, but from `internalrequest` ON EVERY CALL. That made a per-request path a concurrent
# writer to a Set that `startup.`/`shutdown.` broadcast over (src/core/lifecycle.jl).
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
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/x", (req::HTTP.Request) -> Res.send("ok"))
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
    ctx = App()
    processed = process_middleware(ctx, [lf])
    @test length(processed) == 1
    @test processed[1] === lf.middleware
    # Route-owned: every caller of `process_middleware` is a route-registration path (#82).
    @test lf in ctx.service.route_lifecycle
    @test isempty(ctx.service.serve_lifecycle)
end

@testset "route and HOF registration paths register" begin
    lf, _, _, _ = counting_lifecycle()
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/y", (req::HTTP.Request) -> Res.send("ok"), middleware = [lf])
    ])
    @test lf in ctx.service.route_lifecycle

    lf2, _, _, _ = counting_lifecycle()
    ctx2 = App()
    Nitro.Core.router(ctx2, "/hof"; middleware = [lf2])
    @test lf2 in ctx2.service.route_lifecycle
end

@testset "dedup holds — one shared instance across N routes registers once" begin
    # Load-bearing: a single `RateLimiter()` used by several routes must start its cleanup
    # task once, not once per route.
    lf, _, _, _ = counting_lifecycle()
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/p", (req::HTTP.Request) -> Res.send("ok"), middleware = [lf]),
        path("/q", (req::HTTP.Request) -> Res.send("ok"), middleware = [lf]),
    ])
    @test length(ctx.service.route_lifecycle) == 1
end

@testset "route ownership wins over serve ownership (#82)" begin
    # A single object handed both to a route and to `serve(middleware = ...)` must start
    # ONCE per cycle, not twice — and it must land on the half that survives `terminate`.
    lf, _, _, _ = counting_lifecycle()
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/shared", (req::HTTP.Request) -> Res.send("ok"), middleware = [lf]),
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
    ctx = App()
    Nitro.Core.RouterHOF.register_serve_lifecycle!(ctx, Any[lf])
    @test lf in ctx.service.serve_lifecycle

    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/late", (req::HTTP.Request) -> Res.send("ok"), middleware = [lf]),
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
import Nitro: App, path, text

# The other half of #68 item 2: moving registration out of `setupmiddleware` must not break
# the path that legitimately needs it. `serve` registers explicitly now, so `on_startup`
# must still fire once and `terminate` must still run `on_shutdown`.

started, stopped = Ref(0), Ref(0)
lf = LifecycleMiddleware(
    middleware  = handler -> (req::HTTP.Request -> handler(req)),
    on_startup  = () -> (started[] += 1),
    on_shutdown = () -> (stopped[] += 1))

ctx = App()
Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
    path("/health", (req::HTTP.Request) -> Res.send("ok"))
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
import Nitro: App, path, text

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
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/limited", (req::HTTP.Request) -> Res.send("ok"), middleware = [lf])
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
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/health", (req::HTTP.Request) -> Res.send("ok"))
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
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/o", (req::HTTP.Request) -> Res.send("ok"), middleware = [route_lf])
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


@testitem "RateLimiter — a throwing cleanup sweep costs one tick, not all of them" tags=[:middleware, :slow] setup=[NitroCommon] begin
using Test
using Dates
using Nitro
using Nitro.Core.Middleware.RateLimiterMiddleware: BucketKey, _Stripe, _cleanup_loop

# #169. The sweep used to be a bare `@async` with no `errormonitor` and no `try` inside the
# loop, so ANY throw in the sweep body was stored in a Task nobody waits on: the sweep died
# mute and the bucket store was never reaped again for the life of the process. The component
# whose entire job is bounding memory failed open, silently.
#
# `_cleanup_loop` is a named function precisely so this is testable — the limiter's own stripes
# are closure-local, so a limiter built through `RateLimiter(...)` offers no seam to inject a
# failure through. Driving the loop directly over a deliberately-failing store tests the thing
# that actually matters: WHERE the `try` sits.
#
# Against the unpatched shape — `try` hoisted outside the `while`, or absent — the loop exits
# on the first throw, `stale` is never deleted, and the `timedwait` below times out.

# A store that throws on its first `failures` iterations, then behaves like the Dict it wraps.
# Mirrors `FlakyStore` in test/session_tests.jl, which guards the same property for the
# session janitor.
mutable struct FlakyBucketStore <: AbstractDict{BucketKey, Tuple{Int, DateTime}}
    inner         :: Dict{BucketKey, Tuple{Int, DateTime}}
    failures_left :: Int
    sweeps        :: Int
end

function Base.iterate(s::FlakyBucketStore)
    s.sweeps += 1
    if s.failures_left > 0
        s.failures_left -= 1
        error("simulated sweep failure")
    end
    return iterate(s.inner)
end
Base.iterate(s::FlakyBucketStore, state) = iterate(s.inner, state)
Base.length(s::FlakyBucketStore)         = length(s.inner)
Base.delete!(s::FlakyBucketStore, k)     = (delete!(s.inner, k); s)

@testset "the loop survives a throwing sweep and keeps reaping" begin
    old = now(UTC) - Minute(30)          # older than the threshold -> must be reaped
    fresh = now(UTC)                     # inside the threshold -> must be left alone
    store = FlakyBucketStore(
        Dict{BucketKey, Tuple{Int, DateTime}}((false, UInt128(1)) => (1, old),
                                              (false, UInt128(2)) => (1, fresh)),
        3, 0)
    stripes = [_Stripe(ReentrantLock(), store)]

    token = Ref(true)
    # Silence the loop's OWN logger, not the spawn expression: `@suppress_err` restores stderr
    # the moment `Threads.@spawn` hands back the Task, microseconds before the first tick, so
    # it would leave all three deliberate `@error` lines (with backtraces) in the worker log.
    # ReTestItems flushes that log when an item goes red — exactly when the one line that
    # matters must not be buried under failures the test caused on purpose.
    # `Base.CoreLogging`, not `using Logging`: Logging is not a declared test dependency, and
    # adding one for a null logger would trip the Aqua [compat] guard for no reason.
    task = Threads.@spawn Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
        _cleanup_loop(token, stripes, Millisecond(20), Minute(10))
    end
    try
        # The assertion that fails against the unpatched code: the loop must survive its three
        # throwing ticks and still reap afterwards.
        @test timedwait(() -> length(store) == 1, 10.0) === :ok
        @test haskey(store.inner, (false, UInt128(2)))   # fresh bucket untouched
        @test store.sweeps > 3                           # it really kept ticking past the failures
        @test !istaskdone(task)                          # ...and the janitor is still alive
    finally
        token[] = false
    end
    @test timedwait(() -> istaskdone(task), 10.0) === :ok
end

@testset "the sweep is spawned migratable, not pinned to a request thread" begin
    # #169 chose `Threads.@spawn` over `@async`, diverging from the issue's own lean, and that
    # choice had NO test: `t isa Task` and `timedwait(istaskdone)` pass identically against the
    # old `@async` version, and both are already covered by the restart testitem above. The
    # `sticky` flag is what actually discriminates — `@async` pins the task to the spawning
    # thread for life (`sticky == true`), which for this O(total-buckets) sweep means a
    # request-handling thread. Without this assertion, "simplifying" it back to `@async` is a
    # green run.
    #
    # `Task.sticky` is a Base INTERNAL field, like `HTTP.BytesBody.data` in
    # test/http_internals_contract_tests.jl. If a future Julia renames it this fails with an
    # unhelpful `FieldError` — the fix is to find the new spelling, not to drop the assertion.
    #
    # `errormonitor` itself is deliberately NOT asserted here. Its only observable effect is an
    # async log on a fatal death, which the per-tick `try` above now prevents from happening at
    # all; there is no seam to observe it through that would not be theater.
    lf = RateLimiter(rate_limit = 5, window = Second(1),
                     cleanup_period = Millisecond(50), cleanup_threshold = Millisecond(50))
    t = lf.on_startup()
    try
        @test t isa Task
        @test t.sticky === false
    finally
        lf.on_shutdown()
    end
    @test timedwait(() -> istaskdone(t), 10.0) === :ok
end
end # @testitem


@testitem "Lifecycle middleware — order is registration order, teardown is LIFO" tags=[:middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core: LifecycleMiddleware, startup, shutdown
using Nitro.Core.RouterHOF: register_route_lifecycle!, register_serve_lifecycle!,
                            lifecycle_snapshot
import Nitro: App, path, text

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
# reversal, because they supply the `Iterators.reverse` themselves; swapping `src/core/lifecycle.jl` to
# FIFO leaves them green. The assertion that actually pins the teardown contract is
# `order == ["up:route", "up:serve", "down:serve", "down:route"]` in the
# "route-owned hooks survive a serve/terminate cycle" item above, which drives the real
# `serve`/`terminate` — and it is tagged `:network`, so a run filtered away from `:network`
# does not check the teardown order at all.
#
# The promotion testset further down has the same scope: it pins the SPLIT that promotion leaves
# behind — which half each object ends up in AND its position within that half, and therefore
# what order the two broadcasts visit them in — and likewise supplies its own `Iterators.reverse`
# rather than pinning `terminate`'s.
@testset "the container preserves registration order" begin
    order, mk = recorder()
    a, b, c = mk("a"), mk("b"), mk("c")
    ctx = App()
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
        ctx = App()
        register_route_lifecycle!(ctx, Any[mk("a"), mk("b"), mk("c")])
        route_lf, _ = lifecycle_snapshot(ctx)
        startup.(route_lf)
        shutdown.(Iterators.reverse(route_lf))
        order
    end
    @test runs[1] == runs[2]
end

@testset "a promoted entry tears down out of LIFO in its own cycle, and the next one is settled" begin
    # #188. `register_route_lifecycle!` PROMOTES: an object handed both to `serve(middleware=…)`
    # and to a route is moved out of the serve-owned half and APPENDED to the route-owned half.
    # `terminate` unwinds serve-owned first and route-owned second, so in that one cycle the
    # promoted object is torn down after every serve-owned entry — including ones that started
    # BEFORE it, which LIFO required to be torn down after it.
    #
    # Until now the only assertion about promotion was `lf ∉ ctx.service.serve_lifecycle`, i.e.
    # membership. Nothing pinned the ORDER, which is how `routerhof.jl`'s "Promotion is not
    # order-preserving" note described the exception BACKWARDS from #82 until 5086684 — and how
    # that wrong sentence got copied into the public `LifecycleMiddleware` docstring in PR #184
    # before the delta review caught it. A wrong ordering claim survived two releases and became
    # a published contract because no test disagreed with it.
    #
    # This block MIRRORS three pieces of policy that live in `src/core/lifecycle.jl`, with
    # nothing linking them but this comment: `startserver`'s route-then-serve startup (its two
    # `_broadcast_lifecycle(startup, …)` calls, lines 426-427), `terminate`'s
    # reverse-serve-then-reverse-route teardown (its two `_broadcast_lifecycle(shutdown, …)`
    # calls, lines 386-387), and `terminate` clearing ONLY the serve half (line 398). Change any
    # of those and update this too — the `:network` item above is what actually pins them, and it
    # has no promoted object in it. (The line numbers moved once already, in #185; the call
    # names are the durable half of this pointer.)
    order, mk = recorder()
    a, rl, b, c = mk("a"), mk("rl"), mk("b"), mk("c")
    ctx = App()

    # ── Cycle 1: promotion happens mid-cycle ──────────────────────────────────────────────
    # `c` is route-owned from the start, so the route half is NOT empty when the promotion
    # lands. That is what makes the append position below an assertion rather than a claim:
    # with one entry, `push!` and `pushfirst!` are indistinguishable.
    register_route_lifecycle!(ctx, Any[c])
    # `a`, `rl` and `b` arrive via `serve(middleware=…)`, then a route claims `rl`. That is the
    # runtime `include_routes` / `revise=:lazy` shape — route registration FOLLOWING serve —
    # which is the case the promoting guard exists for.
    register_serve_lifecycle!(ctx, Any[a, rl, b])
    route_lf, serve_lf = lifecycle_snapshot(ctx)
    startup.(route_lf); startup.(serve_lf)        # `startserver`'s order: route-owned, then serve-owned
    @test order == ["up:c", "up:a", "up:rl", "up:b"]

    register_route_lifecycle!(ctx, Any[rl])       # PROMOTION
    route_lf, serve_lf = lifecycle_snapshot(ctx)
    @test serve_lf == [a, b]                      # `rl` removed from here, in place
    @test route_lf == [c, rl]                     # ...and APPENDED here, behind `c` — not prepended

    empty!(order)
    shutdown.(Iterators.reverse(serve_lf))        # `terminate`'s order, exactly
    shutdown.(Iterators.reverse(route_lf))

    # This is NOT LIFO, and that is accepted rather than a bug. Startup was `c, a, rl, b`, so
    # LIFO would be `b, rl, a, c`. `rl` moved to the route half, which tears down LAST, so `a`
    # — which started BEFORE `rl` — is now torn down before it. `b`, which started after it, is
    # unaffected. Route ownership winning and the promoted object keeping its old serve-phase
    # position are mutually exclusive, which is why the ordering contract is stated per cycle
    # (`register_route_lifecycle!`, src/routerhof.jl).
    @test order == ["down:b", "down:a", "down:rl", "down:c"]

    # ── Cycle 2: settled, and exact LIFO again ────────────────────────────────────────────
    # `terminate` clears ONLY the serve-owned half (#82), so the split no longer moves: `rl`
    # stays route-owned across the restart and nothing is promoted again.
    lock(() -> empty!(ctx.service.serve_lifecycle), ctx.service.lifecycle_lock)
    register_serve_lifecycle!(ctx, Any[a, b])     # what the next `serve(middleware=…)` does
    route_lf, serve_lf = lifecycle_snapshot(ctx)

    empty!(order)
    startup.(route_lf); startup.(serve_lf)
    @test order == ["up:c", "up:rl", "up:a", "up:b"]   # route-owned first now — `c`, then `rl`

    empty!(order)
    shutdown.(Iterators.reverse(serve_lf))
    shutdown.(Iterators.reverse(route_lf))
    @test order == ["down:b", "down:a", "down:rl", "down:c"]   # the exact reverse of startup
end

@testset "dedup survives the container change" begin
    # Load-bearing, and the thing a naive Set -> Vector swap regresses silently: one shared
    # `RateLimiter()` on N routes must start its cleanup task once, not N times.
    _, mk = recorder()
    lf = mk("shared")
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/p", (req::HTTP.Request) -> Res.send("ok"), middleware = [lf]),
        path("/q", (req::HTTP.Request) -> Res.send("ok"), middleware = [lf]),
        path("/r", (req::HTTP.Request) -> Res.send("ok"), middleware = [lf]),
    ])
    route_lf, _ = lifecycle_snapshot(ctx)
    @test length(route_lf) == 1

    # ...and on the serve-owned side too, including across repeated registration.
    ctx2 = App()
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
    ctx = App()

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
    ctx = App()
    register_route_lifecycle!(ctx, Any[mk("a")])
    snap, _ = lifecycle_snapshot(ctx)
    register_route_lifecycle!(ctx, Any[mk("b")])
    @test length(snap) == 1                      # the copy did not grow underneath us
    @test length(lifecycle_snapshot(ctx)[1]) == 2
end
end # @testitem


@testitem "SessionMiddleware — serve()/terminate() own the prune janitor" tags=[:middleware, :network, :slow] setup=[NitroCommon] begin
using Test
using Dates
using Nitro
using Nitro.Types: MemoryStore

# The unit tests in test/session_tests.jl drive `on_startup`/`on_shutdown` directly, which
# proves the janitor works but NOT that anything calls it. This is the wiring test: pruning
# only actually happens in a real app if `serve()` runs the startup hook of the
# `LifecycleMiddleware` that `SessionMiddleware` now returns (#36). Against the previous
# bare-closure version there is no hook to run at all.

store = MemoryStore{String, Dict{String,Any}}()
for i in 1:20
    Nitro.Cookies.storesession!(store, "dead-$i", Dict{String,Any}("i" => i), ttl=1)
end
Nitro.Cookies.storesession!(store, "live", Dict{String,Any}("i" => 0), ttl=3600)
sleep(1.2)                       # let the 20 short-TTL entries expire
@test length(store.data) == 21   # nothing has pruned them yet

port = get_free_port()
app = App(mod = @__MODULE__)
urlpatterns(app, "", Nitro.RouteDefinition[path("/ping", (req) -> "pong", method="GET")])

serve(app;
      middleware = [SessionMiddleware(store = store, prune_interval = Millisecond(100),
                                      secure = false)],
      port = port, host = HOST, async = true,
      show_banner = false, show_errors = false, access_log = nothing)
try
    # serve() must have started the janitor.
    @test timedwait(() -> length(store.data) == 1, 10.0) === :ok
    @test haskey(store.data, "live")      # unexpired sessions are never touched
finally
    terminate(app)
end
sleep(0.5)

# ...and terminate() must have stopped it: a newly expired entry is NOT reaped.
Nitro.Cookies.storesession!(store, "post", Dict{String,Any}("i" => 9), ttl=1)
sleep(1.6)
@test haskey(store.data, "post")
end # @testitem


# ── #185: the lifecycle interrupt broadcast ──────────────────────────────────────────────────
#
# `startup`/`shutdown` used to catch EVERYTHING, `InterruptException` included, and lose it: a
# Ctrl-C landing inside a hook was logged as an `@error` and the server carried on as if nothing
# had happened. A bare `rethrow()` there would have been worse — it abandons the rest of the
# sequence, and on the teardown path it skips `close(service)` and leaves the listener up. So the
# interrupt is DEFERRED: every sequence runs to completion, then exactly one is re-raised.
#
# Every item below drives the interrupt with a hook that is literally
# `() -> throw(InterruptException())`, the same way `test/middleware/janitor_tests.jl` reaches the
# stranded state on purpose. No signals, no timing, no flake.

@testitem "Lifecycle interrupt — startup/shutdown defer instead of swallowing (#185)" tags=[:middleware] setup=[NitroCommon] begin
using Test
using Dates
using HTTP
using Nitro
using Nitro.Core: LifecycleMiddleware, startup, shutdown
using Nitro.Core.Middleware.JanitorMiddleware: _janitor

_pass(handler) = (req::HTTP.Request -> handler(req))
# The deferral logs a `@warn` at the moment it happens. Silence it where it is expected.
_quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())

@testset "an interrupted hook is returned, not swallowed" begin
    boom = LifecycleMiddleware(middleware = _pass,
                               on_startup  = () -> throw(InterruptException()),
                               on_shutdown = () -> throw(InterruptException()))

    # Against the unpatched code both of these are `nothing` — the interrupt was eaten by the
    # catch-all's `@error` and there was no way for a caller to learn it had happened.
    @test _quiet(() -> startup(boom)) isa InterruptException
    @test _quiet(() -> shutdown(boom)) isa InterruptException
end

@testset "everything else still returns nothing" begin
    none = LifecycleMiddleware(middleware = _pass)
    @test startup(none) === nothing
    @test shutdown(none) === nothing

    ran = Ref(0)
    plain = LifecycleMiddleware(middleware = _pass,
                                on_startup  = () -> (ran[] += 1),
                                on_shutdown = () -> (ran[] += 1))
    @test startup(plain) === nothing
    @test shutdown(plain) === nothing
    @test ran[] == 2

    # The slot means "was this hook interrupted?", so a hook's own return value must not reach
    # it. `_janitor`'s `on_startup` really does hand back a `Task`, and it leaked through this
    # frame until #185 — the one case where the pre-existing docstring was simply false.
    on_up, on_down = _janitor(() -> nothing, Millisecond(50), "TestJanitor", "test tick", "interval")
    janitor = LifecycleMiddleware(middleware = _pass, on_startup = on_up, on_shutdown = on_down)
    @test on_up() isa Task                 # the hook itself: still a Task, unchanged
    @test startup(janitor) === nothing     # through `startup`: discarded, as documented
    @test shutdown(janitor) === nothing
    on_down()                              # stop any activation this testset left running
end

@testset "_broadcast_lifecycle completes the sequence and keeps the FIRST interrupt" begin
    order = String[]
    mk(name) = LifecycleMiddleware(middleware = _pass, on_startup = () -> push!(order, name))
    boom = LifecycleMiddleware(middleware = _pass,
                               on_startup = () -> throw(InterruptException()))

    got = _quiet(() -> Nitro.Core._broadcast_lifecycle(startup, [mk("a"), boom, mk("b")]))
    @test got isa InterruptException
    # The whole point of deferring: `b` ran anyway. A `break`-on-interrupt loses it.
    @test order == ["a", "b"]

    # A pre-existing interrupt from an earlier half of the same sequence is not overwritten.
    # Without the `isnothing(interrupt) &&` guard the last one would win instead.
    first_one = InterruptException()
    @test _quiet(() -> Nitro.Core._broadcast_lifecycle(startup, [boom], first_one)) === first_one
    @test Nitro.Core._broadcast_lifecycle(startup, [mk("c")], first_one) === first_one
    @test Nitro.Core._broadcast_lifecycle(startup, LifecycleMiddleware[]) === nothing
end

end # @testitem


@testitem "Lifecycle interrupt — a startup interrupt unwinds instead of stranding the listener (#185)" tags=[:middleware, :network] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core: LifecycleMiddleware
import Nitro: App, path

_pass(handler) = (req::HTTP.Request -> handler(req))

# Route-owned hooks run FIRST, so this interrupt lands before the serve-owned half has started.
# `armed` disarms it for the re-serve at the bottom: route-owned entries survive `terminate` by
# design (#82), so without this the second `serve` would simply interrupt again and the
# re-servability check would assert nothing about being stranded.
armed = Ref(true)
boom_stopped = Ref(0)
boom = LifecycleMiddleware(middleware = _pass,
                           on_startup  = () -> (armed[] && throw(InterruptException())),
                           on_shutdown = () -> (boom_stopped[] += 1))
later_started, later_stopped = Ref(0), Ref(0)
later = LifecycleMiddleware(middleware = _pass,
                            on_startup  = () -> (later_started[] += 1),
                            on_shutdown = () -> (later_stopped[] += 1))

ctx = App()
Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
    path("/health", (req::HTTP.Request) -> Res.send("ok"), middleware = [boom])
])

# The fixture is what it claims to be: two DISTINCT entries, so `later` really does land in the
# serve half. Pinned rather than assumed — `LifecycleMiddleware` is an immutable struct, so two
# entries built from the same closure over the same `Ref` compare EQUAL, and the promotion rule
# ("route ownership wins", #82) would then fold the serve-owned one into the route half and leave
# the assertions below silently measuring one hook instead of two.
@test boom != later

Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
    # Against the unpatched code nothing is thrown at all: the interrupt is eaten and `serve`
    # returns a running server.
    @test_throws InterruptException Nitro.Core.serve(ctx; middleware = [later], host = HOST,
        port = get_free_port(), async = true, show_banner = false, show_errors = false,
        access_log = nothing)
end

# The sequence completed past the interrupt — a bare `rethrow()` leaves this at 0.
@test later_started[] == 1
# ...and the unwind paired every hook that had started, including the one that interrupted.
@test boom_stopped[] == 1
@test later_stopped[] == 1

# The listener `start(...)` had already opened is closed, not stranded.
@test !Base.isopen(ctx.service)
@test ctx.service.server[] === nothing
@test isempty(ctx.service.serve_lifecycle)
@test ctx.service.external_url[] === nothing

# The operator-visible assertion. Against a bare `rethrow()` this dies with
# `ArgumentError("This App is already serving on …")` and nothing can close the old listener.
armed[] = false
Nitro.Core.serve(ctx; host = HOST, port = get_free_port(), async = true,
                 show_banner = false, show_errors = false, access_log = nothing)
@test timedwait(() -> Base.isopen(ctx.service), 10.0) === :ok
Nitro.Core.terminate(ctx)
@test !Base.isopen(ctx.service)

end # @testitem


@testitem "Lifecycle interrupt — terminate completes its teardown before re-raising (#185)" tags=[:middleware, :network] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core: LifecycleMiddleware
import Nitro: App, path

_pass(handler) = (req::HTTP.Request -> handler(req))

@testset "a serve-owned interrupt does not abandon the route-owned half" begin
    # `terminate` unwinds serve-owned first, so B interrupts BEFORE A's hook runs — which is
    # exactly the ordering a bare `rethrow()` destroys.
    a_down = Ref(0)
    a = LifecycleMiddleware(middleware = _pass, on_shutdown = () -> (a_down[] += 1))
    b = LifecycleMiddleware(middleware = _pass,
                            on_shutdown = () -> throw(InterruptException()))
    @test a != b        # distinct entries, or promotion folds `b` into the route half — see below

    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/health", (req::HTTP.Request) -> Res.send("ok"), middleware = [a])
    ])
    Nitro.Core.serve(ctx; middleware = [b], host = HOST, port = get_free_port(), async = true,
                     show_banner = false, show_errors = false, access_log = nothing)
    @test timedwait(() -> Base.isopen(ctx.service), 10.0) === :ok

    Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
        # Unpatched: `terminate` swallows it and does not throw at all.
        @test_throws InterruptException Nitro.Core.terminate(ctx)
    end

    @test a_down[] == 1                        # the later half of the sequence still ran
    @test isempty(ctx.service.serve_lifecycle)  # the clears still ran
    @test ctx.service.external_url[] === nothing
    @test !Base.isopen(ctx.service)             # `close` still ran
    @test ctx.service.server[] === nothing

    # Not stranded: the app serves and stops cleanly afterwards.
    Nitro.Core.serve(ctx; host = HOST, port = get_free_port(), async = true,
                     show_banner = false, show_errors = false, access_log = nothing)
    @test timedwait(() -> Base.isopen(ctx.service), 10.0) === :ok
    Nitro.Core.terminate(ctx)
    @test !Base.isopen(ctx.service)
end

@testset "both halves interrupt: one escapes, both are reported" begin
    # A counter EACH, deliberately. `LifecycleMiddleware` is an immutable struct, so two entries
    # built from the same closure over the same `Ref` compare EQUAL — and the promotion rule
    # ("route ownership wins", #82) then folds the serve-owned one into the route half, leaving
    # the serve half empty and this testset silently measuring one hook instead of two.
    a_entered, b_entered = Ref(0), Ref(0)
    a = LifecycleMiddleware(middleware = _pass,
        on_shutdown = () -> (a_entered[] += 1; throw(InterruptException())))
    b = LifecycleMiddleware(middleware = _pass,
        on_shutdown = () -> (b_entered[] += 1; throw(InterruptException())))

    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/both", (req::HTTP.Request) -> Res.send("ok"), middleware = [a])
    ])
    Nitro.Core.serve(ctx; middleware = [b], host = HOST, port = get_free_port(), async = true,
                     show_banner = false, show_errors = false, access_log = nothing)
    @test timedwait(() -> Base.isopen(ctx.service), 10.0) === :ok
    # The fixture is what it claims to be: one interrupting hook in EACH half.
    _rlf, _slf = Nitro.Core.lifecycle_snapshot(ctx)
    @test length(_rlf) == 1
    @test length(_slf) == 1

    logger = Test.TestLogger(min_level = Base.CoreLogging.Warn)
    Base.CoreLogging.with_logger(logger) do
        @test_throws InterruptException Nitro.Core.terminate(ctx)
    end

    # Both hooks ran; neither was skipped. `b` is serve-owned so it interrupts FIRST, and `a`
    # runs anyway — a bare `rethrow()` leaves `a_entered[]` at 0.
    @test b_entered[] == 1
    @test a_entered[] == 1
    @test !Base.isopen(ctx.service)             # the teardown still completed
    # The dropped interrupt is REPORTED, not silently discarded: `_report_interrupt` logs at the
    # moment each one happens, precisely because only the first is re-raised.
    reported = count(r -> occursin("interrupt during LifecycleMiddleware.on_shutdown", r.message),
                     logger.logs)
    @test reported == 2
end

end # @testitem


# NOT TESTED HERE, and stated rather than faked: the `finally terminate(ctx)` that #185 added to
# `startserver`'s `!async` branch (`src/core/lifecycle.jl`), which stops a BLOCKING `serve` from
# returning with its listener still open after Ctrl-C.
#
# Two reasons no test here is worth its cost:
#
#  1. The interrupt has to arrive in a task already parked in `wait(ctx.service)`, and
#     `schedule(t, exc; error = true)` is documented as incorrect for a started, blocked task.
#     Doing it anyway does not fail this item — it tears down the ReTestItems runner itself with
#     a `TaskFailedException`, which is how this comment came to be written.
#  2. No IN-PROCESS test is honest, and the out-of-process one is not portable. A subprocess that
#     opts in with `Base.exit_on_sigint(false)` WOULD reproduce it — that is a normal pattern for
#     a containerized server wanting graceful SIGINT shutdown, and it is precisely the deployment
#     this `finally` helps. But it costs a process per run and leans on SIGINT delivery to a
#     child process, which is unlikely to be portable to the Windows leg of the CI matrix —
#     Windows has no POSIX signals and maps `kill` onto console control events. That last point
#     is a judgement, not a measurement: nobody has spot-checked it on the Windows runner. If
#     this coverage is ever wanted badly enough, measure it there first.
#
# Note what reason 2 does NOT claim. Julia's *default* non-interactive posture is
# `exit_on_sigint(true)` (`base/client.jl`), under which SIGINT calls `jl_exit` and no
# `InterruptException` is ever constructed — that is why this is not an upgrade-note-worthy
# behavior change. It is a default, not a law, and an app may opt out of it.
#
# Reviewed by eye, the same call `janitor_tests.jl` makes about `errormonitor`. What the items
# above DO pin is the half that is reachable in-process: an interrupt inside a startup or
# shutdown hook.
