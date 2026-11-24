# The report of bench/julia/master_measure.sh (#618, agent-config #82 Idea 17, session 2): the native
# mark on master, with JuliaLang/julia#62285 in the same blocks. Stdlib only.
#   julia bench/julia/master_measure_report.jl <OUT> [<E2 dir>]    (OUT: the driver's results directory)
#
# Builds are named by the commit label each row carries (multiq_variant.jl's MULTIQ_BUILD, which ends
# in `*` for a tree marked dirty): ctl (master 4b0df1484a), ctl2 (the same commit again), mark
# (a570d2c9d9; split by variant: mark = nothing marked, markN = N, markArm = N-arm), inline (ca2a5c7f0b),
# bypass (ffa1184f7b*), ws and base (#62285's head 84961e79ff, work-stealing and partr); session 3
# (SESSION=3, section S3): july (6ac8c4f030, the merge-base, the master trees' Make.user) and july-n
# (6ac8c4f030*, the same commit with base's Make.user: a native sysimage).
# A ratio is "slower" as its metric says: times (fib_fine, tasks.jl ns, pfib) above 1 are slower,
# throughputs (rps) below 1 are slower. Each tree is read only against its own base.
using Dates, Printf

const OUT = isempty(ARGS) ? error("usage: julia master_measure_report.jl <OUT> [<E2 dir>]") : ARGS[1]
const E2 = length(ARGS) >= 2 ? ARGS[2] : joinpath(OUT, "e2")
io = stdout

med(v) = (s = sort(collect(v)); n = length(s); n == 0 ? NaN : isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)
f3(x) = isnan(x) ? "-" : @sprintf("%.3f", x)
fg(x) = isnan(x) ? "-" : x >= 1e6 ? @sprintf("%.3f M", x / 1e6) : x >= 1e4 ? @sprintf("%.1f k", x / 1e3) : x >= 100 ? @sprintf("%.1f", x) : @sprintf("%.4g", x)
fmt(v; f = fg) = isempty(v) ? "-" : string(f(med(v)), " [", f(minimum(v)), "–", f(maximum(v)), "]")

function readtsv(path)
    isfile(path) || return Dict{String,String}[]
    lines = readlines(path)
    isempty(lines) && return Dict{String,String}[]
    hdr = split(lines[1], '\t')
    [Dict(zip(hdr, split(l, '\t'))) for l in lines[2:end] if !isempty(l) && l != lines[1] && !startswith(l, hdr[1] * "\t" * get(hdr, 2, ""))]
end
num(s) = (x = tryparse(Float64, s); x === nothing ? NaN : x)

function col_of(commit::AbstractString, variant::AbstractString = "A")
    c = replace(commit, r"/(local|native)$" => "")
    c == "4b0df1484a" && return "ctl"
    c == "4b0df1484a*" && return "ctl2"
    c == "ca2a5c7f0b" && return "inline"
    c == "ffa1184f7b*" && return "bypass"
    c == "84961e79ff/workstealing" && return "ws"
    c == "84961e79ff/partr" && return "base"
    c == "6ac8c4f030" && return "july"
    c == "6ac8c4f030*" && return "july-n"
    if c == "a570d2c9d9"
        variant == "N-none" && return "mark"
        variant == "N-arm" && return "markArm"
        variant == "N" && return "markN"
        return "mark-$variant"
    end
    c == "9606a5f156" && return "mv-$variant"
    return "?$c"
end

# cell data: round => col => value
const Cell = Dict{Int,Dict{String,Float64}}
add!(cell::Cell, r, col, v) = (get!(() -> Dict{String,Float64}(), cell, r)[col] = v)
cols_of(cell::Cell) = sort(unique(reduce(vcat, [collect(keys(d)) for d in values(cell)]; init = String[])))
perround(cell::Cell, a, b) = [d[a] / d[b] for (r, d) in sort(collect(cell); by = first) if haskey(d, a) && haskey(d, b) && r > 0]
values_of(cell::Cell, c) = [d[c] for (r, d) in sort(collect(cell); by = first) if haskey(d, c) && r > 0]
slower(x, lower) = lower ? x > 1 : x < 1

function columns_table(cell::Cell, cols, unit)
    println(io, "| column | median [min–max] ($unit) | rounds |")
    println(io, "|---|--:|--:|")
    for c in cols
        v = values_of(cell, c)
        isempty(v) && continue
        println(io, "| $c | $(fmt(v)) | $(length(v)) |")
    end
end
function ratio_line(cell::Cell, a, b, lower)
    r = perround(cell, a, b)
    isempty(r) && return "| $a/$b | - | - |"
    "| $a/$b | $(fmt(r; f = f3)) | $(count(x -> slower(x, lower), r)) of $(length(r)) slower |"
end

# ------------------------------------------------------------------------------------------ header
println(io, "# #618 report of master_measure.sh: ", OUT, "\n")
log = joinpath(OUT, "driver.log")
if isfile(log)
    for l in eachline(log)
        occursin(r"build [a-z0-9-]+: |step [a-z0-9]+: (exit|CUT)|STOP|driver done|RESULT|CACHE FILES", l) && println(io, "    ", l)
    end
