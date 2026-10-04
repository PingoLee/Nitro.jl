@testitem "Revise integration" tags=[:extension, :network] setup=[NitroCommon] begin

using Test
using Pkg: TOML
using Nitro
using HTTP
using Sockets

port = get_free_port()
localhost = "http://$HOST:$port"

urlpatterns("",
    path("/", function() return Res.send("Ok") end, method="GET"),
)

project_toml = TOML.parsefile(joinpath(pkgdir(Nitro), "Project.toml"))
@test get(project_toml["weakdeps"], "Revise", nothing) == "295af30f-e4ad-537b-8983-00126c2a3abe"
@test get(project_toml["extensions"], "NitroReviseExt", nothing) == "Revise"

revise_path = Base.find_package("Revise")
# FAIL, do not skip (#128) -- the sibling of the `PormG` case in
# `test/extensions/pormg_worker_tests.jl`. This was `@test_skip false`, which reports as
# `Broken` and carries no message at all, so a run that never exercised the
# `NitroReviseExt` hot-reload integration was indistinguishable from one that did.
# `Revise` is a declared `[targets].test` dependency; its absence is an environment bug.
if revise_path === nothing
    error("Revise is not available, so the NitroReviseExt integration cannot be " *
          "exercised. Revise is a declared `[targets].test` dependency: this is a " *
          "broken test environment, not a valid configuration, and failing here is " *
          "deliberate (#128). Re-provision with `Pkg.test()`.")
else
    integration_script = """
        using Revise
        using Nitro

        Nitro.has_revise_hooks() || error(\"Nitro did not register Revise hooks\")
        ext = Base.get_extension(Nitro, :NitroReviseExt)
        ext !== nothing || error(\"NitroReviseExt was not loaded\")
        # The hook must leave the event CLEARED (#372). It only bites on a Revise whose
        # `revision_event` does not autoreset (<= 3.14.2): there, without the `reset`, the eager
        # watcher re-woke at once forever. On later versions `wait` already cleared it, so this
        # passes either way -- it is a regression check for the versions `[compat]` still admits.
        notify(Revise.revision_event)
        ext._wait_for_revision_event()
        (@atomic Revise.revision_event.set) && error(\"the revision hook left Revise.revision_event set\")

        # #427, against the REAL event: `close` must take the watcher off `revision_event`, not
        # leave it parked until the next save. The ext's own wait and cancel, a counting `revise`.
        revised = Threads.Atomic{Int}(0)
        Nitro.register_revise_hooks!(;
            revise=() -> (Threads.atomic_add!(revised, 1); nothing),
            has_pending_revisions=() -> false,
            wait_for_revision_event=ext._wait_for_revision_event,
            cancel_revision_wait=ext._cancel_revision_wait,
        )
        waitq = Revise.revision_event.notify.waitq
        parked(svc) = svc.task.queue === waitq
        svc1 = Nitro.Core.start_revise_service()
        timedwait(() -> parked(svc1), 10.0) === :ok || error(\"watcher 1 never parked\")
        close(svc1)
        timedwait(() -> istaskdone(svc1.task), 10.0) === :ok ||
            error(\"close left the watcher parked on Revise.revision_event (#427)\")
        istaskfailed(svc1.task) && error(\"watcher 1 failed instead of stopping\")
        isempty(waitq) || error(\"a task is still queued on Revise.revision_event after close\")

        # The issue's acceptance: after a restart, the FIRST save reaches the new watcher. This
        # only discriminates on an autoresetting event (Revise 3.14.5+), where a notify wakes one
        # waiter -- before #427 that was the dead watcher 1. A non-autoreset event wakes both.
        svc2 = Nitro.Core.start_revise_service()
        timedwait(() -> parked(svc2), 10.0) === :ok || error(\"watcher 2 never parked\")
        notify(Revise.revision_event)
        timedwait(() -> revised[] == 1, 10.0) === :ok ||
            error(\"the first save after a restart was not revised (#427)\")
        close(svc2)
        timedwait(() -> istaskdone(svc2.task), 10.0) === :ok || error(\"watcher 2 did not stop\")
        println(\"ok\")
    """
    integration_cmd = `$(Base.julia_cmd()) --project=$(pkgdir(Nitro)) -e $(integration_script)`
    @test success(integration_cmd)
end

original_revise_hooks = Nitro.revise_hooks()
Nitro.clear_revise_hooks!()

