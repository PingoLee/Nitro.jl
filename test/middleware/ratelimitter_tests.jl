@testitem "Rate limiter" tags=[:middleware, :network, :slow] setup=[NitroCommon] begin
using HTTP
using Dates
using Sockets
using Nitro

port = get_free_port()
localhost = "http://$HOST:$port"

# Route-level limiters, sized so neither testset below races its own window (#212).
# `/greet` is the enforcement case: a window far larger than the burst, so the counter
# decrements deterministically however slow the runner is. `/goodbye` is the recovery
# case: `rate_limit=1` means it only ever issues single requests, so the 3s window it
# waits out is never something a burst has to fit inside.
#
# `/greet` uses the deprecated `window_period=` alias, and its window must stay a
# NON-default value: the constructor defaults to `window = Minute(1)`, so passing
# `window_period=Minute(1)` would be satisfied by an alias that silently dropped its
# value. `Second(30)` keeps the alias falsifiable — drop the rename and the reset header
# reports 60, which the `<= 30` assertions below reject — while still giving the 4-request
# burst a 7.5s-per-request budget.
urlpatterns("/limited",
    path("/goodbye", function() return "goodbye" end, method="GET",
        middleware=[RateLimiter(rate_limit=1, window=Second(3))]),
    path("/greet", function() return "hello" end, method="GET",
        middleware=[RateLimiter(rate_limit=3, window_period=Second(30))]),
)
urlpatterns("",
    path("/ok", function() return "ok" end, method="GET"),
)

