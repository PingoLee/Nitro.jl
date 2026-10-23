# Included into `module Types` (src/types.jl), after `RouteResolution` and `RouteMiddleware`.
#
# One erasure point per route (#718). A route table holds chains and handlers of as many types
# as it has routes, so the call out of it cannot be resolved statically, and `juliac
# --trim=safe` rejects a call it cannot resolve. Tower/axum erase each route once, at the router
# (`BoxCloneService`); `RouteEndpoint` is that erasure here, for both halves of a route: the
# chain `compose` calls and the leaf the router terminal calls. docs/design/juliac-trim.md §3.2
# has the candidates that were measured and why this one was chosen.

"""
    RouteEndpoint(obj)

One route chain or one route handler, behind one concrete type (#718). Built once, at
registration, by `publish_route_middleware!` (the chain) and `registerhandler` (the leaf).

**Under the JIT it is a direct call**, `obj(req)`: the same one dynamic call per route that the
untyped table made before, and nothing more (docs/design/juliac-trim.md §4: the JIT build does not
pay for the trim).

**In a trimmed image it is a `ccall`**, which `juliac --trim=safe` accepts where it rejects the
dynamic call. Registration in a `--trim` build exports one thunk per chain type and request shape
under a C symbol (`Base._ccallable`), roots it (`Base.Experimental.entrypoint`), and flips
[`_trimmed`](@ref) to `true`. The image keeps the symbol but not a pointer to it, so the first
call looks the pointer up with `dlsym` and keeps it. The two `Base` internals are pinned by
test/juliac_internals_contract_tests.jl.

A trimmed image serves only routes registered while it was built (at top level), and only the
request shapes the transport builds (`EmptyRequest`, `BytesRequest`). Anything else is an error
there, never a silent dynamic call.
"""
mutable struct RouteEndpoint <: Function
    const obj :: Any
    const sym :: String                 # "" under the JIT: nothing was exported
    # A handler's endpoint with `format_response` folded in (`leaf_endpoint`); `nothing` for a
    # chain, which is never formatted.
    const formatted :: Union{Nothing, RouteEndpoint}
    @atomic empty_fptr :: Ptr{Cvoid}    # looked up on first use, in a trimmed image only
    @atomic bytes_fptr :: Ptr{Cvoid}
end

"""
    _trimmed() -> Bool

`false`, unless a `--trim` build has registered a route: then it is redefined to `true`, so
inference folds [`RouteEndpoint`](@ref)'s branch either way and each build compiles one of its
two calls. The JIT never sees the `ccall`; the verifier never sees the dynamic call.
"""
_trimmed() = false

# The two concrete requests `stream_handler` builds (src/core/transport.jl).
const EmptyRequest = HTTP.Request{HTTP.EmptyBody}
const BytesRequest = HTTP.Request{HTTP.BytesBody{Vector{UInt8}}}

# The exported entry for chain type `C` and request type `R`. `@ccallable` wants C argument types,
# so it takes three object pointers (the endpoint, the request, an output cell) and returns nothing.
struct EndpointThunk{C,R} end

# What the thunk hands back instead of a result when the call threw. An exception never unwinds
# through the `@ccallable` frame: it is caught on the far side and thrown again on this one, as
# itself, so `handlerequest` maps it exactly as it maps one from a direct call. Only its backtrace
# starts at the rethrow.
struct EndpointFailure
    err :: Any
end

function _endpoint_thunk(::Type{C}, ::Type{R}, ep::Ptr{Cvoid}, req::Ptr{Cvoid},
                         out::Ptr{Cvoid}) where {C,R}
    e = unsafe_pointer_to_objref(ep)::RouteEndpoint
    cell = unsafe_pointer_to_objref(out)::Base.RefValue{Any}
    cell[] = try
        (e.obj::C)(unsafe_pointer_to_objref(req)::R)
    catch err
        EndpointFailure(err)
    end
    return nothing
end

(::EndpointThunk{C,R})(ep::Ptr{Cvoid}, req::Ptr{Cvoid}, out::Ptr{Cvoid}) where {C,R} =
    _endpoint_thunk(C, R, ep, req, out)

