# The report of bench/julia/perf_unmarked.sh (#618, agent-config #82 Idea 15).
#
#   julia bench/julia/perf_report.jl <OUT>
#
# A1: per build and layout, every counter per operation = (count at 2N - count at N) / N, one value
# a pair, median [min-max] over the pairs. "all" sums every thread of the process; "spawner" is Julia
# thread 1 (the main task's, :interactive here), "default" the :default threads, "other" the rest
# (GC, I/O). Then, for each counter, whether m2 sits off both bypass builds by more than they sit off
# each other (on the medians). A2: who ran each child. A3: voluntary context switches per operation
# in the loop's window, per thread, and the kernel's share of cycles. A4: the recorded runs' wall
# time against the unrecorded ones.
using Statistics, Printf

const OUT = ARGS[1]
const COLS = split(get(ENV, "PU_COLS", "ctl m2 bp bp2 s1 s2"))   # slim2.sh: "ctl m2 bp bp2 s2 s2b"
const LAYOUTS = ["2,1", "4,1"]

kv(line) = Dict(split(f, '=', limit = 2)[1] => split(f, '=', limit = 2)[2] for f in split(chomp(line), '\t') if occursin('=', f))
readline_kv(path) = kv(readline(path))

# perf stat --per-thread -x';' : "<comm>-<tid>;<count>;;<event>;..."; returns event => tid => count.
function read_perf(path)
    d = Dict{String, Dict{Int, Float64}}()
    for line in eachline(path)
        (isempty(line) || startswith(line, '#')) && continue
        f = split(line, ';')
        length(f) < 4 && continue
        tid = parse(Int, split(f[1], '-')[end])
        c = tryparse(Float64, f[2]); c === nothing && continue   # <not counted>
        get!(Dict{Int, Float64}, d, String(f[4]))[tid] = c
    end
    return d
end

function roles(line)
    m = Dict{Int, Symbol}()
    for p in split(line["os_tid_by_jtid"], ',')
        j, t = parse.(Int, split(p, ':'))
        m[t] = j == 1 ? :spawner : :default
    end
    return m
end

med(v) = isempty(v) ? NaN : median(v)
fmt(x) = isnan(x) ? "–" : abs(x) >= 100 ? @sprintf("%.0f", x) : abs(x) >= 10 ? @sprintf("%.1f", x) : abs(x) >= 1 ? @sprintf("%.2f", x) : @sprintf("%.3f", x)
cell(v) = isempty(v) ? "–" : "$(fmt(med(v))) [$(fmt(minimum(v)))–$(fmt(maximum(v)))]"

# group => (layout, build) => event => role => per-op values over pairs; plus wall ns/op.
function a1(g)
    dir = joinpath(OUT, g)
    isdir(dir) || return nothing
    res = Dict{Tuple{String, String}, Dict{String, Dict{Symbol, Vector{Float64}}}}()
    for f in readdir(dir)
        m = match(r"^p(\d+)-(\d)_(\d)-(\w+)-n(\d+)\.line$", f)
        m === nothing && continue
        p, l, b, n = m[1], "$(m[2]),$(m[3])", m[4], parse(Int, m[5])
        n2 = joinpath(dir, "p$p-$(m[2])_$(m[3])-$b-n$(2n).line")
        isfile(n2) || continue
        L1, L2 = readline_kv(joinpath(dir, f)), readline_kv(n2)
        P1 = read_perf(replace(joinpath(dir, f), ".line" => ".perf"))
        P2 = read_perf(replace(n2, ".line" => ".perf"))
        r1, r2 = roles(L1), roles(L2)
        d = get!(() -> Dict{String, Dict{Symbol, Vector{Float64}}}(), res, (l, b))
        w = get!(() -> Dict{Symbol, Vector{Float64}}(), d, "wall_ns")
        push!(get!(Vector{Float64}, w, :all), (parse(Int, L2["loop_ns"]) - parse(Int, L1["loop_ns"])) / n)
        for ev in keys(P1)
            haskey(P2, ev) || continue
            sums(P, r) = (s = Dict(:all => 0.0, :spawner => 0.0, :default => 0.0, :other => 0.0);
                          for (t, c) in P[ev]; s[:all] += c; s[get(r, t, :other)] += c; end; s)
            s1, s2 = sums(P1, r1), sums(P2, r2)
            e = get!(() -> Dict{Symbol, Vector{Float64}}(), d, ev)
            for role in (:all, :spawner, :default, :other)
                push!(get!(Vector{Float64}, e, role), (s2[role] - s1[role]) / n)
            end
        end
    end
    return res
