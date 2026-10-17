# Socket-level throughput target (#448, #453). Unlike the rest of `bench/`, which drives the
# pipeline in-process through `internalrequest`, this serves over a real loopback socket so the
# transport layer -- the per-request spawn, the request build, the response write and HTTP.jl's
# connection loop -- is part of what is measured. `run.sh` drives it with `oha`.
#
#   MODE=nitro          Nitro `serve()` with no middleware (the default).
#   MODE=nitro_log      The same with `access_log = true`, `serve()`'s own default (#443), so the
#                       log's cost can be A/B'd against `nitro` in one interleaved run.
#   MODE=bare_spawn     HTTP.jl `listen!` + `streamhandler`, one `Threads.@spawn` per request:
#                       the shape Nitro's `parallel_stream_handler` takes, and the ceiling to
#                       compare it against.
#   MODE=bare_nospawn   The same without the spawn: the handler runs on HTTP.jl's connection task.
#   MODE=bare_pool      `bare_spawn` with the per-request spawn replaced by POOL long-lived tasks on
#                       `:default` (default `nthreads(:default)`), fed by a channel (#468): is
#                       CREATING a task per request a material cost, or is a pool no cheaper?
#
#   POOL=<n>            bare_pool only: how many pooled handler tasks.
#   PORT=8080           Loopback port.
#   ACCESS_LOG=0|1      Nitro only: `serve(access_log = …)`. Default 0.
#   PROFILE=<seconds>   After WARMUP seconds, sample every thread for this long and write three
#                       reports under bench/results/: `-flat` (all threads), `-threads` (flat,
#                       grouped by thread) and `-interactive-tree` (a call tree of the
#                       `:interactive` threads only, C frames included, headed by the window's GC
#                       time -- where HTTP.jl accepts, parses every request head and wakes the
#                       per-request task, #462). 0 (the default) disables it.
#   WARMUP=<seconds>    Delay before the profile window opens. Default 8.
#   CPU_MS=50           What `/cpu` burns: a loop that never yields, holding its thread for this many
#                       milliseconds (#491: does a CPU-bound handler starve `/health`?).
#                       `/cpu_yield` burns the same but calls `yield()` every YIELD_MS (default 2),
#                       the cooperative mitigation #467 measures.
#   WORKERS=0|1         Nitro only: also serve `/burst?n=K`, which submits K Workers jobs that each
#                       burn JOB_MS (default 500) without yielding, on a `WorkerRuntime` of its own.
#                       `&queue=1` submits them to a queue of concurrency BURST_K instead of all at
#                       once, and `&cp=MS` makes each job call `checkpoint!` every MS ms (#513).
#                       `/cpu_job` submits ONE job of CPU_MS to that queue and answers 202 at once:
#                       `/cpu`'s work moved off the request path (#467). `/jobs` answers how many
#                       `/cpu_job` jobs are submitted and not yet finished, so a script can drain.
#   BURST_K=<k>         Nitro only: that queue's concurrency. Default `nthreads(:default) - 2`, at
#                       least 1. The queue buffers 100, so a queued burst above 100 is refused.
#   LAG=0|1             Start the `/lag` probe (off by default, so a throughput run carries no extra
#                       task). Without it `/lag` answers `{"n":0}`.
#   LOGIN=0|1           Nitro only: also serve `/login` and `/login_bcrypt`, which each verify one
#                       password with `Nitro.Auth.check_password` against a hash minted at startup at
#                       the default cost (pbkdf2_sha256, and bcrypt) and answer a fixed `ok` (#587):
#                       the computing handler every app has, for `stall.sh`'s `login` variants.
#                       PASSWORD_CONCURRENCY=<n> passes `n` to `set_password_concurrency!` (#587;
#                       `0` is unbounded); unset keeps Nitro's default.
#   AGG_ROWS=<n>        Build `n` aggregation rows at startup (default 0: none, so `rss.sh` counts
#                       nothing) and serve `/aggregate?n=<N>&op=<sum|mean|groupby>` over the first N
#                       of them (#590), in every mode: a plain loop in the handler, answering one
#                       number or 100 key => sum pairs as JSON. The kernel and the generator are in
#                       `aggregate.jl`, shared with `suite/aggregate.jl` and mirrored in `go/`.
#                       Nitro with WORKERS=1 also takes `&queue=1`: the same op submitted to the
#                       `/cpu_job` queue, answered 202, and counted by `/jobs`. `&yield=<ms>` runs
#                       the loop with a `yield()` every <ms> in the handler (§5's fallback; Go
#                       has no twin, it preempts).
#   HOLDS=0|1           Nitro only: also serve the largest holds of #588's inventory as routes,
#                       so `stall.sh` can keep K of them in flight: `GET /hold/json` answers
#                       `Res.json` of a ~12 MB untyped `JSON.Object` parsed once at startup (the
#                       `write_dict_10mb` row); `POST /hold/json_typed` binds the request's body
#                       with `json(req, T; max_fields = 0)` (the `json_typed_10mb` row when it is
#                       sent `rows_body.jl`'s 12 MB body) and answers `ok <rows>`;
#                       `POST /hold/multipart` parses the request's multipart body with `getfiles`
#                       (the `multipart_64mib` row when it is sent a 64 MiB body) and answers
#                       `ok <parts>`; `GET /hold/file` is `Res.file(req, HOLD_FILE)`, the whole-file
#                       read (`file_100mib`), and `GET /hold/file_stream` the same with
#                       `stream = true`, the negative control (`file_100mib_stream_read`).
#   HOLD_FILE=<path>    The file the two `/hold/file*` routes serve. Default
#                       `bench/results/hold-100mib.bin`, written (100 MiB of random bytes) when
#                       missing and read once at startup, so it is in page cache.
#   PARK=timer|event    What the main task parks on once serving: a never-firing `Timer` (the
#                       default) or a `Base.Event`, which is not a libuv handle (#598, `wake.sh`).
#   GUARD=0|1           Hold one extra `Timer(typemax(Int32))` for the process's life: the
#                       workaround for JuliaLang/julia#63882 that #598 asks `serve()` to adopt.
#   PRELOAD="Pkg ..."   Load these packages before serving, so `rss.sh` can measure what one adds
#                       to the process (PRELOAD=PormG also loads NitroPormGExt). The project
#                       passed to `--project` must have them; the bench env does not.
#
# Run with `julia --project=bench -t 8 bench/socket/server.jl`. Every mode answers the same routes
# with the same bodies, so the stacks differ only in what serves them: `/plaintext`, `/json`,
# `/health`, `/cpu`, and `/lag`. `/lag` reports how late a `sleep(0.01)` loop on the `:default`
# pool woke since the previous `/lag` (p50/p99/max in ms, then resets) -- what a `Timer`-driven
# deadline, such as a Workers timeout, sees while the pool is busy (#491). `/gc` answers every
# field of `Base.gc_num()` as JSON, so a script can take the GC's counters before and after a run.

