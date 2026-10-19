@testitem "Workers -- a SIGTERM runs exit on top of thread 1; a task pinned elsewhere goes on (#636)" tags=[:workers, :slow] begin

# Why a consumer's heartbeat is pinned off thread 1 (`_spawn_pinned`). On a SIGTERM, Julia's
# signal thread interrupts thread 1 wherever it is and runs the `atexit` hooks on top of the task
# it was running (`jl_exit_thread0` in `src/signals-unix.c`). That task never resumes, even one
# parked in a `sleep`, which stays thread 1's current task while the thread looks for work. So
# whatever it holds, the hooks never get. A consumer's drain is such a hook, and a heartbeat on
# thread 1 holding the store's write lock mid-renewal left the drain's hand-backs waiting for it
# until they timed out.
#
# No Nitro code beyond the two spawns: the child holds a lock across a `sleep` in one task, and
# its `atexit` hook waits for that lock from another thread. The control is what makes the first
# testset mean something: on thread 1 the holder never releases.

using Test

const CHILD = joinpath(@__DIR__, ".helpers", "thread1_hijack_child.jl")

function sigterm_run(mode, threads)
    outdir = mktempdir()
    out = IOBuffer()
    cmd = `$(Base.julia_cmd()) --code-coverage=none --threads=$threads --startup-file=no
           --project=$(Base.active_project()) $CHILD $mode $outdir`
    p = run(pipeline(ignorestatus(cmd); stdout = out, stderr = out); wait = false)
    holding = joinpath(outdir, "holding")
    timedwait(() -> isfile(holding) || !process_running(p), 120.0; pollint = 0.02)
    # From the write, not from this poll noticing it, so a parent that stalled in between counts.
    seen = isfile(holding) ? mtime(holding) : time()
    held_on = isfile(holding) ? read(holding, String) : ""
    process_running(p) && kill(p, Base.SIGTERM)
    # The holder sleeps 4 s with the lock. A signal sent well inside that says something; one
    # sent late, on a loaded runner, may land after the release, and the run is repeated.
    prompt = time() - seen < 1.0
    timedwait(() -> !process_running(p), 30.0; pollint = 0.05)
    process_running(p) && kill(p, Base.SIGKILL)
    wait(p)
    hook = joinpath(outdir, "hook")
    result = (held_on = held_on, prompt = prompt, hook = isfile(hook) ? read(hook, String) : "",
              log = String(take!(out)))
    rm(outdir; recursive = true, force = true)
    return result
end

function prompt_run(mode, threads)
    r = sigterm_run(mode, threads)
    for _ in 2:3
        r.prompt && break
        r = sigterm_run(mode, threads)
    end
    return r
end

# A SIGTERM on Windows is `TerminateProcess`: no hook runs, so there is nothing to show there.
Sys.iswindows() || @testset "a pinned holder releases the lock while the exit hook waits" begin
    r = prompt_run("pinned", "1,2")
    @test r.prompt
    @test r.held_on == "2"
    @test r.hook == "acquired"
    r.hook == "acquired" || @info "the pinned child's output" r.log
end

Sys.iswindows() || @testset "the control: a holder on thread 1 never releases it" begin
    r = prompt_run("unpinned", "1,1")
    @test r.prompt
    @test r.held_on == "1"
    @test r.hook == "blocked"
    r.hook == "blocked" || @info "the unpinned child's output" r.log
end

end