end

# ------------------------------------------------------------------------------------------ part A
const A_COLS = ["ctl", "ctl2", "mark", "inline", "bypass"]
function partA_cells()
    cells = Pair{String,Tuple{Cell,Bool,String,Float64}}[]   # name => (cell, lower is better, unit, ops per unit for ns)
    for (step, layout) in (("a81f", "8,1"), ("a21f", "2,1"))
        c = Cell(); spawns = NaN
        for row in readtsv(joinpath(OUT, step, "fibabba-nested.tsv"))
            row["bench"] == "fib_fine" || continue
            add!(c, parse(Int, row["round"]), col_of(row["commit"], row["variant"]), num(row["wall_median_s"]))
            spawns = num(row["spawns"])
        end
        isempty(c) || push!(cells, "fib_fine $layout" => (c, true, "s", spawns))
    end
    rows = readtsv(joinpath(OUT, "a80h", "costrounds-spawn.tsv"))
    for C in ("50", "500")
        c = Cell()
        for row in rows
            row["c"] == C || continue
            add!(c, parse(Int, row["round"]), col_of(row["commit"], row["variant"]), num(row["rps"]))
        end
        isempty(c) || push!(cells, "H = 0, C = $C, :default, 8,0" => (c, false, "req/s", 1.0))
    end
    for (step, layout) in (("a21s", "2,1"), ("a41s", "4,1"))
        c = Cell()
        for l in (isfile(joinpath(OUT, step, "costrounds-micro.tsv")) ? eachline(joinpath(OUT, step, "costrounds-micro.tsv")) : String[])
            v = split(l, '\t')
            length(v) >= 11 && v[7] == "SpawnWait" || continue
            b = replace(v[end], "build=" => "")
            add!(c, parse(Int, v[1]), col_of(b, split(v[4], '%')[1]), num(replace(v[8], "ns_per_op=" => "")))
        end
        isempty(c) || push!(cells, "tasks.jl SpawnWait $layout" => (c, true, "ns/op", 1.0))
    end
    cells
end

function readingA(cell::Cell, lower)
    m(a, b) = med(perround(cell, a, b))
    floor = max(abs(m("ctl2", "ctl") - 1), 0.005)
    d_mc = abs(m("mark", "ctl") - 1); d_cc = abs(m("ctl2", "ctl") - 1)
    bypass_with_mark = abs(m("mark", "bypass") - 1) <= floor
    bypass_with_ctls = abs(m("bypass", "ctl") - 1) <= floor && abs(m("bypass", "ctl2") - 1) <= floor
    rounds = sort([r for r in keys(cell) if r > 0 && all(c -> haskey(cell[r], c), ("mark", "ctl", "ctl2", "bypass"))])
    off_all = count(r -> all(c -> slower(cell[r]["mark"] / cell[r][c], lower), ("ctl", "ctl2", "bypass")), rounds)
    need = ceil(Int, 13 / 15 * length(rounds))
    s = "floor (|ctl2/ctl − 1|, at least 0.005) = $(f3(floor)); |mark/ctl − 1| = $(f3(d_mc)); mark slower than ctl, ctl2 and bypass in $off_all of $(length(rounds)) rounds (THE PATH needs $need). "
    if bypass_with_ctls && !bypass_with_mark && off_all >= need
        return s * "**THE PATH**"
    elseif d_mc <= d_cc || bypass_with_mark
        return s * "**LAYOUT**" * (d_mc <= d_cc ? " (mark within the two controls' distance)" : "") * (bypass_with_mark ? " (bypass stands with the mark)" : "")
    else
        return s * "**NOT SEPARABLE**"
    end
end

cellsA = partA_cells()
if !isempty(cellsA)
    println(io, "\n## A. The floor on master, and what code that marks nothing pays\n")
    for (name, (cell, lower, unit, ops)) in cellsA
        println(io, "\n### $name\n")
        columns_table(cell, A_COLS, unit)
        println(io, "\n| per round | median [min–max] | lean |\n|---|--:|---|")
        for (a, b) in (("mark", "ctl"), ("mark", "ctl2"), ("ctl2", "ctl"), ("mark", "bypass"), ("inline", "mark"), ("bypass", "ctl"))
            println(io, ratio_line(cell, a, b, lower))
        end
        rounds = sort([r for r in keys(cell) if r > 0 && all(c -> haskey(cell[r], c), ("mark", "ctl", "ctl2", "bypass"))])
        if !isempty(rounds)
            # The mark against the mean of the three columns without the path, per round, in ns an operation.
            d = [cell[r]["mark"] - (cell[r]["ctl"] + cell[r]["ctl2"] + cell[r]["bypass"]) / 3 for r in rounds]
            nsop = unit == "s" ? [x * 1e9 / ops for x in d] : unit == "req/s" ?
                   [1e9 / cell[r]["mark"] - 3e9 / (cell[r]["ctl"] + cell[r]["ctl2"] + cell[r]["bypass"]) for r in rounds] : d
            println(io, "\nmark − mean(ctl, ctl2, bypass), ns ", unit == "s" ? "a spawn" : unit == "req/s" ? "a request (pool wall time)" : "an op", ": ", fmt(nsop; f = f3))
        end
        println(io, "\nReading: ", readingA(cell, lower))
    end
