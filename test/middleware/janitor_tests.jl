@testitem "Janitor — the shared lifecycle discipline (#190)" tags=[:middleware, :slow] setup=[NitroCommon] begin
using Test
using Dates
using Nitro
using Nitro.Core.Middleware.JanitorMiddleware: _janitor, _janitor_loop
using Nitro.Core.Middleware: RateLimiterMiddleware

# Every janitor in Nitro (`SessionMiddleware`/`SessionPruner`'s prune, `FixedRateLimiter`'s
# sweep) is built from `_janitor`, so these testsets are the ONE place the discipline is
# checked. The per-caller items -- `session_tests.jl`'s five janitor testsets and
# `lifecycle_middleware_tests.jl`'s #82/#169 items -- still drive the real constructors and are
# what proves the callers are actually wired to this.
#
# Logging note: work that throws on purpose is run under a `NullLogger` INSIDE the spawned task,
# never `@suppress_err` around the spawn -- stderr is restored before the first tick fires. Same
# reason as `lifecycle_middleware_tests.jl`.

# A `work` that fails `fail_times` times and then succeeds, counting every call. Passed as
# `() -> w()` at every call site: `_janitor`/`_janitor_loop` take a `work::Function`, and a
# callable struct is NOT `<: Function` in Julia. Loosening that signature to accommodate a test
# double would be the tail wagging the dog -- every real caller passes a closure.
mutable struct FlakyWork
    calls::Int
    fail_times::Int
    failure::Exception
end
FlakyWork(fail_times::Int, failure::Exception=ErrorException("janitor work boom")) =
    FlakyWork(0, fail_times, failure)

function (w::FlakyWork)()
    w.calls += 1
    w.calls <= w.fail_times && throw(w.failure)
    return nothing
end

# `_janitor`'s hooks under a logger that eats the deliberate `@error`. `on_startup` spawns, so the
# logger has to be installed around the whole hook lifetime, not around the call.
quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())

@testset "the stranded case: a loop that ends does not make the janitor unrestartable" begin
    # THE regression #190 exists for. `InterruptException` is the one thing that ends
    # `_janitor_loop` while its token is still set, so it is how the stranded state is reached on
    # purpose. Before #190 the activation Refs stayed populated when the loop ended, so the next
    # `on_startup()` hit its own `isnothing(active[]) || return nothing` guard and returned
    # `nothing` FOREVER -- the janitor was gone for the life of the process while the thing it
    # bounds kept growing.
    #
    # Against the #190-unpatched code the `t2 isa Task` assertion below fails (it was `nothing`).
    interrupting = FlakyWork(1, InterruptException())
    on_startup, on_shutdown = _janitor(() -> interrupting(), Millisecond(20),
                                       "JanitorTest", "interrupting work", "interval")

    t1 = quiet(on_startup)
    @test t1 isa Task
    # The interrupt escapes the per-tick `try` and ends the loop -- and the task. Since #369 it
    # ends it NORMALLY, with a warning, rather than failing it (the next testset).
    @test timedwait(() -> istaskdone(t1), 10.0) === :ok
    @test !istaskfailed(t1)

    # ...and the activation retired itself on the way out, so a later start really respawns.
    t2 = quiet(on_startup)
    @test t2 isa Task
    @test t2 !== t1
    @test timedwait(() -> interrupting.calls > 1, 10.0) === :ok   # the new one is doing work
    @test !istaskdone(t2)

    on_shutdown()
    @test timedwait(() -> istaskdone(t2), 10.0) === :ok
end

@testset "an interrupt ends the loop normally, with a warning -- not a failure (#369)" begin
    # With `exit_on_sigint(false)` -- every REPL -- Julia throws SIGINT into whichever task parked
    # last on thread 1. A janitor is `Threads.@spawn`, so under Julia 1.12's default layout (thread
    # 1 is the interactive thread) it never gets one. Under `-t 1` it can, and then rethrowing
    # killed it with an `Unhandled Task ERROR` while the server kept running, and looping on would
    # re-park it to take every later press too. It stops and says so; the reasoning is next to the
    # Workers `_cleanup_scheduler_loop`. Against the unpatched loop this call THROWS.
    interrupting = FlakyWork(1, InterruptException())
    token = Ref(true)
    @test_logs (:warn, "Nitro.JanitorTest: an interrupt (Ctrl-C) reached the interrupting work task instead of the server. It has stopped until the server is started again. Press Ctrl-C again to stop the server.") begin
        @test _janitor_loop(() -> interrupting(), token, Millisecond(1),
                            "JanitorTest", "interrupting work") === nothing
    end
    @test interrupting.calls == 1     # stopped, not looping on
    @test token[]                     # it was the interrupt that ended it, not a shutdown
