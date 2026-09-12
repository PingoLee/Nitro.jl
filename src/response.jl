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
using MIMEs: MIME, mime_from_path, contenttype_from_mime
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
