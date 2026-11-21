# The report of bench/julia/bypass.sh's question 3 (#618, agent-config #82 Idea 13): throughput of
# JuliaLang/julia#62285's head on its two backends (ws: work-stealing, base: partr) against the mark,
# in the same blocks. ws and base are another Julia version than ctl and m2, so the report gives only
# ws/base and m2/ctl (and m2 with nothing marked against ctl), never one tree against the other.
#   julia bench/julia/q3_report.jl <OUT> [<fairness tsv>...]
# <OUT>/q3spawn/costrounds-spawn.tsv: spawn_order.jl at H = 0. Each fairness TSV: /plaintext under oha,
# its oha_rps and, from each slot's `<stem>-oha.json`, oha's p99. Medians [min-max] over rounds; a ratio
# is the median of the per-round ratios. Stdlib only, plus a small JSON field reader.

const OUT = isempty(ARGS) ? error("usage: julia q3_report.jl <OUT> [fairness.tsv ...]") : ARGS[1]
med(v) = (s = sort(v); n = length(s); n == 0 ? NaN : isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)
f3(x) = isnan(x) ? "-" : string(round(x; digits = 3))
fmt(v; d = 3) = isempty(v) ? "-" : string(round(med(v); digits = d), " [", round(minimum(v); digits = d), "-", round(maximum(v); digits = d), "]")

function read_tsv(path)
    lines = readlines(path)
    hdr = split(lines[1], '\t')
    return [Dict(zip(hdr, split(l, '\t'))) for l in lines[2:end] if !isempty(l) && split(l, '\t')[1] != hdr[1]]
end

function column(commit, variant)
    occursin("/workstealing", commit) && return "ws"
    occursin("84961e79ff/partr", commit) && return "base"
    startswith(commit, "c1ac32ab73") && return "ctl"
    startswith(commit, "b4f05f4d47") && return variant == "N-none" ? "m2-none" : "m2"
    return "?" * commit
end
ratios(rd, a, b, rs) = [rd[r][a] / rd[r][b] for r in rs if haskey(rd[r], a) && haskey(rd[r], b)]

f = joinpath(OUT, "q3spawn", "costrounds-spawn.tsv")
if isfile(f)
    cells = Dict{String,Dict{Int,Dict{String,Float64}}}()
    for row in read_tsv(f)
        cell = "H = 0 C = $(row["c"]), $(row["clients"]) clients, $(row["threads"])"
        rd = get!(() -> Dict{Int,Dict{String,Float64}}(), cells, cell)
        get!(() -> Dict{String,Float64}(), rd, parse(Int, row["round"]))[column(row["commit"], row["variant"])] = parse(Float64, row["rps"])
    end
    println("# spawn_order.jl, req/s (higher is faster)\n")
    for cell in sort(collect(keys(cells)))
        rd = cells[cell]; rs = sort(collect(keys(rd)))
        println("## ", cell, " (", length(rs), " rounds)")
        for c in ("ws", "base", "ctl", "m2", "m2-none")
            println("  ", rpad(c, 8), fmt([rd[r][c] for r in rs if haskey(rd[r], c)]; d = 0))
        end
        for (a, b) in (("ws", "base"), ("m2", "ctl"), ("m2-none", "ctl"))
            v = ratios(rd, a, b, rs)
            println("  ", rpad("$a/$b", 12), fmt(v), "   above 1 in ", count(>(1), v), " of ", length(v))
        end
        println()
    end
end

# A number field of oha's JSON report, by key path, without a JSON package.
function json_num(s, keys...)
    i = 1
    for k in keys
        m = findnext("\"$k\"", s, i); m === nothing && return NaN; i = last(m) + 1
    end
    m = match(r"^\s*:\s*(-?[0-9.eE+-]+)", s[i:end]); m === nothing && return NaN
    return parse(Float64, m.captures[1])
end
function server_col(mode)
    endswith(mode, "%ws") && return "ws"
    endswith(mode, "%base") && return "base"
    endswith(mode, "%control") && return "ctl"
    endswith(mode, "%mark") && return "m2"
    return mode
end
for tsv in ARGS[2:end]
    raw = replace(tsv, r"\.tsv$" => "-raw")
    rows = read_tsv(tsv)
    rd = Dict{Int,Dict{String,Tuple{Float64,Float64}}}()   # round => col => (oha rps, oha p99 ms)
    layout = ""
    for row in rows
        r = parse(Int, row["round"]); r == 0 && continue
        m = match(r"@([0-9]+,[0-9]+)", row["mode"]); m === nothing || (layout = m.captures[1])
        col = server_col(row["mode"])
        # fairness.sh's stem: r<round>-<mode with @ , % as - _ ->-oha.json
        fn = joinpath(raw, string("r", r, "-", replace(row["mode"], '@' => '-', ',' => '_', '%' => '-'), "-oha.json"))
        p99 = isfile(fn) ? 1000 * json_num(read(fn, String), "latencyPercentiles", "p99") : NaN
        get!(() -> Dict{String,Tuple{Float64,Float64}}(), rd, r)[col] = (parse(Float64, row["oha_rps"]), p99)
    end
    rs = sort(collect(keys(rd)))
    println("# /plaintext under oha, c = 500, fresh servers, ", layout, " (", basename(tsv), ", ", length(rs), " rounds)\n")
    for c in ("ws", "base", "ctl", "m2")
        rps = [rd[r][c][1] for r in rs if haskey(rd[r], c)]; p = filter(!isnan, [rd[r][c][2] for r in rs if haskey(rd[r], c)])
        println("  ", rpad(c, 5), "oha req/s ", fmt(rps; d = 0), "   oha p99 ms ", fmt(p; d = 2))
    end
    for (a, b) in (("ws", "base"), ("m2", "ctl"))
        v = [rd[r][a][1] / rd[r][b][1] for r in rs if haskey(rd[r], a) && haskey(rd[r], b)]
        p = filter(!isnan, [rd[r][a][2] / rd[r][b][2] for r in rs if haskey(rd[r], a) && haskey(rd[r], b)])
        println("  ", rpad("$a/$b", 8), "req/s ", fmt(v), " (above 1 in ", count(>(1), v), " of ", length(v), ")   p99 ", fmt(p))
    end
    println()
end
