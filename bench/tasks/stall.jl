# The stall repro of the JuliaLang/julia#62285 measurement (#618, the comment of 2026-10-22, PR #716):
# hold every other `:default` thread with a task that never yields, spawn n tasks, release, twelve
# times. On #62285's head (84961e79ff) some holders never started although threads were parked
# (work-stealing build 3 of 3 runs, partr build 2 of 3); 1.13.2 passed 3 of 3. A run ends three
# ways: twelve `ok` lines; the `stuck` error below (a holder queued with idle threads for 5 s);
# or no progress at all, which only an outer timeout ends (stall.sh). The code below is the script
# as posted there, unchanged.
#
# STALL_MARK (#618, the battery's item 4: can the native mark lose a wakeup?) marks tasks through
# `Threads._spawn_set_fair`, behind an `isdefined` check so the file still runs on a build without the
# mark. `none` (the default) runs the posted code below, unchanged. The marked modes run the same
# iteration with the spawns built by hand (`Task`, `sticky = false`, the `:default` pool, the mark,
# `schedule`), which is what `Threads.@spawn` does:
#   all      holders and the n tasks marked (class F, the rings);
#   tasks    the n tasks marked, the holders not (the rings beside stock's heaps);
#   holders  the reverse;
#   under    the whole iteration runs inside one marked root and spawns nothing marked, so every
#            holder and every task is the root's descendant (class R, the R heaps).
# On a `stuck`, a build with the validation counters prints them (`validate: counts`).

const POSTED = raw"""
# julia -t 8 stall.jl
function once(n)
    hold = Threads.Atomic{Bool}(true); started = Threads.Atomic{Int}(0)
    k = Threads.nthreads(:default) - 1
    holders = [Threads.@spawn (Threads.atomic_add!(started, 1); while hold[]; GC.safepoint(); end) for _ in 1:k]
    t0 = time()
    while started[] < k
        yield()
        time() - t0 > 5 && error("stuck: $(started[]) of $k holder tasks started, $(k - started[]) queued with idle threads")
    end
    done = Threads.Atomic{Int}(0)
    ts = [Threads.@spawn Threads.atomic_add!(done, 1) for _ in 1:n]
    hold[] = false
    foreach(wait, ts); foreach(wait, holders)
end
for n in (10_000, 100_000), rep in 1:6
    once(n); println("n=$n rep=$rep ok")
end
"""

const STALL_MARK = get(ENV, "STALL_MARK", "none")
STALL_MARK in ("none", "all", "tasks", "holders", "under") ||
    error("STALL_MARK must be none, all, tasks, holders or under, not $STALL_MARK")

# `Threads._spawn_set_fair` is reached only when a marked mode runs, so these compile on any build.
function spawnm(f, mark::Bool)
    t = Task(f)
    t.sticky = false
    Threads._spawn_set_thrpool(t, :default)
    mark && Threads._spawn_set_fair(t, true)
    schedule(t)
    return t
end
function once_m(n, mh::Bool, mt::Bool)
    hold = Threads.Atomic{Bool}(true); started = Threads.Atomic{Int}(0)
    k = Threads.nthreads(:default) - 1
    holders = [spawnm(() -> (Threads.atomic_add!(started, 1); while hold[]; GC.safepoint(); end), mh) for _ in 1:k]
    t0 = time()
    while started[] < k
        yield()
        time() - t0 > 5 && error("stuck: $(started[]) of $k holder tasks started, $(k - started[]) queued with idle threads")
    end
    done = Threads.Atomic{Int}(0)
    ts = [spawnm(() -> Threads.atomic_add!(done, 1), mt) for _ in 1:n]
    hold[] = false
    foreach(wait, ts); foreach(wait, holders)
end
function print_counts()
    isdefined(Base.Partr, :sched_counts) || return nothing
    c = Base.Partr.sched_counts()
    println("validate: counts f_first=", c.f_first, " l_first=", c.l_first, " r_first=", c.r_first,
            " f_pops=", c.f_pops, " r_pops=", c.r_pops, " l_pops=", c.l_pops, " demoted=", c.demoted)
end
function main_marked(mode::String)
    isdefined(Threads, :_spawn_set_fair) || error("STALL_MARK=$mode needs a build with the native mark")
    mh, mt = mode == "all" ? (true, true) : mode == "tasks" ? (false, true) :
             mode == "holders" ? (true, false) : (false, false)
    println("mark=", mode, " threads=", Threads.nthreads(:default), ",", Threads.nthreads(:interactive))
    for n in (10_000, 100_000), rep in 1:6
        try
            if mode == "under"
                fetch(spawnm(() -> once_m(n, false, false), true))
            else
                once_m(n, mh, mt)
            end
        catch e
            m = match(r"stuck: [^\n]*", sprint(showerror, e))
            m === nothing || println(m.match)
            print_counts()
            rethrow()
        end
        println("n=$n rep=$rep ok")
    end
    print_counts()
end

if STALL_MARK == "none"
    include_string(@__MODULE__, POSTED, "stall.jl (as posted)")
else
    main_marked(STALL_MARK)
end
