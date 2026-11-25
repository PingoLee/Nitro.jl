# The diagnostic of session 6 (#618): rows f and h on v2, v2-timens and v3 in one block.
# Usage: julia clock_diag_report.jl <evidence/candidate-v3-clock-diag-20261125>   (prints summary.txt)
D = ARGS[1]
med(v) = (s = sort(v); n = length(s); isodd(n) ? s[(n+1)÷2] : (s[n÷2] + s[n÷2+1]) / 2)
rd(p) = (l = readlines(p); h = split(l[1], '\t'); [Dict(zip(h, split(x, '\t'))) for x in l[2:end] if !isempty(x) && split(x, '\t')[1] != h[1]])
for st in ("pfib2", "pfib81")
    rows = filter(r -> parse(Int, r["round"]) >= 1, rd(joinpath(D, "raw", st, "pfib.tsv")))
    by(l) = Dict(parse(Int, r["round"]) => parse(Float64, r["median_s"]) for r in rows if r["label"] == l)
    c = by("ctl")
    println(st)
    for (l, n) in (("r2", "v2 root"), ("rt", "v2-timens root"), ("r3", "v3 root"), ("a2", "v2 all"), ("at", "v2-timens all"), ("a3", "v3 all"))
        b = by(l); s = [c[k] / b[k] for k in sort(collect(keys(b))) if haskey(c, k)]
        println("  ", rpad(n, 16), round(med(s); digits = 3), " [", round(minimum(s); digits = 3), "–", round(maximum(s); digits = 3), "] (", length(s), ")")
    end
end
rows = filter(r -> parse(Int, r["round"]) >= 1, rd(joinpath(D, "raw", "arm", "fibabba-nested.tsv")))
w(commit, v) = Dict(parse(Int, r["round"]) => parse(Float64, r["wall_median_s"]) for r in rows if startswith(r["commit"], commit) && r["variant"] == v)
ctl = w("419aba7972", "A")
println("arm (after one marked task / never marked, same build; and never marked / master)")
for (c, n) in (("2caefffc63", "v2"), ("1313112ba5", "v2-timens"), ("2db177599e", "v3"))
    u, a = w(c, "N-none"), w(c, "N-arm")
    s = [u[k] / a[k] for k in sort(collect(keys(a))) if haskey(u, k)]
    s0 = [ctl[k] / u[k] for k in sort(collect(keys(u))) if haskey(ctl, k)]
    println("  ", rpad(n, 10), round(med(s); digits = 3), " [", round(minimum(s); digits = 3), "–", round(maximum(s); digits = 3), "] (", length(s), ");  never marked vs master ", round(med(s0); digits = 3))
end
