# The Markdown tables of a rounds_fifo.sh results directory (#618, variants M and O): each value is
# the median over rounds with [min–max]. One build per directory, so a series is a variant (with
# `pool` under A as the fairness reference, shown as `pool`).
#
#   julia bench/tasks/aggregate_fifo.jl <dir>            # the rounds: <block>-*-r<N>.tsv
#   julia bench/tasks/aggregate_fifo.jl <dir> pilot      # the pilot, with its gate evaluated
#   julia bench/tasks/aggregate_fifo.jl <dir> sharepilot # PROFILE=share: the share pilot and its gate
#   julia bench/tasks/aggregate_fifo.jl <dir> markall    # the marked-fib_fine row
#   julia bench/tasks/aggregate_fifo.jl <dir> mixed      # the mixed cell (mixed_cell.jl): mixed-r<N>.tsv
#   julia bench/tasks/aggregate_fifo.jl <dir> halfmix    # the half-pool mixed cell: halfmix-r<N>.tsv
#   julia bench/tasks/aggregate_fifo.jl <dir> validate   # the validation pass's TSVs (not timings)
#   julia bench/tasks/aggregate_fifo.jl <dir> q1         # PROFILE=rings: Q1's timed sweep round
#   julia bench/tasks/aggregate_fifo.jl <dir> sweep      # PROFILE=rings: the sweep rounds (H = 0 by layout)
#   julia bench/tasks/aggregate_fifo.jl <dir> mixedinner # PROFILE=inherit: the mixed-inner cell, mixedinner-r<N>.tsv
#   julia bench/tasks/aggregate_fifo.jl <dir> inheritpilot # PROFILE=inherit: the pilot and its gate
#   julia bench/tasks/aggregate_fifo.jl <dir> markroot   # PROFILE=inherit: fib_fine under one marked root
#   julia bench/tasks/aggregate_fifo.jl <dir> step0b     # PROFILE=inherit: the own-ring insert's timing
#   julia bench/tasks/aggregate_fifo.jl <dir> age        # PROFILE=inherit: the age sweep
#   julia bench/tasks/aggregate_fifo.jl <dir> inheritpilot # PROFILE=gc: the pilot and its gate, as above
#   julia bench/tasks/aggregate_fifo.jl <dir> pool       # PROFILE=gc: the Channel worker pool, pool-r<N>.tsv
#   julia bench/tasks/aggregate_fifo.jl <dir> credit     # PROFILE=gc: credited against run, from validate.log

const SPAWN_COLS = ["julia", "commit", "threads", "guard", "variant", "round", "mode", "clients", "c", "h_ms",
                    "rps", "p50_ms", "p90_ms", "p99_ms", "max_ms", "count_min", "count_p1",
                    "count_median", "count_max", "jain", "slow1_spawn_to_start_pct", "slow1_end_to_wake_pct",
                    "shape", "hw_p50_ms", "hw_p99_ms", "hw_max_ms"]
const NESTED_COLS = ["julia", "commit", "threads", "guard", "variant", "round", "bench", "n", "cut",
                     "depth", "spawns", "runs", "wall_min_s", "wall_median_s", "alloc_mib_median",
                     "gc_ms_median", "gc_pct_median", "gc_pauses_median", "gc_full_median",
                     "hwm_mib_max", "peak_queued_median", "peak_live_median", "peak_heaps_median",
                     "peak_queued_max", "counted_wall_median_s", "digest"]
const MIXED_COLS = ["julia", "commit", "threads", "guard", "variant", "round", "c", "h_ms", "d_s",
                    "rps", "p50_ms", "p99_ms", "max_ms", "count_min", "count_median", "jain",
                    "slow1_spawn_to_start_pct", "slow1_end_to_wake_pct",
                    "fib_alone_median_s", "fib_alone_min_s", "fib_alone_max_s",
                    "fib_runs", "fib_median_s", "fib_min_s", "fib_max_s", "fib_walls_s"]