using HTTP
using JSON

const MODE       = get(ENV, "MODE", "nitro")

# Only where it is used, so a `bare_*` process has no Nitro in it at all: `rss.sh` reports that
# mode as the HTTP.jl-only floor (#451), and a loaded-but-idle Nitro would be counted in it.
MODE in ("nitro", "nitro_log") && @eval using Nitro

const PORT      = parse(Int, get(ENV, "PORT", "8080"))
const ACCESS_LOG = get(ENV, "ACCESS_LOG", "0") == "1" || MODE == "nitro_log"
const PROFILE_S  = parse(Float64, get(ENV, "PROFILE", "0"))
const WARMUP_S   = parse(Float64, get(ENV, "WARMUP", "8"))
const CPU_MS     = parse(Float64, get(ENV, "CPU_MS", "50"))
const YIELD_MS   = parse(Float64, get(ENV, "YIELD_MS", "2"))
const JOB_MS     = parse(Float64, get(ENV, "JOB_MS", "500"))
const WORKERS    = get(ENV, "WORKERS", "0") == "1"
const LAG        = get(ENV, "LAG", "0") == "1"
const LOGIN      = get(ENV, "LOGIN", "0") == "1"
const HOLDS      = get(ENV, "HOLDS", "0") == "1"
const AGG_ROWS   = parse(Int, get(ENV, "AGG_ROWS", "0"))
const BURST_K    = parse(Int, get(ENV, "BURST_K", string(max(Threads.nthreads(:default) - 2, 1))))

