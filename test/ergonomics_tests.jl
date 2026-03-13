module ErgonomicsTests

using Test
using HTTP
using Nitro
using Base.Threads

@testset "Request ergonomics" begin
    @testset "request property caching" begin
        req = HTTP.Request("POST", "/items?source=query", [], "{\"source\":\"json\",\"count\":1}")

        first_json = req.json
        second_json = req.json
        first_input = req.input
        second_input = req.input

        @test first_json === second_json
        @test first_input === second_input
        @test haskey(req.context, Nitro.Core.REQUEST_JSON_CACHE_KEY)
        @test haskey(req.context, Nitro.Core.REQUEST_INPUT_CACHE_KEY)
    end

    @testset "query and merged input" begin
        req = HTTP.Request("POST", "/users/42?shared=query&only_query=1", [], "{\"shared\":\"json\",\"only_json\":2}")
        req.context[:params] = Dict("shared" => "path", "id" => "42")

        @test req.query == Dict("shared" => "query", "only_query" => "1")
        @test req.params == Dict("shared" => "path", "id" => "42")
        @test req.input["shared"] == "path"
        @test req.input["id"] == "42"
        @test req.input["only_query"] == "1"
        @test req.input["only_json"] == 2
    end

    @testset "form overrides query" begin
        req = HTTP.Request("POST", "/submit?shared=query&only_query=1", [], "shared=form&only_form=2")

        @test req.form == Dict("shared" => "form", "only_form" => "2")
        @test req.input["shared"] == "form"
        @test req.input["only_query"] == "1"
        @test req.input["only_form"] == "2"
    end

    @testset "empty and malformed bodies degrade gracefully" begin
        empty_req = HTTP.Request("POST", "/empty", [], "")
        bad_json_req = HTTP.Request("POST", "/bad-json", [], "{not-json")
        plain_text_req = HTTP.Request("POST", "/plain", [], "hello world")

        @test isnothing(empty_req.json)
        @test empty_req.form == Dict{String,String}()
        @test isempty(empty_req.input)

        @test isnothing(bad_json_req.json)
        @test bad_json_req.form == Dict{String,String}()

        @test isnothing(plain_text_req.json)
        @test plain_text_req.form == Dict{String,String}()
    end

    @testset "concurrent requests keep isolated caches" begin
        tasks = [Threads.@spawn begin
            req = HTTP.Request("POST", "/items?request=$(index)", [], "{\"request\":$(index),\"payload\":\"$(repeat('x', 128))\"}")
            req.context[:params] = Dict("request" => string(index))
            return req.input["request"] => req.json["payload"]
        end for index in 1:8]

        results = fetch.(tasks)
        @test length(results) == 8
        @test Set(first.(results)) == Set(string(index) for index in 1:8)
        @test all(length(last(result)) == 128 for result in results)
    end

    @testset "large payloads are cached" begin
        blob = repeat("a", 100_000)
        req = HTTP.Request("POST", "/large", [], "{\"blob\":\"$(blob)\"}")

        first_json = req.json
        second_json = req.json

        @test first_json === second_json
        @test length(first_json["blob"]) == 100_000
    end
end

end