# mixed_cell.jl SHAPE=inner (2026-11-16) appends the shape and the handler wall p50/p99.
const MIXED_INNER_COLS = [MIXED_COLS; "shape"; "hw_p50_ms"; "hw_p99_ms"]
const ORDER = ["pool", "A", "A0", "C", "M-none", "M-f", "M-l", "M-l-r2", "M-l-r2o", "M-l-r4", "M-t", "M-t0", "M-p2", "M-p16",
               "M-p128", "M-p1024", "M-t-r2", "M-t0-r2", "M-il-r2", "M-it-r2", "M-g-r2", "M-g25-r2", "M-g75-r2",
               "M-g0-r2", "M-gc-r2", "M-gc25-r2", "M-gc75-r2", "M-a10-r2", "M-a100-r2", "M-a1000-r2", "M-h-f",
               "M-h-l", "M-h-l-r2", "M-h-l-r4", "M-h-t", "M-h-g-r2", "M-h-gc-r2", "O-f", "O-l"]
# The ratio columns a table shows: the pairs among these whose both series are in it.
const RATIO_PAIRS = [("M-none", "A0"), ("M-f", "A"), ("M-l", "A"), ("M-l-r2", "A"), ("M-l-r4", "A"),
                     ("M-l-r2", "M-l"), ("M-l-r4", "M-l"), ("M-t", "A"), ("M-t", "M-l"), ("O-f", "A"), ("C", "A"),
                     ("M-l-r2o", "M-l-r2"), ("M-g-r2", "A"), ("M-g-r2", "M-l-r2"), ("M-il-r2", "A"),
                     ("M-gc-r2", "A"), ("M-gc-r2", "M-g-r2")]
pairs_in(names; base_none = "A0") = [(a == "M-none" ? (a, base_none) : (a, b)) for (a, b) in RATIO_PAIRS
                                     if a in names && (a == "M-none" ? base_none : b) in names]
pair_heads(ps) = join(("$a/$b" for (a, b) in ps), " | ")

med(v) = (s = sort(v); n = length(s); isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)
fmt(x) = !isfinite(x) ? "–" : abs(x) >= 1000 ? replace(string(round(Int, x)), r"(?<=\d)(?=(\d{3})+$)" => ",") :
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
    ps = pairs_in(names)
    println("| clients | layout | clients C | ", join(names, " | "), " | ", pair_heads(ps), " |")
    println("|---|---|--:|", repeat("--:|", length(names) + length(ps)))
    for (cl, t, c) in unique((r["clients"], r["threads"], r["c"]) for r in rows)
        rs = filter(r -> (r["clients"], r["threads"], r["c"]) == (cl, t, c), rows)
        v(s) = vals(rs, s, "rps")
        println("| ", cl, " | ", t, " | ", c, " | ", join((cell(v(s)) for s in names), " | "), " | ",
                join((ratios(v(a), v(b)) for (a, b) in ps), " | "), " |")
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
    ps = pairs_in(names)
    println("| row | unit | layout | ", join(names, " | "), " | ", pair_heads(ps), " |")
    println("|---|---|---|", repeat("--:|", length(names) + length(ps)))
    for (name, key, unit) in (("SpawnWait", "ns_per_op", "ns/op"), ("PingPong", "ns_per_op", "ns/op"),
                              ("FanOut1000", "ns_per_task", "ns/task"), ("FanOut10000", "ns_per_task", "ns/task"),
                              ("Queued10000", "drain_ns_per_task", "drain ns/task"),
                              ("Queued100000", "drain_ns_per_task", "drain ns/task")),
        t in unique(r.threads for r in recs)
        rs = sort(filter(r -> r.name == name && r.threads == t && haskey(r.kv, key), recs); by = r -> r.round)
        isempty(rs) && continue
        v(s) = [parse(Float64, r.kv[key]) for r in rs if r.variant == s]
        println("| ", name, " | ", unit, " | ", t, " | ", join((cell(v(s)) for s in names), " | "), " | ",
                join((ratios(v(a), v(b)) for (a, b) in ps), " | "), " |")
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
    ps = pairs_in(names; base_none = "A")
    println("| workload | layout | metric | ", join(names, " | "), " | ", pair_heads(ps), " |")
    println("|---|---|---|", repeat("--:|", length(names) + length(ps)))
    for b in unique(r["bench"] for r in rows), t in unique(r["threads"] for r in rows)
        for (label, key) in (("wall s", "wall_median_s"), ("peak live", "peak_live_median"),
                             ("peak queued", "peak_queued_median"), ("peak in queues", "peak_heaps_median"),
                             ("GC %", "gc_pct_median"), ("alloc MiB", "alloc_mib_median"),
                             ("peak RSS MiB", "hwm_mib_max"))
            rs = sort(filter(r -> r["bench"] == b && r["threads"] == t, rows); by = r -> r["round"])
            isempty(rs) && continue
            v(s) = [num(r, key) for r in rs if r["variant"] == s]
            println("| ", b, " | ", t, " | ", label, " | ", join((cell(v(s)) for s in names), " | "), " | ",
                    join((ratios(v(a), v(b)) for (a, b) in ps), " | "), " |")
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