# Chain or handler type => the stem of its exported symbols. `--trim` builds only.
const ENDPOINT_EXPORTS = IdDict{Any,String}()
const ENDPOINT_EXPORTS_LOCK = ReentrantLock()

function _export_thunk(::Type{C}, ::Type{R}, sym::String) where {C,R}
    # `jl_extern_c` finds the method by its EXACT signature, not by dispatch, so the concrete
    # method has to exist; the `where {C,R}` one above does not count.
    Core.eval(@__MODULE__, :((::EndpointThunk{$C,$R})(ep::Ptr{Cvoid}, req::Ptr{Cvoid}, out::Ptr{Cvoid}) =
                                 _endpoint_thunk($C, $R, ep, req, out)))
    Base.Experimental.entrypoint(EndpointThunk{C,R}(), (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}))
    Base._ccallable(sym, Cvoid, Tuple{EndpointThunk{C,R}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}})
    return nothing
end

# The symbol stem for `C`, exporting it on first sight. Only a `--trim` build exports: that is
# the build that runs this file's registration at build time and keeps only what it roots.
function _endpoint_symbol(::Type{C})::String where {C}
    Base.JLOptions().trim == 0 && return ""
    return lock(ENDPOINT_EXPORTS_LOCK) do
        get!(ENDPOINT_EXPORTS, C) do
            isempty(ENDPOINT_EXPORTS) && Core.eval(@__MODULE__, :(_trimmed() = true))
            sym = string("nitro_route_endpoint_", length(ENDPOINT_EXPORTS) + 1)
            _export_thunk(C, EmptyRequest, sym * "_e")
            _export_thunk(C, BytesRequest, sym * "_b")
            sym
        end
    end
end

function RouteEndpoint(obj::C) where {C}
    obj isa RouteEndpoint && return obj
    return RouteEndpoint(obj, _endpoint_symbol(C), nothing, C_NULL, C_NULL)
end

"""
    FormattedLeaf(handler)

A route handler with the serializer's `format_response` applied to what it returns. Behind its own
[`RouteEndpoint`](@ref), the handler's return type is concrete where `format_response` is called,
so the call resolves per route instead of on an `Any` in the serializer.
"""
struct FormattedLeaf{C} <: Function
    handler :: C
end

(f::FormattedLeaf)(req::HTTP.Request) = format_response(f.handler(req))

"""
    leaf_endpoint(handler) -> RouteEndpoint

The endpoint `registerhandler` puts on the router for `handler`: the handler itself, called as is
for `serialize = false`, and in `formatted` the same handler through [`FormattedLeaf`](@ref), which
the serializer calls instead ([`call_formatted`](@ref)). A trimmed image exports a thunk for each.
"""
function leaf_endpoint(obj::C) where {C}
    obj isa RouteEndpoint && return obj
    return RouteEndpoint(obj, _endpoint_symbol(C), RouteEndpoint(FormattedLeaf(obj)), C_NULL, C_NULL)
end

function (e::RouteEndpoint)(req::HTTP.Request)
    _trimmed() || return e.obj(req)
    return _call_exported(e, req)
end

"""
    call_formatted(e, req) -> HTTP.Response

The leaf call when the pipeline serializes: the handler and `format_response` in one call, through
`e.formatted`. Under the JIT that is one dynamic call per request where the serializer made two
(the handler, then `format_response` on its `Any` result); in a trimmed image it is a `ccall`.
"""
function call_formatted(e::RouteEndpoint, req::HTTP.Request)
    f = e.formatted
    f === nothing || return f(req)::HTTP.Response
    return _format_unregistered(e, req)
end

# A leaf endpoint built without its formatted half: `RouteEndpoint(f)` rather than
# `leaf_endpoint(f)`, as a test driving the terminal builds one. The JIT formats its result here,
# as the serializer did. A trimmed image refuses it: that call is the dynamic one
# `FormattedLeaf` exists to remove, and `_trimmed()` folds this branch away there.
@noinline function _format_unregistered(e::RouteEndpoint, req::HTTP.Request)
    _trimmed() && throw(ArgumentError("Nitro: a route handler endpoint has no formatted call; register routes with path()"))
    return format_response(e(req))::HTTP.Response