for pkg in split(get(ENV, "PRELOAD", ""))
    @eval using $(Symbol(pkg))
end

const PLAINTEXT = "Hello, World!"
json_body() = JSON.json(Dict("message" => "Hello, World!"))

include(joinpath(@__DIR__, "aggregate.jl"))
const AGG_DATA = agg_rows(AGG_ROWS)

# `(n, op)` from the query's strings, or `nothing` when either is not one `/aggregate` serves.
function agg_params(n_str, op_str)::Union{Nothing, Tuple{Int, String}}
    n = n_str === nothing ? nothing : tryparse(Int, n_str)
    (n === nothing || !(1 <= n <= length(AGG_DATA))) && return nothing
    op_str in ("sum", "mean", "groupby") || return nothing
    return n, String(op_str)
end

# `&yield=<ms>`: 0 (the plain loop) when absent; `nothing` when it is not a positive number.
function agg_yield_ms(y_str)::Union{Nothing, Float64}
    y_str === nothing && return 0.0
    y = tryparse(Float64, y_str)
    return y === nothing || !(y > 0) ? nothing : y
end

gc_body() = let g = Base.gc_num()
    JSON.json(Dict(string(f) => getfield(g, f) for f in fieldnames(typeof(g))))
end

# Compute for `ms` without reaching a yield point: `time_ns` is a plain clock read. Julia does not
# preempt, so this holds its thread for the whole duration, which is the case #491 asks about.
# `GC.safepoint()` is not a yield point, but it lets a collection proceed: a loop that never
# allocates otherwise holds up every stop-the-world GC, which stalls ALL threads, the interactive
# one included, and would make every thread layout look equally slow for a reason that is not
# scheduling. A real handler allocates and reaches safepoints anyway.
function burn(ms::Float64)::Float64
    deadline = time_ns() + round(UInt64, ms * 1e6)
    x = 0.0
    while time_ns() < deadline
        x = sin(x + 1.0)
        GC.safepoint()
    end
    return x
end
cpu_body() = string("ok ", burn(CPU_MS) > 2.0)   # never true; keeps `burn` from being elided

# `burn`, with a `yield()` every `every_ms`: the cooperative mitigation for a CPU-bound handler
# (#467). Same clock-read loop otherwise, so the two differ only in the yield.
function burn_yielding(ms::Float64, every_ms::Float64)::Float64
    now = time_ns()
    deadline = now + round(UInt64, ms * 1e6)
    step = round(UInt64, every_ms * 1e6)
    next = now + step
    x = 0.0
    while (now = time_ns()) < deadline
        x = sin(x + 1.0)
        GC.safepoint()
        if now >= next
            yield()
            next = time_ns() + step
        end
    end
    return x
end
cpu_yield_body() = string("ok ", burn_yielding(CPU_MS, YIELD_MS) > 2.0)

# How late a 10 ms sleep on the `:default` pool wakes. Every mode can start it (LAG=1), so modes
# stay alike.
const LAG_LOCK = ReentrantLock()
const LAG_MS   = Float64[]
function lag_probe()
    while true
        t0 = time_ns()
        sleep(0.01)
        late = (time_ns() - t0) / 1e6 - 10.0
        lock(() -> push!(LAG_MS, late), LAG_LOCK)
    end
end
function lag_body()
    samples = lock(LAG_LOCK) do
        s = copy(LAG_MS); empty!(LAG_MS); s
    end
    isempty(samples) && return JSON.json(Dict("n" => 0))
    sort!(samples)
    q(p) = round(samples[clamp(ceil(Int, p * length(samples)), 1, length(samples))]; digits = 2)
    return JSON.json(Dict("n" => length(samples), "p50" => q(0.5), "p99" => q(0.99),
                          "max" => round(samples[end]; digits = 2)))
