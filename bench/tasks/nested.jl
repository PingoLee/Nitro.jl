# #618: what the multiqueue order variants do to NESTED (fork-join) parallelism. Every earlier
# #618 row spawned independent tasks; the objection a FIFO order meets is that depth-first order is
# what nested parallel code wants (JuliaLang/julia#35589: `<=` made `pfib` run ~forever). Each
# workload below spawns one branch, runs the other inline and waits, cut off to serial below a
# threshold:
#
#   fib     `pfib(n)` as in #35589: spawn n-2, recurse into n-1, `fetch`. Two cut-offs, fine and
#           coarse grain (FIB_FINE, FIB_COARSE, each "n:cut")
#   msort   a parallel mergesort of N Float64: spawn the left half, recurse into the right, wait,
#           merge serially (MSORT, "N:cut", leaves of at most `cut` elements go to `sort!`)
#   reduce  a fork-join sum over N Float64 by recursive halving (REDUCE, "N:cut")
#   fanout  the control with no nesting: tasks.jl's FanOut, N tiny tasks spawned by one task and
#           then waited on, repeated R times per run (FANOUT, "N:R")
#
# VARIANT=A|A0|B|C|D<K>|D-inf|E<K>|E-inf picks the multiqueue order (multiq_variant.jl, included
# first, before any task exists). The root of every workload is spawned on `:default`, so it starts
# there in both layouts.
#
# Each workload runs two passes in one process:
#   clean   no instrumentation: wall time, bytes allocated, GC time, GC pauses and full sweeps, and
#           peak RSS above the RSS at the start of the run (VmHWM, reset through clear_refs), per run.
#           A full `GC.gc()` precedes every run. RUNS runs after one warm-up, or fewer once BUDGET_S
#           seconds have gone (never fewer than 3).
#   counted the same code compiled with per-thread counters, INSTR_RUNS runs: every spawn bumps its
#           thread's `spawned`, every spawned task bumps `started` when it begins and `finished`
#           when it ends. At every spawn the spawner sums all threads' counters and keeps, per
#           thread, the peak of
#             queued  spawned - started: spawned and not yet begun (no stack yet)
#             live    started - finished: begun and not ended, each holding a stack
#             heaps   the tasks in the `:default` multiqueue heaps, which also counts parents woken
#                     from their `fetch` and waiting to resume (on a build whose scheduler is the
#                     work-stealing backend: its rings, LIFO slots and injection queue instead)
#           The reads race with other threads' writes, so each is a sample, not an exact count.
#           After each run spawned == started == finished is asserted: every spawned task completed.
#           Its wall time is reported only to show what the counting costs.
#
#   julia --threads=8,1 bench/tasks/nested.jl                 # one TSV line per workload on stdout
#   VARIANT=C ROUND=2 NOHEADER=1 julia --threads=8,0 bench/tasks/nested.jl
#   WHAT="fib_fine msort" RUNS=3 julia --threads=8,1 bench/tasks/nested.jl
#
#   RUNS, MIN_RUNS, BUDGET_S  clean runs: at most RUNS (7) after the warm-up, and none started past
#                             BUDGET_S (30) seconds once MIN_RUNS (3) are done
#   INSTR_RUNS                counted runs, at most (3); none started past BUDGET_S once one is done
#
# nested.sh runs one process per workload, so that a variant too slow for one workload is killed
# alone and peak RSS is not carried from one workload to the next.
#   julia bench/tasks/nested.jl --report results.tsv          # the Markdown tables of a TSV
#
# Every process checks its result, after the timing, against a serial run of the same recursion:
# equal Int for fib, equal to `sort` for msort, the same Float64 bits for reduce (the halving fixes
# the association order, so the sum does not depend on the schedule), the exact total for fanout.
# `--report` also refuses a TSV in which a workload's digest differs between variants or rounds of
# one build. VALIDATE=1 adds multiq_variant.jl's checks: single-heap order asserts, under C and D a
# live assert in every pop that it takes its heap's minimum, calls into the new code on every
# `:default` thread, and nothing left in the heaps at exit; under D also the slot probe, slot pops
# and steals in every workload (slot pops on every `:default` thread in fine-grain fib) and nothing
# left in the slots at exit (the fan-out needs steals only); under E the check_empty probes, the
# pop counts of every workload (periodic pops on every `:default` thread in fine-grain fib, none
# under E-inf) and empty deques at exit. Each validated run is under `multiq_watchdog`: a stall
# kills it.
#
# GUARD=1 (the default) holds one never-firing `Timer`, as spawn_order.jl does: on 1.13.0-rc3..1.13.2
# a process with no live timer can miss wake-ups (JuliaLang/julia#63882), a different bug.

