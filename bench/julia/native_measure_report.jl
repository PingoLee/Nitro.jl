# #618, the native mark, session 2: the report of bench/julia/native_measure.sh's run, as markdown.
# Columns: ctl (the control build, A), bridgeA (the official binary, A), mark (the mark build, N; and
# mark25/mark75, N25/N75), bridge (the official binary under the runtime patch, M-gc-r2), mark0 (the
# mark build, N-none). A value is a median over rounds with [min–max]; a ratio is the median of the
# per-round ratios with [min–max]; the native columns are read against ctl, the bridge against
# bridgeA. Rounds alternate the column order (odd: ctl bridgeA mark bridge mark0; even: reversed), so
# a column's position follows from the round's parity.
#
# Usage: julia bench/julia/native_measure_report.jl <OUT> [<server log dir>]
#   OUT: rounds_fifo's results directory (bench/results/618-native-measure)
#   server log dir: mark_server.sh's logs (bench/results/618-mark), whose "results:" lines name the
#   fairness TSVs of the native blocks
using Statistics

const OUT = ARGS[1]
const MLOG = length(ARGS) >= 2 ? ARGS[2] : joinpath(dirname(OUT), "618-mark")
const ORDER = ["ctl", "bridgeA", "mark", "bridge", "mark0"]

function readtsv(path)
    isfile(path) || return Dict{String,String}[]
    lines = filter(!isempty, readlines(path))
    isempty(lines) && return Dict{String,String}[]
    hdr = split(lines[1], '\t')
    rows = Dict{String,String}[]
    for l in lines[2:end]
        f = split(l, '\t')
        f[1] == hdr[1] && continue   # a repeated header
        push!(rows, Dict(String(hdr[i]) => String(get(f, i, "")) for i in eachindex(hdr)))
    end
    rows
end
rounds_of(prefix) = sort([parse(Int, m[1]) for f in readdir(OUT) for m in (match(Regex("^$(prefix)-r([0-9]+)\\.tsv\$"), f),) if m !== nothing])
allrows(prefix) = reduce(vcat, [readtsv(joinpath(OUT, "$(prefix)-r$(r).tsv")) for r in rounds_of(prefix)]; init = Dict{String,String}[])

function col_of(commit, variant)
    if endswith(commit, "/native")
        variant == "N" ? "mark" : variant == "N-none" ? "mark0" : variant == "N25" ? "mark25" : variant == "N75" ? "mark75" : "?$variant"
    elseif endswith(commit, "/local")
        variant == "A" ? "ctl" : "?$variant"
    else
        variant == "A" ? "bridgeA" : variant == "M-gc-r2" ? "bridge" : "?$variant"
    end
end
col_of(r::Dict) = col_of(r["commit"], r["variant"])
num(s) = (x = tryparse(Float64, s); x === nothing ? NaN : x)

fmt(x) = isnan(x) ? "–" : abs(x) >= 1e5 ? string(round(Int, x)) : abs(x) >= 100 ? string(round(x; digits = 1)) :
         abs(x) >= 1 ? string(round(x; digits = 3)) : string(round(x; sigdigits = 4))
med(v) = isempty(v) ? NaN : median(v)
mmr(v) = isempty(v) ? "–" : "$(fmt(median(v))) [$(fmt(minimum(v)))–$(fmt(maximum(v)))]"
overlap(a, b) = !isempty(a) && !isempty(b) && maximum(a) >= minimum(b) && maximum(b) >= minimum(a)
position(col, r, cols = ORDER) = (i = findfirst(==(col), cols); i === nothing ? 0 : isodd(r) ? i : length(cols) + 1 - i)

# value[col][round] for the rows that pass `sel`, metric `f`.
function byround(rows, sel, f)
    d = Dict{String,Dict{Int,Float64}}()
    for r in rows
        sel(r) || continue
        get!(d, col_of(r), Dict{Int,Float64}())[parse(Int, r["round"])] = f(r)
    end
    d
