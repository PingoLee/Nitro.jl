# #618, reduced: does `Threads.@spawn` run runnable tasks in an order that lets some wait seconds
# while tasks spawned later run first, with no I/O and no HTTP.jl at all?
#
# The shape of #618's `bare_spawn`, minus the network. C client tasks, each a closed loop: stamp
# t0, start a handler, wait on the client's own autoreset `Base.Event`, stamp the wake. The handler
# stamps its start, computes H ms with server.jl's `burn` (a clock-read loop that never yields
# and never allocates), stamps its end and notifies the client. Every client loops until D seconds
# have passed since the cell started. All stamps are `time_ns()` in one process.
#
#   spawn  one plain `Threads.@spawn` per request, as `parallel_stream_handler` does from HTTP.jl's
#          connection task (it lands on `:default` from an `:interactive` caller)
#   pool   nthreads(:default) long-lived tasks on `:default` taking requests from one `Channel`,
#          FIFO by construction, as server.jl's `bare_pool`
#
# Clients run on `:interactive`, where HTTP.jl runs its connection tasks, or on `:default`. With no
# interactive thread (`--threads=8,0`) only `default` runs, which is where HTTP.jl's connection
# tasks run in that layout.
#
# GUARD=1 (the default) holds one never-firing `Timer` for the process's life, waited on by nobody.
# Every #618 server held one: `serve()`'s wake guard on 1.13.x (#598) and server.jl's main task,
# parked on a `Timer` in every mode. On 1.13.0-rc3..1.13.2 a process without any live timer can
# miss wake-ups (JuliaLang/julia#63882), which would be a different bug from this one. Nothing in
# this file waits on a `Timer`.
#
#   julia --threads=8,1 bench/tasks/spawn_order.jl           # one round of every cell, TSV on stdout
#   D=8 CS="50 500" HS="0 2" MODES="spawn pool" CLIENTS="interactive default" ROUND=1 julia ...
#   CELLS="50:0 500:0 500:2" julia ...                      # (C, H ms) pairs instead of CS × HS
#   julia bench/tasks/spawn_order.jl --report results.tsv    # the Markdown tables of a TSV
#
# Each measured cell prints one TSV line (header first, unless NOHEADER=1): the run's labels, then
# throughput, latency p50/p90/p99/max (ms), requests per client min/p1/median/max, Jain's index,
# and for the slowest 1% of requests the share of their summed latency spent between the spawn
# (or the `put!`) and the handler's start, and between the handler's end and the client's wake.
# `spawn_order.sh` runs it on several Julia versions and thread layouts behind `quiet.sh`.
#
# VARIANT=A|A0|B|C|D<K>|D-inf|E<K>|E-inf picks the multiqueue order (multiq_variant.jl, included
# first, before any task exists): stock, stock recompiled, `<=` in `multiq_sift_down`, FIFO among
# equal priorities, FIFO behind a LIFO slot per `:default` thread with a budget of K pops in a row,
# or stock's order with every K-th pop taking the oldest task instead of the newest.
# VALIDATE=1 is the instrumented check to run before timing a variant: single-heap order asserts,
# every handler accounted for, the new code reached on every `:default` thread, and how far each
# handler's start ran behind its spawn, counted in handlers (its start ordinal minus its spawn
# ordinal); under D also the slot probe, the slot counts of each cell (slot pops required with
# `:default` clients) and empty slots at exit; under E the check_empty probes, the pop counts of
# each cell (periodic pops on every `:default` thread, none under E-inf) and empty deques at exit.
# Each validated cell runs under `multiq_watchdog`.
# Use a small cell: `VALIDATE=1 D=1 CS=50 HS=0.2 VARIANT=C julia ...`.

include(joinpath(@__DIR__, "multiq_variant.jl"))
const VALIDATE = MULTIQ_VALIDATE

const GUARD_TIMER = get(ENV, "GUARD", "1") == "1" ? Timer(typemax(Int32)) : nothing

# server.jl's `burn`, verbatim: `GC.safepoint()` lets a collection proceed, but it is not a yield
# point, so the handler holds its thread for the whole H ms.
function burn(ms::Float64)::Float64
    deadline = time_ns() + round(UInt64, ms * 1e6)
    x = 0.0
    while time_ns() < deadline
        x = sin(x + 1.0)
        GC.safepoint()
    end
    return x
