# Closed-loop clients starved by newer work, and `Threads.@spawn fair=true`. Standard library only.
#
#   julia --threads=8,1 starved.jl          stock order
#   julia --threads=8,1 starved.jl fair     each client's task marked (a build without the keyword
#                                           says so and exits 0)
#
# 500 clients on :interactive; each spawns a 2 ms compute task on :default and waits for it, for 8 s,
# after a 1 s warm-up. With 8 :default threads every client should wait about 500 * 2 / 8 = 125 ms.
# Prints one line: tasks/s, the latency's p50, p99 and max (ms), and the tasks per client (min, median).
const C, H, D = 500, 2.0, 8.0
const FAIR = get(ARGS, 1, "plain") == "fair"
const HAS_FAIR = try
    wait(Core.eval(Main, :(Threads.@spawn fair=false nothing)))
    true
catch
    false
end
const ID = string(VERSION, " ", Base.GIT_VERSION_INFO.commit_short)
FAIR && !HAS_FAIR && (println("starved ", ID, ": fair= not supported by this build"); exit(0))

function burn(ms)                       # busy compute, no yield, no allocation
    deadline = time_ns() + round(UInt64, ms * 1e6)
    x = 0.0
    while time_ns() < deadline
        x = sin(x + 1.0)
        GC.safepoint()
    end
    return x
end
if FAIR
    @eval function client(deadline, lat)
        done = Base.Event(true)
        while time_ns() < deadline
            t0 = time_ns()
            Threads.@spawn fair=true (burn(H); notify(done))
            wait(done)
            push!(lat, (time_ns() - t0) / 1e6)
        end
    end
else
    function client(deadline, lat)
        done = Base.Event(true)
        while time_ns() < deadline
            t0 = time_ns()
            Threads.@spawn (burn(H); notify(done))
            wait(done)
            push!(lat, (time_ns() - t0) / 1e6)
        end
    end
end
function cell(d)
    lats = [Float64[] for _ in 1:C]
    deadline = time_ns() + round(UInt64, d * 1e9)
    foreach(wait, [Threads.@spawn :interactive client(deadline, lats[i]) for i in 1:C])
    return lats
end
const guard = Timer(typemax(Int32))     # nothing waits on it (keeps JuliaLang/julia#63882 out on 1.13)
cell(1.0)
lats = cell(D)
counts = sort(length.(lats))
all = sort(reduce(vcat, lats))
pct(p) = round(all[clamp(ceil(Int, p * length(all)), 1, length(all))]; digits = 1)
println("starved ", ID, ": threads=", Threads.nthreads(:default), ",", Threads.nthreads(:interactive),
        " mode=", FAIR ? "fair" : "plain", " tasks_per_s=", round(Int, length(all) / D),
        " p50_ms=", pct(0.5), " p99_ms=", pct(0.99), " max_ms=", round(all[end]; digits = 1),
        " client_min=", counts[1], " client_median=", counts[(end + 1) ÷ 2])
