# #618, reduced: does `Threads.@spawn` run runnable tasks in an order that lets some wait seconds
# while tasks spawned later run first, with no I/O and no HTTP.jl at all?
#
# The shape of #618's `bare_spawn`, minus the network. C client tasks, each a closed loop: stamp
# t0, start a handler, wait on the client's own autoreset `Base.Event`, stamp the wake. The handler
# stamps its start, computes H ms with server.jl's `burn` (a clock-read loop that never yields
# and never allocates), stamps its end and notifies the client. Every client loops until D seconds
# have passed since the cell started. All stamps are `time_ns()` in one process.
#
#   spawn     one plain `Threads.@spawn` per request, as `parallel_stream_handler` does from
#             HTTP.jl's connection task (it lands on `:default` from an `:interactive` caller)
#   pool      nthreads(:default) long-lived tasks on `:default` taking requests from one `Channel`,
#             FIFO by construction, as server.jl's `bare_pool`
#   sticky    as spawn, but each handler is a `Task` made by hand, `sticky`, pinned with
#             `jl_set_task_tid` to the next `:default` tid of one round-robin counter shared by every
#             client (the way `@threads :static` pins its tasks), then scheduled. A pinned sticky
#             task goes into that thread's `StickyWorkqueue`, a FIFO list, and `trypoptask` drains
#             that list before it touches the multiqueue: the handlers come out FIFO per thread and
#             ahead of anything in the heaps, with no stealing (a thread with a long queue cannot be
#             helped by an idle one). Nothing a handler spawns is sticky, so inner work keeps
#             stock's order in the multiqueue. The application-side half of what the #62285 ring
#             gives, with no runtime patch (`VARIANT=A`).
#   priority  as spawn, but the handler `Task` gets `priority = arrival sequence` before it is
#             scheduled, from one counter reset when the cell starts; everything else keeps the
#             default 0. The multiqueue is a min-heap on `priority`, so among queued handlers the
#             oldest comes out first ("priority before order"), and every task with priority 0,
#             inner work and woken clients included, comes out before any handler. `Task.priority`
#             is a `UInt16`, so the sequence wraps every 65,535 requests: a fairness cell of 8 s at
#             about 4,000 req/s (C = 500, H = 2 ms) makes about 32k requests and does not wrap, so
#             those cells show the order, not the wrap hazard; the H = 0 cost cells wrap many times
#             a second (3M req/s), and there a wrap puts the newest request ahead of every older
#             one for one window, so they show the cost, with the order kept inside a window only.
#             The sequence is taken modulo 65,535, never 65,535 itself: `typemax(UInt16)` is the
#             value `multiq_deletemin` reads as "this heap is empty". Gated by the P microbench
#             below: stock's `multiq_sift_down` is cheap only while every priority is equal.
#
# Handler shapes, selectable per cell (a third field in CELLS: `500:2:hetero`), for every mode:
#   plain     H ms of `burn`
#   hetero    one request in ten runs 10×H (per client: its k-th request when (k + i) % 10 == 0, i
#             the client's index, so the slow requests spread over clients and over arrival order).
#             The head-of-line cost of a FIFO without stealing: under sticky a queue behind a 20 ms
#             handler waits while other threads may idle.
#   inner     the handler spawns four non-sticky `:default` tasks of H/4 each and fetches them, a
#             small fork-join inside a request; it burns nothing itself. Besides the request
#             latency the cell reports the handler's own wall time, its start to its last fetch:
#             under sticky the children sit in the multiqueue behind every thread's sticky queue,
#             and the handler, woken by its last child, goes to the back of its own queue.
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
#   CELLS="500:2 500:2:hetero 500:2:inner" MODES="spawn sticky pool priority" julia ...
#   julia bench/tasks/spawn_order.jl --report results.tsv    # the Markdown tables of a TSV
#   julia --threads=8,1 bench/tasks/spawn_order.jl --prio-bench   # the P microbench alone
#
# Each measured cell prints one TSV line (header first, unless NOHEADER=1): the run's labels, then
# throughput, latency p50/p90/p99/max (ms), requests per client min/p1/median/max, Jain's index,
# for the slowest 1% of requests the share of their summed latency spent between the spawn (or the
# `put!`) and the handler's start, and between the handler's end and the client's wake; then the
# shape and the handler wall p50/p99/max (ms). The last four columns came with the shapes; a TSV
# written before them has 22 columns, and `--report` reads it as `plain`.
# `spawn_order.sh` runs it on several Julia versions and thread layouts behind `quiet.sh`;
# `rounds_sticky.sh` is the rounds driver of the sticky/priority comparison.
#
# The P microbench (`--prio-bench`, and run before the cells whenever MODES has `priority`): the
# single-heap drain of multiq_variant.jl on the build's own `taskheap`, 1,000 and 10,000 tasks,
# with equal priorities (stock's case), with distinct increasing priorities (the arrival sequence)
# and with distinct random priorities; ns per pop, best of 3. Gate: if distinct priorities cost
# more than PRIO_GATE (10)× equal ones at 10,000, the priority cells are skipped and the numbers
# are reported, since `multiq_sift_down` swaps with every smaller child in turn and recurses into
# each, which with distinct keys walks the heap.
#
# VARIANT=A|A0|B|C|D<K>|D-inf|E<K>|E-inf picks the multiqueue order (multiq_variant.jl, included
# first, before any task exists): stock, stock recompiled, `<=` in `multiq_sift_down`, FIFO among
# equal priorities, FIFO behind a LIFO slot per `:default` thread with a budget of K pops in a row,
# or stock's order with every K-th pop taking the oldest task instead of the newest. The priority
# mode runs under A only (its heap is the build's own).
# VALIDATE=1 is the instrumented check to run before timing a variant: single-heap order asserts,
# every handler accounted for, the new code reached on every `:default` thread, and how far each
# handler's start ran behind its spawn, counted in handlers (its start ordinal minus its spawn
# ordinal); under D also the slot probe, the slot counts of each cell (slot pops required with
# `:default` clients) and empty slots at exit; under E the check_empty probes, the pop counts of
# each cell (periodic pops on every `:default` thread, none under E-inf) and empty deques at exit.
# With the modes here also: the handler count per `:default` tid in every mode; under sticky every
# handler ran on its assigned tid, was still there at its end, the per-tid counts are within 10%
# of each other, and the depth of the queue each handler joined is reported (p50/p90/p99/max, and
# the deepest per tid: equal shares of the arrivals do not make equal queues when the threads do
# not serve at the same rate); under priority every handler started with the priority it was
# given; under inner every child ran, non-sticky, on `:default`.
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
    h::Float64           # this request's burn, ms (hetero: 10×H one time in ten)
    t_start::UInt64
    t_end::UInt64
    sink::Float64
    spawn_ord::Int   # VALIDATE only, as are the fields below
    start_ord::Int
    atid::Int16      # sticky: the tid the handler was pinned to
    rtid::Int16      # the tid the handler started on
    prio::UInt16     # priority: the priority the handler was given
    depth::Int32     # sticky: handlers pinned to that tid and not yet started, at the pin
    Slot() = new(Base.Event(true), 0.0, 0, 0, 0.0, 0, 0, 0, 0, 0, 0)   # autoreset: one notify, one wake
