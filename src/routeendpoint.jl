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

`false`, unless a `--trim` build has registered a route or a route's lifecycle middleware: then it
is redefined to `true`, so
inference folds [`RouteEndpoint`](@ref)'s branch either way and each build compiles one of its
two calls. The JIT never sees the `ccall`; the verifier never sees the dynamic call. The startup
banner reads it too (`_with_stdout`, `_stdout_color` in src/core/lifecycle.jl), for the two calls a
trimmed build cannot make there.
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
# The same for a route-owned `LifecycleMiddleware` type (#719, `route_lifecycle_entry` below).
const LIFECYCLE_EXPORTS = IdDict{Any,String}()
const ENDPOINT_EXPORTS_LOCK = ReentrantLock()     # guards both tables

# The first export of either kind redefines `_trimmed()`. Called under `ENDPOINT_EXPORTS_LOCK`.
_flip_trimmed!() = isempty(ENDPOINT_EXPORTS) && isempty(LIFECYCLE_EXPORTS) &&
    Core.eval(@__MODULE__, :(_trimmed() = true))

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
            _flip_trimmed!()
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

# ── The response's body type (docs/design/juliac-trim.md §3.7) ──────────────────────────────────
#
# `HTTP.Response{B}` is a UnionAll over its body, and `B` varies by route: a builder's `String` or
# `Vector{UInt8}`, `servecontent`'s `BytesBody` (a range is a view), a streamed file, an SSE stream.
# So a response that leaves a route chain is `HTTP.Response` at best, and every call on it that
# reads the body or rebuilds the response (`add_response_headers` keeps `B`) dispatches on `B` at
# run time: a dynamic call under the JIT, a call `juliac --trim` rejects. `with_response` is the
# closed dispatch over the bodies Nitro's own builders produce, in the style of `_error_response`.

# `servecontent`'s 206 over a byte source: `BytesBody(@view(source[a:b]))`.
const RangeBytes = SubArray{UInt8, 1, Vector{UInt8}, Tuple{UnitRange{Int64}}, true}
# `servecontent(req, ::IO)` over `open(path)`: `Res.file(req, path; stream = true)` and a mount's
# files over its threshold. HTTP.jl does not declare the type `public`; the name is canaried in
# test/http_internals_contract_tests.jl.
const StreamedFileBody = HTTP._SeekableResponseBody{IOStream}

"""
    with_response(f, resp::HTTP.Response, args...)

`f(resp, args...)`, with `resp` at its concrete type `HTTP.Response{B}` whenever `B` is a body
type Nitro builds: `String`, `Vector{UInt8}`, `HTTP.EmptyBody`, `HTTP.BytesBody` over a vector or
a range of one, a streamed file, an `HTTP.SSEStream`. The test on `B` is a closed set of `isa`s, so
each branch is a static call.

Any other body is a response an application built itself. Under the JIT it takes one dynamic call,
as every response did before; a trimmed image refuses it, since that call is exactly what it
cannot make. Add a branch here when a Nitro builder gains a body type; the guard in
test/response_type_tests.jl fails until it is.
"""
# `Vararg{Any,N}`, not a bare `args...`: Julia does not specialize a vararg tail it only passes on,
# and the splat into `f` is then a dynamic `_apply_iterate`.
function with_response(f::F, @nospecialize(resp::HTTP.Response), args::Vararg{Any,N}) where {F,N}
    resp isa HTTP.Response{String} && return f(resp, args...)
    resp isa HTTP.Response{Vector{UInt8}} && return f(resp, args...)
    resp isa HTTP.Response{HTTP.EmptyBody} && return f(resp, args...)
    resp isa HTTP.Response{HTTP.BytesBody{Vector{UInt8}}} && return f(resp, args...)
    resp isa HTTP.Response{HTTP.BytesBody{RangeBytes}} && return f(resp, args...)
    resp isa HTTP.Response{StreamedFileBody} && return f(resp, args...)
    resp isa HTTP.Response{HTTP.SSEStream} && return f(resp, args...)
    return _with_unlisted_body(f, resp, args...)