end

function print_a1(g, res)
    res === nothing && return
    evs = sort(unique(vcat([collect(keys(v)) for v in values(res)]...)))
    println("\n## $g: per operation, median [min–max] over pairs (2N − N)\n")
    for l in LAYOUTS
        println("### $l\n")
        println("| counter | role | ", join(COLS, " | "), " |")
        println("|---|---|", repeat("--:|", length(COLS)))
        for ev in evs, role in (ev == "wall_ns" ? (:all,) : (:all, :spawner, :default, :other))
            vals = [get(get(get(res, (l, b), Dict()), ev, Dict()), role, Float64[]) for b in COLS]
            all(isempty, vals) && continue
            println("| $ev | $role | ", join(cell.(vals), " | "), " |")
        end
        # IPC and separation
        if haskey(get(res, (l, "m2"), Dict()), "instructions:u")
            for role in (:all, :spawner, :default)
                ipc = [med(get(get(res, (l, b), Dict()), "instructions:u", Dict())[role] ./
                           get(get(res, (l, b), Dict()), "cycles:u", Dict())[role]) for b in COLS if haskey(res, (l, b))]
                println("| IPC (u) | $role | ", join(fmt.(ipc), " | "), " |")
            end
        end
        println("\nSeparation (medians, all threads): m2 − bp, m2 − bp2, |bp − bp2|; ✔ = m2 off both by more than bp off bp2\n")
        println("| counter | role | m2 − bp | m2 − bp2 | \\|bp − bp2\\| | sep | s1 − bp | s2 − bp |")
        println("|---|---|--:|--:|--:|:-:|--:|--:|")
        for ev in evs, role in (ev == "wall_ns" ? (:all,) : (:all, :spawner, :default))
            g_(b) = med(get(get(get(res, (l, b), Dict()), ev, Dict()), role, Float64[]))
            m2, bp, bp2, s1, s2 = g_("m2"), g_("bp"), g_("bp2"), g_("s1"), g_("s2")
            sp = abs(bp - bp2)
            sep = min(abs(m2 - bp), abs(m2 - bp2)) > sp && sign(m2 - bp) == sign(m2 - bp2) ? "✔" : ""
            println("| $ev | $role | $(fmt(m2 - bp)) | $(fmt(m2 - bp2)) | $(fmt(sp)) | $sep | $(fmt(s1 - bp)) | $(fmt(s2 - bp)) |")
        end
        println()
    end
end

# A3 from g1's lines (in-process, the loop's window only): context switches per op per Julia thread.
function print_a3()
    dir = joinpath(OUT, "a1g1")
    isdir(dir) || return
    println("\n## A3: voluntary (and involuntary) context switches per 1,000 operations, loop window, per Julia thread\n")
    for l in LAYOUTS
        println("### $l\n")
        println("| thread | ", join(COLS, " | "), " |")
        println("|---|", repeat("--:|", length(COLS)))
        rows = Dict{String, Dict{String, Vector{Float64}}}()
        for f in readdir(dir)
            m = match(r"^p\d+-(\d)_(\d)-(\w+)-n(\d+)\.line$", f)
            (m === nothing || "$(m[1]),$(m[2])" != l) && continue
            L = readline_kv(joinpath(dir, f)); n = parse(Int, m[4])
            for (key, tag) in (("vcs_by_jtid", "v"), ("ivcs_by_jtid", "iv"))
                for p in split(L[key], ',')
                    j, c = parse.(Int, split(p, ':'))
                    push!(get!(Vector{Float64}, get!(() -> Dict{String, Vector{Float64}}(), rows, "$tag $j"), m[3]), 1000c / n)
                end
            end
            push!(get!(Vector{Float64}, get!(() -> Dict{String, Vector{Float64}}(), rows, "v other"), m[3]), 1000parse(Int, L["vcs_other_os_threads"]) / n)
            push!(get!(Vector{Float64}, get!(() -> Dict{String, Vector{Float64}}(), rows, "gc ns per op"), m[3]), parse(Int, L["gc_ns"]) / n)
        end
        for k in sort(collect(keys(rows)))
            println("| $k | ", join([cell(get(rows[k], b, Float64[])) for b in COLS], " | "), " |")
        end
        println()
    end