end

const SPAWNED = Threads.Atomic{Int}(0)
const STARTED = Threads.Atomic{Int}(0)
const HANDLED = Threads.Atomic{Int}(0)
const TID_BAD = Threads.Atomic{Int}(0)       # sticky: started on a tid other than the assigned one
const TID_MOVED = Threads.Atomic{Int}(0)     # ended on a tid other than the one it started on
const PRIO_BAD = Threads.Atomic{Int}(0)      # priority: started with a priority other than the one set
const INNER_RUN = Threads.Atomic{Int}(0)     # inner: children that ran
const INNER_BAD = Threads.Atomic{Int}(0)     # inner: children that ran sticky, or off `:default`

# sticky: the `:default` tids and the shared round-robin counter; priority: the arrival sequence.
# Both counters are reset when a cell starts.
const DEFAULT_TIDS = Threads.threadpooltids(:default)
const RR = Threads.Atomic{Int}(0)
const SEQ = Threads.Atomic{Int}(0)
# VALIDATE only, sticky: per tid, the handlers pinned to it and not yet started (its queue depth).
const DEPTH = [Threads.Atomic{Int}(0) for _ in 1:Threads.maxthreadid()]
const PRIO_MOD = Int(typemax(UInt16))   # 0..65534; typemax itself means "empty heap" to multiq_deletemin
const PRIO_GATE = parse(Float64, get(ENV, "PRIO_GATE", "10"))