end

mutable struct Slot
    const ev::Base.Event
    t_start::UInt64
    t_end::UInt64
    sink::Float64
    spawn_ord::Int   # VALIDATE only, as are the ordinals below
    start_ord::Int
    Slot() = new(Base.Event(true), 0, 0, 0.0, 0, 0)   # autoreset: one notify, one wake
end

const SPAWNED = Threads.Atomic{Int}(0)
const STARTED = Threads.Atomic{Int}(0)
const HANDLED = Threads.Atomic{Int}(0)

# Per client: latency, spawn -> start, end -> wake, all in ns.
struct Rec
    lat::Vector{Int64}
    s2s::Vector{Int64}
    e2w::Vector{Int64}
    lag::Vector{Int64}   # VALIDATE only: start ordinal minus spawn ordinal
    Rec() = new(sizehint!(Int64[], 4096), sizehint!(Int64[], 4096), sizehint!(Int64[], 4096), Int64[])
end

@inline function stamp_spawn!(slot::Slot)
    VALIDATE && (slot.spawn_ord = Threads.atomic_add!(SPAWNED, 1))
    return nothing
end

function handle!(slot::Slot, h::Float64)
    VALIDATE && (slot.start_ord = Threads.atomic_add!(STARTED, 1))
    slot.t_start = time_ns()
    slot.sink += burn(h)
    slot.t_end = time_ns()
    VALIDATE && Threads.atomic_add!(HANDLED, 1)
    notify(slot.ev)
    return nothing
end

function record!(rec::Rec, slot::Slot, t0::UInt64, t1::UInt64)
    push!(rec.lat, Int64(t1 - t0))
    push!(rec.s2s, Int64(slot.t_start - t0))
    push!(rec.e2w, Int64(t1 - slot.t_end))
    VALIDATE && push!(rec.lag, slot.start_ord - slot.spawn_ord)
    return nothing
end

function client_spawn(slot::Slot, rec::Rec, deadline::UInt64, h::Float64)
    while time_ns() < deadline
        t0 = time_ns()
        stamp_spawn!(slot)
        Threads.@spawn handle!(slot, h)
        wait(slot.ev)
        record!(rec, slot, t0, time_ns())
    end
end

function client_pool(slot::Slot, rec::Rec, deadline::UInt64, jobs::Channel{Slot})
    while time_ns() < deadline
        t0 = time_ns()
        stamp_spawn!(slot)
        put!(jobs, slot)
        wait(slot.ev)
        record!(rec, slot, t0, time_ns())
    end
end

# One cell: C clients for D seconds. Returns the per-client records and the wall time.
function run_cell(mode::String, clients::Symbol, c::Int, h::Float64, d::Float64)
    slots = [Slot() for _ in 1:c]
    recs = [Rec() for _ in 1:c]
    jobs = Channel{Slot}(Inf)
    workers = Task[]
    if mode == "pool"
        for _ in 1:Threads.nthreads(:default)
            worker = Threads.@spawn :default for slot in jobs
                handle!(slot, h)
            end
            push!(workers, worker)
        end
    end
    GC.gc()
    start = time_ns()
    deadline = start + round(UInt64, d * 1e9)
    tasks = if clients === :interactive
        mode == "spawn" ?
            [Threads.@spawn :interactive client_spawn(slots[i], recs[i], deadline, h) for i in 1:c] :
            [Threads.@spawn :interactive client_pool(slots[i], recs[i], deadline, jobs) for i in 1:c]
    else
        mode == "spawn" ?
            [Threads.@spawn :default client_spawn(slots[i], recs[i], deadline, h) for i in 1:c] :
            [Threads.@spawn :default client_pool(slots[i], recs[i], deadline, jobs) for i in 1:c]
    end
    foreach(wait, tasks)
    wall = (time_ns() - start) / 1e9
    close(jobs)
    foreach(wait, workers)
    return recs, wall
end

q(v, p) = isempty(v) ? NaN : v[clamp(ceil(Int, p * length(v)), 1, length(v))]   # v sorted

