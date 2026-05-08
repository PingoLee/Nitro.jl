@testitem "CORS middleware" tags=[:middleware, :network] setup=[NitroCommon] begin
using HTTP
using Nitro

port = get_free_port()
localhost = "http://$HOST:$port"

# ── Router-level CORS ──

urlpatterns("/cors",
    path("/hello", function() return "ok" end, methods=["GET", "OPTIONS"], middleware=[Cors()]),
)

urlpatterns("/customcors",
    path("/test", function() return "custom" end, methods=["GET", "OPTIONS"],
        middleware=[Cors(allowed_origins=["https://example.com"], allow_credentials=true, max_age=600)]),
)

urlpatterns("/extracors",
    path("/custom", function() return "custom headers" end, methods=["GET", "OPTIONS"],
        middleware=[Cors(extra_headers=["Access-Control-Expose-Headers" => "X-My-Header", "X-Test-Header" => "TestValue"])]),
)

# Multiple allowed origins — the middleware must echo the matching origin
urlpatterns("/multicors",
    path("/data", function() return "multi" end, methods=["GET", "OPTIONS"],
        middleware=[Cors(allowed_origins=["https://app.example.com", "https://admin.example.com"], allow_credentials=true)]),
)

# Wildcard + credentials — must echo request origin, not "*"
urlpatterns("/wildcred",
    path("/open", function() return "wildcred" end, methods=["GET", "OPTIONS"],
        middleware=[Cors(allowed_origins=["*"], allow_credentials=true)]),
)

serve(port=port, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

@testset "CORS Middleware Tests" begin
    # Preflight OPTIONS request
    r = HTTP.request("OPTIONS", "$localhost/cors/hello")
    @test r.status == 200
    @test HTTP.header(r, "Access-Control-Allow-Origin") == "*"
    @test HTTP.header(r, "Access-Control-Allow-Headers") == "*"
    @test occursin("GET", HTTP.header(r, "Access-Control-Allow-Methods"))
    @test occursin("POST", HTTP.header(r, "Access-Control-Allow-Methods"))
    @test occursin("OPTIONS", HTTP.header(r, "Access-Control-Allow-Methods"))

    # GET request includes CORS headers
    r = HTTP.get("$localhost/cors/hello")
    @test r.status == 200
    @test HTTP.header(r, "Access-Control-Allow-Origin") == "*"
    @test HTTP.header(r, "Access-Control-Allow-Headers") == "*"
    @test occursin("GET", HTTP.header(r, "Access-Control-Allow-Methods"))

    # Single origin + credentials — echoes back the one origin, adds Vary
    r = HTTP.request("OPTIONS", "$localhost/customcors/test")
    @test HTTP.header(r, "Access-Control-Allow-Origin") == "https://example.com"
    @test HTTP.header(r, "Access-Control-Allow-Credentials") == "true"
    @test HTTP.header(r, "Access-Control-Max-Age") == "600"
    @test HTTP.header(r, "Vary") == "Origin"

    # Custom CORS headers test
    r = HTTP.request("OPTIONS", "$localhost/extracors/custom")
    @test HTTP.header(r, "Access-Control-Expose-Headers") == "X-My-Header"
    @test HTTP.header(r, "X-Test-Header") == "TestValue"

    r = HTTP.get("$localhost/extracors/custom")
    @test HTTP.header(r, "Access-Control-Expose-Headers") == "X-My-Header"
    @test HTTP.header(r, "X-Test-Header") == "TestValue"
end

@testset "Multi-Origin CORS" begin
    # Matching origin is echoed back
    r = HTTP.request("OPTIONS", "$localhost/multicors/data",
        ["Origin" => "https://app.example.com"])
    @test HTTP.header(r, "Access-Control-Allow-Origin") == "https://app.example.com"
    @test HTTP.header(r, "Access-Control-Allow-Credentials") == "true"
    @test HTTP.header(r, "Vary") == "Origin"

    # Second allowed origin works too
    r = HTTP.request("OPTIONS", "$localhost/multicors/data",
        ["Origin" => "https://admin.example.com"])
    @test HTTP.header(r, "Access-Control-Allow-Origin") == "https://admin.example.com"

    # Non-matching origin — no Allow-Origin header
    r = HTTP.request("OPTIONS", "$localhost/multicors/data",
        ["Origin" => "https://evil.example.com"])
    @test HTTP.header(r, "Access-Control-Allow-Origin") == ""

    # GET with matching origin
    r = HTTP.get("$localhost/multicors/data",
        ["Origin" => "https://app.example.com"])
    @test HTTP.header(r, "Access-Control-Allow-Origin") == "https://app.example.com"
    @test HTTP.header(r, "Vary") == "Origin"
end

@testset "Wildcard + Credentials CORS" begin
    # Must echo the request origin, not "*"
    r = HTTP.request("OPTIONS", "$localhost/wildcred/open",
        ["Origin" => "https://any-site.example.com"])
    @test HTTP.header(r, "Access-Control-Allow-Origin") == "https://any-site.example.com"
    @test HTTP.header(r, "Access-Control-Allow-Credentials") == "true"
    @test HTTP.header(r, "Vary") == "Origin"

    # Without Origin header, falls back to "*"
    r = HTTP.request("OPTIONS", "$localhost/wildcred/open")
    @test HTTP.header(r, "Access-Control-Allow-Origin") == "*"
end

terminate()

# ── Global CORS ──

urlpatterns("",
    path("/hello", function() return "ok" end, method="GET"),
)

serve(middleware=[Cors()], port=port, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

@testset "Global CORS Tests" begin
    # Preflight OPTIONS request
    r = HTTP.request("OPTIONS", "$localhost/hello")
    @test r.status == 200
    @test HTTP.header(r, "Access-Control-Allow-Origin") == "*"
    @test HTTP.header(r, "Access-Control-Allow-Headers") == "*"
    @test occursin("GET", HTTP.header(r, "Access-Control-Allow-Methods"))
    @test occursin("POST", HTTP.header(r, "Access-Control-Allow-Methods"))
    @test occursin("OPTIONS", HTTP.header(r, "Access-Control-Allow-Methods"))
end

terminate()

end