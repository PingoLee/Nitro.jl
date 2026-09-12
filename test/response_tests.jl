@testitem "Response builders" tags=[:core] setup=[NitroCommon] begin
cd(@__DIR__)
using Test
using HTTP

using Nitro

# `Res` is the ONE response-building namespace (#28). The bare names `text`, `json` and
# `binary` belong to the request parsers in `src/utilities/bodyparsers.jl` and are used
# here only to read a response body back.

@testset "Content-type builders" begin

    @testset "Res.html" begin
        response = Res.html("<h1>Hello, World!</h1>")
        @test response.status == 200
        @test text(response) == "<h1>Hello, World!</h1>"
        @test Dict(response.headers)["Content-Type"] == "text/html; charset=utf-8"
    end

    @testset "Res.send — string body defaults to text/plain" begin
        response = Res.send("Hello, World!")
        @test response.status == 200
        @test text(response) == "Hello, World!"
        @test Dict(response.headers)["Content-Type"] == "text/plain; charset=utf-8"
    end

    @testset "Res.send — content_type covers what js/css/xml used to" begin
        for (body, ctype) in (
            ("body { color: red; }", "text/css; charset=utf-8"),
            ("console.log(1)",       "application/javascript; charset=utf-8"),
            ("<root/>",              "application/xml; charset=utf-8"),
        )
            response = Res.send(body; content_type = ctype)
            @test response.status == 200
            @test text(response) == body
            @test Dict(response.headers)["Content-Type"] == ctype
        end
    end

    @testset "Res.send — byte body defaults to octet-stream" begin
        bytes = UInt8[72, 101, 108, 108, 111]   # "Hello"
        response = Res.send(bytes)
        @test response.status == 200
        @test binary(response) == bytes
        @test Dict(response.headers)["Content-Type"] == "application/octet-stream"

        typed = Res.send(bytes; content_type = "image/png")
        @test Dict(typed.headers)["Content-Type"] == "image/png"
    end

    @testset "Res.json — serializes" begin
        response = Res.json(Dict("message" => "Hello, World!"))
        @test response.status == 200
        @test text(response) == "{\"message\":\"Hello, World!\"}"
        @test Dict(response.headers)["Content-Type"] == "application/json; charset=utf-8"
    end

    @testset "Res.json — pre-serialized bytes pass through verbatim" begin
        # Routing these through `JSON.json` would re-encode them as an array of integers.
        raw = Vector{UInt8}("{\"message\":\"Hello, World!\"}")
        response = Res.json(raw)
        @test response.status == 200
        @test text(response) == "{\"message\":\"Hello, World!\"}"
        @test Dict(response.headers)["Content-Type"] == "application/json; charset=utf-8"
    end

    @testset "Res.status" begin
        response = Res.status(204)
        @test response.status == 204
        @test text(response) == ""
    end

    @testset "Res.redirect" begin
        # 302 is the default. The deleted top-level `redirect` defaulted to 307 (#28).
        response = Res.redirect("/login")
        @test response.status == 302
        @test Dict(response.headers)["Location"] == "/login"

        preserved = Res.redirect("/login"; status = 307)
        @test preserved.status == 307
        @test Dict(preserved.headers)["Location"] == "/login"
    end
end

@testset "Caller headers are applied last and override defaults" begin
    # `Res` builds the defaults first and runs `apply_headers!` last, so a caller-supplied
    # header wins. Contract test, not a regression test: `Res.send` already behaved this way
    # before #28. What is new is `Res.html`, which replaces a `render.jl` builder that did the
    # OPPOSITE -- headers to the constructor, then clobbered by `setheader`.
    response = Res.send("x"; headers = ["Content-Type" => "text/markdown", "X-Custom" => "1"])
    @test Dict(response.headers)["Content-Type"] == "text/markdown"
    @test Dict(response.headers)["X-Custom"] == "1"

    page = Res.html("<p>x</p>"; headers = ["Content-Type" => "application/xhtml+xml"])
    @test Dict(page.headers)["Content-Type"] == "application/xhtml+xml"
end

