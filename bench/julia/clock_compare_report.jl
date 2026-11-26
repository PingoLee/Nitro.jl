# The comparison block of session 7 (#618): rows f, g and h on v2, v3 and v4 in one block, master (pin-control) as
# the reference, and the reading of v4 against v3 that decides whether v4 replaces v3 as the candidate.
#
#   julia clock_compare_report.jl <block directory>     (prints summary.txt; the last line is the decision input)
#
# The block is candidate_evidence.sh with the slots control = pin-control, candidate = v4, bypass = v3, timens = v2
# (builds.tsv names them), STEPS="pfib2 pfib81 spawnpath arm", 12 rounds, and the column overrides of its README.
# EVERY RATIO IS A SPEED against its reference: above 1 is faster.
#   f   pfib(25), 2 threads and 8,1: master's median time over the build's, per round;
#   g   H = 0, C = 50 and 500, :default clients at 8,0, clients and handlers marked: the build's req/s over master's;
#   h   fib_fine at 8,1 after one marked task, against the same build never marked: never-marked wall over armed.
# Per round, v4/v3 is v4's speed over v3's in that round (for h, v4's armed-over-never ratio over v3's).
# One reading a line, fixed before the block ran (the session prompt):
#   BETTER  median v4/v3 >= 1.015 and v4/v3 > 1 in at least 10 of 12 rounds;
#   WORSE   median v4/v3 <= 0.985 and v4/v3 < 1 in at least 10 of 12 rounds;
#   SAME    anything else.
D = ARGS[1]
med(v) = (s = sort(v); n = length(s); isodd(n) ? s[(n+1)÷2] : (s[n÷2] + s[n÷2+1]) / 2)
r3(x) = round(x; digits = 3)
rng(v) = string(r3(med(v)), " [", r3(minimum(v)), "–", r3(maximum(v)), "]")
function rd(p)
    l = readlines(p); h = split(l[1], '\t')
    [Dict(zip(h, split(x, '\t'))) for x in l[2:end] if !isempty(x) && split(x, '\t')[1] != h[1]]
end
builds = Dict(r["label"] => r["commit_short"] for r in rd(joinpath(D, "builds.tsv")))
const NAMES = ("v2" => "timens", "v3" => "bypass", "v4" => "candidate")
commit(name) = builds[Dict(NAMES)[name]]

function reading(s)
    n = length(s); m = med(s); up = count(>(1), s); dn = count(<(1), s)
    word = m >= 1.015 && up >= 10 ? "BETTER" : m <= 0.985 && dn >= 10 ? "WORSE" : "SAME"
    return word, string(word, ": median ", r3(m), ", above 1 in ", up, " of ", n, ", below 1 in ", dn)
end

lines = Pair{String,String}[]     # line => word
function show_line(title, speeds::Dict{String,Dict{Int,Float64}}, decides::Bool)
    println(title)
    for n in ("v2", "v3", "v4")
        s = speeds[n]
        println("  ", rpad(n, 4), rng([s[k] for k in sort(collect(keys(s)))]), " (", length(s), " rounds)")
    end
    ks = sort(collect(intersect(keys(speeds["v3"]), keys(speeds["v4"]))))
    q = [speeds["v4"][k] / speeds["v3"][k] for k in ks]
    println("  v4/v3 per round: ", join(r3.(q), " "))
    w, txt = reading(q)
    println("  ", txt, decides ? "" : "   (a WORSE here blocks; it cannot adopt)")
    push!(lines, title => w)
    println()
end

# ---- row f
for (st, lay) in (("pfib2", "2 threads"), ("pfib81", "8,1"))
    p = joinpath(D, "raw", st, "pfib.tsv")
    isfile(p) || (println("row f ", lay, ": NOT RUN"); continue)
    rows = filter(r -> parse(Int, r["round"]) >= 1 && !startswith(get(r, "min_s", ""), "FAILED"), rd(p))
    by(l) = Dict(parse(Int, r["round"]) => parse(Float64, r["median_s"]) for r in rows if r["label"] == l)
    c = by("ctl")
    for (mode, tag) in (("root", "r"), ("all", "a"))
        sp = Dict(n => (b = by(tag * n[2:2]); Dict(k => c[k] / b[k] for k in keys(b) if haskey(c, k))) for n in ("v2", "v3", "v4"))
        show_line("f pfib(25) $(mode == "root" ? "root marked" : "every spawn marked"), $lay", sp, mode == "root")
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
        sp = Dict(n => (b = rps(commit(n), "N"); Dict(k => b[k] / m[k] for k in keys(b) if haskey(m, k))) for n in ("v2", "v3", "v4"))
        show_line("g everything marked on the spawn path, C = $c, 8,0", sp, false)
    end
else
    println("row g: NOT RUN\n")
end

# ---- row h
p = joinpath(D, "raw", "arm", "fibabba-nested.tsv")
if isfile(p)
    rows = filter(r -> parse(Int, r["round"]) >= 1, rd(p))
    w(cm, v) = Dict(parse(Int, r["round"]) => parse(Float64, r["wall_median_s"]) for r in rows
                    if startswith(r["commit"], cm) && r["variant"] == v)
    ctl = w(builds["control"], "A")
    sp = Dict{String,Dict{Int,Float64}}()
    for n in ("v2", "v3", "v4")
        u, a = w(commit(n), "N-none"), w(commit(n), "N-arm")
        sp[n] = Dict(k => u[k] / a[k] for k in keys(a) if haskey(u, k))
        s0 = [ctl[k] / u[k] for k in keys(u) if haskey(ctl, k)]
        s1 = [ctl[k] / a[k] for k in keys(a) if haskey(ctl, k)]
        println("h ", n, ": never marked against master ", rng(s0), "; after one marked task against master ", rng(s1))
    end
    show_line("h fib_fine after one marked task, against the same build never marked, 8,1", sp, true)
else
    println("row h: NOT RUN\n")
end

println("READINGS: ", join((string(k, " => ", v) for (k, v) in lines), "; "))
better = any(((k, v),) -> v == "BETTER" && (occursin("root marked", k) || startswith(k, "h ")), lines)
worse = any(((k, v),) -> v == "WORSE", lines)
println("BLOCK: ", better && !worse ? "ADOPT-ELIGIBLE (a deciding line BETTER, none WORSE)" :
                   worse ? "KEEP v3 (a line reads WORSE)" : "KEEP v3 (no deciding line reads BETTER)",
        " — the decision also needs the equivalence and every check")
