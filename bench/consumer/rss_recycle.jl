# What does a consumer process keep after a heavy run? (#514, step 4)
#
# A long-lived consumer's resident memory rises to its heaviest run's peak, and how much of it the
# process gives back afterwards decides whether recycling (`consume!(…; max_runs, max_rss_mb)`) is
# needed. This runs a real consumer (`_start_consumer`, the heartbeat on `:interactive`) over an
# in-process claim-capable store, submits one heavy job that keeps `live_mb` of small live objects
# for a few seconds and then drops them, and samples the process's memory throughout:
#
# - `rss` is the CURRENT resident set (`/proc/self/statm`, Linux only);
# - `maxrss` is `Sys.maxrss()`, the peak, which is what `max_rss_mb` compares against.
#
#   julia +1.12 --project=bench -t 2,2 bench/consumer/rss_recycle.jl [live_mb] [hold_seconds]
using Nitro, Nitro.Workers, Dates, Printf
const W = Nitro.Workers

live_mb = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 1024
hold = length(ARGS) >= 2 ? parse(Float64, ARGS[2]) : 5.0
Sys.islinux() || error("rss_recycle.jl reads /proc/self/statm, so it runs on Linux only")

const PAGE = ccall(:getpagesize, Cint, ())
rss_mb() = parse(Int, split(read("/proc/self/statm", String))[2]) * PAGE / 2^20
maxrss_mb() = Sys.maxrss() / 2^20

# An in-memory store that answers as a shared one, as the consumer tests' does: the claim
# operations are the in-memory ones, and `consume!`'s refusal of a store no other process can read
# is lifted, since there is no other process here.
struct BenchStore <: W.AbstractWorkerStore
    inner::W.InMemoryWorkerStore
end
for (f, n) in ((:get_task_info, 1), (:set_task!, 2), (:replace_task!, 2), (:add_watcher!, 2),
               (:try_transition!, 3), (:delete_task!, 1), (:try_delete_task!, 2), (:cleanup_tasks!, 1),
               (:get_all_tasks, 1), (:get_queue_authorizer, 0), (:set_queue_authorizer!, 1),
               (:get_watch_authorizer, 0), (:set_watch_authorizer!, 1), (:get_error_redactor, 0),
               (:set_error_redactor!, 1), (:claim_next!, 2), (:release_claim!, 2), (:renew_leases!, 2),
               (:requeue_expired!, 1), (:count_external_runs, 1), (:list_running_task_refs, 0))
    args = [Symbol("a", i) for i in 1:n]
    @eval W.$f(s::BenchStore, $(args...); kw...) = W.$f(s.inner, $(args...); kw...)
end
W.task_locks(s::BenchStore) = W.task_locks(s.inner)
W._visible_across_processes(::BenchStore) = true

Base.@kwdef struct Heavy
    live_mb::Int
    hold::Float64
end

const PHASE = Ref("idle")
function heavy(task_info, h::Heavy)
    PHASE[] = "allocating"
    # Small objects, as a real job's heap is made of, not one big array the allocator could hand
    # straight back to the OS.
    n = h.live_mb * 2^20 ÷ 64
    keep = Vector{Vector{Float64}}(undef, n)
    for i in 1:n
        keep[i] = rand(4)            # 32 B of payload plus the array header
    end
    PHASE[] = "holding"
    sleep(h.hold)
    PHASE[] = "returned"
    return length(keep)
end

function setup!(app)
    declare_queues!(app, ["heavy" => External(on_lease_expiry = :requeue)])
    register_job!(heavy, app, "heavy", Heavy)
    return app
end

samples = Tuple{Float64, String, Float64, Float64}[]
t0 = time()
sampling = Ref(true)
sampler = Threads.@spawn :interactive while sampling[]
    push!(samples, (time() - t0, PHASE[], rss_mb(), maxrss_mb()))
    sleep(0.1)
end

store = BenchStore(W.InMemoryWorkerStore())
web = setup!(App())
start!(web; store, cleanup_enabled = false, recover_zombies = false)
worker = setup!(App())
GC.gc(true)
floor_ = (rss_mb(), maxrss_mb())
c = W._start_consumer(worker; store, queues = ["heavy" => 1], lease = 30.0, poll_interval = 0.1)
id = submit_queued_task(web, "heavy", "h1", Job("heavy", Heavy(live_mb, hold)), Owner("bench"))
timedwait(() -> W.get_task_info(store, id).status == COMPLETED, 600; pollint = 0.1)
after_run = (rss_mb(), maxrss_mb())
PHASE[] = "idle after"
sleep(5)
after_idle = (rss_mb(), maxrss_mb())
GC.gc(true)
sleep(1)
after_gc = (rss_mb(), maxrss_mb())
trimmed = Sys.islinux() ? (ccall(:malloc_trim, Cint, (Csize_t,), 0); sleep(1); (rss_mb(), maxrss_mb())) : nothing
sampling[] = false
wait(sampler)
W._request_stop!(c); W._drain!(c)
uninstall!(web; drain_timeout = 0)

peak = maximum(s[3] for s in samples)
@printf("Julia %s, -t %d,%d, live_mb = %d, hold = %.1f s\n", VERSION, Threads.nthreads(:default),
        Threads.nthreads(:interactive), live_mb, hold)
@printf("%-26s %10s %10s\n", "", "rss MiB", "maxrss MiB")
for (label, (r, m)) in (("floor (consumer started)", floor_), ("run returned", after_run),
                        ("5 s idle", after_idle), ("after GC.gc(true)", after_gc),
                        ("after malloc_trim(0)", something(trimmed, (NaN, NaN))))
    @printf("%-26s %10.0f %10.0f\n", label, r, m)
end
@printf("%-26s %10.0f\n", "peak sampled rss", peak)
@printf("kept after GC: %.0f MiB above the floor (%.0f%% of the run's growth)\n",
        after_gc[1] - floor_[1], 100 * (after_gc[1] - floor_[1]) / (peak - floor_[1]))
