@testitem "Request ergonomics" tags=[:core] setup=[NitroCommon] begin

using Test
using HTTP
using Nitro
using Base.Threads

@testset "Request ergonomics" begin
    @testset "request accessor caching" begin
        req = HTTP.Request("POST", "/items?source=query", [], "{\"source\":\"json\",\"count\":1}")

        first_json = getjson(req)
        second_json = getjson(req)
        first_input = payload(req)
        second_input = payload(req)

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
        # parameter. `getjson(req)`/`getform(req)` were already memoized; this closed the gap.
        @test getquery(req) === getquery(req)
        @test getparams(req) === getparams(req)
        @test Nitro.Core.Types.headers(req) === Nitro.Core.Types.headers(req)

        @test haskey(req.context, Nitro.Core.Types.REQUEST_QUERY_CACHE_KEY)
        @test haskey(req.context, Nitro.Core.Types.REQUEST_PATHPARAMS_CACHE_KEY)
        @test haskey(req.context, Nitro.Core.Types.REQUEST_HEADERS_CACHE_KEY)

        # Values still correct after caching.
        @test getquery(req) == Dict("a" => "1", "b" => "2")
        @test getparams(req) == Dict("id" => "7")
        @test Nitro.Core.Types.headers(req)["x-trace"] == "abc"
    end

    @testset "a pre-router read of path params is never cached (#38)" begin
        # `HTTP.getparams` reads `req.context[:params]`, which the ROUTER fills — and
        # middleware runs before the router. Caching the `nothing` a pre-router read sees
        # would poison the request: the path binder would later index into `nothing` and
        # 500 every parameterized route. So `nothing` is returned uncached, and the value
        # starts being cached only once the router has actually populated the slot.
        req = HTTP.Request("GET", "/never-routed")
        @test getparams(req) === nothing
        @test !haskey(req.context, Nitro.Core.Types.REQUEST_PATHPARAMS_CACHE_KEY)

        # Now the router runs. The next read must see the real params, not a cached miss.
        req.context[:params] = Dict("id" => "7")
        @test getparams(req) == Dict("id" => "7")
        @test haskey(req.context, Nitro.Core.Types.REQUEST_PATHPARAMS_CACHE_KEY)
        @test getparams(req) === getparams(req)
    end

    @testset "a malformed query is not memoized as a value (#38)" begin
        # `queryvars` raises `ValidationError` so the error handler can turn it into a 400.
        # A cache that stored the *failure* would be the wrong shape for that, so a throwing
        # builder must cache nothing and rethrow on the next touch.
        req = HTTP.Request("GET", "/x?v=%ZZ")
        @test_throws Nitro.ValidationError getquery(req)
        @test !haskey(req.context, Nitro.Core.Types.REQUEST_QUERY_CACHE_KEY)
        @test_throws Nitro.ValidationError getquery(req)
    end

    @testset "query and merged input" begin
        req = HTTP.Request("POST", "/users/42?shared=query&only_query=1", [], "{\"shared\":\"json\",\"only_json\":2}")
        req.context[:params] = Dict("shared" => "path", "id" => "42")

        @test getquery(req) == Dict("shared" => "query", "only_query" => "1")
        @test getparams(req) == Dict("shared" => "path", "id" => "42")
        @test payload(req)["shared"] == "path"
        @test payload(req)["id"] == "42"
        @test payload(req)["only_query"] == "1"
        @test payload(req)["only_json"] == 2
    end

    @testset "form overrides query" begin
        req = HTTP.Request("POST", "/submit?shared=query&only_query=1", [], "shared=form&only_form=2")

        @test getform(req) == Dict("shared" => "form", "only_form" => "2")
        @test payload(req)["shared"] == "form"
        @test payload(req)["only_query"] == "1"
        @test payload(req)["only_form"] == "2"
    end

    @testset "empty and malformed bodies degrade gracefully" begin
        empty_req = HTTP.Request("POST", "/empty", [], "")
        bad_json_req = HTTP.Request("POST", "/bad-json", [], "{not-json")
        plain_text_req = HTTP.Request("POST", "/plain", [], "hello world")

        @test isnothing(getjson(empty_req))
        @test getform(empty_req) == Dict{String,String}()
        @test isempty(payload(empty_req))

        @test isnothing(getjson(bad_json_req))
        @test getform(bad_json_req) == Dict{String,String}()

        @test isnothing(getjson(plain_text_req))
        @test getform(plain_text_req) == Dict{String,String}()
    end

    @testset "concurrent requests keep isolated caches" begin
        tasks = [Threads.@spawn begin
            req = HTTP.Request("POST", "/items?request=$(index)", [], "{\"request\":$(index),\"payload\":\"$(repeat('x', 128))\"}")
            req.context[:params] = Dict("request" => string(index))
            return payload(req)["request"] => getjson(req)["payload"]
        end for index in 1:8]

        results = fetch.(tasks)
        @test length(results) == 8
        @test Set(first.(results)) == Set(string(index) for index in 1:8)
        @test all(length(last(result)) == 128 for result in results)
    end

    @testset "large payloads are cached" begin
        blob = repeat("a", 100_000)
        req = HTTP.Request("POST", "/large", [], "{\"blob\":\"$(blob)\"}")

        first_json = getjson(req)
        second_json = getjson(req)

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

        # getfiles(req) — Django request.FILES: only the file parts.
        files = getfiles(req)
        @test haskey(files, "file1_id")
        @test !haskey(files, "cruzamento")
        @test files["file1_id"] isa FormFile
        @test files["file1_id"].filename == "data.dbf"
        @test String(files["file1_id"].data) == "dbf bytes"

        # getpost(req) — Django request.POST: only the text fields.
        post = getpost(req)
        @test post["cruzamento"] == "yes"
        @test !haskey(post, "file1_id")

        # Both accessors are cached and the body is parsed only once.
        @test getfiles(req) === files
        @test getpost(req) === post

        # Multipart text fields are folded into the merged payload(req) (Django POST
        # ⊂ input); files are NOT, and the body is no longer parsed as urlencoded
        # form data (which would otherwise leave a garbage key behind).
        @test payload(req)["cruzamento"] == "yes"
        @test !haskey(payload(req), "file1_id")
        @test getform(req) == Dict{String,String}()
    end

    @testset "non-multipart requests degrade gracefully" begin
        req = HTTP.Request("POST", "/plain", [], "shared=form")

        @test getfiles(req) == Dict{String, Union{FormFile, Vector{FormFile}}}()
        @test getpost(req) == Dict{String, Union{String, Vector{String}}}()
    end
end

end