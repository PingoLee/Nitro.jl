
module BodyParserTests 
using Test

using Nitro
using Nitro: set_content_size!

struct rank
    title   :: String 
    power   :: Float64
end

req = Request("GET", "/json", [], """{"message":["hello",1.0]}""")
json(req)

@testset "queryparams" begin
    no_params = Request("GET", "http://google.com")
    with_params = Request("GET", "http://google.com?q=123&l=345")

    @test queryparams(no_params) == Dict{String, String}()
    @test queryparams(with_params) == Dict("q" => "123", "l" => "345")

    @test queryparams(Response(200; body="", request=with_params)) == Dict("q" => "123", "l" => "345")
    @test isnothing(queryparams(Response(200; body="")))
end

@testset "formdata() Request struct keyword tests" begin 
    req = Request("POST", "/", [], "message=hello world&value=3")
    data = formdata(req)
    @test data["message"] == "hello world"
    @test data["value"] == "3"
end

@testset "formdata() Response struct keyword tests" begin 
    req = Response("message=hello world&value=3")
    data = formdata(req)
    @test data["message"] == "hello world"
    @test data["value"] == "3"
end


@testset "set_content_size!" begin
    headers = ["Content-Type" => "text/plain"]
    body = Vector{UInt8}("Hello, World!")
    @testset "when add is false and replace is false" begin
        set_content_size!(body, headers, add=false, replace=false)
        @test length(headers) == 1
        @test headers[1].first == "Content-Type" 
        @test headers[1].second == "text/plain"
    end

    @testset "when add is true and replace is false" begin
        set_content_size!(body, headers, add=true, replace=false)
        @test length(headers) == 2
        @test headers[1].first == "Content-Type"
        @test headers[1].second == "text/plain"
        @test headers[2].first == "Content-Length"
        @test headers[2].second == "13"
    end

    @testset "when add is false and replace is true" begin
        headers = ["Content-Length" => "0", "Content-Type" => "text/plain"]
        set_content_size!(body, headers, add=false, replace=true)
        @test length(headers) == 2
        @test headers[1].first == "Content-Length"
        @test headers[1].second == "13"
        @test headers[2].first == "Content-Type"
        @test headers[2].second == "text/plain"
    end

    @testset "when add is true and replace is true" begin
        headers = ["Content-Type" => "text/plain"]
        set_content_size!(body, headers, add=true, replace=true)
        @test length(headers) == 2
        @test headers[1].first == "Content-Type"
        @test headers[1].second == "text/plain"
        @test headers[2].first == "Content-Length"
        @test headers[2].second == "13"
    end
end


