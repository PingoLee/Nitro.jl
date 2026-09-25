"""
    Res

The response-building namespace for handlers. Every builder an application should reach
for lives here:

| Builder | Content-Type |
|---------|--------------|
| [`Res.json`](@ref) | `application/json`; a `Vector{UInt8}` is sent verbatim as pre-serialized JSON |
| [`Res.html`](@ref) | `text/html` — the framework's markup sink, escape first |
| [`Res.send`](@ref) | `text/plain` by default, or `content_type=`; a `Vector{UInt8}` gives `application/octet-stream` |
| [`Res.status`](@ref) | none — bare status code, empty body |
| [`Res.file`](@ref) | sniffed from the path; serves **inline** unless `disposition=`/`filename=` is given |
| [`Res.redirect`](@ref) | none — sets `Location`; **302** by default, `status=307` preserves method and body |
| [`Res.sse`](@ref) | `text/event-stream` — a long-lived Server-Sent Events stream, chunked and flushed per event |

`Res.sse` is the one builder whose body is **not** materialized when it returns: it hands back a
response whose body is an open `HTTP.SSEStream` cursor that a producer fills afterwards. That makes
it single-use — never cache or share an SSE response — and it is why it is the only builder with a
background task behind it. See the streaming tutorial for the shape.

The bare names `text`, `json` and `binary` are *request body parsers*
(`Nitro.BodyParsers`), not response builders. One name, one direction.

Two other places build responses, neither of them for handler code: `Nitro.Util.response`,
which **content-sniffs** and is what the Mustache and OteraEngine template extensions render
through, and `protobuf` in the ProtoBuf extension. Middleware and core also construct fixed
error and redirect responses directly.

Caller-supplied `headers` are applied **last** in every builder, so they override the
defaults, `Content-Type` included.
"""
module Res

using HTTP
using Dates: DateTime, unix2datetime
using MIMEs: MIME, mime_from_path, contenttype_from_mime
using SHA: sha256
import JSON

function apply_headers!(response::HTTP.Response, headers)
    for header in headers
        HTTP.setheader(response, header)
    end
    return response
end

"""
    content_disposition(filename, disposition) -> String

The `Content-Disposition` value for `filename`, per RFC 6266 — the same shape Express's
`content-disposition` package emits (#328).

`filename` is often a value the app did not choose — an upload's original name kept as metadata —
so it is treated as untrusted. Control characters are dropped, and `\\` and `"` are escaped inside
the quoted-string. Unescaped, a `"` closed the quote and let the name append parameters of its own:
`report.txt"; filename*=UTF-8''evil.html; x="` injected a `filename*`, which browsers prefer over
`filename`.

The quoted `filename=` is ASCII-only, with `?` standing in for anything else. A name that needed
that substitution also gets an RFC 5987 `filename*=UTF-8''…` carrying the real name, so a plain
ASCII name produces exactly the header it always did.
"""
function content_disposition(filename::AbstractString, disposition::String)
    clean = filter(!iscntrl, filename)
    fallback = map(c -> isascii(c) ? c : '?', clean)
    quoted = replace(fallback, '\\' => "\\\\", '"' => "\\\"")
    header = string(disposition, "; filename=\"", quoted, "\"")
    fallback == clean && return header
    return string(header, "; filename*=UTF-8''", rfc5987_encode(clean))
end

# RFC 5987 `attr-char`: the bytes an `ext-value` carries literally. Everything else, including
# every byte of a multi-byte UTF-8 sequence, is percent-encoded.
is_attr_char(b::UInt8) = UInt8('a') <= b <= UInt8('z') || UInt8('A') <= b <= UInt8('Z') ||
    UInt8('0') <= b <= UInt8('9') || b in codeunits("!#\$&+-.^_`|~")

function rfc5987_encode(s::AbstractString)
    io = IOBuffer()
    for b in codeunits(s)
        is_attr_char(b) ? write(io, b) : print(io, '%', uppercase(string(b, base = 16, pad = 2)))
    end
    return String(take!(io))
end

"""
    file_content_type(path) -> String

The `Content-Type` a file is served with: its MIME type by extension, or
`application/octet-stream`. Shared with the static mounts so a mounted file and a
`Res.file` of the same path never disagree.

Deliberately `MIMEs.mime_from_path` rather than HTTP.jl's own table, which covers 21
extensions to MIMEs' several hundred.
"""
file_content_type(path::AbstractString)::String =
    mime_from_path(path, MIME"application/octet-stream"()) |> contenttype_from_mime

