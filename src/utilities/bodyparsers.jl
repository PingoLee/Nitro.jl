module BodyParsers

using HTTP
using JSON
using Dates: Dates
using UUIDs: UUID
using ..Util
using ...Errors: is_unrecoverable, ValidationError

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

# A float field must receive a finite value (#327). JSON itself has no NaN or Infinity, but it has
# no size limit either: JSON.jl reads `1e999`, or a 400-digit integer, as a `BigFloat`/`BigInt`,
# and converting that to a `Float64` field is `Inf`. The `Union` bound also covers a
# `Nullable{Float64}` field, which is lifted with its union type, not the float alone.
function _SU.lift(st::NitroReadStyle, ::Type{T}, x::Real) where {T <: Union{AbstractFloat, Nothing, Missing}}
    value, state = @invoke _SU.lift(st::_SU.StructStyle, T::Type, x::Any)
    value isa AbstractFloat && !isfinite(value) && throw(ArgumentError("not a finite number"))
    return value, state
end

"""
    interns_client_strings(T) :: Bool

Whether binding request input to `T` could build a `Symbol` from a client string (#306): `T` is
`Symbol`, or contains one anywhere a value is read into -- a `Union` member, an element, key or
value type, a tuple slot, a struct field. A dictionary keyed by an enum counts too: JSON.jl lifts
dictionary keys with its own conversion, which interns an enum name before looking it up.

Route registration refuses such a parameter, and `json(req, T)` refuses such a `T`. An enum
*value* is fine: every Nitro path matches it by name without interning.
"""
interns_client_strings(@nospecialize(T)) :: Bool = _interns(T, Base.IdSet{Any}())

function _interns(@nospecialize(T), seen::Base.IdSet{Any}) :: Bool
    T === Symbol && return true
    T === Any && return false
    T isa TypeVar && return _interns(T.ub, seen)
    T isa UnionAll && return _interns(Base.unwrap_unionall(T), seen)
    T isa Union && return _interns(T.a, seen) || _interns(T.b, seen)
    T isa DataType || return false
    T in seen && return false
    push!(seen, T)
    # An unwrapped `UnionAll` (`Vector` -> `Array{T,1}`) still has free type variables, which
    # `eltype`/`fieldtypes` cannot resolve; its parameters (each a `TypeVar` bound) can be.
    Base.has_free_typevars(T) &&
        return any(p -> (p isa Type || p isa TypeVar) && _interns(p, seen), T.parameters)
    # Values of these types are parsed or matched without ever building a Symbol.
    T <: Union{Number, AbstractString, AbstractChar, Enum, Dates.TimeType, UUID, Regex, Nothing, Missing} &&
        return false
    if T <: AbstractDict
        K, V = keytype(T), valtype(T)
        (K isa Type && K <: Enum) && return true
        return _interns(K, seen) || _interns(V, seen)
    end
    T <: Union{AbstractArray, AbstractSet} && return _interns(eltype(T), seen)
    T <: Tuple && return any(t -> _interns(Base.unwrapva(t), seen), T.parameters)
    isstructtype(T) || return false
    return any(t -> _interns(t, seen), fieldtypes(T))
end

# HTTP.jl v2 replaced the raw `Vector{UInt8}` request body (and `HTTP.payload`) with the
# `AbstractBody` hierarchy. Read the bytes without consuming the body cursor so the
# same request body can be read more than once (e.g. `.json` and `.form`). Responses may
# additionally retain their body as a raw `Vector{UInt8}` or `String` (v2 keeps byte/string
# bodies as-is so fixtures can inspect `response.body` directly), so handle those too.
#
# A VIEW of the body's bytes, never a copy (#327). Every reader used to start from its own
# `Vector{UInt8}` copy, and `text` made a second, so `payload(req)` -- or CSRF reading the form
# and then the JSON -- made about four transient copies: ~256 MB for one 64 MiB body. The
# parsers now read this view in place and copy only what they hand out.
#
# It must never reach `String(::Vector{UInt8})`: that constructor takes over the vector's memory
# and leaves the vector EMPTY, which here would erase the request body for every later reader.
# `_view_string` is the one sanctioned way to a `String`.
_body_view(::HTTP.EmptyBody) = UInt8[]
_body_view(body::HTTP.BytesBody) = body.data
_body_view(::Nothing) = UInt8[]
_body_view(body::AbstractVector{UInt8}) = body
_body_view(body::AbstractString) = codeunits(body)

# The body as a `String`: no copy when it already is one (a `String` body is stored as its code
# units), otherwise exactly one. Not `String(Vector{UInt8}(bytes))`: on Julia 1.12 that copies
# twice, because `String(::Vector)` still copies memory not allocated for a string.
_view_string(bytes::Base.CodeUnits{UInt8, String}) = bytes.s
_view_string(bytes::DenseVector{UInt8}) = GC.@preserve bytes unsafe_string(pointer(bytes), length(bytes))
_view_string(bytes::AbstractVector{UInt8}) = String(collect(bytes))

