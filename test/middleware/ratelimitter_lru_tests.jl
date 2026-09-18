@testitem "Rate limiter LRU" tags=[:middleware, :network, :slow] setup=[NitroCommon] begin
using HTTP
using Dates
using Nitro

port = get_free_port()
localhost = "http://$HOST:$port"

# Route-level limiters, sized by the same enforcement/recovery split the comment below
# describes — it was applied to the two global-middleware testsets and never carried to
# these two, which kept racing 51- and 26-request bursts against a 3s window (#212).
urlpatterns("/limited",
    path("/goodbye", function() return "goodbye" end, method="GET",
        middleware=[RateLimiter(strategy=:sliding_window, rate_limit=1, window=Second(3))]),
    path("/greet", function() return "hello" end, method="GET",
        middleware=[RateLimiter(strategy=:sliding_window, rate_limit=3, window=Second(30))]),
)
urlpatterns("",
    path("/ok", function() return "ok" end, method="GET"),
)

# The sliding-window strategy prunes timestamps per-request, so a burst that
# spans the window lets early requests age out before the limit is reached. On a
# loaded CI run (parallel workers compiling at startup) even a few localhost
# round-trips can take seconds, which made the original "fire N requests within a
# 3s window" approach flaky. Enforcement and recovery are therefore tested
# separately so neither depends on a burst-vs-window timing race:
#   • enforcement uses a large window the tiny burst cannot possibly span;
#   • recovery uses rate_limit=1 so it only ever issues single requests.