# The mixed cell: the requests, and fib_fine's wall per run during the cell against the same
# process's wall alone (every run of every round pooled for the per-run ratio).
function mixed_rows(rows; half = false, inner = false)
    isempty(rows) && return
    rounds = length(unique(r["round"] for r in rows))
    if inner
        println("\n### The mixed-inner cell: the mixed cell with the inner shape (each handler spawns four `:default` ",
                "children of H/4 and fetches them; clients on :interactive, 8,1, C = 500, H = 2 ms, D = 8 s), ",
                "fib_fine looping on :default, ", rounds, " round(s)\n")
    elseif half   # the fib_* columns are the four loops' runs (400 chunks of sfib(24) each)
        println("\n### The half-pool mixed cell: C = 4 clients on :interactive, 8,1, H = 2 ms, D = 8 s, ",
                "beside 4 unmarked loops on :default (fib_fine columns: the loops' runs), ", rounds, " round(s)\n")
    else
        println("\n### The mixed cell: the starved cell (clients on :interactive, 8,1, C = 500, H = 2 ms, D = 8 s) ",
                "with fib_fine looping on :default, ", rounds, " round(s)\n")
    end
    println("| variant | p99 ms | max ms | slowest client | Jain | req/s | slowest 1%: spawn→start | fib_fine alone s | fib_fine runs in the cell | fib_fine per run s | per run / alone |",
            inner ? " handler wall p50 / p99 ms |" : "")
    println("|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|", inner ? "--:|" : "")
    for v in byorder(unique(r["variant"] for r in rows))
        rs = sort(filter(r -> r["variant"] == v, rows); by = r -> r["round"])
        x(k) = [num(r, k) for r in rs]
        per = Float64[]; rel = Float64[]
        for r in rs
            w = isempty(r["fib_walls_s"]) ? Float64[] : parse.(Float64, split(r["fib_walls_s"], ','))
            append!(per, w); append!(rel, w ./ num(r, "fib_alone_median_s"))
        end
        println("| ", v, " | ", cell(x("p99_ms")), " | ", cell(x("max_ms")), " | ", cell(x("count_min")), " | ",
                cell(x("jain")), " | ", cell(x("rps")), " | ", cell(x("slow1_spawn_to_start_pct")), "% | ",
                cell(x("fib_alone_median_s")), " | ", join(Int.(x("fib_runs")), ", "), " | ", cell(per), " | ",
                cell(round.(rel; digits = 2)), " |",
                inner ? string(" ", cell(x("hw_p50_ms")), " / ", cell(x("hw_p99_ms")), " |") : "")
    end
    println("\nPer run, every round: ", join((string(r["variant"], " r", r["round"], ": ", r["fib_walls_s"], " (alone ",
                                                     r["fib_alone_median_s"], ")") for r in rows), "; "))
end