"""
    file_validators(path; etag = :weak_stat, bytes = nothing) -> (etag, modtime)

The cache validators for a file: an `ETag` string (or `nothing`) and a `Last-Modified`
`DateTime` (or `nothing`).

`etag` selects the strategy:

| Value | Tag | Cost |
|---|---|---|
| `:weak_stat` (default) | `W/"<size>-<mtime>"` | free — reuses the `stat` already taken |
| `:strong` | `"<sha256 of the body>"` | hashes the whole body |
| `nothing` | none emitted | — |
| a `String` | used verbatim | — |

**`:weak_stat` is the default on purpose.** A strong tag means hashing every byte, which for
a mount is paid once per file at startup — fine for a small `dist/`, a visible pause for a
folder of media. Size-plus-mtime is what Go's `net/http` and nginx both use by default, and a
weak tag is *exactly* as good for `If-None-Match`, which compares weakly. Strong tags matter
for `If-Range` and `If-Match`, so `:strong` is there when you want resumable downloads to be
airtight.

A weak tag is correct even when the bytes were captured at mount time and the file has since
changed on disk: the tag describes what is being served, and what is being served is the
snapshot.
"""
function file_validators(path::AbstractString; etag = :weak_stat, bytes = nothing)
    st = stat(path)
    modtime = unix2datetime(st.mtime)
    tag = if etag === nothing
        nothing
    elseif etag === :weak_stat
        # `sizeof(bytes)` when the caller has the body, `st.size` only when it does not. A
        # `loadfile` decides the body, so the file's own size is not the representation's size —
        # the same rule `Res.file` applies to `Content-Length` (#92). Using `st.size` here would
        # emit a validator for a representation that was never sent.
        size = bytes === nothing ? st.size : sizeof(bytes)
        string("W/\"", size, "-", round(Int64, st.mtime), "\"")
    elseif etag === :strong
        body = bytes === nothing ? read(path) : bytes
        string("\"", bytes2hex(sha256(body)), "\"")
    elseif etag isa AbstractString
        String(etag)
    else
        throw(ArgumentError("Res.file: `etag` must be :weak_stat, :strong, a String, or nothing — got $(repr(etag))"))
    end
    return tag, modtime
end

"""
    adopt_stream_io!(response, io) -> response

Hand ownership of `io` to a streaming response body, or close it when there is no body.

`HTTP.servecontent(req, ::IO)` builds its streaming body with `owns_io = false`, because it does
not know whether the caller wants the handle back. HTTP's own `servefile` then claims it through a
private helper; this is that step, done without naming the private body type — the field is set
only if it exists, which is exactly the condition under which a body will be drained.

**The `else` branch is not defensive padding.** A `304`, `412` or `416` carries *no* body, so
nothing will ever drain it and the handle would leak until finalization. Under load that is an
unbounded file-descriptor leak in precisely the common case: a client that already has the file
cached.
"""
function adopt_stream_io!(response::HTTP.Response, io::IO)
    body = response.body
    if body isa HTTP.AbstractBody && hasfield(typeof(body), :owns_io)
        body.owns_io = true
    else
        close(io)
    end
    return response
end

"""
    json(data; status=200, headers=[])

Return an HTTP.Response with the provided data serialized to JSON and the Content-Type header set to application/json.
"""
function json(data; status::Int=200, headers::Vector=[])
    response = HTTP.Response(status, body=JSON.json(data))
    HTTP.setheader(response, "Content-Type" => "application/json; charset=utf-8")
    apply_headers!(response, headers)
    return response
end

"""
    json(data::Vector{UInt8}; status=200, headers=[])

Return an HTTP.Response for a body that is *already* serialized JSON. The bytes are sent
verbatim — passing them through `JSON.json` would re-encode them as an array of integers.
"""
function json(data::Vector{UInt8}; status::Int=200, headers::Vector=[])
    response = HTTP.Response(status, body=data)
    HTTP.setheader(response, "Content-Type" => "application/json; charset=utf-8")
    apply_headers!(response, headers)
    return response
end

