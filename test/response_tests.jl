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

@testset "Res.file — an untrusted filename cannot inject parameters (#328)" begin
    disposition(name) = Dict(Res.file("content/index.html"; filename = name).headers)["Content-Disposition"]

    # The audit's payload: unescaped, the `"` closed the quote and the name appended a
    # `filename*`, which browsers prefer. Escaped, it is all one quoted-string.
    evil = "report.txt\"; filename*=UTF-8''evil.html; x=\""
    @test disposition(evil) ==
        "attachment; filename=\"report.txt\\\"; filename*=UTF-8''evil.html; x=\\\"\""
    # Nothing outside the quoted-string: strip the one quoted value and no parameter is left.
    @test replace(disposition(evil), r"\"(?:[^\"\\]|\\.)*\"" => "Q") == "attachment; filename=Q"

    @test disposition("a\\b.txt") == "attachment; filename=\"a\\\\b.txt\""
    # Control characters are dropped, not passed to the header writer to neutralize.
    @test disposition("a\r\nb\tc\x7f.txt") == "attachment; filename=\"abc.txt\""

    # Non-ASCII: an ASCII fallback, plus the real name as RFC 5987 `filename*`.
    uni = disposition("relatório 2026.pdf")
    @test uni == "attachment; filename=\"relat?rio 2026.pdf\"; filename*=UTF-8''relat%C3%B3rio%202026.pdf"
    @test HTTP.unescapeuri(split(uni, "UTF-8''")[2]) == "relatório 2026.pdf"
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
        # `sizeof`, not `length`, and that distinction became OBSERVABLE at HTTP 2.7 (#225).
        # HTTP.jl #1364 stores a String body as-is instead of wrapping it in a byte-backed
        # `BytesBody`, so `resp.body` is now a `String` here and `length` counts CHARACTERS.
        # These assertions used `length` and passed only because the old wrapping made the two
        # agree; on a multibyte body they now differ (15 bytes vs 13 characters). `Content-Length`
        # is a byte count, so `Res.file` was always right to use `sizeof` -- see its own comment --
        # and the test was measuring the wrong thing.
        grown = Res.file(utf8_path; loadfile = p -> read(p, String) * "!!")
        @test Dict(grown.headers)["Content-Length"] == string(sizeof(grown.body))
        @test Dict(grown.headers)["Content-Length"] != string(filesize(utf8_path))
        # Pin the divergence itself, so a future bump that re-wraps String bodies is visible here
        # rather than silently making `length` correct again.
        @test grown.body isa AbstractString
        @test sizeof(grown.body) != length(grown.body)

        # ... and smaller than the file on disk, the other direction of the same inconsistency.
        shrunk = Res.file(utf8_path; loadfile = _ -> "hi")
        @test Dict(shrunk.headers)["Content-Length"] == string(sizeof(shrunk.body))
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