end
vals(d, c) = haskey(d, c) ? [v for (_, v) in sort(collect(d[c]))] : Float64[]
function ratios(d, a, b)
    (haskey(d, a) && haskey(d, b)) || return Tuple{Int,Float64}[]
    [(r, d[a][r] / d[b][r]) for r in sort(collect(keys(d[a]))) if haskey(d[b], r)]
end
rv(x) = last.(x)

"A table: one line per cell, the columns' medians, then the ratios."
function celltable(io, title, cells, rows, sel_of, f; cols = ORDER, metric = "", lower_better = false)
    println(io, "\n### $title\n")
    metric == "" || println(io, "*$metric*\n")
    println(io, "| cell | ", join(cols, " | "), " | mark0/ctl | mark/ctl | bridge/bridgeA | ctl/bridgeA | mark0 in ctl's range |")
    println(io, "|---|", repeat("--:|", length(cols) + 5))
    for (label, sel) in cells
        d = byround(rows, sel, f)
        println(io, "| $label | ", join([mmr(vals(d, c)) for c in cols], " | "), " | ",
                mmr(rv(ratios(d, "mark0", "ctl"))), " | ", mmr(rv(ratios(d, "mark", "ctl"))), " | ",
                mmr(rv(ratios(d, "bridge", "bridgeA"))), " | ", mmr(rv(ratios(d, "ctl", "bridgeA"))), " | ",
                overlap(vals(d, "mark0"), vals(d, "ctl")) ? "yes" : "**no**", " |")
    end
end

"Per-round mark0/ctl ratios with mark0's position (and ctl's)."
function perround(io, title, cells, rows, sel_of, f; a = "mark0", b = "ctl", cols = ORDER)
    println(io, "\n#### $title: $a/$b per round (positions $a, $b)\n")
    for (label, sel) in cells
        d = byround(rows, sel, f)
        rs = ratios(d, a, b)
        println(io, "- $label: ", join(["r$r $(fmt(x)) ($(position(a, r, cols)),$(position(b, r, cols)))" for (r, x) in rs], " · "))
    end
end

io = stdout
println(io, "# #618 native mark, session 2: report of $(OUT)\n")
println(io, "Columns: ", join(ORDER, ", "), ". Values: median [min–max] over rounds; ratios: median [min–max] of per-round ratios.")

# --- Cost: H = 0 spawn cells
cost = allrows("cost-spawn")
costcells = [("$(cl) $(th) C=$(c)", r -> r["clients"] == cl && r["threads"] == th && r["c"] == c && r["mode"] == "spawn")
             for (th, cl) in (("8,1", "interactive"), ("8,1", "default"), ("8,0", "default")) for c in ("50", "500")]
celltable(io, "Cost: H = 0, throughput (req/s)", costcells, cost, nothing, r -> num(r["rps"]))
perround(io, "Cost H = 0", costcells, cost, nothing, r -> num(r["rps"]))
perround(io, "Cost H = 0", costcells, cost, nothing, r -> num(r["rps"]); a = "mark", b = "ctl")
perround(io, "Cost H = 0", costcells, cost, nothing, r -> num(r["rps"]); a = "bridge", b = "bridgeA")

# --- tasks.jl micro and queued (headerless rows: round, version, layout, token, kind, tool, name, ns_per_op=…)
micro = Dict{String,String}[]
for r in rounds_of("micro"), l in eachline(joinpath(OUT, "micro-r$(r).tsv"))
    f = split(l, '\t'); length(f) >= 8 || continue
    tok = String(f[4]); v, b = occursin('%', tok) ? split(tok, '%') : (tok, "")
    commit = b == "control" ? "x/local" : b == "mark" ? "x/native" : "x"
    ns = match(r"ns_per_op=([0-9.eE+-]+)", l)
    push!(micro, Dict("round" => String(f[1]), "threads" => String(f[3]), "variant" => String(v), "commit" => commit,
                      "kind" => String(f[5]), "name" => String(f[7]), "ns" => ns === nothing ? "NaN" : ns[1]))