end

function bare_handler(req::HTTP.Request)::HTTP.Response
    target = req.target
    target == "/plaintext" && return HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8"], PLAINTEXT)
    target == "/json"      && return HTTP.Response(200, ["Content-Type" => "application/json"], json_body())
    target == "/health"    && return HTTP.Response(200, "ok")
    target == "/cpu"       && return HTTP.Response(200, cpu_body())
    target == "/cpu_yield" && return HTTP.Response(200, cpu_yield_body())
    target == "/lag"       && return HTTP.Response(200, ["Content-Type" => "application/json"], lag_body())
    target == "/gc"        && return HTTP.Response(200, ["Content-Type" => "application/json"], gc_body())
    if startswith(target, "/aggregate")
        query = HTTP.URIs.queryparams(HTTP.URIs.URI(target))
        parsed = agg_params(get(query, "n", nothing), get(query, "op", nothing))
        yield_ms = agg_yield_ms(get(query, "yield", nothing))
        (parsed === nothing || yield_ms === nothing) && return HTTP.Response(400, "bad n, op or yield")
        return HTTP.Response(200, ["Content-Type" => "application/json"], agg_body(AGG_DATA, parsed..., yield_ms))
    end
    return HTTP.Response(404)
end

function start_bare(spawn::Bool)
    inner = HTTP.streamhandler(bare_handler)
    handler = spawn ? (stream -> wait(Threads.@spawn inner(stream))) : inner
    return HTTP.listen!(handler, "127.0.0.1", PORT)
end

# One reusable hand-off per CONNECTION (a connection serves one request at a time), kept in the
# connection task's storage: the pool side allocates no task and no event per request, which is
# the whole point of a pool. `stream` is untyped, one dynamic call per request -- tens of
# nanoseconds against a spawn's microseconds, and it errs in the spawn's favour.
mutable struct PoolSlot
    stream::Any
    err::Any
    const done::Base.Event
    PoolSlot() = new(nothing, nothing, Base.Event(true))   # autoreset: reusable
end

function start_bare_pool()
    inner = HTTP.streamhandler(bare_handler)
    n = parse(Int, get(ENV, "POOL", string(Threads.nthreads(:default))))
    jobs = Channel{PoolSlot}(Inf)
    for _ in 1:n
        Threads.@spawn :default for slot in jobs
            try
                inner(slot.stream)
            catch e
                slot.err = e
            end
            notify(slot.done)
        end
    end
    handler = function (stream)
        slot = get!(PoolSlot, task_local_storage(), :bench_pool_slot)::PoolSlot
        slot.stream = stream
        slot.err = nothing
        put!(jobs, slot)
        wait(slot.done)
        slot.stream = nothing
        slot.err === nothing || throw(slot.err)
        return nothing
    end
    return HTTP.listen!(handler, "127.0.0.1", PORT)
end

function start_nitro()
    app = App()
    urlpatterns(app, "",
        path("/plaintext", req -> Res.send(PLAINTEXT); method = "GET"),
        path("/json",      req -> Res.send(json_body(); content_type = "application/json"); method = "GET"),
        path("/health",    req -> Res.send("ok"); method = "GET"),
        path("/cpu",       req -> Res.send(cpu_body()); method = "GET"),
        path("/cpu_yield", req -> Res.send(cpu_yield_body()); method = "GET"),
        path("/lag",       req -> Res.send(lag_body(); content_type = "application/json"); method = "GET"),
        path("/gc",        req -> Res.send(gc_body(); content_type = "application/json"); method = "GET"),
    )
    if HOLDS
        hold_json, hold_json_typed, hold_multipart, hold_file, hold_file_stream = hold_routes()
        urlpatterns(app, "",
            path("/hold/json",        hold_json; method = "GET"),
            path("/hold/json_typed",  hold_json_typed; method = "POST"),
            path("/hold/multipart",   hold_multipart; method = "POST"),
            path("/hold/file",        hold_file; method = "GET"),
            path("/hold/file_stream", hold_file_stream; method = "GET"),
        )
    end
    if LOGIN
        login, login_bcrypt = login_routes()
        urlpatterns(app, "",
            path("/login",        login; method = "GET"),
            path("/login_bcrypt", login_bcrypt; method = "GET"),
        )
    end
    agg_job = nothing
    if WORKERS
        burst, cpu_job, jobs, agg_job = worker_routes()
        urlpatterns(app, "",
            path("/burst",   burst; method = "GET"),
            path("/cpu_job", cpu_job; method = "GET"),
            path("/jobs",    jobs; method = "GET"),
        )
    end
    urlpatterns(app, "", path("/aggregate", aggregate_route(agg_job); method = "GET"))
    serve(app; host = "127.0.0.1", port = PORT, async = true, show_banner = false,
          access_log = ACCESS_LOG)
    return app
