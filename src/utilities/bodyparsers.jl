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

# ── Nitro's read style for typed client JSON (#306) ─────────────────────────────
#
# Julia never frees an interned `Symbol`, so building one from a client string is unbounded,
# unauthenticated memory growth. JSON.jl's default style does exactly that for two field types:
# `StructUtils.lift(::Type{Symbol}, x) = Symbol(x)`, and `lift(::Type{<:Enum}, x)` interns the
# string *before* looking it up, so even an invalid enum name stays in memory for good. Every
# typed parse of client input -- `Json{T}`, `json(req, T)`, `parseparam`'s JSON fallback, the
# struct binder behind `Query{T}`/`Form{T}`/`Header{T}`/`Path{T}`/`JsonFragment{T}` -- passes
# this style instead. JSON.jl (>= 1.5.2; the compat floor is 1.9) wraps a caller's style and
# forwards `lift` to it after turning its internal `PtrString` into a `String`, so these methods
# see a plain string and can match an enum by name without interning it.
#
# `Symbol` itself is refused at route registration (`interns_client_strings`); the `lift` method
# below is the backstop for a `Symbol` reached some other way.
const _SU = JSON.StructUtils

"""
    NitroReadStyle

The `StructUtils` style every typed parse of client JSON goes through. It differs from JSON.jl's
default in what it refuses to do with a client string: it never interns one as a `Symbol` (#306).
Not part of the public API.
"""
struct NitroReadStyle <: _SU.StructStyle end
const NITRO_READ_STYLE = NitroReadStyle()

"""
    enum_from_string(E, s) :: E

The member of enum `E` whose name is `s`, found by comparing names rather than by building
`Symbol(s)`, so an unknown name is not interned. `Symbol(inst)` returns the member's own name,
which is interned already. Throws an `ArgumentError` that does not repeat `s`.
"""
function enum_from_string(::Type{E}, s::AbstractString) :: E where {E<:Enum}
    for inst in instances(E)
        String(Symbol(inst)) == s && return inst
    end
    throw(ArgumentError("not a valid $E name"))
end

_SU.lift(st::NitroReadStyle, ::Type{E}, x::AbstractString) where {E<:Enum} =
    (enum_from_string(E, x), _SU.defaultstate(st))
_SU.lift(st::NitroReadStyle, ::Type{E}, x::Integer) where {E<:Enum} =
    (E(x), _SU.defaultstate(st))

const _SYMBOL_REFUSED = "Nitro never builds a Symbol from request input (#306); declare an @enum, or a String checked against an allow-list"
_SU.lift(::NitroReadStyle, ::Type{Symbol}, x) = throw(ArgumentError(_SYMBOL_REFUSED))
_SU.liftkey(::NitroReadStyle, ::Type{Symbol}, x) = throw(ArgumentError(_SYMBOL_REFUSED))

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
"""
function json(req::HTTP.Request; kwargs...)
    payload = _request_payload(req)
    if isnothing(payload)
        return nothing
    end
    try
        return JSON.parse(IOBuffer(payload); kwargs...)
    catch e
        # `nothing` means "the body was not JSON", and that is the whole contract here.
        #
        # It used to also mean "the body was 20 KB of `[[[[…`, `JSON.parse` blew the stack,
        # and Julia says program state may be corrupted" -- swallowed, unlogged, on a route
        # needing no credentials at all, after which the handler served a normal 200 off
        # that worker (#254). This is the same defect as the auth middleware's, one layer
        # out and reachable by anyone.
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
        return JSON.parse(IOBuffer(payload); kwargs...)
    catch e
        # Same narrowing as the `Request` method above (#254). This one reads a RESPONSE
        # body, so it is not the attacker-reachable path -- it is here because the contract
        # ("not JSON" -> `nothing`) is the same and the two must not drift.
        is_unrecoverable(e) && rethrow()
        return nothing
    end
end

"""
    json(request::HTTP.Request, class_type::Type{T}; keyword_arguments...)

Read the body of a HTTP.Request as JSON with additional arguments for the read/serializer into a custom struct.

The body is client input, so it is always parsed with Nitro's read style, which never interns a
client string as a `Symbol` (#306): an enum field binds by name or by integer, and a `Symbol`
field is refused. Passing `style` is an `ArgumentError`.
"""
function json(req::HTTP.Request, class_type::Type{T}; kwargs...) where {T}
    haskey(kwargs, :style) && throw(ArgumentError(
        "json(req, T) parses client input with Nitro's read style (#306); `style` cannot be overridden"))
    payload = _request_payload(req)
    if isnothing(payload)
        return nothing
    end
    return JSON.parse(IOBuffer(payload), class_type; style = NITRO_READ_STYLE, kwargs...)
end

function json(res::HTTP.Response, class_type::Type{T}; kwargs...) where {T}
    payload = _request_payload(res)
    if isnothing(payload)
        return nothing
    end
    return JSON.parse(IOBuffer(payload), class_type; kwargs...)
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
