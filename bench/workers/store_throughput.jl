# What does a worker store's task lock cost one process's submit/finish rate? (#548)
#
# `k` clients each loop `submit_task` -> wait for that task's COMPLETED write, with a trivial
# callback, for `seconds`. The rate is closed-loop: a cycle is one submit plus the run's start and
# terminal writes, so it is what one process can push through its store, not what a burst queues.
# The store is wrapped in a forwarding store that times every `lock_tasks` section: how long a
# caller waited to get the lock, and how long it then held it. On a store whose writes are database
# round trips, flat throughput in `k` with hold ≈ the cycle time says the lock, not the database,
# is the ceiling.
#
#   julia --project=<env> -t 4 bench/workers/store_throughput.jl [store] [seconds] [ks]
#
# `store` is `memory` (the default), `sqlite` (a temporary file) or `postgres`, which connects to
# the libpq conninfo in `NITRO_BENCH_POSTGRES` (`host=… port=… user=… dbname=…`) and empties its
# `nitro_task` table before each k: point it at a throwaway database. `ks` is a comma list, default `1,4,16`. The two
# database stores need PormG, SQLite and LibPQ, which the bench env does not carry: run it from an
# env that adds them to a `Pkg.develop`ed Nitro, as `bench/consumer/heartbeat_lateness.jl` says.
using Nitro, Nitro.Workers, Dates, Printf
const W = Nitro.Workers

backend = length(ARGS) >= 1 ? ARGS[1] : "memory"
seconds = length(ARGS) >= 2 ? parse(Float64, ARGS[2]) : 10.0
ks = length(ARGS) >= 3 ? parse.(Int, split(ARGS[3], ",")) : [1, 4, 16]

backend in ("memory", "sqlite", "postgres") || error("store must be memory, sqlite or postgres, got $backend")
backend == "memory" || @eval using PormG, SQLite, LibPQ

# A fresh PormG store per run, so every k starts from an empty table. Called through
# `invokelatest`: PormG is loaded above, after this file's other definitions were compiled.
function pormg_store(n::Int)
    key = "store_throughput_$n"
    if backend == "sqlite"
        PormG.register_connection(key, joinpath(mktempdir(), "bench.sqlite"); adapter = "SQLite")
    else
        PormG.register_connection(key, ENV["NITRO_BENCH_POSTGRES"]; adapter = "PostgreSQL")
    end
    PormG.config[key].change_data = true
    PormG.config[key].change_db = true
    store = Nitro.pormg_nitro_worker(db_key = key)
    # PostgreSQL keeps the table between runs; start each from empty.
    Base.get_extension(Nitro, :NitroPormGExt)._task_objects(store).delete(allow_delete_all = true)
    return store
end

# Forwards every store call, times `lock_tasks`, and wakes the client waiting on a task when its
# COMPLETED write lands.
struct LockTimedStore{S <: W.AbstractWorkerStore} <: W.AbstractWorkerStore
    inner::S
    waits::Vector{Float64}
    holds::Vector{Float64}
    stats_lock::ReentrantLock
    done::Dict{String, Base.Event}
end
LockTimedStore(inner) = LockTimedStore(inner, Float64[], Float64[], ReentrantLock(), Dict{String, Base.Event}())

for (f, n) in ((:get_task_info, 1), (:set_task!, 2), (:replace_task!, 2), (:add_watcher!, 2),
               (:delete_task!, 1), (:try_delete_task!, 2), (:cleanup_tasks!, 1),
               (:get_all_tasks, 1), (:get_queue_authorizer, 0), (:set_queue_authorizer!, 1),
               (:get_watch_authorizer, 0), (:set_watch_authorizer!, 1), (:get_error_redactor, 0),
               (:set_error_redactor!, 1), (:list_running_task_refs, 0), (:count_external_runs, 1))
    args = [Symbol("a", i) for i in 1:n]
    @eval W.$f(s::LockTimedStore, $(args...); kw...) = W.$f(s.inner, $(args...); kw...)
end
W._visible_across_processes(s::LockTimedStore) = W._visible_across_processes(s.inner)

function W.try_transition!(s::LockTimedStore, id, from, to; kw...)
    won = W.try_transition!(s.inner, id, from, to; kw...)
    if won && to == W.COMPLETED
        ev = lock(() -> get(s.done, id, nothing), s.stats_lock)
        ev === nothing || notify(ev)
    end
    return won
end

function W.lock_tasks(cb::Function, s::LockTimedStore)
    asked = time()
    return W.lock_tasks(s.inner) do
        got = time()
        try
            cb()
        finally
            held = time() - got
            lock(s.stats_lock) do
                push!(s.waits, got - asked)
                push!(s.holds, held)
            end
        end
    end
end

trivial() = nothing

# One client: submit, wait for this task's COMPLETED, repeat until `stop`.
function client(rt, s::LockTimedStore, c::Int, stop::Threads.Atomic{Bool}, cycles::Threads.Atomic{Int})
    owner = Owner("client$c")
    i = 0
    while !stop[]
        i += 1
        key = "c$(c)_$i"
        ev = Base.Event()
        lock(() -> s.done["client$c::$key"] = ev, s.stats_lock)
        W.submit_task(key, trivial, owner; runtime = rt)
        wait(ev)
        lock(() -> delete!(s.done, "client$c::$key"), s.stats_lock)
        Threads.atomic_add!(cycles, 1)
    end
end

pct(v, p) = isempty(v) ? NaN : sort(v)[clamp(ceil(Int, p * length(v)), 1, length(v))]

function run_once(k::Int)
    inner = backend == "memory" ? W.InMemoryWorkerStore() : Base.invokelatest(pormg_store, k)
    s = LockTimedStore(inner)
    rt = W.WorkerRuntime(s; max_concurrent_runs = nothing)
    # Warm on one client until 200 cycles (or 60 s), so compilation stays out of the window.
    cycles = Threads.Atomic{Int}(0)
    warm = Threads.Atomic{Bool}(false)
    t = Threads.@spawn client(rt, s, 0, warm, cycles)
    deadline = time() + 60
    while cycles[] < 200 && time() < deadline
        sleep(0.05)
    end
    warm[] = true; wait(t)
    lock(() -> (empty!(s.waits); empty!(s.holds)), s.stats_lock)
    cycles[] = 0
    stop = Threads.Atomic{Bool}(false)
    t0 = time()
    tasks = [Threads.@spawn client(rt, s, c, stop, cycles) for c in 1:k]
    sleep(seconds)
    stop[] = true
    foreach(wait, tasks)
    elapsed = time() - t0
    W.shutdown!(rt)
    waits, holds = lock(() -> (copy(s.waits), copy(s.holds)), s.stats_lock)
    rate = cycles[] / elapsed
    busy = sum(holds; init = 0.0) / elapsed
    @printf("%-8s k=%-3d  %9.1f cycles/s | lock sections %8d (%5.1f/cycle) | hold mean %8.1f µs p99 %8.1f µs | wait mean %9.1f µs p99 %9.1f µs | lock busy %5.1f%%\n",
            backend, k, rate, length(holds),
            length(holds) / max(cycles[], 1), 1e6 * sum(holds; init = 0.0) / max(length(holds), 1), 1e6 * pct(holds, 0.99),
            1e6 * sum(waits; init = 0.0) / max(length(waits), 1), 1e6 * pct(waits, 0.99), 100 * busy)
end

println("# store_throughput: julia $(VERSION), threads $(Threads.nthreads()), $(seconds) s per k, store $backend")
foreach(run_once, ks)