end

# ------------------------------------------------------------------------------------------ part B
function fairness_rows(step)
    d = joinpath(OUT, step, "raw")
    rows = Dict{String,String}[]
    isdir(d) || return rows
    for f in sort(readdir(d; join = true))
        occursin(r"fairness-\d+-\d+\.tsv$", f) || continue
        append!(rows, readtsv(f))
    end
    rows
end
fcol(mode) = (m = match(r"%(\w[\w-]*)$", mode); m === nothing ? mode : m[1] == "mark" ? "mark (listener marked, N)" : m[1])
flayout(mode) = (m = match(r"@(\d+,\d+)", mode); m === nothing ? "?" : m[1])

function server_table(rows; extra = String[])
    groups = Dict{Tuple{String,String},Vector{Dict{String,String}}}()
    for r in rows
        parse(Int, r["round"]) > 0 || continue
        push!(get!(groups, (flayout(r["mode"]), fcol(r["mode"])), Dict{String,String}[]), r)
    end
    println(io, "| layout | column | rounds | rps | p99 ms | max ms | requests a connection, min | median | jain |", join([" $e |" for e in extra]))
    println(io, "|---|---|--:|--:|--:|--:|--:|--:|--:|", repeat("--:|", length(extra)))
    for k in sort(collect(keys(groups)))
        g = groups[k]
        p(c) = fmt(num.(getindex.(g, c)))
        println(io, "| $(k[1]) | $(k[2]) | $(length(g)) | $(p("rps")) | $(p("p99_ms")) | $(p("max_ms")) | $(p("conn_min")) | $(p("conn_p50")) | $(p("jain")) |",
                join([" $(p(e)) |" for e in extra]))
    end
    groups
end

function mixed_table(path, label)
    rows = readtsv(path)
    isempty(rows) && return
    g = Dict{String,Vector{Dict{String,String}}}()
    for r in rows
        parse(Int, r["round"]) > 0 || continue
        push!(get!(g, col_of(r["commit"], r["variant"]), Dict{String,String}[]), r)
    end
    println(io, "\n$label\n")
    println(io, "| column | rounds | p99 ms | max ms | least-served client (requests) | rps | fib alone (s, in-process) | fib during (s) | fib slowdown (during / alone) | fib runs during |")
    println(io, "|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|")
    for c in sort(collect(keys(g)))
        rs = g[c]
        slow = [num(r["fib_median_s"]) / num(r["fib_alone_median_s"]) for r in rs]
        println(io, "| $c | $(length(rs)) | $(fmt(num.(getindex.(rs, "p99_ms")))) | $(fmt(num.(getindex.(rs, "max_ms")))) | $(fmt(num.(getindex.(rs, "count_min")))) | ",
                "$(fmt(num.(getindex.(rs, "rps")))) | $(fmt(num.(getindex.(rs, "fib_alone_median_s")))) | $(fmt(num.(getindex.(rs, "fib_median_s")))) | ",
                "$(fmt(filter(!isnan, slow); f = f3)) | $(fmt(num.(getindex.(rs, "fib_runs")))) |")
    end
    g
end

function pfib_table(path)
    rows = readtsv(path)
    isempty(rows) && return
    g = Dict{String,Cell}()
    c = Cell()
    for r in rows
        haskey(r, "median_s") || continue
        add!(c, parse(Int, r["round"]), r["label"], num(r["median_s"]))
    end
    columns_table(c, ["ws", "base", "ctl", "m", "root", "all"], "s, median of the BenchmarkTools samples")
    println(io, "\n| per round | median [min–max] | lean |\n|---|--:|---|")
    for (a, b) in (("ws", "base"), ("m", "ctl"), ("root", "ctl"), ("all", "ctl"))
        isempty(perround(c, a, b)) || println(io, ratio_line(c, a, b, true))
    end
    c
end

