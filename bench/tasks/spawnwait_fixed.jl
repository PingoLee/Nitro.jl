# #618: SpawnWait as a fixed loop, for counters (agent-config #82 Idea 15). tasks.jl's `micro` times
# `wait(Threads.@spawn _tiny_work())` through BenchmarkTools, which picks its own sample count; a
# hardware counter needs a known number of operations. This runs that body exactly, N times after a
# warm-up, and prints N and the loop's wall time; run it at N and at 2N and take the difference of
# every counter, so start-up and compilation cancel (bench/julia/perf_unmarked.sh does).
#
#   N=3000000 julia --startup-file=no --threads=2,1 bench/tasks/spawnwait_fixed.jl
#
#   N      operations in the timed loop (3,000,000)
#   WARM   operations before it (200,000)
#   MODE   plain: the body as tasks.jl has it.
#          who: each child writes its thread id into a preallocated byte vector (no print, no
#          allocation in the loop); after the loop, the share of children per thread and the share
#          that ran on a thread other than the previous child's (and other than the spawner's).
#          split: four time_ns() stamps an operation into preallocated vectors (#618 A5): before
#          the spawn, the child's first and last statements, the main task back from `wait`. After the
#          loop: p10, p50, p90 and mean of pickup (spawn to child start), run (child start to end) and
#          wake (child end to resume), of the whole operation, of the period between consecutive
#          spawns, and the median over blocks of BT_EVALS (70) consecutive periods, which is the
#          statistic tasks.jl's SpawnWait row reports (BenchmarkTools: the median over samples of a
#          sample's time / evals; `evals` is tuned per run, 61-76 for this body on the bench box).
#          idle: no operation; after the handshake the main task sleeps IDLE_S (2) seconds, so with
#          JULIA_THREAD_SLEEP_THRESHOLD=infinite the :default threads spin empty turns the whole
#          window (#618 A6: the poll turn).
#   ATTACH  a path prefix: after the warm-up, write "<pid>" to <ATTACH>.ready and wait for
#          <ATTACH>.go before the loop, so `perf stat --per-thread -p <pid>` (which cannot launch a
#          command) can attach first; it counts until the process exits, and N vs 2N cancels both edges.
#
# Around the loop only, it also reads every OS thread's voluntary and involuntary context switches
# from /proc/self/task/*/status, keyed by Julia thread id (the OS tid of each Julia thread is read on
# that thread), and Base.gc_num()'s collection time. One tab-separated line on stdout.
# The process loads nothing but Base: no package, no precompile cache.

const N = parse(Int, get(ENV, "N", "3000000"))
const WARM = parse(Int, get(ENV, "WARM", "200000"))
const MODE = get(ENV, "MODE", "plain")
MODE in ("plain", "who", "split", "idle") || error("MODE must be plain, who, split or idle, not $MODE")
const IDLE_S = parse(Float64, get(ENV, "IDLE_S", "2"))
const BT_EVALS = parse(Int, get(ENV, "BT_EVALS", "70"))
const ATTACH = get(ENV, "ATTACH", "")

# tasks.jl's body, unchanged.
@noinline _tiny_work() = length("pong")

function loop(n::Int)
    for _ in 1:n
        wait(Threads.@spawn _tiny_work())
    end
end

# The instrumented body: the closure captures `i` only; the vector is a constant global.
const WHO = zeros(UInt8, max(N, WARM))
@noinline _tiny_work_who(i::Int) = (@inbounds WHO[i] = Threads.threadid() % UInt8; length("pong"))

function loop_who(n::Int)
    for i in 1:n
        wait(Threads.@spawn _tiny_work_who(i))
    end
end

# The split body: the stamps go to constant global vectors, the closure captures `i` only.
const NS = MODE == "split" ? max(N, WARM) : 1
const T0 = zeros(UInt64, NS); const T1 = zeros(UInt64, NS)
const T2 = zeros(UInt64, NS); const T3 = zeros(UInt64, NS)
@noinline function _tiny_work_split(i::Int)
    @inbounds T1[i] = time_ns()
    r = length("pong")
    @inbounds T2[i] = time_ns()
    return r
end

function loop_split(n::Int)
    for i in 1:n
        @inbounds T0[i] = time_ns()
        wait(Threads.@spawn _tiny_work_split(i))
        @inbounds T3[i] = time_ns()
    end
end

loop_idle(::Int) = sleep(IDLE_S)

# p10, p50, p90 and mean of a vector of nanoseconds, as "<name>_p10=…" fields.
function quantile_fields(name::String, v::Vector{Float64})
    s = sort(v)
    q(p) = s[clamp(round(Int, p * length(s)), 1, length(s))]
    r(x) = round(x; digits = 1)
    return ["$(name)_p10=$(r(q(0.1)))", "$(name)_p50=$(r(q(0.5)))", "$(name)_p90=$(r(q(0.9)))",
            "$(name)_mean=$(r(sum(s) / length(s)))"]
end

# Julia threads: both pools (`maxthreadid()` also counts slots no thread runs on, and a task placed
# there never starts).
const NJT = Threads.nthreads(:interactive) + Threads.nthreads(:default)

