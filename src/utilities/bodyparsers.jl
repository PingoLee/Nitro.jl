module BodyParsers

using HTTP 
using JSON
using ..Util
using ...Errors: is_unrecoverable

export text, binary, json, formdata, multipart, FormFile

"""
    FormFile

Represents a single uploaded file from a `multipart/form-data` request.

# Fields
- `name::String` — the form field name
- `filename::String` — the original filename provided by the client
- `content_type::String` — the MIME type of the file (e.g. `"application/octet-stream"`)
- `data::Vector{UInt8}` — the raw file bytes
"""
struct FormFile
    name::String
    filename::String
    content_type::String
    data::Vector{UInt8}
end

const EMPTY_FORM_DATA = Dict{String,String}()

# HTTP.jl v2 replaced the raw `Vector{UInt8}` request body (and `HTTP.payload`) with the
# `AbstractBody` hierarchy. Extract the bytes without consuming the body cursor so the
# same request body can be read more than once (e.g. `.json` and `.form`). Responses may
# additionally retain their body as a raw `Vector{UInt8}` or `String` (v2 keeps byte/string
# bodies as-is so fixtures can inspect `response.body` directly), so handle those too.
_body_bytes(::HTTP.EmptyBody) = UInt8[]
_body_bytes(body::HTTP.BytesBody) = Vector{UInt8}(body.data)
_body_bytes(::Nothing) = UInt8[]
_body_bytes(body::AbstractVector{UInt8}) = Vector{UInt8}(body)
_body_bytes(body::AbstractString) = Vector{UInt8}(codeunits(String(body)))

function _request_payload(req::HTTP.Request)
    payload = _body_bytes(req.body)
    return isempty(payload) ? nothing : payload
end

function _request_payload(res::HTTP.Response)
    payload = _body_bytes(res.body)
    return isempty(payload) ? nothing : payload
end

### Bounded JSON parsing (#314)

"""
    MAX_JSON_DEPTH

The deepest nesting of arrays and objects Nitro will hand to `JSON.parse`: **512**. A document
nested any deeper is rejected as malformed JSON before the parser sees it.

JSON.jl parses by recursive descent and has no depth option, so without this bound the depth
of a request's JSON is the depth of the parser's recursion, and a small request exhausts the
stack. Measured on a `Threads.@spawn` task -- the stack every request runs on -- with JSON 1.8.0
and Julia 1.12.7, the first depth that raises `StackOverflowError`:

| input | overflows at depth |
|---|---|
| untyped `[[[…]]]`, or unclosed `[[[…` | ~3,100 |
| untyped objects (`dicttype = Dict{String, Any}`), typed `Dict{String, Any}` | ~3,800 |
| typed `Vector{Any}` | ~3,900 |
| typed `Dict{String, JSON.JSONText}` | ~5,900 |

An unclosed `[[[…` reaches that in ~3.1 KB, which is a ~4.1 KB bearer token once base64url
encoded. Catching the overflow is not a defence: Julia reports program state as possibly
corrupted afterwards, and on some Windows hosts the process dies outright (#301). 512 leaves a
6× margin for larger stack frames (Win64, coverage builds, user types) and for the stack the
middleware chain has already used, and is far deeper than any real payload.

Internal and fixed on purpose. Every request-data `JSON.parse` in Nitro goes through
`_parse_json_bounded`, and `test/bodyparser_tests.jl` fails if one does not.
"""
const MAX_JSON_DEPTH = 512

@noinline _throw_json_too_deep() =
    throw(ArgumentError("JSON nesting exceeds the maximum depth of $MAX_JSON_DEPTH"))

"""
    _check_json_depth(bytes) -> nothing

Throw `ArgumentError` if the JSON text `bytes` nests arrays and objects deeper than
`MAX_JSON_DEPTH`. One pass, no allocation, no recursion -- it must not be able to fail
the way the parser it guards does.

It counts `[`/`{` against `]`/`}` outside string literals; inside one, `\\` skips the next byte
and `"` closes it. On any valid prefix of a JSON document that count IS the parser's recursion
depth: JSON has no comments or single-quoted strings, a `\\uXXXX` escape contains neither `"`
nor `\\`, and no byte of a multi-byte UTF-8 sequence matches an ASCII delimiter. It does not
validate anything else -- malformed input that stays shallow is left to `JSON.parse`, which
rejects it at the first bad byte. The count never goes below zero, so leading stray closers
cannot bank depth for a later run of openers. (With `jsonlines = true` the parser adds one
implicit root array, so it recurses one level deeper than the count -- immaterial at this margin.)

`ArgumentError` is what `JSON.parse` itself throws on malformed input, so a too-deep document
lands on every caller's existing "not JSON" path. The message names the limit, never the input.
"""
function _check_json_depth(bytes::AbstractVector{UInt8})
    depth = 0
    instring = false
    escaped = false
    for b in bytes
        if instring
            if escaped
                escaped = false
            elseif b == UInt8('\\')
                escaped = true
            elseif b == UInt8('"')
                instring = false
            end
        elseif b == UInt8('"')
            instring = true
        elseif b == UInt8('[') || b == UInt8('{')
            depth += 1
            depth > MAX_JSON_DEPTH && _throw_json_too_deep()
        elseif (b == UInt8(']') || b == UInt8('}')) && depth > 0
            depth -= 1
        end
    end
    return nothing