@testset "Repeated calls do not duplicate headers" begin
    response1 = Res.send("body { background-color: #f0f0f0; }"; content_type = "text/css")
    response2 = Res.send("body { background-color: #f0f0f0; }"; content_type = "text/css")
    @test Dict(response1.headers)["Content-Type"] == "text/css"
    @test Dict(response2.headers)["Content-Type"] == "text/css"
    # One header: Content-Type. `Res` does not set Content-Length -- HTTP.jl derives it from
    # `response.content_length` when it serializes (see the framing assertion below).
    @test length(response1.headers) == length(response2.headers) == 1

    response1 = Res.send(UInt8[72, 101, 108, 108, 111])
    response2 = Res.send(UInt8[72, 101, 108, 108, 111])
    @test Dict(response1.headers)["Content-Type"] == "application/octet-stream"
    @test length(response1.headers) == length(response2.headers) == 1
end

@testset "Res.file — Content-Disposition is opt-in" begin
    # A plain `Res.file(path)` serves INLINE. Static mounts (`staticfiles`, `spafiles`,
    # `dynamicfiles`) all route through here, so an `attachment` default would turn an SPA's
    # index.html into a forced download (#28).
    response = Res.file("content/index.html")
    @test response.status == 200
    @test Dict(response.headers)["Content-Type"] == "text/html; charset=utf-8"
    @test !haskey(Dict(response.headers), "Content-Disposition")

    # The opt-in cases below produced identical headers before #28 too -- contract tests, not
    # regression tests. The discriminating assertion is the `!haskey` above: the old default
    # emitted `attachment` unasked.
    attached = Res.file("content/index.html"; disposition = "attachment")
    @test Dict(attached.headers)["Content-Disposition"] == "attachment; filename=\"index.html\""

    inlined = Res.file("content/index.html"; disposition = "inline")
    @test Dict(inlined.headers)["Content-Disposition"] == "inline; filename=\"index.html\""

    # An empty string means the same as `nothing`; emitting it would build a malformed
    # `Content-Disposition: ; filename="..."`.
    @test !haskey(Dict(Res.file("content/index.html"; disposition = "").headers), "Content-Disposition")

    # `filename` alone still emits one -- otherwise naming the download would silently do nothing.
    named = Res.file("content/index.html"; filename = "report.html")
    @test Dict(named.headers)["Content-Disposition"] == "attachment; filename=\"report.html\""
end

@testset "Repeated calls do not duplicate headers for Res.file" begin
    response1 = Res.file("content/index.html")
    response2 = Res.file("content/index.html")

    @test Dict(response1.headers)["Content-Type"] == "text/html; charset=utf-8"
    @test Dict(response2.headers)["Content-Type"] == "text/html; charset=utf-8"

    # Content-Type + Content-Length, and no Content-Disposition by default.
    @test length(response1.headers) == length(response2.headers) == 2
end

