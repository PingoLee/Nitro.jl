module BodyParsers

using HTTP 
using JSON
using ..Util

export text, binary, json, formdata

const EMPTY_FORM_DATA = Dict{String,String}()

function _request_payload(req::HTTP.Request)
    payload = HTTP.payload(req)
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


"""
    binary(request::HTTP.Request)

Read the body of a HTTP.Request as a Vector{UInt8}
"""
function binary(req::HTTP.Request) :: Vector{UInt8}
    body = IOBuffer(HTTP.payload(req))
    return eof(body) ? UInt8[] : readavailable(body)
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

"""
    json(request::HTTP.Request, class_type::Type{T}; keyword_arguments...)

Read the body of a HTTP.Request as JSON with additional arguments for the read/serializer into a custom struct.
"""
function json(req::HTTP.Request, class_type::Type{T}; kwargs...) where {T}
    payload = _request_payload(req)
    if isnothing(payload)
        return nothing
    end
    try
        return JSON.parse(IOBuffer(payload), class_type; kwargs...)
    catch
        return nothing
    end
end

end # module BodyParsers