end

# `/login` and `/login_bcrypt` (#587): one password check per request, at the default cost, and a
# fixed body. No user, no store, no request body: the point is how long the check holds its
# `:default` thread, not the auth flow. The password is right, so the check runs to the end and
# `denied` is never sent.
function login_routes()
    n = get(ENV, "PASSWORD_CONCURRENCY", "")
    isempty(n) || Nitro.Auth.set_password_concurrency!(parse(Int, n))
    @info "bench: password checks" concurrency = Nitro.Auth.password_concurrency()
    password = "correct horse battery staple"
    pbkdf2 = Nitro.Auth.make_password(password)
    bcrypt = Nitro.Auth.make_password(password; algorithm = "bcrypt")
    check(hash) = req -> Res.send(Nitro.Auth.check_password(password, hash) ? "ok" : "denied")
    return check(pbkdf2), check(bcrypt)
end

# `/aggregate` in Nitro: the query through `getquery`, as an app reads it. `submit` is
# `worker_routes`' queue submitter, or `nothing` without WORKERS=1.
function aggregate_route(submit)
    return function (req)
        query = Nitro.getquery(req)
        parsed = agg_params(get(query, "n", nothing), get(query, "op", nothing))
        yield_ms = agg_yield_ms(get(query, "yield", nothing))
        (parsed === nothing || yield_ms === nothing) && return Res.send("bad n, op or yield"; status = 400)
        if get(query, "queue", "0") == "1"
            submit === nothing && return Res.send("queue=1 needs WORKERS=1"; status = 400)
            submit(parsed...)
            return Res.send("accepted"; status = 202)
        end
        return Res.send(agg_body(AGG_DATA, parsed..., yield_ms); content_type = "application/json")
    end
end

# The largest holds of #588's inventory, as routes. The JSON value is built the way
# `suite/holds.jl` builds `write_dict_10mb`'s: `suite/json.jl`'s rows payload at 250,000 rows,
# parsed untyped. It is shared by every request and only read. `HoldRows` is `bench/setup.jl`'s
# `BenchRows` under another name, so `/hold/json_typed` binds what `json_typed_10mb` binds.
struct HoldRow
    id::Int
    label::String
    value::Float64
end
struct HoldRows
    rows::Vector{HoldRow}
end

const HOLD_FILE_BYTES = 100 * 1024 * 1024

function hold_routes()
    rows = JSON.json(Dict("rows" => [Dict("id" => i, "label" => "row-$i", "value" => i * 1.5)
                                     for i in 1:250_000]))
    value = JSON.parse(rows)
    file = get(ENV, "HOLD_FILE", joinpath(@__DIR__, "..", "results", "hold-100mib.bin"))
    if filesize(file) != HOLD_FILE_BYTES
        mkpath(dirname(file))
        write(file, rand(UInt8, HOLD_FILE_BYTES))
    end
    read(file)   # into page cache
    hold_json = req -> Res.json(value)
    hold_json_typed = req -> Res.send(string("ok ", length(Nitro.json(req, HoldRows; max_fields = 0).rows)))
    hold_multipart = req -> Res.send(string("ok ", length(Nitro.getfiles(req))))
    hold_file = req -> Res.file(req, file)
    hold_file_stream = req -> Res.file(req, file; stream = true)
    return hold_json, hold_json_typed, hold_multipart, hold_file, hold_file_stream