if any(isdir(joinpath(OUT, s)) for s in ("bstarved", "bmixed", "bcell1", "bpfib", "bshare"))
    println(io, "\n## B. The design on master over rounds\n")
    rows = filter(r -> r["mode"] == "spawn", readtsv(joinpath(OUT, "bstarved", "fairrounds-spawn.tsv")))
    if !isempty(rows)
        println(io, "\n### The starved cell, 500:2, 8,1, :interactive clients\n")
        println(io, "| column | rounds | p99 ms (per round) | max ms | least-served client | rps |\n|---|--:|---|--:|--:|--:|")
        for c in ("ctl", "markN")
            rs = filter(r -> col_of(r["commit"], r["variant"]) == c && parse(Int, r["round"]) > 0, rows)
            isempty(rs) && continue
            println(io, "| $c | $(length(rs)) | $(join([r["p99_ms"] for r in rs], ", ")) | $(fmt(num.(getindex.(rs, "max_ms")))) | $(fmt(num.(getindex.(rs, "count_min")))) | $(fmt(num.(getindex.(rs, "rps")))) |")
        end
        mk = filter(r -> col_of(r["commit"], r["variant"]) == "markN" && parse(Int, r["round"]) > 0, rows)
        ok = !isempty(mk) && all(r -> num(r["p99_ms"]) <= 200 && num(r["count_min"]) >= 1, mk)
        println(io, "\nBar (the tag's: p99 ≤ 200 ms in every round, every client served): ", isempty(mk) ? "no rows" : ok ? "**pass**" : "**FAIL**")
    end
    gm = mixed_table(joinpath(OUT, "bmixed", "mixed.tsv"), "### The mixed cell, plain, w = 1/2, 8,1")
    gi = mixed_table(joinpath(OUT, "bmixed", "mixedinner.tsv"), "### The mixed cell, inner, w = 1/2, 8,1")
    for (g, nm) in ((gm, "plain"), (gi, "inner"))
        g === nothing && continue
        rs = get(g, "markN", Dict{String,String}[])
        local ok = !isempty(rs) && all(r -> num(r["p99_ms"]) <= 600 && num(r["fib_median_s"]) / num(r["fib_alone_median_s"]) <= 2.5, rs)
        println(io, "\nBar, $nm (the tag's: p99 ≤ 600 ms and fib ≤ 2.5× in every round): ", isempty(rs) ? "no rows" : ok ? "**pass**" : "**FAIL**")
    end
    if isfile(log)
        sl = filter(l -> occursin(r"bshare (plain|inner): ", l), readlines(log))
        isempty(sl) || (println(io, "\n### The credited share (N on mark-validate, VALIDATE=1, once)\n"); foreach(l -> println(io, "    ", l), sl))
    end
    rows = fairness_rows("bcell1")
    if !isempty(rows)
        println(io, "\n### Server cell 1, /aggregate, c = 500, fresh servers\n")
        groups = server_table(rows)
        for lay in ("8,1", "8,0")
            ctl = get(groups, (lay, "control"), nothing); local mk = get(groups, (lay, "mark (listener marked, N)"), nothing)
            (ctl === nothing || mk === nothing) && continue
            byr(g) = Dict(parse(Int, r["round"]) => r for r in g)
            cr, mr = byr(ctl), byr(mk)
            rs = sort(collect(intersect(keys(cr), keys(mr))))
            ratio = [num(mr[r]["rps"]) / num(cr[r]["rps"]) for r in rs]
            local ok = all(r -> num(mr[r]["p99_ms"]) <= 150, rs) && all(>=(0.98), ratio)
            println(io, "\n$lay: rps mark/control per round $(join(f3.(ratio), ", ")); bar (mine: mark p99 ≤ 150 ms and rps ≥ 0.98× the control in every round): ", ok ? "**pass**" : "**FAIL**")
        end
    end
    if isfile(joinpath(OUT, "bpfib", "pfib.tsv"))
        println(io, "\n### pfib(25), 8,1\n")
        c = pfib_table(joinpath(OUT, "bpfib", "pfib.tsv"))
        r = perround(c, "root", "ctl")
        isempty(r) || println(io, "\nBar (the tag's: root marked ≤ 1.10× the control): ", med(r) <= 1.10 ? "**pass**" : "**FAIL**", " (median $(f3(med(r))))")
    end
end

