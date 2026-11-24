# The benchmark of JuliaLang/julia#35589: `pfib(25)`, as posted in that PR's thread. Standard
# library only.
#
#   julia --threads=2 pfib.jl [none|root|all]
#
#   none  the root unmarked (any build);
#   root  the root spawned with `fair=true`, the rest as posted;
#   all   every spawn marked.
# `root` and `all` on a build without the keyword say so and exit 0. Each run spawns the root on
# :default and fetches it; after 1 s of warm-up, runs repeat for 4 s. Prints one line: the minimum
# and the median wall time of a run (s), and the number of runs.
const MODE = get(ARGS, 1, "none")
MODE in ("none", "root", "all") || error("the mode is none, root or all, not $MODE")
const ID = string(VERSION, " ", Base.GIT_VERSION_INFO.commit_short)
const HAS_FAIR = try
    wait(Core.eval(Main, :(Threads.@spawn fair=false nothing)))
    true
catch
    false
end
MODE != "none" && !HAS_FAIR && (println("pfib ", ID, ": fair= not supported by this build"); exit(0))

function pfib(n::Int)
    if n <= 1
        return n
    end
    t = Threads.@spawn pfib(n-2)
    return pfib(n-1) + fetch(t)::Int
end
if HAS_FAIR
    @eval function pfib_all(n::Int)
        if n <= 1
            return n
        end
        t = Threads.@spawn fair=true pfib_all(n-2)
        return pfib_all(n-1) + fetch(t)::Int
    end
    @eval root(n) = MODE == "none" ? fetch(Threads.@spawn :default pfib(n)) :
                    MODE == "root" ? fetch(Threads.@spawn :default fair=true pfib(n)) :
                                     fetch(Threads.@spawn :default fair=true pfib_all(n))
else
    root(n) = fetch(Threads.@spawn :default pfib(n))
end
function timed(seconds)
    walls = Float64[]
    stop = time_ns() + round(UInt64, seconds * 1e9)
    while time_ns() < stop
        t0 = time_ns()
        root(25) == 75025 || error("pfib(25) is wrong")
        push!(walls, (time_ns() - t0) / 1e9)
    end
    return sort!(walls)
end
timed(1.0)
w = timed(4.0)
println("pfib ", ID, ": threads=", Threads.nthreads(:default), ",", Threads.nthreads(:interactive), " mode=", MODE,
        " min_s=", round(w[1]; sigdigits = 4), " median_s=", round(w[(end + 1) ÷ 2]; sigdigits = 4), " runs=", length(w))
