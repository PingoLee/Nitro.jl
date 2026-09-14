# RateLimiter hot path (#22). Three costs are measured, all through the composed
# middleware with `auto_extract_ip=false` and the IP assigned directly, so the
# numbers isolate the limiter from `ExtractIP` and from the socket layer:
#
#   single_key  — uncontended lock + keying cost per request
#   many_keys   — the same, rotating over distinct clients (bucket lookup, and for
#                 the sliding limiter, LRU behaviour)
#   contended   — N concurrent tasks on DISTINCT keys. Before striping, every one of
#                 them serialises on the single `store_lock` even though their buckets
#                 are independent; this is the benchmark the striping has to move.
#
# `exempt_miss_k*` measures the per-request exempt-path scan on a MISS, which is what
# every non-exempt request pays. Read it as a DELTA across k, not as an absolute.
#
# Requests are built once and reused: the limiter only reads `req.target` and
# `getip(req)`, and `HTTP.Request` construction otherwise dominates every number here
# and swamps the signal. Windows are short and limits huge on purpose — the point is
# the per-request bookkeeping, never the 429 path, and a short window keeps the
# sliding limiter's timestamp vector small so `filter!` does not dominate.

using Sockets
using Base.Threads: @spawn

SUITE["ratelimiter"] = BenchmarkGroup()

const RL_HANDLER = (req) -> HTTP.Response(200, "ok")
const RL_NTASKS = 64

# `FixedRateLimiter` returns a LifecycleMiddleware; `SlidingRateLimiter` a bare function.
rl_mw(x) = x isa Nitro.LifecycleMiddleware ? x.middleware : x

rl_build(strategy::Symbol; kwargs...) =
    rl_mw(Nitro.RateLimiter(; strategy, auto_extract_ip = false,
                              rate_limit = 10^9, window = Dates.Millisecond(10),
                              kwargs...))(RL_HANDLER)

function rl_req(ip::Sockets.IPAddr, target::String = "/bench/rl")
    r = HTTP.Request("GET", target)
    Nitro.Core.setip!(r, ip)
    return r
end

# DISTINCT clients: one address per /64, so these are separate buckets under both the
# old (/128) and the new (/64) keying. Addresses inside a SINGLE /64 would be 1024
# buckets before the fix and one bucket after — which measures two different things and
# reads as a regression. That set is benchmarked separately below, on purpose.
const RL_REQS = [rl_req(IPv6("2001:db8:0:$(string(i, base = 16))::1")) for i in 1:1024]

# One client rotating source addresses inside its own /64 — the #22 attack. Before the
# fix these were 1024 independent buckets and the limit was never reached; after it they
# are one bucket, so this measures the cost of the now-correctly-hot bucket.
const RL_ROTATING = [rl_req(IPv6("2001:db8::$(string(i, base = 16))")) for i in 1:1024]

const RL_FIXED   = rl_build(:fixed_window)
const RL_SLIDING = rl_build(:sliding_window)

# Fan out over distinct keys and wait. Measures wall time for the whole batch, so
# lock serialisation shows up directly.
function rl_contended(mw, reqs)
    tasks = Vector{Task}(undef, RL_NTASKS)
    for t in 1:RL_NTASKS
        r = reqs[t]
        tasks[t] = @spawn mw(r)
    end
    foreach(wait, tasks)
    return nothing
end

for (label, mw) in ("fixed" => RL_FIXED, "sliding" => RL_SLIDING)
    SUITE["ratelimiter"]["$(label)_single_key"] =
        @benchmarkable $mw(RL_REQS[1])
    SUITE["ratelimiter"]["$(label)_many_keys"] =
        @benchmarkable $mw(RL_REQS[i]) setup = (i = rand(1:length(RL_REQS)))
    SUITE["ratelimiter"]["$(label)_contended"] =
        @benchmarkable rl_contended($mw, RL_REQS)
    SUITE["ratelimiter"]["$(label)_rotating_one_prefix"] =
        @benchmarkable rl_contended($mw, RL_ROTATING)
end

# Exempt-path scan, miss case, at three list sizes. `/bench/rl` matches none of them,
# so each is a full scan of the list — the worst case for a linear matcher.
for k in (1, 8, 64)
    paths = ["/exempt$(i)/" for i in 1:k]
    mw = rl_build(:fixed_window; exempt_paths = paths)
    SUITE["ratelimiter"]["exempt_miss_k$(k)"] = @benchmarkable $mw(RL_REQS[1])
end
