# The comparison block of session 10 (#618): rows f, g and h on v4 and v5 in one block, master (pin-control) as the
# reference, and one yardstick line: fib_fine at 8,1 with nothing marked on v5 and on v5-validate-off (the same code
# in two binaries). THIS BLOCK DECIDES NOTHING: v5's changes are semantics and a bug, not speed.
#
#   julia compare_v5_report.jl <block directory>     (prints summary.txt)
#
# The block is candidate_evidence.sh with the slots control = pin-control, candidate = v5, bypass = v4,
# timens = v5-validate-off (builds.tsv names them), STEPS="prep pfib2 pfib81 spawnpath arm", 12 rounds, and the
# column overrides of its README. EVERY RATIO IS A SPEED against its reference: above 1 is faster.
#   f   pfib(25), 2 threads and 8,1: master's median time over the build's, per round;
#   g   H = 0, C = 50 and 500, :default clients at 8,0, clients and handlers marked: the build's req/s over master's;
#   h   fib_fine at 8,1 after one marked task: against master, and against the same build never marked;
#   yardstick   fib_fine at 8,1, nothing marked (row h's never-marked column), v5 and v5-validate-off against master.
# Per round, v5/v4 is v5's speed over v4's in that round. A line whose median v5/v4 differs from 1 by more than the
# yardstick's two readings differ from each other is reported as such, with its size.
D = ARGS[1]
med(v) = (s = sort(v); n = length(s); isodd(n) ? s[(n+1)÷2] : (s[n÷2] + s[n÷2+1]) / 2)
r3(x) = round(x; digits = 3)
rng(v) = string(r3(med(v)), " [", r3(minimum(v)), "–", r3(maximum(v)), "]")
function rd(p)
    l = readlines(p); h = split(l[1], '\t')
    [Dict(zip(h, split(x, '\t'))) for x in l[2:end] if !isempty(x) && split(x, '\t')[1] != h[1]]
end
builds = Dict(r["label"] => r["commit_short"] for r in rd(joinpath(D, "builds.tsv")))
const NAMES = Dict("v4" => "bypass", "v5" => "candidate", "v5-off" => "timens")
commit(name) = builds[NAMES[name]]
vals(d) = [d[k] for k in sort(collect(keys(d)))]

lines = Tuple{String,Float64,String}[]   # title, median v5/v4, per-round summary
function show_line(title, speeds::Dict{String,Dict{Int,Float64}})
    println(title)
    for n in ("v4", "v5")
        println("  ", rpad(n, 4), "against master ", rng(vals(speeds[n])), " (", length(speeds[n]), " rounds)")
    end
    ks = sort(collect(intersect(keys(speeds["v4"]), keys(speeds["v5"]))))
    q = [speeds["v5"][k] / speeds["v4"][k] for k in ks]
    up, dn = count(>(1), q), count(<(1), q)
    println("  v5/v4 per round: ", join(r3.(q), " "))
    println("  v5/v4: median ", r3(med(q)), ", above 1 in ", up, " of ", length(q), ", below 1 in ", dn)
    push!(lines, (title, med(q), string("above 1 in ", up, " of ", length(q))))
    println()
end

# ---- row f
for (st, lay) in (("pfib2", "2 threads"), ("pfib81", "8,1"))
    p = joinpath(D, "raw", st, "pfib.tsv")
    isfile(p) || (println("row f ", lay, ": NOT RUN\n"); continue)
    rows = filter(r -> parse(Int, r["round"]) >= 1 && !startswith(get(r, "min_s", ""), "FAILED"), rd(p))
    by(l) = Dict(parse(Int, r["round"]) => parse(Float64, r["median_s"]) for r in rows if r["label"] == l)
    c = by("ctl")
    for (mode, tag) in (("root", "r"), ("all", "a"))
        sp = Dict(n => (b = by(tag * n[2:2]); Dict(k => c[k] / b[k] for k in keys(b) if haskey(c, k))) for n in ("v4", "v5"))
        show_line("f pfib(25) $(mode == "root" ? "root marked" : "every spawn marked"), $lay", sp)
    end