end

function print_a2()
    dir = joinpath(OUT, "a2")
    isdir(dir) || return
    println("\n## A2: who runs the child (MODE=who, one value a run, median [min–max])\n")
    for l in LAYOUTS
        println("### $l\n")
        println("| | ", join(COLS, " | "), " |")
        println("|---|", repeat("--:|", length(COLS)))
        rows = Dict{String, Dict{String, Vector{Float64}}}()
        for f in readdir(dir)
            m = match(r"^r\d+-(\d)_(\d)-(\w+)\.line$", f)
            (m === nothing || "$(m[1]),$(m[2])" != l) && continue
            L = readline_kv(joinpath(dir, f))
            put(k, v) = push!(get!(Vector{Float64}, get!(() -> Dict{String, Vector{Float64}}(), rows, k), m[3]), v)
            put("ns/op (instrumented)", parse(Float64, L["ns_per_op"]))
            put("share on the spawner's thread", parse(Float64, L["share_on_spawner_thread"]))
            put("share on a thread other than the previous child's", parse(Float64, L["share_thread_changed"]))
            for p in split(L["child_share_by_jtid"], ',')
                j, s = split(p, ':')
                put("share on thread $j", parse(Float64, s))
            end
        end
        for k in sort(collect(keys(rows)))
            println("| $k | ", join([cell(get(rows[k], b, Float64[])) for b in COLS], " | "), " |")
        end
        println()
    end
end

function print_a4()
    dir = joinpath(OUT, "a4")
    isdir(dir) || return
    println("\n## A4: wall time with and without `perf record` (2,1, ns/op of the loop)\n")
    println("| build | unrecorded | recorded | change |")
    println("|---|--:|--:|--:|")
    for b in ("m2", "bp")
        pl = [parse(Float64, readline_kv(joinpath(dir, f))["ns_per_op"]) for f in readdir(dir) if occursin(Regex("^plain-\\d-$b\\.line\$"), f)]
        rc = [parse(Float64, readline_kv(joinpath(dir, f))["ns_per_op"]) for f in readdir(dir) if occursin(Regex("^rec-\\d-$b\\.line\$"), f)]
        isempty(pl) || isempty(rc) || println("| $b | $(cell(pl)) | $(cell(rc)) | $(@sprintf("%+.2f%%", 100(med(rc) / med(pl) - 1))) |")
    end
end

# A5 and A7: the split runs, one value a run; and per-run (same rotation round) ratios.
function split_runs()
    dir = joinpath(OUT, "a5")
    isdir(dir) || return nothing
    v = Dict{Tuple{String, String}, Dict{String, Dict{String, Float64}}}()   # (layout, build) => run => key => value
    for f in readdir(dir)
        m = match(r"^r(\d+)-(\d)_(\d)-(\w+)\.line$", f)
        m === nothing && continue
        L = readline_kv(joinpath(dir, f))
        d = get!(() -> Dict{String, Dict{String, Float64}}(), v, ("$(m[2]),$(m[3])", m[4]))
        d[m[1]] = Dict(k => parse(Float64, x) for (k, x) in L if occursin(r"^(pickup|run|wake|op|period)_|^bt_median$|^ns_per_op$", k))
    end
    return v
end

const SPLIT_KEYS = ["pickup_p10", "pickup_p50", "pickup_p90", "pickup_mean", "run_p50", "run_mean",
                    "wake_p10", "wake_p50", "wake_p90", "wake_mean", "op_p50", "op_mean", "period_mean", "bt_median"]