end

_check_json_depth(s::AbstractString) = _check_json_depth(codeunits(s))

"""
    _parse_json_bounded(buf, T = Any; kwargs...)

`JSON.parse(buf, T; kwargs...)` after `_check_json_depth`. The one way Nitro parses JSON
that came from a request -- body, query string, path segment, cookie, or JWT segment -- so the
parser's recursion is bounded by `MAX_JSON_DEPTH` and never by the input (#314).
Throws `ArgumentError` for a too-deep document, like any other malformed one.
"""
function _parse_json_bounded(buf::Union{AbstractVector{UInt8}, AbstractString}, ::Type{T} = Any; kwargs...) where {T}
    _check_json_depth(buf)
    return JSON.parse(buf, T; kwargs...)
end

### Helper functions used to parse the body of a HTTP.Request object

"""
    text(request::HTTP.Request)

Read the body of a HTTP.Request as a String
"""
function text(req::HTTP.Request) :: String
    body = IOBuffer(_body_bytes(req.body))
    return eof(body) ? "" : read(seekstart(body), String)
end

function text(res::HTTP.Response) :: String
    payload = _request_payload(res)
    return isnothing(payload) ? "" : String(payload)
end


"""
    formdata(request::HTTP.Request)

Read the html form data from the body of a HTTP.Request
"""
function formdata(req::HTTP.Request) :: Dict{String,String}
    # multipart/form-data is not urlencoded — parsing it here yields a garbage
    # key. Use `getfiles(req)` / `getpost(req)` (or `multipart(req)`) for multipart bodies.
    if occursin("multipart/form-data", HTTP.header(req, "Content-Type", ""))
        return copy(EMPTY_FORM_DATA)
    end
    body = text(req)
    if isnothing(body) || !occursin('=', body)
        return copy(EMPTY_FORM_DATA)
    end
    try
        return HTTP.queryparams(body)
    catch e
        # An unparseable form is "no form", which is this function's contract. A corrupted
        # process is not (#254) -- see `is_unrecoverable` (src/errors.jl).
        is_unrecoverable(e) && rethrow()
        return copy(EMPTY_FORM_DATA)
    end
end

function formdata(res::HTTP.Response) :: Dict{String,String}
    body = text(res)
    if isempty(body) || !occursin('=', body)
        return copy(EMPTY_FORM_DATA)
    end
    try
        return HTTP.queryparams(body)
    catch e
        # Same narrowing as the `Request` method above (#254).
        is_unrecoverable(e) && rethrow()
        return copy(EMPTY_FORM_DATA)
    end
end


"""
    binary(request::HTTP.Request)

Read the body of a HTTP.Request as a Vector{UInt8}
"""
function binary(req::HTTP.Request) :: Vector{UInt8}
    body = IOBuffer(_body_bytes(req.body))
    return eof(body) ? UInt8[] : readavailable(body)
end

function binary(res::HTTP.Response) :: Vector{UInt8}
    payload = _request_payload(res)
    if isnothing(payload)
        return UInt8[]
    elseif payload isa AbstractVector{UInt8}
        return Vector{UInt8}(payload)
    end
    return Vector{UInt8}(codeunits(String(payload)))
end


"""
    json(request::HTTP.Request; keyword_arguments...)

Read the body of a HTTP.Request as JSON with additional arguments for the read/serializer.

Returns `nothing` when the body is empty or is not JSON -- including a document nested deeper
than 512 arrays/objects, which is rejected before parsing (#314).
"""
function json(req::HTTP.Request; kwargs...)
    payload = _request_payload(req)
    if isnothing(payload)
        return nothing
    end
    try
        return _parse_json_bounded(payload; kwargs...)
    catch e
        # `nothing` means "the body was not JSON", and that is the whole contract here. A
        # document nested past `MAX_JSON_DEPTH` is one of those: `_parse_json_bounded`
        # rejects it with an `ArgumentError` before `JSON.parse` can recurse into it (#314).
        #
        # Before that bound, 3 KB of `[[[[…` blew the stack here, and a bare catch served
        # the handler a normal 200 off a worker Julia called possibly corrupt (#254). The
        # rethrow stays for what the bound does not cover -- `OutOfMemoryError`, an
        # `InterruptException`, or a regression in the bound itself.
        is_unrecoverable(e) && rethrow()
        return nothing
    end