const M_SPAWN, M_STICKY, M_PRIORITY = 1, 2, 3
const MODE_CODE = Dict("spawn" => M_SPAWN, "sticky" => M_STICKY, "priority" => M_PRIORITY)

# Per client: latency, spawn -> start, end -> wake, handler wall, all in ns.
struct Rec
    lat::Vector{Int64}
    s2s::Vector{Int64}
    e2w::Vector{Int64}
    hw::Vector{Int64}
    lag::Vector{Int64}   # VALIDATE only: start ordinal minus spawn ordinal
    tid::Vector{Int16}   # VALIDATE only: the tid the handler started on
    depth::Vector{Int32} # VALIDATE only, sticky: the assigned tid's queue depth at the pin
    Rec() = new(sizehint!(Int64[], 4096), sizehint!(Int64[], 4096), sizehint!(Int64[], 4096),
                sizehint!(Int64[], 4096), Int64[], Int16[], Int32[])
end

@inline function stamp_spawn!(slot::Slot)
    VALIDATE && (slot.spawn_ord = Threads.atomic_add!(SPAWNED, 1))
    return nothing
end

# inner's children: H/4 of burn each, non-sticky, on `:default` whatever the handler's thread.
function inner_child(q::Float64)
    if VALIDATE
        Threads.atomic_add!(INNER_RUN, 1)
        (current_task().sticky || Threads.threadpool() !== :default) && Threads.atomic_add!(INNER_BAD, 1)
    end
    return burn(q)
end

function handle!(slot::Slot, inner::Bool)
    if VALIDATE
        slot.start_ord = Threads.atomic_add!(STARTED, 1)
        slot.rtid = Threads.threadid()
        slot.atid != 0 && slot.rtid != slot.atid && Threads.atomic_add!(TID_BAD, 1)
        slot.atid != 0 && Threads.atomic_sub!(DEPTH[slot.atid], 1)
        slot.prio != current_task().priority && Threads.atomic_add!(PRIO_BAD, 1)
    end
    slot.t_start = time_ns()
    if inner
        q = slot.h / 4
        t1 = Threads.@spawn :default inner_child(q)
        t2 = Threads.@spawn :default inner_child(q)
        t3 = Threads.@spawn :default inner_child(q)
        t4 = Threads.@spawn :default inner_child(q)
        slot.sink += fetch(t1) + fetch(t2) + fetch(t3) + fetch(t4)
    else
        slot.sink += burn(slot.h)
    end
    slot.t_end = time_ns()
    if VALIDATE
        Threads.threadid() != slot.rtid && Threads.atomic_add!(TID_MOVED, 1)
        Threads.atomic_add!(HANDLED, 1)
    end
    notify(slot.ev)
    return nothing
end

