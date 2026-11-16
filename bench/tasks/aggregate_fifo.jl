# The Markdown tables of a rounds_fifo.sh results directory (#618, variants M and O): each value is
# the median over rounds with [min–max]. One build per directory, so a series is a variant (with
# `pool` under A as the fairness reference, shown as `pool`).
#
#   julia bench/tasks/aggregate_fifo.jl <dir>            # the rounds: <block>-*-r<N>.tsv
#   julia bench/tasks/aggregate_fifo.jl <dir> pilot      # the pilot, with its gate evaluated
#   julia bench/tasks/aggregate_fifo.jl <dir> markall    # the marked-fib_fine row
#   julia bench/tasks/aggregate_fifo.jl <dir> validate   # the validation pass's TSVs (not timings)

const SPAWN_COLS = ["julia", "commit", "threads", "guard", "variant", "round", "mode", "clients", "c", "h_ms",
                    "rps", "p50_ms", "p90_ms", "p99_ms", "max_ms", "count_min", "count_p1",
                    "count_median", "count_max", "jain", "slow1_spawn_to_start_pct", "slow1_end_to_wake_pct",
                    "shape", "hw_p50_ms", "hw_p99_ms", "hw_max_ms"]
const NESTED_COLS = ["julia", "commit", "threads", "guard", "variant", "round", "bench", "n", "cut",
                     "depth", "spawns", "runs", "wall_min_s", "wall_median_s", "alloc_mib_median",
                     "gc_ms_median", "gc_pct_median", "gc_pauses_median", "gc_full_median",
                     "hwm_mib_max", "peak_queued_median", "peak_live_median", "peak_heaps_median",
                     "peak_queued_max", "counted_wall_median_s", "digest"]
const ORDER = ["pool", "A", "A0", "C", "M-none", "M-f", "M-l", "M-h-f", "M-h-l", "O-f", "O-l"]

med(v) = (s = sort(v); n = length(s); isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)
fmt(x) = isnan(x) ? "–" : abs(x) >= 1000 ? replace(string(round(Int, x)), r"(?<=\d)(?=(\d{3})+$)" => ",") :
         abs(x) >= 100 || x == round(x) ? string(round(Int, x)) : string(round(x; sigdigits = 3))
cell(v) = isempty(v) ? "–" : length(v) == 1 ? fmt(v[1]) :
          string(fmt(med(v)), " [", fmt(minimum(v)), "–", fmt(maximum(v)), "]")
ratio(a, b) = (isempty(a) || isempty(b) || med(b) == 0) ? "–" : string(round(med(a) / med(b); digits = 2))
ratios(a, b) = (isempty(a) || isempty(b)) ? "–" :   # per-round ratios when the rounds pair up
    length(a) == length(b) ? cell(round.(a ./ b; digits = 2)) : ratio(a, b)
byorder(names) = sort(collect(names); by = n -> something(findfirst(==(n), ORDER), 99))

function readtsv(paths, cols)
    rows = Vector{Dict{String,String}}()
    for p in paths, l in eachline(p)
        isempty(l) && continue
        f = split(l, '\t')
        f[1] == cols[1] && continue
        length(f) >= length(cols) || error("$p: $(length(f)) fields, at least $(length(cols)) expected: $l")
        push!(rows, Dict(zip(cols, f)))
    end
    return rows
end
num(r, k) = parse(Float64, r[k])
series(r) = r["mode"] == "spawn" ? r["variant"] : r["mode"] * (r["variant"] == "A" ? "" : " " * r["variant"])
# Values of `key` per round for one series, ordered by round, so two series' values pair up by round.
vals(rs, s, key) = [num(r, key) for r in sort(filter(r -> series(r) == s, rs); by = r -> r["round"])]

# One table per (clients, layout, cell): a row per series.
function spawn_rows(rows, title)
    isempty(rows) && return
    rounds = length(unique(r["round"] for r in rows))
    println("\n### ", title, ", ", rounds, " round(s)\n")
    cells = unique((r["clients"], r["threads"], r["c"], r["h_ms"], r["shape"]) for r in rows)
    for (cl, t, c, h, shape) in cells
        rs = filter(r -> (r["clients"], r["threads"], r["c"], r["h_ms"], r["shape"]) == (cl, t, c, h, shape), rows)
        println("\n**clients on :", cl, ", --threads=", t, ", C = ", c, ", H = ", h, " ms, ", shape, "**\n")
        println("| variant | p99 ms | max ms | slowest client | Jain | p50 ms | req/s | req/s / A | slowest 1%: spawn→start | end→wake | handler wall p50 / p99 ms |")
        println("|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|")
        a = vals(rs, "A", "rps")
        for s in byorder(unique(series(r) for r in rs))
            v(k) = vals(rs, s, k)
            println("| ", s, " | ", cell(v("p99_ms")), " | ", cell(v("max_ms")), " | ", cell(v("count_min")), " | ",
                    cell(v("jain")), " | ", cell(v("p50_ms")), " | ", cell(v("rps")), " | ", ratios(v("rps"), a), " | ",
                    cell(v("slow1_spawn_to_start_pct")), "% | ", cell(v("slow1_end_to_wake_pct")), "% | ",
                    cell(v("hw_p50_ms")), " / ", cell(v("hw_p99_ms")), " |")
        end
    end