@testset "Res.file(req, path) — conditional GET and ranges (#40)" begin
    dir  = mktempdir()
    path = joinpath(dir, "app.js")
    write(path, "console.log('x');")
    body = "console.log('x');"
    get(target = "/app.js"; hdrs = Pair{String,String}[]) = HTTP.Request("GET", target, hdrs)
    bodystr(r) = (b = r.body; b isa AbstractString ? String(b) :
                  b isa AbstractVector{UInt8} ? String(copy(b)) :
                  b isa HTTP.BytesBody ? String(copy(b.data)) : "")

    @testset "the request-less builder is unchanged" begin
        # `Res.file(path)` is a pure builder: it cannot see `If-None-Match`, so it must not start
        # claiming validators it cannot honour. All of #40 lives on the `req` method.
        plain = Res.file(path)
        @test HTTP.header(plain, "ETag", "") == ""
        @test HTTP.header(plain, "Last-Modified", "") == ""
        @test HTTP.header(plain, "Accept-Ranges", "") == ""
        @test plain.status == 200
    end

    @testset "validators are emitted and honoured" begin
        r = Res.file(get(), path)
        etag, lastmod = HTTP.header(r, "ETag"), HTTP.header(r, "Last-Modified")
        @test r.status == 200
        @test bodystr(r) == body
        @test startswith(etag, "W/\"")            # weak by default -- see `file_validators`
        @test !isempty(lastmod)
        @test HTTP.header(r, "Accept-Ranges") == "bytes"
        @test startswith(HTTP.header(r, "Content-Type"), "text/javascript")

        fresh = Res.file(get(; hdrs = ["If-None-Match" => etag]), path)
        @test fresh.status == 304
        @test isempty(bodystr(fresh))
        # A 304 must not carry entity headers describing a body it is not sending.
        @test HTTP.header(fresh, "Content-Length", "") == ""
        @test HTTP.header(fresh, "Content-Type", "") == ""

        @test Res.file(get(; hdrs = ["If-Modified-Since" => lastmod]), path).status == 304
        # A validator that does NOT match must still send the body -- otherwise "always 304"
        # would pass every assertion above.
        stale = Res.file(get(; hdrs = ["If-None-Match" => "\"nope\""]), path)
        @test stale.status == 200
        @test bodystr(stale) == body
    end

    @testset "byte ranges" begin
        part = Res.file(get(; hdrs = ["Range" => "bytes=0-6"]), path)
        @test part.status == 206
        @test bodystr(part) == "console"
        @test HTTP.header(part, "Content-Range") == "bytes 0-6/$(sizeof(body))"

        @test Res.file(get(; hdrs = ["Range" => "bytes=9999-"]), path).status == 416
        # `allow_ranges=false` opts out entirely -- the whole body, and no advertisement.
        whole = Res.file(get(; hdrs = ["Range" => "bytes=0-6"]), path; allow_ranges = false)
        @test whole.status == 200
        @test bodystr(whole) == body
        @test HTTP.header(whole, "Accept-Ranges", "") == ""
    end

    @testset "etag strategies" begin
        weak, _   = Res.file_validators(path)
        strong, _ = Res.file_validators(path; etag = :strong)
        none, _   = Res.file_validators(path; etag = nothing)
        fixed, _  = Res.file_validators(path; etag = "\"pinned\"")
        @test startswith(weak, "W/\"")
        @test startswith(strong, "\"") && !startswith(strong, "W/")
        @test length(strong) == 66                 # 64 hex chars of sha256 plus two quotes
        @test none === nothing
        @test fixed == "\"pinned\""
        @test_throws ArgumentError Res.file_validators(path; etag = :nonsense)

        # A strong tag follows the BODY, not the file, when `loadfile` decides the body.
        a = Res.file(get(), path; etag = :strong)
        b = Res.file(get(), path; etag = :strong, loadfile = p -> read(p) )
        c = Res.file(get(), path; etag = :strong, loadfile = _ -> Vector{UInt8}("different"))
        @test HTTP.header(a, "ETag") == HTTP.header(b, "ETag")
        @test HTTP.header(a, "ETag") != HTTP.header(c, "ETag")
    end

    @testset "Cache-Control is opt-in, Content-Disposition still is too" begin
        @test HTTP.header(Res.file(get(), path), "Cache-Control", "") == ""
        cc = Res.file(get(), path; cache_control = "public, max-age=60")
        @test HTTP.header(cc, "Cache-Control") == "public, max-age=60"

        @test HTTP.header(Res.file(get(), path), "Content-Disposition", "") == ""
        dl = Res.file(get(), path; disposition = "attachment")
        @test HTTP.header(dl, "Content-Disposition") == "attachment; filename=\"app.js\""
        # The request-aware builder escapes an untrusted name the same way (#328).
        evil = Res.file(get(), path; filename = "x\"; filename*=UTF-8''evil.html; y=\"")
        @test HTTP.header(evil, "Content-Disposition") ==
            "attachment; filename=\"x\\\"; filename*=UTF-8''evil.html; y=\\\"\""
        # Caller headers are applied LAST and override what the builder computed.
        over = Res.file(get(), path; headers = ["Content-Type" => "text/plain"])
        @test HTTP.header(over, "Content-Type") == "text/plain"
    end
end