function record!(rec::Rec, slot::Slot, t0::UInt64, t1::UInt64)
    push!(rec.lat, Int64(t1 - t0))
    push!(rec.s2s, Int64(slot.t_start - t0))
    push!(rec.e2w, Int64(t1 - slot.t_end))
    push!(rec.hw, Int64(slot.t_end - slot.t_start))
    if VALIDATE
        push!(rec.lag, slot.start_ord - slot.spawn_ord)
        push!(rec.tid, slot.rtid)
        push!(rec.depth, slot.depth)
    end
    return nothing
end

# A handler task made by hand, on `:default`, the way `Threads.@spawn :default` makes one, before
# it is pinned or given a priority.
function handler_task(slot::Slot, inner::Bool)
    t = Task(() -> handle!(slot, inner))
    t.sticky = false
    ccall(:jl_set_task_threadpoolid, Cint, (Any, Int8), t, Threads._sym_to_tpid(:default)) == 1 ||
        error("could not put the handler task on :default")
    return t
end

# sticky: `@threads :static`'s pinning (base/threadingconstructs.jl `threading_run`), to the next
# `:default` tid round-robin. The task is not started, so `jl_set_task_tid` always succeeds.
function spawn_sticky!(slot::Slot, inner::Bool)
    t = handler_task(slot, inner)
    t.sticky = true
    tid = DEFAULT_TIDS[mod1(Threads.atomic_add!(RR, 1) + 1, length(DEFAULT_TIDS))]
    ccall(:jl_set_task_tid, Cint, (Any, Cint), t, tid - 1) == 1 || error("could not pin the handler to tid $tid")
    if VALIDATE
        slot.atid = tid
        slot.depth = Threads.atomic_add!(DEPTH[tid], 1)
    end
    schedule(t)
    return t
end

# priority: the arrival sequence as the task's priority, never typemax(UInt16).
function spawn_priority!(slot::Slot, inner::Bool)
    t = handler_task(slot, inner)
    t.priority = UInt16(Threads.atomic_add!(SEQ, 1) % PRIO_MOD)
    VALIDATE && (slot.prio = t.priority)
    schedule(t)
    return t
end

@inline request_h(h::Float64, hetero::Bool, k::Int, i::Int) = hetero && (k + i) % 10 == 0 ? 10h : h

function client_spawn(slot::Slot, rec::Rec, deadline::UInt64, h::Float64, mode::Int, hetero::Bool,
                      inner::Bool, i::Int)
    k = 0
    while time_ns() < deadline
        k += 1
        slot.h = request_h(h, hetero, k, i)
        t0 = time_ns()
        stamp_spawn!(slot)
        if mode == M_SPAWN
            Threads.@spawn handle!(slot, inner)
        elseif mode == M_STICKY
            spawn_sticky!(slot, inner)
        else
            spawn_priority!(slot, inner)
        end
        wait(slot.ev)
        record!(rec, slot, t0, time_ns())
    end
end

function client_pool(slot::Slot, rec::Rec, deadline::UInt64, h::Float64, jobs::Channel{Slot}, hetero::Bool,
                     i::Int)
    k = 0
    while time_ns() < deadline
        k += 1
        slot.h = request_h(h, hetero, k, i)
        t0 = time_ns()
        stamp_spawn!(slot)
        put!(jobs, slot)
        wait(slot.ev)
        record!(rec, slot, t0, time_ns())
    end
end

