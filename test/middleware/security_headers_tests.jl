@testitem "SecurityHeaders middleware" tags=[:middleware, :security] setup=[NitroCommon] begin
using Test
using Dates
using HTTP
using Nitro

# Driven by wrapping a handler directly rather than over a socket. `SecurityHeaders` never reads
# the request and owns no background resource, so a live server would only add a port binding and
# a few seconds to assertions about a header vector.
wrap(mw, handler = _ -> HTTP.Response(200, "ok")) = mw(handler)
call(mw; target = "/") = wrap(mw)(HTTP.Request("GET", target))

headervalues(resp, name) = [v for (k, v) in resp.headers if lowercase(k) == lowercase(name)]

@testset "Defaults are the three headers that cannot break a caller" begin
    resp = call(SecurityHeaders())
    @test resp.status == 200
    @test HTTP.header(resp, "X-Content-Type-Options") == "nosniff"
    @test HTTP.header(resp, "X-Frame-Options") == "DENY"
    @test HTTP.header(resp, "Referrer-Policy") == "strict-origin-when-cross-origin"

    # Off unless asked for. Both are omitted on purpose: HSTS is sticky for its whole max-age and
    # cannot be recalled, and there is no CSP that is safe to guess for an unknown SPA.
    @test HTTP.header(resp, "Strict-Transport-Security", "") == ""
    @test HTTP.header(resp, "Content-Security-Policy", "") == ""
end

@testset "Each default can be suppressed with nothing" begin
    resp = call(SecurityHeaders(content_type_options = nothing,
                                frame_options        = nothing,
                                referrer_policy      = nothing))
    @test HTTP.header(resp, "X-Content-Type-Options", "") == ""
    @test HTTP.header(resp, "X-Frame-Options", "") == ""
    @test HTTP.header(resp, "Referrer-Policy", "") == ""
    # Suppressing everything yields a pass-through that does not rebuild the response at all.
    @test resp.status == 200
end

@testset "A header the inner layer already set is left alone, not duplicated" begin
    # This is the assertion the obvious version of this test MISSES. Wrapping the default handler
    # (whose headers are empty) proves only that the constructor swapped a string, and passes
    # identically against an implementation that appends a second copy. The inner layer has to
    # actually set the header for the difference to show.
    inner = _ -> HTTP.Response(200, ["X-Frame-Options" => "SAMEORIGIN"], "ok")

    resp = SecurityHeaders()(inner)(HTTP.Request("GET", "/widget"))
    # Two conflicting values is not "more secure" -- RFC 7034 §2.1 makes the directive invalid, so
    # the browser may drop the protection entirely. The route's explicit choice wins.
    @test headervalues(resp, "X-Frame-Options") == ["SAMEORIGIN"]
    # The headers it did NOT set still arrive.
    @test HTTP.header(resp, "X-Content-Type-Options") == "nosniff"
    @test HTTP.header(resp, "Referrer-Policy") == "strict-origin-when-cross-origin"

    # Same rule for an opt-in header and for `extra_headers`, not just the three defaults.
    inner2 = _ -> HTTP.Response(200, ["Content-Security-Policy" => "default-src 'none'",
                                      "X-Custom" => "route"], "ok")
    resp2 = SecurityHeaders(csp = "default-src 'self'",
                            extra_headers = ["X-Custom" => "global"])(inner2)(HTTP.Request("GET", "/"))
    @test headervalues(resp2, "Content-Security-Policy") == ["default-src 'none'"]
    @test headervalues(resp2, "X-Custom") == ["route"]
end

@testset "Constructor kwargs still replace the default value itself" begin
    resp = call(SecurityHeaders(frame_options = "SAMEORIGIN"))
    @test headervalues(resp, "X-Frame-Options") == ["SAMEORIGIN"]
end