function metrics(recs::Vector{Rec}, wall::Float64)
    lat = reduce(vcat, (r.lat for r in recs))
    s2s = reduce(vcat, (r.s2s for r in recs))
    e2w = reduce(vcat, (r.e2w for r in recs))
    counts = sort!([length(r.lat) for r in recs])
    order = sortperm(lat)
    sorted = lat[order]
    cut = q(sorted, 0.99)
    slow = findall(>=(cut), lat)
    slow_lat = sum(lat[slow])
    jain = sum(counts)^2 / (length(counts) * sum(abs2, counts))
    ms(x) = round(x / 1e6; sigdigits = 4)
    return (rps = round(Int, length(lat) / wall), p50 = ms(q(sorted, 0.5)), p90 = ms(q(sorted, 0.9)),
            p99 = ms(cut), max = ms(sorted[end]),
            cmin = counts[1], cp1 = q(counts, 0.01), cmed = q(counts, 0.5), cmax = counts[end],
            jain = round(jain; digits = 3),
            s2s_share = round(100 * sum(s2s[slow]) / slow_lat; digits = 1),
            e2w_share = round(100 * sum(e2w[slow]) / slow_lat; digits = 1))
end

const COLUMNS = ["julia", "commit", "threads", "guard", "variant", "round", "mode", "clients", "c", "h_ms",
                 "rps", "p50_ms", "p90_ms", "p99_ms", "max_ms", "count_min", "count_p1",
                 "count_median", "count_max", "jain", "slow1_spawn_to_start_pct",
                 "slow1_end_to_wake_pct"]

function measure()
    d = parse(Float64, get(ENV, "D", "8"))
    cs = parse.(Int, split(get(ENV, "CS", "50 500")))
    hs = parse.(Float64, split(get(ENV, "HS", "0 2")))
    modes = split(get(ENV, "MODES", "spawn pool"))
    clients = Symbol.(split(get(ENV, "CLIENTS", "interactive default")))
    Threads.nthreads(:interactive) == 0 && filter!(!=(:interactive), clients)
    labels = (string(VERSION), Base.GIT_VERSION_INFO.commit_short,
              string(Threads.nthreads(:default), ",", Threads.nthreads(:interactive)),
              GUARD_TIMER === nothing ? "0" : "1", MULTIQ_VARIANT, get(ENV, "ROUND", "1"))
    handler_pool = fetch(Threads.@spawn :interactive fetch(Threads.@spawn Threads.threadpool()))
    println(stderr, "spawn_order: julia ", VERSION, " (", Base.GIT_VERSION_INFO.commit_short, " ",
            Base.GIT_VERSION_INFO.date_string, "), threads ", labels[3], ", guard ", labels[4],
            ", a plain @spawn from :interactive lands on :", handler_pool, ", D = ", d, " s, variant ",
            MULTIQ_VARIANT)
    VALIDATE && multiq_unit_asserts()
    # Compile every path before measuring; the warm-up cells are not reported.
    for mode in modes, cl in clients
        run_cell(String(mode), cl, 8, 0.1, 0.2)
    end
    get(ENV, "NOHEADER", "0") == "1" || println(join(COLUMNS, '\t'))
    cells = haskey(ENV, "CELLS") ?
        [(parse(Int, a), parse(Float64, b)) for (a, b) in split.(split(ENV["CELLS"]), ':')] :
        [(c, h) for c in cs for h in hs]
    for mode in modes, cl in clients, (c, h) in cells
        VALIDATE && (HANDLED[] = 0)
        slots0 = multiq_slot_counts()
        budget0 = multiq_budget_counts()
        multiq_watchdog(ceil(Int, d) + 60)
        recs, wall = run_cell(String(mode), cl, c, h, d)
        multiq_watchdog(0)
        m = metrics(recs, wall)
        println(join((labels..., mode, cl, c, h, values(m)...), '\t'))
        flush(stdout)
        VALIDATE && validate_cell(recs, String(mode), cl, c, h)
        # Under D a `:default` client spawns or wakes its handler from a `:default` thread: the slot.
        VALIDATE && multiq_slot_check("$mode/$cl C=$c H=$h", slots0; pops = cl === :default)
        # Under E every `:default` thread pops handlers (spawn) or client wake-ups (`:default`
        # clients), so each makes periodic pops; `pool` with `:interactive` clients only wakes the
        # 8 workers from `take!`, so there some thread must.
        VALIDATE && multiq_budget_check("$mode/$cl C=$c H=$h", budget0;
                                        everywhere = mode == "spawn" || cl === :default)
    end
    VALIDATE && validate_threads()
    multiq_variant_check()
