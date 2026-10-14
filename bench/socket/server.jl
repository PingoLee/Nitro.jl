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
#   MODE=nitro_serial   Nitro `serve(parallel = false)`: no per-request spawn, so the handler runs on
#                       HTTP.jl's connection task -- the Nitro counterpart of `bare_nospawn` (#492).
#
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
#   WORKERS=0|1         Nitro only: also serve `/burst?n=K`, which submits K Workers jobs that each
#                       burn JOB_MS (default 500) without yielding, on a `WorkerRuntime` of its own.
#                       `&queue=1` submits them to a queue of concurrency BURST_K instead of all at
#                       once, and `&cp=MS` makes each job call `checkpoint!` every MS ms (#513).
#   BURST_K=<k>         Nitro only: that queue's concurrency. Default `nthreads(:default) - 2`, at
#                       least 1. The queue buffers 100, so a queued burst above 100 is refused.
#   LAG=0|1             Start the `/lag` probe (off by default, so a throughput run carries no extra
#                       task). Without it `/lag` answers `{"n":0}`.
#   PRELOAD="Pkg ..."   Load these packages before serving, so `rss.sh` can measure what one adds
#                       to the process (PRELOAD=PormG also loads NitroPormGExt). The project
#                       passed to `--project` must have them; the bench env does not.
#
# Run with `julia --project=bench -t 8 bench/socket/server.jl`. Every mode answers the same routes
# with the same bodies, so the stacks differ only in what serves them: `/plaintext`, `/json`,
# `/health`, `/cpu`, and `/lag`. `/lag` reports how late a `sleep(0.01)` loop on the `:default`
# pool woke since the previous `/lag` (p50/p99/max in ms, then resets) -- what a `Timer`-driven
# deadline, such as a Workers timeout, sees while the pool is busy (#491).

using HTTP
using JSON

const MODE       = get(ENV, "MODE", "nitro")

# Only where it is used, so a `bare_*` process has no Nitro in it at all: `rss.sh` reports that
# mode as the HTTP.jl-only floor (#451), and a loaded-but-idle Nitro would be counted in it.
MODE in ("nitro", "nitro_log", "nitro_serial") && @eval using Nitro

const PORT      = parse(Int, get(ENV, "PORT", "8080"))
const ACCESS_LOG = get(ENV, "ACCESS_LOG", "0") == "1" || MODE == "nitro_log"
const PROFILE_S  = parse(Float64, get(ENV, "PROFILE", "0"))
const WARMUP_S   = parse(Float64, get(ENV, "WARMUP", "8"))
const CPU_MS     = parse(Float64, get(ENV, "CPU_MS", "50"))
const JOB_MS     = parse(Float64, get(ENV, "JOB_MS", "500"))
const WORKERS    = get(ENV, "WORKERS", "0") == "1"
const LAG        = get(ENV, "LAG", "0") == "1"
const BURST_K    = parse(Int, get(ENV, "BURST_K", string(max(Threads.nthreads(:default) - 2, 1))))

for pkg in split(get(ENV, "PRELOAD", ""))
    @eval using $(Symbol(pkg))
end

const PLAINTEXT = "Hello, World!"
json_body() = JSON.json(Dict("message" => "Hello, World!"))

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
    target == "/lag"       && return HTTP.Response(200, ["Content-Type" => "application/json"], lag_body())
    return HTTP.Response(404)
end

function start_bare(spawn::Bool)
    inner = HTTP.streamhandler(bare_handler)
    handler = spawn ? (stream -> wait(Threads.@spawn inner(stream))) : inner
    return HTTP.listen!(handler, "127.0.0.1", PORT)
end

function start_nitro(parallel::Bool)
    app = App()
    urlpatterns(app, "",
        path("/plaintext", req -> Res.send(PLAINTEXT); method = "GET"),
        path("/json",      req -> Res.send(json_body(); content_type = "application/json"); method = "GET"),
        path("/health",    req -> Res.send("ok"); method = "GET"),
        path("/cpu",       req -> Res.send(cpu_body()); method = "GET"),
        path("/lag",       req -> Res.send(lag_body(); content_type = "application/json"); method = "GET"),
    )
    WORKERS && urlpatterns(app, "", path("/burst", burst_route(); method = "GET"))
    serve(app; host = "127.0.0.1", port = PORT, async = true, show_banner = false,
          access_log = ACCESS_LOG, parallel)
    return app
end

# `/burst?n=K`: K Workers jobs at once, each burning JOB_MS on the `:default` pool -- the pool
# HTTP.jl's connection tasks share when there is no interactive thread (#491). A runtime of its own,
# no run cap (a `burst128` must run 128 jobs, not be refused past the default 64), no deadline
# short enough to fire: the question is what the jobs do to `/health`.
#
# The two #513 levers are per REQUEST, not per server, so one `contention.sh` run interleaves every
# variant on the same servers: `queue=1` sends the jobs to a queue of concurrency BURST_K (the
# bulkhead), and `cp=MS` makes each one call `checkpoint!` every MS milliseconds.
function burst_route()
    runtime = Nitro.Workers.WorkerRuntime(Nitro.Workers.InMemoryWorkerStore();
                                          max_concurrent_runs = nothing,
                                          queues = ["burst" => BURST_K])
    owner = Nitro.Workers.Owner("bench")
    seq = Threads.Atomic{Int}(0)
    return function (req)
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
    @info "bench: profile written" stem
end

handle = MODE in ("nitro", "nitro_log") ? start_nitro(true) :
         MODE == "nitro_serial" ? start_nitro(false) :
         MODE == "bare_spawn"   ? start_bare(true) :
         MODE == "bare_nospawn" ? start_bare(false) :
         error("unknown MODE=$(MODE): expected nitro, nitro_log, nitro_serial, bare_spawn or bare_nospawn")

@info "bench: serving" MODE PORT threads = Threads.nthreads() interactive = Threads.nthreads(:interactive)
PROFILE_S > 0 && Threads.@spawn profile_window()
LAG && Threads.@spawn lag_probe()

# Block until killed. A `Timer` keeps an idle task parked so the process stays up and a SIGTERM
# from `run.sh` ends it cleanly.
wait(Timer(typemax(Int32)))
