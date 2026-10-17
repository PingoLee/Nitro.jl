# The tail of a `run.sh` invocation against the collections it contained (#590 H3). Reads what
# `KEEP_JSON=1 GC_SNAPSHOTS=1` leaves -- `socket-<stamp>-raw/*.json` and `socket-<stamp>-gc.tsv` --
# and the `go` mode's log, which carries one `gctrace` line per collection when that server ran
# with GODEBUG=gctrace=1. One row per mode, route and run, then the median per mode and route.
#
#   julia --project=bench bench/socket/gc_tail.jl bench/results/socket-<stamp> [route]
#
# Julia columns are `Base.gc_num()` deltas over the run: collections (`pause`), GC time, the share
# of the run's wall time that is, the bytes allocated, the longest pause and the longest wait for
# every thread to reach a safepoint (both cumulative maxima, so shown only when the run raised
# them), and the summed time to safepoint. Go columns are the `gctrace` lines that appeared during
# the run: collections, the summed and longest stop-the-world time (sweep termination plus mark
# termination; the concurrent mark between them is not a pause).

using JSON

stem = ARGS[1]
only_route = length(ARGS) >= 2 ? ARGS[2] : nothing
raw = stem * "-raw"
slug(s) = replace(s, r"[^A-Za-z0-9._-]" => "_")

struct Snap
    before::String
    after::String
end
snaps = Dict{Tuple{String, String, Int}, Snap}()
let pending = Dict{Tuple{String, String, Int}, String}()
    for line in Iterators.drop(eachline(stem * "-gc.tsv"), 1)
        mode, route, run, phase, snap = split(line, '\t'; limit = 5)
        key = (String(mode), String(route), parse(Int, run))
        phase == "before" ? (pending[key] = snap) : (snaps[key] = Snap(pending[key], snap))
    end
end

ms(ns) = round(ns / 1e6; digits = 2)

function julia_cols(s::Snap, wall_s::Float64)
    a, b = JSON.parse(s.before), JSON.parse(s.after)
    d(f) = b[f] - a[f]
    total(x) = x["total_allocd"] + x["deferred_alloc"] + x["allocd"]
    raised(f) = b[f] > a[f] ? string(ms(b[f])) : "-"
    return (gcs = d("pause"), gc_ms = ms(d("total_time")),
            gc_share = round(100 * d("total_time") / (wall_s * 1e9); digits = 2),
            alloc_mib = round((total(b) - total(a)) / 2^20; digits = 1),
            max_pause_ms = raised("max_pause"), max_tts_ms = raised("max_time_to_safepoint"),
            tts_ms = ms(d("total_time_to_safepoint")))
end

# `gc 12 @3.456s 1%: 0.020+1.2+0.003 ms clock, ...`: the clock triple's first and last terms are
# the two stop-the-world phases.
function go_cols(s::Snap, log_lines::Vector{String})
    lo = parse(Int, split(s.before, '=')[2]); hi = parse(Int, split(s.after, '=')[2])
    stw = Float64[]
    for line in log_lines[lo+1:min(hi, length(log_lines))]
        m = match(r"^gc \d+ @[\d.]+s \d+%: ([\d.]+)\+([\d.]+)\+([\d.]+) ms clock", line)
        m === nothing && continue
        push!(stw, parse(Float64, m[1]) + parse(Float64, m[3]))
    end
    return (gcs = length(stw), stw_ms = round(sum(stw; init = 0.0); digits = 2),
            max_stw_ms = isempty(stw) ? 0.0 : round(maximum(stw); digits = 3))
end

median(v) = (s = sort(v); n = length(s); isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)

rows = Dict{Tuple{String, String}, Vector{Any}}()
for ((mode, route, run), s) in sort!(collect(snaps); by = first)
    only_route === nothing || route == only_route || continue
    js = JSON.parse(read(joinpath(raw, "r$run-$(slug(mode))-$(slug(route)).json"), String))
    wall = Float64(js["summary"]["total"])
    lat = js["latencyPercentiles"]
    base = (rps = round(Int, js["summary"]["requestsPerSec"]), p50_ms = ms(lat["p50"] * 1e9),
            p99_ms = ms(lat["p99"] * 1e9), p999_ms = ms(lat["p99.9"] * 1e9))
    extra = if startswith(mode, "go")
        go_cols(s, readlines("$stem-$mode.log"))
    else
        julia_cols(s, wall)
    end
    row = merge(base, extra)
    println(rpad(mode, 12), rpad(route, 32), "run ", run, "  ",
            join(("$k=$v" for (k, v) in pairs(row)), "  "))
    push!(get!(rows, (mode, route), Any[]), row)
end
println("\nmedian of runs")
for ((mode, route), rs) in sort!(collect(rows); by = first)
    cols = [k => median([r[k] for r in rs]) for k in keys(rs[1]) if rs[1][k] isa Number]
    println(rpad(mode, 12), rpad(route, 32), join(("$k=$v" for (k, v) in cols), "  "))
end
