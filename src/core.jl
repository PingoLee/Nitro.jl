module Core

using Base: @kwdef
using HTTP
using HTTP: Router
using Sockets
using JSON
using Base
using Dates
using Reexport
using DataStructures: CircularDeque
import Base.Threads: lock, nthreads
import ..WAS_LOADED_AFTER_REVISE

include("errors.jl");       @reexport using .Errors
include("util.jl");         @reexport using .Util
include("types.jl");        @reexport using .Types 
include("crypto.jl");       @reexport using .Crypto
include("cookies.jl");      @reexport using .Cookies
include("constants.jl");    @reexport using .Constants
include("context.jl");      @reexport using .AppContext

function getparams end
function getquery end
function getsession end
function setsession! end
function getip end
function setip! end

include("handlers.jl");     @reexport using .Handlers
include("middleware.jl");   @reexport using .Middleware
include("routerhof.jl");    @reexport using .RouterHOF
include("reflection.jl");   @reexport using .Reflection
include("extractors.jl");   @reexport using .Extractors
include("response.jl");     @reexport using .Res
include("routing.jl");      @reexport using .Routing

export start, serve, serveparallel, terminate,
    internalrequest, staticfiles, dynamicfiles, spafiles,
    getparams, getquery, getsession, setsession!, getip, setip!, payload

const REQUEST_JSON_CACHE_KEY = :__nitro_request_json
const REQUEST_FORM_CACHE_KEY = :__nitro_request_form
const REQUEST_INPUT_CACHE_KEY = :__nitro_request_input

function request_cache!(builder::Function, req::HTTP.Request, key::Symbol)
    if haskey(req.context, key)
        return req.context[key]
    end

    value = builder()
    req.context[key] = value
    return value
end

function merge_request_input!(merged::Dict{String,Any}, source)
    if source isa AbstractDict
        for (key, value) in pairs(source)
            merged[string(key)] = value
        end
    end
    return merged
end

function request_input(req::HTTP.Request) :: Dict{String,Any}
    return request_cache!(req, REQUEST_INPUT_CACHE_KEY) do
        merged = Dict{String,Any}()
        merge_request_input!(merged, req.query)
        merge_request_input!(merged, req.json)
        merge_request_input!(merged, req.form)
        merge_request_input!(merged, req.params)
        merged
    end
end

"""
Extend HTTP.Request to provide DX-friendly shorthand access to common properties:
- `req.params`: Returns path parameters
- `req.query`: Returns query parameters 
- `req.session`: Returns the session dictionary from context (if present)
- `req.user`: Returns the authenticated user from context (if present)
- `req.ip`: Returns the caller's IP address from context
- `req.json`: Returns the parsed JSON body (cached per request)
- `req.form`: Returns parsed form data (cached per request)
- `req.input`: Returns merged request input (params > form > json > query)
"""
function Base.getproperty(req::HTTP.Request, sym::Symbol)
    if sym === :params
        return HTTP.getparams(req)
    elseif sym === :query
        return Types.queryvars(req)
    elseif sym === :json
        return request_cache!(req, REQUEST_JSON_CACHE_KEY) do
            Types.jsonbody(req)
        end
    elseif sym === :form
        return request_cache!(req, REQUEST_FORM_CACHE_KEY) do
            Types.formbody(req)
        end
    elseif sym === :input || sym === :data
        return request_input(req)
    elseif sym === :session
        return Base.get(req.context, :session, nothing)
    elseif sym === :user
        return Base.get(req.context, :user, nothing)
    elseif sym === :ip
        return Base.get(req.context, :ip, nothing)
    else
        return getfield(req, sym)
    end
end

"""
    getparams(req::HTTP.Request) -> Dict{String, String}

Returns the path parameters for the request.
"""
getparams(req::HTTP.Request) = HTTP.getparams(req)

"""
    getquery(req::HTTP.Request) -> Dict{String, String}

Returns the query parameters for the request.
"""
getquery(req::HTTP.Request) = HTTP.queryparams(req)

"""
    getsession(req::HTTP.Request) -> Union{Dict{String,Any}, Nothing}

Returns the session dictionary from the request context, if present.
"""
getsession(req::HTTP.Request) = Base.get(req.context, :session, nothing)

"""
    setsession!(req::HTTP.Request, val::Dict{String,Any})

Assigns the session dictionary to the request context.
"""
setsession!(req::HTTP.Request, val) = (req.context[:session] = val)

"""
    getip(req::HTTP.Request) -> Union{Sockets.IPAddr, Nothing}

Returns the caller's IP address from the request context, if present.
"""
getip(req::HTTP.Request) = Base.get(req.context, :ip, nothing)

"""
    setip!(req::HTTP.Request, val::Sockets.IPAddr)

Assigns the caller's IP address to the request context.
"""
setip!(req::HTTP.Request, val) = (req.context[:ip] = val)

"""
    payload(req::HTTP.Request) -> Dict{String, Any}

Returns a merged dictionary containing the JSON body, form data, and query parameters 
from the incoming request.
"""
function payload(req::HTTP.Request)::Dict{String, Any}
    return req.input
end

end # module Core