end

@testset "an ordinary throw costs one tick, not the janitor" begin
    # The other half of #169, now checked once for every caller instead of twice by copy. An
    # `InterruptException` ends the loop (above); anything else is logged and the loop ticks on.
    flaky = FlakyWork(3)
    on_startup, on_shutdown = _janitor(() -> flaky(), Millisecond(20),
                                       "JanitorTest", "flaky work", "interval")

    task = quiet(on_startup)
    try
        @test task isa Task
        @test timedwait(() -> flaky.calls > 5, 10.0) === :ok   # ticked well past the failures
        @test !istaskdone(task)                                # ...and is still alive
    finally
        on_shutdown()
    end
    @test timedwait(() -> istaskdone(task), 10.0) === :ok
end

@testset "a stale task cannot retire a live activation" begin
    # The subtle half of the `finally`. The retirement is guarded on `active[] === token`, so a
    # task from a PREVIOUS activation that exits after a restart must leave the current
    # activation's state alone. An unguarded `finally` would clear it, and the next
    # `on_startup()` would then spawn a SECOND live task -- #82's leak, reached from the other
    # side.
    #
    # Long interval: the first task must still be parked in `sleep` when the restart happens, so
    # it exits strictly after the second activation is installed.
    on_startup, on_shutdown = _janitor(() -> nothing, Millisecond(50),
                                       "JanitorTest", "idle work", "interval")

    t1 = on_startup()
    @test t1 isa Task
    @test on_shutdown() === t1        # signalled, but still parked in its sleep
    t2 = on_startup()                 # second activation installed while t1 is still alive
    @test t2 isa Task
    @test t2 !== t1

    # Now let t1 notice and run its `finally`.
    @test timedwait(() -> istaskdone(t1), 10.0) === :ok

    # t1's exit must NOT have retired t2's activation: a start is still a no-op, and a shutdown
    # still finds t2 to signal. Both would read the other way if the guard were `isnothing`.
    @test on_startup() === nothing
    @test !istaskdone(t2)
    @test on_shutdown() === t2
    @test timedwait(() -> istaskdone(t2), 10.0) === :ok
end

@testset "hook return values are the contract the callers' tests depend on" begin
    # Matches `session_tests.jl`'s "Session janitor hooks are idempotent across a restart"
    # exactly. `startup`/`shutdown` (src/types.jl) discard these, but tests call the hooks
    # directly -- it is the only way to observe that a stale activation's task actually exits.
    on_startup, on_shutdown = _janitor(() -> nothing, Millisecond(50),
                                       "JanitorTest", "idle work", "interval")

    t1 = on_startup()
    @test t1 isa Task
    @test on_startup() === nothing     # already running: no second task
    @test on_shutdown() === t1         # returns the task it signalled
    t2 = on_startup()                  # a restart gets its own token and task
    @test t2 isa Task
    @test t2 !== t1
    on_shutdown()
    @test on_shutdown() === nothing    # idempotent when already stopped
    @test timedwait(() -> istaskdone(t1) && istaskdone(t2), 10.0) === :ok
end

@testset "the interval is validated at construction, naming the caller's own keyword" begin
    # `require_fixed_period` runs in `_janitor`, not in the janitor task: a calendar period must
    # fail on the constructor call that is actually wrong, rather than killing a background task
    # on its first `sleep` and turning the feature silently off (#168).
    for bad in (Second(0), Second(-1), Nanosecond(500))
        @test_throws ArgumentError _janitor(() -> nothing, bad, "JanitorTest", "w", "interval")
    end
    for calendar in (Month(1), Quarter(1), Year(1))
        @test_throws ArgumentError _janitor(() -> nothing, calendar, "JanitorTest", "w", "interval")
    end

    # `kwname` is the caller's spelling, not a hardcoded one -- `SessionPruner` says `interval`
    # and `SessionMiddleware` says `prune_interval`, and an error naming a keyword the caller's
    # function does not have sends them hunting.
    err = try
        _janitor(() -> nothing, Month(1), "SessionMiddleware", "session prune", "prune_interval")
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("SessionMiddleware: prune_interval", err.msg)
end

