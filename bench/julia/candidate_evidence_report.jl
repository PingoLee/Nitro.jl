# Writes results.md for candidate_evidence.sh: one section a claim, in a form a pull request can take
# as it is. Standard library only. Usage: julia candidate_evidence_report.jl <OUT> > <OUT>/results.md
#
# Every ratio is a speed against its reference (above 1 is faster). Each criterion is the one fixed
# before the run (bench/julia/README.md); a row outside it reads FAIL. Where a row has a standalone
# reproducer (bench/julia/candidate/), its number stands beside the harness's.
using Printf

const OUT = ARGS[1]
const RAW = joinpath(OUT, "raw")
const CMD = "bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]"

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
const HAS_BYPASS = haskey(BUILDS, "bypass")
const HAS_TIMENS = haskey(BUILDS, "timens")
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
pct(x) = @sprintf("%+.2f%%", 100 * (x - 1))
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
    isempty(rows) && return
    println("| ", join(hdr, " | "), " |")
    println("|", join(fill("---", length(hdr)), "|"), "|")
    for r in rows
        println("| ", join(r, " | "), " |")
    end
    println()
end
byround(rows, f) = Dict(rnd(r) => f(r) for r in rows if rnd(r) >= 1)
paired(a::Dict, b::Dict, f) = [f(a[k], b[k]) for k in sort(collect(intersect(keys(a), keys(b))))]

# ---------------------------------------------------------------- the standalone reproducers
kv(line) = Dict(String(m[1]) => String(m[2]) for m in eachmatch(r"(\w+)=(\S+)", line))
const REPRO = vcat(readtsv(joinpath(RAW, "repro", "repro.tsv")), readtsv(joinpath(RAW, "repro_gh", "repro.tsv")))
rvals(file, args, build, key) = [num(get(kv(r["line"]), key, "NaN")) for r in REPRO
                                 if r["file"] == file && r["args"] == args && r["build"] == build]
rmed(file, args, build, key) = med(rvals(file, args, build, key))
function beside(rows, why)
    isempty(REPRO) && return
    println("Standalone reproducer beside the harness (medians; the reproducer's rounds are its own):\n")
    table(["", "harness", "reproducer"], rows)
    println(why, "\n")
end

println("# Measurements of the fair class: master against this PR\n")
println("Every ratio is a **speed** against its reference: above 1 is faster. Cells show median [min–max] (rounds).")
println("Each column is a fresh process every round, the columns rotated, after one throwaway slot. ",
        "\"master\" is the base commit, \"master, second build\" the same commit built again (the floor), ",
        "\"this PR\" the base with the patch", HAS_BYPASS ? ", \"the bypass\" this PR with stock's entry points under master's names and the patch's code compiled in but unreachable" : "",
        ". Machine and builds: `environment.md`; raw data: `raw/`.")

# ---------------------------------------------------------------- a, b
function row_ab()
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
            "Criterion b: this PR's p99 at most 200 ms and every client served, in every round: ", pf(okb), ".\n")
    beside([["master, p99 (ms)", fmtv(med(pa)), fmtv(rmed("starved.jl", "plain", "control", "p99_ms"))],
            ["this PR marked, p99 (ms)", fmtv(med(pb)), fmtv(rmed("starved.jl", "fair", "candidate", "p99_ms"))],
            ["this PR marked, least-served client", fmtv(med([num(r["count_min"]) for r in sb]); d = 0),
             fmtv(rmed("starved.jl", "fair", "candidate", "client_min"); d = 0)]],
           "The same cell: the reproducer keeps only the latencies, where the harness also records each request's timings and checks every task; " *
           "stock's tail varies by hundreds of ms between runs in both.")
end