include(joinpath(@__DIR__, "multiq_variant.jl"))
import Random
const VALIDATE = MULTIQ_VALIDATE
const GUARD_TIMER = get(ENV, "GUARD", "1") == "1" ? Timer(typemax(Int32)) : nothing

# ── counters (the counted pass only) ────────────────────────────────────────────────────────
# One 128-byte line per thread, written only by the tasks running on that thread. A task moves
# threads only at a yield point and there is none between a load and its store, so a plain
# read-modify-write cannot lose a count.

const STRIDE = 16
const NT = Threads.maxthreadid()
const CNT = zeros(Int, STRIDE * NT)
const SPAWNED, STARTED, FINISHED, PEAK_QUEUED, PEAK_LIVE, PEAK_HEAPS = 1, 2, 3, 4, 5, 6

@inline _ptr(tid::Int, k::Int) = pointer(CNT, STRIDE * (tid - 1) + k)
@inline _get(tid::Int, k::Int) = unsafe_load(_ptr(tid, k), :monotonic)
@inline _set!(tid::Int, k::Int, x::Int) = unsafe_store!(_ptr(tid, k), x, :monotonic)
@inline function _bump!(k::Int)
    tid = Threads.threadid()
    _set!(tid, k, _get(tid, k) + 1)
    return nothing
end
@inline _peak!(tid::Int, k::Int, x::Int) = x > _get(tid, k) && _set!(tid, k, x)

_in_heaps() = multiq_queued(Int(ccall(:jl_threadpoolid, Int8, (Int16,), Threads.threadid() - 1)) + 1)

@noinline function _sample!()
    s = st = f = 0
    for tid in 1:NT
        s += _get(tid, SPAWNED)
    end
    for tid in 1:NT
        st += _get(tid, STARTED)
    end
    for tid in 1:NT
        f += _get(tid, FINISHED)
    end
    me = Threads.threadid()
    _peak!(me, PEAK_QUEUED, s - st)
    _peak!(me, PEAK_LIVE, st - f)
    _peak!(me, PEAK_HEAPS, _in_heaps())
    return nothing
end

_total(k::Int) = sum(tid -> _get(tid, k), 1:NT)
_peak(k::Int) = maximum(tid -> _get(tid, k), 1:NT)
_reset_counters!() = fill!(CNT, 0)

# The one spawn every workload goes through. `Val(false)` is the clean pass: a plain `@spawn`.
@inline function spawn_task(f::F, ::Val{I}) where {F,I}
    if I
        _bump!(SPAWNED)
        _sample!()
        return Threads.@spawn (_bump!(STARTED); r = f(); _bump!(FINISHED); r)
    else
        return Threads.@spawn f()
    end
end

# ── workloads ───────────────────────────────────────────────────────────────────────────────

sfib(n::Int) = n <= 1 ? n : sfib(n - 1) + sfib(n - 2)

function pfib(n::Int, cut::Int, v::Val)
    n <= max(cut, 1) && return sfib(n)
    t = spawn_task(() -> pfib(n - 2, cut, v), v)
    return pfib(n - 1, cut, v) + fetch(t)::Int
end

