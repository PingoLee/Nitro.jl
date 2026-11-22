# #618 Idea 16, part A's decision: does s2 stand on two builds? (bench/julia/slim2.sh, step decideA)
#   julia slim2_decide.jl <report-a.txt> <perf OUT dir>   -> prints the reading, writes <dir of report>/stands
# Inputs: slim_report.jl's report of the cells (s2's second build is its `w2` column), and the split
# loop's runs (perf_unmarked.sh step a5, MODE=split: <perf OUT>/a5/r<run>-<layout>-<build>.line).
# s2 stands if (1) in every cell where m2 is off both bypass builds, s2 and w2 both stand with them
# (slim_report.jl's own test: cand/bp and cand/bp2 within the spread, max(|bp2/bp - 1|, 0.5%)), and
# (2) in the split loop, at each layout, both s2 builds' pickup (median over runs of the per-run mean)
# is within 5 ns of both bypass builds'. A DRAW (part B does not run) if in some cell the two s2 builds
# are further apart (|median w2/s2 - 1|) than the spread. Stdlib only.
const REPORT, PERF = ARGS[1], ARGS[2]
med(v) = (s = sort(v); n = length(s); n == 0 ? NaN : isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)
num(s) = parse(Float64, rstrip(first(split(strip(s))), [';', ',']))

cells = Dict{String, Dict{String, Any}}()
cur = ""
for l in eachline(REPORT)
    m = match(r"^## (.+?)  \(", l)
    if m !== nothing
        global cur = m[1]; cells[cur] = Dict{String, Any}(); continue
    end
    isempty(cur) && continue
    m = match(r"^  (w2/s2|bp2/bp|s2/bp|s2/bp2|w2/bp|w2/bp2|m2/bp|m2/bp2)\s+(\S+)", l)
    m !== nothing && (cells[cur][m[1]] = num(m[2]))
    if startswith(l, "  spread ")
        cells[cur]["spread"] = num(l[10:end])
        cells[cur]["m2off"] = occursin("m2 OFF both", l)
        cells[cur]["s2"] = occursin("s2 stands", l)
        cells[cur]["w2"] = occursin("w2 stands", l)
    end
end

# The verdict's cells: slim_report.jl's PATH (fib_fine 2,1 is the layout control, PingPong and FanOut
# ride along in tasks.jl's micro rows: reported, not tested).
const PATH = ["H = 0 C = 50 default 2,1 (rps)", "tasks.jl SpawnWait 2,1 (ns)", "tasks.jl SpawnWait 4,1 (ns)"]
lines = String[]
ok = true; draw = false
for c in sort(collect(keys(cells)))
    d = cells[c]
    haskey(d, "spread") || continue
    apart = haskey(d, "w2/s2") ? abs(d["w2/s2"] - 1) : NaN
    inpath = c in PATH
    dis = !isnan(apart) && apart > d["spread"]
    dis && inpath && (global draw = true)
    need = d["m2off"]
    pass = !need || (d["s2"] && d["w2"])
    pass || !inpath || (global ok = false)
    push!(lines, string("cell\t", c, "\tm2off=", need, "\ts2=", d["s2"], "\ts2b=", d["w2"], "\tspread=", round(d["spread"]; digits = 4),
                        "\ts2b/s2=", get(d, "w2/s2", NaN), "\tbuilds_disagree=", dis, "\t", inpath ? "" : "(info) ", need ? (pass ? "STANDS" : "DOES NOT STAND") : "m2 not off: no test"))
end

# The split loop.
kv(l) = Dict(split(f, '=', limit = 2)[1] => split(f, '=', limit = 2)[2] for f in split(chomp(l), '\t') if occursin('=', f))
pk = Dict{Tuple{String, String}, Vector{Float64}}()
dir = joinpath(PERF, "a5")
if isdir(dir)
    for f in readdir(dir)
        m = match(r"^r\d+-(\d)_(\d)-(\w+)\.line$", f)
        m === nothing && continue
        push!(get!(Vector{Float64}, pk, ("$(m[1]),$(m[2])", m[3])), parse(Float64, kv(readline(joinpath(dir, f)))["pickup_mean"]))
    end
end
for l in sort(unique(k[1] for k in keys(pk)))
    g(b) = med(get(pk, (l, b), Float64[]))
    bp, bp2 = g("bp"), g("bp2")
    for b in ("s2", "s2b")
        x = g(b)
        pass = !isnan(x) && abs(x - bp) <= 5 && abs(x - bp2) <= 5
        pass || (global ok = false)
        push!(lines, string("split\t", l, "\t", b, " pickup mean ", round(x; digits = 1), " ns; bp ", round(bp; digits = 1), ", bp2 ",
                            round(bp2; digits = 1), "; m2 ", round(g("m2"); digits = 1), "\t", pass ? "within 5 ns of both" : "NOT within 5 ns of both"))
    end
end
isempty(pk) && (push!(lines, "split\tno split runs found: s2 cannot stand without them"); ok = false)

verdict = draw ? "draw" : ok ? "yes" : "no"
push!(lines, string("stands\t", verdict))
foreach(println, lines)
write(joinpath(dirname(REPORT), "stands"), verdict * "\n")
write(joinpath(dirname(REPORT), "stands.tsv"), join(lines, '\n') * "\n")