# ── Enforcement: the limit is applied and the remaining counter decrements ─────
# The window is far larger than the burst, so the counter decrements deterministically
# regardless of request latency. The previous shape — 101 live requests that all had to
# land inside a 3s window — left macOS at -t 1 a ~30ms per-request budget and failed on
# correct code whenever it slipped (#212). Recovery is covered separately below, so
# neither testset depends on a burst-vs-window race. This is the same split
# `ratelimitter_lru_tests.jl` already documents for the sliding strategy.
serve(middleware=[RateLimiter(rate_limit=3, window=Second(30))], port=port, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

@testset "Rate Limiter Tests" begin

    # First request: verify headers and countdown start
    r = HTTP.get("$localhost/ok")
    @test r.status == 200
    @test text(r) == "ok"
    @test HTTP.header(r, "X-RateLimit-Limit") == "3"
    @test HTTP.header(r, "X-RateLimit-Remaining") == "2"
    reset_time = parse(Int, HTTP.header(r, "X-RateLimit-Reset"))
    @test reset_time > 0 && reset_time <= 30

    # Exhaust the remaining quota, asserting each decrement rather than looping: under a
    # 1-minute window every one of these is deterministic.
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
        reset_time = parse(Int, HTTP.header(e.response, "X-RateLimit-Reset"))
        @test reset_time > 0 && reset_time <= 30
    end

end
terminate()

sleep(1)  # let the port free up before re-binding

# ── Recovery: the bucket resets once the window elapses ───────────────────────
# `rate_limit=1` keeps this to single requests, so the window being waited out is never
# something a burst has to fit inside.
serve(middleware=[RateLimiter(rate_limit=1, window=Second(3))], port=port, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

@testset "Fixed Window Recovery" begin
    # First request consumes the only slot
    r = HTTP.get("$localhost/ok")
    @test r.status == 200
    @test HTTP.header(r, "X-RateLimit-Remaining") == "0"

    # An immediate follow-up is refused — both fall within the same window
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
    # reset, so it discriminates nothing on its own. The reset header does: an expired
    # window re-anchors `last_reset` to now, so this reports the full window again.
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
    # is waited out rather than raced against a burst — this is the route-level mirror of
    # the "Fixed Window Recovery" testset above, which covers the global-middleware case.
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

    # Wait for reset and verify recovery. See "Fixed Window Recovery" above for why
    # `retry=false` and the reset-header assertion are both load-bearing here.
    sleep(3.1)
    r = HTTP.get("$localhost/limited/goodbye"; retry=false)
    @test r.status == 200
    @test HTTP.header(r, "X-RateLimit-Remaining") == "0"
    @test HTTP.header(r, "X-RateLimit-Reset") == "3"
end

terminate()

# The background sweep has no testset here any more. The one that sat here asserted the
# defect #319 fixed: `window=Hour(1)` with a 1s `cleanup_threshold`, and a throttled client
# admitted again 2s later. Over HTTP a reaped bucket and an expired one give the same answer,
# so the sweep is covered in-process by "Rate limiter: fixed-window sweep" below.

# Start server for exempt paths test
urlpatterns("",
    path("/limited", function() return "limited" end, method="GET"),
    path("/exempt",  function() return "exempt" end,  method="GET"),
)

# This testset's subject is exempt-path behaviour, not window expiry, so the window is
# sized to be unreachable by the burst rather than raced against it. This is the exact
# assertion that flaked on macOS at -t 1 (#212): 11 live requests had to land inside one
# wall-clock second, and when the window rolled over mid-sequence the 11th was correctly
# admitted and the test failed against correct code.
serve(middleware=[RateLimiter(rate_limit=3, window=Second(30), exempt_paths=["/exempt"])], port=port, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

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

# ── Proxied-setup behavior ────────────────────────────────────────────────────
# The limiter keys on the resolved client IP. These tests pin the two behaviors
# of the secure-by-default IP extraction: forwarding headers are ignored unless
# the operator trusts the proxy. The live server's socket peer is the loopback
# address (HOST = "127.0.0.1"), which stands in for the reverse proxy.

# No inter-server sleep is needed: each `RateLimiter(...)` builds its own stripe store as
# a closure local, so a fresh `serve()` below cannot see the previous limiter's buckets.
# The waits that used to sit here claimed to "ensure any prior window/cleanup state is
# gone" and were clearing nothing (#212).

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

end # @testitem "Rate limiter"


# Everything below this line is server-free: no `serve`, no port binding, no sleeping.
# It lives in its own `@testitem` so it does NOT inherit `:network`/`:slow` from the item
# above — tags apply per item, not per testset, so while these shared one item the tags
# overstated what they describe and 115 socket-free assertions were filed as `:network`
# and `:slow` (#210). Note that the issue frames the cost the other way round, as a
# filtered run validating no `RateLimiter` argument; that did not reproduce at the time,
# because `--tags` is AND-combined subset matching and the launcher had no exclusion
# operator, so `--tags middleware` always selected the whole-file item too. #214 added
# one: `--tags middleware --skip-tags network` now runs THIS item and not the one above,
# which is the payoff the split was for. The last `terminate()` above is the file's
# network/non-network seam, so the boundary cannot drift back.
# `ratelimitter_lru_tests.jl` already carries a second item on this pattern.
#
# `@testitem` bodies do not share scope, so the preamble is repeated: `Dates` for the
# `Period` keywords, `Sockets` for the `ip"…"` literals and `IPv4`, `HTTP` for the
# synthetic `HTTP.Request`s.
@testitem "Rate limiter construction and keying" tags=[:middleware] setup=[NitroCommon] begin
using HTTP
using Dates
using Sockets
using Nitro
using Nitro: setip!

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
        mw = closed.middleware
        @test mw(ok_handler)(bare()).status == 503

        # ...and passes through when the operator opted into availability instead.
        open_ = RateLimiter(; strategy, rate_limit=5, window=Second(5),
                            auto_extract_ip=false, fail_open=true)
        mwo = open_.middleware
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

@testset "Rate limiter: the removed cleanup_threshold is rejected by name" begin
    # #319. The sweep reaped any bucket older than `cleanup_threshold`, window over or not, so a
    # threshold under `window` cut every window short. The sweep now reaps at `window` and the
    # keyword is gone. The error says to drop it: nothing it could still set changes an answer.
    for strategy in (:fixed_window, :sliding_window)
        err = try RateLimiter(; strategy, cleanup_threshold=Minute(10)); nothing catch e; e end
        @test err isa ArgumentError
        @test occursin("cleanup_threshold", err.msg)
        @test occursin("window", err.msg)
    end
end

# ── Exempt paths match whole segments (#319) ──────────────────────────────────
# `startswith(req.target, ex)` made `"/health"` exempt `/healthz-admin` as well. In-process with
# `rate_limit=1`, so a path the limiter counts is refused on its second request, and an exempt
# one is never counted and carries no rate-limit headers.

@testset "Rate limiter: exempt_paths match whole path segments" begin
    ok_handler = _ -> HTTP.Response(200, "ok")
    req_to(target) = (r = HTTP.Request("GET", target); setip!(r, ip"203.0.113.60"); r)
    exempt(resp) = resp.status == 200 && !HTTP.hasheader(resp, "X-RateLimit-Limit")

    for strategy in (:fixed_window, :sliding_window)
        # A fresh limiter per assertion, so each one sees a full quota of 1.
        limiter(paths) = RateLimiter(; strategy, rate_limit=1, window=Minute(1),
                                     auto_extract_ip=false, exempt_paths=paths).middleware(ok_handler)

        # The entry itself, anything below it, and it with a query string are exempt.
        for target in ("/health", "/health/live", "/health?full=1", "/health/")
            w = limiter(["/health"])
            @test all(exempt(w(req_to(target))) for _ in 1:3)
        end

        # A sibling that merely shares the leading characters is counted. This is the
        # assertion that fails against the bare prefix match.
        for target in ("/healthz-admin", "/healthcheck", "/health-internal/x")
            w = limiter(["/health"])
            @test w(req_to(target)).status == 200
            @test w(req_to(target)).status == 429
        end

        # An entry ending in `/` keeps its old meaning: everything below it, not the bare
        # directory. The fix only narrows what is exempt.
        w = limiter(["/static/"])
        @test all(exempt(w(req_to("/static/app.js"))) for _ in 1:3)
        w = limiter(["/static/"])
        @test w(req_to("/static")).status == 200
        @test w(req_to("/static")).status == 429

        # `"/"` still exempts everything.
        w = limiter(["/"])
        @test all(exempt(w(req_to("/anything/at/all"))) for _ in 1:3)
    end
end

@testset "Rate limiter: an unknown strategy names the valid ones" begin
    # `strategy` was the last unvalidated keyword on the constructor: with no fallback method,
    # a typo produced a raw `MethodError` naming the internal `dispatch_rate_limiter`, which
    # says nothing about which argument is wrong or what it accepts (#187).
    err = try RateLimiter(strategy=:slidingwindow, rate_limit=100); nothing catch e; e end
    @test err isa ArgumentError
    @test occursin("slidingwindow", err.msg)      # the value the caller actually passed
    @test occursin(":fixed_window", err.msg)      # ...and both valid values, so the fix is in the message
    @test occursin(":sliding_window", err.msg)
    @test !occursin("dispatch_rate_limiter", err.msg)   # no internal in a user-facing error

    # The fallback is `::Val{S} where {S}`, so it must stay strictly less specific than the two
    # concrete methods — if it ever shadows them, both lines below throw instead of returning.
    #
    # Asserting on the HOOKS rather than on `!== nothing` is what makes these pin strategy
    # SELECTION too. Both strategies return the same type on purpose (#172), so the type says
    # nothing about which one you got; the background task does. `FixedRateLimiter` owns a
    # cleanup sweep and sets both hooks, `SlidingRateLimiter` prunes inline and leaves both
    # `nothing` — so swapping the two method bodies above goes red here rather than silently
    # handing every caller the other algorithm.
    @test RateLimiter(strategy=:fixed_window).on_startup    !== nothing
    @test RateLimiter(strategy=:sliding_window).on_startup  === nothing
    @test RateLimiter(strategy=:sliding_window).on_shutdown === nothing
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


# ── Bucket keying: IPv6 prefix normalization (#22) ────────────────────────────
# A single IPv6 host normally controls an entire /64. Keying buckets on the full /128
# meant a client could rotate source addresses inside its OWN allocation and get a fresh
# bucket every request — the limit was never reached, while `X-RateLimit-*` kept
# reporting that limiting was in effect. This is the IPv6 analogue of the #16 spoofed
# `X-Forwarded-For` rotation regression above, except no header is involved: the
# addresses are genuinely the client's.
#
# In-process (`auto_extract_ip=false` + `setip!`) so the source address is chosen
# directly rather than being whatever the loopback socket reports.

@testset "Rate limiter: rotating inside one IPv6 /64 cannot buy quota" begin
    ok_handler = _ -> HTTP.Response(200, "ok")
    req_from(ip) = (r = HTTP.Request("GET", "/ok"); setip!(r, ip); r)
    for strategy in (:fixed_window, :sliding_window)
        limit = 5
        wrapped = RateLimiter(; strategy, rate_limit=limit, window=Minute(1),
                              auto_extract_ip=false).middleware(ok_handler)

        # Every request comes from a DIFFERENT address inside 2001:db8:: /64.
        statuses = [wrapped(req_from(IPv6("2001:db8::$(string(i, base=16))"))).status
                    for i in 1:(2 * limit)]

        @test count(==(200), statuses) == limit
        @test count(==(429), statuses) == limit
    end
end

@testset "Rate limiter: distinct IPv6 /64s keep independent buckets" begin
    ok_handler = _ -> HTTP.Response(200, "ok")
    req_from(ip) = (r = HTTP.Request("GET", "/ok"); setip!(r, ip); r)
    for strategy in (:fixed_window, :sliding_window)
        limit = 3
        wrapped = RateLimiter(; strategy, rate_limit=limit, window=Minute(1),
                              auto_extract_ip=false).middleware(ok_handler)

        # Exhaust one /64...
        for _ in 1:limit
            @test wrapped(req_from(IPv6("2001:db8:0:1::5"))).status == 200
        end
        @test wrapped(req_from(IPv6("2001:db8:0:1::9"))).status == 429

        # ...a neighbouring /64 is a different client and still has its full quota.
        @test wrapped(req_from(IPv6("2001:db8:0:2::5"))).status == 200
    end
end

@testset "Rate limiter: IPv4 keying is unchanged, and mapped peers fold onto it" begin
    ok_handler = _ -> HTTP.Response(200, "ok")
    req_from(ip) = (r = HTTP.Request("GET", "/ok"); setip!(r, ip); r)
    for strategy in (:fixed_window, :sliding_window)
        # limit=3 is load-bearing: the 203.0.113.7 bucket receives exactly 4 requests
        # below, so only a limit of 3 makes the last one discriminate. At limit=4 the
        # test passes whether or not the mapped address folds onto the v4 bucket.
        limit = 3
        wrapped = RateLimiter(; strategy, rate_limit=limit, window=Minute(1),
                              auto_extract_ip=false).middleware(ok_handler)

        # Default ipv4_prefix is /32, so neighbouring IPv4 hosts stay separate buckets.
        @test wrapped(req_from(IPv4("203.0.113.7"))).status == 200
        @test wrapped(req_from(IPv4("203.0.113.8"))).status == 200

        # A mapped address must share a bucket with the plain v4 spelling rather than
        # opening a second one. Since #66 the socket peer arrives already demoted, so what
        # this now pins is the fold `_bucket_key` applies to whatever `getip(req)` holds —
        # a header-derived address behind a proxy, or one written with `setip!`.
        @test wrapped(req_from(IPv6("::ffff:203.0.113.7"))).status == 200
        @test wrapped(req_from(IPv4("203.0.113.7"))).status == 200
        @test wrapped(req_from(IPv6("::ffff:203.0.113.7"))).status == 429
    end
end

@testset "Rate limiter: prefix lengths are configurable and validated" begin
    ok_handler = _ -> HTTP.Response(200, "ok")
    req_from(ip) = (r = HTTP.Request("GET", "/ok"); setip!(r, ip); r)
    for strategy in (:fixed_window, :sliding_window)
        # Widened to /48: two DIFFERENT /64s inside one /48 now share a bucket.
        limit = 2
        wrapped = RateLimiter(; strategy, rate_limit=limit, window=Minute(1),
                              auto_extract_ip=false, ipv6_prefix=48).middleware(ok_handler)
        @test wrapped(req_from(IPv6("2001:db8:0:1::1"))).status == 200
        @test wrapped(req_from(IPv6("2001:db8:0:2::1"))).status == 200
        @test wrapped(req_from(IPv6("2001:db8:0:3::1"))).status == 429

        # Narrowed IPv4 to /24: neighbouring hosts collapse onto one bucket.
        w4 = RateLimiter(; strategy, rate_limit=limit, window=Minute(1),
                         auto_extract_ip=false, ipv4_prefix=24).middleware(ok_handler)
        @test w4(req_from(IPv4("198.51.100.1"))).status == 200
        @test w4(req_from(IPv4("198.51.100.2"))).status == 200
        @test w4(req_from(IPv4("198.51.100.3"))).status == 429
        # A different /24 is still its own client.
        @test w4(req_from(IPv4("198.51.101.1"))).status == 200

        # Out-of-range prefixes are rejected at construction. /0 in particular would put
        # every client on the internet in one shared bucket.
        @test_throws ArgumentError RateLimiter(; strategy, ipv6_prefix=0)
        @test_throws ArgumentError RateLimiter(; strategy, ipv4_prefix=0)
        @test_throws ArgumentError RateLimiter(; strategy, ipv4_prefix=33)
        @test_throws ArgumentError RateLimiter(; strategy, ipv6_prefix=129)
        @test_throws ArgumentError RateLimiter(; strategy, ipv6_prefix=-1)
    end
end


@testset "Rate limiter: Period keywords reject calendar durations" begin
    # `Dates.value(p) > 0` was the old check and it does NOT catch these: `Dates.value(Month(1))`
    # is 1, so a calendar period passed validation. What it broke depends on the keyword:
    #   cleanup_period -> `sleep(Month(1))` throws in the un-monitored `@async` sweep, so the
    #                     background cleanup dies on tick 1, silently, for the life of the
    #                     process — in the component whose whole job is bounding memory.
    #   window         -> the `current_time - last_reset > window` comparison throws
    #                     (Millisecond vs Month) ON THE REQUEST PATH. The limiter's own catch
    #                     turns it into 503 for EVERY request (or fail-open, letting everything
    #                     through). Since #319 the sweep makes the same comparison, so it would
    #                     also die silently.
    # A third keyword, `cleanup_threshold`, was checked here too until #319 removed it.
    # Same defect class as the session janitor (#36); fixed in both.
    for bad in (Month(1), Year(1), Quarter(1))
        @test_throws ArgumentError RateLimiter(cleanup_period=bad)
        @test_throws ArgumentError RateLimiter(window=bad)
        @test_throws ArgumentError RateLimiter(strategy=:sliding_window, window=bad)
    end
    # Sub-millisecond rounds to a zero-length sleep and spins.
    @test_throws ArgumentError RateLimiter(cleanup_period=Nanosecond(500))
    # Fixed periods, including the sub-second ones other tests rely on, still build.
    @test RateLimiter(window=Second(3)) isa Nitro.LifecycleMiddleware
    @test RateLimiter(cleanup_period=Millisecond(50)) isa Nitro.LifecycleMiddleware
    # Both strategies return a LifecycleMiddleware (#172): `strategy` picks the algorithm, not
    # the return type. The sliding one owns no background task, so its hooks are `nothing`.
    sliding = RateLimiter(strategy=:sliding_window, window=Minute(1))
    @test sliding isa Nitro.LifecycleMiddleware
    @test sliding.on_startup === nothing
    @test sliding.on_shutdown === nothing
    @test typeof(sliding) === typeof(RateLimiter(strategy=:fixed_window, window=Minute(1)))
    # ...and the wrapper changed nothing about the request path: `.middleware` is still the
    # composed limiter chain, which admits a request under the limit and reaches the handler.
    bare_sliding = RateLimiter(strategy=:sliding_window, rate_limit=5, window=Minute(1),
                               auto_extract_ip=false)
    req = HTTP.Request("GET", "/ok"); setip!(req, IPv4("198.51.100.9"))
    @test bare_sliding.middleware(_ -> HTTP.Response(200, "reached"))(req).status == 200
end

@testset "the request closure boxes nothing (#364)" begin
    # The fixed limiter declared its three decision values before `lock(stripe.lock) do … end`
    # and assigned them inside it. Assigning an enclosing-scope local from a closure boxes it, so
    # `set_rate_headers!` got three `Any`s on every request (nitro-core §7). The sliding limiter
    # had no box but still leaked one `Any`: LRUCache's `get!` infers `Any`, and
    # `remaining_requests` was computed from what it returned.
    #
    # `test/closure_boxing_tests.jl` catches a box anywhere in Nitro; this is the narrower check
    # that the values reaching the headers are concrete, which a box-free closure can still miss.
    for strategy in (:fixed_window, :sliding_window)
        f = RateLimiter(; strategy, auto_extract_ip=false).middleware(_ -> HTTP.Response(200))
        ci = only(code_typed(f, (HTTP.Request,); optimize = false)).first
        @test (strategy, filter(T -> T === Core.Box, ci.slottypes)) == (strategy, [])
        for (name, T) in (:should_limit => Bool, :remaining_requests => Int, :reset_time => Int)
            # A name can own several slots; one that is never assigned infers `Union{}`.
            assigned = unique(S for (n, S) in zip(ci.slotnames, ci.slottypes)
                              if n === name && S !== Union{})
            @test (strategy, name, assigned) == (strategy, name, [T])
        end
    end
end

end # @testitem "Rate limiter construction and keying"


# #319. The fixed-window sweep reaped any bucket older than `cleanup_threshold` (10 minutes by
# default) whether or not its window had ended, so a throttled client got a fresh quota partway
# through a longer window. It now reaps at `window` and the keyword is gone.
#
# In-process and socket-free, but the janitor is a real spawned task and these wait on its ticks,
# hence `:slow` — the same tags as the janitor tests in lifecycle_middleware_tests.jl.
@testitem "Rate limiter: fixed-window sweep" tags=[:middleware, :slow] setup=[NitroCommon] begin
using HTTP
using Dates
using Sockets
using Nitro
using Nitro: setip!
using Nitro.Core.Middleware.RateLimiterMiddleware: BucketKey, _Stripe, _sweep_expired!

# White-box on purpose. Whether a bucket was reaped cannot be seen through the request path: an
# expired bucket and a missing one give the same answer, which is exactly why reaping at `window`
# is safe. So these read the store. It is a closure-local of `FixedRateLimiter`, captured by the
# request-path closure that `.middleware` is under `auto_extract_ip=false`, and Julia names a
# closure's fields after the variables it captures. Renaming that local turns this into a
# `FieldError`, not a quiet pass — the fix is to follow the rename, not to drop the read.
stripes_of(lf) = getfield(lf.middleware, :stripes)
buckets(lf) = sum(s -> lock(() -> length(s.store), s.lock), stripes_of(lf))

ok_handler = _ -> HTTP.Response(200, "ok")
req_from(ip) = (r = HTTP.Request("GET", "/login"); setip!(r, ip); r)

@testset "the sweep reaps a bucket once its window has ended, never before" begin
    # This pins the boundary, not the wiring: the comparison must be the request path's own
    # strict `>`, so the sweep deletes exactly the buckets a request would have reset. The
    # wiring — that `FixedRateLimiter` hands the sweep `window` — is the next testset's job.
    t = DateTime(2026, 9, 25, 12)
    window = Hour(1)
    store = Dict{BucketKey, Tuple{Int, DateTime}}(
        (false, UInt128(1)) => (5, t - Minute(20)),                # throttled, older than the old 10-min default
        (false, UInt128(2)) => (5, t - window),                    # window ends at `t`: still counted
        (false, UInt128(3)) => (1, t - window - Millisecond(1)),   # expired
        (true,  UInt128(4)) => (1, t - Day(1)))                    # long expired
    _sweep_expired!([_Stripe(ReentrantLock(), store)], window, t)
    @test Set(keys(store)) == Set([(false, UInt128(1)), (false, UInt128(2))])
end

@testset "a throttled client stays throttled while the sweep runs" begin
    # The failure scenario from #319, at the default settings it was reported against: a
    # one-hour window on a login route, with the client throttled 20 minutes ago. That is inside
    # the window and past the old 10-minute threshold, so the old sweep deleted the bucket and the
    # next request was admitted. `cleanup_period` is 20ms so the sweep runs many times during the
    # wait, which also catches the sweep being handed `cleanup_period` as its age by mistake.
    lf = RateLimiter(rate_limit=1, window=Hour(1), cleanup_period=Millisecond(20),
                     auto_extract_ip=false)
    w = lf.middleware(ok_handler)
    client = ip"203.0.113.70"
    @test w(req_from(client)).status == 200
    @test w(req_from(client)).status == 429

    # Backdate that one bucket's window start by 20 minutes. Rewriting it in place, in whichever
    # stripe holds it, avoids re-deriving the key-to-stripe mapping here.
    @test buckets(lf) == 1
    for s in stripes_of(lf)
        lock(s.lock) do
            for (k, (count, last_reset)) in collect(s.store)
                s.store[k] = (count, last_reset - Minute(20))
            end
        end
    end
    @test w(req_from(client)).status == 429         # still inside its window on the request path

    # A bucket whose window ended an hour ago, planted beside the live one. Its disappearance
    # proves the sweep really ran; without it, "still 429" would also pass with no sweep at all.
    planted = (false, UInt128(0xC0000201))
    s = first(stripes_of(lf))
    lock(() -> (s.store[planted] = (1, now(UTC) - Hour(2))), s.lock)
    @test buckets(lf) == 2

    task = lf.on_startup()
    try
        @test timedwait(() -> buckets(lf) == 1, 10.0) === :ok
        sleep(0.2)                                  # ten more sweeps over the live bucket
        @test buckets(lf) == 1                      # 0 before the fix: both were reaped
        @test w(req_from(client)).status == 429     # 200 before the fix
    finally
        lf.on_shutdown()
    end
    @test timedwait(() -> istaskdone(task), 10.0) === :ok
end

@testset "expired buckets are still reaped, so the store stays bounded" begin
    # Removing the threshold must not stop the sweep reaping; it is what bounds this
    # unbounded `Dict`. The janitor is started only after the count is taken, so a slow runner
    # cannot race the 100ms window before the assertion that the buckets exist.
    lf = RateLimiter(rate_limit=5, window=Millisecond(100), cleanup_period=Millisecond(20),
                     auto_extract_ip=false)
    w = lf.middleware(ok_handler)
    for i in 1:3
        @test w(req_from(IPv4("198.51.100.$i"))).status == 200
    end
    @test buckets(lf) == 3

    task = lf.on_startup()
    try
        @test timedwait(() -> buckets(lf) == 0, 10.0) === :ok
    finally
        lf.on_shutdown()
    end
    @test timedwait(() -> istaskdone(task), 10.0) === :ok
end

end # @testitem "Rate limiter: fixed-window sweep"

