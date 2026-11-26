# The second layout draw of session 9 (#618): the two lines session 7's block could not read, on v3 and v4 and on
# a second binary of each (their validation builds with the switch off, which compile the compared functions to
# v3's and v4's code: native_code_gate.sh says which), with master (pin-control) as the reference.
#
#   julia layout_draw_report.jl <block directory>     (prints summary.txt)
#
# The block is candidate_evidence.sh with the slots control = pin-control, control2 = v3, candidate = v4,
# bypass = v3-validate-off, timens = v4-validate-off (builds.tsv names them), STEPS="prep pfib81 arm", 10 rounds,
# and the column overrides of its README. EVERY RATIO IS A SPEED against master: above 1 is faster.
#   pfib(25) with every spawn marked at 8,1: master's unmarked median time over the build's, per round;
#   fib_fine at 8,1 with nothing marked: master's wall over the build's, per round.
# Per round, v4/v3 is v4's speed over v3's, and v4off/v3off the same for the second binaries.
# One reading a line, fixed before the block ran (the session prompt):
#   THE SAME SIGN IN BOTH PAIRS   both medians (v4/v3 and v4off/v3off) on the same side of 1 by 1% or more;
#   NOT REPEATED                  anything else.
# It decides nothing (v4 is adopted either way): it says what may be claimed about the two lines.
D = ARGS[1]
med(v) = (s = sort(v); n = length(s); n == 0 ? NaN : isodd(n) ? s[(n+1)÷2] : (s[n÷2] + s[n÷2+1]) / 2)
r3(x) = round(x; digits = 3)
rng(v) = isempty(v) ? "–" : string(r3(med(v)), " [", r3(minimum(v)), "–", r3(maximum(v)), "] (", length(v), ")")
function rd(p)
    l = readlines(p); h = split(l[1], '\t')
    [Dict(zip(h, split(x, '\t'))) for x in l[2:end] if !isempty(x) && split(x, '\t')[1] != h[1]]
end
builds = Dict(r["label"] => r["commit_short"] for r in rd(joinpath(D, "builds.tsv")))
const SLOTS = ["v3" => "control2", "v4" => "candidate", "v3off" => "bypass", "v4off" => "timens"]
println("Builds: master = pin-control ", builds["control"], "; ",
        join((string(n, " = ", builds[s]) for (n, s) in SLOTS), "; "), "\n")

readings = String[]
function show_line(title, sp::Dict{String,Dict{Int,Float64}})
    println(title)
    for (n, _) in SLOTS
        s = sp[n]; println("  ", rpad(n, 6), "against master ", rng([s[k] for k in sort(collect(keys(s)))]))
    end
    q(a, b) = (ks = sort(collect(intersect(keys(sp[a]), keys(sp[b])))); [sp[a][k] / sp[b][k] for k in ks])
    p1, p2 = q("v4", "v3"), q("v4off", "v3off")
    println("  v4/v3 per round:       ", join(r3.(p1), " "), "   median ", r3(med(p1)), ", above 1 in ", count(>(1), p1), " of ", length(p1))
    println("  v4off/v3off per round: ", join(r3.(p2), " "), "   median ", r3(med(p2)), ", above 1 in ", count(>(1), p2), " of ", length(p2))
    m1, m2 = med(p1), med(p2)
    same = (m1 >= 1.01 && m2 >= 1.01) || (m1 <= 0.99 && m2 <= 0.99)
    w = same ? "THE SAME SIGN IN BOTH PAIRS" : "NOT REPEATED"
    println("  ", w, ": v4/v3 ", r3(m1), ", v4off/v3off ", r3(m2), "\n")
    push!(readings, string(title, " => ", w))
end

# ---- pfib(25), every spawn marked, 8,1
p = joinpath(D, "raw", "pfib81", "pfib.tsv")
if isfile(p)
    rows = filter(r -> parse(Int, r["round"]) >= 1 && !startswith(get(r, "min_s", ""), "FAILED"), rd(p))
    by(l) = Dict(parse(Int, r["round"]) => parse(Float64, r["median_s"]) for r in rows if r["label"] == l)
    c = by("ctl")
    tag = Dict("v3" => "a3", "v4" => "a4", "v3off" => "a3o", "v4off" => "a4o")
    sp = Dict(n => (b = by(tag[n]); Dict(k => c[k] / b[k] for k in keys(b) if haskey(c, k))) for (n, _) in SLOTS)
    show_line("pfib(25), every spawn marked, 8,1", sp)
else
    println("pfib(25), every spawn marked, 8,1: NOT RUN\n")
end

# ---- fib_fine, nothing marked, 8,1
p = joinpath(D, "raw", "arm", "fibabba-nested.tsv")
if isfile(p)
    rows = filter(r -> parse(Int, r["round"]) >= 1, rd(p))
    w(cm, v) = Dict(parse(Int, r["round"]) => parse(Float64, r["wall_median_s"]) for r in rows
                    if first(split(r["commit"], '/')) == cm && r["variant"] == v)
    ctl = w(builds["control"], "A")
    sp = Dict(n => (u = w(builds[s], "N-none"); Dict(k => ctl[k] / u[k] for k in keys(u) if haskey(ctl, k))) for (n, s) in SLOTS)
    show_line("fib_fine, nothing marked, 8,1", sp)
else
    println("fib_fine, nothing marked, 8,1: NOT RUN\n")
end

println("READINGS: ", join(readings, "; "))