end

# The same call, for `compose`'s chain. A second method rather than the call above so the JIT's
# dynamic call has a site of its own, as the chain and the leaf had before #718: one shared site,
# alternating between a route's chain type and its handler type on every request, measured slower.
function call_chain(e::RouteEndpoint, req::HTTP.Request)
    _trimmed() || return e.obj(req)
    return _call_exported(e, req)
end

_call_exported(e::RouteEndpoint, req::EmptyRequest) =
    _ccall_endpoint(e, req, _endpoint_fptr!(e, true))
_call_exported(e::RouteEndpoint, req::BytesRequest) =
    _ccall_endpoint(e, req, _endpoint_fptr!(e, false))
_call_exported(::RouteEndpoint, ::HTTP.Request) =
    throw(ArgumentError("Nitro: a trimmed image serves only the request shapes the transport builds"))

# An exported symbol of the executable `juliac` built, or `C_NULL`. Through Julia's `jl_dlsym`
# (`Libdl.dlsym_e`) on the executable's own handle, not libc's `dlsym`: Windows has none, and
# `RTLD_DEFAULT` is not `C_NULL` everywhere.
_image_symbol(name::String)::Ptr{Cvoid} =
    Base.Libc.Libdl.dlsym_e(unsafe_load(cglobal(:jl_exe_handle, Ptr{Cvoid})), name)

function _endpoint_fptr!(e::RouteEndpoint, empty::Bool)::Ptr{Cvoid}
    p = empty ? (@atomic :acquire e.empty_fptr) : (@atomic :acquire e.bytes_fptr)
    p == C_NULL || return p
    p = _image_symbol(e.sym * (empty ? "_e" : "_b"))
    p == C_NULL && throw(ErrorException(
        "Nitro: no code for route endpoint `$(e.sym)` in this process. In a trimmed image, register " *
        "routes at top level; a request served while the image is being built cannot reach one"))
    # Racing first calls look up the same symbol, so whichever store lands is the right one.
    empty ? (@atomic :release e.empty_fptr = p) : (@atomic :release e.bytes_fptr = p)
    return p
end

function _ccall_endpoint(e::RouteEndpoint, req::HTTP.Request, p::Ptr{Cvoid})
    out = Ref{Any}()
    ccall(p, Cvoid, (Any, Any, Any), e, req, out)    # `Any` arguments are rooted for the call
    result = out[]
    result isa EndpointFailure && throw(result.err)
    return result
end

"""
    RouteNext(router)

The innermost layer of every route chain (#718). A chain is built once, at registration, so it
cannot close over the handler of a pipeline that does not exist yet. It reaches that handler,
which has one concrete type ([`PipelineHandler`](@ref)) whatever the pipeline's settings, through
the [`RouteResolution`](@ref) `compose` writes on the request before it calls the chain.

`router` is the registering app's. A stash another app's pipeline wrote on the same request object
(an `internalrequest(other_app, req)` from inside this chain) is refused rather than followed: it
would continue into that app's pipeline, whose terminal accepts its own stash, and serve that app's
leaf under this chain's guards. The same check `_dispatch_resolved` makes with its `router`.
"""
struct RouteNext <: Function
    router :: NitroRouter
end

function (n::RouteNext)(req::HTTP.Request)
    res = get(req.context, ROUTE_RESOLUTION_KEY, nothing)
    res isa RouteResolution && res.router === n.router && res.pipeline.has_next &&
        return res.pipeline.next(req)
    throw(ArgumentError("Nitro: a route middleware chain was continued outside its own app's pipeline"))
end

"""
    RouteChainRecord(entry, endpoint)

A route's chain as registration built it, with the `custommiddleware` entry it was built from.
`compose` serves `endpoint` only to a request whose snapshot holds that very `entry`, so a chain
and the middleware it was folded from never disagree (#718). See `publish_route_middleware!`.
"""
struct RouteChainRecord
    entry    :: RouteMiddleware
    endpoint :: RouteEndpoint
end
