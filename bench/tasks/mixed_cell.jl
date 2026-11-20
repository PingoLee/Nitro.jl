# #618, the mixed cell: the starved cell while fork-join work runs on the same pool.
#
# Under M-l a marked task runs only when stock's heaps are empty, so sustained unmarked work could
# hold every marked task back. This runs spawn_order.jl's starved cell (C = 500 clients on
# `:interactive`, H = 2 ms handlers, D = 8 s, --threads=8,1) while `fib_fine` (nested.jl's
# `pfib(42)` cut at 12, unmarked, on `:default`) loops back to back for the whole cell, started
# when the cell's clock starts. Each process first times `fib_fine` alone (ALONE_RUNS runs, back
# to back, the way the loop runs them), then the cell. One TSV row per process: the request
# metrics, and `fib_fine`'s wall alone and during the cell (only the runs that ended before the
# last client did; the run still going when the clients stop is dropped).
#
#   VARIANT=A|C|M-l|M-h-l|...   as spawn_order.jl (M-l marks handlers and clients; the clients sit
#                               in the one-thread `:interactive` pool, so only the handlers reach
#                               the F queue; M-h-l marks the handlers only)
#   C, H, D                     500, 2, 8;  FIB_FINE "42:12";  ALONE_RUNS 5;  ROUND 1
#   SHAPE=plain|inner|inner20|async   (async, #618 the battery: spawn_order.jl's async shape)
#                               inner: the mixed-inner cell (2026-11-16, agent-config #82 Idea 5): the
#                               handlers spawn four `:default` children of H/4 and fetch them, the
#                               inner shape of spawn_order.jl, while fib_fine loops beside them; the
#                               row gains the shape and the handler wall p50/p99 (ms) at its end
#                               (inner20: the same with the fork-join inside one of SLOTS = 20
#                               semaphore slots, see spawn_order.jl; the row also carries the
#                               requests in flight and the slot wait)
#   BG=loops:<n>                the half-pool cell: n loops of short chunks instead of fib_fine (above
#                               loop_run); run it with C small enough that C + n <= 8
#   NOHEADER=1                  no header line
#   VALIDATE=1                  as spawn_order.jl: the variant's asserts and probes, every handler
#                               accounted for, the classification (F first-inserts = the handlers
#                               under M, the fib tasks all L), the F queue empty after the cell,
#                               and every fib_fine result equal to fib(42)
#
#   taskset -c 0,1,2,3,6,7,8,9 julia --threads=8,1 bench/tasks/mixed_cell.jl >> mixed.tsv
# The driver is rounds_fifo.sh (BLOCKS=mixed); the table is aggregate_fifo.jl's `mixed` mode.

include(joinpath(@__DIR__, "spawn_order.jl"))

const MIX_C = parse(Int, get(ENV, "C", "500"))
const MIX_H = parse(Float64, get(ENV, "H", "2"))
const MIX_D = parse(Float64, get(ENV, "D", "8"))
const FIB_N, FIB_CUT = parse.(Int, split(get(ENV, "FIB_FINE", "42:12"), ':'))
const ALONE_RUNS = parse(Int, get(ENV, "ALONE_RUNS", "5"))
const MIX_SHAPE = get(ENV, "SHAPE", "plain")
MIX_SHAPE in ("plain", "inner", "inner20", "async") || error("mixed_cell: SHAPE must be plain, inner, inner20 or async")

mix_sfib(n::Int) = n <= 1 ? n : mix_sfib(n - 1) + mix_sfib(n - 2)
function mix_pfib(n::Int, cut::Int)
    n <= max(cut, 1) && return mix_sfib(n)
    t = Threads.@spawn mix_pfib(n - 2, cut)
    return mix_pfib(n - 1, cut) + fetch(t)::Int
end
const FIB_REF = mix_sfib(FIB_N)

# BG=loops:<n> (the half-pool cell): instead of fib_fine, n unmarked loops on `:default`, each
# running chunks of `sfib(24)` with a `yield()` between chunks, so each needs one thread and the
# pool is not over capacity when C + n <= 8. One "run" is 400 chunks; its wall is what the fib_*
# columns then report.
const BG = get(ENV, "BG", "fib")
const BG_LOOPS = BG == "fib" ? 0 : startswith(BG, "loops:") ? parse(Int, BG[7:end]) :
                 error("mixed_cell: BG must be fib or loops:<n>")
const UNIT_N, UNITS_PER_RUN = 24, 400
const UNIT_REF = mix_sfib(UNIT_N)
function loop_run()
    t0 = time_ns()
    acc = 0
    for _ in 1:UNITS_PER_RUN
        acc += mix_sfib(UNIT_N)
        yield()
    end
    t1 = time_ns()
    acc == UNITS_PER_RUN * UNIT_REF || error("mixed_cell: a loop computed $acc")
    return (t1 - t0) / 1e9, t1
end

# One fib_fine run, rooted on `:default` as nested.jl roots it: (wall s, end stamp).
function fib_once()
    t0 = time_ns()
    r = fetch(Threads.@spawn :default mix_pfib(FIB_N, FIB_CUT))::Int
    t1 = time_ns()
    r == FIB_REF || error("mixed_cell: fib_fine returned $r, expected $FIB_REF")
    return (t1 - t0) / 1e9, t1
end

const MIX_COLUMNS = ["julia", "commit", "threads", "guard", "variant", "round", "c", "h_ms", "d_s",
                     "rps", "p50_ms", "p99_ms", "max_ms", "count_min", "count_median", "jain",
                     "slow1_spawn_to_start_pct", "slow1_end_to_wake_pct",
                     "fib_alone_median_s", "fib_alone_min_s", "fib_alone_max_s",
                     "fib_runs", "fib_median_s", "fib_min_s", "fib_max_s", "fib_walls_s",
                     "shape", "hw_p50_ms", "hw_p99_ms",
                     "inflight_mean", "inflight_peak", "slot_wait_p50_ms", "slot_wait_p99_ms"]