# Merge v[lo:mid] and v[mid+1:hi], both sorted, in place, through tmp[lo:mid].
function merge_halves!(v::Vector{Float64}, tmp::Vector{Float64}, lo::Int, mid::Int, hi::Int)
    copyto!(tmp, lo, v, lo, mid - lo + 1)
    i, j, k = lo, mid + 1, lo
    @inbounds while i <= mid && j <= hi
        if v[j] < tmp[i]
            v[k] = v[j]; j += 1
        else
            v[k] = tmp[i]; i += 1
        end
        k += 1
    end
    @inbounds while i <= mid
        v[k] = tmp[i]; i += 1; k += 1
    end
    return nothing
end

function psort!(v::Vector{Float64}, tmp::Vector{Float64}, lo::Int, hi::Int, cut::Int, val::Val)
    if hi - lo + 1 <= cut
        sort!(view(v, lo:hi))
        return 0
    end
    mid = (lo + hi) >>> 1
    t = spawn_task(() -> psort!(v, tmp, lo, mid, cut, val), val)
    psort!(v, tmp, mid + 1, hi, cut, val)
    wait(t)
    merge_halves!(v, tmp, lo, mid, hi)
    return 0
end

function psum(x::Vector{Float64}, lo::Int, hi::Int, cut::Int, val::Val)
    hi - lo + 1 <= cut && return sum(view(x, lo:hi))
    mid = (lo + hi) >>> 1
    t = spawn_task(() -> psum(x, lo, mid, cut, val), val)
    r = psum(x, mid + 1, hi, cut, val)
    return fetch(t)::Float64 + r
end

# The same recursion with no task: the reference sum, bit for bit.
function ssum(x::Vector{Float64}, lo::Int, hi::Int, cut::Int)
    hi - lo + 1 <= cut && return sum(view(x, lo:hi))
    mid = (lo + hi) >>> 1
    l = ssum(x, lo, mid, cut)
    return l + ssum(x, mid + 1, hi, cut)
end

# tasks.jl's FanOut: n spawns of a tiny task from one task, then one wait for all, here with an
# explicit task vector (what `@sync` keeps) so the counted pass sees every spawn.
@noinline _tiny_work() = length("pong")

function fan_out(n::Int, reps::Int, v::Val)
    tasks = Vector{Task}(undef, n)
    total = 0
    for _ in 1:reps
        for j in 1:n
            tasks[j] = spawn_task(_tiny_work, v)
        end
        for t in tasks
            total += fetch(t)::Int
        end
    end
    return total
end

# ── one workload: setup, run, digest ────────────────────────────────────────────────────────

parse_pair(s) = Tuple(parse.(Int, split(s, ':')))

struct Workload
    name::String
    n::Int        # fib's n, msort's and reduce's length, fanout's tasks per wave
    cut::Int      # the serial cut-off; fanout: waves per run
    depth::Int    # the deepest chain of nested spawns
    setup!::Function
    run::Function # Val -> digest, a UInt64
    warm::Function # Val -> anything: the same code on a small instance, to compile it
    check::Function # digest -> nothing: against the serial reference
end