# ------------------------------------------------------------------------------------------ part C
const C_ORDER = ["ws", "base", "ctl", "mark", "markN"]
if any(isdir(joinpath(OUT, s)) for s in ("cspawn", "cserver", "cmixed", "cplain81", "cplain80", "cfj", "ctasks"))
    println(io, "\n## C. #62285 against the mark (each against its own base: ws/base, mark/control)\n")
    summary = String[]   # the maintainer's table rows
    rows = readtsv(joinpath(OUT, "cspawn", "costrounds-spawn.tsv"))
    for (lay, cl) in (("8,0", "default"), ("8,1", "interactive")), C in ("50", "500")
        local c = Cell()
        for r in rows
            (r["threads"] == lay && r["clients"] == cl && r["c"] == C) || continue
            add!(c, parse(Int, r["round"]), col_of(r["commit"], r["variant"]), num(r["rps"]))
        end
        isempty(c) && continue
        println(io, "\n### Spawn path, H = 0, C = $C, :$cl clients, $lay (req/s)\n")
        columns_table(c, C_ORDER, "req/s")
        println(io, "\n| per round | median [min–max] | lean |\n|---|--:|---|")
        for (a, b) in (("ws", "base"), ("markN", "ctl"), ("mark", "ctl"))
            println(io, ratio_line(c, a, b, false))
        end
        push!(summary, "| spawn path H = 0, C = $C, :$cl, $lay (req/s) | $(f3(med(perround(c, "ws", "base")))) | $(f3(med(perround(c, "markN", "ctl")))) (N), $(f3(med(perround(c, "mark", "ctl")))) (none) | " *
              join([fg(med(values_of(c, x))) for x in ("ws", "base", "ctl", "markN")], " · ") * " |")
    end
    for (step, title) in (("cserver", "Server cell 1, /aggregate, c = 500, 8,1"), ("cplain81", "/plaintext, oha, c = 500, 8,1"), ("cplain80", "/plaintext, oha, c = 500, 8,0"))
        local rows = fairness_rows(step)
        isempty(rows) && continue
        println(io, "\n### $title\n")
        plain = startswith(step, "cplain")
        local groups = server_table(rows; extra = plain ? ["oha_rps", "cli_cpu", "oha_cpu"] : String[])
        lay = step == "cplain80" ? "8,0" : "8,1"
        byr(g) = Dict(parse(Int, r["round"]) => r for r in g)
        function rr(a, b, f)
            ga = get(groups, (lay, a), nothing); gb = get(groups, (lay, b), nothing)
            (ga === nothing || gb === nothing) && return Float64[]
            A, B = byr(ga), byr(gb)
            [num(A[r][f]) / num(B[r][f]) for r in sort(collect(intersect(keys(A), keys(B))))]
        end
        mkl = "mark (listener marked, N)"
        metric = plain ? "oha_rps" : "rps"
        println(io, "\nPer round: ws/base $metric $(fmt(rr("ws", "base", metric); f = f3)); mark/control $(fmt(rr(mkl, "control", metric); f = f3))",
                plain ? "" : "; p99 ws/base $(fmt(rr("ws", "base", "p99_ms"); f = f3)), mark/control $(fmt(rr(mkl, "control", "p99_ms"); f = f3))")
        abs4 = join([fg(med(num.(getindex.(get(groups, (lay, x), Dict{String,String}[]), metric)))) for x in ("ws", "base", "control", mkl)], " · ")
        push!(summary, "| $title ($metric) | $(f3(med(rr("ws", "base", metric)))) | $(f3(med(rr(mkl, "control", metric)))) | $abs4 |")
        if !plain
            p4 = join([fg(med(num.(getindex.(get(groups, (lay, x), Dict{String,String}[]), "p99_ms")))) for x in ("ws", "base", "control", mkl)], " · ")
            push!(summary, "| $title (p99 ms) | $(f3(med(rr("ws", "base", "p99_ms")))) | $(f3(med(rr(mkl, "control", "p99_ms")))) | $p4 |")
        end
    end
    for (f, nm) in (("mixed.tsv", "plain"), ("mixedinner.tsv", "inner"))
        g = mixed_table(joinpath(OUT, "cmixed", f), "### The mixed cell, $nm, 8,1 (requests beside unmarked compute)")
        g === nothing && continue
        p99(c) = med(num.(getindex.(get(g, c, Dict{String,String}[]), "p99_ms")))
        sl(c) = med(filter(!isnan, [num(r["fib_median_s"]) / num(r["fib_alone_median_s"]) for r in get(g, c, Dict{String,String}[])]))
        cm(c) = med(num.(getindex.(get(g, c, Dict{String,String}[]), "count_min")))
        push!(summary, "| mixed $nm: p99 ms · least-served client · fib slowdown | – | – | " *
              join(["$x $(fg(p99(x))) · $(fg(cm(x))) · $(f3(sl(x)))" for x in ("ws", "base", "ctl", "markN")], "; ") * " |")
    end
    if isfile(joinpath(OUT, "cfj", "fibabba-nested.tsv"))
        c = Cell()
        for r in readtsv(joinpath(OUT, "cfj", "fibabba-nested.tsv"))
            r["bench"] == "fib_fine" || continue
            add!(c, parse(Int, r["round"]), col_of(r["commit"], r["variant"]), num(r["wall_median_s"]))
        end
        println(io, "\n### Fork-join: fib_fine alone, 8,1 (s)\n")
        columns_table(c, C_ORDER, "s")
        println(io, "\n| per round | median [min–max] | lean |\n|---|--:|---|")
        println(io, ratio_line(c, "ws", "base", true)); println(io, ratio_line(c, "mark", "ctl", true))
        push!(summary, "| fib_fine alone, 8,1 (s) | $(f3(med(perround(c, "ws", "base")))) | $(f3(med(perround(c, "mark", "ctl")))) | " *
              join([fg(med(values_of(c, x))) for x in ("ws", "base", "ctl", "mark")], " · ") * " |")
    end
    if isfile(joinpath(OUT, "cfj", "pfib.tsv"))
        println(io, "\n### Fork-join: pfib(25), 8,1\n")
        c = pfib_table(joinpath(OUT, "cfj", "pfib.tsv"))
        push!(summary, "| pfib(25), 8,1 (s) | $(f3(med(perround(c, "ws", "base")))) | $(f3(med(perround(c, "m", "ctl")))) | " *
              join([fg(med(values_of(c, x))) for x in ("ws", "base", "ctl", "m")], " · ") * " |")
    end
    mp = joinpath(OUT, "ctasks", "costrounds-micro.tsv")
    if isfile(mp)
        println(io, "\n### tasks.jl at 8,1 (ns an op)\n")
        for row in ("SpawnWait", "FanOut1000")
            local c = Cell()
            for l in eachline(mp)
                v = split(l, '\t')
                length(v) >= 11 && v[7] == row && startswith(v[8], "ns_per_op=") || continue
                add!(c, parse(Int, v[1]), col_of(replace(v[end], "build=" => ""), split(v[4], '%')[1]), num(replace(v[8], "ns_per_op=" => "")))
            end
            isempty(c) && continue
            println(io, "\n$row\n"); columns_table(c, C_ORDER, "ns/op")
            println(io, "\n| per round | median [min–max] | lean |\n|---|--:|---|")
            println(io, ratio_line(c, "ws", "base", true)); println(io, ratio_line(c, "mark", "ctl", true))
            push!(summary, "| tasks.jl $row, 8,1 (ns/op) | $(f3(med(perround(c, "ws", "base")))) | $(f3(med(perround(c, "mark", "ctl")))) | " *
                  join([fg(med(values_of(c, x))) for x in ("ws", "base", "ctl", "mark")], " · ") * " |")
        end
    end
    pp = joinpath(OUT, "ctasks", "pool.tsv")
    if isfile(pp)
        rows = readtsv(pp)
        for (lay, cl) in (("8,1", "interactive"), ("8,0", "default"))
            local c = Cell()
            for r in rows
                r["threads"] == lay && r["clients"] == cl || continue
                add!(c, parse(Int, r["round"]), col_of(r["commit"], r["variant"]), num(r["rps"]))
            end
            isempty(c) && continue
            println(io, "\n### The Channel worker pool (spawn_order.jl MODES=pool), C = 500, :$cl clients, $lay (req/s)\n")
            columns_table(c, C_ORDER, "req/s")
            println(io, "\n| per round | median [min–max] | lean |\n|---|--:|---|")
            println(io, ratio_line(c, "ws", "base", false)); println(io, ratio_line(c, "mark", "ctl", false))
            push!(summary, "| Channel worker pool, C = 500, $lay (req/s) | $(f3(med(perround(c, "ws", "base")))) | $(f3(med(perround(c, "mark", "ctl")))) | " *
                  join([fg(med(values_of(c, x))) for x in ("ws", "base", "ctl", "mark")], " · ") * " |")
        end
    end
    if !isempty(summary)
        println(io, "\n### The table for the maintainer\n")
        println(io, "| cell | ws/base | mark/control | ws · base · control · mark (absolute, medians) |\n|---|--:|--:|---|")
        foreach(l -> println(io, l), summary)
    end
