# Writes results.md for candidate_evidence.sh: one section a claim, in a form a pull request can take
# as it is. Standard library only. Usage: julia candidate_evidence_report.jl <OUT> > <OUT>/results.md
#
# Every ratio is a speed against its reference (above 1 is faster). Each criterion is the one fixed
# before the run (bench/julia/README.md, "The PR candidate"); a row outside it reads FAIL.
using Printf

const OUT = ARGS[1]
const RAW = joinpath(OUT, "raw")
const CMD = "bench/julia/candidate_evidence.sh <master> <master, second build> <this PR>"

# ---------------------------------------------------------------- reading
function readtsv(path)
    isfile(path) || return Dict{String,String}[]
    lines = filter(!isempty, readlines(path))
    isempty(lines) && return Dict{String,String}[]
    hdr = split(lines[1], '\t')
    rows = Dict{String,String}[]
    for l in lines[2:end]
        f = split(l, '\t')
        f[1] == hdr[1] && continue                        # a repeated header
        push!(rows, Dict(String(hdr[i]) => String(get(f, i, "")) for i in eachindex(hdr)))
    end
    return rows
end
readtsvs(dir, prefix) = isdir(dir) ? reduce(vcat, [readtsv(joinpath(dir, f)) for f in sort(readdir(dir))
                                                   if startswith(f, prefix) && endswith(f, ".tsv")]; init = Dict{String,String}[]) :
                                     Dict{String,String}[]
num(s) = something(tryparse(Float64, s), NaN)
const BUILDS = Dict(r["label"] => r["commit_short"] for r in readtsv(joinpath(OUT, "builds.tsv")))
commit_of(r) = first(split(r["commit"], '/'))
is(r, label) = commit_of(r) == get(BUILDS, label, "?")
rnd(r) = parse(Int, r["round"])

# ---------------------------------------------------------------- statistics and formatting
function med(v)
    s = sort(filter(!isnan, v)); n = length(s)
    n == 0 && return NaN
    return isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2
end
fmtv(x; d = 3) = isnan(x) ? "–" : abs(x) >= 1000 ? @sprintf("%.0f", x) : abs(x) >= 100 ? @sprintf("%.1f", x) : @sprintf("%.*f", d, x)
function cellstr(v; d = 3)
    w = filter(!isnan, v)
    isempty(w) && return "–"
    return string(fmtv(med(w); d), " [", fmtv(minimum(w); d), "–", fmtv(maximum(w); d), "] (", length(w), ")")
end
pf(b) = b ? "**PASS**" : "**FAIL**"
# A value that is NaN in some rounds (the fork-join did not finish inside the cell's 8 s): say how often.
function unfinished(v)
    k = count(isnan, v)
    k == 0 && return cellstr(v)
    k == length(v) && return "did not finish in any of $(length(v)) rounds"
    return cellstr(v) * "; did not finish in $k of $(length(v)) rounds"
end
section(title) = println("\n## ", title, "\n")
claim(s) = println("**Claim.** ", s, "\n")
reproduce(s) = println("Reproduce: `", CMD, "` (step ", s, ")\n")
function table(hdr, rows)
    println("| ", join(hdr, " | "), " |")
    println("|", join(fill("---", length(hdr)), "|"), "|")
    for r in rows
        println("| ", join(r, " | "), " |")
    end
    println()
end
# Per-round values of a column, keyed by round.
byround(rows, f) = Dict(rnd(r) => f(r) for r in rows if rnd(r) >= 1)
function paired(a::Dict, b::Dict, f)   # f(a_round, b_round) for the rounds both have
    return [f(a[k], b[k]) for k in sort(collect(intersect(keys(a), keys(b))))]
end

println("# Measurements of the fair class: master against this PR\n")
println("Every ratio is a **speed** against its reference: above 1 is faster. Cells show median [min–max] (rounds).")
println("Each column is a fresh process every round, the columns rotated, after one throwaway slot. ",
        "\"master\" is the base commit, \"master, second build\" the same commit built again (the floor), ",
        "\"this PR\" the base with the patch. Machine and builds: `environment.md`; raw data: `raw/`.")

