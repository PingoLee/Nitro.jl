# #618, the two loose ends of 2026-11-18 (agent-config #82 Idea 9): read a fairness.sh TSV.
#
#   julia bench/socket/burst_report.jl ratios <fairness-*.tsv>   per server, the median of its
#       per-round ratios to the first mode (A) for the client's rps and oha's, the per-round ratios,
#       oha's req/s median [min-max], and the client's and oha's CPU share (CLIENT_CPU=1).
#   julia bench/socket/burst_report.jl burst <fairness-*.tsv>    per server, in how many rounds
#       ListenOverflows was above zero, the counts, p99 in the rounds with and without one, and
#       est0 (established connections before each window: 0 is a fresh burst).
#
# Standard library only; run with a bare `julia`.
using Statistics: median

function rows(path)
    lines = readlines(path)
    head = split(lines[1], '\t')
    [Dict(zip(head, split(l, '\t'))) for l in lines[2:end] if !isempty(l)]
end
num(s) = s == "-" ? NaN : parse(Float64, s)
modes(rs) = unique(r["mode"] for r in rs)
fmt(x; d = 3) = isnan(x) ? "-" : string(round(x; digits = d))
mmr(v) = isempty(v) ? "-" : "$(round(Int, median(v))) [$(round(Int, minimum(v)))–$(round(Int, maximum(v)))]"

function ratios(path)
    rs = rows(path); ms = modes(rs); a = ms[1]
    byround(m, col) = Dict(r["round"] => num(r[col]) for r in rs if r["mode"] == m)
    println("| server | client rps | client ratio to A (median; per round) | oha rps | oha ratio to A (median; per round) | client CPU | oha CPU |")
    println("|---|--:|---|--:|---|--:|--:|")
    for m in ms
        line = ["`$m`"]
        for col in ("rps", "oha_rps")
            mine, base = byround(m, col), byround(a, col)
            rds = sort(collect(keys(mine)); by = x -> parse(Int, x))
            per = [mine[k] / base[k] for k in rds]
            push!(line, mmr(filter(!isnan, [mine[k] for k in rds])))
            push!(line, isempty(per) || any(isnan, per) ? "-" :
                  "**$(fmt(median(per)))**; " * join(fmt.(per), " · "))
        end
        for col in ("cli_cpu", "oha_cpu")
            v = filter(!isnan, [num(get(r, col, "-")) for r in rs if r["mode"] == m])
            push!(line, isempty(v) ? "-" : "$(fmt(median(v))) [$(fmt(minimum(v)))–$(fmt(maximum(v)))]")
        end
        println("| ", join(line, " | "), " |")
    end
end

function burst(path)
    rs = rows(path)
    println("| server | rounds with overflow | overflow counts (per round) | p99 ms, rounds with one (median [min-max]) | p99 ms, rounds without | max ms (median) | est0 max |")
    println("|---|--:|---|---|---|--:|--:|")
    for m in modes(rs)
        mine = sort([r for r in rs if r["mode"] == m]; by = r -> parse(Int, r["round"]))
        ovf = [parse(Int, r["listen_ovf"]) for r in mine]
        p99 = [num(r["p99_ms"]) for r in mine]
        mx = [num(r["max_ms"]) for r in mine]
        est = [parse(Int, get(r, "est0", "0")) for r in mine]
        with = p99[ovf .> 0]; without = p99[ovf .== 0]
        f(v) = isempty(v) ? "-" : "$(fmt(median(v); d = 1)) [$(fmt(minimum(v); d = 1))–$(fmt(maximum(v); d = 1))]"
        println("| `$m` | $(count(>(0), ovf)) / $(length(ovf)) | $(join(ovf, " · ")) | $(f(with)) | $(f(without)) | ",
                "$(fmt(median(mx); d = 1)) | $(maximum(est)) |")
    end
end

length(ARGS) == 2 || error("usage: burst_report.jl ratios|burst <fairness-*.tsv>")
ARGS[1] == "ratios" ? ratios(ARGS[2]) : ARGS[1] == "burst" ? burst(ARGS[2]) : error("ratios or burst, not $(ARGS[1])")
