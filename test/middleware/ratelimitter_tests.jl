@testitem "Rate limiter" tags=[:middleware, :network, :slow] setup=[NitroCommon] begin
using HTTP
using Dates
using Sockets
using Nitro

port = get_free_port()
localhost = "http://$HOST:$port"

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
serve(middleware=[RateLimiter(rate_limit=100, window=Second(3))], port=port, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

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
        @test e isa HTTP.StatusError
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
serve(port=port, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

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

rl = RateLimiter(rate_limit=1, window=Hour(1), cleanup_period=Second(1), cleanup_threshold=Second(1))

# Start server for background cleanup test
serve(middleware=[rl], port=port, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

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
        @test e isa HTTP.StatusError
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

serve(middleware=[RateLimiter(rate_limit=10, window=Second(1), exempt_paths=["/exempt"])], port=port, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

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

# ── Proxied-setup behavior ────────────────────────────────────────────────────
# The limiter keys on the resolved client IP. These tests pin the two behaviors
# of the secure-by-default IP extraction: forwarding headers are ignored unless
# the operator trusts the proxy. The live server's socket peer is the loopback
# address (HOST = "127.0.0.1"), which stands in for the reverse proxy.

sleep(3.1) # ensure any prior window/cleanup state is gone

# Default: no trust configured → X-Forwarded-For is IGNORED. Distinct forwarded
# client IPs all collapse onto the proxy's socket IP and share a single bucket.
serve(middleware=[RateLimiter(rate_limit=3, window=Second(5))], port=port, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

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
        @test e isa HTTP.StatusError
        @test e.response.status == 429
    end
end

terminate()

sleep(3.1)

# Trusted proxy: when the socket peer is a configured trusted proxy, the limiter
# honors X-Forwarded-For and buckets each forwarded client independently.
serve(middleware=[RateLimiter(rate_limit=2, window=Second(5),
        forwarded_header=:x_forwarded_for,
        trusted_proxies=[ip"127.0.0.1", ip"::1"])],
    port=port, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

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
            @test e isa HTTP.StatusError
            @test e.response.status == 429
        end
    end
end

terminate()

sleep(3.1)

# Regression #16, end to end. The client prepends its own X-Forwarded-For entry; the loopback
# "proxy" appends the address it actually saw, exactly as nginx's proxy_add_x_forwarded_for
# does. Under the old leftmost-wins rule the prepended value became the bucket key, so rotating
# it minted a fresh quota on every request — unlimited requests from one client.
serve(middleware=[RateLimiter(rate_limit=2, window=Second(5),
        forwarded_header=:x_forwarded_for,
        trusted_proxies=[ip"127.0.0.1", ip"::1"])],
    port=port, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

@testset "Proxied: rotating a spoofed X-Forwarded-For prefix cannot buy quota" begin
    real_client = "203.0.113.20"

    # Two requests, each with a DIFFERENT spoofed prefix, must land in the same bucket —
    # the one keyed on the rightmost non-proxy entry, which is the real client.
    r1 = HTTP.get("$localhost/ok", ["X-Forwarded-For" => "9.9.9.9, $real_client"]; retry=false)
    @test r1.status == 200
    r2 = HTTP.get("$localhost/ok", ["X-Forwarded-For" => "8.8.8.8, $real_client"]; retry=false)
    @test r2.status == 200

    # A third rotation is throttled: the quota belongs to the client, not to the header.
    try
        HTTP.get("$localhost/ok", ["X-Forwarded-For" => "1.2.3.4, $real_client"]; retry=false)
        @test false
    catch e
        @test e isa HTTP.StatusError
        @test e.response.status == 429
    end

    # A vendor header cannot be used to sidestep the declared one either.
    try
        HTTP.get("$localhost/ok", ["CF-Connecting-IP" => "7.7.7.7",
                                   "X-Forwarded-For"  => "5.5.5.5, $real_client"]; retry=false)
        @test false
    catch e
        @test e isa HTTP.StatusError
        @test e.response.status == 429
    end
end

terminate()

# ── No client IP on the request ───────────────────────────────────────────────
# Driven in-process: `auto_extract_ip=false` returns the bare `handle -> req -> resp`
# closure, so a synthetic request with no `:ip` reaches the limiter unresolved. There is
# no bucket to key on, so the limiter must decide explicitly rather than letting the
# `nothing` reach the store and surface as a caught exception per request.

@testset "Rate limiter: a request with no client IP" begin
    bare() = HTTP.Request("GET", "/ok")
    ok_handler = _ -> HTTP.Response(200, "ok")

    for strategy in (:fixed_window, :sliding_window)
        # Fails closed by default — a request that cannot be limited is not admitted.
        closed = RateLimiter(; strategy, rate_limit=5, window=Second(5), auto_extract_ip=false)
        mw = closed isa Nitro.LifecycleMiddleware ? closed.middleware : closed
        @test mw(ok_handler)(bare()).status == 503

        # ...and passes through when the operator opted into availability instead.
        open_ = RateLimiter(; strategy, rate_limit=5, window=Second(5),
                            auto_extract_ip=false, fail_open=true)
        mwo = open_ isa Nitro.LifecycleMiddleware ? open_.middleware : open_
        @test mwo(ok_handler)(bare()).status == 200

        # A request that DOES carry an IP is unaffected by the guard.
        withip = HTTP.Request("GET", "/ok"); setip!(withip, ip"203.0.113.50")
        @test mw(ok_handler)(withip).status == 200
    end
end

# ── Construction-time validation ──────────────────────────────────────────────
# Pure constructor tests: nothing here starts a server, which is the point — a bad trust
# configuration must be rejected by `RateLimiter(...)` itself, not deferred to `serve()`.

@testset "Rate limiter: keyword dispatch survives a single-typed kwargs dict" begin
    # `Dict(kwargs)` narrowed to whatever value type it happened to see, so these missed the
    # `Dict{Symbol, Any}` helper signatures with a MethodError. Only calls mixing two unrelated
    # value types widened to `Any` — which is exactly what every other test in this file does,
    # and why the plainest documented call was broken without anything noticing.
    @test RateLimiter() !== nothing                                       # empty kwargs
    @test RateLimiter(rate_limit=100) !== nothing                         # Dict{Symbol, Int64}
    @test RateLimiter(auto_extract_ip=false, fail_open=true) !== nothing  # Dict{Symbol, Bool}
    @test RateLimiter(exempt_paths=["/health"]) !== nothing               # Dict{Symbol, Vector{String}}
    @test RateLimiter(strategy=:sliding_window, rate_limit=100) !== nothing
    # The rename alias still works through the widened dict.
    @test RateLimiter(window_period=Second(3)) !== nothing
end

@testset "Rate limiter: removed and inert trust keywords are rejected" begin
    # `trust_forwarded` is gone from both constructors. Deleting it outright would leave only
    # Julia's bare "unsupported keyword argument", which names no replacement.
    err = try RateLimiter(trust_forwarded=true); nothing catch e; e end
    @test err isa ArgumentError
    @test occursin("forwarded_header", err.msg)
    @test occursin("trusted_proxies", err.msg)
    @test occursin("trust_forwarded", err.msg)
    @test (try RateLimiter(strategy=:sliding_window, trust_forwarded=false); nothing
           catch e; e end) isa ArgumentError

    for strategy in (:fixed_window, :sliding_window)
        # `auto_extract_ip=false` means no `ExtractIP` is built, so these two would be
        # accepted, never validated, and silently do nothing — every client in one bucket
        # while the setting reads as active.
        @test_throws ArgumentError RateLimiter(; strategy, auto_extract_ip=false,
            forwarded_header=:x_forwarded_for, trusted_proxies=[ip"127.0.0.1"])
        @test_throws ArgumentError RateLimiter(; strategy, auto_extract_ip=false,
            trusted_proxies=[ip"127.0.0.1"])
        @test_throws ArgumentError RateLimiter(; strategy, auto_extract_ip=false,
            forwarded_header=:x_forwarded_for)
        # Unparseable entries used to construct cleanly on this path for the same reason.
        @test_throws ArgumentError RateLimiter(; strategy, auto_extract_ip=false,
            forwarded_header=:x_forwarded_for, trusted_proxies=["not-an-ip"])
        # `auto_extract_ip=false` on its own stays valid — that is the documented escape hatch.
        @test RateLimiter(; strategy, auto_extract_ip=false) !== nothing
    end
end

@testset "Rate limiter: trust configuration is validated at construction, not at serve" begin
    for strategy in (:fixed_window, :sliding_window)
        # Each of these previously constructed a limiter and only threw later, when `serve`
        # composed the middleware chain and reached `ExtractIP`.
        @test_throws ArgumentError RateLimiter(; strategy, trusted_proxies=[ip"127.0.0.1"])
        @test_throws ArgumentError RateLimiter(; strategy, forwarded_header=:x_forwarded_for)
        @test_throws ArgumentError RateLimiter(; strategy,
            forwarded_header=:x_forwarded_for, trusted_proxies=String[])
        @test_throws ArgumentError RateLimiter(; strategy,
            forwarded_header=:x_forwarded_for, trusted_proxies=["0.0.0.0/0"])
        @test_throws ArgumentError RateLimiter(; strategy,
            forwarded_header=:typo, trusted_proxies=[ip"127.0.0.1"])

        # The correctly-declared pair builds, with CIDR and literals mixed.
        @test RateLimiter(; strategy, rate_limit=10,
            forwarded_header=:x_forwarded_for,
            trusted_proxies=["10.244.0.0/16", ip"127.0.0.1"]) !== nothing
    end
end

end