function workloads()
    ws = Workload[]
    for (name, var, def) in (("fib_fine", "FIB_FINE", "42:12"), ("fib_coarse", "FIB_COARSE", "45:25"))
        n, cut = parse_pair(get(ENV, var, def))
        push!(ws, Workload(name, n, cut, n - max(cut, 1), () -> nothing,
                           v -> UInt64(fetch(Threads.@spawn :default pfib(n, cut, v))),
                           v -> fetch(Threads.@spawn :default pfib(min(n, max(cut, 1) + 6), cut, v)),
                           d -> (d == sfib(n) || error("$name: pfib($n) = $d, sfib = $(sfib(n))"))))
    end
    let (n, cut) = parse_pair(get(ENV, "MSORT", "10000000:4096"))
        src = rand(Random.Xoshiro(618), n)
        v, tmp = similar(src), similar(src)
        ref = Ref{UInt64}(0)
        push!(ws, Workload("msort", n, cut, ceil(Int, log2(n / cut)), () -> copyto!(v, src),
                           function (val)
                               fetch(Threads.@spawn :default psort!(v, tmp, 1, n, cut, val))
                               return UInt64(GC.@preserve v Base._crc32c(
                                   unsafe_wrap(Array, Ptr{UInt8}(pointer(v)), sizeof(v))))
                           end,
                           val -> fetch(Threads.@spawn :default psort!(copy(src[1:8cut]), similar(tmp, 8cut),
                                                                       1, 8cut, cut, val)),
                           d -> (v == sort(src) || error("msort: result differs from sort"))))
    end
    let (n, cut) = parse_pair(get(ENV, "REDUCE", "100000000:16384"))
        x = rand(Random.Xoshiro(35589), n)
        push!(ws, Workload("reduce", n, cut, ceil(Int, log2(n / cut)), () -> nothing,
                           v -> reinterpret(UInt64, fetch(Threads.@spawn :default psum(x, 1, n, cut, v))),
                           v -> fetch(Threads.@spawn :default psum(x, 1, 8cut, cut, v)),
                           d -> (d == reinterpret(UInt64, ssum(x, 1, n, cut)) ||
                                 error("reduce: sum differs from the serial recursion's"))))
    end
    let (n, reps) = parse_pair(get(ENV, "FANOUT", "10000:50"))
        push!(ws, Workload("fanout", n, reps, 1, () -> nothing,
                           v -> UInt64(fetch(Threads.@spawn :default fan_out(n, reps, v))),
                           v -> fetch(Threads.@spawn :default fan_out(n, 1, v)),
                           d -> (d == 4 * n * reps || error("fanout: total $d"))))
    end
    what = split(get(ENV, "WHAT", join((w.name for w in ws), ' ')))
    return filter(w -> w.name in what, ws)
end

# ── measurement ─────────────────────────────────────────────────────────────────────────────

function proc_kib(field::String)
    for line in eachline("/proc/self/status")
        startswith(line, field) && return parse(Int, split(line)[2])
    end
    return -1
end

# Reset the peak RSS to the current RSS (Linux >= 4.0); false if this kernel refuses.
reset_hwm!() = try
    write("/proc/self/clear_refs", "5"); true
catch
    false
end

med(v) = (s = sort(v); n = length(s); isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)

function clean_runs(w::Workload, runs::Int, min_runs::Int, budget::Float64)
    w.warm(Val(false))                       # warm-up: compile
    rows = NamedTuple[]
    digest = UInt64(0)
    t_start = time()
    while length(rows) < runs && (length(rows) < min_runs || time() - t_start < budget)
        w.setup!()
        GC.gc()
        hwm_ok = reset_hwm!()
        rss0 = proc_kib("VmRSS:")
        multiq_watchdog(300)
        st = @timed w.run(Val(false))
        multiq_watchdog(0)
        hwm = hwm_ok ? (proc_kib("VmHWM:") - rss0) / 1024 : NaN
        d = st.value
        isempty(rows) ? (digest = d) : (d == digest || error("$(w.name): digest changed between runs"))
        push!(rows, (wall = st.time, bytes = st.bytes, gc = st.gctime, pauses = st.gcstats.pause,
                     full = st.gcstats.full_sweep, hwm = hwm))
    end
    return rows, digest
end

function counted_runs(w::Workload, runs::Int, budget::Float64, digest::UInt64)
    w.warm(Val(true))                        # warm-up: compile the counted code
    rows = NamedTuple[]
    t_start = time()
    while length(rows) < runs && (isempty(rows) || time() - t_start < budget)
        w.setup!()
        GC.gc()
        _reset_counters!()
        t0 = time_ns()
        multiq_watchdog(300)
        d = w.run(Val(true))
        multiq_watchdog(0)
        wall = (time_ns() - t0) / 1e9
        d == digest || error("$(w.name): counted run's digest differs from the clean run's")
        s, st, f = _total(SPAWNED), _total(STARTED), _total(FINISHED)
        s == st == f || error("$(w.name): spawned $s, started $st, finished $f")
        push!(rows, (wall = wall, spawned = s, queued = _peak(PEAK_QUEUED), live = _peak(PEAK_LIVE),
                     heaps = _peak(PEAK_HEAPS)))
    end
    return rows
