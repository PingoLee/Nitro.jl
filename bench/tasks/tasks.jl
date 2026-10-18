# Task-primitive measurements, Julia side (#469 part 2). Twin of go/tasks_test.go and go/main.go:
# the same shapes, so the two isolate the runtimes from HTTP. Run it through run.sh, which pins
# both to the same CPUs with the Julia default thread count equal to GOMAXPROCS.
#
#   julia --project=bench --threads=8,1 bench/tasks/tasks.jl [micro] [queued] [parked] [spin]
#   VARIANT=B FAN_OUT_NS="1000 10000" julia --project=bench --threads=8,1 bench/tasks/tasks.jl micro
#
#   VARIANT  the multiqueue order (multiq_variant.jl, #618), applied before anything else runs
#   FAN_OUT_NS  the fan-out sizes of `micro`, "1000" by default
#
#   micro   BenchmarkTools: spawn + wait one at a time (bench/suite/taskpattern.jl's
#           `spawn_single`, the shape of Nitro's per-request spawn), a ping-pong round trip over
#           unbuffered channels, and a fan-out of 1000 tasks with one wait for all.
#   queued  every `:default` thread held busy while N tasks are spawned, then released: the drain
#           time per task with all N waiting in the multiqueue heaps (QUEUED_NS, QUEUED_REPS)
#   parked  100,000 tasks blocked on one `Base.Event`: creation time and resident memory per task.
#   spin    one task per `:default` thread that computes for 1.5 s without yielding, and a
#           heartbeat that wants to wake every 1 ms -- once on `:default` (where Nitro runs
#           handlers) and once on `:interactive` (where HTTP.jl runs connection tasks). A third
#           pass has the spinners `yield()` about every millisecond.
#
# Every line is `kind <TAB> runtime <TAB> ...`, the format go/ prints, so run.sh can keep both.
include(joinpath(@__DIR__, "multiq_variant.jl"))
using BenchmarkTools

@noinline _tiny_work() = length("pong")

function rss_kib()
    for line in eachline("/proc/self/status")
        startswith(line, "VmRSS:") && return parse(Int, split(line)[2])
    end
    return -1
end

# ── micro ───────────────────────────────────────────────────────────────────────────────────

const FAN_OUT_NS = parse.(Int, split(get(ENV, "FAN_OUT_NS", "1000")))
const FAN_OUT_RESULTS = zeros(Int, maximum(FAN_OUT_NS))

function fan_out(n::Int)
    @sync for j in 1:n
        Threads.@spawn @inbounds FAN_OUT_RESULTS[j] = _tiny_work()
    end
end

function report(name, trial; per = 1, unit = "op")
    m = median(trial)
    println("micro\tjulia\t", name, "\tns_per_", unit, "=", round(m.time / per; digits = 1),
            "\tbytes_per_op=", m.memory, "\tallocs_per_op=", m.allocs)
end

function micro()
    report("SpawnWait", @benchmark wait(Threads.@spawn _tiny_work()))

    a, b = Channel{Int}(0), Channel{Int}(0)
    echo = Threads.@spawn for v in a
        put!(b, v)
    end
    report("PingPong", @benchmark (put!($a, 1); take!($b)))
    close(a); wait(echo)

    for n in FAN_OUT_NS
        trial = @benchmark fan_out($n)
        report("FanOut$n", trial)
        report("FanOut$n", trial; per = n, unit = "task")
    end
end

# ── queued ──────────────────────────────────────────────────────────────────────────────────
# The fan-out rows never queue deeply: one
# spawner cannot outrun the threads popping, so the multiqueue heaps stay a few tasks deep, and a
# cost that grows with heap depth (#618's variant B) does not show there. Here every `:default`
# thread except the spawner's is held by a spinner while `n` tasks are spawned, so all `n` sit in
# the heaps (about n / 16 per heap at 8 threads); then the spinners are released and the drain is
# timed: release -> every task done, per task.

const QUEUED_NS = parse.(Int, split(get(ENV, "QUEUED_NS", "10000 100000")))
const QUEUED_REPS = parse(Int, get(ENV, "QUEUED_REPS", "5"))
const QUEUED_DONE = Threads.Atomic{Int}(0)

function queued_once(n::Int)
    hold = Threads.Atomic{Bool}(true)
    started = Threads.Atomic{Int}(0)
    # A spinner on every :default thread, less the one this task is on if it is a :default one.
    k = Threads.nthreads(:default) - (Threads.threadpool() === :default ? 1 : 0)
    spinners = [Threads.@spawn :default (Threads.atomic_add!(started, 1);
                                         while hold[]; GC.safepoint(); end) for _ in 1:k]
    while started[] < k
        yield()
    end
    QUEUED_DONE[] = 0
    t0 = time_ns()
    tasks = Vector{Task}(undef, n)
    for j in 1:n
        tasks[j] = Threads.@spawn :default (Threads.atomic_add!(QUEUED_DONE, 1); nothing)
    end
    t1 = time_ns()
    hold[] = false
    foreach(wait, tasks)
    t2 = time_ns()
    foreach(wait, spinners)
    return (t1 - t0) / n, (t2 - t1) / n
end

