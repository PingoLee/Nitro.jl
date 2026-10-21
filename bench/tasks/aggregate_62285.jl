# The Markdown tables of a rounds_62285.sh results directory (#618 x JuliaLang/julia#62285): fairness,
# scheduler-bound throughput, the tasks.jl micro and queued rows and the nested workloads, each value
# the median over rounds with [min–max], per series. A series is a (build, variant): a build is the
# TSV's commit label, which on a build with a selectable scheduler is `<commit>/<backend>` and is
# shown as WS (workstealing) or BASE (partr); any other build is shown by its version. When both WS
# and BASE are present a WS/BASE column of the medians' ratio follows. The nested digests are checked
# to be identical across series and rounds of one workload and n, as nested.jl --report does.
#
#   julia bench/tasks/aggregate_62285.jl <dir> [prefix]
#     reads <dir>/<prefix>{spawn,micro,nested}-r*.tsv; with prefix "validate-" the single-round
#     files validate-{spawn,micro,nested}.tsv

const SPAWN_COLS = ["julia", "commit", "threads", "guard", "variant", "round", "mode", "clients", "c", "h_ms",
                    "rps", "p50_ms", "p90_ms", "p99_ms", "max_ms", "count_min", "count_p1",
                    "count_median", "count_max", "jain", "slow1_spawn_to_start_pct", "slow1_end_to_wake_pct"]
const NESTED_COLS = ["julia", "commit", "threads", "guard", "variant", "round", "bench", "n", "cut",
                     "depth", "spawns", "runs", "wall_min_s", "wall_median_s", "alloc_mib_median",
                     "gc_ms_median", "gc_pct_median", "gc_pauses_median", "gc_full_median",
                     "hwm_mib_max", "peak_queued_median", "peak_live_median", "peak_heaps_median",
                     "peak_queued_max", "counted_wall_median_s", "digest"]

med(v) = (s = sort(v); n = length(s); isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)
fmt(x) = isnan(x) ? "–" : abs(x) >= 1000 ? replace(string(round(Int, x)), r"(?<=\d)(?=(\d{3})+$)" => ",") :
         abs(x) >= 100 || x == round(x) ? string(round(Int, x)) : string(round(x; sigdigits = 3))
cell(v) = isempty(v) ? "–" : length(v) == 1 ? fmt(v[1]) :
          string(fmt(med(v)), " [", fmt(minimum(v)), "–", fmt(maximum(v)), "]")
ratio(a, b) = (isempty(a) || isempty(b) || med(b) == 0) ? "–" : string(round(med(a) / med(b); digits = 2))

# The series name of a (julia, commit, variant).
function series(julia, commit, variant)
    build = endswith(commit, "/workstealing") ? "WS" : endswith(commit, "/partr") ? "BASE" : julia
    return variant == "A" && build in ("WS", "BASE") ? build : "$build $variant"
end
# A series order: WS, BASE, then the rest as met.
function order(names)
    first = filter(in(names), ["WS", "BASE"])
    return vcat(first, filter(!in(first), names))
end
wsbase(names) = "WS" in names && "BASE" in names

function readtsv(paths, cols)
    rows = Vector{Dict{String,String}}()
    for p in paths, l in eachline(p)
        isempty(l) && continue
        f = split(l, '\t')
        f[1] == cols[1] && continue
        length(f) == length(cols) || error("$p: $(length(f)) fields, $(length(cols)) expected: $l")
        push!(rows, Dict(zip(cols, f)))
    end
    return rows
end
num(r, k) = parse(Float64, r[k])

function header(names, extra)
    println("| ", join(extra, " | "), " | ", join(names, " | "), wsbase(names) ? " | WS/BASE |" : " |")
    println("|", repeat("---|", length(extra)), repeat("--:|", length(names) + (wsbase(names) ? 1 : 0)))
end

# ── spawn_order rows ──────────────────────────────────────────────────────────────────────
function spawn_tables(rows)
    isempty(rows) && return
    names = order(unique(series(r["julia"], r["commit"], r["variant"]) for r in rows))
    sel(r, k) = series(r["julia"], r["commit"], r["variant"]) == k
    layouts = unique(r["threads"] for r in rows)
    rounds = length(unique(r["round"] for r in rows))
    println("\n### spawn_order.jl, $rounds round(s), series: ", join(names, ", "), "\n")
    for metric in (("p99 ms", "p99_ms"), ("max ms", "max_ms"), ("slowest client (requests)", "count_min"),
                   ("Jain", "jain"), ("req/s", "rps"), ("p50 ms", "p50_ms"))
        println("\n**", metric[1], "**, median [min–max] over rounds\n")
        header(names, ["mode", "clients", "layout", "C", "H ms"])
        for mode in ("spawn", "pool"), cl in ("interactive", "default"), t in layouts,
            ch in unique((r["c"], r["h_ms"]) for r in rows)
            rs = filter(r -> r["mode"] == mode && r["clients"] == cl && r["threads"] == t &&
                             (r["c"], r["h_ms"]) == ch, rows)
            isempty(rs) && continue
            vals = Dict(k => [num(r, metric[2]) for r in rs if sel(r, k)] for k in names)
            print("| ", mode, " | ", cl, " | ", t, " | ", ch[1], " | ", ch[2], " | ",
                  join((cell(vals[k]) for k in names), " | "))
            println(wsbase(names) ? " | $(ratio(vals["WS"], vals["BASE"])) |" : " |")
        end
    end
