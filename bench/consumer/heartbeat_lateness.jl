# How late does a consumer's lease heartbeat run while its jobs allocate heavily? (#514)
#
# The lease must outlast the longest gap between two renewals, or a healthy run is taken back.
# A stop-the-world collection stops the interactive thread too, so the gap is bounded below by the
# worst GC pause the jobs cause, plus scheduling delay. This drives a real consumer
# (`_start_consumer`, the heartbeat on `:interactive`) over an in-process claim-capable store,
# runs `k` jobs that allocate as hard as they can, and records every successful renewal.
#
#   julia +1.12 --project=bench -t 4,1 bench/consumer/heartbeat_lateness.jl [seconds] [k] [live_mb] [mode]
#
# `live_mb` is the long-lived heap each job keeps (a ring of small objects), which is what makes a
# full collection's mark phase, and so its pause, long. `mode = spin` runs CPU-bound jobs that
# neither allocate nor yield instead: what the interactive-thread placement exists for.
using Nitro, Nitro.Workers, Dates, Printf
const W = Nitro.Workers

seconds = length(ARGS) >= 1 ? parse(Float64, ARGS[1]) : 60.0
k = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 3
live_mb = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 256
mode = length(ARGS) >= 4 ? ARGS[4] : "churn"
lease = 3.0                                     # heartbeat every 1 s

# An in-memory store that answers like a shared one, and timestamps every renewal it serves.
struct TimedStore <: W.AbstractWorkerStore
    inner::W.InMemoryWorkerStore
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
W.lock_tasks(cb::Function, s::TimedStore) = W.lock_tasks(cb, s.inner)
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

store = TimedStore(W.InMemoryWorkerStore(), Float64[])
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
@printf "julia %s  threads %d,%d  k=%d  mode=%s  live=%d MiB/job  lease=%.1f s (tick %.2f s)  %.0f s\n" VERSION Threads.nthreads(:default) Threads.nthreads(:interactive) k mode live_mb lease tick seconds
@printf "renewals %d  gap p50 %.3f s  p99 %.3f s  max %.3f s  (max lateness %.3f s)\n" length(stamps) pct(0.5) pct(0.99) maximum(gaps; init = 0.0) maximum(gaps; init = 0.0) - tick
@printf "GC: %d collections (%d full), total pause %.2f s, max pause %.3f s\n" (gc1.pause - gc0.pause) (gc1.full_sweep - gc0.full_sweep) (gc1.total_time - gc0.total_time) / 1e9 gc1.max_pause / 1e9