med(v) = (s = sort(v); n = length(s); n == 0 ? NaN : isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)

function mixed()
    Threads.nthreads(:interactive) > 0 || error("mixed_cell: needs an :interactive thread (--threads=8,1)")
    println(stderr, "mixed_cell: julia ", VERSION, " (", Base.GIT_VERSION_INFO.commit_short, "), threads ",
            Threads.nthreads(:default), ",", Threads.nthreads(:interactive), ", variant ", MULTIQ_VARIANT,
            ", C = ", MIX_C, ", H = ", MIX_H, " ms, D = ", MIX_D, " s, ",
            BG_LOOPS == 0 ? "fib_fine $(FIB_N):$(FIB_CUT)" : "$(BG_LOOPS) loops of sfib($(UNIT_N)) x $(UNITS_PER_RUN)",
            " looping on :default, shape ", MIX_SHAPE)
    VALIDATE && multiq_unit_asserts()
    # Compile both halves before timing; not reported.
    run_cell("spawn", :interactive, 8, 0.1, 0.2, MIX_SHAPE)
    fetch(Threads.@spawn :default mix_pfib(min(FIB_N, FIB_CUT + 8), FIB_CUT))
    GC.gc()
    walls, ends = Float64[], UInt64[]
    bg = Ref{Task}()
    if BG_LOOPS == 0
        alone = [fib_once()[1] for _ in 1:ALONE_RUNS]
        loop = deadline -> (bg[] = Threads.@spawn :default begin
            while time_ns() < deadline
                w, e = fib_once()
                push!(walls, w)
                push!(ends, e)
            end
        end)
    else
        # BG=loops:<n>: n unmarked loops, each its own task, timed alone together first.
        loop_run()
        alone = reduce(vcat, fetch.([Threads.@spawn :default [loop_run()[1] for _ in 1:ALONE_RUNS] for _ in 1:BG_LOOPS]))
        loop = deadline -> (bg[] = Threads.@spawn :default begin
            parts = fetch.([Threads.@spawn :default begin
                w, e = Float64[], UInt64[]
                while time_ns() < deadline
                    x, y = loop_run()
                    push!(w, x)
                    push!(e, y)
                end
                (w, e)
            end for _ in 1:BG_LOOPS])
            for (w, e) in parts
                append!(walls, w)
                append!(ends, e)
            end
        end)
    end
    if VALIDATE
        HANDLED[] = 0; TID_MOVED[] = 0; INNER_RUN[] = 0; INNER_BAD[] = 0; ASYNC_RUN[] = 0; ASYNC_OFF[] = 0; ASYNC_PSTICKY[] = 0
    end
    fifo0 = multiq_fifo_counts()
    share0, sfifo0 = multiq_share_counts(), share_fifo_pops()
    multiq_watchdog(ceil(Int, MIX_D) + 120)
    recs, wall = run_cell("spawn", :interactive, MIX_C, MIX_H, MIX_D, MIX_SHAPE; onstart = loop)
    clients_done = time_ns()
    wait(bg[])
    multiq_watchdog(0)
    inside = walls[ends .<= clients_done]
    m = metrics(recs, wall)
    r6(x) = round(x; sigdigits = 4)
    labels = (string(VERSION), MULTIQ_BUILD, string(Threads.nthreads(:default), ",", Threads.nthreads(:interactive)),
              GUARD_TIMER === nothing ? "0" : "1", MULTIQ_VARIANT, get(ENV, "ROUND", "1"))
    get(ENV, "NOHEADER", "0") == "1" || println(join(MIX_COLUMNS, '\t'))
    println(join((labels..., MIX_C, MIX_H, MIX_D, m.rps, m.p50, m.p99, m.max, m.cmin, m.cmed, m.jain,
                  m.s2s_share, m.e2w_share, r6(med(alone)), r6(minimum(alone)), r6(maximum(alone)),
                  length(inside), r6(med(inside)), isempty(inside) ? NaN : r6(minimum(inside)),
                  isempty(inside) ? NaN : r6(maximum(inside)), join(r6.(inside), ","),
                  MIX_SHAPE, m.hw_p50, m.hw_p99, m.inflight_mean, m.inflight_peak, m.sw_p50, m.sw_p99), '\t'))
    flush(stdout)
    if VALIDATE
        validate_cell(recs, "spawn", :interactive, MIX_C, MIX_H, MIX_SHAPE == "plain" ? "mixed" : MIX_SHAPE)
        multiq_fifo_check("mixed C=$(MIX_C) H=$(MIX_H) $(MIX_SHAPE)", fifo0;
                          f_first = expected_f_first(:interactive, MIX_C, sum(r -> length(r.lat), recs)),
                          desc = expected_desc(MIX_SHAPE, sum(r -> length(r.lat), recs)))
        # Under M-t (and M-h-t) the two sides' time must come out 40-60% on every :default thread;
        # under -g the request side's weight, +-10 points (not under g0, whose balance never moves).
        multiq_share_check("mixed C=$(MIX_C) H=$(MIX_H) $(MIX_SHAPE)", share0, sfifo0;
                           half = FIFO_SERVE in (:t, :g) && BG_LOOPS == 0)
        validate_threads()
        println(stderr, "validate: mixed: ", length(walls), BG_LOOPS == 0 ? " fib_fine" : " loop", " runs during the cell (",
                length(inside), " ended before the last client), every result checked")
    end
    multiq_variant_check()
end

mixed()