@testset "json() Request struct keyword tests" begin 


    @testset "json() Request struct keyword tests" begin 

        req = Request("GET", "/json", [], "{\"message\":[NaN,1.0]}")
        @test isnan(json(req, allownan = true)["message"][1])
        @test !isnan(json(req, allownan = true)["message"][2])

        req = Request("GET", "/json", [], "{\"message\":[Inf,1.0]}")
        @test isinf(json(req, allownan = true)["message"][1])

        req = Request("GET", "/json", [], "{\"message\":[null,1.0]}")
        @test isnothing(json(req, allownan = false)["message"][1])

    end


    @testset "json() Request stuct keyword with class_type" begin 

        req = Request("GET","/", [],"""{"title": "viscount", "power": NaN}""")
        myjson = json(req, rank, allownan = true)
        @test isnan(myjson.power)

        req = Request("GET","/", [],"""{"title": "viscount", "power": 9000.1}""")
        myjson = json(req, rank, allownan = false)
        @test myjson.power == 9000.1

    end


    @testset "regular Request json() tests" begin 

        req = Request("GET", "/json", [], "{\"message\":[null,1.0]}")
        @test isnothing(json(req)["message"][1])
        @test json(req)["message"][2] == 1

        req = Request("GET", "/json", [], """{"message":["hello",1.0]}""")
        @test json(req)["message"][1] == "hello"
        @test json(req)["message"][2] == 1

        req = Request("GET", "/json", [], "{\"message\":[3.4,4.0]}")
        @test json(req)["message"][1] == 3.4
        @test json(req)["message"][2] == 4

        req = Request("GET", "/json", [], "{\"message\":[null,1.0]}")
        @test isnothing(json(req)["message"][1])
    end


    @testset "json() Request with class_type" begin 

        req = Request("GET","/", [],"""{"title": "viscount", "power": NaN}""")
        myjson = json(req, rank, allownan = true)
        @test isnan(myjson.power)

        req = Request("GET","/", [],"""{"title": "viscount", "power": 9000.1}""")
        myjson = json(req, rank)
        @test myjson.power == 9000.1

        # test invalid json
        req = Request("GET","/", [],"""{}""")
        @test_throws TypeError json(req, rank) 

        # test extra key
        req = Request("GET","/", [],"""{"title": "viscount", "power": 9000.1, "extra": "hi"}""")
        myjson = json(req, rank)
        @test myjson.power == 9000.1

    end


    @testset "json() Response" begin 

        res = Response("""{"title": "viscount", "power": 9000.1}""")
        myjson = json(res)
        @test myjson["power"] == 9000.1

        res = Response("""{"title": "viscount", "power": 9000.1}""")
        myjson = json(res, rank)
        @test myjson.power == 9000.1

    end

    @testset "json() Response struct keyword tests" begin 

        req = Response("{\"message\":[NaN,1.0]}")
        @test isnan(json(req, allownan = true)["message"][1])
        @test !isnan(json(req, allownan = true)["message"][2])

        req = Response("{\"message\":[Inf,1.0]}")
        @test isinf(json(req, allownan = true)["message"][1])

        req = Response("{\"message\":[null,1.0]}")
        @test isnothing(json(req, allownan = false)["message"][1])

    end


    @testset "json() Response stuct keyword with class_type" begin 

        req = Response("""{"title": "viscount", "power": NaN}""")
        myjson = json(req, rank, allownan = true)
        @test isnan(myjson.power)

        req = Response("""{"title": "viscount", "power": 9000.1}""")
        myjson = json(req, rank, allownan = false)
        @test myjson.power == 9000.1

    end


    @testset "regular json() Response tests" begin 

        req = Response("{\"message\":[null,1.0]}")
        @test isnothing(json(req)["message"][1])
        @test json(req)["message"][2] == 1

        req = Response("""{"message":["hello",1.0]}""")
        @test json(req)["message"][1] == "hello"
        @test json(req)["message"][2] == 1

        req = Response("{\"message\":[3.4,4.0]}")
        @test json(req)["message"][1] == 3.4
        @test json(req)["message"][2] == 4

        req = Response("{\"message\":[null,1.0]}")
        @test isnothing(json(req)["message"][1])
    end


    @testset "json() Response with class_type" begin 

        req = Response("""{"title": "viscount", "power": NaN}""")
        myjson = json(req, rank; allownan=true)
        @test isnan(myjson.power)

        req = Response("""{"title": "viscount", "power": 9000.1}""")
        myjson = json(req, rank)
        @test myjson.power == 9000.1

        # test invalid json
        req = Response("""{}""")
        @test_throws TypeError json(req, rank) 

        # test extra key
        req = Response("""{"title": "viscount", "power": 9000.1, "extra": "hi"}""")
        myjson = json(req, rank)
        @test myjson.power == 9000.1

    end


    @testset "payload merges JSON, Form, and Query params" begin
        # Test Query only
        req = Request("GET", "/?a=1&b=2")
        data = payload(req)
        @test data["a"] == "1"
        @test data["b"] == "2"

        # Test Form only
        req = Request("POST", "/", [], "a=1&b=2")
        data = payload(req)
        @test data["a"] == "1"
        @test data["b"] == "2"

        # Test JSON only
        req = Request("POST", "/", [], """{"a": 1, "b": 2}""")
        data = payload(req)
        @test data["a"] == 1
        @test data["b"] == 2

        # Test Precedence (JSON > Form > Query)
        # Using HTTP Request directly to combine query and body
        req = Request("POST", "/?a=query_a&b=query_b&c=query_c", ["Content-Type" => "application/json"], """{"a": "json_a"}""")
        # We need to force `formdata` to parse something for the test by simulating a multipart or x-www-form-urlencoded,
        # but JSON parser won't parse it if Content-Type isn't json. 
        # So we'll test Query + JSON first.
        data = payload(req)
        @test data["a"] == "json_a" # JSON wins
        @test data["b"] == "query_b" # Fallback to Query
        @test data["c"] == "query_c"

        # Test Query + Form Data
        req_form = Request("POST", "/?a=query_a&b=query_b", ["Content-Type" => "application/x-www-form-urlencoded"], "a=form_a&c=form_c")
        data_form = payload(req_form)
        @test data_form["a"] == "form_a" # Form wins over Query
        @test data_form["b"] == "query_b" # Fallback to Query
        @test data_form["c"] == "form_c" # Only in Form
    end