@testset "Res.sse — the SSE response contract, in process (#160)" begin
    # Socket-level behavior (chunked framing, per-event flush, the fast-producer regression, the
    # middleware chain) lives in test/sse_tests.jl and HAS to: `internalrequest` never reaches
    # `_write_response_body!` at all (src/core/pipeline.jl), so nothing here proves a byte was
    # written. What this testset pins is the part that is decided in the BUILDER.

    @testset "headers, framing signal, and body type" begin
        resp = Res.sse()
        try
            @test resp.status == 200
            @test resp.body isa HTTP.SSEStream
            @test HTTP.header(resp, "Content-Type") == "text/event-stream"
            @test HTTP.header(resp, "Cache-Control") == "no-cache"
            # Nitro's one addition over HTTP's SSE header set: without it nginx buffers the
            # stream and a working endpoint is indistinguishable from a hung one.
            @test HTTP.header(resp, "X-Accel-Buffering") == "no"
            # An unknown length is what makes HTTP choose chunked framing on the wire. Asserting
            # the ABSENCE of Content-Length matters: a stale one would make the response a
            # fixed-length write and truncate it.
            @test resp.content_length == -1
            @test !HTTP.hasheader(resp, "Content-Length")
        finally
            close(resp.body)
        end
    end

    @testset "caller headers are applied last, like every other builder" begin
        resp = Res.sse(; status = 201,
                       headers = ["Cache-Control" => "no-store", "X-Trace" => "abc"])
        try
            @test resp.status == 201
            @test HTTP.header(resp, "Cache-Control") == "no-store"
            @test HTTP.header(resp, "X-Trace") == "abc"
            @test HTTP.header(resp, "Content-Type") == "text/event-stream"
        finally
            close(resp.body)
        end
    end

    @testset "the producer form runs the producer and closes the stream" begin
        resp = Res.sse() do events
            write(events, SSEEvent("a"; event = "x"))
            write(events, SSEEvent("b"))
        end
        # The producer runs on its own task, so wait for it rather than assuming it has run.
        @test timedwait(() -> !isopen(resp.body), 10.0; pollint = 0.02) === :ok
        # Closing the stream is what ENDS the response -- the transport parks in `body_read!`
        # until it happens -- so `Res.sse` closing on the producer's behalf is the contract.
        @test HTTP.body_closed(resp.body)

        # The bytes are still readable after the close: buffered-and-closed is a legitimate state
        # and is exactly what the write path must not mistake for "empty".
        buffer = Vector{UInt8}(undef, 4096)
        n = HTTP.body_read!(resp.body, buffer)
        @test String(@view buffer[1:n]) == "event: x\ndata: a\n\ndata: b\n\n"
    end

    @testset "a throwing producer still closes the stream" begin
        # Otherwise the connection would be held open for the life of the process: the drain has
        # no other way to learn the producer is gone.
        resp = Res.sse() do events
            write(events, SSEEvent("partial"))
            error("boom -- this @error line is expected")
        end
        @test timedwait(() -> HTTP.body_closed(resp.body), 10.0; pollint = 0.02) === :ok
    end

    @testset "a producer fault is reported even when the producer closed its own stream (#160)" begin
        # THE case `!isopen(events)` alone got wrong. The docstring teaches
        # `try ... finally close(events) end`, so a genuine fault routinely arrives at the
        # `catch` with the stream already closed by the producer's own `finally`. Keying on the
        # state alone demoted that to `@debug` -- compiled out by default -- so the operator saw
        # nothing and the client saw a clean short stream.
        events = HTTP.SSEStream()
        @test_logs (:error, r"event producer failed") match_mode=:any begin
            Nitro.Res._run_sse_producer(events) do ev
                try
                    error("a genuine producer fault")
                finally
                    close(ev)
                end
            end
        end
        @test HTTP.body_closed(events)

        # A framing fault is an `ArgumentError`, not an `IOError`, so it stays at error level too
        # even though the `finally` has closed the stream by the time it is caught.
        small = HTTP.SSEStream(; max_len = 16)
        @test_logs (:error, r"event producer failed") match_mode=:any begin
            Nitro.Res._run_sse_producer(small) do ev
                try
                    write(ev, SSEEvent("x"^512))
                finally
                    close(ev)
                end
            end
        end
    end

    @testset "a fan-out producer's disconnect is still not an error (#160)" begin
        # A producer that spawns its writes gets the `IOError` wrapped:
        # `CompositeException` -> `TaskFailedException` -> `Base.IOError`. Classifying the wrapper
        # as a fault would log an error per departing client -- the noise the predicate exists to
        # suppress -- so the check unwraps a bounded number of levels.
        gone = HTTP.SSEStream()
        close(gone)
        @test_logs min_level = Base.CoreLogging.Error begin
            Nitro.Res._run_sse_producer(gone) do ev
                @sync for _ in 1:2
                    Threads.@spawn write(ev, SSEEvent("into the void"))
                end
            end
        end

        # ... while a wrapped ArgumentError is still a fault, not a disconnect.
        @test !Nitro.Res._is_closed_stream_error(ArgumentError("nope"))
        @test Nitro.Res._is_closed_stream_error(Base.IOError("closed", 0))
    end

    @testset "a disconnect is NOT reported as an error (#160)" begin
        # The other direction of the same predicate: writing into a stream the transport already
        # closed is how most SSE connections end, so it must not log at error level once per
        # departing client. `Base.IOError` + closed is the signature.
        gone = HTTP.SSEStream()
        close(gone)
        @test_logs min_level = Base.CoreLogging.Error begin
            Nitro.Res._run_sse_producer(ev -> write(ev, SSEEvent("into the void")), gone)
        end
    end

    @testset "max_len caps one serialized event" begin
        resp = Res.sse(; max_len = 32)
        try
            @test_throws ArgumentError write(resp.body, SSEEvent("x"^256))
        finally
            close(resp.body)
        end
        @test Nitro.Res.SSE_MAX_EVENT_BYTES == 16 * 1024 * 1024
    end
