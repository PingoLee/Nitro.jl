@testitem "CORS middleware" tags=[:middleware, :network] setup=[NitroCommon] begin
using HTTP
using Nitro

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

serve(port=PORT, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

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

    r = HTTP.request("OPTIONS", "$localhost/customcors/test")
    @test HTTP.header(r, "Access-Control-Allow-Origin") == "https://example.com"
    @test HTTP.header(r, "Access-Control-Allow-Credentials") == "true"
    @test HTTP.header(r, "Access-Control-Max-Age") == "600"

    # Custom CORS headers test
    r = HTTP.request("OPTIONS", "$localhost/extracors/custom")
    @test HTTP.header(r, "Access-Control-Expose-Headers") == "X-My-Header"
    @test HTTP.header(r, "X-Test-Header") == "TestValue"

    r = HTTP.get("$localhost/extracors/custom")
    @test HTTP.header(r, "Access-Control-Expose-Headers") == "X-My-Header"
    @test HTTP.header(r, "X-Test-Header") == "TestValue"
end

terminate()

# ── Global CORS ──

urlpatterns("",
    path("/hello", function() return "ok" end, method="GET"),
)

serve(middleware=[Cors()], port=PORT, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

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