end
mnames = unique([(r["threads"], r["kind"], r["name"]) for r in micro])
mcells = [("$(th) $(k) $(n)", r -> r["threads"] == th && r["kind"] == k && r["name"] == n) for (th, k, n) in mnames]
celltable(io, "tasks.jl micro and queued (ns per op, lower is faster)", mcells, micro, nothing, r -> num(r["ns"]))
perround(io, "tasks.jl", mcells, micro, nothing, r -> num(r["ns"]))

# --- Fairness: the three starved cells
fair = allrows("fairness-spawn")
fcells = [("$(cl) $(th)", r -> r["clients"] == cl && r["threads"] == th && r["mode"] == "spawn")
          for (th, cl) in (("8,1", "interactive"), ("8,1", "default"), ("8,0", "default"))]
celltable(io, "Starved cells (C = 500, H = 2 ms): p99 ms", fcells, fair, nothing, r -> num(r["p99_ms"]))
celltable(io, "Starved cells: throughput (req/s)", fcells, fair, nothing, r -> num(r["rps"]))
celltable(io, "Starved cells: slowest client's requests", fcells, fair, nothing, r -> num(r["count_min"]))
pool = [r for r in fair if r["mode"] == "pool"]
println(io, "\nPool reference (A on the control build): ",
        join(["$(cl) $(th) p99 $(mmr([num(r["p99_ms"]) for r in pool if r["clients"] == cl && r["threads"] == th]))"
              for (th, cl) in (("8,1", "interactive"), ("8,1", "default"), ("8,0", "default"))], "; "))

# --- Inner shape
shapes = allrows("shapes-spawn")
icells = [("500:2:inner 8,1 interactive", r -> r["shape"] == "inner")]
celltable(io, "Inner shape: p99 ms", icells, shapes, nothing, r -> num(r["p99_ms"]))
celltable(io, "Inner shape: throughput", icells, shapes, nothing, r -> num(r["rps"]))

# --- Mixed and mixed-inner
const MIXCOLS = ["ctl", "bridgeA", "mark", "mark25", "mark75", "bridge", "mark0"]
for (name, prefix) in (("Mixed", "mixed"), ("Mixed-inner", "mixedinner"))
    rows = allrows(prefix)
    cells = [("8,1", r -> true)]
    celltable(io, "$name: p99 ms", cells, rows, nothing, r -> num(r["p99_ms"]); cols = MIXCOLS)
    celltable(io, "$name: slowest client's requests", cells, rows, nothing, r -> num(r["count_min"]); cols = MIXCOLS)
    celltable(io, "$name: fib_fine slowdown (fib_median_s / fib_alone_median_s)", cells, rows, nothing,
              r -> num(r["fib_median_s"]) / num(r["fib_alone_median_s"]); cols = MIXCOLS)
    celltable(io, "$name: fib_fine runs in the window", cells, rows, nothing, r -> num(r["fib_runs"]); cols = MIXCOLS)
end

# --- fib_fine alone and under a marked root
nest = allrows("nested")
ncells = [("fib_fine alone $th", r -> r["threads"] == th && r["bench"] == "fib_fine") for th in ("8,1", "8,0")]
celltable(io, "fib_fine alone: wall median s (lower is faster)", ncells, nest, nothing, r -> num(r["wall_median_s"]))
perround(io, "fib_fine alone (cells block)", ncells, nest, nothing, r -> num(r["wall_median_s"]))
perround(io, "fib_fine alone (cells block)", ncells, nest, nothing, r -> num(r["wall_median_s"]); a = "mark", b = "ctl")
mroot = allrows("markroot")
rcells = [("fib_fine under a marked root $th", r -> r["threads"] == th) for th in ("8,1", "8,0")]
celltable(io, "fib_fine under a marked root: wall median s", rcells, mroot, nothing, r -> num(r["wall_median_s"]))

