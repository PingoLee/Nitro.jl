@testitem "Render" tags=[:core] setup=[NitroCommon] begin
cd(@__DIR__)
using Test
using HTTP

using Nitro

@testset "Render Module Tests" begin

    @testset "html function" begin
        response = html("<h1>Hello, World!</h1>")
        @test response.status == 200
        @test text(response) == "<h1>Hello, World!</h1>"
        @test Dict(response.headers)["Content-Type"] == "text/html; charset=utf-8"
    end

    @testset "text function" begin
        response = text("Hello, World!")
        @test response.status == 200
        @test text(response) == "Hello, World!"
        @test Dict(response.headers)["Content-Type"] == "text/plain; charset=utf-8"
    end

    @testset "json function" begin
        response = json(Dict("message" => "Hello, World!"))
        @test response.status == 200
        @test text(response) == "{\"message\":\"Hello, World!\"}"
        @test Dict(response.headers)["Content-Type"] == "application/json; charset=utf-8"
    end

    @testset "json binary function" begin
        response = json(Vector{UInt8}("{\"message\":\"Hello, World!\"}"))
        @test response.status == 200
        @test text(response) == "{\"message\":\"Hello, World!\"}"
        @test Dict(response.headers)["Content-Type"] == "application/json; charset=utf-8"
    end
 
    @testset "xml function" begin
        response = xml("<message>Hello, World!</message>")
        @test response.status == 200
        @test text(response) == "<message>Hello, World!</message>"
        @test Dict(response.headers)["Content-Type"] == "application/xml; charset=utf-8"
    end

    @testset "js function" begin
        response = js("console.log('Hello, World!');")
        @test response.status == 200
        @test text(response) == "console.log('Hello, World!');"
        @test Dict(response.headers)["Content-Type"] == "application/javascript; charset=utf-8"
    end

    @testset "css function" begin
        response = css("body { background-color: #f0f0f0; }")
        @test response.status == 200
        @test text(response) == "body { background-color: #f0f0f0; }"
        @test Dict(response.headers)["Content-Type"] == "text/css; charset=utf-8"
    end

    @testset "binary function" begin
        response = binary(UInt8[72, 101, 108, 108, 111])  # "Hello" in ASCII
        @test response.status == 200
        @test response.body == UInt8[72, 101, 108, 108, 111]
        @test Dict(response.headers)["Content-Type"] == "application/octet-stream"
    end
end

@testset "Repeated calls do not duplicate headers" begin
    response1 = css("body { background-color: #f0f0f0; }")
    response2 = css("body { background-color: #f0f0f0; }")
    @test Dict(response1.headers)["Content-Type"] == "text/css; charset=utf-8"
    @test Dict(response2.headers)["Content-Type"] == "text/css; charset=utf-8"
    @test length(response1.headers) == length(response2.headers)

    response1 = binary(UInt8[72, 101, 108, 108, 111])  # "Hello" in ASCII
    response2 = binary(UInt8[72, 101, 108, 108, 111])  # "Hello" in ASCII
    @test Dict(response1.headers)["Content-Type"] == "application/octet-stream"
    @test Dict(response2.headers)["Content-Type"] == "application/octet-stream"
    @test length(response1.headers) == length(response2.headers) == 2
end

@testset "Repeated calls do not duplicate headers for file renderer" begin
    response1 = file("content/index.html")
    response2 = file("content/index.html")

    @test findfirst(x -> x == ("Content-Type" => "text/html; charset=utf-8"), response1.headers) !== nothing
    @test findfirst(x -> x == ("Content-Type" => "text/html; charset=utf-8"), response2.headers) !== nothing

    count1 = length(response1.headers)
    count2 = length(response2.headers)

    @test count1 == count2 == 2
end

@testset "file() Content-Length matches the body it sends" begin
    # Content-Length must be measured from the bytes actually written, never from a second stat of
    # the path. A `dynamicfiles` mount re-reads per request, so a file changing between the read and
    # the measurement used to leave the header disagreeing with its own body (#92).
    #
    # Scope note: HTTP.jl recomputes Content-Length from the body when it serializes, so the stale
    # value never reached a client. What these assertions pin is the response object as middleware,
    # `internalrequest` and the header-copying helpers see it -- which is where the inconsistency
    # was actually observable.
    #
    # NOTE: `length(response.body)`, not `sizeof`. The body is an `HTTP.BytesBody`, so `sizeof`
    # returns the struct's own size (24 bytes) rather than the payload length.
    for path in ("content/test.txt", "content/index.html", "content/file.min.js")
        response = file(path)
        @test Dict(response.headers)["Content-Length"] == string(length(response.body))
        # `content_length` is HTTP.jl's own framing length, computed independently of the header
        # we set -- so this pins that our explicit header agrees with how the response is framed.
        @test Dict(response.headers)["Content-Length"] == string(response.content_length)
    end

    # file.min.js is zero bytes -- pin that the empty case still reports a header.
    @test Dict(file("content/file.min.js").headers)["Content-Length"] == "0"

    mktempdir() do dir
        # Multi-byte UTF-8: Content-Length is a *byte* count, not a character count.
        utf8_path = joinpath(dir, "utf8.txt")
        body = "héllo — wörld ✓"
        write(utf8_path, body)
        response = file(utf8_path)
        @test Dict(response.headers)["Content-Length"] == string(sizeof(body))
        @test Dict(response.headers)["Content-Length"] != string(length(body))

        # The loadfile branch decides the body, so it must also decide the length. This branch was
        # already correct before #92, so these are *contract* tests, not regression tests -- they
        # cannot fail on the old code. What they pin is the future: an unconditional `filesize`
        # here would put a length on the response that its body does not have.
        grown = file(utf8_path; loadfile = p -> read(p, String) * "!!")
        @test Dict(grown.headers)["Content-Length"] == string(length(grown.body))
        @test Dict(grown.headers)["Content-Length"] != string(filesize(utf8_path))

        # ... and smaller than the file on disk, the other direction of the same inconsistency.
        shrunk = file(utf8_path; loadfile = _ -> "hi")
        @test Dict(shrunk.headers)["Content-Length"] == string(length(shrunk.body))
        @test Dict(shrunk.headers)["Content-Length"] != string(filesize(utf8_path))
    end

    # The assertions above are contract tests, not regression tests: for any stable regular file
    # `read(path, String)` and `filesize(path)` agree by construction, and the `loadfile` branch was
    # already correct before #92. procfs is the one input where the two deterministically disagree
    # -- `stat` reports 0 bytes while the read returns content -- so it is the only place the old
    # code can be caught red-handed. Linux-only; the other CI legs run the invariants alone, which
    # is stated here rather than hidden so the gap cannot silently widen.
    if Sys.islinux() && isfile("/proc/version") && filesize("/proc/version") == 0
        response = file("/proc/version")
        @test length(response.body) > 0
        @test Dict(response.headers)["Content-Length"] == string(length(response.body))
        @test Dict(response.headers)["Content-Length"] != string(filesize("/proc/version"))
    else
        @info "file(): no zero-stat/non-empty-read file on this host, so the #92 discriminator is skipped; the Content-Length invariants above still ran" islinux = Sys.islinux()
    end
end

end