end

# ------------------------------------------------------------------------------------------ part D
function set_windows(logf)
    starts = Dict{String,DateTime}(); wins = Tuple{String,Float64,Float64}[]
    isfile(logf) || return wins
    for l in eachline(logf)
        m = match(r"^(\S+)\s+\((\d+)\)\s+\|\s+started at (\S+)", l)
        if m !== nothing
            starts[m[1]] = DateTime(m[3][1:min(end, 23)]); continue
        end
        m = match(r"^(\S+)\s+\((\d+)\)\s+\|\s+([0-9.]+)\s+\|", l)
        if m !== nothing && haskey(starts, m[1])
            push!(wins, (String(m[1]), datetime2unix(starts[m[1]]), datetime2unix(starts[m[1]]) + parse(Float64, m[3])))
        end
    end
    wins
end
const TZOFF = round(Int, (now() - now(UTC)).value / 1000)
const SUBPROC_SET = Dict("print_process_affinity.jl" => "threads", "profile_spawnmany_exec.jl" => "threads",
    "threads_exec.jl" => "threads", "channel_threadpool.jl" => "channel_threadpool", "threadpool_use.jl" => "threadpool_use",
    "ioloop_wakeup.jl" => "threads (ioloop_wakeup)", "threadcall_iolock_wakeup.jl" => "threads", "foreign_thread_reuse.jl" => "threads")
function attribute(file, args, t, wins)
    file == "runtests.jl" && return (isempty(args) ? "(the runner)" : "runner: $args", "read")
    s = get(SUBPROC_SET, file, nothing)
    s === nothing || return (s, "read")
    file in ("", "-") || return ("(other: $file)", "read")
    ended = [w[1] for w in wins if w[3] - 1 <= t <= w[3] + 4]
    length(ended) == 1 && return (ended[1], "inferred: worker exit as the set ended")
    running = unique([w[1] for w in wins if w[2] <= t <= w[3]])
    length(running) == 1 && return (running[1], "inferred: exited while only this set ran")
    isempty(running) ? ("(between sets / precompile)", "inferred") : (join(sort(running), "/"), "inferred: ambiguous")