# ── Enforcement: limit is applied and the remaining counter decrements ─────────
serve(middleware=[RateLimiter(strategy=:sliding_window, rate_limit=3, window=Minute(1))], port=port, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

@testset "Sliding Window Enforcement" begin
    # First request: verify headers and remaining countdown start
    r = HTTP.get("$localhost/ok")
    @test r.status == 200
    @test text(r) == "ok"
    @test HTTP.header(r, "X-RateLimit-Limit") == "3"
    @test HTTP.header(r, "X-RateLimit-Remaining") == "2"
    @test parse(Int, HTTP.header(r, "X-RateLimit-Reset")) > 0

    # Exhaust the remaining quota; the window is far larger than the burst, so
    # the counter decrements deterministically regardless of request latency.
    @test HTTP.header(HTTP.get("$localhost/ok"), "X-RateLimit-Remaining") == "1"
    @test HTTP.header(HTTP.get("$localhost/ok"), "X-RateLimit-Remaining") == "0"

    # Next request must be rate limited (429)
    try
        HTTP.get("$localhost/ok"; retry=false)
        @test false  # Should not reach here
    catch e
        @test e isa HTTP.StatusError
        @test e.response.status == 429
        @test HTTP.header(e.response, "X-RateLimit-Limit") == "3"
        @test HTTP.header(e.response, "X-RateLimit-Remaining") == "0"
        @test parse(Int, HTTP.header(e.response, "X-RateLimit-Reset")) > 0
    end
end
terminate()

sleep(1)  # let the port free up before re-binding

# ── Recovery: a slot frees up once its window elapses ──────────────────────────
serve(middleware=[RateLimiter(strategy=:sliding_window, rate_limit=1, window=Second(3))], port=port, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

@testset "Sliding Window Recovery" begin
    # First request consumes the only slot
    r = HTTP.get("$localhost/ok")
    @test r.status == 200
    @test HTTP.header(r, "X-RateLimit-Remaining") == "0"

    # An immediate follow-up is rate limited (both fall within the same window)
    try
        HTTP.get("$localhost/ok"; retry=false)
        @test false  # Should not reach here
    catch e
        @test e isa HTTP.StatusError
        @test e.response.status == 429
    end

    # After the window elapses the slot frees up again. `retry=false` matters: HTTP.jl
    # treats 429 as retryable and would silently retry a still-throttled GET four times
    # with backoff, turning "recovered within 3.1s" into "recovered within ~5s".
    sleep(3.1)
    r = HTTP.get("$localhost/ok"; retry=false)
    @test r.status == 200
    @test HTTP.header(r, "X-RateLimit-Remaining") == "0"
    # At rate_limit=1 the remaining counter reads "0" both when throttled and when freshly
    # reset, so it discriminates nothing on its own. The reset header does: the only live
    # timestamp is the one this request just added, so the slot frees a full window out.
    @test HTTP.header(r, "X-RateLimit-Reset") == "3"
end
terminate()


# Create a server without global middleware but with route-level middleware on /limited/*
# The JIT warmup and the inter-testset sleeps that used to sit here are gone: both existed
# only to service the burst-vs-window race the limits at the top removed (#212).
serve(port=port, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

@testset "Limited Greet Endpoint Rate Limiter" begin
    # First request: verify headers
    r = HTTP.get("$localhost/limited/greet")
    @test r.status == 200
    @test text(r) == "hello"
    @test HTTP.header(r, "X-RateLimit-Limit") == "3"
    @test HTTP.header(r, "X-RateLimit-Remaining") == "2"
    reset_time = parse(Int, HTTP.header(r, "X-RateLimit-Reset"))
    @test reset_time > 0 && reset_time <= 30

    # Exhaust the remaining quota one deterministic decrement at a time
    @test HTTP.header(HTTP.get("$localhost/limited/greet"), "X-RateLimit-Remaining") == "1"
    @test HTTP.header(HTTP.get("$localhost/limited/greet"), "X-RateLimit-Remaining") == "0"

    # 4th request should be rate limited (429)
    try
        HTTP.get("$localhost/limited/greet"; retry=false)
        @test false
    catch e
        @test e isa HTTP.StatusError
        @test e.response.status == 429
        @test HTTP.header(e.response, "X-RateLimit-Limit") == "3"
        @test HTTP.header(e.response, "X-RateLimit-Remaining") == "0"
        reset_time = parse(Int, HTTP.header(e.response, "X-RateLimit-Reset"))
        @test reset_time > 0 && reset_time <= 30
    end
end

@testset "Limited Other Endpoint Rate Limiter" begin
    # Route-level recovery. `rate_limit=1` keeps this to single requests, so the 3s window
    # is waited out rather than raced against a burst — the route-level mirror of the
    # "Sliding Window Recovery" testset above, which covers the global-middleware case.
    r = HTTP.get("$localhost/limited/goodbye")
    @test r.status == 200
    @test text(r) == "goodbye"
    @test HTTP.header(r, "X-RateLimit-Limit") == "1"
    @test HTTP.header(r, "X-RateLimit-Remaining") == "0"
    reset_time = parse(Int, HTTP.header(r, "X-RateLimit-Reset"))
    @test reset_time > 0 && reset_time <= 3

    # An immediate follow-up is refused
    try
        HTTP.get("$localhost/limited/goodbye"; retry=false)
        @test false
    catch e
        @test e isa HTTP.StatusError
        @test e.response.status == 429
        @test HTTP.header(e.response, "X-RateLimit-Limit") == "1"
        @test HTTP.header(e.response, "X-RateLimit-Remaining") == "0"
    end

    # Wait for reset and verify recovery. See "Sliding Window Recovery" above for why
    # `retry=false` and the reset-header assertion are both load-bearing here.
    sleep(3.1)
    r = HTTP.get("$localhost/limited/goodbye"; retry=false)
    @test r.status == 200
    @test HTTP.header(r, "X-RateLimit-Remaining") == "0"
    @test HTTP.header(r, "X-RateLimit-Reset") == "3"
end

terminate()

# Start server for exempt paths test
urlpatterns("",
    path("/limited", function() return "limited" end, method="GET"),
    path("/exempt",  function() return "exempt" end,  method="GET"),
)

# Subject is exempt-path behaviour, not window expiry, so the window is sized to be
# unreachable by the burst rather than raced against it — the sibling of the assertion
# that flaked on macOS at -t 1 in ratelimitter_tests.jl (#212).
serve(middleware=[RateLimiter(strategy=:sliding_window, rate_limit=3, window=Second(30), exempt_paths=["/exempt"])], port=port, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

@testset "Exempt Paths Test" begin
    # First request to /limited should succeed with headers
    r = HTTP.get("$localhost/limited")
    @test r.status == 200
    @test text(r) == "limited"
    @test HTTP.header(r, "X-RateLimit-Limit") == "3"
    @test HTTP.header(r, "X-RateLimit-Remaining") == "2"
    reset_time = parse(Int, HTTP.header(r, "X-RateLimit-Reset"))
    @test reset_time > 0 && reset_time <= 30

    # Exhaust the remaining quota one deterministic decrement at a time
    @test HTTP.header(HTTP.get("$localhost/limited"), "X-RateLimit-Remaining") == "1"
    @test HTTP.header(HTTP.get("$localhost/limited"), "X-RateLimit-Remaining") == "0"

    # 4th request should be rate limited (429)
    try
        HTTP.get("$localhost/limited"; retry=false)
        @test false
    catch e
        @test e isa HTTP.StatusError
        @test e.response.status == 429
        @test HTTP.header(e.response, "X-RateLimit-Limit") == "3"
        @test HTTP.header(e.response, "X-RateLimit-Remaining") == "0"
        reset_time = parse(Int, HTTP.header(e.response, "X-RateLimit-Reset"))
        @test reset_time > 0 && reset_time <= 30
    end

    # Exempt path should succeed and have no rate limit headers
    r = HTTP.get("$localhost/exempt")
    @test r.status == 200
    @test text(r) == "exempt"
    @test !HTTP.hasheader(r, "X-RateLimit-Limit")
    @test !HTTP.hasheader(r, "X-RateLimit-Remaining")
    @test !HTTP.hasheader(r, "X-RateLimit-Reset")
end

terminate()

# Start server for multiple exempt paths test
urlpatterns("",
    path("/limited",   function() return "limited" end,   method="GET"),
    path("/exempt1",  function() return "exempt1" end,   method="GET"),
    path("/exempt2",  function() return "exempt2" end,   method="GET"),
    path("/notexempt", function() return "notexempt" end, method="GET"),
)

# Same sizing as the single-exempt-path testset above: the window cannot be spanned by
# the burst, so the per-request decrements are deterministic (#212).
serve(middleware=[RateLimiter(strategy=:sliding_window, rate_limit=3, window=Second(30), exempt_paths=["/exempt1", "/exempt2"])], port=port, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

@testset "Multiple Exempt Paths Test" begin
    # First 3 requests to /limited should succeed
    for i in 1:3
        r = HTTP.get("$localhost/limited")
        @test r.status == 200
        @test text(r) == "limited"
        @test HTTP.header(r, "X-RateLimit-Limit") == "3"
        @test HTTP.header(r, "X-RateLimit-Remaining") == string(3 - i)
    end

    # 4th request to /limited should be rate limited
    try
        HTTP.get("$localhost/limited"; retry=false)
        @test false
    catch e
        @test e.response.status == 429
    end

    # Requests to exempt paths should succeed and not have headers
    for path in ["/exempt1", "/exempt2"]
        r = HTTP.get("$localhost$path")
        @test r.status == 200
        @test text(r) == split(path, "/")[2]  # "exempt1" or "exempt2"
        @test !HTTP.hasheader(r, "X-RateLimit-Limit")
        @test !HTTP.hasheader(r, "X-RateLimit-Remaining")
        @test !HTTP.hasheader(r, "X-RateLimit-Reset")
    end

    # Requests to /notexempt should also be limited
    try
        HTTP.get("$localhost/notexempt"; retry=false)
        @test false
    catch e
        @test e.response.status == 429
    end
end

terminate()

end

@testitem "Sliding rate limiter does not hold its lock across the handler" tags=[:middleware] setup=[NitroCommon] begin
using HTTP
using Dates
using Sockets
using Nitro
using Nitro: setip!

# Regression test for #15. `SlidingRateLimiter` used to call the downstream handler
# from inside `lock(store_lock) do … end`, so the whole inner middleware chain and
# route handler ran while a limiter-wide lock was held. Under Nitro's
# `Threads.@spawn`-per-request model (nitro-core §2) that serialised every request
# through that limiter behind whichever handler happened to be slowest.
#
# The bug has no functional signature — status, body and headers are identical either
# way — so wall-clock overlap is the only observable. These are the repo's only
# `@elapsed` assertions; the margins are deliberately generous (4x in testset 1, 2x in
# testset 4), and testsets 2 and 3 add deterministic (non-timing) assertions so the item
# still has teeth on a slow machine.
#
# Driven in-process (cf. test/middleware/shared_response_mutation_tests.jl) rather than
# through a live server, so the measurement isn't polluted by HTTP.jl's connection pool
# and accept loop. `RateLimiter` returns a `LifecycleMiddleware` whichever strategy you pick
# (#172), so the `handle -> req -> resp` closure is its `.middleware` field;
# `auto_extract_ip=false` makes that closure the bare limiter with no `ExtractIP` composed in
# front of it, so each synthetic request
# must carry its own IP via `setip!` — a request with no IP is caught by the limiter's
# explicit guard, which fail-closes to 503 (or passes through under `fail_open=true`).
# See the "no client IP" testset in test/middleware/ratelimitter_tests.jl.

const DELAY = 0.2          # per-request handler latency
const N     = 8            # concurrent requests (must be < rate_limit, or the surplus
                           # is rejected with 429 and never reaches the sleep)

make_request(ip) = begin
    r = HTTP.Request("GET", "/")
    setip!(r, ip)
    return r
end

# ── 1. Concurrency: N slow requests must overlap, not serialize ────────────────
@testset "Handler runs outside store_lock" begin
    slow = req -> (sleep(DELAY); HTTP.Response(200, "ok"))
    wrapped = RateLimiter(strategy=:sliding_window, rate_limit=100,
                          window=Minute(1), auto_extract_ip=false).middleware(slow)
    ip = IPv4("10.0.0.1")

    # Warm up: JIT the limiter closure, own_response_headers and set_rate_headers!
    # before anything is timed. On a cold ReTestItems worker, compilation alone can
    # otherwise exceed the budget below.
    @test wrapped(make_request(ip)).status == 200

    responses = Vector{HTTP.Response}(undef, N)
    elapsed = @elapsed begin
        # `@async`, not `Threads.@spawn`: ReTestItems workers default to
        # nworker_threads = 1, and `sleep` yields, so this exercises the lock
        # contention identically at 1 thread and at N threads.
        @sync for i in 1:N
            @async responses[i] = wrapped(make_request(ip))
        end
    end

    @test all(r -> r.status == 200, responses)

    # Fixed:  ~DELAY       (all N sleeps overlap)      -> ~0.2s
    # Buggy:  ~N * DELAY   (each waits for store_lock) -> ~1.6s
    @test elapsed < 4 * DELAY
end

# ── 2. The lock still does its job: no lost updates on the shared bucket ───────
@testset "Counter is still serialized under concurrency" begin
    limit = 100
    wrapped = RateLimiter(strategy=:sliding_window, rate_limit=limit,
                          window=Minute(1), auto_extract_ip=false).middleware(
        req -> (yield(); HTTP.Response(200, "ok")))
    ip = IPv4("10.0.0.2")

    remaining = Vector{Int}(undef, N)
    @sync for i in 1:N
        @async begin
            r = wrapped(make_request(ip))
            remaining[i] = parse(Int, HTTP.header(r, "X-RateLimit-Remaining"))
        end
    end

    # Each admitted request must consume exactly one distinct slot. Order-independent,
    # so it holds under `-t auto` too. A read-modify-write moved out of store_lock
    # would show up here as duplicated values.
    @test sort(remaining) == collect((limit - N):(limit - 1))
end

# ── 3. The limit itself still holds under concurrent load ─────────────────────
@testset "Exactly rate_limit requests are admitted" begin
    limit = 50
    wrapped = RateLimiter(strategy=:sliding_window, rate_limit=limit,
                          window=Minute(1), auto_extract_ip=false).middleware(
        req -> (yield(); HTTP.Response(200, "ok")))
    ip = IPv4("10.0.0.3")

    statuses = Vector{Int}(undef, 2 * limit)
    @sync for i in 1:(2 * limit)
        Threads.@spawn statuses[i] = wrapped(make_request(ip)).status
    end

    @test count(==(200), statuses) == limit
    @test count(==(429), statuses) == limit
end

# ── 4. A rejection is not stuck behind an in-flight slow handler ──────────────
@testset "429 is served while slow handlers are in flight" begin
    limit = 2
    wrapped = RateLimiter(strategy=:sliding_window, rate_limit=limit,
                          window=Minute(1), auto_extract_ip=false).middleware(
        req -> (sleep(DELAY); HTTP.Response(200, "ok")))

    # Warm both the admit and reject paths on a throwaway limiter with a fast handler.
    # Closure specializations are shared across instances, so this JITs everything the
    # timed section below needs without spending the real limiter's quota — and keeps
    # this testset independent of whether testset 3 ran first.
    warmup = RateLimiter(strategy=:sliding_window, rate_limit=1, window=Minute(1),
                         auto_extract_ip=false).middleware(req -> HTTP.Response(200, "ok"))
    @test warmup(make_request(IPv4("10.0.0.4"))).status == 200
    @test warmup(make_request(IPv4("10.0.0.4"))).status == 429

    # Saturate the quota; both handlers are now parked in `sleep(DELAY)`.
    ip = IPv4("10.0.0.5")
    inflight = [@async wrapped(make_request(ip)) for _ in 1:limit]
    sleep(DELAY / 4)   # let both tasks reach the sleep

    # This request is rejected without consulting the handler at all, so it must not
    # wait on the in-flight ones. Pre-fix it blocks on store_lock until at least the
    # first slow handler returns (>= 0.75 * DELAY remaining here); post-fix the lock is
    # free and the 429 is built in microseconds.
    rejected = nothing
    elapsed = @elapsed (rejected = wrapped(make_request(ip)))

    @test rejected.status == 429
    @test HTTP.header(rejected, "X-RateLimit-Remaining") == "0"
    @test elapsed < DELAY / 2

    # Drain the in-flight requests so the testset doesn't leak running tasks.
    @test all(r -> r.status == 200, fetch.(inflight))
end

# ── Lock striping: the size-bounded store must not evict early (#22) ──────────
# The sliding limiter's LRU is size-bounded, and striping divides `max_clients` across
# the stripes. Naively splitting a small cache 16 ways would evict a client while the
# store held a fraction of what the caller asked for -- silently, and looking like the
# limit simply reset. `_bounded_stripe_count` collapses small caches to a single stripe
# to keep the caller's bound meaningful.

@testset "Sliding limiter: stripe count keeps max_clients honest" begin
    bsc = Nitro.Core.RateLimiterMiddleware._bounded_stripe_count

    # Too small to divide: one stripe, i.e. exactly the pre-striping behaviour.
    @test bsc(1) == 1
    @test bsc(100) == 1
    @test bsc(127) == 1

    # Large enough to divide, and always a power of two (stripe selection is a mask).
    @test bsc(128) == 2
    @test bsc(10_000) == 16
    for m in (128, 500, 1024, 10_000, 1_000_000)
        n = bsc(m)
        @test ispow2(n)
        @test n <= 16
        # Never fewer than ~64 entries per stripe.
        @test cld(m, n) >= 64
    end
end

@testset "Sliding limiter: stripes evict independently" begin
    # The property striping actually introduces: each stripe has its OWN LRU budget, so
    # flooding one stripe must not evict buckets held by another -- otherwise the victim
    # silently gets a fresh quota, which is a rate-limit bypass.
    #
    # Which assertion catches which regression (simulated against both buggy shapes):
    #   selection collapsed onto one stripe -> the MIDDLE assertion fires (victim evicted
    #     by the other stripe's flood).
    #   stripes sharing one store of 128    -> the middle assertion still passes (85 entries
    #     in a 128 store evicts nothing); the FINAL assertion is what fires.
    # So the non-vacuousness check at the end is load-bearing, not decoration.
    #
    # White-box on purpose: the stripe index is `hash(key) & (n-1)`, so the keys are sorted
    # into stripes here the same way the limiter does it. max_clients=128 gives exactly
    # 2 stripes of 64 (asserted below, so this test fails loudly if the sizing changes).
    RL = Nitro.Core.RateLimiterMiddleware
    nstripes = RL._bounded_stripe_count(128)
    @test nstripes == 2
    per_stripe = cld(128, nstripes)
    @test per_stripe == 64

    v4mask, v6mask = RL._prefix_masks(32, 64)
    stripe_of(ip) = (hash(RL._bucket_key(ip, v4mask, v6mask)) & UInt(nstripes - 1)) + 1

    ips = [IPv4("10.$(div(i, 256)).$(mod(i, 256)).1") for i in 0:1499]
    by_stripe = Dict(k => filter(ip -> stripe_of(ip) == k, ips) for k in 1:nstripes)
    # Must cover the `per_stripe + 20` slices taken below, or a hash change turns a clean
    # failure into a BoundsError.
    @test all(length(v) > per_stripe + 20 for v in values(by_stripe))

    limit = 1
    wrapped = RateLimiter(strategy=:sliding_window, rate_limit=limit, window=Minute(1),
                          max_clients=128, auto_extract_ip=false).middleware(
        _ -> HTTP.Response(200, "ok"))
    req_from(ip) = (r = HTTP.Request("GET", "/"); setip!(r, ip); r)

    # A victim on stripe 1 spends its single request.
    victim = by_stripe[1][1]
    @test wrapped(req_from(victim)).status == 200
    @test wrapped(req_from(victim)).status == 429

    # Flood stripe 2 with far more than its own budget. None of these touch stripe 1.
    for ip in by_stripe[2][1:(per_stripe + 20)]
        wrapped(req_from(ip))
    end

    # The victim's bucket must be untouched -- still out of quota.
    @test wrapped(req_from(victim)).status == 429

    # And flooding the victim's OWN stripe past its budget does evict it, which is what
    # proves the assertion above was not vacuous.
    for ip in by_stripe[1][2:(per_stripe + 20)]
        wrapped(req_from(ip))
    end
    @test wrapped(req_from(victim)).status == 200
end

end
