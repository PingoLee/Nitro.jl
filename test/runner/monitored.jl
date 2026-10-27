# Monitored tasks: a background task started under `errormonitor` must not outlive the run.
#
# Nitro starts its background tasks -- janitors, the access-log writer, the Workers scheduler and
# consumer loops, SSE producers -- under `errormonitor`, because nothing waits on them. One still
# running at exit is a crash waiting for its order: after the `atexit` hooks, Julia runs EVERY
# finalizer, reachable objects included, so a task parked on a `Timer` or a stream wakes with an
# exception on another thread, and `errormonitor` compiles the code that prints it while the
# process is being torn down. That was #772, which surfaced as a segfault after a green summary,
# under one `--shuffle` seed, with the task's own error never printed.
#
# So the watched child records every task `errormonitor` is handed -- the item running at the
# time, and a raw backtrace resolved only if needed -- and at the end of the run fails if any of
# them is still running, naming the item and the call site. The rule is zero, not a baseline:
# which tasks are left depends on which items ran and in what order, so a count above zero could
# only let a new leak hide behind an old one.
#
# Only in the watched child (`run_items` decides): the record works by replacing
# `Base.errormonitor(::Task)`, and a process that runs `--in-process` may be someone's REPL.
# The replacement records, then runs Base's own method through `invoke(f, ::Method, args...)`,
# so what an unhandled task prints, and in which world, is unchanged.
#
# Only `errormonitor`'d tasks are seen. Those are Nitro's background loops, and the ones Julia
# itself prints, and so compiles for, at exit.

struct MonitoredTask
    task::Task
    item::String
    bt::typeof(backtrace())
end

const MONITORED = MonitoredTask[]
const MONITORED_LOCK = ReentrantLock()
const MONITORING = Ref(false)

# Where the run is, for the record, phrased to follow "started": `_run_listed!` sets it around
# each item, setups and TEST_END included. Read from any thread; a `String` is replaced whole.
const CURRENT_ITEM = Ref("before the first test item")

function record_monitored!(t::Task, bt)
    entry = MonitoredTask(t, CURRENT_ITEM[], bt)
    @lock MONITORED_LOCK begin
        # Done tasks are dropped as new ones arrive, so the list holds what is running now and
        # a finished task is not kept alive until the end of the run.
        filter!(e -> !istaskdone(e.task), MONITORED)
        push!(MONITORED, entry)
    end
    return nothing
end

"""
    monitor_tasks!()

Replace `Base.errormonitor(::Task)` in this process with one that records each task for
`monitored_left`, then calls the original method. Idempotent.
"""
function monitor_tasks!()
    MONITORING[] && return nothing
    original = which(Base.errormonitor, Tuple{Task})
    record = record_monitored!
    # Evaluated into `Base`, so the definition replaces Base's own method (no new method, no
    # overwrite warning) and every caller, Nitro's compiled code included, reaches it. The record
    # is best-effort: if it throws, the task is still monitored, and the guard never stops the
    # code it watches from starting its tasks.
    Core.eval(Base, quote
        function errormonitor(t::Task)
            try
                $record(t, backtrace())
            catch
            end
            return invoke(errormonitor, $original, t)
        end
    end)
    MONITORING[] = true
    return nothing
end

"""
    monitored_left(; grace = 10.0) -> Vector{MonitoredTask}

The recorded tasks still running, after waiting up to `grace` seconds for them to end: a task
the last item stopped may still be on its way out. Read again after the wait, so a leaked loop
that starts more tasks during it is reported with them. Empties the record, so the tasks are
no longer kept alive by it.
"""
function monitored_left(; grace::Real = 10.0)
    left = @lock MONITORED_LOCK filter(e -> !istaskdone(e.task), MONITORED)
    isempty(left) || timedwait(() -> all(e -> istaskdone(e.task), left), float(grace); pollint = 0.05)
    left = @lock MONITORED_LOCK begin
        l = filter(e -> !istaskdone(e.task), MONITORED)
        empty!(MONITORED)
        l
    end
    return left
end

# The frames that say where a task was started: the caller of `errormonitor` and up from it,
# without Base, Core, the stdlibs or this runner. Base's files are the relative paths: an inlined
# `Threads.@spawn` expansion has no module to go by. The stdlibs' paths are the build machine's.
# A frame at line 0 is an item's top level, which carries no line of the item's body; the item
# itself is named above the frames. When nothing is left -- a task a stdlib started -- the
# unfiltered frames are shown instead, so the site is never blank.
const _STDLIB_PATH = r"[/\\]stdlib[/\\]v\d+\.\d+[/\\]"

function _spawn_site(bt; frames::Int = 6)
    runner = @__DIR__
    all_frames = filter(fr -> !fr.from_c, stacktrace(bt))
    keep = filter(all_frames) do fr
        file = String(fr.file)
        mod = parentmodule(fr)
        !(mod === Base || mod === Core || !isabspath(file) || startswith(file, runner) ||
          occursin(_STDLIB_PATH, file) || fr.line == 0)
    end
    isempty(keep) && (keep = all_frames)
    return first(keep, frames)
end

function report_monitored(io::IO, left::Vector{MonitoredTask})
    n = length(left)
    println(io, "\n$n background task$(n == 1 ? " was" : "s were") still running at the end of the run.")
    println(io, "Each was started under `errormonitor` and outlived the test item that started it. At exit,")
    println(io, "Julia finalizes the Timers and streams such a task waits on, and the error it then throws is")
    println(io, "printed while the process tears down, which crashed the run in #772. Stop it before the")
    println(io, "item ends: `terminate`, `shutdown!`, `close`, or whatever owns it.\n")
    for e in left
        println(io, "  started $(e.item):")
        for fr in _spawn_site(e.bt)
            println(io, "    ", fr.func, " at ", fr.file, ":", fr.line)
        end
    end
    println(io)
    flush(io)
    return nothing
end