end
const XHDR = ["pid", "mode", "src", "threads", "f_first", "l_first", "r_first", "demoted", "r_ins", "f_again", "stale", "file", "args"]
td = joinpath(OUT, "dtests")
if isdir(td) || isfile(log)
    println(io, "\n## D. The validation session 1 did not reach\n")
    isfile(log) && foreach(l -> println(io, "    ", l), filter(l -> occursin(r"tests |dinline|window ", l), readlines(log)))
    isdir(td) && for c in sort(readdir(td))
        ld = joinpath(td, c, "log")
        (isdir(ld) && !isempty(readdir(ld))) || continue
        logs = filter(f -> endswith(f, ".log"), readdir(joinpath(td, c); join = true))
        wins = reduce(vcat, [set_windows(f) for f in logs]; init = Tuple{String,Float64,Float64}[])
        agg = Dict{String,Vector{Any}}()
        for f in readdir(ld; join = true)
            endswith(f, ".tsv") || continue
            line = readchomp(f); isempty(line) && continue
            v = split(line, '\t'); length(v) < 11 && continue
            local r = Dict(XHDR[i] => String(get(v, i, "")) for i in eachindex(XHDR))
            r["file"] = basename(r["file"])
            set, how = attribute(r["file"], r["args"], mtime(f) + TZOFF, wins)
            a = get!(agg, set, Any[0, 0, 0, 0, 0, 0, Set{String}(), Set{String}()])
            a[1] += 1; r["mode"] != "unset" && (a[2] += 1)
            a[3] += parse(Int, r["f_first"]); a[4] += parse(Int, r["r_ins"]); a[5] += parse(Int, r["stale"]); a[6] += parse(Int, r["demoted"])
            push!(a[7], r["threads"]); push!(a[8], how)
        end
        println(io, "\n### exit logs: $c\n")
        println(io, "| set | processes | switch on | marked first enqueues (f_first) | R inserts | stale pops | demoted | layouts | attribution | reached the multiqueue |")
        println(io, "|---|--:|--:|--:|--:|--:|--:|---|---|---|")
        for k in sort(collect(keys(agg)))
            a = agg[k]
            println(io, "| $k | $(a[1]) | $(a[2]) | $(a[3]) | $(a[4]) | $(a[5]) | $(a[6]) | $(join(sort(collect(a[7])), " ")) | $(join(sort(collect(a[8])), "; ")) | ",
                    a[3] + a[4] > 0 ? "yes" : "**no**", " |")
        end
    end
end

# ------------------------------------------------------------------------------------------ part E
f = joinpath(OUT, "e1", "fibabba-nested.tsv")
if isfile(f)
    println(io, "\n## E1. fib_fine at 8,1 with nothing marked: the pool flag unset and set\n")
    c = Cell()
    for r in readtsv(f)
        r["bench"] == "fib_fine" || continue
        add!(c, parse(Int, r["round"]), col_of(r["commit"], r["variant"]), num(r["wall_median_s"]))
    end
    columns_table(c, ["ctl", "mark", "markArm"], "s")
    println(io, "\n| per round | median [min–max] | lean |\n|---|--:|---|")
    for (a, b) in (("mark", "ctl"), ("markArm", "ctl"), ("markArm", "mark"))
        println(io, ratio_line(c, a, b, true))
    end
end
tsv = joinpath(E2, "runs.tsv")
if isfile(tsv)
    println(io, "\n## E2. Forcible abandonments (master_checks.jl abandon 50)\n")
    rows = readtsv(tsv)
    println(io, "| build | runs | hung | failed otherwise | the probe's ok line missing | Workqueue inconsistency | median wall s |\n|---|--:|--:|--:|--:|--:|--:|")
    for b in unique(getindex.(rows, "build"))
        rs = filter(r -> r["build"] == b, rows)
        h = count(r -> r["hung"] == "1", rs)
        println(io, "| $b | $(length(rs)) | $h | $(count(r -> r["hung"] == "0" && r["status"] != "0", rs)) | $(count(r -> r["ok_line"] == "0", rs)) | ",
                "$(count(r -> r["workqueue_inconsistency"] == "1", rs)) | $(f3(med(num.(getindex.(rs, "wall_s"))))) |")
    end
    hangs = filter(f -> endswith(f, ".hang"), readdir(E2; join = true))
    for h in hangs
        println(io, "\n#### ", basename(h), "\n\n```")
        println(io, read(h, String))
        e = replace(h, ".hang" => ".err")
        isfile(e) && println(io, "--- stderr (last 60 lines)\n", join(last(readlines(e), 60), "\n"))
        println(io, "```")
    end
end

# ------------------------------------------------------------------------------------------ session 3
# Master at #62285's merge-base, built twice (SESSION=3). Every ratio here is a SPEED against its
# reference: above 1 is faster (a throughput ratio, or the reference's time over this one's).
const S3_COLS = ["july", "july-n", "base", "ctl", "ctl2"]
const S3_PAIRS = [("base", "july-n", "base/july-n: the branch, one configuration"),
                  ("ctl", "july", "control/july: master's four months, one configuration"),
                  ("july-n", "july", "july-n/july: the build configuration, one source"),
                  ("ctl2", "ctl", "control2/control: the floor"),
                  ("ctl", "base", "control/base: session 2's gap")]
speed(cell::Cell, a, b, lower) = lower ? perround(cell, b, a) : perround(cell, a, b)
function s3_reading(cell::Cell, lower)
    m(a, b) = med(speed(cell, a, b, lower))
    fl = abs(m("ctl2", "ctl") - 1)
    bar = max(0.05, 3fl)
    beyond(x) = !isnan(x) && abs(x - 1) > bar
    b, ms, t = m("base", "july-n"), m("ctl", "july"), m("july-n", "july")
    v = beyond(b) && !beyond(ms) ? "**THE BRANCH**" : beyond(ms) && !beyond(b) ? "**MASTER**" :
        beyond(b) && beyond(ms) ? "**BOTH** (branch $(f3(b)), master $(f3(ms)))" : "**NEITHER READABLE**"
    beyond(t) && (v *= "; **CONFIGURATION** (july-n/july $(f3(t)))")
    return bar, v
