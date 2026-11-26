# julia --threads=8,1 mwe.jl: 500 closed-loop clients on :interactive, each spawns a 2 ms task and waits
const C, H, D = 500, 2.0, 8.0                    # clients, ms per task, seconds
function burn(ms)                                # busy compute, no yield, no allocation
    deadline = time_ns() + round(UInt64, ms * 1e6)
    x = 0.0
    while time_ns() < deadline
        x = sin(x + 1.0); GC.safepoint()
    end
    return x
end
function client(deadline, lat)
    done = Base.Event(true)
    while time_ns() < deadline
        t0 = time_ns()
        Threads.@spawn fair=true (burn(H); notify(done))
        wait(done)
        push!(lat, (time_ns() - t0) / 1e6)
    end
end
lats = [Float64[] for _ in 1:C]
deadline = time_ns() + round(UInt64, D * 1e9)
foreach(wait, [Threads.@spawn :interactive client(deadline, lats[i]) for i in 1:C])
counts = sort(length.(lats)); all = sort(reduce(vcat, lats))
println(VERSION, "  threads ", Threads.nthreads(:default), ",", Threads.nthreads(:interactive),
        "  tasks/s ", round(Int, length(all) / D), "  fair wait ≈ ", C * H / Threads.nthreads(:default), " ms")
println("latency ms: p50 ", round(all[end ÷ 2]; digits = 1), "  p99 ", round(all[ceil(Int, 0.99 * end)]; digits = 1),
        "  max ", round(all[end]; digits = 1))
println("tasks per client: min ", counts[1], "  median ", counts[end ÷ 2], "  max ", counts[end])