end

# ── tasks.jl rows (round, julia, layout, variant, then the tasks.jl line) ─────────────────
function micro_tables(paths)
    recs = NamedTuple[]
    killed = String[]
    for p in paths, l in eachline(p)
        f = split(l, '\t')
        length(f) >= 7 || continue
        f[5] == "killed" && (push!(killed, "round $(f[1]) $(f[2]) $(f[3]) $(f[4]) $(f[7]) ($(f[8]))"); continue)
        kv = Dict(split(x, '=', limit = 2) for x in f[8:end] if occursin('=', x))
        build = get(kv, "build", f[2])
        push!(recs, (round = f[1], julia = f[2], threads = f[3], variant = f[4], kind = f[5], name = f[7],
                     series = series(f[2], build, f[4]), kv = kv))
    end
    isempty(recs) && return
    names = order(unique(r.series for r in recs))
    layouts = unique(r.threads for r in recs)
    println("\n### tasks.jl micro and queued rows, series: ", join(names, ", "), "\n")
    header(names, ["row", "unit", "layout"])
    for (name, key, unit) in (("SpawnWait", "ns_per_op", "ns/op"), ("PingPong", "ns_per_op", "ns/op"),
                              ("FanOut1000", "ns_per_task", "ns/task"), ("FanOut10000", "ns_per_task", "ns/task"),
                              ("Queued10000", "drain_ns_per_task", "drain ns/task"),
                              ("Queued100000", "drain_ns_per_task", "drain ns/task"),
                              ("Queued10000", "spawn_ns_per_task", "spawn ns/task"),
                              ("Queued100000", "spawn_ns_per_task", "spawn ns/task")), t in layouts
        rs = filter(r -> r.name == name && r.threads == t && haskey(r.kv, key), recs)
        isempty(rs) && continue
        vals = Dict(k => [parse(Float64, r.kv[key]) for r in rs if r.series == k] for k in names)
        print("| ", name, " | ", unit, " | ", t, " | ", join((cell(vals[k]) for k in names), " | "))
        println(wsbase(names) ? " | $(ratio(vals["WS"], vals["BASE"])) |" : " |")
    end
    isempty(killed) || println("\ntasks.jl processes killed by the timeout (their rows are missing above): ",
                               join(killed, "; "))
end

# ── nested rows ───────────────────────────────────────────────────────────────────────────
function nested_tables(rows)
    isempty(rows) && return
    killed = filter(r -> r["digest"] == "timeout", rows)
    rows = filter(r -> r["digest"] != "timeout", rows)
    for b in unique(r["bench"] for r in rows), n in unique(r["n"] for r in rows)
        ds = unique(r["digest"] for r in rows if r["bench"] == b && r["n"] == n)
        length(ds) <= 1 || error("$b (n $n) has digests $ds across series or rounds")
    end
    names = order(unique(series(r["julia"], r["commit"], r["variant"]) for r in rows))
    sel(r, k) = series(r["julia"], r["commit"], r["variant"]) == k
    layouts = unique(r["threads"] for r in rows)
    rounds = length(unique(r["round"] for r in rows))
    println("\n### nested.jl, $rounds round(s), series: ", join(names, ", "),
            "; digests identical across series and rounds for every workload\n")
    header(names, ["workload", "layout", "metric"])
    for b in unique(r["bench"] for r in rows), t in layouts
        any_row = findfirst(r -> r["bench"] == b && r["threads"] == t, rows)
        any_row === nothing && continue
        for (label, key) in (("wall s", "wall_median_s"), ("peak queued", "peak_queued_median"),
                             ("peak live", "peak_live_median"), ("peak in queues", "peak_heaps_median"),
                             ("GC %", "gc_pct_median"), ("alloc MiB", "alloc_mib_median"),
                             ("peak RSS MiB", "hwm_mib_max"), ("GC pauses", "gc_pauses_median"))
            vals = Dict(k => [num(r, key) for r in rows if r["bench"] == b && r["threads"] == t && sel(r, k)]
                        for k in names)
            all(isempty, values(vals)) && continue
            print("| ", b, " | ", t, " | ", label, " | ", join((cell(vals[k]) for k in names), " | "))
            println(wsbase(names) ? " | $(ratio(vals["WS"], vals["BASE"])) |" : " |")
        end
    end
    isempty(killed) || println("\nKilled by nested.sh's timeout: ",
        join(("$(r["commit"]) $(r["threads"]) $(r["variant"]) $(r["bench"]) round $(r["round"])" for r in killed), "; "))
end

function main(dir, prefix)
    files(kind) = sort(filter(f -> occursin(Regex("^" * prefix * kind * "(-r\\d+)?\\.tsv\$"), f), readdir(dir)))
    paths(kind) = joinpath.(dir, files(kind))
    println("Files: spawn ", files("spawn"), ", micro ", files("micro"), ", nested ", files("nested"))
    spawn_tables(readtsv(paths("spawn"), SPAWN_COLS))
    micro_tables(paths("micro"))
    nested_tables(readtsv(paths("nested"), NESTED_COLS))
end

main(ARGS[1], length(ARGS) >= 2 ? ARGS[2] : "")