end

# `/burst?n=K`: K Workers jobs at once, each burning JOB_MS on the `:default` pool -- the pool
# HTTP.jl's connection tasks share when there is no interactive thread (#491). A runtime of its own,
# no run cap (a `burst128` must run 128 jobs, not be refused past the default 64), no deadline
# short enough to fire: the question is what the jobs do to `/health`.
#
# The two #513 levers are per REQUEST, not per server, so one `contention.sh` run interleaves every
# variant on the same servers: `queue=1` sends the jobs to a queue of concurrency BURST_K (the
# bulkhead), and `cp=MS` makes each one call `checkpoint!` every MS milliseconds.
#
# `/cpu_job` (#467) is `/cpu` moved to that same queue: one job of CPU_MS per request, answered
# 202 before it runs. `/jobs` counts the ones not yet finished, so `stall.sh` can drain between
# passes instead of letting one pass's backlog load the next.
function worker_routes()
    runtime = Nitro.Workers.WorkerRuntime(Nitro.Workers.InMemoryWorkerStore();
                                          max_concurrent_runs = nothing,
                                          queues = ["burst" => BURST_K])
    owner = Nitro.Workers.Owner("bench")
    seq = Threads.Atomic{Int}(0)
    pending = Threads.Atomic{Int}(0)
    cpu_job = function (req)
        id = Threads.atomic_add!(seq, 1)
        Threads.atomic_add!(pending, 1)
        job = _ -> try burn(CPU_MS) finally Threads.atomic_sub!(pending, 1) end
        try
            Nitro.Workers.submit_queued_task("burst", "cpu-$id", job, owner; runtime)
        catch
            # A full queue refuses the job with `WorkerCapacityError`, which Nitro answers 503.
            # It will never run, so it is not pending.
            Threads.atomic_sub!(pending, 1)
            rethrow()
        end
        return Res.send("accepted"; status = 202)
    end
    jobs = req -> Res.send(string(pending[]))
    # `/aggregate?…&queue=1`: one aggregation per request on the same queue, counted the same way.
    agg_job = function (n, op)
        id = Threads.atomic_add!(seq, 1)
        Threads.atomic_add!(pending, 1)
        job = _ -> try agg_body(AGG_DATA, n, op) finally Threads.atomic_sub!(pending, 1) end
        try
            Nitro.Workers.submit_queued_task("burst", "agg-$id", job, owner; runtime)
        catch
            Threads.atomic_sub!(pending, 1)
            rethrow()
        end
        return nothing
    end
    burst = function (req)
        query = Nitro.getquery(req)
        n = parse(Int, something(get(query, "n", nothing), "8"))
        queued = get(query, "queue", "0") == "1"
        cp_ms = parse(Float64, something(get(query, "cp", nothing), "0"))
        job = cp_ms > 0 ? (task_info -> burn_checkpointed(JOB_MS, cp_ms, task_info)) :
                          (_ -> burn(JOB_MS))
        for _ in 1:n
            id = Threads.atomic_add!(seq, 1)
            if queued
                Nitro.Workers.submit_queued_task("burst", "burn-$id", job, owner; runtime)
            else
                Nitro.Workers.submit_task("burn-$id", job, owner; runtime)
            end
        end
        return Res.send("submitted $n")
    end
    return burst, cpu_job, jobs, agg_job
end

# `burn`, but calling `checkpoint!` every `every_ms` of it (#513): the cooperative yield point a
# CPU-bound job is told to reach. Same clock-read loop otherwise, so the two differ only in that.
function burn_checkpointed(ms::Float64, every_ms::Float64, task_info)::Float64
    now = time_ns()
    deadline = now + round(UInt64, ms * 1e6)
    step = round(UInt64, every_ms * 1e6)
    next = now + step
    x = 0.0
    while (now = time_ns()) < deadline
        x = sin(x + 1.0)
        GC.safepoint()
        if now >= next
            Nitro.Workers.checkpoint!(task_info)
            next = time_ns() + step
        end
    end
    return x
end