@testset "the janitor task is spawned, not @async" begin
    # `t.sticky === false` is the only thing that discriminates `Threads.@spawn` from `@async`,
    # and the distinction is load-bearing: `@async` pins the task for life to the thread that ran
    # `startserver`, which is also serving requests. See the rationale block in
    # src/middleware/janitor.jl -- two independent routes to the same answer (#169, and a session
    # prune running a caller-supplied store's blocking SQL DELETE).
    on_startup, on_shutdown = _janitor(() -> nothing, Millisecond(50),
                                       "JanitorTest", "idle work", "interval")
    t = on_startup()
    try
        @test t isa Task
        @test t.sticky === false
    finally
        on_shutdown()
    end
    @test timedwait(() -> istaskdone(t), 10.0) === :ok
end

@testset "the failure log names the caller's label and work" begin
    # Nothing else in the suite pins these strings: every other failing-tick test deliberately
    # runs under a `NullLogger`, so an edit to either caller's `label`/`what` is otherwise a
    # silent, fully-green regression in the exact line an operator greps for. Both halves are
    # pinned -- the format here, the callers' arguments below -- so changing either goes red.
    token = Ref(true)
    once_then_stop = function ()
        token[] = false                    # exactly one tick, so `@test_logs` sees one record
        error("boom")
    end
    @test_logs (:error, "Nitro.RateLimiter: bucket cleanup sweep failed") match_mode=:any begin
        _janitor_loop(once_then_stop, token, Millisecond(1),
                      "RateLimiter", "bucket cleanup sweep")
    end

    # ...and the rate limiter really does pass those two strings. `_cleanup_loop` and
    # `FixedRateLimiter` both build their work from these, so one assertion covers both paths.
    @test RateLimiterMiddleware._SWEEP_LABEL == "RateLimiter"
    @test RateLimiterMiddleware._SWEEP_WHAT == "bucket cleanup sweep"

    # The session side end to end, through the real public constructor over a real store, so
    # `SessionPruner`'s own `label` and the `"session prune"` in `_prune_janitor` are both pinned.
    mutable struct ThrowingStore <: Nitro.Types.AbstractSessionStore{String, Dict{String,Any}}
        calls::Int
    end
    Nitro.Types.cleanup_expired_sessions!(s::ThrowingStore) =
        (s.calls += 1; error("simulated store failure"))

    store = ThrowingStore(0)
    pruner = SessionPruner(store; interval = Millisecond(20))
    logger = Test.TestLogger(min_level = Base.CoreLogging.Error)
    # `with_logger` around the spawn: a task inherits the logger in force when it is CREATED, so
    # this reaches the janitor task -- which is why it has to wrap `on_startup`, not just wait.
    task = Base.CoreLogging.with_logger(logger) do
        t = pruner.on_startup()
        @test timedwait(() -> store.calls > 0, 10.0) === :ok
        t
    end
    pruner.on_shutdown()
    # Read `logger.logs` only once the task is finished writing to it.
    @test timedwait(() -> istaskdone(task), 10.0) === :ok
    @test any(r -> r.message == "Nitro.SessionPruner: session prune failed", logger.logs)
end

@testset "_janitor_loop is drivable directly, over a caller's own work" begin
    # The reason the loop stays a separate named function: a middleware's real work closes over
    # state that is closure-local (the rate limiter's stripes, a session store) and cannot be
    # reached any other way, so `lifecycle_middleware_tests.jl`'s #169 item drives
    # `_cleanup_loop` -- now a thin wrapper over this -- with a token it owns.
    flaky = FlakyWork(2)
    token = Ref(true)
    task = Threads.@spawn Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
        _janitor_loop(() -> flaky(), token, Millisecond(20), "JanitorTest", "flaky work")
    end
    try
        @test timedwait(() -> flaky.calls > 4, 10.0) === :ok
        @test !istaskdone(task)
    finally
        token[] = false
    end
    @test timedwait(() -> istaskdone(task), 10.0) === :ok
end

end # @testitem