end
function s3_cell(name, cell::Cell, lower, unit, summary)
    isempty(cell) && return
    println(io, "\n### $name ($unit)\n")
    columns_table(cell, S3_COLS, unit)
    println(io, "\n| speed per round (above 1 is faster) | median [min–max] | faster in |\n|---|--:|--:|")
    for (a, b, what) in S3_PAIRS
        r = speed(cell, a, b, lower)
        isempty(r) && continue
        println(io, "| $what | $(fmt(r; f = f3)) | $(count(>(1), r)) of $(length(r)) |")
    end
    bar, v = s3_reading(cell, lower)
    println(io, "\nBar: beyond 5% and beyond 3 × |control2/control − 1| = $(f3(bar)). Reading: $v")
    push!(summary, "| $name ($unit) | " * join([fg(med(values_of(cell, c))) for c in S3_COLS], " · ") * " | " *
          join([f3(med(speed(cell, a, b, lower))) for (a, b, _) in S3_PAIRS[1:4]], " | ") * " | $(f3(bar)) | $v |")
end
const S3_SERVER_COL = Dict("july" => "july", "july-n" => "july-n", "base" => "base", "control" => "ctl", "control2" => "ctl2")
if any(isdir(joinpath(OUT, s)) for s in ("jtasks", "jspawn", "jpool", "jperf", "jplain81", "jplain80"))
    println(io, "\n## S3. Master at #62285's merge-base: is base/control the branch or master?\n")
    println(io, "Columns: july (6ac8c4f030, the master trees' multi-target Make.user), july-n (the same commit, base's native Make.user), base (#62285's head, partr), ctl and ctl2 (master 4b0df1484a, twice). Every ratio is a SPEED: above 1 is faster.")
    summary = String[]
    mp = joinpath(OUT, "jtasks", "costrounds-micro.tsv")
    if isfile(mp)
        for row in ("SpawnWait", "FanOut1000")
            local c = Cell()
            for l in eachline(mp)
                v = split(l, '\t')
                length(v) >= 11 && v[7] == row && startswith(v[8], "ns_per_op=") || continue
                add!(c, parse(Int, v[1]), col_of(replace(v[end], "build=" => ""), split(v[4], '%')[1]), num(replace(v[8], "ns_per_op=" => "")))
            end
            s3_cell("tasks.jl $row, 8,1", c, true, "ns/op", summary)
        end
    end
    rows = readtsv(joinpath(OUT, "jspawn", "costrounds-spawn.tsv"))
    for (lay, cl) in (("8,1", "interactive"), ("8,0", "default")), C in ("50", "500")
        local c = Cell()
        for r in rows
            (r["threads"] == lay && r["clients"] == cl && r["c"] == C) || continue
            add!(c, parse(Int, r["round"]), col_of(r["commit"], r["variant"]), num(r["rps"]))
        end
        s3_cell("spawn path H = 0, C = $C, :$cl, $lay", c, false, "req/s", summary)
    end
    rows = readtsv(joinpath(OUT, "jpool", "pool.tsv"))
    for (lay, cl) in (("8,1", "interactive"), ("8,0", "default"))
        local c = Cell()
        for r in rows
            r["threads"] == lay && r["clients"] == cl || continue
            add!(c, parse(Int, r["round"]), col_of(r["commit"], r["variant"]), num(r["rps"]))
        end
        s3_cell("Channel worker pool, C = 500, :$cl, $lay", c, false, "req/s", summary)
    end
    for (step, lay) in (("jplain81", "8,1"), ("jplain80", "8,0"))
        local c = Cell()
        for r in fairness_rows(step)
            flayout(r["mode"]) == lay || continue
            local m = match(r"%(\w[\w-]*)$", r["mode"]); m === nothing && continue
            haskey(S3_SERVER_COL, m[1]) || continue
            add!(c, parse(Int, r["round"]), S3_SERVER_COL[m[1]], num(r["oha_rps"]))
        end
        s3_cell("/plaintext, oha, c = 500, $lay", c, false, "oha rps", summary)
    end
    if !isempty(summary)
        println(io, "\n### The table (medians; speeds above 1 are faster)\n")
        println(io, "| cell | july · july-n · base · control · control2 | base/july-n | control/july | july-n/july | control2/control | bar | reading |")
        println(io, "|---|---|--:|--:|--:|--:|--:|---|")
        foreach(l -> println(io, l), summary)
    end
    isdir(joinpath(OUT, "jperf")) && println(io, "\nPart B: `PU_COLS=\"july julyn base ctl\" PU_REPORT_LAYOUTS=8,1 julia bench/julia/perf_report.jl $(joinpath(OUT, "jperf"))`.")
end
