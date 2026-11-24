# The spawn path with everything marked: what the mark costs where it is used. Standard library only.
#
#   julia --threads=8,0 spawn_path.jl [plain|fair] [clients]
#
# `clients` (default 500) closed-loop clients on :default; each spawns a task that does no work but
# notify the client, and waits for it, for 8 s after a 1 s warm-up. `fair` marks the clients and
# every task they spawn (a build without the keyword says so and exits 0). Prints one line: the
# requests served per second.
const FAIR = get(ARGS, 1, "plain") == "fair"
const C = parse(Int, get(ARGS, 2, "500"))
const D = 8.0
const ID = string(VERSION, " ", Base.GIT_VERSION_INFO.commit_short)
const HAS_FAIR = try
    wait(Core.eval(Main, :(Threads.@spawn fair=false nothing)))
    true
catch
    false
end
FAIR && !HAS_FAIR && (println("spawn_path ", ID, ": fair= not supported by this build"); exit(0))

if FAIR
    @eval function client(deadline, n)
        done = Base.Event(true)
        k = 0
        while time_ns() < deadline
            Threads.@spawn fair=true notify(done)
            wait(done)
            k += 1
        end
        n[] = k
    end
    @eval start(f) = Threads.@spawn :default fair=true f()
else
    function client(deadline, n)
        done = Base.Event(true)
        k = 0
        while time_ns() < deadline
            Threads.@spawn notify(done)
            wait(done)
            k += 1
        end
        n[] = k
    end
    start(f) = Threads.@spawn :default f()
end
function cell(d)
    ns = [Ref(0) for _ in 1:C]
    deadline = time_ns() + round(UInt64, d * 1e9)
    t0 = time_ns()
    foreach(wait, [start(() -> client(deadline, ns[i])) for i in 1:C])
    return sum(n[] for n in ns) / ((time_ns() - t0) / 1e9)
end
cell(1.0)
rps = cell(D)
println("spawn_path ", ID, ": threads=", Threads.nthreads(:default), ",", Threads.nthreads(:interactive),
        " mode=", FAIR ? "fair" : "plain", " clients=", C, " rps=", round(Int, rps))