try
    @test_throws "Invalid `revise` value" serve(port=port, host=HOST, show_errors=false, show_banner=false, access_log=nothing, revise=:all)

    # Production path should not require Revise when hot reload is disabled.
    serve(port=port, host=HOST, show_errors=false, show_banner=false, access_log=nothing, async=true)
    @test String(HTTP.get("$localhost/").body) == "Ok"
    terminate()

    # Test error message when Revise support is unavailable.
    error_task = @async begin
        for revise in (:lazy, :eager)
            @test_throws "Revise support is unavailable" serve(port=port, host=HOST, show_errors=false, show_banner=false, access_log=nothing, revise=revise)
        end
    end

    if timedwait(() -> istaskdone(error_task), 60) == :timed_out
        error("Timed out waiting for Revise usage error")
    end

    function run_revise_mode_test(revise_mode::Symbol)
        revision_queue = [nothing] # non-empty
        revision_event = Channel{Nothing}(1)
        revise_mode == :eager && put!(revision_event, nothing)
        revise_called_count = Ref(0)
        invocation = []

        function revise()
            revise_called_count[] += 1
            empty!(revision_queue)
            return nothing
        end

        Nitro.register_revise_hooks!(;
            revise=revise,
            has_pending_revisions=() -> !isempty(revision_queue),
            wait_for_revision_event=() -> take!(revision_event),
        )

        function handler1(handler)
            return function(req::HTTP.Request)
                push!(invocation, 1)
                handler(req)
            end
        end

        try
            serve(port=port, host=HOST, show_errors=false, show_banner=false, access_log=nothing, revise=revise_mode, middleware=[handler1], async=true)

            if revise_mode == :eager
                @test timedwait(() -> revise_called_count[] == 1, 10) == :ok
            end

            @test String(HTTP.get("$localhost/").body) == "Ok"
            @test invocation == [1]
            @test revise_called_count[] == 1
        finally
            terminate()
            if revise_mode == :eager
                put!(revision_event, nothing)
            end
        end
    end

    run_revise_mode_test(:lazy)
    run_revise_mode_test(:eager)

    # #427, the other way to strand a watcher: `serve(async = true)` starts it BEFORE `listen!`,
    # so a listener that fails to bind returns no handle for `terminate` to reach it through.
    let revisions = Channel{Nothing}(Inf)
        Nitro.register_revise_hooks!(;
            revise=() -> nothing,
            has_pending_revisions=() -> false,
            wait_for_revision_event=() -> take!(revisions),
            cancel_revision_wait=t -> lock(revisions) do
                t.queue === revisions.cond_take.waitq || return false
                schedule(t, Nitro.ReviseWaitCancelled(); error = true)
                return true
            end,
        )
        busy_port = get_free_port()
        blocker = Sockets.listen(Sockets.IPv4(HOST), busy_port)
        app = App(mod = @__MODULE__)
        try
            @test_throws Exception serve(app; port=busy_port, host=HOST, show_errors=false,
                                         show_banner=false, access_log=nothing, revise=:eager,
                                         async=true, reuseaddr=false)
            watcher = app.service.eager_revise[]
            @test watcher !== nothing
            @test timedwait(() -> istaskdone(watcher.task), 10) === :ok
            @test !istaskfailed(watcher.task)
        finally
            close(blocker)
            terminate(app)
        end
    end
finally
    if original_revise_hooks !== nothing
        Nitro.register_revise_hooks!(;
            revise=original_revise_hooks.revise,
            has_pending_revisions=original_revise_hooks.has_pending_revisions,
            wait_for_revision_event=original_revise_hooks.wait_for_revision_event,
            cancel_revision_wait=original_revise_hooks.cancel_revision_wait,
        )
    else
        Nitro.clear_revise_hooks!()
    end
end

println()

end
# The eager watcher's loop discipline (#372), in-process: the hooks are fakes, so nothing here needs
# Revise, a file watcher or a socket. What a REAL Ctrl-C does is the next item's job.
@testitem "Revise -- eager watcher stops on an interrupt and survives a failed revision (#372)" tags=[:extension] setup=[NitroCommon] begin

using Test
using Nitro
using Suppressor

original_revise_hooks = Nitro.revise_hooks()
restore_hooks() = original_revise_hooks === nothing ? Nitro.clear_revise_hooks!() :
    Nitro.register_revise_hooks!(;
        revise=original_revise_hooks.revise,
        has_pending_revisions=original_revise_hooks.has_pending_revisions,
        wait_for_revision_event=original_revise_hooks.wait_for_revision_event,
        cancel_revision_wait=original_revise_hooks.cancel_revision_wait,
    )

