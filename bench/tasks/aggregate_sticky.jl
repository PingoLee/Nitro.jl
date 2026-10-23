# The Markdown tables of rounds_sticky.sh's TSVs (#618, variants S and P): one table per cell
# (layout, clients, C, H, shape), one row per (build, mode), each value the median over rounds with
# [min–max]. Rows are ordered by build as met, then spawn, sticky, pool, priority. The handler wall
# columns are the request's own work, start to end (for `inner`, first spawn to last fetch).
#
#   julia bench/tasks/aggregate_sticky.jl <tsv>...
#   julia bench/tasks/aggregate_sticky.jl bench/results/sticky/spawn-r*.tsv

const COLS = ["julia", "commit", "threads", "guard", "variant", "round", "mode", "clients", "c", "h_ms",
              "rps", "p50_ms", "p90_ms", "p99_ms", "max_ms", "count_min", "count_p1",
              "count_median", "count_max", "jain", "slow1_spawn_to_start_pct",
              "slow1_end_to_wake_pct", "shape", "hw_p50_ms", "hw_p99_ms", "hw_max_ms"]
const MODE_ORDER = ["spawn", "sticky", "pool", "priority"]

med(v) = (s = sort(v); n = length(s); isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)
fmt(x) = isnan(x) ? "–" : abs(x) >= 1e6 ? string(round(x / 1e6; digits = 2), "M") :
         abs(x) >= 1000 ? replace(string(round(Int, x)), r"(?<=\d)(?=(\d{3})+$)" => ",") :
         abs(x) >= 100 || x == round(x) ? string(round(Int, x)) : string(round(x; sigdigits = 3))
cell(v) = isempty(v) ? "–" : length(v) == 1 ? fmt(v[1]) :
          string(fmt(med(v)), " [", fmt(minimum(v)), "–", fmt(maximum(v)), "]")

function readtsv(paths)
    rows = Vector{Dict{String,String}}()
    for p in paths, l in eachline(p)
        isempty(l) && continue
        f = split(l, '\t')
        f[1] == COLS[1] && continue
        length(f) == length(COLS) || error("$p: $(length(f)) fields, $(length(COLS)) expected: $l")
        push!(rows, Dict(zip(COLS, f)))
    end
    return rows
end
num(r, k) = parse(Float64, r[k])

function main(paths)
    rows = readtsv(paths)
    isempty(rows) && error("no rows")
    builds = unique(r["julia"] for r in rows)
    modes = filter(m -> any(r -> r["mode"] == m, rows), MODE_ORDER)
    append!(modes, filter(!in(modes), unique(r["mode"] for r in rows)))
    nrounds = length(unique(r["round"] for r in rows))
    ckey(r) = (r["threads"], r["clients"], r["c"], r["h_ms"], r["shape"])
    cells = unique(ckey(r) for r in rows)
    # Fairness cells (H > 0) first, then cost cells, each by layout then clients.
    sort!(cells; by = k -> (num(Dict("h_ms" => k[4]), "h_ms") == 0, k[1], k[2], k[5], parse(Int, k[3])))
    println("Medians over ", nrounds, " round", nrounds == 1 ? "" : "s", " [min–max]; builds ",
            join(builds, ", "), "; modes ", join(modes, ", "), ".")
    for k in cells
        threads, clients, c, h, shape = k
        println("\n**--threads=", threads, ", clients on :", clients, ", C = ", c, ", H = ", h, " ms, ", shape, "**\n")
        println("| build | mode | req/s | p50 ms | p99 ms | max ms | slowest client | Jain | handler wall p50 ms | p99 ms | max ms |")
        println("|---|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|")
        for b in builds, m in modes
            rs = filter(r -> ckey(r) == k && r["julia"] == b && r["mode"] == m, rows)
            isempty(rs) && continue
            v(name) = [num(r, name) for r in rs]
            println("| ", b, " | ", m, " | ", cell(v("rps")), " | ", cell(v("p50_ms")), " | ", cell(v("p99_ms")),
                    " | ", cell(v("max_ms")), " | ", cell(v("count_min")), " | ", cell(v("jain")), " | ",
                    cell(v("hw_p50_ms")), " | ", cell(v("hw_p99_ms")), " | ", cell(v("hw_max_ms")), " |")
        end
    end
end

main(ARGS)