end

@noinline function _with_unlisted_body(f::F, @nospecialize(resp::HTTP.Response),
                                     args::Vararg{Any,N}) where {F,N}
    _trimmed() && throw(ArgumentError(
        "Nitro: a trimmed image serves only the response bodies Nitro builds; got a $(typeof(resp))"))
    return f(resp, args...)
end

# ── Lifecycle hooks (#719; docs/design/juliac-trim.md §3.4) ─────────────────────────────────────
#
# The registry holds lifecycle middleware of as many types as an app installs, so the call from
# `startserver`/`terminate` into each one's `startup`/`shutdown`/`stopped` cannot be resolved
# statically.
# `LifecycleEntry` is that call's erasure point, as `RouteEndpoint` is a route's. The two halves of
# the registry are registered at different times, so each gets the pointer it can get then:
# route-owned entries at top level, which under `juliac` is build time, through an exported thunk;
# serve-owned ones in `serve`, inside `main`, through a static `@cfunction` taken where the
# middleware's type is concrete, as `ServerHandle` takes the server's (src/context.jl).

"""
    LifecycleEntry

One registered [`LifecycleMiddleware`](@ref), behind one concrete type, for
`Service.route_lifecycle` and `Service.serve_lifecycle` (#719). `mw` is the object itself, which
dedup and promotion compare by `===`; [`startup`](@ref), [`shutdown`](@ref) and [`stopped`](@ref)
on the entry run that object's hooks.

**Under the JIT it is a direct call**, `startup(e.mw)`: one dynamic call per hook per server, as
before. **In a trimmed image it is a `ccall`**: through the thunk a `--trim` build exported for a
route-owned entry ([`route_lifecycle_entry`](@ref)), or through the `@cfunction` `serve` took for
a serve-owned one ([`serve_lifecycle_entry`](@ref)). An entry with neither has no code to call,
and running it is an error.
"""
mutable struct LifecycleEntry
    const mw   :: LifecycleMiddleware
    const sym  :: String        # an exported thunk's symbol: route-owned, `--trim` build; else ""
    const shim :: Ptr{Cvoid}    # a static `@cfunction`: serve-owned, trimmed image; else `C_NULL`
    @atomic thunk :: Ptr{Cvoid} # `sym`, looked up on first use
end

# The hook a foreign call asks for, as the `Cint` both kinds of pointer carry. `0`/`1` keep the
# meaning of the `up` flag this replaced; `2` is the post-drain hook (#161).
const _PHASE_SHUTDOWN = Cint(0)
const _PHASE_STARTUP  = Cint(1)
const _PHASE_STOPPED  = Cint(2)

# What both kinds of pointer call: the hook, at `L`. `startup`/`shutdown`/`stopped` already catch
# what a hook throws; this catch is for anything else, which must not unwind through the foreign
# frame (`EndpointFailure`, above).
function _lifecycle_call(lf::L, phase::Cint)::Any where {L<:LifecycleMiddleware}
    try
        return _lifecycle_direct(lf, phase)
    catch err
        return EndpointFailure(err)
    end
end

# The exported entry for a route-owned type `L`, in `RouteEndpoint`'s calling convention.
struct LifecycleThunk{L} end

function _lifecycle_thunk(::Type{L}, lf::Ptr{Cvoid}, phase::Cint, out::Ptr{Cvoid}) where {L}
    cell = unsafe_pointer_to_objref(out)::Base.RefValue{Any}
    cell[] = _lifecycle_call(unsafe_pointer_to_objref(lf)::L, phase)
    return nothing
end

