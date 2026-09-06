@testitem "Request ergonomics" tags=[:core] setup=[NitroCommon] begin

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

    @testset "query, params and headers are cached per request (#38)" begin
        req = HTTP.Request("GET", "/items/7?a=1&b=2", ["X-Trace" => "abc"])
        req.context[:params] = Dict("id" => "7")

        # Identity, not equality: these three used to rebuild their Dict on every call,
        # so the param binder re-decoded the same unchanged target once per bound
        # parameter. `req.json`/`req.form` were already memoized; this closed the gap.
        @test req.query === req.query
        @test req.params === req.params
        @test Nitro.Core.Types.headers(req) === Nitro.Core.Types.headers(req)

        @test haskey(req.context, Nitro.Core.Types.REQUEST_QUERY_CACHE_KEY)
        @test haskey(req.context, Nitro.Core.Types.REQUEST_PATHPARAMS_CACHE_KEY)
        @test haskey(req.context, Nitro.Core.Types.REQUEST_HEADERS_CACHE_KEY)

        # Values still correct after caching.
        @test req.query == Dict("a" => "1", "b" => "2")
        @test req.params == Dict("id" => "7")
        @test Nitro.Core.Types.headers(req)["x-trace"] == "abc"
    end

    @testset "a pre-router read of path params is never cached (#38)" begin
        # `HTTP.getparams` reads `req.context[:params]`, which the ROUTER fills — and
        # middleware runs before the router. Caching the `nothing` a pre-router read sees
        # would poison the request: the path binder would later index into `nothing` and
        # 500 every parameterized route. So `nothing` is returned uncached, and the value
        # starts being cached only once the router has actually populated the slot.
        req = HTTP.Request("GET", "/never-routed")
        @test req.params === nothing
        @test !haskey(req.context, Nitro.Core.Types.REQUEST_PATHPARAMS_CACHE_KEY)

        # Now the router runs. The next read must see the real params, not a cached miss.
        req.context[:params] = Dict("id" => "7")
        @test req.params == Dict("id" => "7")
        @test haskey(req.context, Nitro.Core.Types.REQUEST_PATHPARAMS_CACHE_KEY)
        @test req.params === req.params
    end

    @testset "a malformed query is not memoized as a value (#38)" begin
        # `queryvars` raises `ValidationError` so the error handler can turn it into a 400.
        # A cache that stored the *failure* would be the wrong shape for that, so a throwing
        # builder must cache nothing and rethrow on the next touch.
        req = HTTP.Request("GET", "/x?v=%ZZ")
        @test_throws Nitro.ValidationError req.query
        @test !haskey(req.context, Nitro.Core.Types.REQUEST_QUERY_CACHE_KEY)
        @test_throws Nitro.ValidationError req.query
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

    @testset "multipart files and post" begin
        # Build a raw multipart/form-data body with both a file part and text fields.
        boundary = "----TestBoundary7MA4YWxkTrZu0gW"
        function build_multipart(parts)
            io = IOBuffer()
            for part in parts
                write(io, "--$boundary\r\n")
                if haskey(part, :filename)
                    write(io, "Content-Disposition: form-data; name=\"$(part[:name])\"; filename=\"$(part[:filename])\"\r\n")
                    write(io, "Content-Type: application/octet-stream\r\n")
                else
                    write(io, "Content-Disposition: form-data; name=\"$(part[:name])\"\r\n")
                end
                write(io, "\r\n")
                write(io, part[:data])
                write(io, "\r\n")
            end
            write(io, "--$boundary--\r\n")
            return take!(io), "multipart/form-data; boundary=$boundary"
        end

        body, ct = build_multipart([
            Dict(:name => "file1_id", :filename => "data.dbf", :data => "dbf bytes"),
            Dict(:name => "cruzamento", :data => "yes"),
        ])
        req = HTTP.Request("POST", "/upload", ["Content-Type" => ct], body)

        # req.files — Django request.FILES: only the file parts.
        files = req.files
        @test haskey(files, "file1_id")
        @test !haskey(files, "cruzamento")
        @test files["file1_id"] isa FormFile
        @test files["file1_id"].filename == "data.dbf"
        @test String(files["file1_id"].data) == "dbf bytes"

        # req.post — Django request.POST: only the text fields.
        post = req.post
        @test post["cruzamento"] == "yes"
        @test !haskey(post, "file1_id")

        # Both accessors are cached and the body is parsed only once.
        @test req.files === files
        @test req.post === post

        # Multipart text fields are folded into the merged req.input (Django POST
        # ⊂ input); files are NOT, and the body is no longer parsed as urlencoded
        # form data (which would otherwise leave a garbage key behind).
        @test req.input["cruzamento"] == "yes"
        @test !haskey(req.input, "file1_id")
        @test req.form == Dict{String,String}()
    end

    @testset "non-multipart requests degrade gracefully" begin
        req = HTTP.Request("POST", "/plain", [], "shared=form")

        @test req.files == Dict{String, Union{FormFile, Vector{FormFile}}}()
        @test req.post == Dict{String, Union{String, Vector{String}}}()
    end
end

end