# Profile is not in Julia's system image (~13 MiB resident once loaded), so it loads only when
# profiling: `rss.sh` must not count it. The function is evaluated after the `using`, not defined
# at top level, because `Profile.@profile` needs the module when the macro expands.
PROFILE_S > 0 && @eval using Profile
PROFILE_S > 0 && @eval function profile_window()
    sleep(WARMUP_S)
    Profile.init(n = 10^7, delay = 0.001)
    Profile.clear()
    @info "bench: profiling every thread for $(PROFILE_S) s"
    gc0, t0 = Base.gc_time_ns(), time_ns()
    Profile.@profile sleep(PROFILE_S)
    gc_ns, window_ns = Base.gc_time_ns() - gc0, time_ns() - t0
    dir = joinpath(@__DIR__, "..", "results")
    mkpath(dir)
    stem = joinpath(dir, "profile-$(MODE)-$(round(Int, time()))")
    open("$stem-flat.txt", "w") do io
        Profile.print(IOContext(io, :displaysize => (10_000, 400)); format = :flat,
                      sortedby = :count, mincount = 20)
    end
    open("$stem-threads.txt", "w") do io
        Profile.print(IOContext(io, :displaysize => (10_000, 400)); format = :flat,
                      sortedby = :count, groupby = :thread, mincount = 20)
    end
    # The interactive thread(s) alone, as a tree: HTTP.jl's accept loop and every connection task
    # run there, so this is where `read_request` and the `@spawn` wake-up show up against each
    # other (#462). Selected by pool, not by id, so it stays
    # right if the numbering ever changes. C frames are kept: without them a stop-the-world GC is
    # charged to whatever Julia allocation site the thread was parked at, which reads as a parser
    # cost. The GC line is the window's wall time spent collecting -- every thread pays it.
    interactive = filter(i -> Threads.threadpool(i) == :interactive, 1:Threads.maxthreadid())
    open("$stem-interactive-tree.txt", "w") do io
        println(io, "interactive thread ids: ", interactive)
        println(io, "GC: ", round(gc_ns / 1e6; digits = 1), " ms of a ", round(window_ns / 1e6; digits = 1),
                " ms window (", round(100 * gc_ns / window_ns; digits = 1), "%)")
        Profile.print(IOContext(io, :displaysize => (10_000, 400)); format = :tree, C = true,
                      threads = interactive, mincount = 20, maxdepth = 80)
    end
    open(io -> sched_share(io, interactive), "$stem-sched.txt", "w")
    @info "bench: profile written" stem
end

# What share of the AWAKE samples is task machinery (#468): creating, scheduling, switching to and
# waiting on tasks. Each awake sample is charged to the leaf-most frame that decides it: a C frame
# outside Julia's runtime (libc, libuv) is skipped, so the `pthread_cond_signal` that wakes a
# thread is charged to `scheduler.c` and a `memcpy` inside `jl_new_task` to `task.c`; a runtime C
# frame that is neither task nor GC code (dispatch, `jl_apply`) is skipped too, to its caller. A
# Julia frame decides: task machinery if it is one of Base's task files, otherwise `other`.
# Sleeping samples -- a thread parked with nothing to run -- are counted separately and charged to
# nothing: without the profiler's sleep state an idle thread reads as time spent in `poptask`.
PROFILE_S > 0 && @eval begin
const SCHED_JL = ("task.jl", "partr.jl", "condition.jl", "lock.jl", "locks-mt.jl",
                  "threadingconstructs.jl")
const SCHED_C  = ("task.c", "scheduler.c", "partr.c", "threading.c")

# `:tasks`, `:gc` or `:other` when this frame decides the sample, `nothing` to look at its caller.
function frame_category(fr)::Union{Symbol, Nothing}
    path = string(fr.file)
    f = basename(path)
    (isempty(f) || f == "?") && return nothing
    if fr.from_c
        occursin("libuv", path) && return nothing        # libuv's own `src/` is not Julia's
        f in SCHED_C && return :tasks
        (startswith(f, "gc") && endswith(f, ".c")) || f == "safepoint.c" ? :gc : nothing
    else
        base = startswith(path, "./") || occursin("/base/", path)   # not a package's `task.jl`
        base && f in SCHED_JL && return :tasks
        return base && f == "gc.jl" ? :gc : :other
    end