"""
    html(content::String; status=200, headers=[])

Return an HTTP.Response with the Content-Type header set to text/html.

Security: this is the framework's markup sink. Everything else defaults to a non-markup
content type, and a raw `String` returned from a handler is served as text/plain without
content-sniffing. Escape user-influenced data before it reaches here, always.
"""
function html(content::String; status::Int=200, headers::Vector=[])
    response = HTTP.Response(status, body=content)
    HTTP.setheader(response, "Content-Type" => "text/html; charset=utf-8")
    apply_headers!(response, headers)
    return response
end

"""
    status(code::Int; headers=[])

Return an empty HTTP.Response with the specified status code.
"""
function status(code::Int; headers::Vector=[])
    response = HTTP.Response(code, body="")
    apply_headers!(response, headers)
    return response
end

"""
    send(body::String; status=200, headers=[], content_type="text/plain; charset=utf-8")

Return an HTTP.Response with the provided string body. Defaults to text/plain; pass
`content_type` for any other textual type (`"text/css"`, `"application/xml"`, …).

Security: `content_type` makes this an opt-in markup sink — `send(x; content_type="text/html")`
is exactly as dangerous as `html(x)`. Escape user-influenced data first.
"""
function send(body::String; status::Int=200, headers::Vector=[], content_type::String="text/plain; charset=utf-8")
    response = HTTP.Response(status, body=body)
    HTTP.setheader(response, "Content-Type" => content_type)
    apply_headers!(response, headers)
    return response
end

"""
    send(body::Vector{UInt8}; status=200, headers=[], content_type="application/octet-stream")

Return an HTTP.Response for a raw byte body. Defaults to application/octet-stream.
"""
function send(body::Vector{UInt8}; status::Int=200, headers::Vector=[], content_type::String="application/octet-stream")
    response = HTTP.Response(status, body=body)
    HTTP.setheader(response, "Content-Type" => content_type)
    apply_headers!(response, headers)
    return response
end

"""
    file(path; status=200, headers=[], filename=nothing, disposition=nothing, loadfile=nothing)

Return an HTTP.Response for a file, setting Content-Type from the path's MIME type and
Content-Length from the body actually sent.

`Content-Disposition` is **opt-in**: it is emitted only when `disposition` or `filename` is
given, so a plain `file(path)` serves inline — which is what static mounts need. Pass
`disposition="attachment"` to force a download. Supplying `filename` alone implies
`"attachment"`.

`filename` may be untrusted — an upload's original name, say. It is escaped for the header, not
interpolated: control characters are dropped, `"` and `\\` are escaped, and a non-ASCII name is
sent as an ASCII `filename=` fallback plus an RFC 5987 `filename*=UTF-8''…` with the real name.

Custom headers are applied last and may override defaults.
"""
function file(path::String; status::Int=200, headers::Vector=[], filename=nothing,
              disposition::Union{Nothing,String}=nothing, loadfile=nothing)
    body = isnothing(loadfile) ? read(path) : loadfile(path)
    response = HTTP.Response(status, body=body)
    content_type = mime_from_path(path, MIME"application/octet-stream"()) |> contenttype_from_mime

    HTTP.setheader(response, "Content-Type" => content_type)
    # `sizeof`, not `length`: a `loadfile` returning a String makes `length` a *character* count.
    HTTP.setheader(response, "Content-Length" => string(sizeof(body)))
    # An empty `disposition` means the same as `nothing`; emitting it would produce a
    # malformed `Content-Disposition: ; filename="..."`.
    wanted = isnothing(disposition) || isempty(disposition) ? nothing : disposition
    if !isnothing(wanted) || !isnothing(filename)
        resolved_filename = isnothing(filename) ? basename(path) : filename
        HTTP.setheader(response, "Content-Disposition" =>
            content_disposition(resolved_filename, something(wanted, "attachment")))
    end
    apply_headers!(response, headers)
    return response
end