# One cell: C clients for D seconds. Returns the per-client records and the wall time.
function run_cell(mode::String, clients::Symbol, c::Int, h::Float64, d::Float64, shape::String = "plain")
    shape in ("plain", "hetero", "inner") || error("unknown shape $shape")
    hetero, inner = shape == "hetero", shape == "inner"
    mode == "priority" && MULTIQ_VARIANT != "A" && error("the priority mode runs on the build's own heap only (VARIANT=A)")
    slots = [Slot() for _ in 1:c]
    recs = [Rec() for _ in 1:c]
    jobs = Channel{Slot}(Inf)
    workers = Task[]
    if mode == "pool"
        for _ in 1:Threads.nthreads(:default)
            worker = Threads.@spawn :default for slot in jobs
                handle!(slot, inner)
            end
            push!(workers, worker)
        end
    end
    RR[] = 0
    SEQ[] = 0
    GC.gc()
    start = time_ns()
    deadline = start + round(UInt64, d * 1e9)
    tasks = if mode == "pool"
        clients === :interactive ?
            [Threads.@spawn :interactive client_pool(slots[i], recs[i], deadline, h, jobs, hetero, i) for i in 1:c] :
            [Threads.@spawn :default client_pool(slots[i], recs[i], deadline, h, jobs, hetero, i) for i in 1:c]
    else
        m = MODE_CODE[mode]
        clients === :interactive ?
            [Threads.@spawn :interactive client_spawn(slots[i], recs[i], deadline, h, m, hetero, inner, i) for i in 1:c] :
            [Threads.@spawn :default client_spawn(slots[i], recs[i], deadline, h, m, hetero, inner, i) for i in 1:c]
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
    hw = sort!(reduce(vcat, (r.hw for r in recs)))
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
            e2w_share = round(100 * sum(e2w[slow]) / slow_lat; digits = 1),
            hw_p50 = ms(q(hw, 0.5)), hw_p99 = ms(q(hw, 0.99)), hw_max = ms(hw[end]))
end

const COLUMNS = ["julia", "commit", "threads", "guard", "variant", "round", "mode", "clients", "c", "h_ms",
                 "rps", "p50_ms", "p90_ms", "p99_ms", "max_ms", "count_min", "count_p1",
                 "count_median", "count_max", "jain", "slow1_spawn_to_start_pct",
                 "slow1_end_to_wake_pct", "shape", "hw_p50_ms", "hw_p99_ms", "hw_max_ms"]

# The P microbench and its gate: true when the priority cells may run.
function prio_gate()
    r = priority_drain_bench()
    r === nothing && (println(stderr, "prio gate: no stock heap to bench (variant ", MULTIQ_VARIANT,
                                      ", backend ", MULTIQ_BACKEND, "); priority cells skipped"); return false)
    ratio = r.increasing[2] / r.equal[2]
    ok = ratio <= PRIO_GATE
    println(stderr, "prio gate: distinct increasing priorities cost ", round(ratio; digits = 1),
            "× equal ones at 10,000 (gate ", PRIO_GATE, "×): priority cells ", ok ? "run" : "skipped")
    return ok
end

# A cell spec: "C:H" or "C:H:shape".
function parse_cells(spec::AbstractString)
    cells = Tuple{Int,Float64,String}[]
    for s in split(spec)
        f = split(s, ':')
        2 <= length(f) <= 3 || error("cell $s: expected C:H or C:H:shape")
        push!(cells, (parse(Int, f[1]), parse(Float64, f[2]), length(f) == 3 ? String(f[3]) : "plain"))
    end
    return cells
end

