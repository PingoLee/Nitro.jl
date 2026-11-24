# A fine-grained fork-join with nothing marked: what the mark costs code that does not use it.
# Standard library only.
#
#   julia --threads=8,1 fib_fine.jl [runs]
#
# pfib(42), spawning down to n = 12 (about 2.2 million tasks), from one root task spawned on
# :default. One warm-up run, then `runs` runs (default 7), each after a full GC. Prints one line:
# the median and the minimum wall time (s).
const RUNS = parse(Int, get(ARGS, 1, "7"))
const N, CUT = 42, 12
sfib(n::Int) = n <= 1 ? n : sfib(n - 1) + sfib(n - 2)
function pfib(n::Int, cut::Int)
    n <= max(cut, 1) && return sfib(n)
    t = Threads.@spawn pfib(n - 2, cut)
    return pfib(n - 1, cut) + fetch(t)::Int
end
function run1(n)
    GC.gc()
    t0 = time_ns()
    r = fetch(Threads.@spawn :default pfib(n, CUT))
    return (time_ns() - t0) / 1e9, r
end
run1(CUT + 6)
walls = Float64[]
for _ in 1:RUNS
    w, r = run1(N)
    r == sfib(N) || error("pfib($N) = $r")
    push!(walls, w)
end
sort!(walls)
println("fib_fine ", VERSION, " ", Base.GIT_VERSION_INFO.commit_short, ": threads=", Threads.nthreads(:default), ",",
        Threads.nthreads(:interactive), " runs=", RUNS, " median_s=", round(walls[(end + 1) ÷ 2]; digits = 4),
        " min_s=", round(walls[1]; digits = 4))