# ---------------------------------------------------------------- c
function row_c()
    section("c. Beside unmarked compute, both sides advance")
    claim("The starved cell while an unmarked fork-join (`fib_fine`, pfib(42) cut at 12) runs on `:default`. " *
          "With the clients' tasks marked, both advance: the clients' p99 stays bounded and the compute keeps a share of the machine. " *
          "Compute speed = its wall time alone / its wall time during the cell.")
    reproduce("mixed")
    ok = true; any1 = false
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
        any1 |= !isempty(c1)
        ok &= !isempty(c1) && all(r -> num(r["p99_ms"]) <= 600 && sp(r) >= 0.40, c1)
    end
    println("Criterion c: this PR's p99 at most 600 ms and the compute at 0.40 or better, in every round of both shapes: ", pf(ok && any1), ".")
end

# ---------------------------------------------------------------- d
function row_d()
    section("d. Behind a real HTTP server")
    claim("An HTTP.jl server whose handler does 2 ms of compute (`/aggregate`), 500 connections from a closed-loop load generator on other CPUs, 8 s a round, a fresh server each round. " *
          "With the accepted connections' tasks marked, the tail stays bounded at about the same throughput.")
    reproduce("cell81, cell80")
    ok = true; any1 = false; spreads = String[]
    for (layout, dir) in (("8,1", "cell81"), ("8,0", "cell80"))
        rows = filter(r -> parse(Int, r["round"]) >= 1, readtsvs(joinpath(RAW, dir), "fairness-"))
        m0 = filter(r -> endswith(r["mode"], "%control"), rows)
        m1 = filter(r -> endswith(r["mode"], "%candidate"), rows)
        isempty(m1) && continue
        any1 = true
        s = paired(byround(m0, r -> num(r["rps"])), byround(m1, r -> num(r["rps"])), (a, b) -> b / a)
        r0 = [num(r["rps"]) for r in m0]
        push!(spreads, "$layout: master's requests/s spread $(@sprintf("%.1f", 100 * (maximum(r0) - minimum(r0)) / med(r0)))% between its own rounds")
        println("At **", layout, "**:\n")
        table(["", "master", "this PR, marked"],
              [["p99 latency (ms)", cellstr([num(r["p99_ms"]) for r in m0]), cellstr([num(r["p99_ms"]) for r in m1])],
               ["requests/s", cellstr(r0; d = 0), cellstr([num(r["rps"]) for r in m1]; d = 0)],
               ["throughput speed (master = 1)", "1", cellstr(s)]])
        ok &= all(r -> num(r["p99_ms"]) <= 150, m1) && !isempty(s) && med(s) >= 0.98
    end
    println("Criterion d: this PR's p99 at most 150 ms in every round, and its median throughput 0.98 of master's or better, at each layout: ",
            pf(ok && any1), ". (", join(spreads, "; "), ".)")
end

# ---------------------------------------------------------------- e
# One unmarked cell: the speeds against master per round, the floor, the reading.
function floor_cell(name, rows, val, slower_is_larger, opns)
    lab(l) = byround(filter(r -> is(r, l), rows), val)
    v0, v2, v1, vb = lab("control"), lab("control2"), lab("candidate"), HAS_BYPASS ? lab("bypass") : Dict{Int,Float64}()
    sp(a, b) = slower_is_larger ? a / b : b / a                  # speed of b against a
    s2, s1 = paired(v0, v2, sp), paired(v0, v1, sp)
    sb, s1b, sb2 = paired(v0, vb, sp), paired(vb, v1, sp), paired(v2, vb, sp)
    d = max(abs(med(s2) - 1), 0.005)
    within(s) = !isempty(s) && abs(med(s) - 1) <= d
    reading = if within(s1)
        "LAYOUT: this PR stands within the floor of master's second build (±$(@sprintf("%.2f", 100d))%)"
    elseif HAS_BYPASS && within(s1b)
        "LAYOUT: the bypass stands with this PR ($(pct(med(s1b))) against ±$(@sprintf("%.2f", 100d))%)"
    elseif HAS_BYPASS && within(sb) && within(sb2)
        ks = sort(collect(intersect(keys(v0), keys(v2), keys(v1), keys(vb))))
        off = count(k -> slower_is_larger ? (v1[k] > max(v0[k], v2[k], vb[k])) : (v1[k] < min(v0[k], v2[k], vb[k])), ks)
        need = round(Int, 10 / 12 * length(ks))
        if off >= need
            ns = med([opns(v1[k]) - (opns(v0[k]) + opns(v2[k]) + opns(vb[k])) / 3 for k in ks])
            "THE PATH: the bypass stands with both builds of master and this PR is slower than all three in $off of $(length(ks)) rounds; " *
            "$(@sprintf("%.2f", ns)) ns an operation"
        else
            "NOT SEPARABLE: the bypass stands with master, but this PR is slower than all three in only $off of $(length(ks)) rounds (the bar is $need); more rounds would separate it"
        end
    elseif HAS_BYPASS
        "NOT SEPARABLE: the bypass stands neither with this PR nor with both builds of master ($(pct(med(sb))) and $(pct(med(sb2)))); a second bypass build, or more rounds, would separate it"
    else
        "outside the floor: $(pct(med(s1))) against ±$(@sprintf("%.2f", 100d))% (no bypass column)"
    end
    return (name = name, s2 = s2, s1 = s1, sb = sb, s1b = s1b, layout = startswith(reading, "LAYOUT"), reading = reading)