end

const COLUMNS = ["julia", "commit", "threads", "guard", "variant", "round", "bench", "n", "cut",
                 "depth", "spawns", "runs", "wall_min_s", "wall_median_s", "alloc_mib_median",
                 "gc_ms_median", "gc_pct_median", "gc_pauses_median", "gc_full_median",
                 "hwm_mib_max", "peak_queued_median", "peak_live_median", "peak_heaps_median",
                 "peak_queued_max", "counted_wall_median_s", "digest"]

function measure()
    runs = parse(Int, get(ENV, "RUNS", VALIDATE ? "1" : "7"))
    min_runs = min(runs, parse(Int, get(ENV, "MIN_RUNS", "3")))
    budget = parse(Float64, get(ENV, "BUDGET_S", "30"))
    counted = parse(Int, get(ENV, "INSTR_RUNS", VALIDATE ? "1" : "3"))
    labels = (string(VERSION), MULTIQ_BUILD,
              string(Threads.nthreads(:default), ",", Threads.nthreads(:interactive)),
              GUARD_TIMER === nothing ? "0" : "1", MULTIQ_VARIANT, get(ENV, "ROUND", "1"))
    println(stderr, "nested: julia ", VERSION, " (", labels[2], "), threads ", labels[3],
            ", variant ", MULTIQ_VARIANT, VALIDATE ? " (VALIDATE)" : "")
    VALIDATE && multiq_unit_asserts()
    ws = workloads()
    get(ENV, "NOHEADER", "0") == "1" || println(join(COLUMNS, '\t'))
    for w in ws
        slots0 = multiq_slot_counts()
        budget0 = multiq_budget_counts()
        clean, digest = clean_runs(w, runs, min_runs, budget)
        cnt = counted_runs(w, counted, budget, digest)
        w.check(digest)
        # The fan-out's one spawner fills its own slot and the idle threads steal it: steals, few pops.
        VALIDATE && multiq_slot_check(w.name, slots0; pops = w.name != "fanout", steals = true,
                                      pops_everywhere = w.name == "fib_fine")
        # Under E only fine-grain fib keeps every `:default` thread popping for long enough that
        # each makes a periodic pop; the others need one somewhere.
        VALIDATE && multiq_budget_check(w.name, budget0; everywhere = w.name == "fib_fine")
        v(k) = [getfield(r, k) for r in clean]
        c(k) = [getfield(r, k) for r in cnt]
        r(x) = round(x; sigdigits = 4)
        wall = v(:wall)
        println(join((labels..., w.name, w.n, w.cut, w.depth, cnt[1].spawned, length(clean),
                      r(minimum(wall)), r(med(wall)), r(med(v(:bytes)) / 2^20), r(1e3 * med(v(:gc))),
                      r(100 * med(v(:gc) ./ wall)), med(v(:pauses)), med(v(:full)), r(maximum(v(:hwm))),
                      med(c(:queued)), med(c(:live)), med(c(:heaps)), maximum(c(:queued)),
                      r(med(c(:wall))), string(digest; base = 16)), '\t'))
        flush(stdout)
        println(stderr, "nested: ", MULTIQ_VARIANT, " ", w.name, ": result matches the serial ",
                "reference; every one of ", cnt[1].spawned, " spawned tasks completed, in ",
                length(cnt), " counted runs")
    end
    if VALIDATE && MULTIQ_VARIANT != "A"
        calls = multiq_variant_calls()
        tids = Threads.threadpooltids(:default)
        all(tid -> calls[tid] > 0, tids) || error("validate: no calls into the new code on some :default tid: ", calls[tids])
        println(stderr, "validate: calls into the new code per :default tid ", calls[tids])
    end
    multiq_variant_check()