# The share pilot's gate (PROFILE=share): M-t passes when, in the mixed cell, the requests' p99 is
# under 0.6 s with no client starved and fib_fine per run is under 2.5x its standalone wall (median
# of the runs in the cell over the same process's median alone). M-l must starve the requests
# there (under 200 req/s), or the cell does not tell a share from strict precedence.
function share_gate(mixed)
    println("\n### Share pilot gate\n")
    row(v) = (r = filter(r -> r["variant"] == v, mixed); isempty(r) ? nothing : r[1])
    function fibratio(r)
        w = isempty(r["fib_walls_s"]) ? Float64[] : parse.(Float64, split(r["fib_walls_s"], ','))
        isempty(w) ? NaN : med(w) / num(r, "fib_alone_median_s")
    end
    l = row("M-l")
    control = l !== nothing && num(l, "rps") < 200
    l === nothing || println("- control M-l: ", fmt(num(l, "rps")), " req/s → ",
                             control ? "starves the requests, as it must" : "DOES NOT STARVE: the cell tells nothing")
    t = row("M-t")
    pass = false
    if t !== nothing
        p99, slow, fr = num(t, "p99_ms"), num(t, "count_min"), fibratio(t)
        pass = control && p99 < 600 && slow > 0 && fr < 2.5
        println("- M-t: p99 ", fmt(p99), " ms (limit 600), slowest client ", fmt(slow), ", fib_fine ",
                round(fr; digits = 2), "× alone (limit 2.5)")
    end
    a = row("A")
    a === nothing || println("- A: p99 ", fmt(num(a, "p99_ms")), " ms, fib_fine ", round(fibratio(a); digits = 2), "× alone")
    println("\n**Gate: ", pass ? "PASSES, go on to the rounds" : "FAILS: run the M-pK sweep once, then write it up", "**")
end

# The classes' pilot gate (PROFILE=inherit): per variant, the three cells' limits. mixed and
# mixed-inner: requests' p99 under 0.6 s, no client starved, fib_fine per run under 2.5x alone
# (median of the runs in the cell over the same process's median alone); inner: p99 under 0.2 s.
function inherit_gate(spawn, mixed, mixedinner)
    println("\n### Inherit pilot gate\n")
    function fibratio(r)
        w = isempty(r["fib_walls_s"]) ? Float64[] : parse.(Float64, split(r["fib_walls_s"], ','))
        isempty(w) ? NaN : med(w) / num(r, "fib_alone_median_s")
    end
    one(rows, v) = (r = filter(r -> r["variant"] == v && get(r, "mode", "spawn") == "spawn", rows); isempty(r) ? nothing : r[1])
    function mix_ok(r)
        r === nothing && return (false, "–")
        p99, slow, fr = num(r, "p99_ms"), num(r, "count_min"), fibratio(r)
        return (p99 < 600 && slow > 0 && fr < 2.5, string(fmt(p99), " ms · ", fmt(slow), " · ", round(fr; digits = 2), "×"))
    end
    println("| variant | inner p99 ms (< 200) | mixed p99 · slowest · fib (< 600, > 0, < 2.5×) | mixed-inner p99 · slowest · fib | passes |")
    println("|---|--:|--:|--:|---|")
    for v in byorder(unique(r["variant"] for r in mixed))
        i = one(spawn, v)
        iok = i !== nothing && num(i, "p99_ms") < 200
        mok, mtxt = mix_ok(one(mixed, v))
        xok, xtxt = mix_ok(one(mixedinner, v))
        println("| ", v, " | ", i === nothing ? "–" : fmt(num(i, "p99_ms")), " | ", mtxt, " | ", xtxt, " | ",
                iok && mok && xok ? "**all three**" : join([c for (c, ok) in (("inner", iok), ("mixed", mok), ("mixed-inner", xok)) if !ok], ", ", " and ") * " fail", " |")
    end
end

