# The report of the lost-wakeup window repro (bench/tasks/wake_window.jl; #618, agent-config #82 Idea 13).
#   julia bench/julia/window_report.jl <dir>        (dir: holds the *.tsv and *.events wake_window wrote)
# Per column: layout, build, mode, negative control, rounds, tasks enqueued, stuck (rescued by the
# driver's wake), late (past STUCK_MS, ran before the rescue), unrescued, the stuck rate per million
# enqueues, the latency's p99.9 and max, and the counts that show which structure the tasks went
# through (validation build). Then, per column with stuck tasks, what the watchdog saw: the queues'
# depth (rings, R heaps, stock's heaps) and the threads that made no pop in 20 ms. Stdlib only.

const DIR = isempty(ARGS) ? error("usage: julia window_report.jl <dir>") : ARGS[1]

rows = Dict{String,String}[]
for f in sort(filter(endswith(".tsv"), readdir(DIR; join = true)))
    hdr = nothing
    for l in eachline(f)
        x = split(l, '\t')
        if x[1] == "label"
            hdr = x
        elseif hdr !== nothing && length(x) == length(hdr)
            push!(rows, Dict(zip(hdr, x)))
        end
    end
end
events = Dict{Tuple{String,String},Vector{Vector{SubString{String}}}}()   # (layout file, label) => events
for f in sort(filter(endswith(".events"), readdir(DIR; join = true)))
    for l in eachline(f)
        x = split(l, '\t')
        length(x) >= 11 && x[2] in ("stuck", "late") || continue
        push!(get!(() -> [], events, (basename(f), String(x[1]))), x)
    end
end

println("| layout | label | build | neg | rounds | enqueued | stuck | late | unresc. | per 10^6 | p99.9 us | max us | f_first | r_again |")
println("|---|---|---|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|")
for r in rows
    n = parse(Int, r["enqueued"]); s = parse(Int, r["stuck"]) + parse(Int, r["late"]) + parse(Int, r["unrescued"])
    println("| ", join([r["layout"], r["label"], r["commit"], r["neg_env"], r["rounds"], r["enqueued"], r["stuck"], r["late"],
                        r["unrescued"], string(round(1e6 * s / max(n, 1); digits = 2)), r["lat_p999_us"], r["lat_max_us"],
                        r["f_first"], r["r_again"]], " | "), " |")
end
println()
for ((file, label), ev) in sort(collect(events); by = first)
    st = [e for e in ev if e[2] == "stuck"]
    println("## ", file, " ", label, ": ", length(st), " stuck, ", length(ev) - length(st), " late")
    tally(k) = (d = Dict{String,Int}(); for e in ev; d[e[k]] = get(d, e[k], 0) + 1; end; join(("$v x $c" for (v, c) in sort(collect(d); by = last, rev = true)), ", "))
    println("  rings queued: ", tally(6), "; R heaps queued: ", tally(7), "; stock queued: ", tally(8))
    println("  threads with no pop in 20 ms: ", tally(9), "; rescue: ", tally(10))
    lat = sort([parse(Float64, e[11]) for e in st if e[11] != "-"])
    isempty(lat) || println("  rescue latency us: median ", lat[(length(lat) + 1) ÷ 2], ", max ", lat[end])
end