end

# Every handler accounted for, and how far starts ran behind spawns.
function validate_cell(recs::Vector{Rec}, mode::String, cl::Symbol, c::Int, h::Float64)
    n = sum(r -> length(r.lat), recs)
    n == HANDLED[] || error("validate: $n requests recorded, $(HANDLED[]) handled")
    all(r -> length(r.lag) == length(r.lat), recs) || error("validate: an ordinal is missing")
    lag = sort!(reduce(vcat, (r.lag for r in recs)))
    println(stderr, "validate: ", MULTIQ_VARIANT, " ", mode, "/", cl, " C=", c, " H=", h, ": ", n,
            " requests, all handled; start ordinal minus spawn ordinal: p50 ", q(lag, 0.5),
            ", p99 ", q(lag, 0.99), ", max ", lag[end])
end

# The redefined scheduler ran on every `:default` thread (none to check for A).
function validate_threads()
    MULTIQ_VARIANT == "A" && return
    calls = multiq_variant_calls()
    tids = Threads.threadpooltids(:default)
    all(tid -> calls[tid] > 0, tids) || error("validate: no calls into the new code on some :default tid: ", calls[tids])
    println(stderr, "validate: calls into the new code per :default tid ", calls[tids])
end

# `--report <tsv>`: one Markdown table per (julia, threads), one row per cell, each value the median
# over the rounds with [min–max].
function report(path::String)
    rows = [split(l, '\t') for l in eachline(path) if !isempty(l) && !startswith(l, "julia\t")]
    col(name) = findfirst(==(name), COLUMNS)
    num(r, name) = parse(Float64, r[col(name)])
    med(v) = (s = sort(v); n = length(s); isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)
    fmt(x) = x >= 1000 ? string(round(Int, x)) : string(round(x; sigdigits = 3))
    cell(v) = length(v) == 1 ? fmt(v[1]) : string(fmt(med(v)), " [", fmt(minimum(v)), "–", fmt(maximum(v)), "]")
    key(r) = (r[col("julia")], r[col("commit")], r[col("threads")], r[col("variant")])
    groups = unique(key(r) for r in rows)
    for g in groups
        grows = filter(r -> key(r) == g, rows)
        cells = unique((r[col("mode")], r[col("clients")], r[col("c")], r[col("h_ms")]) for r in grows)
        println("\n**Julia ", g[1], " (", g[2], "), --threads=", g[3], ", variant ", g[4], "**, ",
                length(unique(r[col("round")] for r in grows)), " rounds\n")
        println("| mode | clients | C | H ms | req/s | p50 ms | p90 ms | p99 ms | max ms | per client: min / p1 / median / max | Jain | slowest 1%: spawn→start | slowest 1%: end→wake |")
        println("|---|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|")
        for k in cells
            rs = filter(r -> (r[col("mode")], r[col("clients")], r[col("c")], r[col("h_ms")]) == k, grows)
            v(name) = [num(r, name) for r in rs]
            println("| ", join(k, " | "), " | ", cell(v("rps")), " | ", cell(v("p50_ms")), " | ",
                    cell(v("p90_ms")), " | ", cell(v("p99_ms")), " | ", cell(v("max_ms")), " | ",
                    fmt(med(v("count_min"))), " / ", fmt(med(v("count_p1"))), " / ",
                    fmt(med(v("count_median"))), " / ", fmt(med(v("count_max"))), " | ",
                    cell(v("jain")), " | ", cell(v("slow1_spawn_to_start_pct")), "% | ",
                    cell(v("slow1_end_to_wake_pct")), "% |")
        end
    end
end

if length(ARGS) >= 2 && ARGS[1] == "--report"
    report(ARGS[2])
else
    measure()
end