@testset "HSTS accepts a Period or seconds, and composes its modifiers" begin
    @test HTTP.header(call(SecurityHeaders(hsts = Day(365))), "Strict-Transport-Security") ==
          "max-age=31536000; includeSubDomains"
    @test HTTP.header(call(SecurityHeaders(hsts = 600)), "Strict-Transport-Security") ==
          "max-age=600; includeSubDomains"
    @test HTTP.header(call(SecurityHeaders(hsts = Hour(1), hsts_include_subdomains = false)),
                      "Strict-Transport-Security") == "max-age=3600"
    @test HTTP.header(call(SecurityHeaders(hsts = Day(365), hsts_preload = true)),
                      "Strict-Transport-Security") ==
          "max-age=31536000; includeSubDomains; preload"
end

@testset "A preload configuration the browser list would reject is refused at construction" begin
    # The same discipline `Cors` applies to `allow_credentials` with a wildcard origin: a header
    # that could never be accepted is not a weaker header, it is a deployment that believes it is
    # preloaded and is not.
    @test_throws ArgumentError SecurityHeaders(hsts = Day(365), hsts_preload = true,
                                               hsts_include_subdomains = false)
    @test_throws ArgumentError SecurityHeaders(hsts = Day(30), hsts_preload = true)
    @test_throws ArgumentError SecurityHeaders(hsts_preload = true)
    @test_throws ArgumentError SecurityHeaders(hsts = -1)
    # Month and Year have no fixed length, so they are not a usable max-age.
    @test_throws MethodError SecurityHeaders(hsts = Year(1))
end

@testset "CSP and extra headers are passed through verbatim" begin
    resp = call(SecurityHeaders(csp = "default-src 'self'; frame-ancestors 'none'",
                                extra_headers = ["Cross-Origin-Opener-Policy" => "same-origin",
                                                 "Permissions-Policy" => "geolocation=()"]))
    @test HTTP.header(resp, "Content-Security-Policy") == "default-src 'self'; frame-ancestors 'none'"
    @test HTTP.header(resp, "Cross-Origin-Opener-Policy") == "same-origin"
    @test HTTP.header(resp, "Permissions-Policy") == "geolocation=()"
end

@testset "Headers reach an error response too, not just a 200" begin
    # The clickjacking and MIME-sniff classes do not care what status the body came with, and a
    # middleware that only decorated successes would miss every error page.
    resp = wrap(SecurityHeaders(), _ -> HTTP.Response(404, "nope"))(HTTP.Request("GET", "/missing"))
    @test resp.status == 404
    @test HTTP.header(resp, "X-Content-Type-Options") == "nosniff"
end

@testset "A shared const response is never mutated" begin
    # `test/middleware/shared_response_mutation_tests.jl` guards Cors/Session and the
    # `*_response_headers` helpers; it is explicitly NOT a net for new middleware, so this member
    # brings its own. The hazard is real here: module-level `const` error responses are an
    # endorsed Nitro pattern (auth rejections use them), and Nitro serves every request on its own
    # thread -- so an in-place `setheader` would both accumulate headers across requests and race.
    SHARED = HTTP.Response(401, "shared-const-body")
    @test isempty(SHARED.headers)

    wrapped = wrap(SecurityHeaders(hsts = Day(365)), _ -> SHARED)
    for _ in 1:3
        resp = wrapped(HTTP.Request("GET", "/"))
        @test resp.status == 401
        @test resp !== SHARED
        @test length(headervalues(resp, "X-Content-Type-Options")) == 1
        @test length(headervalues(resp, "Strict-Transport-Security")) == 1
    end
    @test isempty(SHARED.headers)
    @test String(SHARED.body) == "shared-const-body"
end

@testset "The middleware is reachable through `using Nitro`" begin
    # Three files have to agree for a middleware to be public: its own `export`, the
    # `@reexport using` in src/middleware.jl, and the explicit list in src/Nitro.jl. Only the last
    # one reaches a `using Nitro` caller, and forgetting it is silent everywhere else.
    @test isdefined(Nitro, :SecurityHeaders)
    @test :SecurityHeaders in names(Nitro)
end

end