# PROFILE=gc's pool block (agent-config #82 Idea 8): the Channel worker pool at H = 0, nothing marked.
# Per cell, req/s of every variant, each as a ratio to A, and A's range as a share of its median (the
# prompt's rule: 5 rounds if that exceeds 10% in the 8,1, C = 500 cell).
function pool_rows(rows)
    isempty(rows) && return
    rows = [merge(r, Dict("mode" => "spawn")) for r in rows]   # a series per variant
    names = byorder(unique(series(r) for r in rows))
    println("\n### The Channel worker pool (H = 0, nothing marked), req/s, ", length(unique(r["round"] for r in rows)), " round(s)\n")
    others = filter(!=("A"), names)
    println("| clients | layout | C | ", join(names, " | "), " | A's range / median | ", join(("$n/A" for n in others), " | "), " |")
    println("|---|---|--:|", repeat("--:|", length(names) + 1 + length(others)))
    for (cl, t, c) in unique((r["clients"], r["threads"], r["c"]) for r in rows)
        rs = filter(r -> (r["clients"], r["threads"], r["c"]) == (cl, t, c), rows)
        v(s) = vals(rs, s, "rps")
        a = v("A")
        spread = isempty(a) ? "–" : string(round(100 * (maximum(a) - minimum(a)) / med(a); digits = 1), "%")
        println("| ", cl, " | ", t, " | ", c, " | ", join((cell(v(s)) for s in names), " | "), " | ", spread, " | ",
                join((ratios(v(n), a) for n in others), " | "), " |")
    end
end

# The validation pass's credited-against-run lines (`validate: credit-run, <label> (<variant>): k=v ...`
# from multiq_share_check under -g) in <dir>/validate.log: per cell and variant, the time the share
# credited each side while both had work against the time each side actually ran (a clock read at
# every pop), and the part of it that started at a two-sided pop.
function credit_rows(log)
    isfile(log) || return println("credit: no ", log)
    recs = NamedTuple[]
    for l in eachline(log)
        m = match(r"^validate: credit-run, (.*) \(([^()]+)\): (.*)$", l)
        m === nothing && continue
        kv = Dict(split(x, '=', limit = 2) for x in split(m[3]))
        push!(recs, (label = String(m[1]), variant = String(m[2]), kv = kv))
    end
    isempty(recs) && return println("credit: no credit-run lines in ", log)
    println("\n### Credited against run, per cell (VALIDATE, -g variants)\n")
    println("| cell | layout | variant | credited R / L ms (R part) | run R / L ms (R part) | run from two-sided R / L ms (R part) | pops R / L |")
    println("|---|---|---|---|---|---|---|")
    for r in sort(recs; by = r -> (r.label, r.kv["threads"], something(findfirst(==(r.variant), ORDER), 99)))
        k = r.kv
        println("| ", r.label, " | ", k["threads"], " | ", r.variant, " | ", k["credited_r_ms"], " / ", k["credited_l_ms"],
                " (", k["credited_r_pct"], "%) | ", k["run_r_ms"], " / ", k["run_l_ms"], " (", k["run_r_pct"], "%) | ",
                k["run2_r_ms"], " / ", k["run2_l_ms"], " (", k["run2_r_pct"], "%) | ", k["pops_r"], " / ", k["pops_l"], " |")
    end
end

