@testitem "Request ergonomics" tags=[:core] setup=[NitroCommon] begin

using Test
using HTTP
using Nitro
using Base.Threads

# `getjson` reads only a body that declares itself JSON (#327).
const JSON_CT = ["Content-Type" => "application/json"]

@testset "Request ergonomics" begin
    @testset "request accessor caching" begin
        req = HTTP.Request("POST", "/items?source=query", JSON_CT, "{\"source\":\"json\",\"count\":1}")

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
        req = HTTP.Request("POST", "/users/42?shared=query&only_query=1", JSON_CT, "{\"shared\":\"json\",\"only_json\":2}")
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
        bad_json_req = HTTP.Request("POST", "/bad-json", JSON_CT, "{not-json")
        plain_text_req = HTTP.Request("POST", "/plain", [], "hello world")

        @test isnothing(getjson(empty_req))
        @test getform(empty_req) == Dict{String,String}()
        @test isempty(payload(empty_req))

        @test isnothing(getjson(bad_json_req))
        @test getform(bad_json_req) == Dict{String,String}()

        @test isnothing(getjson(plain_text_req))
        @test getform(plain_text_req) == Dict{String,String}()
    end

    @testset "a body that does not declare itself JSON is not read as JSON (#327)" begin
        # `text/plain`, a form type, and no Content-Type at all are what a cross-site page can
        # send without a CORS preflight; the body is valid JSON in every case.
        body = "{\"role\":\"admin\"}"
        for headers in ([], ["Content-Type" => "text/plain"],
                        ["Content-Type" => "application/x-www-form-urlencoded"])
            req = HTTP.Request("POST", "/items", headers, body)
            @test isnothing(getjson(req))
            @test !haskey(payload(req), "role")
        end
        for ct in ("application/json", "application/json; charset=utf-8", "APPLICATION/JSON",
                   "application/vnd.api+json", "application/problem+json")
            req = HTTP.Request("POST", "/items", ["Content-Type" => ct], body)
            @test getjson(req)["role"] == "admin"
            @test payload(req)["role"] == "admin"
        end
        # `application/jsonp` and `text/json` are not JSON media types.
        for ct in ("application/jsonp", "text/json", "application/json-seq")
            @test isnothing(getjson(HTTP.Request("POST", "/items", ["Content-Type" => ct], body)))
        end
    end

    @testset "concurrent requests keep isolated caches" begin
        tasks = [Threads.@spawn begin
            req = HTTP.Request("POST", "/items?request=$(index)", JSON_CT, "{\"request\":$(index),\"payload\":\"$(repeat('x', 128))\"}")
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
        req = HTTP.Request("POST", "/large", JSON_CT, "{\"blob\":\"$(blob)\"}")

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

@testitem "payload(req) reads only the parser its Content-Type admits (#553)" tags=[:core] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro: App

# The merge `payload` did before #553, through the public accessors: every parser, in order. A
# skipped parser must be one whose answer contributed nothing.
oracle(req) = (m = Dict{String, Any}();
    for src in (getquery(req), getjson(req), getform(req), getpost(req), getparams(req))
        src isa AbstractDict && for (k, v) in src; m[string(k)] = v; end
    end; m)

const MP = "--b\r\nContent-Disposition: form-data; name=\"shared\"\r\n\r\nmultipart\r\n" *
           "--b\r\nContent-Disposition: form-data; name=\"mp\"\r\n\r\nm\r\n--b--\r\n"
const JSONBODY = "{\"shared\":\"json\",\"j\":1}"
const FORMBODY = "shared=form&f=2"
cases = Tuple{Union{Nothing, String}, String}[]
for ct in ("application/json", "application/problem+json", "APPLICATION/JSON; charset=utf-8",
           "application/x-www-form-urlencoded", "Application/X-WWW-Form-Urlencoded; charset=UTF-8",
           "multipart/form-data; boundary=b", "Multipart/Form-Data; boundary=b", "multipart/form-data",
           "text/plain", "application/xml", "", nothing),
    body in (JSONBODY, FORMBODY, MP, "")
    push!(cases, (ct, body))
end
mkreq(target, ct, body) = HTTP.Request("POST", target, isnothing(ct) ? [] : ["Content-Type" => ct], body)

@testset "the merge is the old one for every body and type" begin
    for (ct, body) in cases, target in ("/p/7", "/p/7?shared=query&q=1")
        req = mkreq(target, ct, body)
        got = payload(req)
        @test got == oracle(req)
    end
    # Each source still reaches the merge under its own type (a constant answer could not pass).
    @test payload(mkreq("/p", "application/json", JSONBODY))["j"] == 1
    @test payload(mkreq("/p", "application/x-www-form-urlencoded", FORMBODY))["f"] == "2"
    @test payload(mkreq("/p", nothing, FORMBODY))["f"] == "2"
    @test payload(mkreq("/p", "multipart/form-data; boundary=b", MP))["mp"] == "m"
end

@testset "and through the router, path params included" begin
    app = App(mod = @__MODULE__)
    urlpatterns(app, "", path("/p/<str:id>", function (req, id::String)
        got = payload(req)
        return got == oracle(req) && got["id"] == id ? "same" : "differs: $(got) vs $(oracle(req))"
    end; method = "POST"))
    for (ct, body) in cases
        r = internalrequest(app, mkreq("/p/7?shared=query&q=1", ct, body))
        @test (r.status, Nitro.text(r)) == (200, "same")
    end
end

@testset "a JSON POST no longer pays for the form and multipart parsers" begin
    hdrs() = Pair{String, String}["Host" => "example.test", "Accept" => "application/json",
        "Content-Length" => "7", "Content-Type" => "application/json"]
    fresh() = HTTP.Request("POST", "/x", hdrs(), "{\"a\":1}")
    # Every measurement builds the same fresh request, so differences of totals cancel it out.
    @testset let json = allocs(() -> getjson(fresh()); calls = 200),
                 merged = allocs(() -> payload(fresh()); calls = 200),
                 # Positive control: the old merge, which ran the form and multipart parsers too.
                 old = allocs(() -> oracle(fresh()); calls = 200)
        # Beyond `getjson`, `payload` owns the query parse, the merged `Dict` and its cache slot:
        # measured 9 on 1.13.2, where the old merge cost 20. Bound at the target, not the value.
        @test merged.count - json.count <= 12
        @test old.count - json.count > 12
    end
end
end