@testset "Res.file Content-Length matches the body it sends" begin
    # Content-Length must be measured from the bytes actually written, never from a second stat of
    # the path. A `dynamicfiles` mount re-reads per request, so a file changing between the read and
    # the measurement used to leave the header disagreeing with its own body (#92).
    #
    # Scope note: HTTP.jl recomputes Content-Length from the body when it serializes, so the stale
    # value never reached a client. What these assertions pin is the response object as middleware,
    # `internalrequest` and the header-copying helpers see it -- which is where the inconsistency
    # was actually observable.
    #
    # NOTE: `length(response.body)`, not `sizeof`. The body may be an `HTTP.BytesBody`, whose
    # `sizeof` is the struct's own size (24 bytes) rather than the payload length.
    for path in ("content/test.txt", "content/index.html", "content/file.min.js")
        response = Res.file(path)
        @test Dict(response.headers)["Content-Length"] == string(length(response.body))
        # `content_length` is HTTP.jl's own framing length, computed independently of the header
        # we set -- so this pins that our explicit header agrees with how the response is framed.
        @test Dict(response.headers)["Content-Length"] == string(response.content_length)
    end

    # file.min.js is zero bytes -- pin that the empty case still reports a header.
    @test Dict(Res.file("content/file.min.js").headers)["Content-Length"] == "0"

    mktempdir() do dir
        # Multi-byte UTF-8: Content-Length is a *byte* count, not a character count.
        utf8_path = joinpath(dir, "utf8.txt")
        body = "héllo — wörld ✓"
        write(utf8_path, body)
        response = Res.file(utf8_path)
        @test Dict(response.headers)["Content-Length"] == string(sizeof(body))
        @test Dict(response.headers)["Content-Length"] != string(length(body))

        # The loadfile branch decides the body, so it must also decide the length. This branch was
        # already correct before #92, so these are *contract* tests, not regression tests -- they
        # cannot fail on the old code. What they pin is the future: an unconditional `filesize`
        # here would put a length on the response that its body does not have.
        grown = Res.file(utf8_path; loadfile = p -> read(p, String) * "!!")
        @test Dict(grown.headers)["Content-Length"] == string(length(grown.body))
        @test Dict(grown.headers)["Content-Length"] != string(filesize(utf8_path))

        # ... and smaller than the file on disk, the other direction of the same inconsistency.
        shrunk = Res.file(utf8_path; loadfile = _ -> "hi")
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
        response = Res.file("/proc/version")
        @test length(response.body) > 0
        @test Dict(response.headers)["Content-Length"] == string(length(response.body))
        @test Dict(response.headers)["Content-Length"] != string(filesize("/proc/version"))
    else
        @info "Res.file: no zero-stat/non-empty-read file on this host, so the #92 discriminator is skipped; the Content-Length invariants above still ran" islinux = Sys.islinux()
    end
end

end

@testitem "Response builders on the wire" tags=[:core, :network] setup=[NitroCommon] begin
using Test
using HTTP
import JSON

using Nitro
import Nitro: ServerContext

# `Res.html`/`Res.send`/`Res.json` deliberately set NO `Content-Length` header (#28): HTTP.jl
# computes `content_length` from the body and writes the header itself at serialization time, so a
# builder-set one would only be overwritten with the same value. That reasoning is about the WRITE
# path -- asserting it on the response object in-process proves nothing, so it has to go over a
# socket. Bodies are deliberately multi-byte: a character count would be wrong here, a byte count right.
#
# Isolation: a fresh `ServerContext` rather than the global `CONTEXT[]`, so this cannot perturb the
# shared router the rest of the suite depends on. (`instance()` would isolate too, but it re-evals a
# whole second copy of the Nitro module into an anonymous module that is never freed.)

const BODY_HTML = "<p>héllo — wörld</p>"
const BODY_TEXT = "héllo — wörld ✓"
# One key on purpose: with two, `JSON.json` ordering would make the expected string flaky.
const BODY_JSON = Dict("gruß" => "wörld")

ctx = ServerContext()
Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
    path("/page",  (req::HTTP.Request) -> Res.html(BODY_HTML)),
    path("/plain", (req::HTTP.Request) -> Res.send(BODY_TEXT)),
    path("/sheet", (req::HTTP.Request) -> Res.send(BODY_TEXT; content_type = "text/css; charset=utf-8")),
    path("/data",  (req::HTTP.Request) -> Res.json(BODY_JSON)),
])

port = get_free_port()
Nitro.Core.serve(ctx; host = HOST, port = port, async = true,
                 show_banner = false, show_errors = false, access_log = nothing)
@test timedwait(() -> Base.isopen(ctx.service), 10.0) === :ok

try
    @testset "Content-Length reaches the client even though no builder sets it" begin
        for (route, expected, ctype) in (
            ("/page",  BODY_HTML,            "text/html; charset=utf-8"),
            ("/plain", BODY_TEXT,            "text/plain; charset=utf-8"),
            ("/sheet", BODY_TEXT,            "text/css; charset=utf-8"),
            ("/data",  JSON.json(BODY_JSON), "application/json; charset=utf-8"),
        )
            r = HTTP.get("http://$HOST:$port$route")
            @test r.status == 200
            @test HTTP.header(r, "Content-Type") == ctype
            # Present on the wire, and a BYTE count of the body actually sent.
            @test HTTP.header(r, "Content-Length") == string(sizeof(expected))
            @test String(r.body) == expected
        end
    end
finally
    Nitro.Core.terminate(ctx)
end

end
