# How late does a consumer's lease heartbeat run while its jobs allocate heavily? (#514)
#
# The lease must outlast the longest gap between two renewals, or a healthy run is taken back.
# A stop-the-world collection stops the interactive thread too, so the gap is bounded below by the
# worst GC pause the jobs cause, plus scheduling delay. This drives a real consumer
# (`_start_consumer`, the heartbeat on `:interactive`) over an in-process claim-capable store,
# runs `k` jobs that allocate as hard as they can, and records every successful renewal.
#
#   julia +1.12 --project=bench -t 4,2 bench/consumer/heartbeat_lateness.jl [seconds] [k] [live_mb] [mode] [store]
#
# `live_mb` is the long-lived heap each job keeps (a ring of small objects), which is what makes a
# full collection's mark phase, and so its pause, long. `mode = spin` runs CPU-bound jobs that
# neither allocate nor yield instead: what the interactive-thread placement exists for.
#
# `store = memory` (the default) measures the heartbeat's own scheduling. `store = sqlite` runs the
# same consumer over `pormg_nitro_worker()` on a temporary SQLite file, so a renewal pays for the
# driver too, and in particular for WHERE the driver runs its statement: PormG's SQLite backend
# runs every statement on one `:default` task (PormG#1280), which spinning jobs can starve. It
# needs PormG and SQLite, which the bench env does not carry: run it from an env that adds them to
# a `Pkg.develop`ed Nitro.
using Nitro, Nitro.Workers, Dates, Printf
const W = Nitro.Workers

seconds = length(ARGS) >= 1 ? parse(Float64, ARGS[1]) : 60.0
k = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 3
live_mb = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 256
mode = length(ARGS) >= 4 ? ARGS[4] : "churn"
backend = length(ARGS) >= 5 ? ARGS[5] : "memory"
lease = 3.0                                     # heartbeat every 1 s

backend in ("memory", "sqlite") || error("store must be memory or sqlite, got $backend")
backend == "sqlite" && @eval using PormG, SQLite

# A real PormG store on a fresh SQLite file. Called through `invokelatest`: PormG is loaded above,
# after this file's other definitions were compiled.
function sqlite_store()
    key = "heartbeat_bench"
    path = joinpath(mktempdir(), "bench.sqlite")
    PormG.register_connection(key, path; adapter = "SQLite", env = "bench")
    PormG.config[key].change_data = true
    PormG.config[key].change_db = true
    return Nitro.pormg_nitro_worker(db_key = key)
end

# A store that answers like a shared one, and timestamps every renewal it serves (when the call
# returns, which is when the lease is actually extended).
struct TimedStore{S <: W.AbstractWorkerStore} <: W.AbstractWorkerStore
    inner::S
    renewed_at::Vector{Float64}
end
for (f, n) in ((:get_task_info, 1), (:set_task!, 2), (:replace_task!, 2), (:add_watcher!, 2),
               (:try_transition!, 3), (:delete_task!, 1), (:try_delete_task!, 2), (:cleanup_tasks!, 1),
               (:get_all_tasks, 1), (:get_queue_authorizer, 0), (:set_queue_authorizer!, 1),
               (:get_watch_authorizer, 0), (:set_watch_authorizer!, 1), (:get_error_redactor, 0),
               (:set_error_redactor!, 1), (:claim_next!, 2), (:release_claim!, 2),
               (:requeue_expired!, 1), (:count_external_runs, 1))
    args = [Symbol("a", i) for i in 1:n]
    @eval W.$f(s::TimedStore, $(args...); kw...) = W.$f(s.inner, $(args...); kw...)
end
W.task_locks(s::TimedStore) = W.task_locks(s.inner)
W._visible_across_processes(::TimedStore) = true
function W.renew_leases!(s::TimedStore, consumer::String, runs; kw...)
    out = W.renew_leases!(s.inner, consumer, runs; kw...)
    isempty(out) || push!(s.renewed_at, time())
    return out
end

@kwdef struct Churn
    live_mb::Int
    spin::Bool = false
end

# CPU-bound with no allocation and no yield: only the token's atomic read between rounds.
function spin(task_info)
    x = 0.0
    while !cancel_requested(task_info)
        for i in 1:10_000_000
            x += sin(i)
        end
    end
    return x
end

# Allocate without pause: a ring of small boxed objects (mark-heavy) that keeps `live_mb` alive,
# plus short-lived garbage, checking the token so a drain can stop it.
function churn(task_info, args::Churn)
    args.spin && return spin(task_info)
    per = 64                                    # bytes per small object, roughly
    n = args.live_mb * 1024 * 1024 ÷ per
    ring = Vector{Any}(undef, n)
    i = 0
    while !cancel_requested(task_info)
        for _ in 1:10_000
            i = i % n + 1
            ring[i] = (i, string(i), [i, i])     # small objects, replaced as the ring turns
        end
        tmp = rand(50_000)                       # short-lived garbage
        sum(tmp)
    end
    return i
end

inner = backend == "sqlite" ? Base.invokelatest(sqlite_store) : W.InMemoryWorkerStore()
store = TimedStore(inner, Float64[])
app = App()
declare_queues!(app, ["heavy" => External(on_lease_expiry = :requeue)])
register_job!(churn, app, "churn", Churn)
web = App()
declare_queues!(web, ["heavy" => External(on_lease_expiry = :requeue)])
register_job!(churn, web, "churn", Churn)
start!(web; store, cleanup_enabled = false, recover_zombies = false)
for j in 1:k
    submit_queued_task(web, "heavy", "c$j", Job("churn", Churn(live_mb, mode == "spin")), Owner("bench"))
end

gc0 = Base.gc_num()
c = W._start_consumer(app; store, queues = ["heavy" => k], lease, poll_interval = 0.1, drain_timeout = 30,
                       require_interactive = false)   # so `-t N,0` can measure the counterfactual
t0 = time()
sleep(seconds)
W._request_stop!(c)
W._drain!(c)
gc1 = Base.gc_num()

stamps = filter(t -> t >= t0, store.renewed_at)
gaps = diff(stamps)
tick = lease / 3
sorted = sort(gaps)
pct(p) = isempty(sorted) ? NaN : sorted[clamp(ceil(Int, p * length(sorted)), 1, length(sorted))]
@printf "julia %s  threads %d,%d  k=%d  mode=%s  store=%s  live=%d MiB/job  lease=%.1f s (tick %.2f s)  %.0f s\n" VERSION Threads.nthreads(:default) Threads.nthreads(:interactive) k mode backend live_mb lease tick seconds
@printf "renewals %d  gap p50 %.3f s  p99 %.3f s  max %.3f s  (max lateness %.3f s)\n" length(stamps) pct(0.5) pct(0.99) maximum(gaps; init = 0.0) maximum(gaps; init = 0.0) - tick
# A gap longer than the lease is a window in which the run's lease was expired: another consumer,
# or the web's retention tick, could have taken a healthy run back. The first renewal counts from
# the start of the measurement, so a heartbeat that never renewed at all shows here too.
first_gap = isempty(stamps) ? seconds : first(stamps) - t0
@printf "first renewal after %.3f s; gaps longer than the lease: %d\n" first_gap count(>(lease), [first_gap; gaps])
@printf "GC: %d collections (%d full), total pause %.2f s, max pause %.3f s\n" (gc1.pause - gc0.pause) (gc1.full_sweep - gc0.full_sweep) (gc1.total_time - gc0.total_time) / 1e9 gc1.max_pause / 1e9