end
function row_e()
    section("e. Code that marks nothing pays nothing measurable")
    claim("With nothing marked, this PR's speed against master lies within the distance between two builds of master itself, " *
          "or the bypass build (this PR's binary with stock's entry points) stands with it. " *
          "LAYOUT: the difference cannot be told from building the code differently. THE PATH: it is the patch's unmarked path, with its size in ns an operation.")
    reproduce("floorfib, floorh0")
    fib = readtsv(joinpath(RAW, "floorfib", "fibabba-nested.tsv"))
    h0 = filter(r -> r["mode"] == "spawn", readtsv(joinpath(RAW, "floorh0", "costrounds-spawn.tsv")))
    spawns = med([num(r["spawns"]) for r in fib])
    cells = [floor_cell("fib_fine, 8,1", fib, r -> num(r["wall_median_s"]), true, w -> 1e9 * w / spawns)]
    for c in ("50", "500")
        push!(cells, floor_cell("spawn path, H = 0, C = $c, 8,0", filter(r -> r["c"] == c, h0), r -> num(r["rps"]), false, x -> 1e9 / x))
    end
    table(["cell", "master, second build", "this PR"], [[c.name, cellstr(c.s2), cellstr(c.s1)] for c in cells])
    HAS_BYPASS && table(["cell", "the bypass", "this PR against the bypass"], [[c.name, cellstr(c.sb), cellstr(c.s1b)] for c in cells])
    for c in cells
        println("- ", c.name, ": ", c.reading, ".")
    end
    println("\nCriterion e: every cell LAYOUT: ", pf(all(c -> c.layout, cells)), ".\n")
    fr = filter(r -> r["file"] == "fib_fine.jl", REPRO)
    isempty(fr) || beside([["fib_fine, this PR against master", fmtv(med(cells[1].s1)),
                            fmtv(rmed("fib_fine.jl", "", "control", "median_s") / rmed("fib_fine.jl", "", "candidate", "median_s"))]],
                          "The same pfib(42) cut at 12 in both; the reproducer has 3 rounds and no harness counters, so a difference of a point is within its spread.")
end