function _export_lifecycle_thunk(::Type{L}, sym::String) where {L}
    # The exact signature, for `jl_extern_c` (see `_export_thunk`).
    Core.eval(@__MODULE__, :((::LifecycleThunk{$L})(lf::Ptr{Cvoid}, phase::Cint, out::Ptr{Cvoid}) =
                                 _lifecycle_thunk($L, lf, phase, out)))
    Base.Experimental.entrypoint(LifecycleThunk{L}(), (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
    Base._ccallable(sym, Cvoid, Tuple{LifecycleThunk{L}, Ptr{Cvoid}, Cint, Ptr{Cvoid}})
    return nothing
end

"""
    route_lifecycle_entry(mw::LifecycleMiddleware) -> LifecycleEntry

The entry `register_route_lifecycle!` (src/routerhof.jl) records. In a `--trim` build, where routes
register while the image is built, it exports a thunk for `mw`'s type on first sight, as
`RouteEndpoint` does for a chain; otherwise it has no pointer.
"""
function route_lifecycle_entry(mw::LifecycleMiddleware)
    L = typeof(mw)
    Base.JLOptions().trim == 0 && return LifecycleEntry(mw, "", C_NULL, C_NULL)
    sym = lock(ENDPOINT_EXPORTS_LOCK) do
        get!(LIFECYCLE_EXPORTS, L) do
            _flip_trimmed!()
            # Not `sym`: assigning the outer name inside these closures would box it (#364).
            stem = string("nitro_lifecycle_", length(LIFECYCLE_EXPORTS) + 1)
            _export_lifecycle_thunk(L, stem)
            stem
        end
    end
    return LifecycleEntry(mw, sym, C_NULL, C_NULL)
end

"""
    serve_lifecycle_entry(mw::LifecycleMiddleware) -> LifecycleEntry

The entry `register_serve_lifecycle!` records for a `serve(middleware = (…))` member, where `mw`'s
type is concrete. In a trimmed image it takes a static `@cfunction` pointer to the hooks at that
type, made at run time and never stored in an image (`ServerHandle`, src/context.jl).
"""
function serve_lifecycle_entry(mw::L) where {L<:LifecycleMiddleware}
    _trimmed() || return LifecycleEntry(mw, "", C_NULL, C_NULL)
    return LifecycleEntry(mw, "", @cfunction(_lifecycle_call, Any, (Ref{L}, Cint)), C_NULL)
end

function _lifecycle_fptr!(e::LifecycleEntry)::Ptr{Cvoid}
    p = @atomic :acquire e.thunk
    p == C_NULL || return p
    p = isempty(e.sym) ? C_NULL : _image_symbol(e.sym)
    p == C_NULL && throw(ErrorException(
        "Nitro: no code for this lifecycle middleware's hooks in this process. In a trimmed image, " *
        "register route middleware at top level and pass `serve(middleware = (…))` as a Tuple"))
    @atomic :release e.thunk = p      # racing first calls look up the same symbol
    return p
end

function _run_lifecycle(e::LifecycleEntry, phase::Cint)::Union{Nothing,InterruptException}
    _trimmed() || return _lifecycle_direct(e.mw, phase)
    result = if e.shim != C_NULL
        ccall(e.shim, Any, (Any, Cint), e.mw, phase)
    else
        out = Ref{Any}()
        ccall(_lifecycle_fptr!(e), Cvoid, (Any, Cint, Any), e.mw, phase, out)
        out[]
    end
    result isa EndpointFailure && throw(result.err)
    return result::Union{Nothing,InterruptException}
end

# The hook runner for a phase, called directly: the JIT's whole path, and the far side of a trimmed
# build's foreign call.
_lifecycle_direct(mw::LifecycleMiddleware, phase::Cint) =
    phase == _PHASE_STARTUP ? startup(mw) :
    phase == _PHASE_STOPPED ? stopped(mw) : shutdown(mw)

startup(e::LifecycleEntry) = _run_lifecycle(e, _PHASE_STARTUP)
shutdown(e::LifecycleEntry) = _run_lifecycle(e, _PHASE_SHUTDOWN)
stopped(e::LifecycleEntry) = _run_lifecycle(e, _PHASE_STOPPED)