end

function sched_share(io::IO, interactive::Vector{Int})
    data, lidict = Profile.retrieve()
    # Each block is: ip... (leaf first), threadid, taskid, cycles, sleep state + 1, 0, 0 -- the
    # offsets are Profile's own `META_OFFSET_*`, and `is_block_end` finds the closing zero.
    counts = Dict{Tuple{Symbol, Symbol}, Int}()   # (pool, category) => samples
    block_start = 1
    for i in eachindex(data)
        i > Profile.META_OFFSET_THREADID || continue
        Profile.is_block_end(data, i) || continue
        tid = Int(data[i - Profile.META_OFFSET_THREADID])
        sleeping = data[i - Profile.META_OFFSET_SLEEPSTATE] - 1 == 1
        # The profiler also samples threads Julia did not start for tasks: the parallel GC's (one
        # per default thread unless --gcthreads) and any I/O poller. Parked in a condition wait,
        # they read as awake, so lumping them in with `:default` halves every share.
        pool = tid in interactive ? :interactive :
               tid <= Threads.maxthreadid() && Threads.threadpool(tid) == :default ? :default :
               :foreign
        cat = sleeping ? :sleeping : :other
        if !sleeping && pool !== :foreign
            # ips leaf first, and each ip's frames (inlining) leaf first too.
            found = false
            for j in block_start:(i - Profile.META_OFFSET_THREADID - 1)
                for fr in get(lidict, data[j], ())
                    c = frame_category(fr)
                    c === nothing && continue
                    cat = c; found = true; break
                end
                found && break
            end
        end
        counts[(pool, cat)] = get(counts, (pool, cat), 0) + 1
        block_start = i + 1
    end
    println(io, "samples by pool and category (awake samples charged to the leaf-most deciding frame)")
    for pool in (:interactive, :default)
        awake = sum(get(counts, (pool, c), 0) for c in (:tasks, :gc, :other))
        asleep = get(counts, (pool, :sleeping), 0)
        pct(c) = awake == 0 ? 0.0 : round(100 * get(counts, (pool, c), 0) / awake; digits = 1)
        println(io, rpad(string(pool), 12), " awake=", awake, " sleeping=", asleep,
                " | tasks ", pct(:tasks), "%  gc ", pct(:gc), "%  other ", pct(:other), "%")
    end
    foreign = sum(v for ((p, _), v) in counts if p === :foreign; init = 0)
    println(io, rpad("foreign", 12), " samples=", foreign, " (GC and I/O threads, not counted above)")
end
end

handle = MODE in ("nitro", "nitro_log") ? start_nitro() :
         MODE == "bare_spawn"   ? start_bare(true) :
         MODE == "bare_nospawn" ? start_bare(false) :
         MODE == "bare_pool"    ? start_bare_pool() :
         error("unknown MODE=$(MODE): expected nitro, nitro_log, bare_spawn, bare_nospawn or bare_pool")

@info "bench: serving" MODE PORT threads = Threads.nthreads() interactive = Threads.nthreads(:interactive)
PROFILE_S > 0 && Threads.@spawn profile_window()
LAG && Threads.@spawn lag_probe()

# Block until killed. A `Timer` keeps an idle task parked so the process stays up and a SIGTERM
# from `run.sh` ends it cleanly. That `Timer` is also a live libuv handle, which on Julia
# 1.13.0-rc3..1.13.2 hides JuliaLang/julia#63882 (#586): `PARK=event` parks on a `Base.Event`
# instead, which is no handle, so `wake.sh` can look for the stall; `GUARD=1` then adds the
# one-line workaround back explicitly (#598).
const GUARD_TIMER = get(ENV, "GUARD", "0") == "1" ? Timer(typemax(Int32)) : nothing
get(ENV, "PARK", "timer") == "event" ? wait(Base.Event()) : wait(Timer(typemax(Int32)))