# ---------------------------------------------------------------- f
function row_f()
    section("f. The benchmark of JuliaLang/julia#35589")
    claim("`pfib(25)` as posted in that PR's thread, from one root spawned on `:default`: unmarked, with the root marked, and with every spawn marked. " *
          "Speed against master's unmarked run.")
    reproduce("pfib2, pfib81")
    labels = [("cand", "this PR, unmarked"), ("ctl2", "master, second build")]
    HAS_BYPASS && push!(labels, ("byp", "the bypass, unmarked"))
    append!(labels, [("root", "this PR, root marked"), ("all", "this PR, every spawn marked")])
    frows = Dict(k => [name] for (k, name) in labels)
    ok = true; notes = String[]; fl = String[]; sp2 = Dict{String,Vector{Float64}}()
    for (layout, dir) in (("--threads=2", "pfib2"), ("8,1", "pfib81"))
        rows = filter(r -> !startswith(get(r, "min_s", ""), "FAILED") && rnd(r) >= 1, readtsv(joinpath(RAW, dir, "pfib.tsv")))
        isempty(rows) && continue
        push!(fl, layout)
        b(k) = byround(filter(r -> r["label"] == k, rows), r -> num(r["median_s"]))
        base = b("ctl")
        sp = Dict(k => paired(base, b(k), (a, x) -> a / x) for (k, _) in labels)
        layout == "--threads=2" && (sp2 = sp)
        for (k, _) in labels; push!(frows[k], cellstr(sp[k])); end
        d = max(abs(med(sp["ctl2"]) - 1), 0.005)
        lay = !isempty(sp["cand"]) && abs(med(sp["cand"]) - 1) <= d
        rootok = !isempty(sp["root"]) && all(>=(0.90), sp["root"])
        push!(notes, "$layout: unmarked " * (lay ? "within the floor" : "outside the floor ($(pct(med(sp["cand"]))) against ±$(@sprintf("%.2f", 100d))%)") *
                     (HAS_BYPASS && !isempty(sp["byp"]) ? ", the bypass at $(fmtv(med(sp["byp"])))" : "") * ", root marked " * pf(rootok))
        ok &= lay && rootok
    end
    table(vcat(["speed against master, unmarked"], fl), [frows[k] for (k, _) in labels])
    println("Criterion f: unmarked within the floor, and the root marked at 0.90 or better in every round; every spawn marked is reported with no bar. ",
            join(notes, "; "), ". Overall: ", pf(ok && !isempty(fl)), ".\n")
    isempty(sp2) || beside([["unmarked, --threads=2", fmtv(med(sp2["cand"])), fmtv(rmed("pfib.jl", "none", "control", "median_s") / rmed("pfib.jl", "none", "candidate", "median_s"))],
                            ["root marked", fmtv(med(sp2["root"])), fmtv(rmed("pfib.jl", "none", "control", "median_s") / rmed("pfib.jl", "root", "candidate", "median_s"))],
                            ["every spawn marked", fmtv(med(sp2["all"])), fmtv(rmed("pfib.jl", "none", "control", "median_s") / rmed("pfib.jl", "all", "candidate", "median_s"))]],
                           "The same program; the harness times it with BenchmarkTools for 4 s, the reproducer with its own loop for 4 s.")
end

# ---------------------------------------------------------------- g
function row_g()
    section("g. The cost with everything marked")
    claim("The spawn path itself (closed-loop clients on `:default` spawning tasks, 8,0), with the clients and every task they spawn marked. Speed against master.")
    reproduce("spawnpath")
    sprows = filter(r -> r["mode"] == "spawn", readtsv(joinpath(RAW, "spawnpath", "costrounds-spawn.tsv")))
    rows = Any[]; ok = true; any1 = false; hs = Dict{String,Float64}()
    for c in ("50", "500")
        hc = filter(r -> r["c"] == c, sprows)
        a = byround(filter(r -> is(r, "control"), hc), r -> num(r["rps"]))
        b = byround(filter(r -> is(r, "candidate") && r["variant"] == "N", hc), r -> num(r["rps"]))
        s = paired(a, b, (x, y) -> y / x)
        isempty(s) && continue
        any1 = true; hs[c] = med(s)
        push!(rows, ["C = $c", cellstr(collect(values(a)); d = 0), cellstr(s)])
        ok &= all(>=(0.80), s)
    end
    table(["cell", "master, requests/s", "this PR marked, speed"], rows)
    println("Criterion g: speed 0.80 or better in every round: ", pf(ok && any1), ".\n")
    beside([["C = $c, this PR marked against master", fmtv(get(hs, c, NaN)),
             fmtv(rmed("spawn_path.jl", "fair $c", "candidate", "rps") / rmed("spawn_path.jl", "plain $c", "control", "rps"))] for c in ("50", "500")],
           "The harness's handler also stamps and records each request, so the scheduler's share of a request is smaller there; the reproducer's tasks do nothing but notify, so the mark's fixed cost weighs more.")
