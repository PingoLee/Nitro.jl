# The child of `test/workers_thread1_hijack_tests.jl` (#636): one task holds a lock across a
# `sleep`, and an `atexit` hook needs that lock. The parent SIGTERMs this process while the lock
# is held.
#
#   julia --threads=1,2 thread1_hijack_child.jl pinned   <outdir>   # the holder on thread 2
#   julia --threads=1,1 thread1_hijack_child.jl unpinned <outdir>   # the holder on thread 1
using Nitro

mode, outdir = ARGS[1], ARGS[2]
const L = ReentrantLock()

# The parent polls for these files and reads them while this process runs. A plain `write`
# creates the file before filling it, so a poll in between read `""` (#707); a rename is atomic.
function mark(name, value)
    path = joinpath(outdir, name)
    write(path * ".tmp", value)
    mv(path * ".tmp", path; force = true)
end

# The shape of a consumer's heartbeat caught mid-renewal: a store's write lock held, the task
# parked inside it. Released four seconds later, if the task is still allowed to run.
function holder()
    lock(L) do
        mark("holding", string(Threads.threadid()))
        sleep(4)
    end
end

# The shape of a consumer's drain: on another thread, wait for what the holder has.
atexit() do
    got = Threads.Atomic{Bool}(false)
    Threads.@spawn :default begin
        lock(L)
        got[] = true
        unlock(L)
    end
    timedwait(() -> got[], 8.0; pollint = 0.05)
    mark("hook", got[] ? "acquired" : "blocked")
end

if mode == "pinned"
    Nitro.Workers._spawn_pinned(holder, 2)
else
    Nitro.Workers._spawn_detached(holder; pool = :interactive)
end
# Parked, as `consume!`'s main task is. A SIGTERM ends this process through `exit`.
wait(Timer(3600))