# ---------------------------------------------------------------- a, b
starved = filter(r -> r["mode"] == "spawn" && rnd(r) >= 1, readtsv(joinpath(RAW, "starved", "fairrounds-spawn.tsv")))
sa = filter(r -> is(r, "control") && r["variant"] == "A", starved)
sb = filter(r -> is(r, "candidate") && r["variant"] == "N", starved)
section("a, b. Closed-loop clients starved by newer work, and the mark")
claim("500 clients on `:interactive` each spawn a 2 ms task on `:default` (8 threads) and wait for it, for 8 s. " *
      "On master the oldest clients starve (a); with each client's task marked (`fair=true`) every client is served and the tail is gone (b). " *
      "A fair wait is 500 × 2 ms / 8 = 125 ms.")
reproduce("starved")
pa = [num(r["p99_ms"]) for r in sa]; pb = [num(r["p99_ms"]) for r in sb]
table(["", "master", "this PR, marked"],
      [["p99 latency (ms)", cellstr(pa), cellstr(pb)],
       ["least-served client (tasks in 8 s)", cellstr([num(r["count_min"]) for r in sa]; d = 0), cellstr([num(r["count_min"]) for r in sb]; d = 0)],
       ["tasks/s", cellstr([num(r["rps"]) for r in sa]; d = 0), cellstr([num(r["rps"]) for r in sb]; d = 0)]])
oka = !isempty(pa) && all(>(1000), pa)
okb = !isempty(pb) && all(<=(200), pb) && all(r -> num(r["count_min"]) >= 1, sb)
println("Criterion a: master's p99 above 1,000 ms in every round: ", pf(oka), ".  ",
        "Criterion b: this PR's p99 at most 200 ms and every client served, in every round: ", pf(okb), ".")

# ---------------------------------------------------------------- c
section("c. Beside unmarked compute, both sides advance")
claim("The starved cell while an unmarked fork-join (`fib_fine`, pfib(42) cut at 12) runs on `:default`. " *
      "With the clients' tasks marked, both advance: the clients' p99 stays bounded and the compute keeps a share of the machine. " *
      "Compute speed = its wall time alone / its wall time during the cell.")
reproduce("mixed")
okc = true; anyc = false
for (shape, file) in (("plain", "mixed.tsv"), ("inner", "mixedinner.tsv"))
    rows = filter(r -> rnd(r) >= 1, readtsv(joinpath(RAW, "mixed", file)))
    c0 = filter(r -> is(r, "control") && r["variant"] == "A", rows)
    c1 = filter(r -> is(r, "candidate") && r["variant"] == "N", rows)
    sp(r) = num(r["fib_alone_median_s"]) / num(r["fib_median_s"])
    println("Shape **", shape, "**:\n")
    table(["", "master", "this PR, marked"],
          [["clients' p99 latency (ms)", cellstr([num(r["p99_ms"]) for r in c0]), cellstr([num(r["p99_ms"]) for r in c1])],
           ["least-served client", cellstr([num(r["count_min"]) for r in c0]; d = 0), cellstr([num(r["count_min"]) for r in c1]; d = 0)],
           ["compute speed (alone = 1)", unfinished(sp.(c0)), unfinished(sp.(c1))]])
    global anyc |= !isempty(c1)
    global okc &= !isempty(c1) && all(r -> num(r["p99_ms"]) <= 600 && sp(r) >= 0.40, c1)
end
println("Criterion c: this PR's p99 at most 600 ms and the compute at 0.40 or better, in every round of both shapes: ", pf(okc && anyc), ".")

# ---------------------------------------------------------------- d
section("d. Behind a real HTTP server")
claim("An HTTP.jl server whose handler does 2 ms of compute (`/aggregate`), 500 connections from a closed-loop load generator on other CPUs, 8 s a round, a fresh server each round. " *
      "With the accepted connections' tasks marked, the tail stays bounded at the same throughput.")
reproduce("cell81, cell80")
okd = true; anyd = false
for (layout, dir) in (("8,1", "cell81"), ("8,0", "cell80"))
    rows = filter(r -> parse(Int, r["round"]) >= 1, readtsvs(joinpath(RAW, dir), "fairness-"))
    m0 = filter(r -> endswith(r["mode"], "%control"), rows)
    m1 = filter(r -> endswith(r["mode"], "%candidate"), rows)
    isempty(m1) && continue
    global anyd = true
    s = paired(byround(m0, r -> num(r["rps"])), byround(m1, r -> num(r["rps"])), (a, b) -> b / a)
    println("At **", layout, "**:\n")
    table(["", "master", "this PR, marked"],
          [["p99 latency (ms)", cellstr([num(r["p99_ms"]) for r in m0]), cellstr([num(r["p99_ms"]) for r in m1])],
           ["requests/s", cellstr([num(r["rps"]) for r in m0]; d = 0), cellstr([num(r["rps"]) for r in m1]; d = 0)],
           ["throughput speed (master = 1)", "1", cellstr(s)]])
    global okd &= all(r -> num(r["p99_ms"]) <= 150, m1) && !isempty(s) && all(>=(0.98), s)