end

# ---------------------------------------------------------------- h
function row_h()
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
    println("Criterion h: after one marked task, speed 0.965 or better against the same build never marked, in every round: ",
            pf(!isempty(s_ru) && all(>=(0.965), s_ru)), ".\n")
    beside([["after one marked task, against never marked", fmtv(med(s_ru)),
             fmtv(rmed("armed.jl", "unarmed", "candidate", "median_s") / rmed("armed.jl", "armed", "candidate", "median_s"))]],
           "The same work; the reproducer arms the flag by one `fair=true` spawn in the measured process, the harness by one marked task at load, and its 3 rounds spread wider.")
end

# ---------------------------------------------------------------- i
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
function row_i()
    section("i. Julia's tests")
    claim("The test sets the change touches, on master and on this PR, nothing marked: the same counts. The new tests run inside `threads_exec.jl`, " *
          "which `threads` runs in a subprocess at five thread layouts; their own assertions are not in these totals.")
    reproduce("tests")
    irows = Any[]
    for (label, name) in (("control", "master"), ("candidate", "this PR"))
        o = overall(joinpath(RAW, "tests", "$label.log"))
        o === nothing && (push!(irows, [name, "–", "–"]); continue)
        d, st = o
        push!(irows, [name, string(get(d, "Pass", "0"), " passed, ", get(d, "Broken", "0"), " broken, ",
                                  get(d, "Fail", "0"), " failed, ", get(d, "Error", "0"), " errors"), st])
    end
    table(["build", "core, threads, channels, channel_threadpool, threadpool_use, threadpool_latency, cancellation", "result"], irows)
end

# ---------------------------------------------------------------- the reproducers, whole
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
function repro_section()
    section("Standalone reproducers")
    println("Single files in `bench/julia/candidate/`, standard library only, each run as ",
            "`julia --threads=<layout> <file>.jl [args]` on both builds, a fresh process a round, pinned as the cells. ",
            "A marked mode on master prints that the keyword is not there.\n")
    reproduce("repro, repro_gh")
    rrows = Any[]
    for (row, file, args, key, name) in REPRO_ITEMS
        v0, v1 = rvals(file, args, "control", key), rvals(file, args, "candidate", key)
        isempty(v0) && isempty(v1) && continue
        d = key in ("rps", "client_min", "p99_ms") ? 0 : 4
        push!(rrows, ["$name ($row)", isempty(filter(!isnan, v0)) ? "not supported" : cellstr(v0; d), cellstr(v1; d)])
    end
    table(["reproducer (row)", "master", "this PR"], rrows)
end
function mwe_section()
    section("The description's reproducer")
    println("`bench/julia/candidate/mwe.jl` at `--threads=8,1`: once on master as it is, once on this PR with the client's spawn marked (`fair=true`).\n")
    for (name, f) in (("master", "mwe-control.txt"), ("this PR, `fair=true`", "mwe-candidate-fair.txt"))
        p = joinpath(RAW, "mwe", f)
        isfile(p) || continue
        println(name, ":\n\n```\n", rstrip(read(p, String)), "\n```\n")
    end
end

