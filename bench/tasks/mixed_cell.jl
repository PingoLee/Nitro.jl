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

mix_sfib(n::Int) = n <= 1 ? n : mix_sfib(n - 1) + mix_sfib(n - 2)
function mix_pfib(n::Int, cut::Int)
    n <= max(cut, 1) && return mix_sfib(n)
    t = Threads.@spawn mix_pfib(n - 2, cut)
    return mix_pfib(n - 1, cut) + fetch(t)::Int
end
const FIB_REF = mix_sfib(FIB_N)

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
                     "fib_runs", "fib_median_s", "fib_min_s", "fib_max_s", "fib_walls_s"]

med(v) = (s = sort(v); n = length(s); n == 0 ? NaN : isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)

function mixed()
    Threads.nthreads(:interactive) > 0 || error("mixed_cell: needs an :interactive thread (--threads=8,1)")
    println(stderr, "mixed_cell: julia ", VERSION, " (", Base.GIT_VERSION_INFO.commit_short, "), threads ",
            Threads.nthreads(:default), ",", Threads.nthreads(:interactive), ", variant ", MULTIQ_VARIANT,
            ", C = ", MIX_C, ", H = ", MIX_H, " ms, D = ", MIX_D, " s, fib_fine ", FIB_N, ":", FIB_CUT,
            " looping on :default")
    VALIDATE && multiq_unit_asserts()
    # Compile both halves before timing; not reported.
    run_cell("spawn", :interactive, 8, 0.1, 0.2)
    fetch(Threads.@spawn :default mix_pfib(min(FIB_N, FIB_CUT + 8), FIB_CUT))
    GC.gc()
    alone = [fib_once()[1] for _ in 1:ALONE_RUNS]
    walls, ends = Float64[], UInt64[]
    bg = Ref{Task}()
    loop = deadline -> (bg[] = Threads.@spawn :default begin
        while time_ns() < deadline
            w, e = fib_once()
            push!(walls, w)
            push!(ends, e)
        end
    end)
    if VALIDATE
        HANDLED[] = 0; TID_MOVED[] = 0
    end
    fifo0 = multiq_fifo_counts()
    multiq_watchdog(ceil(Int, MIX_D) + 120)
    recs, wall = run_cell("spawn", :interactive, MIX_C, MIX_H, MIX_D; onstart = loop)
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
                  isempty(inside) ? NaN : r6(maximum(inside)), join(r6.(inside), ",")), '\t'))
    flush(stdout)
    if VALIDATE
        validate_cell(recs, "spawn", :interactive, MIX_C, MIX_H, "mixed")
        multiq_fifo_check("mixed C=$(MIX_C) H=$(MIX_H)", fifo0;
                          f_first = expected_f_first(:interactive, MIX_C, sum(r -> length(r.lat), recs)))
        validate_threads()
        println(stderr, "validate: mixed: ", length(walls), " fib_fine runs during the cell (",
                length(inside), " ended before the last client), every result fib($FIB_N)")
    end
    multiq_variant_check()
end

mixed()