try
    @testset "an interrupt ends the loop normally, with a warning -- not a failure" begin
        Nitro.register_revise_hooks!(;
            revise=() -> nothing,
            has_pending_revisions=() -> false,
            wait_for_revision_event=() -> throw(InterruptException()),
        )
        # Returning at all is the point: rethrowing is what killed the watcher, and swallowing
        # would loop straight back into the throwing `wait` and never return.
        @test (@test_logs (:warn, r"reached the eager-Revise watcher") Nitro.Core._eager_revise_loop(Threads.Atomic{Bool}(false))) === nothing
    end

    @testset "an interrupt DURING a revision reaches the same handler" begin
        Nitro.register_revise_hooks!(;
            revise=() -> throw(InterruptException()),
            has_pending_revisions=() -> false,
            wait_for_revision_event=() -> nothing,
        )
        @test (@test_logs (:info,) (:warn, r"reached the eager-Revise watcher") Nitro.Core._eager_revise_loop(Threads.Atomic{Bool}(false))) === nothing
    end

    @testset "a revision that throws costs that revision, never the watcher" begin
        done = Threads.Atomic{Bool}(false)
        events = Ref(0)
        Nitro.register_revise_hooks!(;
            revise=() -> events[] == 1 ? error("boom") : nothing,
            has_pending_revisions=() -> false,
            # Event 1 fails, event 2 must still be served, and event 3 asks the loop to stop.
            wait_for_revision_event=() -> (events[] += 1; events[] == 3 && (done[] = true); nothing),
        )
        @test_logs (:error, "Nitro: eager revision failed") (:info, r"Eager revision finished") match_mode=:any Nitro.Core._eager_revise_loop(done)
        @test events[] == 3
    end

    @testset "a watcher that dies is reported, not silent" begin
        # A throw from the WAIT is outside the per-revision `try`, so it does end the task -- and
        # `errormonitor` is the only thing that says so: nothing ever waits on this task, and
        # `terminate` only stops it. Without it this prints nothing at all.
        Nitro.register_revise_hooks!(;
            revise=() -> nothing,
            has_pending_revisions=() -> false,
            wait_for_revision_event=() -> error("watcher boom (#372)"),
        )
        captured = @capture_err begin
            svc = Nitro.Core.start_revise_service()
            @test timedwait(() -> istaskdone(svc.task), 10) === :ok
            @test istaskfailed(svc.task)
            # `errormonitor` reports from a task of its own, scheduled as the watcher fails.
            sleep(1)
        end
        @test occursin("watcher boom (#372)", captured)
    end

    @testset "the watcher is not sticky, and runs on the :default pool" begin
        Nitro.register_revise_hooks!(;
            revise=() -> nothing,
            has_pending_revisions=() -> false,
            wait_for_revision_event=() -> sleep(0.05),
        )
        svc = Nitro.Core.start_revise_service()
        try
            @test !svc.task.sticky
            @test Threads.threadpool(svc.task) === :default
        finally
            close(svc)
            @test timedwait(() -> istaskdone(svc.task), 10) === :ok
            @test !istaskfailed(svc.task)
        end
    end

    # #427. A fake cancellable wait built like the real one in ext/NitroReviseExt.jl: a `Channel`'s
    # `take!` parks on `cond_take`, whose lock is the Channel's, just as `wait(::Event)` parks on
    # `event.notify`. The real Revise event is exercised in the "Revise integration" child.
    revisions = Channel{Nothing}(Inf)
    cancel_take(t::Task) = lock(revisions) do
        t.queue === revisions.cond_take.waitq || return false
        schedule(t, Nitro.ReviseWaitCancelled(); error = true)
        return true
    end
    parked() = !isempty(revisions.cond_take.waitq)

    @testset "a cancelled wait ends the loop quietly (#427)" begin
        Nitro.register_revise_hooks!(;
            revise=() -> nothing,
            has_pending_revisions=() -> false,
            wait_for_revision_event=() -> throw(Nitro.ReviseWaitCancelled()),
        )
        # No warning, unlike an interrupt: being cancelled is how a watcher is meant to stop.
        @test (@test_logs Nitro.Core._eager_revise_loop(Threads.Atomic{Bool}(false))) === nothing
    end

    @testset "close wakes a watcher parked in its wait (#427)" begin
        Nitro.register_revise_hooks!(;
            revise=() -> nothing,
            has_pending_revisions=() -> false,
            wait_for_revision_event=() -> take!(revisions),
            cancel_revision_wait=cancel_take,
        )
        svc = Nitro.Core.start_revise_service()
        @test timedwait(parked, 10) === :ok
        # Before #427, `close` only set the flag and the watcher stayed parked until the next save.
        close(svc)
        @test timedwait(() -> istaskdone(svc.task), 10) === :ok
        @test !istaskfailed(svc.task)
        @test !parked()
    end

    @testset "close retries a cancel that finds the watcher not yet parked (#427)" begin
        # The first attempt reports "not parked", as it does when the watcher read the flag a
        # moment before `close` set it. Only the retry can wake it.
        attempts = Threads.Atomic{Int}(0)
        Nitro.register_revise_hooks!(;
            revise=() -> nothing,
            has_pending_revisions=() -> false,
            wait_for_revision_event=() -> take!(revisions),
            cancel_revision_wait=t -> Threads.atomic_add!(attempts, 1) == 0 ? false : cancel_take(t),
        )
        svc = Nitro.Core.start_revise_service()
        @test timedwait(parked, 10) === :ok
        close(svc)
        @test timedwait(() -> istaskdone(svc.task), 10) === :ok
        @test !istaskfailed(svc.task)
        @test attempts[] >= 2
    end

    @testset "a cancel hook that throws is logged, never thrown out of close (#427)" begin
        # `close` runs inside `terminate` after the listener is down, so a broken hook must not
        # turn a clean shutdown into an exception.
        Nitro.register_revise_hooks!(;
            revise=() -> nothing,
            has_pending_revisions=() -> false,
            wait_for_revision_event=() -> take!(revisions),
            cancel_revision_wait=_ -> error("cancel boom (#427)"),
        )
        svc = Nitro.Core.start_revise_service()
        @test timedwait(parked, 10) === :ok
        @test (@test_logs (:error, r"cancelling the eager-Revise watcher's wait failed") match_mode=:any close(svc)) === nothing
        # Unblock it the old way, so the item leaves no parked task behind.
        put!(revisions, nothing)
        @test timedwait(() -> istaskdone(svc.task), 10) === :ok
    end

    @testset "close cancels with the hooks the watcher was started with (#427)" begin
        Nitro.register_revise_hooks!(;
            revise=() -> nothing,
            has_pending_revisions=() -> false,
            wait_for_revision_event=() -> take!(revisions),
            cancel_revision_wait=cancel_take,
        )
        svc = Nitro.Core.start_revise_service()
        @test timedwait(parked, 10) === :ok
        # Re-registering, as a test or a reloaded extension does, must not strand the watcher.
        Nitro.register_revise_hooks!(;
            revise=() -> nothing,
            has_pending_revisions=() -> false,
            wait_for_revision_event=() -> nothing,
        )
        close(svc)
        @test timedwait(() -> istaskdone(svc.task), 10) === :ok
        @test !istaskfailed(svc.task)
    end