# The OS tid of each Julia thread, read on that thread (a sticky task placed on it).
function os_tids()
    out = zeros(Int, NJT)
    for tid in 1:NJT
        t = Task(() -> (out[Threads.threadid()] = Int(ccall(:gettid, Cint, ())); nothing))
        t.sticky = true
        ccall(:jl_set_task_tid, Cint, (Any, Cint), t, tid - 1)
        schedule(t)
        wait(t)
    end
    return out
end

# (voluntary, involuntary) context switches of every OS thread of this process, by OS tid.
function ctx_switches()
    d = Dict{Int, Tuple{Int, Int}}()
    for tid in readdir("/proc/self/task")
        v = iv = -1
        try
            for line in eachline("/proc/self/task/$tid/status")
                startswith(line, "voluntary_ctxt_switches:") && (v = parse(Int, split(line)[2]))
                startswith(line, "nonvoluntary_ctxt_switches:") && (iv = parse(Int, split(line)[2]))
            end
        catch
            continue   # a thread that exited between readdir and open
        end
        d[parse(Int, tid)] = (v, iv)
    end
    return d
end

function main()
    tids = os_tids()
    f = MODE == "plain" ? loop : MODE == "who" ? loop_who : MODE == "split" ? loop_split : loop_idle
    MODE == "idle" ? loop(WARM) : f(WARM)
    fill!(WHO, 0x00)
    if !isempty(ATTACH)
        write(ATTACH * ".ready", string(getpid()))
        while !isfile(ATTACH * ".go")
            sleep(0.005)
        end
    end
    GC.gc()
    c0 = ctx_switches(); g0 = Base.gc_num(); t0 = time_ns()
    f(N)
    t1 = time_ns(); g1 = Base.gc_num(); c1 = ctx_switches()
    loop_ns = Int(t1 - t0)
    gc_ns = Int(g1.total_time - g0.total_time)
    gc_count = Int(g1.pause - g0.pause)

    # Context switches: per Julia thread, then every other OS thread of the process together.
    v_by = String[]; iv_by = String[]
    for (j, ost) in enumerate(tids)
        a = get(c0, ost, (0, 0)); b = get(c1, ost, (0, 0))
        push!(v_by, "$j:$(b[1] - a[1])"); push!(iv_by, "$j:$(b[2] - a[2])")
    end
    vo = ivo = 0
    for (ost, b) in c1
        ost in tids && continue
        a = get(c0, ost, (0, 0))
        vo += b[1] - a[1]; ivo += b[2] - a[2]
    end

    spawner = Threads.threadid()
    fields = String[
        "fixed", "build=$(Base.GIT_VERSION_INFO.commit_short)", "version=$(VERSION)",
        "layout=$(Threads.nthreads(:default)),$(Threads.nthreads(:interactive))", "mode=$MODE",
        "n=$N", "warm=$WARM", "loop_ns=$loop_ns", "ns_per_op=$(round(loop_ns / N; digits = 2))",
        "gc_ns=$gc_ns", "gc_pauses=$gc_count",
        "spawner_tid=$spawner", "spawner_pool=$(Threads.threadpool(spawner))", "pid=$(getpid())",
        "os_tid_by_jtid=$(join(["$j:$t" for (j, t) in enumerate(tids)], ','))",
        "vcs_by_jtid=$(join(v_by, ','))", "ivcs_by_jtid=$(join(iv_by, ','))",
        "vcs_other_os_threads=$vo", "ivcs_other_os_threads=$ivo",
    ]
    if MODE == "who"
        w = @view WHO[1:N]
        counts = [count(==(UInt8(j)), w) for j in 1:NJT]
        switched = count(i -> w[i] != w[i - 1], 2:N)
        on_spawner = counts[spawner]
        push!(fields, "child_share_by_jtid=" *
                      join(["$j:$(round(counts[j] / N; digits = 5))" for j in eachindex(counts)], ','))
        push!(fields, "share_on_spawner_thread=$(round(on_spawner / N; digits = 5))")
        push!(fields, "share_thread_changed=$(round(switched / (N - 1); digits = 5))")
        any(==(0x00), w) && push!(fields, "UNRECORDED=$(count(==(0x00), w))")
    end
    if MODE == "split"
        d(a, b) = Float64[Int64(b[i]) - Int64(a[i]) for i in 1:N]
        append!(fields, quantile_fields("pickup", d(T0, T1)))
        append!(fields, quantile_fields("run", d(T1, T2)))
        append!(fields, quantile_fields("wake", d(T2, T3)))
        append!(fields, quantile_fields("op", d(T0, T3)))
        append!(fields, quantile_fields("period", Float64[Int64(T0[i + 1]) - Int64(T0[i]) for i in 1:N-1]))
        nb = (N - 1) ÷ BT_EVALS
        blocks = sort!([(Int64(T0[(b - 1) * BT_EVALS + 1 + BT_EVALS]) - Int64(T0[(b - 1) * BT_EVALS + 1])) / BT_EVALS for b in 1:nb])
        push!(fields, "bt_evals=$BT_EVALS", "bt_blocks=$nb", "bt_median=$(round(blocks[(nb + 1) ÷ 2]; digits = 1))")
    end
    println(join(fields, '\t'))
end

main()
