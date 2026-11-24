# What unmarked code pays once a program has marked one task. Standard library only.
#
#   julia --threads=8,1 armed.jl            nothing marked
#   julia --threads=8,1 armed.jl armed      one task spawned with `fair=true` and waited on first;
#                                           then the same unmarked work (a build without the keyword
#                                           says so and exits 0)
#
# The work is fib_fine.jl's: pfib(42) down to n = 12 from one root on :default, one warm-up run,
# then 7 runs, each after a full GC. Prints one line: the median and the minimum wall time (s).
const ARMED = get(ARGS, 1, "unarmed") == "armed"
const RUNS = 7
const N, CUT = 42, 12
const ID = string(VERSION, " ", Base.GIT_VERSION_INFO.commit_short)
if ARMED
    try
        wait(Core.eval(Main, :(Threads.@spawn fair=true nothing)))
    catch
        println("armed ", ID, ": fair= not supported by this build")
        exit(0)
    end
end
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
println("armed ", ID, ": threads=", Threads.nthreads(:default), ",", Threads.nthreads(:interactive),
        " mode=", ARMED ? "armed" : "unarmed", " median_s=", round(walls[(end + 1) ÷ 2]; digits = 4),
        " min_s=", round(walls[1]; digits = 4))
