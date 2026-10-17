# The tables of a `stall.sh` invocation run with `KEEP_JSON=1` (and, for the GC columns,
# `GC_SNAPSHOTS=1`): one Markdown table per mode, one row per pass, each a median over the rounds
# with its min and max (#588). Reads `stall-<stamp>-raw/` (the oha reports and `index.tsv`) and
# `stall-<stamp>-gc.tsv`.
#
#   julia --project=bench bench/socket/stall_report.jl bench/results/stall-<stamp>
#
# `/plaintext` columns are the measured window's; `load` is the K-in-flight route's own oha report
# (requests per second and the share answered 2xx). GC columns are `Base.gc_num()` deltas over the
# `/plaintext` window: collections, GC time and its share of the window, bytes allocated, and the
# summed time to safepoint. `max pause` is shown only when a round raised the process's cumulative
# maximum, as the largest value it was raised to.

using JSON

stem = ARGS[1]
raw = stem * "-raw"

struct Pass
    mode::String
    variant::String
    k::Int
end

const ROUNDS = Dict{Pass, Vector{Tuple{Int, String}}}()   # pass => [(round, file stem)]
order = Pass[]
for line in eachline(joinpath(raw, "index.tsv"))
    round, mode, variant, k, file = split(line, '\t')
    p = Pass(mode, variant, parse(Int, k))
    haskey(ROUNDS, p) || push!(order, p)
    push!(get!(ROUNDS, p, Tuple{Int, String}[]), (parse(Int, round), String(file)))
end

const GC = Dict{Tuple{Pass, Int}, Tuple{Dict, Dict}}()
let gc_tsv = stem * "-gc.tsv", pending = Dict{Tuple{Pass, Int}, Dict}()
    isfile(gc_tsv) && for line in Iterators.drop(eachline(gc_tsv), 1)
        mode, variant, k, round, phase, snap = split(line, '\t'; limit = 6)
        key = (Pass(mode, variant, parse(Int, k)), parse(Int, round))
        d = JSON.parse(snap; dicttype = Dict{String, Any})
        phase == "before" ? (pending[key] = d) : haskey(pending, key) && (GC[key] = (pending[key], d))
    end
end

median(v) = (s = sort(v); n = length(s); isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)
fmt(x::Integer) = string(x)
fmt(x::Real) = abs(x) >= 100 ? string(round(Int, x)) : string(round(x; sigdigits = 3))
spread(v) = isempty(v) ? "–" : length(v) == 1 ? fmt(v[1]) :
            string(fmt(median(v)), " [", fmt(minimum(v)), "–", fmt(maximum(v)), "]")

const TWO_XX = r"^2"
function load_cols(file)
    path = joinpath(raw, file * "-load.json")
    isfile(path) || return nothing
    js = JSON.parse(read(path, String))
    codes = something(get(js, "statusCodeDistribution", nothing), Dict())
    errs = something(get(js, "errorDistribution", nothing), Dict())
    ok = sum((v for (c, v) in codes if occursin(TWO_XX, c)); init = 0)
    all = sum(values(codes); init = 0) + sum((v for (e, v) in errs if e != "aborted due to deadline"); init = 0)
    return (rps = Float64(js["summary"]["requestsPerSec"]), ok = all == 0 ? 0.0 : ok / all)
end

total_alloc(g) = get(g, "total_allocd", 0) + get(g, "deferred_alloc", 0) + get(g, "allocd", 0)

for mode in unique(p.mode for p in order)
    println("\n### ", mode, "\n")
    println("| variant | K | /plaintext rps | p50 ms | p99 ms | load rps | load 2xx | GCs | GC ms | GC % of window | alloc MiB | TTS ms | max pause ms |")
    println("|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|")
    for p in order
        p.mode == mode || continue
        rps = Float64[]; p50 = Float64[]; p99 = Float64[]; lrps = Float64[]; lok = Float64[]
        gcs = Float64[]; gcms = Float64[]; share = Float64[]; alloc = Float64[]; tts = Float64[]
        raised = Float64[]
        for (round, file) in sort(ROUNDS[p])
            js = JSON.parse(read(joinpath(raw, file * "-plaintext.json"), String))
            push!(rps, js["summary"]["requestsPerSec"])
            lat = js["latencyPercentiles"]
            push!(p50, something(lat["p50"], 0.0) * 1e3); push!(p99, something(lat["p99"], 0.0) * 1e3)
            l = load_cols(file)
            l === nothing || (push!(lrps, l.rps); push!(lok, l.ok))
            g = get(GC, (p, round), nothing)
            g === nothing && continue
            a, b = g
            (isempty(a) || isempty(b)) && continue
            d(f) = get(b, f, 0) - get(a, f, 0)
            push!(gcs, d("pause")); push!(gcms, d("total_time") / 1e6)
            push!(share, 100 * d("total_time") / (js["summary"]["total"] * 1e9))
            push!(alloc, (total_alloc(b) - total_alloc(a)) / 2^20)
            push!(tts, d("total_time_to_safepoint") / 1e6)
            get(b, "max_pause", 0) > get(a, "max_pause", 0) && push!(raised, b["max_pause"] / 1e6)
        end
        println("| ", p.variant, " | ", p.k, " | ", spread(rps), " | ", spread(p50), " | ", spread(p99), " | ",
                spread(lrps), " | ", isempty(lok) ? "–" : fmt(median(lok)), " | ", spread(gcs), " | ",
                spread(gcms), " | ", spread(share), " | ", spread(alloc), " | ", spread(tts), " | ",
                isempty(raised) ? "–" : fmt(maximum(raised)), " |")
    end
end