end

# ─── Helper to build raw multipart/form-data bytes for testing ────────

"""Build a raw multipart/form-data body and Content-Type header for testing."""
function build_multipart(; boundary::String="----TestBoundary7MA4YWxkTrZu0gW", parts::Vector)
    io = IOBuffer()
    for part in parts
        write(io, "--$boundary\r\n")
        if haskey(part, :filename)
            write(io, "Content-Disposition: form-data; name=\"$(part[:name])\"; filename=\"$(part[:filename])\"\r\n")
            ct = get(part, :content_type, "application/octet-stream")
            write(io, "Content-Type: $ct\r\n")
        else
            write(io, "Content-Disposition: form-data; name=\"$(part[:name])\"\r\n")
        end
        write(io, "\r\n")
        write(io, part[:data])
        write(io, "\r\n")
    end
    write(io, "--$boundary--\r\n")
    body = take!(io)
    content_type = "multipart/form-data; boundary=$boundary"
    return body, content_type
end

@testset "multipart() - single file upload" begin
    body, ct = build_multipart(parts=[
        Dict(:name => "document", :filename => "report.xlsx", :content_type => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", :data => "fake xlsx content")
    ])
    req = Request("POST", "/upload", ["Content-Type" => ct], body)
    result = multipart(req)

    @test haskey(result, "document")
    f = result["document"]
    @test f isa FormFile
    @test f.name == "document"
    @test f.filename == "report.xlsx"
    @test f.content_type == "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    @test String(f.data) == "fake xlsx content"
end

@testset "multipart() - multiple files under different field names" begin
    body, ct = build_multipart(parts=[
        Dict(:name => "file1", :filename => "data.dbf", :content_type => "application/octet-stream", :data => "dbf bytes"),
        Dict(:name => "file2", :filename => "sheet.xlsx", :content_type => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", :data => "xlsx bytes")
    ])
    req = Request("POST", "/upload", ["Content-Type" => ct], body)
    result = multipart(req)

    @test length(result) == 2
    @test result["file1"] isa FormFile
    @test result["file2"] isa FormFile
    @test result["file1"].filename == "data.dbf"
    @test result["file2"].filename == "sheet.xlsx"
    @test String(result["file1"].data) == "dbf bytes"
    @test String(result["file2"].data) == "xlsx bytes"
end

@testset "multipart() - multiple files under same field name" begin
    body, ct = build_multipart(parts=[
        Dict(:name => "attachments", :filename => "file1.dbf", :data => "content1"),
        Dict(:name => "attachments", :filename => "file2.dbf", :data => "content2"),
        Dict(:name => "attachments", :filename => "file3.xlsx", :data => "content3")
    ])
    req = Request("POST", "/upload", ["Content-Type" => ct], body)
    result = multipart(req)

    @test haskey(result, "attachments")
    files = result["attachments"]
    @test files isa Vector
    @test length(files) == 3
    @test files[1].filename == "file1.dbf"
    @test files[2].filename == "file2.dbf"
    @test files[3].filename == "file3.xlsx"
end

@testset "multipart() - mixed files and text fields" begin
    body, ct = build_multipart(parts=[
        Dict(:name => "description", :data => "My upload"),
        Dict(:name => "file", :filename => "data.csv", :content_type => "text/csv", :data => "a,b,c\n1,2,3")
    ])
    req = Request("POST", "/upload", ["Content-Type" => ct], body)
    result = multipart(req)

    @test result["description"] isa String
    @test result["description"] == "My upload"
    @test result["file"] isa FormFile
    @test result["file"].filename == "data.csv"
end

@testset "multipart() - non-multipart request returns empty dict" begin
    req = Request("POST", "/upload", ["Content-Type" => "application/json"], """{"key": "value"}""")
    result = multipart(req)
    @test isempty(result)
end

@testset "multipart() - empty body returns empty dict" begin
    req = Request("POST", "/upload", ["Content-Type" => "multipart/form-data; boundary=xyz"], UInt8[])
    result = multipart(req)
    @test isempty(result)
end

end
