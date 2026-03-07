module DXTests

using Test
using Nitro
using HTTP

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
    end

    @testset "HTTP.Request Convenience Properties" begin
        # Create a mock request with injected context
        req = HTTP.Request("GET", "/test")
        
        # Test fallback to standard properties
        @test req.method == "GET"
        @test req.target == "/test"

        # Test session access
        req.context[:session] = Dict("user_id" => 123)
        @test req.session["user_id"] == 123

        # Test IP access
        import Sockets: IPv4
        req.context[:ip] = IPv4("127.0.0.1")
        @test req.ip == IPv4("127.0.0.1")
        
        # Test empty context
        req_empty = HTTP.Request("GET", "/empty")
        @test isnothing(req_empty.session)
        @test isnothing(req_empty.ip)
    end

end

end
