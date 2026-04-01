@testitem "Rate limiter LRU" tags=[:middleware, :network, :slow] setup=[NitroCommon] begin
using HTTP
using Dates
using Nitro

function warm_up_and_reset(url; pause_seconds)
    HTTP.request("GET", url, status_exception=false)
    sleep(pause_seconds)
end

urlpatterns("/limited",
    path("/goodbye", function() return "goodbye" end, method="GET",
        middleware=[RateLimiter(strategy=:sliding_window, rate_limit=4, window=Second(3))]),
    path("/greet", function() return "hello" end, method="GET",
        middleware=[RateLimiter(strategy=:sliding_window, rate_limit=6, window=Second(3))]),
)
urlpatterns("",
    path("/ok", function() return "ok" end, method="GET"),
)

# Warm the route once so JIT latency does not consume the sliding window budget.
serve(middleware=[RateLimiter(strategy=:sliding_window, rate_limit=10, window=Second(3))], port=PORT, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)
warm_up_and_reset("$localhost/ok"; pause_seconds=3.1)

@testset "Rate Limiter Tests" begin

    # First request: verify headers and countdown start
    r = HTTP.get("$localhost/ok")
    @test r.status == 200
    @test text(r) == "ok"
    @test HTTP.header(r, "X-RateLimit-Limit") == "10"
    @test HTTP.header(r, "X-RateLimit-Remaining") == "9"
    reset_time = parse(Int, HTTP.header(r, "X-RateLimit-Reset"))
    @test reset_time > 0 && reset_time <= 3

    # Exhaust the remaining quota (no per-request assertions needed)
    for _ in 2:10
        HTTP.get("$localhost/ok")
    end

    # Next request must be rate limited (429)
    try
        HTTP.get("$localhost/ok"; retry=false)
        @test false  # Should not reach here
    catch e
        @test e isa HTTP.Exceptions.StatusError
        @test e.response.status == 429
        @test HTTP.header(e.response, "X-RateLimit-Limit") == "10"
        @test HTTP.header(e.response, "X-RateLimit-Remaining") == "0"
        reset_time = parse(Int, HTTP.header(e.response, "X-RateLimit-Reset"))
        @test reset_time > 0 && reset_time <= 3
    end

    # Wait for the window to reset (just over 3 seconds)
    sleep(3.1)

    # First request after reset should succeed again
    r = HTTP.get("$localhost/ok")
    @test r.status == 200
    @test HTTP.header(r, "X-RateLimit-Remaining") == "9"

end
terminate()


# Create a server without global middleware but with route-level middleware on /limited/*
serve(port=PORT, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

HTTP.request("GET", "$localhost/limited/greet", status_exception=false)
HTTP.request("GET", "$localhost/limited/goodbye", status_exception=false)
sleep(3.1)

@testset "Limited Greet Endpoint Rate Limiter" begin
    # First request: verify headers
    r = HTTP.get("$localhost/limited/greet")
    @test r.status == 200
    @test text(r) == "hello"
    @test HTTP.header(r, "X-RateLimit-Limit") == "6"
    @test HTTP.header(r, "X-RateLimit-Remaining") == "5"
    reset_time = parse(Int, HTTP.header(r, "X-RateLimit-Reset"))
    @test reset_time > 0 && reset_time <= 3

    # Exhaust remaining quota
    for _ in 2:6
        HTTP.get("$localhost/limited/greet")
    end

    # 7th request should be rate limited (429)
    try
        HTTP.get("$localhost/limited/greet"; retry=false)
        @test false
    catch e
        @test e isa HTTP.Exceptions.StatusError
        @test e.response.status == 429
        @test HTTP.header(e.response, "X-RateLimit-Limit") == "6"
        @test HTTP.header(e.response, "X-RateLimit-Remaining") == "0"
        reset_time = parse(Int, HTTP.header(e.response, "X-RateLimit-Reset"))
        @test reset_time > 0 && reset_time <= 3
    end

    # Wait for reset and verify recovery
    sleep(3.1)
    r = HTTP.get("$localhost/limited/greet")
    @test r.status == 200
    @test HTTP.header(r, "X-RateLimit-Remaining") == "5"
end

sleep(3.1) # Ensure rate limiter window is reset before starting next testset

@testset "Limited Other Endpoint Rate Limiter" begin
    # First request: verify route-level rate limiting headers
    r = HTTP.request("GET", "$localhost/limited/goodbye", status_exception=false)
    @test r.status == 200
    @test text(r) == "goodbye"
    @test HTTP.header(r, "X-RateLimit-Limit") == "4"
    @test HTTP.header(r, "X-RateLimit-Remaining") == "3"
    reset_time = parse(Int, HTTP.header(r, "X-RateLimit-Reset"))
    @test reset_time > 0 && reset_time <= 3

    # Exhaust remaining quota
    for _ in 2:4
        HTTP.request("GET", "$localhost/limited/goodbye", status_exception=false)
    end

    # 5th request should be rate limited (429)
    r = HTTP.request("GET", "$localhost/limited/goodbye", status_exception=false)
    @test r.status == 429
    @test HTTP.header(r, "X-RateLimit-Limit") == "4"
    @test HTTP.header(r, "X-RateLimit-Remaining") == "0"
    reset_time = parse(Int, HTTP.header(r, "X-RateLimit-Reset"))
    @test reset_time > 0 && reset_time <= 3

    # Wait for reset and verify recovery
    sleep(3.1)
    r = HTTP.request("GET", "$localhost/limited/goodbye", status_exception=false)
    @test r.status == 200
    @test HTTP.header(r, "X-RateLimit-Remaining") == "3"
end

terminate()

# Start server for exempt paths test
urlpatterns("",
    path("/limited", function() return "limited" end, method="GET"),
    path("/exempt",  function() return "exempt" end,  method="GET"),
)

serve(middleware=[RateLimiter(strategy=:sliding_window, rate_limit=10, window=Second(1), exempt_paths=["/exempt"])], port=PORT, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)
warm_up_and_reset("$localhost/limited"; pause_seconds=1.1)

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

# Start server for multiple exempt paths test
urlpatterns("",
    path("/limited",   function() return "limited" end,   method="GET"),
    path("/exempt1",  function() return "exempt1" end,   method="GET"),
    path("/exempt2",  function() return "exempt2" end,   method="GET"),
    path("/notexempt", function() return "notexempt" end, method="GET"),
)

serve(middleware=[RateLimiter(strategy=:sliding_window, rate_limit=5, window=Second(1), exempt_paths=["/exempt1", "/exempt2"])], port=PORT, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)
warm_up_and_reset("$localhost/limited"; pause_seconds=1.1)

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