# --- fib_fine ABBA
abba = readtsv(joinpath(OUT, "fibabba-nested.tsv"))
if !isempty(abba)
    println(io, "\n### fib_fine alone, ABBA (ctl and mark0, $(length(unique([r["round"] for r in abba]))) rounds)\n")
    acols = ["ctl", "mark0"]
    for th in ("8,1", "8,0")
        d = byround(abba, r -> r["threads"] == th, r -> num(r["wall_median_s"]))
        rs = ratios(d, "mark0", "ctl")
        println(io, "- **$th**: ctl $(mmr(vals(d, "ctl"))) · mark0 $(mmr(vals(d, "mark0"))) · mark0/ctl $(mmr(rv(rs))) · ranges overlap: ",
                overlap(vals(d, "mark0"), vals(d, "ctl")) ? "yes" : "**no**")
        println(io, "  - per round (mark0/ctl, mark0's position): ",
                join(["r$r $(fmt(x)) ($(position("mark0", r, acols)))" for (r, x) in rs], " · "))
        println(io, "  - mark0 first: $(mmr([x for (r, x) in rs if position("mark0", r, acols) == 1])); mark0 second: $(mmr([x for (r, x) in rs if position("mark0", r, acols) == 2]))")
    end
end

# --- Servers
println(io, "\n## Servers\n")
srvlabel(m) = endswith(m, "%control") ? "ctl" : endswith(m, "@N%mark") ? "mark" : endswith(m, "%mark") ? "mark0" :
              occursin("M-gc-r2", m) ? "bridge" : endswith(m, "%official") ? "bridgeA" : m
for blk in ("nplain-8_0", "nplain-8_1", "ncell1-8_0", "ncell4-8_0", "ncell1-8_1", "ncell4-8_1")
    lf = joinpath(MLOG, "$blk.log")
    isfile(lf) || (println(io, "- $blk: no log"); continue)
    m = match(r"results: (\S+\.tsv)", read(lf, String))
    m === nothing && (println(io, "- $blk: no results line"); continue)
    rows = [r for r in readtsv(m[1]) if r["round"] != "0"]
    for r in rows; r["commit"] = ""; r["col"] = srvlabel(r["mode"]); end
    cols(metric) = (d = Dict{String,Dict{Int,Float64}}();
                    for r in rows; get!(d, r["col"], Dict{Int,Float64}())[parse(Int, r["round"])] = num(r[metric]); end; d)
    println(io, "\n### $blk ($(basename(m[1])))\n")
    println(io, "| metric | ", join(ORDER, " | "), " | mark0/ctl | mark/ctl | bridge/bridgeA | ctl/bridgeA | mark0 in ctl's range |")
    println(io, "|---|", repeat("--:|", length(ORDER) + 5))
    for metric in ("rps", "oha_rps", "p99_ms", "p50_ms", "max_ms", "conn_min", "conn_p50", "listen_ovf", "cli_cpu", "oha_cpu", "gc_ms")
        d = cols(metric)
        all(c -> all(isnan, vals(d, c)), ORDER) && continue
        println(io, "| $metric | ", join([mmr(vals(d, c)) for c in ORDER], " | "), " | ", mmr(rv(ratios(d, "mark0", "ctl"))), " | ",
                mmr(rv(ratios(d, "mark", "ctl"))), " | ", mmr(rv(ratios(d, "bridge", "bridgeA"))), " | ",
                mmr(rv(ratios(d, "ctl", "bridgeA"))), " | ", overlap(vals(d, "mark0"), vals(d, "ctl")) ? "yes" : "**no**", " |")
    end
    for metric in (startswith(blk, "nplain") ? ("oha_rps", "rps") : ("rps",))
        d = cols(metric)
        println(io, "\n- $metric mark0/ctl per round (positions mark0, ctl): ",
                join(["r$r $(fmt(x)) ($(position("mark0", r)),$(position("ctl", r)))" for (r, x) in ratios(d, "mark0", "ctl")], " · "))
    end
end
