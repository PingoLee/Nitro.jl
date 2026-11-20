# The mark-all switch's check (#618, the battery's item 3), untimed. On a validation build (mark-validate,
# or mark-all with JULIA_SCHED_MARK_ALL unset, =spawn or =insert), each spawn path below runs NT tasks
# and prints the validation counters it moved: f_first (first enqueues classed F, a ring), r_first
# (first enqueues classed R, a descendant), l_first (first enqueues left in stock's heaps) and demoted
# (marked tasks of another pool, sent to stock's path). With the switch unset, mark-all must print what
# mark-validate prints, path for path; set, it shows which paths each mode marks and which it leaves.
#
# Usage: JULIA_SCHED_MARK_ALL=spawn julia-mark-all --threads=4,1 bench/julia/mark_all_checks.jl
isdefined(Base.Partr, :sched_counts) || error("needs a validation build (Base.Partr.sched_counts)")
const NT = parse(Int, get(ENV, "NT", "64"))
const KEYS = (:f_first, :r_first, :l_first, :demoted)
counts() = (c = Base.Partr.sched_counts(); NamedTuple{KEYS}(map(k -> getfield(c, k), KEYS)))

function hand_built()
    t = Task(() -> 1)
    t.sticky = false
    schedule(t)
    return t
end
function threads_loop()
    a = zeros(Int, NT)
    Threads.@threads for i in 1:NT
        a[i] = i
    end
    return sum(a)
end
function marked_root_with_children()
    r = Task(() -> (foreach(wait, [Threads.@spawn(1) for _ in 1:NT]); 1))
    r.sticky = false
    Threads._spawn_set_thrpool(r, :default)
    Threads._spawn_set_fair(r, true)
    schedule(r)
    return r
end
const PATHS = [
    "Threads.@spawn"             => () -> foreach(wait, [Threads.@spawn(1) for _ in 1:NT]),
    "Threads.@spawn :interactive" => () -> foreach(wait, [Threads.@spawn(:interactive, 1) for _ in 1:NT]),
    "Threads.@threads"           => threads_loop,
    "Channel(spawn=true)"        => () -> foreach(_ -> (ch = Channel{Int}(1; spawn = true) do c; put!(c, 1); end; take!(ch)), 1:NT),
    "hand-built schedule"        => () -> foreach(_ -> wait(hand_built()), 1:NT),
    "@async"                     => () -> foreach(wait, [@async(1) for _ in 1:NT]),
    "marked root + @spawn kids"  => () -> wait(marked_root_with_children()),
]

println("mark_all_checks: ", Base.GIT_VERSION_INFO.commit_short, " JULIA_SCHED_MARK_ALL=",
        get(ENV, "JULIA_SCHED_MARK_ALL", "(unset)"), " threads ", Threads.nthreads(:default), ",",
        Threads.nthreads(:interactive), " main task on :", Threads.threadpool(), " NT=", NT)
println("before the paths: ", counts())
println(join(("path", KEYS...), '\t'))
for (name, f) in PATHS
    f()   # compile
    c0 = counts(); f(); c1 = counts()
    println(join((name, map(k -> getfield(c1, k) - getfield(c0, k), KEYS)...), '\t'))
end