end

function json(res::HTTP.Response; kwargs...)
    payload = _request_payload(res)
    if isnothing(payload)
        return nothing
    end
    try
        return _parse_json_bounded(payload; kwargs...)
    catch e
        # Same contract and bound as the `Request` method above (#254, #314). This one reads
        # a RESPONSE body, so it is not the attacker-reachable path -- it is here because the
        # contract ("not JSON" -> `nothing`) is the same and the two must not drift.
        is_unrecoverable(e) && rethrow()
        return nothing
    end
end

"""
    json(request::HTTP.Request, class_type::Type{T}; keyword_arguments...)

Read the body of a HTTP.Request as JSON with additional arguments for the read/serializer into a custom struct.

Throws `ArgumentError` when the body is not JSON, including a document nested deeper than 512
arrays/objects (#314).
"""
function json(req::HTTP.Request, class_type::Type{T}; kwargs...) where {T}
    payload = _request_payload(req)
    if isnothing(payload)
        return nothing
    end
    return _parse_json_bounded(payload, class_type; kwargs...)
end

function json(res::HTTP.Response, class_type::Type{T}; kwargs...) where {T}
    payload = _request_payload(res)
    if isnothing(payload)
        return nothing
    end
    return _parse_json_bounded(payload, class_type; kwargs...)
end


"""
    multipart(request::HTTP.Request) :: Dict{String, Union{FormFile, Vector{FormFile}, String, Vector{String}}}

Parse a `multipart/form-data` request body and return a `Dict` mapping field names
to their values.

- **File fields** (those with a `filename`) become [`FormFile`](@ref) objects.
- **Text fields** (no `filename`) become `String` values.
- When the same field name appears more than once, the values are collected into a `Vector`.

Returns an empty `Dict` if the request is not `multipart/form-data` or has no body.

# Examples

```julia
# Inside a handler
function upload_handler(req)
    files = multipart(req.request)
    # Single file field
    file = files["document"]  # => FormFile
    file.filename             # => "report.xlsx"
    file.data                 # => Vector{UInt8}

    # Multiple files under the same field name
    attachments = files["attachments"]  # => Vector{FormFile}
    for f in attachments
        println(f.filename, " => ", length(f.data), " bytes")
    end
end
```
"""
function multipart(req::HTTP.Request) :: Dict{String, Union{FormFile, Vector{FormFile}, String, Vector{String}}}
    result = Dict{String, Union{FormFile, Vector{FormFile}, String, Vector{String}}}()

    parts = try
        HTTP.parse_multipart_form(req)
    catch e
        # A malformed multipart body is "no parts"; a corrupted process is not (#254).
        is_unrecoverable(e) && rethrow()
        return result
    end

    if isnothing(parts)
        return result
    end

    # Collect files and text into separate, homogeneously-typed buckets. This
    # keeps the per-field vectors correctly typed (`Vector{FormFile}` /
    # `Vector{String}`) and, crucially, prevents a field name that anomalously
    # carries both a file part and a text part from collapsing into a
    # `Vector{Any}` — which the typed result Dict cannot hold and which used to
    # throw a `MethodError` (a client-triggerable 500 via `getfiles`/`getpost`).
    files = Dict{String, Vector{FormFile}}()
    texts = Dict{String, Vector{String}}()
    for part in parts
        name = part.name
        if !isnothing(part.filename) && !isempty(part.filename)
            push!(get!(() -> FormFile[], files, name),
                  FormFile(name, part.filename, part.contenttype, read(part.data)))
        else
            push!(get!(() -> String[], texts, name), String(read(part.data)))
        end
    end

    # A file field wins its name (a filename is an explicit upload); a text part
    # sent under a name already used by a file is dropped rather than crashing.
    for (name, fs) in files
        result[name] = length(fs) == 1 ? fs[1] : fs
    end
    for (name, ts) in texts
        haskey(result, name) && continue
        result[name] = length(ts) == 1 ? ts[1] : ts
    end

    return result
end

end # module BodyParsers