end

# ── `--report <tsv>` ────────────────────────────────────────────────────────────────────────
# Per workload: wall time per build × layout × variant, the median over rounds of each process's
# median with [min–max], and C/A, B/A; then the peaks and GC. Refuses a TSV in which a workload's
# digest differs between variants or rounds of one build. Processes nested.sh killed are listed last.

function report(path::String)
    all_rows = [split(l, '\t') for l in eachline(path) if !isempty(l) && !startswith(l, "julia\t")]
    col(name) = findfirst(==(name), COLUMNS)
    get_(r, name) = r[col(name)]
    rows = filter(r -> get_(r, "digest") != "timeout", all_rows)
    killed = filter(r -> get_(r, "digest") == "timeout", all_rows)
    num(r, name) = parse(Float64, get_(r, name))
    fmt(x) = isnan(x) ? "–" : x >= 1000 ? string(round(Int, x)) : string(round(x; sigdigits = 3))
    cell(v) = length(v) == 1 ? fmt(v[1]) : string(fmt(med(v)), " [", fmt(minimum(v)), "–", fmt(maximum(v)), "]")
    for b in unique(get_(r, "bench") for r in rows), j in unique(get_(r, "julia") for r in rows)
        ds = unique(get_(r, "digest") for r in rows if get_(r, "bench") == b && get_(r, "julia") == j)
        length(ds) <= 1 || error("report: $b on julia $j has digests $ds across variants/rounds")
    end
    variants = filter(x -> any(r -> get_(r, "variant") == x, rows), ["A", "A0", "B", "C"])
    sel(b, j, t, x) = filter(r -> get_(r, "bench") == b && get_(r, "julia") == j &&
                                  get_(r, "threads") == t && get_(r, "variant") == x, rows)
    for b in unique(get_(r, "bench") for r in rows)
        any_row = first(filter(r -> get_(r, "bench") == b, rows))
        println("\n**", b, "** (n ", get_(any_row, "n"), ", cut ", get_(any_row, "cut"), ", depth ",
                get_(any_row, "depth"), ", ", get_(any_row, "spawns"), " spawns per run)\n")
        println("| build | layout | metric | ", join(variants, " | "), " | B/A | C/A |")
        println("|---|---|---|", repeat("--:|", length(variants) + 2))
        for j in unique(get_(r, "julia") for r in rows), t in unique(get_(r, "threads") for r in rows)
            metrics = (("wall median s", "wall_median_s"), ("peak queued", "peak_queued_median"),
                       ("peak live", "peak_live_median"), ("peak in heaps", "peak_heaps_median"),
                       ("GC %", "gc_pct_median"), ("GC pauses", "gc_pauses_median"),
                       ("peak RSS MiB", "hwm_mib_max"), ("counted wall s", "counted_wall_median_s"))
            for (label, name) in metrics
                vals = Dict(x => [num(r, name) for r in sel(b, j, t, x)] for x in variants)
                all(isempty, values(vals)) && continue
                ratio(x) = haskey(vals, x) && !isempty(vals[x]) && !isempty(get(vals, "A", Float64[])) &&
                           med(vals["A"]) != 0 ? string(round(med(vals[x]) / med(vals["A"]); digits = 2)) : "–"
                println("| ", j, " | ", t, " | ", label, " | ",
                        join((isempty(vals[x]) ? "–" : cell(vals[x]) for x in variants), " | "), " | ",
                        ratio("B"), " | ", ratio("C"), " |")
            end
        end
    end
    isempty(killed) || println("\nKilled by nested.sh's timeout: ",
        join((string(get_(r, "bench"), " ", get_(r, "variant"), " julia ", get_(r, "julia"), " ",
                     get_(r, "threads"), " round ", get_(r, "round")) for r in killed), "; "))
end

if length(ARGS) >= 2 && ARGS[1] == "--report"
    report(ARGS[2])
else
    measure()
end