end

# The scheduler-bound cells: req/s, a column per variant and the ratios that matter.
function cost_rows(rows)
    isempty(rows) && return
    names = byorder(unique(series(r) for r in rows))
    println("\n### Scheduler-bound throughput (H = 0), req/s, ", length(unique(r["round"] for r in rows)), " round(s)\n")
    println("| clients | layout | clients C | ", join(names, " | "), " | M-none/A0 | M-f/A | M-l/A | O-f/A | C/A |")
    println("|---|---|--:|", repeat("--:|", length(names) + 5))
    for (cl, t, c) in unique((r["clients"], r["threads"], r["c"]) for r in rows)
        rs = filter(r -> (r["clients"], r["threads"], r["c"]) == (cl, t, c), rows)
        v(s) = vals(rs, s, "rps")
        println("| ", cl, " | ", t, " | ", c, " | ", join((cell(v(s)) for s in names), " | "), " | ",
                ratios(v("M-none"), v("A0")), " | ", ratios(v("M-f"), v("A")), " | ", ratios(v("M-l"), v("A")), " | ",
                ratios(v("O-f"), v("A")), " | ", ratios(v("C"), v("A")), " |")
    end
end

# tasks.jl rows (round, julia, layout, variant, then the tasks.jl line).
function micro_rows(paths)
    recs = NamedTuple[]
    for p in paths, l in eachline(p)
        f = split(l, '\t')
        length(f) >= 7 || continue
        kv = Dict(split(x, '=', limit = 2) for x in f[8:end] if occursin('=', x))
        push!(recs, (round = f[1], threads = f[3], variant = f[4], name = f[7], kv = kv))
    end
    isempty(recs) && return
    names = byorder(unique(r.variant for r in recs))
    println("\n### tasks.jl micro and queued rows\n")
    println("| row | unit | layout | ", join(names, " | "), " | M-none/A0 | M-f/A | O-f/A |")
    println("|---|---|---|", repeat("--:|", length(names) + 3))
    for (name, key, unit) in (("SpawnWait", "ns_per_op", "ns/op"), ("PingPong", "ns_per_op", "ns/op"),
                              ("FanOut1000", "ns_per_task", "ns/task"), ("FanOut10000", "ns_per_task", "ns/task"),
                              ("Queued10000", "drain_ns_per_task", "drain ns/task"),
                              ("Queued100000", "drain_ns_per_task", "drain ns/task")),
        t in unique(r.threads for r in recs)
        rs = sort(filter(r -> r.name == name && r.threads == t && haskey(r.kv, key), recs); by = r -> r.round)
        isempty(rs) && continue
        v(s) = [parse(Float64, r.kv[key]) for r in rs if r.variant == s]
        println("| ", name, " | ", unit, " | ", t, " | ", join((cell(v(s)) for s in names), " | "), " | ",
                ratios(v("M-none"), v("A0")), " | ", ratios(v("M-f"), v("A")), " | ", ratios(v("O-f"), v("A")), " |")
    end
end

function nested_rows(rows)
    isempty(rows) && return
    killed = filter(r -> r["digest"] == "timeout", rows)
    rows = filter(r -> r["digest"] != "timeout", rows)
    for b in unique(r["bench"] for r in rows), n in unique(r["n"] for r in rows)
        ds = unique(r["digest"] for r in rows if r["bench"] == b && r["n"] == n)
        length(ds) <= 1 || error("$b (n $n) has digests $ds across variants or rounds")
    end
    names = byorder(unique(r["variant"] for r in rows))
    println("\n### nested.jl, ", length(unique(r["round"] for r in rows)),
            " round(s); digests identical across variants and rounds for every workload\n")
    println("| workload | layout | metric | ", join(names, " | "), " | M-none/A | M-f/A | M-l/A | O-f/A | C/A |")
    println("|---|---|---|", repeat("--:|", length(names) + 5))
    for b in unique(r["bench"] for r in rows), t in unique(r["threads"] for r in rows)
        for (label, key) in (("wall s", "wall_median_s"), ("peak live", "peak_live_median"),
                             ("peak queued", "peak_queued_median"), ("peak in queues", "peak_heaps_median"),
                             ("GC %", "gc_pct_median"), ("alloc MiB", "alloc_mib_median"),
                             ("peak RSS MiB", "hwm_mib_max"))
            rs = sort(filter(r -> r["bench"] == b && r["threads"] == t, rows); by = r -> r["round"])
            isempty(rs) && continue
            v(s) = [num(r, key) for r in rs if r["variant"] == s]
            println("| ", b, " | ", t, " | ", label, " | ", join((cell(v(s)) for s in names), " | "), " | ",
                    ratios(v("M-none"), v("A")), " | ", ratios(v("M-f"), v("A")), " | ", ratios(v("M-l"), v("A")), " | ",
                    ratios(v("O-f"), v("A")), " | ", ratios(v("C"), v("A")), " |")
        end
    end
    isempty(killed) || println("\nKilled by nested.sh's timeout: ",
        join(("$(r["threads"]) $(r["variant"]) $(r["bench"]) round $(r["round"])" for r in killed), "; "))