"""
    file(req, path; headers=[], filename=nothing, disposition=nothing, loadfile=nothing,
         etag=:weak_stat, cache_control=nothing, allow_ranges=true, stream=false)

Serve a file **for a specific request**, with conditional-GET and byte-range handling.

This is the request-aware sibling of [`file(path)`](@ref). Because it can see the request's
headers it can answer `304 Not Modified` instead of resending a body, and `206 Partial
Content` for a `Range` — neither of which a builder without a request can do. It emits
`ETag`, `Last-Modified` and `Accept-Ranges`, and returns `304`, `412` or `416` when the
preconditions call for it.

| Kwarg | Effect |
|---|---|
| `etag` | `:weak_stat` (default), `:strong`, a `String`, or `nothing` — see `Nitro.Res.file_validators` |
| `cache_control` | emitted verbatim when given. **No default**: a `max-age` guessed on your behalf is wrong more often than it is right |
| `allow_ranges` | `false` suppresses `Accept-Ranges` and serves the whole body |
| `loadfile` | as in [`file(path)`](@ref) — decides the body, and therefore the validators |
| `stream` | `true` sends the file in 64 KiB chunks — peak memory is a buffer, not the file |

**`stream = true` is what makes a large download safe.** Without it the whole file is read into
memory before the first byte goes out, so N concurrent downloads of an N-gigabyte file need N×
that resident. With it, memory is bounded by the chunk buffer regardless of file size or
concurrency. The trade is that a streamed response is **single-use** — it is a cursor over an open
file, not a buffer — so it can never be cached or shared, and `etag = :strong` is refused because
hashing the body would mean reading all of it, which is the thing being avoided.

`Content-Disposition` is opt-in exactly as in [`file(path)`](@ref), and caller `headers` are
applied last so they override anything computed here.

The protocol work is `HTTP.servecontent`, which is HTTP.jl **public** API. Nitro does not
hand-roll the precondition table: weak-versus-strong tag comparison, the order `If-Match` /
`If-Unmodified-Since` / `If-None-Match` / `If-Modified-Since` must be evaluated in, and which
headers a `304` may carry are all places where a plausible implementation is subtly wrong.

```julia
path("/reports/<int:id>.csv", function (req::HTTP.Request, id::Int)
    Res.file(req, report_path(id); disposition = "attachment")
end)
```
"""
function file(req::HTTP.Request, path::String; headers::Vector=[], filename=nothing,
              disposition::Union{Nothing,String}=nothing, loadfile=nothing,
              etag = :weak_stat, cache_control::Union{Nothing,AbstractString}=nothing,
              allow_ranges::Bool=true, stream::Bool=false)
    if stream && !isnothing(loadfile)
        throw(ArgumentError("Res.file: `stream=true` and `loadfile` are mutually exclusive — `loadfile` produces the whole body in memory, which is what streaming avoids"))
    end
    if stream && etag === :strong
        throw(ArgumentError("Res.file: `stream=true` and `etag=:strong` are mutually exclusive — a strong tag hashes the whole body, which is what streaming avoids. Use `:weak_stat`, or pass a tag you computed yourself"))
    end

    extra = Vector{Pair{String,String}}()
    if !isnothing(cache_control)
        push!(extra, "Cache-Control" => String(cache_control))
    end
    # Same opt-in rule as the request-less builder: an empty `disposition` means the same as
    # `nothing`, and emitting it would produce a malformed `Content-Disposition: ; filename=…`.
    wanted = isnothing(disposition) || isempty(disposition) ? nothing : disposition
    if !isnothing(wanted) || !isnothing(filename)
        resolved_filename = isnothing(filename) ? basename(path) : filename
        push!(extra, "Content-Disposition" =>
            content_disposition(resolved_filename, something(wanted, "attachment")))
    end

    if stream
        io = open(path, "r")
        try
            tag, modtime = file_validators(path; etag = etag)
            resp = HTTP.servecontent(req, io; name = basename(path), modtime = modtime,
                                     content_type = file_content_type(path), etag = tag,
                                     headers = extra, allow_ranges = allow_ranges)
            adopt_stream_io!(resp, io)
            return apply_headers!(resp, headers)
        catch
            close(io)
            rethrow()
        end
    end

    body = isnothing(loadfile) ? read(path) : loadfile(path)
    source = body isa AbstractVector{UInt8} ? body : Vector{UInt8}(codeunits(body))
    # When `loadfile` decided the body, the file's own size is not the body's size, so the
    # validators must describe what is being sent (#92's rule, one layer up).
    tag, modtime = file_validators(path; etag = etag, bytes = source)
    resp = HTTP.servecontent(req, source; name = basename(path), modtime = modtime,
                             content_type = file_content_type(path), etag = tag,
                             headers = extra, allow_ranges = allow_ranges)
    return apply_headers!(resp, headers)
end

"""
    redirect(url; status=302, headers=[])

Return an HTTP redirect response with the Location header set. Pass `status=307` to
preserve the request method and body.
"""
function redirect(url::String; status::Int=302, headers::Vector=[])
    response = HTTP.Response(status, body="")
    HTTP.setheader(response, "Location" => url)
    apply_headers!(response, headers)
    return response