function measure()
    d = parse(Float64, get(ENV, "D", "8"))
    cs = parse.(Int, split(get(ENV, "CS", "50 500")))
    hs = parse.(Float64, split(get(ENV, "HS", "0 2")))
    modes = String.(split(get(ENV, "MODES", "spawn pool")))
    clients = Symbol.(split(get(ENV, "CLIENTS", "interactive default")))
    Threads.nthreads(:interactive) == 0 && filter!(!=(:interactive), clients)
    labels = (string(VERSION), MULTIQ_BUILD,
              string(Threads.nthreads(:default), ",", Threads.nthreads(:interactive)),
              GUARD_TIMER === nothing ? "0" : "1", MULTIQ_VARIANT, get(ENV, "ROUND", "1"))
    handler_pool = fetch(Threads.@spawn :interactive fetch(Threads.@spawn Threads.threadpool()))
    println(stderr, "spawn_order: julia ", VERSION, " (", Base.GIT_VERSION_INFO.commit_short, " ",
            Base.GIT_VERSION_INFO.date_string, "), threads ", labels[3], ", guard ", labels[4],
            ", a plain @spawn from :interactive lands on :", handler_pool, ", :default tids ", DEFAULT_TIDS,
            ", D = ", d, " s, variant ", MULTIQ_VARIANT)
    VALIDATE && multiq_unit_asserts()
    if "priority" in modes && !prio_gate()
        filter!(!=("priority"), modes)
    end
    # Compile every path before measuring; the warm-up cells are not reported.
    for mode in modes, cl in clients, shape in ("plain", "hetero", "inner")
        run_cell(mode, cl, 8, 0.1, 0.2, shape)
    end
    get(ENV, "NOHEADER", "0") == "1" || println(join(COLUMNS, '\t'))
    cells = haskey(ENV, "CELLS") ? parse_cells(ENV["CELLS"]) : [(c, h, "plain") for c in cs for h in hs]
    for mode in modes, cl in clients, (c, h, shape) in cells
        if VALIDATE
            HANDLED[] = 0; TID_BAD[] = 0; TID_MOVED[] = 0; PRIO_BAD[] = 0; INNER_RUN[] = 0; INNER_BAD[] = 0
        end
        slots0 = multiq_slot_counts()
        budget0 = multiq_budget_counts()
        multiq_watchdog(ceil(Int, d) + 60)
        recs, wall = run_cell(mode, cl, c, h, d, shape)
        multiq_watchdog(0)
        m = metrics(recs, wall)
        println(join((labels..., mode, cl, c, h, m.rps, m.p50, m.p90, m.p99, m.max, m.cmin, m.cp1, m.cmed,
                      m.cmax, m.jain, m.s2s_share, m.e2w_share, shape, m.hw_p50, m.hw_p99, m.hw_max), '\t'))
        flush(stdout)
        VALIDATE && validate_cell(recs, mode, cl, c, h, shape)
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