end
println("Criterion d: this PR's p99 at most 150 ms and throughput at 0.98 or better, in every round at each layout measured: ", pf(okd && anyd), ".")

# ---------------------------------------------------------------- e
section("e. Code that marks nothing pays nothing measurable")
claim("With nothing marked, this PR's speed against master lies within the distance between two builds of master itself. " *
      "LAYOUT means it does: the difference cannot be told from a second build of the same source.")
reproduce("floorfib, floorh0")
function floor_row(name, rows0, rows2, rows1, val, faster_is_smaller)
    sp(a, b) = faster_is_smaller ? a / b : b / a
    s2 = paired(byround(rows0, val), byround(rows2, val), sp)
    s1 = paired(byround(rows0, val), byround(rows1, val), sp)
    d = max(abs(med(s2) - 1), 0.005)
    lay = !isempty(s1) && abs(med(s1) - 1) <= d
    verdict = isempty(s1) ? "–" : lay ? "LAYOUT (floor ±$(@sprintf("%.2f", 100d))%)" :
              "outside the floor: $(@sprintf("%+.2f", 100 * (med(s1) - 1)))% against ±$(@sprintf("%.2f", 100d))%"
    return [name, cellstr(s2), cellstr(s1)], lay, verdict
end
fib = readtsv(joinpath(RAW, "floorfib", "fibabba-nested.tsv"))
h0 = filter(r -> r["mode"] == "spawn", readtsv(joinpath(RAW, "floorh0", "costrounds-spawn.tsv")))
erows = Any[]; verdicts = String[]; oke = true
fr, fl0, fv = floor_row("fib_fine, 8,1", filter(r -> is(r, "control"), fib), filter(r -> is(r, "control2"), fib),
                    filter(r -> is(r, "candidate"), fib), r -> num(r["wall_median_s"]), true)
push!(erows, fr); push!(verdicts, "fib_fine: " * fv); oke &= fl0
for c in ("50", "500")
    hc = filter(r -> r["c"] == c, h0)
    local er, el, ev
    er, el, ev = floor_row("spawn path, H = 0, C = $c, 8,0", filter(r -> is(r, "control"), hc), filter(r -> is(r, "control2"), hc),
                        filter(r -> is(r, "candidate"), hc), r -> num(r["rps"]), false)
    push!(erows, er); push!(verdicts, "C = $c: " * ev); global oke &= el
end
table(["cell", "master, second build", "this PR"], erows)
println("Criterion e: ", join(verdicts, "; "), ". Overall: ", pf(oke), ".")

# ---------------------------------------------------------------- f
section("f. The benchmark of JuliaLang/julia#35589")
claim("`pfib(25)` as posted in that PR's thread, from one root spawned on `:default`: unmarked, with the root marked, and with every spawn marked. " *
      "Speed against master's unmarked run.")
reproduce("pfib2, pfib81")
frows = Dict{String,Vector{String}}(); okf = true; fnotes = String[]
labels = [("cand", "this PR, unmarked"), ("ctl2", "master, second build"), ("root", "this PR, root marked"), ("all", "this PR, every spawn marked")]
for (k, name) in labels; frows[k] = [name]; end
fl = String[]
for (layout, dir) in (("--threads=2", "pfib2"), ("8,1", "pfib81"))
    rows = filter(r -> !startswith(get(r, "min_s", ""), "FAILED") && rnd(r) >= 1, readtsv(joinpath(RAW, dir, "pfib.tsv")))
    isempty(rows) && continue
    push!(fl, layout)
    b(k) = byround(filter(r -> r["label"] == k, rows), r -> num(r["median_s"]))
    base = b("ctl")
    sp = Dict(k => paired(base, b(k), (a, x) -> a / x) for k in ("ctl2", "cand", "root", "all"))
    for (k, _) in labels; push!(frows[k], cellstr(sp[k])); end
    d = max(abs(med(sp["ctl2"]) - 1), 0.005)
    lay = !isempty(sp["cand"]) && abs(med(sp["cand"]) - 1) <= d
    rootok = !isempty(sp["root"]) && all(>=(0.90), sp["root"])
    push!(fnotes, "$layout: unmarked " * (lay ? "LAYOUT" : "outside the floor ($(@sprintf("%+.2f", 100 * (med(sp["cand"]) - 1)))% against ±$(@sprintf("%.2f", 100d))%)") *
                  ", root marked " * pf(rootok))
    global okf &= lay && rootok