function queued()
    for n in QUEUED_NS
        queued_once(n)   # compile, and warm the heaps' storage
        rs = [queued_once(n) for _ in 1:QUEUED_REPS]
        spawn, drain = sort(first.(rs)), sort(last.(rs))
        mid = (QUEUED_REPS + 1) ÷ 2
        println("queued\tjulia\tQueued", n, "\tspawn_ns_per_task=", round(spawn[mid]; digits = 1),
                "\tdrain_ns_per_task=", round(drain[mid]; digits = 1),
                "\tdrain_min=", round(drain[1]; digits = 1), "\tdrain_max=", round(drain[end]; digits = 1))
    end
end

# ── parked ──────────────────────────────────────────────────────────────────────────────────

function parked(n::Int = 100_000)
    GC.gc(true)
    rss0 = rss_kib()
    ev = Base.Event()
    started = Threads.Atomic{Int}(0)
    t0 = time_ns()
    tasks = Vector{Task}(undef, n)
    for i in 1:n
        tasks[i] = Threads.@spawn (Threads.atomic_add!(started, 1); wait(ev))
    end
    # A task that has not run yet has no stack in use; count only once every one is parked.
    while started[] < n
        yield()
    end
    create = time_ns() - t0
    rss1 = rss_kib()
    t1 = time_ns()
    notify(ev)
    foreach(wait, tasks)
    wake = time_ns() - t1
    println("parked\tjulia\t", n, "\tcreate_ns_per_task=", round(Int, create / n),
            "\twake_all_ns_per_task=", round(Int, wake / n),
            "\trss_kib_per_task=", round((rss1 - rss0) / n; digits = 2))
end

# ── spin ────────────────────────────────────────────────────────────────────────────────────

# No call, no allocation, no I/O: nothing in it can make the task yield. `GC.safepoint()` is not
# a yield point; it only lets a collection the heartbeat triggers proceed instead of waiting for
# every spinner to finish -- the same choice bench/socket/server.jl's `burn` makes, so the
# measurement is scheduling, not GC. `yield_every > 0` adds a `yield()` every that many iterations
# (a countdown, not `%`: a division per iteration would triple the loop's cost).
function spin_loop(iters::UInt64, yield_every::UInt64)
    x = UInt64(1)
    left = yield_every
    for i in UInt64(0):iters-1
        x = x * 0x5851f42d4c957f2d + i
        GC.safepoint()
        if yield_every > 0 && (left -= 1) == 0
            yield()
            left = yield_every
        end
    end
    return x
end

# Spawn `n` spinners of `iters` on `:default`; each task's result is its own wall time in seconds.
spin_all(n::Int, iters::UInt64, yield_every::UInt64) =
    [Threads.@spawn :default (t = time_ns(); spin_loop(iters, yield_every); (time_ns() - t) / 1e9)
     for _ in 1:n]

# The "other request": wants to wake at `spawned + k ms` for k = 1..100. Lateness is charged
# against that schedule from the moment it was SPAWNED, so a heartbeat that cannot even start
# while the spinners hold every thread is charged the wait -- which is the stall.
function heartbeat!(lat::Vector{Float64}, spawned::UInt64)
    for k in 1:100
        due = spawned + UInt64(k) * 1_000_000
        now = time_ns()
        now < due && sleep((due - now) / 1e9)
        push!(lat, (Int64(time_ns()) - Int64(due)) / 1e6)
    end
end

function spin_pass(iters::UInt64, yield_every::UInt64, pool::Symbol, label::String)
    n = Threads.nthreads(:default)
    spinners = spin_all(n, iters, yield_every)
    lat = Float64[]
    spawned = time_ns()
    hb = pool === :interactive ? Threads.@spawn(:interactive, heartbeat!(lat, spawned)) :
                                 Threads.@spawn(:default, heartbeat!(lat, spawned))
    wait(hb)
    spun = maximum(fetch, spinners)
    sort!(lat)
    r(x) = round(x; digits = 3)
    println("spin\t", label, "\t", n, " spinners, heartbeat on :", pool,
            "\tlateness_p50_ms=", r(lat[51]), "\tlateness_p99_ms=", r(lat[99]),
            "\tlateness_max_ms=", r(lat[100]), "\tlongest_spinner_s=", r(spun))
end

function spin()
    n = Threads.nthreads(:default)
    foreach(wait, spin_all(n, UInt64(1000), UInt64(10)))                       # compile
    # Calibrate with every spinner running at once: SMT siblings and the clock under full load
    # make one spinner alone several times faster than eight together.
    probe = UInt64(100_000_000)
    per = maximum(fetch, spin_all(n, probe, UInt64(0)))
    iters = UInt64(round(probe * 1.5 / per))
    every_ms = UInt64(round(probe * 0.001 / per))
    spin_pass(iters, UInt64(0), :default, "julia")
    Threads.nthreads(:interactive) > 0 && spin_pass(iters, UInt64(0), :interactive, "julia")
    spin_pass(iters, every_ms, :default, "julia_yield_1ms")
end

# ────────────────────────────────────────────────────────────────────────────────────────────

println(stderr, "Julia ", VERSION, " threads default=", Threads.nthreads(:default),
        " interactive=", Threads.nthreads(:interactive))
what = isempty(ARGS) ? ["micro", "parked", "spin"] : ARGS
"micro" in what && micro()
"queued" in what && queued()
"parked" in what && parked()
"spin" in what && spin()