# Every handler accounted for, how far starts ran behind spawns, the handler count per `:default`
# tid, and the mode's own invariants: sticky ran where it was pinned and evenly, priority started
# with its priority, inner's children all ran non-sticky on `:default`.
function validate_cell(recs::Vector{Rec}, mode::String, cl::Symbol, c::Int, h::Float64, shape::String)
    n = sum(r -> length(r.lat), recs)
    n == HANDLED[] || error("validate: $n requests recorded, $(HANDLED[]) handled")
    all(r -> length(r.lag) == length(r.lat) == length(r.tid), recs) || error("validate: an ordinal is missing")
    lag = sort!(reduce(vcat, (r.lag for r in recs)))
    tids = reduce(vcat, (r.tid for r in recs))
    per_tid = [count(==(t), tids) for t in DEFAULT_TIDS]
    off = count(!in(DEFAULT_TIDS), tids)
    off == 0 || error("validate: $off handlers started outside the :default tids")
    label = "$MULTIQ_VARIANT $mode/$cl C=$c H=$h $shape"
    println(stderr, "validate: ", label, ": ", n, " requests, all handled; start ordinal minus spawn ordinal: p50 ",
            q(lag, 0.5), ", p99 ", q(lag, 0.99), ", max ", lag[end], "; handlers per :default tid ", per_tid,
            "; ended on another tid: ", TID_MOVED[])
    if mode == "sticky"
        TID_BAD[] == 0 || error("validate: sticky: $(TID_BAD[]) handlers started on a tid other than the assigned one")
        TID_MOVED[] == 0 || error("validate: sticky: $(TID_MOVED[]) handlers ended on a tid other than the one they started on")
        lo, hi = extrema(per_tid)
        hi <= 1.1 * lo || error("validate: sticky: handlers per tid $per_tid are not within 10% of each other")
        # The queue each handler joined: how deep, overall and at its deepest per tid. Equal shares of
        # the arrivals do not make equal queues when the threads do not serve at the same rate.
        depth = reduce(vcat, (r.depth for r in recs))
        deepest = [maximum(depth[tids .== t]; init = 0) for t in DEFAULT_TIDS]
        sd = sort(depth)
        println(stderr, "validate: ", label, ": sticky queue depth at the pin: p50 ", q(sd, 0.5), ", p90 ",
                q(sd, 0.9), ", p99 ", q(sd, 0.99), ", max ", sd[end], "; deepest per :default tid ", deepest)
    end
    if mode == "priority"
        PRIO_BAD[] == 0 || error("validate: priority: $(PRIO_BAD[]) handlers started with a priority other than the one set")
    end
    if shape == "inner"
        INNER_RUN[] == 4n || error("validate: inner: $(INNER_RUN[]) children ran for $n requests")
        INNER_BAD[] == 0 || error("validate: inner: $(INNER_BAD[]) children ran sticky or off :default")
        println(stderr, "validate: ", label, ": ", INNER_RUN[], " children ran, all non-sticky on :default")
    end
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
# over the rounds with [min–max]. A 22-column TSV from before the shapes reads as `plain`.
function report(path::String)
    rows = [split(l, '\t') for l in eachline(path) if !isempty(l) && !startswith(l, "julia\t")]
    col(name) = findfirst(==(name), COLUMNS)
    get_(r, name) = (i = col(name); i <= length(r) ? r[i] : name == "shape" ? "plain" : "NaN")
    num(r, name) = parse(Float64, get_(r, name))
    med(v) = (s = sort(v); n = length(s); isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)
    fmt(x) = x >= 1000 ? string(round(Int, x)) : string(round(x; sigdigits = 3))
    cell(v) = length(v) == 1 ? fmt(v[1]) : string(fmt(med(v)), " [", fmt(minimum(v)), "–", fmt(maximum(v)), "]")
    key(r) = (r[col("julia")], r[col("commit")], r[col("threads")], r[col("variant")])
    ckey(r) = (r[col("mode")], r[col("clients")], r[col("c")], r[col("h_ms")], get_(r, "shape"))
    groups = unique(key(r) for r in rows)
    for g in groups
        grows = filter(r -> key(r) == g, rows)
        cells = unique(ckey(r) for r in grows)
        println("\n**Julia ", g[1], " (", g[2], "), --threads=", g[3], ", variant ", g[4], "**, ",
                length(unique(r[col("round")] for r in grows)), " rounds\n")
        println("| mode | clients | C | H ms | shape | req/s | p50 ms | p90 ms | p99 ms | max ms | per client: min / p1 / median / max | Jain | slowest 1%: spawn→start | slowest 1%: end→wake | handler wall p50 / p99 / max ms |")
        println("|---|---|--:|--:|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|")
        for k in cells
            rs = filter(r -> ckey(r) == k, grows)
            v(name) = [num(r, name) for r in rs]
            println("| ", join(k, " | "), " | ", cell(v("rps")), " | ", cell(v("p50_ms")), " | ",
                    cell(v("p90_ms")), " | ", cell(v("p99_ms")), " | ", cell(v("max_ms")), " | ",
                    fmt(med(v("count_min"))), " / ", fmt(med(v("count_p1"))), " / ",
                    fmt(med(v("count_median"))), " / ", fmt(med(v("count_max"))), " | ",
                    cell(v("jain")), " | ", cell(v("slow1_spawn_to_start_pct")), "% | ",
                    cell(v("slow1_end_to_wake_pct")), "% | ", cell(v("hw_p50_ms")), " / ",
                    cell(v("hw_p99_ms")), " / ", cell(v("hw_max_ms")), " |")
        end
    end
end

if length(ARGS) >= 2 && ARGS[1] == "--report"
    report(ARGS[2])
elseif length(ARGS) >= 1 && ARGS[1] == "--prio-bench"
    priority_drain_bench() === nothing && println(stderr, "prio bench: no stock heap to bench (variant ",
                                                  MULTIQ_VARIANT, ", backend ", MULTIQ_BACKEND, ")")
else
    measure()
end
