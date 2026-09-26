module Handlers
using HTTP
using ..Types: Nullable
using ..Constants: SPECIAL_METHODS, TYPE_ALIASES
# `getcontext` and `_upgrade_websocket!` are forward declarations in src/core.jl, above this
# file's include -- the stub block exists precisely so submodules can bind Core names at include
# time.
using ...Core: getcontext, _upgrade_websocket!

export select_handler, first_arg_type

# Union type of supported Handlers
const HandlerArgType = Union{HTTP.Request, HTTP.WebSockets.WebSocket, HTTP.Stream}


""" 
Determine how to call each handler based on the arguments it takes.

These branches are hardcoded because this invoker code is called on each and every 
request. This is a performance critical path and should be as fast as possible.

`parameters` is a `Tuple`, not a `Vector` (#37): `create_param_parser` builds it as a
concrete tuple so that `func(arg, parameters...)` splats statically-typed values into a
statically-known arity. Widening this back to `Vector` reintroduces the `Vector{Any}`
boxing on every parameterized request — nitro-core §7.
"""
function get_invoker_strategy(has_ctx_kwarg::Bool, has_req_kwarg::Bool, has_path_params::Bool, no_args::Bool)
    if no_args
        if has_req_kwarg && has_ctx_kwarg
            return function (func::Function, _::HandlerArgType, req::HTTP.Request, _::Nullable{Tuple})
                func(; request=req, context=getcontext(req))
            end
        elseif has_req_kwarg
            return function (func::Function, _::HandlerArgType, req::HTTP.Request, _::Nullable{Tuple})
                func(; request=req)
            end
        elseif has_ctx_kwarg
            return function (func::Function, _::HandlerArgType, req::HTTP.Request, _::Nullable{Tuple})
                func(; context=getcontext(req))
            end
        else
            return function (func::Function, _::HandlerArgType, _::HTTP.Request, _::Nullable{Tuple})
                func()
            end
        end
    elseif has_path_params
        if has_req_kwarg && has_ctx_kwarg
            return function (func::Function, arg::HandlerArgType, req::HTTP.Request, parameters::Nullable{Tuple})
                func(arg, parameters...; request=req, context=getcontext(req))
            end
        elseif has_req_kwarg
            return function (func::Function, arg::HandlerArgType, req::HTTP.Request, parameters::Nullable{Tuple})
                func(arg, parameters...; request=req)
            end
        elseif has_ctx_kwarg
            return function (func::Function, arg::HandlerArgType, req::HTTP.Request, parameters::Nullable{Tuple})
                func(arg, parameters...; context=getcontext(req))
            end
        else
            return function (func::Function, arg::HandlerArgType, _::HTTP.Request, parameters::Nullable{Tuple})
                func(arg, parameters...)
            end
        end
    else
        if has_req_kwarg && has_ctx_kwarg
            return function (func::Function, arg::HandlerArgType, req::HTTP.Request, _::Nullable{Tuple})
                func(arg; request=req, context=getcontext(req))
            end
        elseif has_req_kwarg
            return function (func::Function, arg::HandlerArgType, req::HTTP.Request, _::Nullable{Tuple})
                func(arg; request=req)
            end
        elseif has_ctx_kwarg
            return function (func::Function, arg::HandlerArgType, req::HTTP.Request, _::Nullable{Tuple})
                func(arg; context=getcontext(req))
            end
        else
            return function (func::Function, arg::HandlerArgType, _::HTTP.Request, _::Nullable{Tuple})
                func(arg)
            end
        end
    end
end



"""
    select_handler(::Type{T})

This base case, returns a handler for `HTTP.Request` objects.
"""
function select_handler(::Type{T}, has_ctx_kwarg::Bool, has_req_kwarg::Bool, has_path_params::Bool; no_args=false) where {T}
    invoker = get_invoker_strategy(has_ctx_kwarg, has_req_kwarg, has_path_params, no_args)
    function (req::HTTP.Request, func::Function; parameters::Nullable{Tuple}=nothing)
        invoker(func, req, req, parameters)
    end
end

"""
    select_handler(::Type{HTTP.Stream})

Returns a handler for `HTTP.Stream` types
"""
function select_handler(::Type{HTTP.Stream}, has_ctx_kwarg::Bool, has_req_kwarg::Bool, has_path_params::Bool; no_args=false)
    invoker = get_invoker_strategy(has_ctx_kwarg, has_req_kwarg, has_path_params, no_args)
    function (req::HTTP.Request, func::Function; parameters::Nullable{Tuple}=nothing)
        invoker(func, req.context[:stream], req, parameters)
    end
end

"""
    select_handler(::Type{HTTP.WebSockets.WebSocket})

Returns a handler for `HTTP.WebSockets.WebSocket`types
"""
function select_handler(::Type{HTTP.WebSockets.WebSocket}, has_ctx_kwarg::Bool, has_req_kwarg::Bool, has_path_params::Bool; no_args=false)
    invoker = get_invoker_strategy(has_ctx_kwarg, has_req_kwarg, has_path_params, no_args)
    function (req::HTTP.Request, func::Function; parameters::Nullable{Tuple}=nothing)
        # The handshake, the proxy-aware Origin check and a refusal's logging live in
        # core/transport.jl (#374).
        _upgrade_websocket!(ws -> invoker(func, ws, req, parameters), req)
    end
end

"""
first_arg_type(method::Method, httpmethod::String)

Determine the type of the first argument of a given method.
If the `httpmethod` is in `Constants.SPECIAL_METHODS`, the function will return the 
corresponding type from `TYPE_ALIASES` if it exists, or `Type{HTTP.Request}` as a default.
Otherwise, it will return the type of the second field of the method's signature.
"""
function first_arg_type(method::Method, httpmethod::String) :: Type
    if httpmethod in SPECIAL_METHODS
        return get(TYPE_ALIASES, httpmethod, HTTP.Request)
    else
        # either grab the first argument type or default to HTTP.Request
        field_types = fieldtypes(method.sig)
        return length(field_types) < 2 ? HTTP.Request : field_types[2]
    end
end


end