end
table(vcat(["speed against master, unmarked"], fl), [frows[k] for (k, _) in labels])
println("Criterion f: unmarked within the floor as in e, and the root marked at 0.90 or better in every round; every spawn marked is reported with no bar. ",
        join(fnotes, "; "), ". Overall: ", pf(okf && !isempty(fl)), ".")

# ---------------------------------------------------------------- g
section("g. The cost with everything marked")
claim("The spawn path itself (closed-loop clients on `:default` spawning tasks that do no work, 8,0), with the clients and every task they spawn marked. " *
      "Speed against master.")
reproduce("spawnpath")
sprows = filter(r -> r["mode"] == "spawn", readtsv(joinpath(RAW, "spawnpath", "costrounds-spawn.tsv")))
grows = Any[]; okg = true; anyg = false
for c in ("50", "500")
    hc = filter(r -> r["c"] == c, sprows)
    a = byround(filter(r -> is(r, "control"), hc), r -> num(r["rps"]))
    b = byround(filter(r -> is(r, "candidate") && r["variant"] == "N", hc), r -> num(r["rps"]))
    s = paired(a, b, (x, y) -> y / x)
    isempty(s) && continue
    global anyg = true
    push!(grows, ["C = $c", cellstr(collect(values(a)); d = 0), cellstr(s)])
    global okg &= all(>=(0.80), s)
end
table(["cell", "master, requests/s", "this PR marked, speed"], grows)
println("Criterion g: speed 0.80 or better in every round: ", pf(okg && anyg), ".")

# ---------------------------------------------------------------- h
section("h. What unmarked code pays once a program has marked something")
claim("`fib_fine` at 8,1 with nothing marked, in a process that first ran one task with `fair=true` (the scheduler's pool flag is then set for good), " *
      "against the same build with nothing ever marked, and against master.")
reproduce("arm")
arm = readtsv(joinpath(RAW, "arm", "fibabba-nested.tsv"))
va = byround(filter(r -> is(r, "control"), arm), r -> num(r["wall_median_s"]))
vu = byround(filter(r -> is(r, "candidate") && r["variant"] == "N-none", arm), r -> num(r["wall_median_s"]))
vr = byround(filter(r -> is(r, "candidate") && r["variant"] == "N-arm", arm), r -> num(r["wall_median_s"]))
s_ru = paired(vu, vr, (u, x) -> u / x); s_ra = paired(va, vr, (u, x) -> u / x); s_ua = paired(va, vu, (u, x) -> u / x)
table(["", "against this PR, never marked", "against master"],
      [["this PR, never marked", "1", cellstr(s_ua)], ["this PR, after one marked task", cellstr(s_ru), cellstr(s_ra)]])
okh = !isempty(s_ru) && all(>=(0.965), s_ru)
println("Criterion h: after one marked task, speed 0.965 or better against the same build never marked, in every round: ", pf(okh), ".")

# ---------------------------------------------------------------- i
section("i. Julia's tests")
claim("The test sets the change touches, on master and on this PR, nothing marked: the same counts. The new tests run inside `threads_exec.jl`, " *
      "which `threads` runs in a subprocess at five thread layouts; their own assertions are not in these totals.")
reproduce("tests")
function overall(path)
    isfile(path) || return nothing
    ls = readlines(path)
    i = findlast(l -> occursin(r"^\s*Overall\s*\|", l), ls)
    i === nothing && return nothing
    h = findlast(l -> startswith(l, "Test Summary:"), ls[1:i])
    names = split(strip(split(ls[h], '|')[2]))
    vals = split(strip(split(ls[i], '|')[2]))
    d = Dict(String(names[k]) => vals[k] for k in eachindex(names) if k <= length(vals))
    st = any(l -> occursin("SUCCESS", l), ls[i:end]) ? "SUCCESS" : "FAILURE"
    return d, st