finally
    restore_hooks()
end

end

# #372 with a REAL SIGINT, built exactly like the #369 item at the top of test/workers_tests.jl:
# where Julia delivers a Ctrl-C is the whole bug, and only a child process can take one. The
# parent is the shared `ctrl_c_child` (the `CtrlCChild` setup in test/setup_tests.jl), which
# owns the handshake, the `settle` lower bound and the watchdog; only what differs is said here.
#
# The children register fake hooks, so no Revise is involved: `wait_for_revision_event` is a
# `take!`, and `revise` prints REVISED, which is the parent's cue. Each child also holds
# `Timer(3600)`, an active libuv handle that never fires. A REPL always has one -- its terminal --
# and without one a headless child idles thread 1 where a SIGINT never wakes it: measured, the
# press then reached NOBODY, patched watcher or not, and every child hung until the watchdog.
# (The #369 child never needed this because its scheduler holds a 24 h `Timer` of its own.)
#
# Against the unpatched `@async` watcher (checked): the isolated child printed
# `main=main_never_saw_it watcher_failed=true` at both layouts, and the `serve` child never
# returned -- a second press then landed in the dead watcher and aborted the process with
# "fatal: error thrown and no exception handler available".
#
# Not on Windows, for the reason the #369 item gives.
@testitem "Revise -- Ctrl-C after an eager revision reaches serve, not the watcher (#372)" tags=[:extension, :slow, :network] setup=[NitroCommon, CtrlCChild] begin
using Test

