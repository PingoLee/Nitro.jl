# The `/aggregate` kernel alone, no HTTP (#590 H1): the three ops at N = 10^3, 10^5 and 10^7 over
# the rows `socket/aggregate.jl` generates, the same file the socket route runs. Run at one thread;
# divide the minimum by N for ns per row, the unit `socket/go`'s `BenchmarkAggregate` reports.
#
#   NITRO_BENCH_GROUPS=aggregate julia --project=bench --threads=1 bench/runbenchmarks.jl
#
# The groupby rows time the kernel and leave the JSON out, as the Go benchmark does.

include(joinpath(BENCH_DIR, "socket", "aggregate.jl"))

SUITE["aggregate"] = BenchmarkGroup()

const AGG_BENCH_ROWS = agg_rows(10_000_000)

# Both languages must aggregate the same numbers: Go's `TestAggregateChecksum` logs the same line.
let g = agg_groupby(AGG_BENCH_ROWS, 1_000)
    @info "aggregate checksum" sum_1e7 = agg_sum(AGG_BENCH_ROWS, 10_000_000) mean_1e3 = agg_mean(AGG_BENCH_ROWS, 1_000) groupby_1e3_key7 = g[7] keys = length(g)
end

# `*_yield2ms_*` is the same loop with a `yield()` every 2 ms (§5's fallback): what that costs the
# kernel itself. With no other task to switch to, a `yield()` here is its own overhead and nothing
# else; at N = 10^3 and 10^5 the 2 ms never elapses and only the per-chunk clock read is left.
agg_sum_yielding(AGG_BENCH_ROWS, 1_000, 2.0) == agg_sum(AGG_BENCH_ROWS, 1_000) &&
    agg_groupby_yielding(AGG_BENCH_ROWS, 100_000, 2.0) == agg_groupby(AGG_BENCH_ROWS, 100_000) ||
    error("aggregate: the yielding loops do not compute what the plain ones do")

for n in (1_000, 100_000, 10_000_000)
    SUITE["aggregate"]["sum_n$n"]     = @benchmarkable agg_sum(AGG_BENCH_ROWS, $n)
    SUITE["aggregate"]["mean_n$n"]    = @benchmarkable agg_mean(AGG_BENCH_ROWS, $n)
    SUITE["aggregate"]["groupby_n$n"] = @benchmarkable agg_groupby(AGG_BENCH_ROWS, $n)
    SUITE["aggregate"]["sum_yield2ms_n$n"]     = @benchmarkable agg_sum_yielding(AGG_BENCH_ROWS, $n, 2.0)
    SUITE["aggregate"]["groupby_yield2ms_n$n"] = @benchmarkable agg_groupby_yielding(AGG_BENCH_ROWS, $n, 2.0)
end