end


end

@testitem "Response builders on the wire" tags=[:core, :network] setup=[NitroCommon] begin
using Test
using HTTP
import JSON

using Nitro
import Nitro: App

# `Res.html`/`Res.send`/`Res.json` deliberately set NO `Content-Length` header (#28): HTTP.jl
# computes `content_length` from the body and writes the header itself at serialization time, so a
# builder-set one would only be overwritten with the same value. That reasoning is about the WRITE
# path -- asserting it on the response object in-process proves nothing, so it has to go over a
# socket. Bodies are deliberately multi-byte: a character count would be wrong here, a byte count right.
#
# A `HEAD` gets no such help from HTTP.jl -- its bodyless framing only ever removes headers -- so the
# write path adds the header itself, from the same `content_length` the `GET` path reads (#146).
#
# Isolation: a fresh `App` rather than the global `CONTEXT[]`, so this cannot perturb the
# shared router the rest of the suite depends on. (`instance()` used to be the other way to do
# this; #31 deleted it -- a fresh `App` is the supported form and costs no recompile.)

const BODY_HTML = "<p>héllo — wörld</p>"
const BODY_TEXT = "héllo — wörld ✓"
# One key on purpose: with two, `JSON.json` ordering would make the expected string flaky.
const BODY_JSON = Dict("gruß" => "wörld")

# Several 64 KiB write chunks, so the streaming loop in `_write_response_body!` actually
# iterates. Random bytes rather than a repeated pattern: a truncated or duplicated chunk would
# survive an equality check against a compressible fixture far too easily.
const STREAM_BYTES = rand(UInt8, 300_000)
const STREAM_PATH  = joinpath(mktempdir(), "big.bin")
write(STREAM_PATH, STREAM_BYTES)

# Returned by reference on every request, the way the auth middleware's `const` rejections are.
# The HEAD fix must build a new response rather than add its header to this one (nitro-core §4).
const SHARED_RESPONSE = HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8"], BODY_TEXT)
const SHARED_304      = HTTP.Response(304)