function main(dir, what)
    ls = readdir(dir)
    pick(re) = joinpath.(dir, sort(filter(f -> occursin(re, f), ls)))
    if what == "sharepilot"
        spawn_rows(readtsv(pick(r"^pilot-spawn\.tsv$"), SPAWN_COLS), "Share pilot: the starved cell")
        mixed = readtsv(pick(r"^pilot-mixed\.tsv$"), MIXED_COLS)
        mixed_rows(mixed)
        share_gate(mixed)
    elseif what == "pilot"
        spawn, nested = readtsv(pick(r"^pilot-spawn\.tsv$"), SPAWN_COLS), readtsv(pick(r"^pilot-nested\.tsv$"), NESTED_COLS)
        spawn_rows(spawn, "Pilot: the starved cell")
        nested_rows(nested)
        pilot_gate(spawn, nested)
    elseif what == "mixed"
        mixed_rows(readtsv(pick(r"^mixed-r\d+\.tsv$"), MIXED_COLS))
    elseif what == "halfmix"   # C = 4 beside 4 loops: the fib_* columns are the loops' runs
        mixed_rows(readtsv(pick(r"^halfmix-r\d+\.tsv$"), MIXED_COLS); half = true)
    elseif what == "q1"        # the rings run's Q1: one timed sweep round (H = 0, :default clients)
        cost_rows(readtsv(pick(r"^q1-sweep\.tsv$"), SPAWN_COLS))
    elseif what == "sweep"     # the sweep rounds
        cost_rows(readtsv(pick(r"^sweep-r\d+\.tsv$"), SPAWN_COLS))
    elseif what == "mixedinner"
        mixed_rows(readtsv(pick(r"^mixedinner-r\d+\.tsv$"), MIXED_INNER_COLS); inner = true)
    elseif what == "inheritpilot"
        spawn = readtsv(pick(r"^pilot-spawn\.tsv$"), SPAWN_COLS)
        mixed = readtsv(pick(r"^pilot-mixed\.tsv$"), MIXED_COLS)
        mixedinner = readtsv(pick(r"^pilot-mixedinner\.tsv$"), MIXED_INNER_COLS)
        spawn_rows(spawn, "Inherit pilot: the inner shape")
        mixed_rows(mixed)
        mixed_rows(mixedinner; inner = true)
        inherit_gate(spawn, mixed, mixedinner)
    elseif what == "markroot"
        nested_rows(readtsv(pick(r"^markroot-r\d+\.tsv$"), NESTED_COLS))
    elseif what == "step0b"
        cost_rows(readtsv(pick(r"^step0b-sweep\.tsv$"), SPAWN_COLS))
        spawn_rows(readtsv(pick(r"^step0b-fairness\.tsv$"), SPAWN_COLS), "Step 0: the starved cells, own-ring insert")
    elseif what == "age"
        mixed_rows(readtsv(pick(r"^age-mixed\.tsv$"), MIXED_COLS))
        spawn_rows(readtsv(pick(r"^age-spawn\.tsv$"), SPAWN_COLS), "Age sweep: the inner shape")
    elseif what == "markall"
        nested_rows(readtsv(pick(r"^markall-nested\.tsv$"), NESTED_COLS))
    elseif what == "pool"      # PROFILE=gc: the Channel worker pool rounds
        pool_rows(readtsv(pick(r"^pool-r\d+\.tsv$"), SPAWN_COLS))
    elseif what == "credit"    # PROFILE=gc: credited against run, from the validation pass
        credit_rows(joinpath(dir, "validate.log"))
    elseif what == "validate"
        cost_rows(readtsv(pick(r"^validate-cost-spawn\.tsv$"), SPAWN_COLS))
        spawn_rows(readtsv(pick(r"^validate-fairness-spawn\.tsv$"), SPAWN_COLS), "Validation cells (D = 1 s, not timings)")
        micro_rows(pick(r"^validate-micro\.tsv$"))
        nested_rows(readtsv(pick(r"^validate-nested\.tsv$"), NESTED_COLS))
        mixed_rows(readtsv(pick(r"^validate-mixed\.tsv$"), MIXED_COLS))
        mixed_rows(readtsv(pick(r"^validate-mixedinner\.tsv$"), MIXED_INNER_COLS); inner = true)
        nested_rows(readtsv(pick(r"^validate-markroot\.tsv$"), NESTED_COLS))
    else
        cost_rows(readtsv(pick(r"^cost-spawn-r\d+\.tsv$"), SPAWN_COLS))
        micro_rows(pick(r"^micro-r\d+\.tsv$"))
        spawn_rows(readtsv(pick(r"^fairness-spawn-r\d+\.tsv$"), SPAWN_COLS), "Fairness: the starved cell")
        spawn_rows(readtsv(pick(r"^shapes-spawn-r\d+\.tsv$"), SPAWN_COLS), "Shapes")
        nested_rows(readtsv(pick(r"^nested-r\d+\.tsv$"), NESTED_COLS))
    end
end

main(ARGS[1], length(ARGS) >= 2 ? ARGS[2] : "rounds")