end


"""
Default ceiling, in bytes, on **one serialized SSE event** — `HTTP.SSEStream`'s `max_len`.

16 MiB is HTTP.jl's own `SSEStream` default. It is spelled out here rather than inherited because
`_DEFAULT_SSE_STREAM_MAX_LEN` is private, while the three names [`sse`](@ref) actually builds on —
`HTTP.sse_stream`, `HTTP.SSEStream` and `HTTP.SSEEvent` — are public API.

This caps a single event, **not** the stream's buffer. See [`sse`](@ref) on pacing.
"""
const SSE_MAX_EVENT_BYTES = 16 * 1024 * 1024

# Is `err` a write that failed because the SSE stream was already closed?
#
# The bare shape is `Base.IOError`, which is what a closed `Base.BufferStream` raises — measured
# both for a stream closed before the write and one closed during a blocked write. But a producer
# that fans its writes out over tasks (`@sync` + `Threads.@spawn`, a perfectly reasonable shape for
# one that multiplexes several sources) gets that wrapped: `CompositeException` →
# `TaskFailedException` → `IOError`. Classifying the wrapper as "not a disconnect" would log an
# error for every departing client, which is the noise this classification exists to prevent.
#
# Bounded depth rather than a `while true`: these wrappers nest at most a couple of levels in
# practice, and a fixed bound cannot be walked into a cycle by an exception type that holds itself.
function _is_closed_stream_error(err, depth::Int = 0)::Bool
    err isa Base.IOError && return true
    depth >= 4 && return false
    if err isa CompositeException
        # `any`, not `first`: a fan-out can fail on several tasks and only one needs to be the
        # disconnect for the rest to be its consequence.
        return any(e -> _is_closed_stream_error(e, depth + 1), err.exceptions)
    end
    err isa TaskFailedException && return _is_closed_stream_error(err.task.result, depth + 1)
    return false
end

# Run a `Res.sse` producer on its own task and close the stream when it finishes.
#
# Closing in `finally` is not hygiene, it is what ENDS the response: the transport's drain parks in
# `body_read!` → `eof(buffer)` until a byte arrives or the stream closes, so a producer that
# returned (or threw) without closing would hold the connection open forever.
#
# `errormonitor` at the call site, plus `InterruptException` rethrow here, per the one background-task
# discipline in src/middleware/janitor.jl: nothing waits on this task, so a throw that is neither
# caught nor monitored dies mute.
function _run_sse_producer(producer::Function, events::HTTP.SSEStream)
    try
        producer(events)
    catch err
        err isa InterruptException && rethrow()
        # A write that failed BECAUSE the stream was closed is the expected end, not a fault. The
        # transport closes the body when the client disconnects — and `terminate` force-closes the
        # socket on a long-lived handler by design (src/core/lifecycle.jl) — after which the
        # producer's next `write` throws. Reporting that at error level would make the most common
        # way an SSE connection ends look like a bug, once per connected client.
        #
        # BOTH halves of the predicate are load-bearing, and `!isopen` alone was wrong. The
        # docstring below teaches `try … finally close(events) end`, so a producer that throws for
        # its OWN reasons routinely reaches this `catch` with the stream already closed by its own
        # `finally` — and keying on the state alone silently demoted that to `@debug`, which is
        # compiled out by default. The operator got nothing and the client got a clean short stream.
        #
        # `_is_closed_stream_error` is the second half, and it is what keeps a genuine fault
        # visible: HTTP's own SSE faults — an oversized event, a CR in `event`/`id` — are
        # `ArgumentError`, so they stay at error level even when the stream is closed, which is
        # exactly the case that used to be swallowed.
        if !isopen(events) && _is_closed_stream_error(err)
            @debug "Nitro.Res.sse: producer stopped because the event stream was closed" exception=err
            return nothing
        end
        # Deliberately no event payload in the message — an SSE body carries whatever the
        # application chose to stream, which may be session- or user-scoped.
        @error "Nitro.Res.sse: the event producer failed" exception=(err, catch_backtrace())
    finally
        HTTP.body_close!(events)
    end
    return nothing
end