# ---------------------------------------------------------------- the time_ns variant
function timens_section()
    HAS_TIMENS || return
    section("Variant, not part of this PR: the clock is `time_ns()` everywhere")
    println("The candidate with `time_ns()` in place of the cycle counter on every platform (no calibration, no architecture branch, one cap), ",
            "measured beside the candidate in steps of its own (`tstarved`, `tmixed`, `tspawnpath`, `tarm`, `tfloorfib`, `tfloorh0`). Speeds against master unless said.\n")
    st = filter(r -> r["mode"] == "spawn" && rnd(r) >= 1, readtsv(joinpath(RAW, "tstarved", "fairrounds-spawn.tsv")))
    g(l, v, rows) = filter(r -> is(r, l) && r["variant"] == v, rows)
    table(["starved cell (b)", "this PR, marked", "variant, marked"],
          [["p99 latency (ms)", cellstr([num(r["p99_ms"]) for r in g("candidate", "N", st)]), cellstr([num(r["p99_ms"]) for r in g("timens", "N", st)])],
           ["least-served client", cellstr([num(r["count_min"]) for r in g("candidate", "N", st)]; d = 0), cellstr([num(r["count_min"]) for r in g("timens", "N", st)]; d = 0)]])
    for (shape, file) in (("plain", "mixed.tsv"), ("inner", "mixedinner.tsv"))
        rows = filter(r -> rnd(r) >= 1, readtsv(joinpath(RAW, "tmixed", file)))
        sp(r) = num(r["fib_alone_median_s"]) / num(r["fib_median_s"])
        table(["mixed cell, $shape (c)", "this PR, marked", "variant, marked"],
              [["clients' p99 latency (ms)", cellstr([num(r["p99_ms"]) for r in g("candidate", "N", rows)]), cellstr([num(r["p99_ms"]) for r in g("timens", "N", rows)])],
               ["compute speed (alone = 1)", unfinished(sp.(g("candidate", "N", rows))), unfinished(sp.(g("timens", "N", rows)))]])
    end
    sprows = filter(r -> r["mode"] == "spawn", readtsv(joinpath(RAW, "tspawnpath", "costrounds-spawn.tsv")))
    trows = Any[]
    for c in ("50", "500")
        hc = filter(r -> r["c"] == c, sprows)
        a = byround(filter(r -> is(r, "control"), hc), r -> num(r["rps"]))
        push!(trows, ["C = $c", cellstr(paired(a, byround(g("candidate", "N", hc), r -> num(r["rps"])), (x, y) -> y / x)),
                      cellstr(paired(a, byround(g("timens", "N", hc), r -> num(r["rps"])), (x, y) -> y / x))])
    end
    table(["spawn path, everything marked (g)", "this PR", "variant"], trows)
    arm = readtsv(joinpath(RAW, "tarm", "fibabba-nested.tsv"))
    w(l, v) = byround(g(l, v, arm), r -> num(r["wall_median_s"]))
    table(["fib_fine after one marked task (h)", "this PR", "variant"],
          [["against the same build never marked", cellstr(paired(w("candidate", "N-none"), w("candidate", "N-arm"), (u, x) -> u / x)),
            cellstr(paired(w("timens", "N-none"), w("timens", "N-arm"), (u, x) -> u / x))]])
    fib = readtsv(joinpath(RAW, "tfloorfib", "fibabba-nested.tsv"))
    h0 = filter(r -> r["mode"] == "spawn", readtsv(joinpath(RAW, "tfloorh0", "costrounds-spawn.tsv")))
    fval(l, rows, f) = byround(filter(r -> is(r, l), rows), f)
    erows = Any[]
    for (name, rows, f, slow) in [("fib_fine, 8,1", fib, r -> num(r["wall_median_s"]), true),
                                  ("H = 0, C = 50, 8,0", filter(r -> r["c"] == "50", h0), r -> num(r["rps"]), false),
                                  ("H = 0, C = 500, 8,0", filter(r -> r["c"] == "500", h0), r -> num(r["rps"]), false)]
        sp(a, b) = slow ? a / b : b / a
        v0 = fval("control", rows, f)
        push!(erows, [name * " (master's second build: $(fmtv(med(paired(v0, fval("control2", rows, f), sp)))))",
                      cellstr(paired(v0, fval("candidate", rows, f), sp)), cellstr(paired(v0, fval("timens", rows, f), sp))])
    end
    table(["nothing marked (e)", "this PR", "variant"], erows)
end

row_ab(); row_c(); row_d(); row_e(); row_f(); row_g(); row_h(); row_i()
repro_section(); mwe_section(); timens_section()
