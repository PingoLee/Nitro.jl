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

@testset "A response that already carries every header is returned as-is" begin
    # The nested case `serve(security_headers=…)` invites: a router's own `SecurityHeaders()`
    # already set them all, so the outer layer has nothing to add and must not rebuild.
    full = HTTP.Response(200, ["X-Content-Type-Options" => "nosniff", "X-Frame-Options" => "DENY",
                               "Referrer-Policy" => "no-referrer"], "ok")
    @test wrap(SecurityHeaders(), _ -> full)(HTTP.Request("GET", "/")) === full
end

@testset "It is a callable value that still drops into a middleware list" begin
    # #402 made it a struct, so `serve(security_headers = …)` can read its frozen pairs for the
    # transport refusals. `<: Function` keeps every `middleware = [SecurityHeaders()]` working.
    sh = SecurityHeaders(csp = "default-src 'self'")
    @test sh isa Function
    @test ("Content-Security-Policy" => "default-src 'self'") in sh.headers
    off = SecurityHeaders(content_type_options = nothing, frame_options = nothing,
                          referrer_policy = nothing)
    inner = _ -> HTTP.Response(200, "ok")
    @test off(inner) === inner                     # still a pass-through when nothing is on
end

end

# #402. As ordinary middleware `SecurityHeaders` sits inside `compose`, so every response built
# OUTSIDE it went out bare: OriginForm's 400, the prefix strip's 404, ErrorBoundary's 500.
# `serve(security_headers = …)` installs it as a framework layer outside all three. Driven through
# `internalrequest`, which runs the same `setupmiddleware` as `serve`, prefix included.
@testitem "SecurityHeaders as a framework layer" tags=[:middleware, :security] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro

app = App(mod = @__MODULE__)
urlpatterns(app, "", path("/ok", () -> "ok"))
sh = SecurityHeaders(hsts = 600)
boom = handle -> req -> error("middleware boom")
nosniff(resp) = HTTP.header(resp, "X-Content-Type-Options", "")
hsts(resp) = HTTP.header(resp, "Strict-Transport-Security", "")

get_(target; kw...) = internalrequest(app, HTTP.Request("GET", target); kw...)

@testset "every framework-built response carries the headers" begin
    @test nosniff(get_("/ok"; security_headers = sh)) == "nosniff"
    @test hsts(get_("/ok"; security_headers = sh)) == "max-age=600; includeSubDomains"
    @test nosniff(get_("/nope"; security_headers = sh)) == "nosniff"          # router 404

    bad = get_("//x"; security_headers = sh)                                   # OriginForm 400
    @test bad.status == 400
    @test nosniff(bad) == "nosniff"                                            # (unpatched: "")

    err = @test_logs (:error,) match_mode=:any get_("/ok"; middleware = [boom], security_headers = sh)
    @test err.status == 500                                                    # ErrorBoundary 500
    @test nosniff(err) == "nosniff"                                            # (unpatched: "")
end

@testset "the prefix strip's 404 carries them too" begin
    app.service.prefix[] = "/api"
    try
        miss = get_("/elsewhere"; security_headers = sh)
        @test miss.status == 404
        @test nosniff(miss) == "nosniff"                                       # (unpatched: "")
        @test get_("/api/ok"; security_headers = sh).status == 200
    finally
        app.service.prefix[] = nothing
    end
end

@testset "the shared const 400/404 are never mutated, and the default stays opt-in" begin
    for _ in 1:3
        @test length(HTTP.headers(get_("//x"; security_headers = sh), "X-Frame-Options")) == 1
    end
    # Same pipeline objects, no keyword: still bare, so nothing leaked into the shared responses.
    @test nosniff(get_("//x")) == ""
    @test nosniff(get_("/ok")) == ""
end

@testset "an app-level SecurityHeaders beside it adds no second copy" begin
    resp = get_("/ok"; middleware = [SecurityHeaders(frame_options = "SAMEORIGIN")],
                security_headers = sh)
    # The inner (route-adjacent) choice wins, as for any header an inner layer already set.
    @test HTTP.headers(resp, "X-Frame-Options") == ["SAMEORIGIN"]
end
end