"""
    sse(; status=200, headers=[], max_len=SSE_MAX_EVENT_BYTES) -> HTTP.Response
    sse(producer; status=200, headers=[], max_len=SSE_MAX_EVENT_BYTES) -> HTTP.Response

Return a Server-Sent Events response: `Content-Type: text/event-stream`, `Cache-Control: no-cache`,
`X-Accel-Buffering: no`, no `Content-Length`, and `Transfer-Encoding: chunked` — one chunk per
event, flushed as it is written.

The body is an `HTTP.SSEStream`. Write `HTTP.SSEEvent` values to it (`SSEEvent` is re-exported, so
`using Nitro` is enough) and **close it to end the response**.

The `producer` form is the usual one: Nitro runs it on its own task, closes the stream when it
returns, and treats a client disconnect as a normal ending rather than an error.

```julia
function ticks(req)
    return Res.sse() do events
        for i in 1:10
            isopen(events) || break          # the client hung up
            write(events, SSEEvent(string(i); event = "tick", id = string(i)))
            sleep(1)
        end
    end
end

path("/events", ticks; method = "GET")
```

The argument-less form hands the response back with the stream still open, for a caller that wants
to own the producing task itself. Closing it is then **your** responsibility.

# Why this is a `Res` builder and not a `STREAM` route

A `method = "STREAM"` handler writes on the raw `HTTP.Stream`, which sets `response_started` — so
Nitro's stream handler discards whatever the middleware chain returned, and `Cors`,
`SecurityHeaders` and a session `Set-Cookie` are all silently dropped. `Res.sse` returns an
ordinary `HTTP.Response`, so the whole chain applies to an event stream exactly as it does to JSON.
Prefer this; reach for `STREAM` only when you need to control the response head yourself.

# Pacing, and what `max_len` does not cover

`max_len` caps one serialized event. It does **not** bound the stream's buffer, which is a
`Base.BufferStream` and grows without limit — so a producer that writes far faster than the client
reads accumulates in memory. Pace the producer (as the loop above does) and check `isopen(events)`
each iteration; that check is also how a disconnected client stops the work rather than merely
stopping the writes.

# Keeping the connection alive

Nitro sets none of HTTP.jl's read/write/idle timeouts, so nothing here closes an idle stream — but
proxies do. Emit a periodic event (`SSEEvent(""; event = "ping")`) if your stream can be quiet for
longer than the proxy's idle timeout, and see the reverse-proxy guide: nginx buffers proxied
responses by default, which `X-Accel-Buffering: no` asks it not to do for this route.

# Shutdown

A long-lived stream is **always cut at `serve(shutdown_timeout = …)`** — the graceful drain cannot
wait out a handler that holds its connection for its whole lifetime. A producer parked in `write`
unwinds as soon as the socket is torn down; one parked on a `sleep` or a `Channel` does not, so give
it a shutdown signal of its own from a `LifecycleMiddleware`'s `on_shutdown`. See
[`terminate`](@ref Nitro.terminate).

Caller-supplied `headers` are applied last, so they override the defaults above — a
`Cache-Control` you pass wins.
"""
function sse(; status::Int=200, headers::Vector=[], max_len::Integer=SSE_MAX_EVENT_BYTES)
    response = HTTP.sse_stream(status; max_len = max_len)
    # Nitro's one addition to HTTP's SSE header set. nginx buffers a proxied response by default,
    # and an event stream that arrives in one lump at the end is indistinguishable from a hung
    # endpoint — so the hint ships with the builder rather than being left to every deployment.
    HTTP.setheader(response, "X-Accel-Buffering" => "no")
    apply_headers!(response, headers)
    return response
end

function sse(producer::Function; status::Int=200, headers::Vector=[],
             max_len::Integer=SSE_MAX_EVENT_BYTES)
    # Built through the method above, NOT through `HTTP.sse_stream(response, f)`. That overload
    # re-runs HTTP's `_configure_sse_response!`, which would `setheader` `Content-Type` and
    # `Cache-Control` back over anything the caller passed — breaking the `Res` contract that
    # caller headers apply last. It also logs every client disconnect as an error; see
    # `_run_sse_producer`.
    response = sse(; status = status, headers = headers, max_len = max_len)
    events = response.body::HTTP.SSEStream
    # Spawned, not sticky: the producer runs for the connection's whole life and must not pin the
    # thread that served the request. Same reasoning as `parallel_stream_handler`
    # (src/core/transport.jl) and the janitor discipline (src/middleware/janitor.jl).
    errormonitor(Threads.@spawn _run_sse_producer(producer, events))
    return response
end

end