function print_a5(v)
    v === nothing && return
    println("\n## A5: the operation split (MODE=split), ns, median [min–max] over runs\n")
    for l in LAYOUTS
        println("### $l\n")
        println("| | ", join(COLS, " | "), " |")
        println("|---|", repeat("--:|", length(COLS)))
        for k in SPLIT_KEYS
            vals = [Float64[r[k] for r in values(get(v, (l, b), Dict())) if haskey(r, k)] for b in COLS]
            println("| $k | ", join(cell.(vals), " | "), " |")
        end
        println("\nDifferences of the medians: m2 − bp, m2 − bp2, |bp − bp2|; ✔ = m2 off both by more than bp off bp2\n")
        println("| | m2 − bp | m2 − bp2 | \\|bp − bp2\\| | sep | s1 − bp | s2 − bp | s2 − m2 |")
        println("|---|--:|--:|--:|:-:|--:|--:|--:|")
        for k in SPLIT_KEYS
            g_(b) = med(Float64[r[k] for r in values(get(v, (l, b), Dict())) if haskey(r, k)])
            m2, bp, bp2, s1, s2 = g_("m2"), g_("bp"), g_("bp2"), g_("s1"), g_("s2")
            sp = abs(bp - bp2)
            sep = min(abs(m2 - bp), abs(m2 - bp2)) > sp && sign(m2 - bp) == sign(m2 - bp2) ? "✔" : ""
            println("| $k | $(fmt(m2 - bp)) | $(fmt(m2 - bp2)) | $(fmt(sp)) | $sep | $(fmt(s1 - bp)) | $(fmt(s2 - bp)) | $(fmt(s2 - m2)) |")
        end
        println()
    end
end

function print_a7(v)
    v === nothing && return
    println("\n## A7: tasks.jl's statistic from A5's samples (median of 70-op block means), per-run ratios (same round)\n")
    println("| layout | key | bp2/bp | m2/bp | m2/bp2 | s1/bp | s1/bp2 | s2/bp | s2/bp2 | m2/ctl |")
    println("|---|---|--:|--:|--:|--:|--:|--:|--:|--:|")
    for l in LAYOUTS, k in ("bt_median", "op_p50", "period_mean", "pickup_p50", "wake_p50")
        rat(x, y) = (rs = Float64[]; for (run, rx) in get(v, (l, x), Dict()); ry = get(get(v, (l, y), Dict()), run, nothing);
                     ry === nothing || push!(rs, rx[k] / ry[k]); end; isempty(rs) ? "–" : "$(@sprintf("%.3f", med(rs))) ($(count(>(1), rs))/$(length(rs)))")
        println("| $l | $k | ", join([rat(x, y) for (x, y) in (("bp2", "bp"), ("m2", "bp"), ("m2", "bp2"), ("s1", "bp"), ("s1", "bp2"), ("s2", "bp"), ("s2", "bp2"), ("m2", "ctl"))], " | "), " |")
    end
end

# A6: the poll turn of an idle :default thread. perf -x fields: comm-tid;count;unit;event;run_ns;pcnt;…
function read_perf_runtime(path)
    d = Dict{String, Dict{Int, Tuple{Float64, Float64}}}()
    for line in eachline(path)
        (isempty(line) || startswith(line, '#')) && continue
        f = split(line, ';'); length(f) < 5 && continue
        c = tryparse(Float64, f[2]); t = tryparse(Float64, f[5]); (c === nothing || t === nothing) && continue
        ev = startswith(f[4], "mem:") ? "bp_hits" : String(f[4])
        get!(Dict{Int, Tuple{Float64, Float64}}, d, ev)[parse(Int, split(f[1], '-')[end])] = (c, t)
    end
    return d
end

