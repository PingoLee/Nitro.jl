@testitem "Rate limiter" tags=[:middleware, :network, :slow] setup=[NitroCommon] begin
using HTTP
using Dates
using Sockets
using Nitro

urlpatterns("/limited",
    path("/goodbye", function() return "goodbye" end, method="GET",
        middleware=[RateLimiter(rate_limit=25, window=Second(3))]),
    path("/greet", function() return "hello" end, method="GET",
        middleware=[RateLimiter(rate_limit=50, window_period=Second(3))]),
)
urlpatterns("",
    path("/ok", function() return "ok" end, method="GET"),
)

# Create a rate limiter with realistic limits for testing (100 requests per second)
serve(middleware=[RateLimiter(rate_limit=100, window=Second(3))], port=PORT, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

@testset "Rate Limiter Tests" begin

    # First request: verify headers and countdown start
    r = HTTP.get("$localhost/ok")
    @test r.status == 200
    @test text(r) == "ok"
    @test HTTP.header(r, "X-RateLimit-Limit") == "100"
    @test HTTP.header(r, "X-RateLimit-Remaining") == "99"
    reset_time = parse(Int, HTTP.header(r, "X-RateLimit-Reset"))
    @test reset_time > 0 && reset_time <= 3

    # Exhaust the remaining quota (no per-request assertions needed)
    for _ in 2:100
        HTTP.get("$localhost/ok")
    end

    # Next request must be rate limited (429)
    try
        HTTP.get("$localhost/ok"; retry=false)
        @test false  # Should not reach here
    catch e
        @test e isa HTTP.Exceptions.StatusError
        @test e.response.status == 429
        @test HTTP.header(e.response, "X-RateLimit-Limit") == "100"
        @test HTTP.header(e.response, "X-RateLimit-Remaining") == "0"
        reset_time = parse(Int, HTTP.header(e.response, "X-RateLimit-Reset"))
        @test reset_time > 0 && reset_time <= 3
    end

    # Wait for the window to reset (just over 3 seconds)
    sleep(3.1)

    # First request after reset should succeed again
    r = HTTP.get("$localhost/ok")
    @test r.status == 200
    @test HTTP.header(r, "X-RateLimit-Remaining") == "99"

end
terminate()


# Create a server without global middleware but with route-level middleware on /limited/*
serve(port=PORT, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)


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
        @test e isa HTTP.Exceptions.StatusError
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
    # First request: verify route-level rate limiting headers
    r = HTTP.request("GET", "$localhost/limited/goodbye", status_exception=false)
    @test r.status == 200
    @test text(r) == "goodbye"
    @test HTTP.header(r, "X-RateLimit-Limit") == "25"
    @test HTTP.header(r, "X-RateLimit-Remaining") == "24"
    reset_time = parse(Int, HTTP.header(r, "X-RateLimit-Reset"))
    @test reset_time > 0 && reset_time <= 3

    # Exhaust remaining quota
    for _ in 2:25
        HTTP.request("GET", "$localhost/limited/goodbye", status_exception=false)
    end

    # 26th request should be rate limited (429)
    r = HTTP.request("GET", "$localhost/limited/goodbye", status_exception=false)
    @test r.status == 429
    @test HTTP.header(r, "X-RateLimit-Limit") == "25"
    @test HTTP.header(r, "X-RateLimit-Remaining") == "0"
    reset_time = parse(Int, HTTP.header(r, "X-RateLimit-Reset"))
    @test reset_time > 0 && reset_time <= 3

    # Wait for reset and verify recovery
    sleep(3.1)
    r = HTTP.request("GET", "$localhost/limited/goodbye", status_exception=false)
    @test r.status == 200
    @test HTTP.header(r, "X-RateLimit-Remaining") == "24"
end

terminate()

rl = RateLimiter(rate_limit=1, window=Hour(1), cleanup_period=Second(1), cleanup_threshold=Second(1))

# Start server for background cleanup test
serve(middleware=[rl], port=PORT, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

@testset "Background Cleanup Test" begin

    # First request should succeed
    r = HTTP.get("$localhost/ok"; retry=false)
    @test r.status == 200
    @test text(r) == "ok"
    @test HTTP.header(r, "X-RateLimit-Limit") == "1"
    @test HTTP.header(r, "X-RateLimit-Remaining") == "0"
    reset_time = parse(Int, HTTP.header(r, "X-RateLimit-Reset"))
    @test reset_time > 0  # Should be close to 1 hour in seconds

    # Second request should be rate limited (429)
    try
        HTTP.get("$localhost/ok"; retry=false)
        @test false
    catch e
        @test e isa HTTP.Exceptions.StatusError
        @test e.response.status == 429
        @test HTTP.header(e.response, "X-RateLimit-Limit") == "1"
        @test HTTP.header(e.response, "X-RateLimit-Remaining") == "0"
        reset_time = parse(Int, HTTP.header(e.response, "X-RateLimit-Reset"))
        @test reset_time > 0
    end

    # Wait for cleanup to run (cleanup_threshold=1s, cleanup_period=1s, wait 2.1s to ensure task runs)
    sleep(2.1)

    # Third request should succeed because the IP entry was cleaned up
    r = HTTP.get("$localhost/ok"; retry=false)
    @test r.status == 200
    @test text(r) == "ok"
    @test HTTP.header(r, "X-RateLimit-Limit") == "1"
    @test HTTP.header(r, "X-RateLimit-Remaining") == "0"
    reset_time = parse(Int, HTTP.header(r, "X-RateLimit-Reset"))
    @test reset_time > 0
end

terminate()

# Start server for exempt paths test
urlpatterns("",
    path("/limited", function() return "limited" end, method="GET"),
    path("/exempt",  function() return "exempt" end,  method="GET"),
)

serve(middleware=[RateLimiter(rate_limit=10, window=Second(1), exempt_paths=["/exempt"])], port=PORT, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

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
        @test e isa HTTP.Exceptions.StatusError
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

# ── Proxied-setup behavior ────────────────────────────────────────────────────
# The limiter keys on the resolved client IP. These tests pin the two behaviors
# of the secure-by-default IP extraction: forwarding headers are ignored unless
# the operator trusts the proxy. The live server's socket peer is the loopback
# address (HOST = "127.0.0.1"), which stands in for the reverse proxy.

sleep(3.1) # ensure any prior window/cleanup state is gone

# Default: no trust configured → X-Forwarded-For is IGNORED. Distinct forwarded
# client IPs all collapse onto the proxy's socket IP and share a single bucket.
serve(middleware=[RateLimiter(rate_limit=3, window=Second(5))], port=PORT, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

@testset "Proxied: forwarding headers ignored by default (shared bucket)" begin
    # Three requests, each claiming a different client IP, consume the SAME quota
    # because the spoofable header is not trusted.
    for i in 1:3
        r = HTTP.get("$localhost/ok", ["X-Forwarded-For" => "203.0.113.$i"]; retry=false)
        @test r.status == 200
    end

    # A fourth distinct "client" is still throttled — proof the bucket is shared
    # across everyone behind the proxy.
    try
        HTTP.get("$localhost/ok", ["X-Forwarded-For" => "203.0.113.4"]; retry=false)
        @test false
    catch e
        @test e isa HTTP.Exceptions.StatusError
        @test e.response.status == 429
    end
end

terminate()

sleep(3.1)

# Trusted proxy: when the socket peer is a configured trusted proxy, the limiter
# honors X-Forwarded-For and buckets each forwarded client independently.
serve(middleware=[RateLimiter(rate_limit=2, window=Second(5),
        trusted_proxies=[ip"127.0.0.1", ip"::1"])],
    port=PORT, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

@testset "Proxied: trusted_proxies honors per-client X-Forwarded-For" begin
    # Each distinct forwarded client gets its own bucket of `rate_limit` requests.
    for client in ("203.0.113.10", "203.0.113.11", "203.0.113.12")
        r1 = HTTP.get("$localhost/ok", ["X-Forwarded-For" => client]; retry=false)
        @test r1.status == 200
        r2 = HTTP.get("$localhost/ok", ["X-Forwarded-For" => client]; retry=false)
        @test r2.status == 200

        # The 3rd request for the SAME client exceeds its own limit of 2.
        try
            HTTP.get("$localhost/ok", ["X-Forwarded-For" => client]; retry=false)
            @test false
        catch e
            @test e isa HTTP.Exceptions.StatusError
            @test e.response.status == 429
        end
    end
end

terminate()

end