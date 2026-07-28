@testitem "Rate limiter LRU" tags=[:middleware, :network, :slow] setup=[NitroCommon] begin
using HTTP
using Dates
using Nitro

urlpatterns("/limited",
    path("/goodbye", function() return "goodbye" end, method="GET",
        middleware=[RateLimiter(strategy=:sliding_window, rate_limit=25, window=Second(3))]),
    path("/greet", function() return "hello" end, method="GET",
        middleware=[RateLimiter(strategy=:sliding_window, rate_limit=50, window=Second(3))]),
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
serve(middleware=[RateLimiter(strategy=:sliding_window, rate_limit=3, window=Minute(1))], port=PORT, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

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
serve(middleware=[RateLimiter(strategy=:sliding_window, rate_limit=1, window=Second(3))], port=PORT, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

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

    # After the window elapses the slot frees up again
    sleep(3.1)
    r = HTTP.get("$localhost/ok")
    @test r.status == 200
    @test HTTP.header(r, "X-RateLimit-Remaining") == "0"
end
terminate()


# Create a server without global middleware but with route-level middleware on /limited/*
serve(port=PORT, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

# Warm up the route + middleware code paths before the timed bursts below, so first-request
# JIT compilation isn't spent inside the 3s rate-limit window. These warmup hits age out of
# the window during the sleeps below, so they don't affect the bucket assertions.
HTTP.get("$localhost/limited/greet")
HTTP.get("$localhost/limited/goodbye")

sleep(5) # Ensure rate limiter window is completely reset and any background cleanup is done

@testset "Limited Greet Endpoint Rate Limiter" begin
    # First request: verify headers
    r = HTTP.get("$localhost/limited/greet")
    @test r.status == 200
    @test text(r) == "hello"
    @test HTTP.header(r, "X-RateLimit-Limit") == "50"
    @test HTTP.header(r, "X-RateLimit-Remaining") == "49"
    reset_time = parse(Int, HTTP.header(r, "X-RateLimit-Reset"))
    @test reset_time > 0 && reset_time <= 3

    # Exhaust remaining quota
    for _ in 2:50
        HTTP.get("$localhost/limited/greet")
    end

    # 51st request should be rate limited (429)
    try
        HTTP.get("$localhost/limited/greet"; retry=false)
        @test false
    catch e
        @test e isa HTTP.StatusError
        @test e.response.status == 429
        @test HTTP.header(e.response, "X-RateLimit-Limit") == "50"
        @test HTTP.header(e.response, "X-RateLimit-Remaining") == "0"
        reset_time = parse(Int, HTTP.header(e.response, "X-RateLimit-Reset"))
        @test reset_time > 0 && reset_time <= 3
    end

    # Wait for reset and verify recovery
    sleep(3.1)
    r = HTTP.get("$localhost/limited/greet")
    @test r.status == 200
    @test HTTP.header(r, "X-RateLimit-Remaining") == "49"
end

sleep(3.1) # Ensure rate limiter window is reset before starting next testset

@testset "Limited Other Endpoint Rate Limiter" begin
    # First request: verify route-level rate limiting headers. Use `HTTP.get` (pooled
    # keep-alive) rather than bare `HTTP.request`, so the 25-request burst stays well
    # inside the 3s window — see the "Limited Greet Endpoint" testset above.
    r = HTTP.get("$localhost/limited/goodbye")
    @test r.status == 200
    @test text(r) == "goodbye"
    @test HTTP.header(r, "X-RateLimit-Limit") == "25"
    @test HTTP.header(r, "X-RateLimit-Remaining") == "24"
    reset_time = parse(Int, HTTP.header(r, "X-RateLimit-Reset"))
    @test reset_time > 0 && reset_time <= 3

    # Exhaust remaining quota
    for _ in 2:25
        HTTP.get("$localhost/limited/goodbye")
    end

    # 26th request should be rate limited (429)
    try
        HTTP.get("$localhost/limited/goodbye"; retry=false)
        @test false
    catch e
        @test e isa HTTP.StatusError
        @test e.response.status == 429
        @test HTTP.header(e.response, "X-RateLimit-Limit") == "25"
        @test HTTP.header(e.response, "X-RateLimit-Remaining") == "0"
        reset_time = parse(Int, HTTP.header(e.response, "X-RateLimit-Reset"))
        @test reset_time > 0 && reset_time <= 3
    end

    # Wait for reset and verify recovery
    sleep(3.1)
    r = HTTP.get("$localhost/limited/goodbye")
    @test r.status == 200
    @test HTTP.header(r, "X-RateLimit-Remaining") == "24"
end

terminate()

# Start server for exempt paths test
urlpatterns("",
    path("/limited", function() return "limited" end, method="GET"),
    path("/exempt",  function() return "exempt" end,  method="GET"),
)

serve(middleware=[RateLimiter(strategy=:sliding_window, rate_limit=10, window=Second(1), exempt_paths=["/exempt"])], port=PORT, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

@testset "Exempt Paths Test" begin
    # First request to /limited should succeed with headers
    r = HTTP.get("$localhost/limited")
    @test r.status == 200
    @test text(r) == "limited"
    @test HTTP.header(r, "X-RateLimit-Limit") == "10"
    @test HTTP.header(r, "X-RateLimit-Remaining") == "9"
    reset_time = parse(Int, HTTP.header(r, "X-RateLimit-Reset"))
    @test reset_time > 0 && reset_time <= 1

    # Exhaust remaining quota
    for _ in 2:10
        HTTP.get("$localhost/limited")
    end

    # 11th request should be rate limited (429)
    try
        HTTP.get("$localhost/limited"; retry=false)
        @test false
    catch e
        @test e isa HTTP.StatusError
        @test e.response.status == 429
        @test HTTP.header(e.response, "X-RateLimit-Limit") == "10"
        @test HTTP.header(e.response, "X-RateLimit-Remaining") == "0"
        reset_time = parse(Int, HTTP.header(e.response, "X-RateLimit-Reset"))
        @test reset_time > 0 && reset_time <= 1
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

serve(middleware=[RateLimiter(strategy=:sliding_window, rate_limit=5, window=Second(1), exempt_paths=["/exempt1", "/exempt2"])], port=PORT, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

@testset "Multiple Exempt Paths Test" begin
    # First 5 requests to /limited should succeed
    for i in 1:5
        r = HTTP.get("$localhost/limited")
        @test r.status == 200
        @test text(r) == "limited"
        @test HTTP.header(r, "X-RateLimit-Limit") == "5"
        @test HTTP.header(r, "X-RateLimit-Remaining") == string(5 - i)
    end

    # 6th request to /limited should be rate limited
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
# way — so wall-clock overlap is the only observable. This is the repo's only
# `@elapsed` assertion; the margin is deliberately 4x, and testsets 2 and 3 add
# deterministic (non-timing) assertions so the item still has teeth on a slow machine.
#
# Driven in-process (cf. test/middleware/shared_response_mutation_tests.jl) rather than
# through a live server, so the measurement isn't polluted by HTTP.jl's connection pool
# and accept loop. `auto_extract_ip=false` makes RateLimiter return the bare
# `handle -> req -> resp` closure; with no ExtractIP in front, each synthetic request
# must carry its own IP via `setip!` (an `LRU{IPAddr,…}` key of `nothing` throws and
# the limiter fail-closes to 503).

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
                          window=Minute(1), auto_extract_ip=false)(slow)
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
    wrapped = RateLimiter(strategy=:sliding_window, rate_limit=100,
                          window=Minute(1), auto_extract_ip=false)(
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
    @test sort(remaining) == collect((100 - N):99)
end

# ── 3. The limit itself still holds under concurrent load ─────────────────────
@testset "Exactly rate_limit requests are admitted" begin
    limit = 50
    wrapped = RateLimiter(strategy=:sliding_window, rate_limit=limit,
                          window=Minute(1), auto_extract_ip=false)(
        req -> (yield(); HTTP.Response(200, "ok")))
    ip = IPv4("10.0.0.3")

    statuses = Vector{Int}(undef, 2 * limit)
    @sync for i in 1:(2 * limit)
        Threads.@spawn statuses[i] = wrapped(make_request(ip)).status
    end

    @test count(==(200), statuses) == limit
    @test count(==(429), statuses) == limit
end
end