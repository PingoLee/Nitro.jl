module BodyParsers

using HTTP 
using JSON
using ..Util

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

function _request_payload(req::HTTP.Request)
    payload = HTTP.payload(req)
    if isnothing(payload) || isempty(payload)
        return nothing
    end
    return payload
end

function _request_payload(res::HTTP.Response)
    payload = res.body
    if isnothing(payload) || isempty(payload)
        return nothing
    end
    return payload
end

### Helper functions used to parse the body of a HTTP.Request object

"""
    text(request::HTTP.Request)

Read the body of a HTTP.Request as a String
"""
function text(req::HTTP.Request) :: String
    body = IOBuffer(HTTP.payload(req))
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
    body = text(req)
    if isnothing(body) || !occursin('=', body)
        return copy(EMPTY_FORM_DATA)
    end
    try
        return HTTP.queryparams(body)
    catch
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
    catch
        return copy(EMPTY_FORM_DATA)
    end
end


"""
    binary(request::HTTP.Request)

Read the body of a HTTP.Request as a Vector{UInt8}
"""
function binary(req::HTTP.Request) :: Vector{UInt8}
    body = IOBuffer(HTTP.payload(req))
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
    catch
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
    catch
        return nothing
    end
end

"""
    json(request::HTTP.Request, class_type::Type{T}; keyword_arguments...)

Read the body of a HTTP.Request as JSON with additional arguments for the read/serializer into a custom struct.
"""
function json(req::HTTP.Request, class_type::Type{T}; kwargs...) where {T}
    payload = _request_payload(req)
    if isnothing(payload)
        return nothing
    end
    return JSON.parse(IOBuffer(payload), class_type; kwargs...)
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
    catch
        return result
    end

    if isnothing(parts)
        return result
    end

    for part in parts
        name = part.name
        if !isnothing(part.filename) && !isempty(part.filename)
            file = FormFile(name, part.filename, part.contenttype, read(part.data))
            _multipart_append!(result, name, file)
        else
            value = String(read(part.data))
            _multipart_append!(result, name, value)
        end
    end

    return result
end

function _multipart_append!(dict, key::String, value)
    if haskey(dict, key)
        existing = dict[key]
        if existing isa Vector
            push!(existing, value)
        else
            dict[key] = [existing, value]
        end
    else
        dict[key] = value
    end
end

end # module BodyParsers