end
irows = Any[]
for (label, name) in (("control", "master"), ("candidate", "this PR"))
    o = overall(joinpath(RAW, "tests", "$label.log"))
    o === nothing && (push!(irows, [name, "–", "–"]); continue)
    d, st = o
    push!(irows, [name, string(get(d, "Pass", "0"), " passed, ", get(d, "Broken", "0"), " broken, ",
                              get(d, "Fail", "0"), " failed, ", get(d, "Error", "0"), " errors"), st])
end
table(["build", "core, threads, channels, channel_threadpool, threadpool_use, threadpool_latency, cancellation", "result"], irows)

# ---------------------------------------------------------------- the standalone reproducers
section("Standalone reproducers")
println("Single files in `bench/julia/candidate/`, standard library only, each run as ",
        "`julia --threads=<layout> <file>.jl [args]` on both builds, a fresh process a round, pinned as the cells. ",
        "A marked mode on master prints that the keyword is not there. Their numbers are their own: the harness's cells above add ",
        "per-request bookkeeping, so compare each reproducer's two columns with each other, and its ratio with the row's.\n")
reproduce("repro, repro_gh")
kv(line) = Dict(String(m[1]) => String(m[2]) for m in eachmatch(r"(\w+)=(\S+)", line))
reprows = vcat(readtsv(joinpath(RAW, "repro", "repro.tsv")), readtsv(joinpath(RAW, "repro_gh", "repro.tsv")))
const REPRO_ITEMS = [
    ("a", "starved.jl", "plain", "p99_ms", "`starved.jl` p99 (ms), stock order"),
    ("b", "starved.jl", "fair", "p99_ms", "`starved.jl fair` p99 (ms), marked"),
    ("b", "starved.jl", "fair", "client_min", "`starved.jl fair` least-served client"),
    ("e", "fib_fine.jl", "", "median_s", "`fib_fine.jl` median wall (s)"),
    ("f", "pfib.jl", "none", "median_s", "`pfib.jl none` at --threads=2, median (s)"),
    ("f", "pfib.jl", "root", "median_s", "`pfib.jl root`, median (s)"),
    ("f", "pfib.jl", "all", "median_s", "`pfib.jl all`, median (s)"),
    ("g", "spawn_path.jl", "plain 50", "rps", "`spawn_path.jl plain 50` requests/s"),
    ("g", "spawn_path.jl", "fair 50", "rps", "`spawn_path.jl fair 50` requests/s"),
    ("g", "spawn_path.jl", "plain 500", "rps", "`spawn_path.jl plain 500` requests/s"),
    ("g", "spawn_path.jl", "fair 500", "rps", "`spawn_path.jl fair 500` requests/s"),
    ("h", "armed.jl", "unarmed", "median_s", "`armed.jl` median wall (s), never marked"),
    ("h", "armed.jl", "armed", "median_s", "`armed.jl armed` median wall (s), one task marked first"),
]
rrows = Any[]
for (row, file, args, key, name) in REPRO_ITEMS
    vals(b) = [num(get(kv(r["line"]), key, "NaN")) for r in reprows if r["file"] == file && r["args"] == args && r["build"] == b]
    v0, v1 = vals("control"), vals("candidate")
    isempty(v0) && isempty(v1) && continue
    d = key in ("rps", "client_min", "p99_ms") ? 0 : 4
    push!(rrows, ["$name ($row)", isempty(filter(!isnan, v0)) ? "not supported" : cellstr(v0; d), cellstr(v1; d)])
end
table(["reproducer (row)", "master", "this PR"], rrows)

# ---------------------------------------------------------------- the description's reproducer
section("The description's reproducer")
println("`bench/julia/candidate/mwe.jl` at `--threads=8,1`: once on master as it is, once on this PR with the client's spawn marked (`fair=true`).\n")
for (name, f) in (("master", "mwe-control.txt"), ("this PR, `fair=true`", "mwe-candidate-fair.txt"))
    p = joinpath(RAW, "mwe", f)
    isfile(p) || continue
    println(name, ":\n\n```\n", rstrip(read(p, String)), "\n```\n")
end