ctx = App()
Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
    path("/page",  (req::HTTP.Request) -> Res.html(BODY_HTML)),
    path("/plain", (req::HTTP.Request) -> Res.send(BODY_TEXT)),
    path("/sheet", (req::HTTP.Request) -> Res.send(BODY_TEXT; content_type = "text/css; charset=utf-8")),
    path("/data",  (req::HTTP.Request) -> Res.json(BODY_JSON)),
    path("/stream", (req::HTTP.Request) -> Res.file(req, STREAM_PATH; stream = true)),
    path("/buffered", (req::HTTP.Request) -> Res.file(req, STREAM_PATH)),
    # Registered for both methods, so each HEAD can be compared against its own GET.
    path("/h/page",   (req::HTTP.Request) -> Res.html(BODY_HTML);  methods = ["GET", "HEAD"]),
    path("/h/plain",  (req::HTTP.Request) -> Res.send(BODY_TEXT);  methods = ["GET", "HEAD"]),
    path("/h/data",   (req::HTTP.Request) -> Res.json(BODY_JSON);  methods = ["GET", "HEAD"]),
    path("/h/file",   (req::HTTP.Request) -> Res.file(req, STREAM_PATH); methods = ["GET", "HEAD"]),
    path("/h/empty",  (req::HTTP.Request) -> Res.status(200);      methods = ["GET", "HEAD"]),
    path("/h/shared", (req::HTTP.Request) -> SHARED_RESPONSE;      methods = ["GET", "HEAD"]),
    # The usual hand-written HEAD route: a GET with a body, and a HEAD-only handler with none.
    path("/h/split",  (req::HTTP.Request) -> Res.send(BODY_TEXT);  methods = ["GET"]),
    path("/h/split",  (req::HTTP.Request) -> Res.status(200);      methods = ["HEAD"]),
    path("/h/none",   (req::HTTP.Request) -> Res.status(204);      methods = ["HEAD"]),
    path("/h/304",    (req::HTTP.Request) -> SHARED_304;           methods = ["HEAD"]),
    # `/h/split` in the other order: the explicit HEAD first, then the GET (#277).
    path("/h/split2", (req::HTTP.Request) -> Res.status(200);      methods = ["HEAD"]),
    path("/h/split2", (req::HTTP.Request) -> Res.send(BODY_TEXT)),
    # GET-only, and reports the method its handler saw.
    path("/h/method", (req::HTTP.Request) -> HTTP.Response(200, ["X-Seen-Method" => req.method], BODY_TEXT)),
    # POST-only, so its HEAD is a 405 (#281).
    path("/h/empty-post", (req::HTTP.Request) -> Res.status(201); method = "POST"),
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

    @testset "HEAD carries the Content-Length its GET would (#146)" begin
        for (route, expected) in (
            ("/h/page",   sizeof(BODY_HTML)),
            ("/h/plain",  sizeof(BODY_TEXT)),
            ("/h/data",   sizeof(JSON.json(BODY_JSON))),
            ("/h/file",   length(STREAM_BYTES)),
            ("/h/shared", sizeof(BODY_TEXT)),
        )
            got  = HTTP.get("http://$HOST:$port$route")
            head = HTTP.request("HEAD", "http://$HOST:$port$route")
            @test head.status == got.status == 200
            @test isempty(head.body)
            @test HTTP.header(got,  "Content-Length") == string(expected)
            @test HTTP.header(head, "Content-Length") == string(expected)
        end

        # Built, not mutated: the shared response is exactly as it was declared, however many
        # HEADs it has answered.
        @test !HTTP.hasheader(SHARED_RESPONSE, "Content-Length")

        # An empty HEAD body cannot be trusted to describe the GET (RFC 9110 §8.6: a wrong
        # Content-Length is a MUST NOT, a missing one a MAY). `/h/split` is the case that matters:
        # its GET sends a body, and a `Content-Length: 0` on its HEAD would be a lie. `/h/empty`
        # is the price -- its GET really is empty, and its HEAD loses a header it was only
        # permitted to send.
        split_get  = HTTP.get("http://$HOST:$port/h/split")
        split_head = HTTP.request("HEAD", "http://$HOST:$port/h/split")
        @test HTTP.header(split_get, "Content-Length") == string(sizeof(BODY_TEXT))
        @test split_head.status == 200
        @test !HTTP.hasheader(split_head, "Content-Length")
        @test HTTP.header(HTTP.get("http://$HOST:$port/h/empty"), "Content-Length") == "0"
        @test !HTTP.hasheader(HTTP.request("HEAD", "http://$HOST:$port/h/empty"), "Content-Length")

        # No representation, so no length: a 204 must not send the header at all, and a 304's
        # empty body says nothing about the size of what it stands in for. (Regression guards
        # only: both bodies are empty, so the empty-body skip already covers them, and HTTP.jl
        # itself strips the header from a 204.)
        for route in ("/h/none", "/h/304")
            r = HTTP.request("HEAD", "http://$HOST:$port$route"; status_exception = false)
            @test r.status in (204, 304)
            @test !HTTP.hasheader(r, "Content-Length")
        end
    end

    @testset "a GET-only route answers HEAD from its GET handler (#277)" begin
        # Every route here is registered for GET alone. Before #277 each HEAD was a 405.
        for route in ("/page", "/plain", "/sheet", "/data", "/buffered", "/stream")
            got  = HTTP.get("http://$HOST:$port$route")
            head = HTTP.request("HEAD", "http://$HOST:$port$route"; status_exception = false)
            @test head.status == got.status == 200
            @test isempty(head.body)
            @test HTTP.header(head, "Content-Type") == HTTP.header(got, "Content-Type")
            @test HTTP.header(head, "Content-Length") == HTTP.header(got, "Content-Length")
            @test !isempty(HTTP.header(got, "Content-Length"))
        end

        # The GET handler runs on the HEAD request itself, so it can tell the two apart.
        @test HTTP.header(HTTP.get("http://$HOST:$port/h/method"), "X-Seen-Method") == "GET"
        @test HTTP.header(HTTP.request("HEAD", "http://$HOST:$port/h/method"), "X-Seen-Method") == "HEAD"

        # An explicit HEAD route wins in either registration order: its empty body means no
        # Content-Length, where the auto-HEAD would have sent the GET's.
        for route in ("/h/split", "/h/split2")
            head = HTTP.request("HEAD", "http://$HOST:$port$route")
            @test head.status == 200
            @test !HTTP.hasheader(head, "Content-Length")
            @test HTTP.header(HTTP.get("http://$HOST:$port$route"), "Content-Length") == string(sizeof(BODY_TEXT))
        end

        # Only HEAD is added: other methods on a GET-only route are still refused.
        @test HTTP.request("POST", "http://$HOST:$port/plain"; status_exception = false).status == 405
    end

    @testset "a 405 carries Allow over the socket (#281)" begin
        r = HTTP.request("DELETE", "http://$HOST:$port/plain"; status_exception = false)
        @test r.status == 405
        @test HTTP.header(r, "Allow") == "GET, HEAD"
        # A HEAD to a 405 gets the same header: the write path drops only the body.
        r = HTTP.request("HEAD", "http://$HOST:$port/h/empty-post"; status_exception = false)
        @test r.status == 405
        @test HTTP.header(r, "Allow") == "POST"
    end

    @testset "a streamed body reaches the client whole (#41)" begin
        # This is the ONLY coverage of `_write_response_body!(::HTTP.Stream, ::HTTP.AbstractBody)`,
        # and it has to be over a socket: in-process, `internalrequest` never reaches the write
        # path at all, so a chunking bug there is invisible to every other assertion in the suite.
        r = HTTP.get("http://$HOST:$port/stream")
        @test r.status == 200
        @test r.body == STREAM_BYTES
        @test HTTP.header(r, "Content-Length") == string(length(STREAM_BYTES))
        @test HTTP.header(r, "Accept-Ranges") == "bytes"

        # Byte-identical to the buffered path -- the transport must not be observable in the body.
        @test HTTP.get("http://$HOST:$port/buffered").body == STREAM_BYTES

        # A streamed body is a CURSOR and is single-use, so each request must open its own. Three
        # in a row catches a body accidentally shared across requests, which would truncate the
        # second one, and a handle that is never released.
        for _ in 1:3
            @test HTTP.get("http://$HOST:$port/stream").body == STREAM_BYTES
        end

        etag = HTTP.header(r, "ETag")
        @test !isempty(etag)
        cached = HTTP.get("http://$HOST:$port/stream", ["If-None-Match" => etag];
                          status_exception = false)
        @test cached.status == 304
        @test isempty(cached.body)

        ranged = HTTP.get("http://$HOST:$port/stream", ["Range" => "bytes=1000-1099"];
                          status_exception = false)
        @test ranged.status == 206
        @test ranged.body == STREAM_BYTES[1001:1100]

        # Interleave 304s (no body at all) with full downloads: if `adopt_stream_io!` failed to
        # close the handle on the bodyless path, this is where descriptors would pile up.
        for _ in 1:10
            HTTP.get("http://$HOST:$port/stream", ["If-None-Match" => etag]; status_exception = false)
        end
        @test HTTP.get("http://$HOST:$port/stream").body == STREAM_BYTES
    end
finally
    Nitro.Core.terminate(ctx)
end

end
