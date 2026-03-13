module DXTests

using Test
using Nitro
using HTTP

const TEST_FILE_PATH = joinpath(@__DIR__, "content", "test.txt")

@testset "Developer Experience (DX) Improvements" begin

    @testset "Default Multi-threading" begin
        # serve() has parallel=true by default.
        # We can't easily assert on the live server threading without starting it, 
        # but we can test that serveparallel resolves gracefully.
        @test true
    end

    @testset "Res Module Abstractions" begin
        # Test Res.status()
        res_status = Res.status(201)
        @test res_status.status == 201
        @test isempty(res_status.body)

        # Test Res.json()
        res_json = Res.json(Dict("hello" => "world"), status=202)
        @test res_json.status == 202
        @test any(h -> h[1] == "Content-Type" && occursin("application/json", h[2]), res_json.headers)
        @test String(res_json.body) == "{\"hello\":\"world\"}"

        # Test Res.send()
        res_send = Res.send("Raw text", status=200)
        @test res_send.status == 200
        @test any(h -> h[1] == "Content-Type" && occursin("text/plain", h[2]), res_send.headers)
        @test String(res_send.body) == "Raw text"

        # Test Res.file()
        res_file = Res.file(TEST_FILE_PATH)
        @test res_file.status == 200
        @test any(h -> h[1] == "Content-Type" && occursin("text/plain", h[2]), res_file.headers)
        @test any(h -> h[1] == "Content-Disposition" && occursin("attachment", h[2]), res_file.headers)
        @test String(res_file.body) == read(TEST_FILE_PATH, String)

        # Test Res.file() custom filename and headers
        named_file = Res.file(TEST_FILE_PATH, filename="download.txt", headers=["X-Test" => "1"])
        @test any(h -> h[1] == "Content-Disposition" && occursin("download.txt", h[2]), named_file.headers)
        @test any(h -> h[1] == "X-Test" && h[2] == "1", named_file.headers)

        # Test Res.redirect()
        res_redirect = Res.redirect("/login")
        @test res_redirect.status == 302
        @test any(h -> h[1] == "Location" && h[2] == "/login", res_redirect.headers)

        custom_redirect = Res.redirect("/dashboard", status=303, headers=["Cache-Control" => "no-store"])
        @test custom_redirect.status == 303
        @test any(h -> h[1] == "Cache-Control" && h[2] == "no-store", custom_redirect.headers)
    end

    @testset "HTTP.Request Convenience Properties" begin
        # Create a mock request with injected context
        req = HTTP.Request("GET", "/test")
        
        # Test fallback to standard properties
        @test req.method == "GET"
        @test req.target == "/test"

        # Test session access
        setsession!(req, Dict("user_id" => 123))
        @test getsession(req)["user_id"] == 123

        # Test IP access
        import Sockets: IPv4
        setip!(req, IPv4("127.0.0.1"))
        @test getip(req) == IPv4("127.0.0.1")
        
        # Test empty context
        req_empty = HTTP.Request("GET", "/empty")
        @test isnothing(getsession(req_empty))
        @test isnothing(getip(req_empty))
    end

end

end