end

# ---- row g
p = joinpath(D, "raw", "spawnpath", "costrounds-spawn.tsv")
if isfile(p)
    rows = filter(r -> r["mode"] == "spawn" && parse(Int, r["round"]) >= 1, rd(p))
    for c in ("50", "500")
        rps(cm, v) = Dict(parse(Int, r["round"]) => parse(Float64, r["rps"]) for r in rows
                          if r["c"] == c && startswith(r["commit"], cm) && r["variant"] == v)
        m = rps(builds["control"], "A")
        sp = Dict(n => (b = rps(commit(n), "N"); Dict(k => b[k] / m[k] for k in keys(b) if haskey(m, k))) for n in ("v4", "v5"))
        show_line("g everything marked on the spawn path, C = $c, 8,0", sp)
    end
else
    println("row g: NOT RUN\n")
end

# ---- row h and the yardstick
yard = nothing
p = joinpath(D, "raw", "arm", "fibabba-nested.tsv")
if isfile(p)
    rows = filter(r -> parse(Int, r["round"]) >= 1, rd(p))
    w(cm, v) = Dict(parse(Int, r["round"]) => parse(Float64, r["wall_median_s"]) for r in rows
                    if startswith(r["commit"], cm) && r["variant"] == v)
    ctl = w(builds["control"], "A")
    sp = Dict{String,Dict{Int,Float64}}()
    spa = Dict{String,Dict{Int,Float64}}()
    for n in ("v4", "v5")
        u, a = w(commit(n), "N-none"), w(commit(n), "N-arm")
        sp[n] = Dict(k => u[k] / a[k] for k in keys(a) if haskey(u, k))
        spa[n] = Dict(k => ctl[k] / a[k] for k in keys(a) if haskey(ctl, k))
        s0 = [ctl[k] / u[k] for k in keys(u) if haskey(ctl, k)]
        println("h ", n, ": never marked against master ", rng(s0), "; after one marked task against master ",
                rng(vals(spa[n])), "; after one marked task against never marked ", rng(vals(sp[n])))
    end
    println()
    show_line("h fib_fine after one marked task, against master, 8,1", spa)
    show_line("h fib_fine after one marked task, against the same build never marked, 8,1", sp)
    # the yardstick: v5 and v5-validate-off, never marked, against master
    u5, uo = w(commit("v5"), "N-none"), w(commit("v5-off"), "N-none")
    y5 = [ctl[k] / u5[k] for k in sort(collect(keys(u5))) if haskey(ctl, k)]
    yo = [ctl[k] / uo[k] for k in sort(collect(keys(uo))) if haskey(ctl, k)]
    ks = sort(collect(intersect(keys(u5), keys(uo))))
    q = [uo[k] / u5[k] for k in ks]     # v5's speed over v5-validate-off's
    global yard = abs(med(y5) - med(yo))
    println("yardstick fib_fine at 8,1, nothing marked (the same code in two binaries):")
    println("  v5             against master ", rng(y5), " (", length(y5), " rounds)")
    println("  v5-validate-off against master ", rng(yo), " (", length(yo), " rounds)")
    println("  v5/v5-validate-off per round: ", join(r3.(q), " "), "; median ", r3(med(q)))
    println("  the two readings differ by ", round(100 * yard; digits = 2), " points")
    println()
else
    println("row h and the yardstick: NOT RUN\n")
end

println("v5 against v4, line by line (median v5/v4; the yardstick's two readings differ by ",
        yard === nothing ? "-" : string(round(100 * yard; digits = 2), " points"), "):")
for (t, m, s) in lines
    big = yard !== nothing && abs(m - 1) > yard
    println("  ", rpad(t, 80), r3(m), " (", s, ")",
            big ? string("  DIFFERS FROM v4 BY MORE THAN THE YARDSTICK: ", round(100 * (m - 1); digits = 2), "%") : "",
            abs(m - 1) > 0.02 ? "  [moves by more than 2%]" : "")
end
println("This block decides nothing.")
