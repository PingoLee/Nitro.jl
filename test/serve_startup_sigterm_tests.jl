@testitem "serve: the startup broadcast runs off thread 1 outside a REPL (#824)" tags=[:core] setup=[NitroCommon] begin

# `startserver` runs the startup hooks through `_startup_broadcast`. Outside a REPL, with thread 1
# in the interactive pool, it runs them on a `:default` task, so a SIGTERM never finds thread 1
# compiling a hook (the next item). Everything else about the broadcast is as it was: route hooks
# before serve hooks, a hook's interrupt deferred to the caller, and anything structural thrown
# with its own type.

using Test
using Nitro
using Nitro: LifecycleMiddleware

const Types = Nitro.Core.Types
broadcast_startup = Nitro.Core._startup_broadcast

@test Nitro.Core._startup_off_thread1() == (!isinteractive() && Threads.threadpool(1) === :interactive)

@testset "the hooks run in order, on a :default thread when thread 1 is interactive" begin
    ran = Tuple{Symbol, Int}[]
    lk = ReentrantLock()
    hook(tag) = LifecycleMiddleware(middleware = identity,
                                    on_startup = () -> @lock(lk, push!(ran, (tag, Threads.threadid()))))
    @test broadcast_startup([hook(:route)], [hook(:serve_a), hook(:serve_b)]) === nothing
    @test first.(ran) == [:route, :serve_a, :serve_b]
    if Nitro.Core._startup_off_thread1()
        @test all(t -> Threads.threadpool(t) === :default, last.(ran))
    end
end

@testset "a hook's interrupt is handed back, and the hooks after it still run" begin
    after = Ref(false)
    first_hook = LifecycleMiddleware(middleware = identity, on_startup = () -> throw(InterruptException()))
    second_hook = LifecycleMiddleware(middleware = identity, on_startup = () -> (after[] = true))
    @test broadcast_startup([first_hook], [second_hook]) isa InterruptException
    @test after[]
end

# An interrupt that reaches the CALLER while a hook runs, as Ctrl-C does under
# `Base.exit_on_sigint(false)` (thrown in here with `schedule`). Off thread 1 the caller waits for
# the hooks to return and then hands it back; in place it lands in the hook, and `startup` hands it
# back the same way. Either way the caller gets one `InterruptException`.
@testset "an interrupt to the waiting caller is deferred until the hooks return" begin
    started, gate = Base.Event(), Base.Event()
    finished = Threads.Atomic{Bool}(false)
    blocking = LifecycleMiddleware(middleware = identity,
                                   on_startup = () -> (notify(started); wait(gate); finished[] = true))
    caller = Threads.@spawn broadcast_startup([blocking], LifecycleMiddleware[])
    wait(started)
    # Parked, in the hook's wait or in the wait for the hook's task: `schedule` on a task that is
    # still running would corrupt it.
    @test timedwait(() -> caller.queue !== nothing, 30.0; pollint = 0.01) === :ok
    schedule(caller, InterruptException(); error = true)
    if Nitro.Core._startup_off_thread1()
        sleep(0.2)
        @test !istaskdone(caller)    # still waiting for the hook, not abandoned
        notify(gate)
        @test fetch(caller) isa InterruptException
        @test finished[]
    else
        @test fetch(caller) isa InterruptException
        notify(gate)
    end
end

# `startup` swallows a hook's own exception, so only an entry whose `startup` itself throws gets
# past the broadcast. It reaches the caller as itself, not wrapped in a `TaskFailedException`.
struct StructuralBoom end
Types.startup(::StructuralBoom) = error("structural")
@test_throws ErrorException("structural") broadcast_startup(StructuralBoom[], [StructuralBoom()])

end

@testitem "serve: a SIGTERM during the startup hooks ends the process (#824)" tags=[:core, :slow, :network] begin

# A SIGTERM ends a script by running the `atexit` hooks on thread 1, on top of whatever thread 1
# was running. A served PormG app SIGTERMed while its Workers boot sweep compiled on thread 1 never
# exited (#824, the newapp item's `@test stopped`). The child's startup hook compiles for up to a
# minute; this sends SIGTERM half a second in. Before the fix the hook ran on thread 1, which the
# first testset reads directly; whether a given SIGTERM then hung depended on landing mid-codegen
# (about one run in seven here; every run for the PormG app, whose first request is answered just
# as the sweep resumes).

using Test

const CHILD = joinpath(@__DIR__, ".helpers", "startup_sigterm_child.jl")

function sigterm_during_startup(threads)
    outdir = mktempdir()
    log = joinpath(outdir, "log")
    cmd = `$(Base.julia_cmd()) --code-coverage=none --threads=$threads --startup-file=no
           --project=$(Base.active_project()) $CHILD $outdir`
    p = open(io -> run(pipeline(ignorestatus(cmd); stdout = io, stderr = io); wait = false), log, "w")
    started = joinpath(outdir, "started")
    timedwait(() -> isfile(started) || !process_running(p), 240.0; pollint = 0.05)
    pool = isfile(started) ? read(started, String) : ""
    sleep(0.5)
    process_running(p) && kill(p, Base.SIGTERM)
    t = time()
    exited = timedwait(() -> !process_running(p), 30.0; pollint = 0.05) === :ok
    exit_s = time() - t
    exited || kill(p, Base.SIGKILL)
    wait(p)
    result = (; pool, exited, exit_s, termsignal = p.termsignal, log = read(log, String))
    rm(outdir; recursive = true, force = true)
    return result
end

# Windows has no SIGTERM to run hooks on: `kill` is `TerminateProcess`.
Sys.iswindows() || @testset "with an interactive thread, the hook is off thread 1 and the SIGTERM exits" begin
    r = sigterm_during_startup("2,1")
    @test r.pool == "default"
    @test r.exited
    @test r.termsignal == Base.SIGTERM
    r.exited && r.pool == "default" || @info "the child's output" r.log r.exit_s
end

end
