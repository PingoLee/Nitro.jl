# The native mark's pilot (#618, agent-config #82 Idea 10): the tables of a rounds_fifo.sh
# PROFILE=native pilot directory and its gate. A series is (build, variant): the builds are told
# apart by the commit column (`<commit>/local` the control, `<commit>/native` the mark build, the
# bare commit the official binary).
#
#   julia bench/julia/native_pilot_report.jl <dir>
#
# The gate (the port prompt's): N within 10% of the official binary's M-gc-r2 in the starved and the
# mixed cell, and inside the classes run's limits (starved p99 < 0.2 s; mixed p99 < 0.6 s, no client
# starved, fib_fine < 2.5x); N-none within 3% of the control's A in fib_fine alone and at H = 0. One
# round cannot show less than that.
using DelimitedFiles

function rows(path)
    isfile(path) || error("no $path")
    m, h = readdlm(path, '\t', String; header = true)
    h = vec(h)
    return [Dict(h[j] => m[i, j] for j in eachindex(h)) for i in 1:size(m, 1) if m[i, 1] != h[1]]
end
build(r) = endswith(r["commit"], "/native") ? "mark" : endswith(r["commit"], "/local") ? "control" :
           occursin("/native-validate", r["commit"]) ? "mark-validate" : "official"
num(r, k) = parse(Float64, r[k])
key(r) = (build(r), r["variant"])
const ORDER = [("control", "A"), ("mark", "N-none"), ("mark", "N"), ("official", "A"), ("official", "M-gc-r2")]
label((b, v)) = "$v on $b"

dir = ARGS[1]
sp = rows(joinpath(dir, "pilot-spawn.tsv"))
mx = rows(joinpath(dir, "pilot-mixed.tsv"))
ns = rows(joinpath(dir, "pilot-nested.tsv"))
pick(rs, k, f) = (x = filter(r -> key(r) == k && f(r), rs); isempty(x) ? nothing : only(x))

starved = Dict(k => pick(sp, k, r -> r["h_ms"] in ("2.0", "2") && r["mode"] == "spawn") for k in ORDER)
h0 = Dict(k => pick(sp, k, r -> r["h_ms"] in ("0.0", "0") && r["mode"] == "spawn") for k in ORDER)
mixed = Dict(k => pick(mx, k, r -> true) for k in ORDER)
fib = Dict(k => pick(ns, k, r -> r["bench"] == "fib_fine") for k in ORDER)
fmt(x; d = 1) = x === nothing ? "-" : string(round(x; digits = d))

println("| series | starved p99 ms | starved req/s | slowest client | H=0 req/s | mixed p99 ms | mixed slowest client | mixed fib_fine x | fib_fine alone s |")
println("|---|--:|--:|--:|--:|--:|--:|--:|--:|")
for k in ORDER
    s, z, m, f = starved[k], h0[k], mixed[k], fib[k]
    println("| ", label(k), " | ", s === nothing ? "-" : fmt(num(s, "p99_ms")), " | ", s === nothing ? "-" : fmt(num(s, "rps"); d = 0),
            " | ", s === nothing ? "-" : s["count_min"], " | ", z === nothing ? "-" : fmt(num(z, "rps"); d = 0),
            " | ", m === nothing ? "-" : fmt(num(m, "p99_ms")), " | ", m === nothing ? "-" : m["count_min"],
            " | ", m === nothing ? "-" : fmt(num(m, "fib_median_s") / num(m, "fib_alone_median_s"); d = 2),
            " | ", f === nothing ? "-" : fmt(num(f, "wall_median_s"); d = 3), " |")
end

gate = String[]
check(ok, msg) = (println(ok ? "PASS  " : "FAIL  ", msg); ok || push!(gate, msg))
N, P, C, Z = ("mark", "N"), ("official", "M-gc-r2"), ("control", "A"), ("mark", "N-none")
r(a, b) = a / b
sN, sP = num(starved[N], "p99_ms"), num(starved[P], "p99_ms")
check(abs(r(sN, sP) - 1) <= 0.10, "starved p99: N $(fmt(sN)) ms against the patch's $(fmt(sP)) ms (ratio $(fmt(r(sN, sP); d = 3)), within 10%")
check(sN < 200, "starved p99 under 0.2 s: $(fmt(sN)) ms")
mN, mP = num(mixed[N], "p99_ms"), num(mixed[P], "p99_ms")
check(abs(r(mN, mP) - 1) <= 0.10, "mixed p99: N $(fmt(mN)) ms against the patch's $(fmt(mP)) ms (ratio $(fmt(r(mN, mP); d = 3)), within 10%")
check(mN < 600, "mixed p99 under 0.6 s: $(fmt(mN)) ms")
check(parse(Int, mixed[N]["count_min"]) > 0, "mixed: no client starved (slowest client $(mixed[N]["count_min"]) requests)")
fx = num(mixed[N], "fib_median_s") / num(mixed[N], "fib_alone_median_s")
check(fx < 2.5, "mixed: fib_fine under 2.5x: $(fmt(fx; d = 2))x")
fz, fc = num(fib[Z], "wall_median_s"), num(fib[C], "wall_median_s")
check(abs(r(fz, fc) - 1) <= 0.03, "fib_fine alone: N-none $(fmt(fz; d = 3)) s against the control's $(fmt(fc; d = 3)) s (ratio $(fmt(r(fz, fc); d = 3))), within 3%")
hz, hc = num(h0[Z], "rps"), num(h0[C], "rps")
check(abs(r(hz, hc) - 1) <= 0.03, "H = 0: N-none $(fmt(hz; d = 0)) req/s against the control's $(fmt(hc; d = 0)) (ratio $(fmt(r(hz, hc); d = 3))), within 3%")
println(isempty(gate) ? "GATE PASSED" : "GATE FAILED: " * join(gate, "; "))