end

# The pilot's gate: under at least one serve rule, M's p99 under 0.6 s with no client starved in
# both starved cells, and fib_fine under M (nothing marked) within 10% of A's wall with a peak of
# live tasks in A's class (taken as at most 1.5x A's).
function pilot_gate(spawn, nested)
    println("\n### Pilot gate\n")
    fib(v, k) = (r = filter(r -> r["variant"] == v && r["bench"] == "fib_fine", nested); isempty(r) ? NaN : num(r[1], k))
    awall, alive = fib("A", "wall_median_s"), fib("A", "peak_live_median")
    any_pass = false
    for v in ("M-f", "M-l")
        ok = true
        for cl in ("interactive", "default")
            r = filter(r -> r["variant"] == v && r["clients"] == cl && r["mode"] == "spawn", spawn)
            isempty(r) && (ok = false; println("- ", v, " :", cl, ": no row"); continue)
            p99, slow = num(r[1], "p99_ms"), num(r[1], "count_min")
            pass = p99 < 600 && slow > 0
            ok &= pass
            println("- ", v, ", clients on :", cl, ": p99 ", fmt(p99), " ms, slowest client ", fmt(slow), " → ",
                    pass ? "fair" : "NOT fair")
        end
        w, l = fib(v, "wall_median_s"), fib(v, "peak_live_median")
        pass = w <= 1.1 * awall && l <= 1.5 * alive
        ok &= pass
        println("- ", v, ", fib_fine: wall ", fmt(w), " s (", round(w / awall; digits = 2), "× A), peak live ",
                fmt(l), " (", round(l / alive; digits = 2), "× A) → ", pass ? "cheap" : "NOT cheap")
        println("- **", v, ": ", ok ? "passes" : "fails", "**")
        any_pass |= ok
    end
    for cl in ("interactive", "default")
        r = filter(r -> r["variant"] == "A" && r["clients"] == cl && r["mode"] == "spawn", spawn)
        isempty(r) || println("- negative control A, clients on :", cl, ": p99 ", fmt(num(r[1], "p99_ms")),
                              " ms, slowest client ", fmt(num(r[1], "count_min")),
                              num(r[1], "p99_ms") >= 2000 && num(r[1], "count_min") <= 1 ? " (starves, as it must)" :
                              " (DOES NOT STARVE: the harness is not telling fair from unfair)")
    end
    println("\n**Gate: ", any_pass ? "PASSES, go on to the rounds" : "FAILS under both serve rules: stop", "**")
end

function main(dir, what)
    ls = readdir(dir)
    pick(re) = joinpath.(dir, sort(filter(f -> occursin(re, f), ls)))
    if what == "pilot"
        spawn, nested = readtsv(pick(r"^pilot-spawn\.tsv$"), SPAWN_COLS), readtsv(pick(r"^pilot-nested\.tsv$"), NESTED_COLS)
        spawn_rows(spawn, "Pilot: the starved cell")
        nested_rows(nested)
        pilot_gate(spawn, nested)
    elseif what == "markall"
        nested_rows(readtsv(pick(r"^markall-nested\.tsv$"), NESTED_COLS))
    elseif what == "validate"
        cost_rows(readtsv(pick(r"^validate-cost-spawn\.tsv$"), SPAWN_COLS))
        spawn_rows(readtsv(pick(r"^validate-fairness-spawn\.tsv$"), SPAWN_COLS), "Validation cells (D = 1 s, not timings)")
        micro_rows(pick(r"^validate-micro\.tsv$"))
        nested_rows(readtsv(pick(r"^validate-nested\.tsv$"), NESTED_COLS))
    else
        cost_rows(readtsv(pick(r"^cost-spawn-r\d+\.tsv$"), SPAWN_COLS))
        micro_rows(pick(r"^micro-r\d+\.tsv$"))
        spawn_rows(readtsv(pick(r"^fairness-spawn-r\d+\.tsv$"), SPAWN_COLS), "Fairness: the starved cell")
        spawn_rows(readtsv(pick(r"^shapes-spawn-r\d+\.tsv$"), SPAWN_COLS), "Shapes")
        nested_rows(readtsv(pick(r"^nested-r\d+\.tsv$"), NESTED_COLS))
    end
end

main(ARGS[1], length(ARGS) >= 2 ? ARGS[2] : "rounds")