# The watcher alone, with main parked in ONE `wait` on it -- the #369 child's shape.
const WATCHER_CHILD = SIGINT_PROBE * raw"""
Base.exit_on_sigint(false)          # what every REPL does
using Nitro
const TERMINAL_STANDIN = Timer(3600)
revisions = Channel{Nothing}(Inf)
Nitro.register_revise_hooks!(;
    revise = () -> (println("REVISED"); flush(stdout)),
    has_pending_revisions = () -> false,
    wait_for_revision_event = () -> take!(revisions),
)
svc = Nitro.Core.start_revise_service()
# Parked in its first `take!` before the save below, for the reason the #369 child polls `wake`.
timedwait(() -> !isempty(revisions.cond_take.waitq), 10.0)
# One save, queued now and served once main parks: under `1,0` the watcher then re-parks AFTER
# main, so it -- not main -- is the last task to park on thread 1 when the press comes.
put!(revisions, nothing)
got = try
    wait(svc.task)
    :main_never_saw_it
catch e
    e isa InterruptException ? :main_interrupted :
    e isa TaskFailedException ? :main_never_saw_it :   # the watcher took it and died (#372)
    rethrow()
end
println("RESULT main=", got, " watcher_failed=", istaskfailed(svc.task))
"""

# The issue's own acceptance: a BLOCKING `serve(revise = :eager)`, one save, one press. The save
# comes from a `:default`-pool task, as Revise's file watchers do -- a sticky trigger would itself
# be the last task to finish on thread 1 and take the press. It serves NO request, on purpose: a
# connection task that finishes on thread 1 takes the press the same way, with or without Revise,
# which is #426 and not this item's subject.
const SERVE_CHILD = SIGINT_PROBE * raw"""
Base.exit_on_sigint(false)
using Nitro, Sockets
const TERMINAL_STANDIN = Timer(3600)
revisions = Channel{Nothing}(Inf)
Nitro.register_revise_hooks!(;
    revise = () -> (println("REVISED"); flush(stdout)),
    has_pending_revisions = () -> false,
    wait_for_revision_event = () -> take!(revisions),
)
port, probe = listenany(ip"127.0.0.1", 20000); close(probe)
app = App(mod = @__MODULE__)
urlpatterns(app, "", path("/", () -> Res.send("ok"), method = "GET"))
Threads.@spawn :default (sleep(3); put!(revisions, nothing))
serve(app; host = "127.0.0.1", port = Int(port), show_banner = false, access_log = nothing,
      revise = :eager)
println("RESULT serve_returned")
"""

if !Sys.iswindows()
    @testset "with an interactive thread -- Julia 1.12's default for `julia` and `-t auto`" begin
        r = ctrl_c_child(WATCHER_CHILD, "1,1"; cue="REVISED")
        report(r)
        @test !r.sigint_ignored
        @test !r.timed_out
        @test r.exitcode == 0
        @test r.termsignal == 0
        @test contains(r.out, "RESULT main=main_interrupted watcher_failed=false")
        @test !occursin(r"unhandled task"i, r.err)
    end

    @testset "on one shared thread -- `-t 1`" begin
        # The watcher re-parks after main here, so it takes the press. It must stop with its
        # warning rather than die, and the warning is asserted so a green means the handler ran.
        r = ctrl_c_child(WATCHER_CHILD, "1,0"; cue="REVISED")
        report(r)
        @test !r.sigint_ignored
        @test !r.timed_out
        @test r.exitcode == 0
        @test r.termsignal == 0
        @test contains(r.out, "RESULT main=main_never_saw_it watcher_failed=false")
        @test occursin("reached the eager-Revise watcher", r.err)
        @test !occursin(r"unhandled task"i, r.err)
    end

    @testset "one press after a revision stops a blocking `serve(revise = :eager)`" begin
        r = ctrl_c_child(SERVE_CHILD, "1,1"; cue="REVISED")
        report(r)
        @test !r.sigint_ignored
        @test !r.timed_out
        @test r.exitcode == 0
        @test r.termsignal == 0
        @test contains(r.out, "RESULT serve_returned")
        @test !occursin(r"fatal: error thrown"i, r.err)
    end
end

end