function print_a6(v)
    dir = joinpath(OUT, "a6")
    isdir(dir) || return
    println("\n## A6: the poll turn of a spinning :default thread (idle, JULIA_THREAD_SLEEP_THRESHOLD=infinite), median [min–max] over runs\n")
    for l in LAYOUTS
        println("### $l\n")
        println("| | ", join(COLS, " | "), " |")
        println("|---|", repeat("--:|", length(COLS)))
        rows = Dict{String, Dict{String, Vector{Float64}}}()
        put(k, b, x) = push!(get!(Vector{Float64}, get!(() -> Dict{String, Vector{Float64}}(), rows, k), b), x)
        for f in readdir(dir)
            m = match(r"^u(\d+)-(\d)_(\d)-(\w+)\.line$", f)
            (m === nothing || "$(m[2]),$(m[3])" != l) && continue
            b = m[4]; bf = joinpath(dir, "b$(m[1])-$(m[2])_$(m[3])-$b")
            isfile(bf * ".perf") || continue
            U = read_perf_runtime(joinpath(dir, replace(f, ".line" => ".perf"))); B = read_perf_runtime(bf * ".perf")
            ru = roles(readline_kv(joinpath(dir, f))); rb = roles(readline_kv(bf * ".line"))
            ins = sum(c for (t, (c, _)) in U["instructions:u"] if get(ru, t, :other) == :default)
            cyc = sum(c for (t, (c, _)) in U["cycles:u"] if get(ru, t, :other) == :default)
            run_ns = sum(r for (t, (_, r)) in U["instructions:u"] if get(ru, t, :other) == :default)
            bins = sum(c for (t, (c, _)) in B["instructions:u"] if get(rb, t, :other) == :default)
            hits = sum(c for (t, (c, _)) in B["bp_hits"] if get(rb, t, :other) == :default)
            ipt = bins / hits; ipns = ins / run_ns
            put("instructions per turn", b, ipt)
            put("IPC (spinning)", b, ins / cyc)
            put("cycles per turn", b, ipt * cyc / ins)
            put("turn, ns", b, ipt / ipns)
            put("GHz (spinning)", b, cyc / run_ns)
        end
        for k in ("instructions per turn", "IPC (spinning)", "cycles per turn", "GHz (spinning)", "turn, ns")
            println("| $k | ", join([cell(get(get(rows, k, Dict()), b, Float64[])) for b in COLS], " | "), " |")
        end
        if v !== nothing && haskey(rows, "turn, ns")
            tpk = [med(Float64[r["pickup_p50"] for r in values(get(v, (l, b), Dict()))]) / med(get(rows["turn, ns"], b, [NaN])) for b in COLS]
            println("| pickup p50 / turn (turns per spinner) | ", join(fmt.(tpk), " | "), " |")
        end
        println()
    end
end

# A7 (#618 Idea 16, A5): the plain loop with perf attached and without, wall ns/op as 2N - N.
function print_a7attach()
    dir = joinpath(OUT, "a7")
    isdir(dir) || return
    println("\n## a7: the plain fixed loop with `perf stat` attached and with nothing attached (2N − N, ns/op)\n")
    w = Dict{Tuple{String, String, String, String}, Float64}()   # (layout, build, tool, pair) => ns/op
    for f in readdir(dir)
        m = match(r"^p(\d+)-(\d)_(\d)-(\w+)-(stat|none)-n(\d+)\.line$", f)
        m === nothing && continue
        n = parse(Int, m[6])
        f2 = joinpath(dir, "p$(m[1])-$(m[2])_$(m[3])-$(m[4])-$(m[5])-n$(2n).line")
        isfile(f2) || continue
        w[("$(m[2]),$(m[3])", m[4], m[5], m[1])] = (parse(Int, readline_kv(f2)["loop_ns"]) - parse(Int, readline_kv(joinpath(dir, f))["loop_ns"])) / n
    end
    for l in unique(k[1] for k in keys(w)), t in ("stat", "none")
        bs = sort(unique(k[2] for k in keys(w) if k[1] == l))
        println("- $l, perf ", t == "stat" ? "attached" : "not attached", ": ",
                join(["$b $(cell([v for (k, v) in w if k[1] == l && k[2] == b && k[3] == t]))" for b in bs], "; "))
        if "bp" in bs && "bp2" in bs
            r = [w[(l, "bp2", t, p)] / w[(l, "bp", t, p)] for p in unique(k[4] for k in keys(w)) if haskey(w, (l, "bp2", t, p)) && haskey(w, (l, "bp", t, p))]
            println("  bp2/bp per pair: $(cell(r)) ($(count(>(1), r))/$(length(r)) > 1); bp2 − bp median $(fmt(med([w[(l, "bp2", t, p)] - w[(l, "bp", t, p)] for p in unique(k[4] for k in keys(w)) if haskey(w, (l, "bp2", t, p)) && haskey(w, (l, "bp", t, p))]))) ns")
        end
    end
end

println("# perf_unmarked report: $OUT")
for g in ("a1g1", "a1g2", "a1g3")
    print_a1(g, a1(g))
end
print_a3()
print_a2()
print_a4()
let v = split_runs()
    print_a5(v); print_a6(v); print_a7(v)
end
print_a7attach()
