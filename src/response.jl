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

function content_disposition(filename::String, disposition::String)
    return string(disposition, "; filename=\"", filename, "\"")
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
        string("W/\"", st.size, "-", round(Int64, st.mtime), "\"")
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
| `etag` | `:weak_stat` (default), `:strong`, a `String`, or `nothing` — see [`file_validators`](@ref) |
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

end