function _request_payload(req::HTTP.Request)
    payload = _body_view(req.body)
    return isempty(payload) ? nothing : payload
end

function _request_payload(res::HTTP.Response)
    payload = _body_view(res.body)
    return isempty(payload) ? nothing : payload
end

### Media types

# The media type of a `Content-Type` value: everything before the first `;`, trimmed and
# lowercased (RFC 9110 §8.3.1: type and subtype are case-insensitive; parameters follow `;`).
function _media_type(content_type::AbstractString) :: String
    i = findfirst(==(';'), content_type)
    mt = i === nothing ? content_type : SubString(content_type, 1, prevind(content_type, i))
    return lowercase(strip(mt))
end

"""
    is_json_media_type(content_type) :: Bool

Whether a `Content-Type` value names JSON: `application/json`, or any `application/*+json`
(`application/problem+json`, `application/vnd.api+json`), compared case-insensitively with
parameters such as `charset` ignored. An empty value -- no `Content-Type` -- is not JSON (#327).
"""
function is_json_media_type(content_type::AbstractString) :: Bool
    mt = _media_type(content_type)
    return mt == "application/json" || (startswith(mt, "application/") && endswith(mt, "+json"))
end

"""
    is_multipart_form_media_type(content_type) :: Bool

Whether a `Content-Type` value is `multipart/form-data`, compared case-insensitively with the
`boundary` and other parameters ignored.
"""
is_multipart_form_media_type(content_type::AbstractString) :: Bool =
    _media_type(content_type) == "multipart/form-data"

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
    return _view_string(_body_view(req.body))
end

function text(res::HTTP.Response) :: String
    return _view_string(_body_view(res.body))
end


"""
    formdata(request::HTTP.Request)

Read the html form data from the body of a HTTP.Request
"""
function formdata(req::HTTP.Request) :: Dict{String,String}
    # multipart/form-data is not urlencoded — parsing it here yields a garbage
    # key. Use `getfiles(req)` / `getpost(req)` (or `multipart(req)`) for multipart bodies.
    if is_multipart_form_media_type(HTTP.header(req, "Content-Type", ""))
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
# A fresh vector the caller owns: mutating it never touches the body other readers see.
function binary(req::HTTP.Request) :: Vector{UInt8}
    return Vector{UInt8}(_body_view(req.body))
end

function binary(res::HTTP.Response) :: Vector{UInt8}
    return Vector{UInt8}(_body_view(res.body))
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

Throws a `ValidationError` -- a `400` when raised in a handler -- when the body does not bind as
a `T`: not JSON, nested deeper than 512 arrays/objects (#314), or the wrong shape (#326). Its
message never quotes the body; the parse error is kept on `.cause`. Calling this on an
`HTTP.Response` is unchanged and rethrows the parse error itself: a response is not client input.

The body is client input, so it is always parsed with Nitro's read style, which never interns a
client string as a `Symbol` (#306): an enum field binds by name or by integer. A float field
must receive a finite value (#327): `1e999`, which JSON.jl reads as a `BigFloat` and would
convert to `Inf`, is rejected. A `T` that would bind a `Symbol` anywhere (see
`interns_client_strings`) is refused, and so is passing `style` or `allownan = true`; all three
are an `ArgumentError`.
"""
function json(req::HTTP.Request, class_type::Type{T}; kwargs...) where {T}
    haskey(kwargs, :style) && throw(ArgumentError(
        "json(req, T) parses client input with Nitro's read style (#306); `style` cannot be overridden"))
    # JSON.jl returns a `Float64` field straight from its number reader, without `lift`, so the
    # style's finite check cannot see a NaN that `allownan` let through (#327).
    get(kwargs, :allownan, false) === true && throw(ArgumentError(
        "json(req, T) never binds NaN or Infinity from client input (#327); `allownan` is refused"))
    interns_client_strings(T) && throw(ArgumentError("json(req, $T): " * _SYMBOL_REFUSED))
    payload = _request_payload(req)
    if isnothing(payload)
        return nothing
    end
    try
        return _parse_json_bounded(payload, class_type; style = NITRO_READ_STYLE, kwargs...)
    catch e
        # A body that does not bind is client input: a `ValidationError` (a 400), like the
        # `Json{T}` extractor answers the same body (#326). Rethrown raw it was a 500, and the
        # log line quoted the payload -- a parse `ArgumentError` echoes the offending bytes, so a
        # submitted password landed in the error log. The message here is value-free; the
        # original is kept on `.cause`, which no Nitro output path renders (#130).
        is_unrecoverable(e) && rethrow()
        e isa ValidationError && rethrow()
        throw(ValidationError("Could not bind the request body as $T", e))
    end
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
