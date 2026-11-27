# #618, the fifth version's change A: does `fair=false` keep a background loop that a marked request
# starts lazily out of the request work, while 500 marked clients run the starved cell?
#
#   <v5-validate julia> --threads=8,1 bench/julia/optout_check.jl optout   the loop spawned with fair=false
#   <v5-validate julia> --threads=8,1 bench/julia/optout_check.jl omit     THE POSITIVE CONTROL: the keyword left out
#
# The starved cell of candidate/starved.jl in its `fair` mode: 500 clients on :interactive, each spawning a
# 2 ms compute task on :default with `fair=true` and waiting for it, for 8 s after a 1 s warm-up. Beside it, a
# marked root (`@spawn fair=true`) starts the background loop and returns at once. The loop, until the cell's
# deadline: spawn one child that burns BG_MS (1 ms), wait for it, sleep 1 ms (about half a thread). Each child
# records its own class when it starts.
#
# Read from the validation build's counters (Base.Partr.sched_counts, summed over threads) over the timed cell:
# the opted-out first enqueues (`opt_out`), the stock first enqueues (`l_first`), the R heaps' first enqueues and
# re-enqueues (`r_first`, `r_again`), the descendants (`desc`).
#   optout: PASS when every child ran with no class, the R heaps took no task at all (r_first and r_again 0:
#           the clients' tasks go to the rings, nothing else in the cell is request work), the loop's one
#           opted-out enqueue is counted (opt_out 1), stock took at least the children (l_first), and the cell's
#           p99 is under 200 ms.
#   omit:   the positive control: PASS (for the control: the check can see the difference) when every child
#           ran with class R and the R heaps took at least the children (r_first >= children). Its p99 is
#           reported, with no bar.
# A client that never gets its task back hangs the cell: the caller's timeout is the "task lost" signal.
const MODE = get(ARGS, 1, "")
MODE in ("optout", "omit") || error("usage: optout_check.jl optout|omit")
const P = Base.Partr
isdefined(P, :C_STOCK) || error("optout_check: this build has no opt-out (Base.Partr.C_STOCK)")
isdefined(P, :SCHED_VALIDATE) && P.SCHED_VALIDATE || error("optout_check: needs the validation build (sched_counts)")
const C, H, D = 500, 2.0, 8.0
const BG_MS = 1.0
const ID = string(VERSION, " ", Base.GIT_VERSION_INFO.commit_short)
cls() = @atomic :monotonic current_task().sched_class

function burn(ms)                       # busy compute, no yield, no allocation
    deadline = time_ns() + round(UInt64, ms * 1e6)
    x = 0.0
    while time_ns() < deadline
        x = sin(x + 1.0)
        GC.safepoint()
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
# the background loop; `seen[c + 1]` counts the children that ran with class c
function bgloop(deadline, seen)
    while time_ns() < deadline
        t = Threads.@spawn (Threads.atomic_add!(seen[cls() + 1], 1); burn(BG_MS))
        wait(t)
        sleep(0.001)
    end
end
start_bg(deadline, seen) = MODE == "optout" ? (Threads.@spawn fair=false bgloop(deadline, seen)) :
                                              (Threads.@spawn bgloop(deadline, seen))
function cell(d)
    seen = [Threads.Atomic{Int}(0) for _ in 1:4]
    lats = [Float64[] for _ in 1:C]
    deadline = time_ns() + round(UInt64, d * 1e9)
    bg = fetch(Threads.@spawn fair=true start_bg(deadline, seen))   # the marked request starts it and returns
    foreach(wait, [Threads.@spawn :interactive client(deadline, lats[i]) for i in 1:C])
    wait(bg)
    return lats, [s[] for s in seen]
end
const guard = Timer(typemax(Int32))     # nothing waits on it (keeps JuliaLang/julia#63882 out on 1.13)
cell(1.0)
c0 = P.sched_counts()
lats, seen = cell(D)
c1 = P.sched_counts()
dd(k) = getfield(c1, k) - getfield(c0, k)
counts = sort(length.(lats))
all = sort(reduce(vcat, lats))
pct(p) = round(all[clamp(ceil(Int, p * length(all)), 1, length(all))]; digits = 1)
nbg = sum(seen)
p99 = pct(0.99)
println("optout_check ", ID, ": threads=", Threads.nthreads(:default), ",", Threads.nthreads(:interactive),
        " mode=", MODE, " tasks_per_s=", round(Int, length(all) / D), " p50_ms=", pct(0.5), " p99_ms=", p99,
        " max_ms=", round(all[end]; digits = 1), " client_min=", counts[1], " client_median=", counts[(end + 1) ÷ 2])
println("optout_check: loop children ", nbg, " by class at start: none ", seen[1], ", F ", seen[2], ", R ", seen[3],
        ", stock-flag ", seen[4], "; counters over the cell: opt_out ", dd(:opt_out), ", l_first ", dd(:l_first),
        ", r_first ", dd(:r_first), ", r_again ", dd(:r_again), ", desc ", dd(:desc), ", f_first ", dd(:f_first))
ok = if MODE == "optout"
    seen[1] == nbg && nbg > 0 && dd(:r_first) == 0 && dd(:r_again) == 0 && dd(:opt_out) == 1 &&
        dd(:l_first) >= nbg && p99 < 200
else
    seen[3] == nbg && nbg > 0 && dd(:r_first) >= nbg
end
println("optout_check: ", MODE, ok ? " PASS" : " FAIL",
        MODE == "optout" ? " (children unclassed, nothing on the R heaps, opt_out 1, stock took the children, p99 < 200 ms)" :
                           " (positive control: children R, counted on the R heaps)")
exit(ok ? 0 : 1)
