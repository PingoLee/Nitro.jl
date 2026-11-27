# #618, the `8,0` diagnostic: read -g's VALIDATE counts out of fairness.sh's `/mq` files.
#
#   julia --project=bench bench/socket/group_report.jl <raw dir> [<raw dir>...]
#
# For every `<stem>-mq.json` that carries `group_per_tid` (a -g variant under VALIDATE; fairness.sh
# reads `/mq` just before the window, so the file after it covers the window alone), one table per
# server and window, one row per `:default` thread and a summed row:
#   pops seen        two-sided (L heaps and the request side both had work), request side only,
#                    L only, nothing
#   pops by structure  R heaps, rings, L heaps (the tasks the pop returned)
#   L missed         stock pops that came back empty while a re-probe saw a task in L's heaps, and of
#                    those how many the pop answered with a request-side task (`→R`) or with nothing
#                    (an upper bound: another thread may have taken the task in between)
#   credited         the share's own accounts, the time it credited while both sides had work, in ms,
#                    and the request side's part of it, against w = GROUP_W4/4
#   run              the time actually run after each pop (a clock read at every pop), in ms, by the
#                    side of the task the pop returned; and the request side's part of the time that
#                    started at a two-sided pop, which is what the share was meant to split
#   per request      run time per request on each side, in µs (requests = the marked spawns in the
#                    window, one per request)
#   depth            the L heaps', the rings' and the R heaps' depth, mean and peak, sampled every
#                    64th pop on each thread (pop-sampled, not time-sampled)
using JSON

ms(c, cpm) = round(c / cpm; digits = 1)
pct(a, b) = a + b == 0 ? "-" : string(round(100 * a / (a + b); digits = 1), "%")

function report(path::AbstractString)
    d = JSON.parse(read(path, String))
    haskey(d, "group_per_tid") || return false
    cpm = Float64(d["cycles_per_ms"])
    w = haskey(d, "group_w") ? Float64(d["group_w"]) : d["group_w4"] / 4
    req = d["marked_spawns"]
    tids = sort(collect(keys(d["group_per_tid"])); by = x -> parse(Int, x))
    rows = [d["group_per_tid"][t] for t in tids]
    sumrow = Dict(k => sum(r[k] for r in rows) for k in keys(rows[1]))
    for k in ("dl_peak", "dq_peak", "dh_peak")
        sumrow[k] = maximum(r[k] for r in rows)
    end
    println("\n### ", basename(path), ": ", d["variant"], " ", get(d, "mode", ""), ", verdict ", d["verdict"],
            ", marked spawns ", req, ", desc ", d["desc"], ", foreign ", d["foreign"], ", w = ", w)
    println("| tid | pops two / R only / L only / none | by structure R heaps / rings / L | L missed (→R, →none) | ",
            "credited R / L ms (R part) | run R / L ms | run from two-sided R / L ms (R part) | per request R / L µs | ",
            "depth L / rings / R heaps mean (peak) |")
    println("|---|---|---|---|---|---|---|---|---|")
    for (t, r) in zip(vcat(tids, ["all"]), vcat(rows, [sumrow]))
        n = max(r["nsamp"], 1)
        mean(x) = round(r[x] / n; digits = 1)
        perreq(x) = req == 0 ? "-" : string(round(1000 * r[x] / cpm / req; digits = 1))
        println("| ", t, " | ", r["two"], " / ", r["one_r"], " / ", r["one_l"], " / ", r["none"],
                " | ", r["r_pops"], " / ", r["f_pops"], " / ", r["l_pops"],
                " | ", r["l_miss"], " (", r["l_miss_r"], ", ", r["l_miss_none"], ")",
                " | ", ms(r["both_f"], cpm), " / ", ms(r["both_l"], cpm), " (", pct(r["both_f"], r["both_l"]), ")",
                " | ", ms(r["run_r"], cpm), " / ", ms(r["run_l"], cpm),
                " | ", ms(r["run_r2"], cpm), " / ", ms(r["run_l2"], cpm), " (", pct(r["run_r2"], r["run_l2"]), ")",
                " | ", t == "all" ? string(perreq("run_r"), " / ", perreq("run_l")) : "",
                " | ", mean("dl_sum"), " (", r["dl_peak"], ") / ", mean("dq_sum"), " (", r["dq_peak"], ") / ",
                mean("dh_sum"), " (", r["dh_peak"], ") |")
    end
    return true
end

isempty(ARGS) && error("usage: group_report.jl <raw dir>...")
for dir in ARGS
    files = sort(filter(f -> endswith(f, "-mq.json"), readdir(dir; join = true)))
    n = count(report, files)
    n == 0 && println("group_report: no -g VALIDATE counts in ", dir)
end
