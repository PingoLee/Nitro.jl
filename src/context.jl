module AppContext
import Base: @kwdef, wait, close, isopen
import Base.Threads: ReentrantLock
using HTTP
using HTTP: Server, Router
using ..Types
# Unexported from `Types` on purpose: `CopyOnWriteDict` is internal plumbing for `compose`,
# so it is named explicitly here rather than widened onto `Core`'s reexport surface.
using ..Types: CopyOnWriteDict
using ..Constants: SHUTDOWN_TIMEOUT_SECONDS

export ServerContext, EagerReviseService, Service, wait, close, isopen
export set_extension!, get_extension, delete_extension!, has_extension



@kwdef struct EagerReviseService
    task::Task
    done::Ref{Bool}
end

function Base.close(revise_service::EagerReviseService)
    revise_service.done[] = true
end

@kwdef struct Service
    server              :: Ref{Nullable{Server}}    = Ref{Nullable{Server}}(nothing)
    router              :: Router                   = Router()
    custommiddleware    :: CopyOnWriteDict{Tuple}   = CopyOnWriteDict{Tuple}()
    named_routes        :: Dict{String, String}     = Dict{String, String}()
    middleware_cache    :: CopyOnWriteDict{Function} = CopyOnWriteDict{Function}()
    external_url        :: Ref{Nullable{String}}    = Ref{Nullable{String}}(nothing)
    prefix              :: Ref{Nullable{String}}    = Ref{Nullable{String}}(nothing)
    eager_revise        :: Ref{Nullable{EagerReviseService}} = Ref{Nullable{EagerReviseService}}(nothing)
    named_routes_lock     :: ReentrantLock          = ReentrantLock()
    # Lifecycle middleware, split by the SCOPE that declared it (#82). The two halves have
    # genuinely different lifetimes, and collapsing them into one collection is what made
    # `serve(); terminate(); serve()` silently drop every route-level startup hook:
    #
    #   `route_lifecycle` — declared by the CONTEXT, at `urlpatterns()`/`router()` time, once.
    #       Nothing re-adds these on a second `serve()`, because routes are not re-registered.
    #       Survives `terminate()`; cleared only by replacing the context (`resetstate()`).
    #
    #   `serve_lifecycle` — declared by THIS SERVER RUN, from the `serve(middleware = ...)`
    #       list, on every `serve()`. Cleared by `terminate()`, or `serve(middleware=[A]);
    #       terminate(); serve(middleware=[B])` would start `A`'s lifecycle again as well.
    #
    # This is the Spring application-context distinction: the registry is a *declaration*, not
    # a consumable, and a declaration belongs to whatever owns it. No framework clears its
    # lifecycle registry wholesale on stop — Spring closes the context and you build a new one,
    # ASP.NET disposes the `IHost`, an OTP child spec outlives its supervisor terminating.
    #
    # `Vector`, not `Set`, and guarded by `lifecycle_lock` (#74). Broadcasting `startup.`/
    # `shutdown.` over a `Set` collected it in hash order, and `LifecycleMiddleware` is an
    # immutable struct whose fields are closures — heap objects — so the order varied run to
    # run. Teardown is now LIFO: startup in registration order, shutdown in its exact reverse,
    # matching Spring's `SmartLifecycle` phases, ASP.NET Core's `IHostedService`, OTP
    # supervisors, ASGI lifespan, and `defer`/`atexit`. Nobody ships FIFO teardown, and nobody
    # should ship an unspecified one.
    #
    # Dedup moves from `Set` to an `∉` guard in `register_*_lifecycle!` and stays load-bearing:
    # one shared `RateLimiter()` passed to N routes must start its cleanup task once, not N
    # times. Swapping the container without that guard would regress it silently.
    #
    # One lock for both halves — they are always read together, and the asymmetry #74 points at
    # (`named_routes` has `named_routes_lock`, `extensions` has `extensions_lock`) is the
    # convention here.
    route_lifecycle       :: Vector{LifecycleMiddleware} = LifecycleMiddleware[]
    serve_lifecycle       :: Vector{LifecycleMiddleware} = LifecycleMiddleware[]
    lifecycle_lock        :: ReentrantLock          = ReentrantLock()
    cookies               :: Ref{CookieConfig}      = Ref{CookieConfig}(CookieConfig())
    extensions            :: Dict{Symbol, Any}      = Dict{Symbol, Any}()
    extensions_lock       :: ReentrantLock          = ReentrantLock()
    shutdown_timeout      :: Ref{Float64}           = Ref{Float64}(SHUTDOWN_TIMEOUT_SECONDS)
end

@kwdef struct ServerContext
    service :: Service          = Service()    
    mod     :: Nullable{Module} = nothing
    app_context :: Ref{Any}     = Ref{Any}(missing) # This stores a reference to an Context{T} object
end

Base.isopen(service::Service)   = !isnothing(service.server[]) && isopen(service.server[])
Base.wait(service::Service)     = !isnothing(service.server[]) && wait(service.server[])

"""
    _shutdown_server(server::Server; timeout::Real) -> Bool

Bounded graceful shutdown of an `HTTP.Server`, modeled on Go's `http.Server.Shutdown(ctx)`:
stop accepting, let in-flight work finish for at most `timeout` seconds, then cut whatever
is left. Returns `true` when the graceful drain finished on its own, `false` when it had to
be forced.

`HTTP.close(::Server)` already releases the **listening socket first**, so the port is freed
either way and the timeout only ever escalates *connection* teardown. What `close` does not
bound is the drain that follows: it loops on `HTTP._close_idle_conns!`, which force-closes
only `IDLE` connections (and `NEW` ones older than 5s) and returns `true` only once nothing
is tracked at all. A connection whose handler is still running stays `ACTIVE` for that
handler's whole lifetime — and HTTP 2.4 declares `_ConnState.HIJACKED` but never assigns it,
so a WebSocket, SSE, or STREAM handler pins its connection `ACTIVE` forever and that loop
never terminates. `terminate()` called from *inside* a handler is the same deadlock against
its own connection.

Overlapping `close` and `forceclose` is safe: `_begin_shutdown!` and `_close_listener!` are
lock-guarded and idempotent, and Reseau documents a repeated `close` on a connection as a
no-op.

The drain task is *not* waited on after the force. A handler blocked on its own socket
unwinds as soon as `forceclose` tears the transport down, and the task exits within
milliseconds. A handler blocked on something else — an app lock, an `Event`, a long `sleep` —
never unwinds, so its drain task keeps polling for the life of the process. That is a bounded
per-forced-shutdown cost (one task in a backoff loop, capped at a 0.5s poll), and it can hold
neither the listening socket, which is released before this function returns, nor the server
handle, which the caller releases. Waiting on it instead would add the whole grace period
again to every forced shutdown and still not collect it.
"""
function _shutdown_server(server::Server; timeout::Real)::Bool
    timeout >= 0 || throw(ArgumentError("`timeout` must be >= 0 seconds, got $timeout"))

    # `HTTP.close` and `HTTP.forceclose` both call `wait(server)`, which rethrows a serve task
    # that already died (an accept-loop error is rethrown, not swallowed). Tolerate exactly
    # that — a shutdown must still be able to finish over a server that is already broken, and
    # letting it escape would stop the caller clearing its own handle.
    #
    # Everything else must stay loud. A bare `catch` here would demote structural breakage —
    # an HTTP upgrade renaming `forceclose`, say — to a debug line, silently skipping the
    # force-close and quietly reinstating the unbounded hang this function exists to prevent.
    _expected(err) = err isa TaskFailedException

    # The serve task's own failure is only logged by the *blocking* `startserver` path, so for
    # `async=true` this is the first and only place it gets reported. `maxlog=1` keeps a
    # repeatedly-terminated broken server from flooding.
    _report(err, what) =
        @warn "Nitro: $what ran against a serve task that had already failed" exception=err maxlog=1

    # Documented opt-out of the graceful phase.
    if iszero(timeout)
        try
            HTTP.forceclose(server)
        catch err
            _expected(err) || rethrow()
            _report(err, "force-close")
        end
        return false
    end

    drain = Threads.@spawn begin
        try
            close(server)
        catch err
            # Rethrowing here would *hide* the error: nothing ever fetches this task, so a
            # failed task is silent. Log instead, at a level that matches the cause.
            if _expected(err)
                _report(err, "graceful shutdown")
            else
                @error "Nitro: graceful server shutdown failed unexpectedly" exception=(err, catch_backtrace())
            end
        end
    end

    timedwait(() -> istaskdone(drain), Float64(timeout); pollint = 0.05) === :ok && return true

    @warn "Nitro: server did not drain within $(timeout)s — force-closing the remaining " *
          "connections. Long-lived WebSocket/SSE/STREAM handlers are the usual cause: they hold " *
          "their connection for the handler's whole lifetime, so the graceful drain has nothing " *
          "to wait for. Set `serve(shutdown_timeout = …)` or `terminate(timeout = …)` to tune this."

    try
        HTTP.forceclose(server)
    catch err
        _expected(err) || rethrow()
        _report(err, "force-close")
    end

    # Deliberately do NOT wait on `drain` — see the docstring. Briefly: the case that reaches
    # this branch is often a handler that `forceclose` cannot unblock, so waiting would cost
    # the whole grace period again and still not collect the task.
    return false
end

"""
    close(service::Service; timeout = service.shutdown_timeout[])

Shut the service's HTTP server down within `timeout` seconds (see `_shutdown_server`) and
release the handle.
"""
function Base.close(service::Service; timeout::Real = service.shutdown_timeout[])
    server = service.server[]
    if !isnothing(server)
        _shutdown_server(server; timeout)
        # Drop the handle — a closed `HTTP.Server` can never be restarted, so keeping it only
        # lets `serve()`'s already-serving guard mistake a corpse for a live listener.
        #
        # Compare-and-clear, NOT an unconditional nil. `HTTP.close` releases the listener up
        # front, so `isopen(service)` goes false while the drain is still running and a
        # concurrent `serve()` is admitted — legitimately, the port is free by then. Clearing
        # blindly afterwards would strand *that* server: live, listening, and unreachable from
        # `terminate()`, which is precisely the leak this whole change exists to remove.
        service.server[] === server && (service.server[] = nothing)
    end
    !isnothing(service.eager_revise[]) && close(service.eager_revise[])
    return nothing
end

function set_extension!(ctx::ServerContext, key::Symbol, value)
    lock(ctx.service.extensions_lock) do
        ctx.service.extensions[key] = value
    end
    return value
end

function get_extension(ctx::ServerContext, key::Symbol, default=nothing)
    lock(ctx.service.extensions_lock) do
        return Base.get(ctx.service.extensions, key, default)
    end
end

function delete_extension!(ctx::ServerContext, key::Symbol)
    lock(ctx.service.extensions_lock) do
        if haskey(ctx.service.extensions, key)
            delete!(ctx.service.extensions, key)
        end
    end
    return nothing
end

function has_extension(ctx::ServerContext, key::Symbol)
    lock(ctx.service.extensions_lock) do
        return haskey(ctx.service.extensions, key)
    end
end


# @eval begin
#     """
#         ServerContext(ctx::ServerContext; kwargs...)

#     Create a new `ServerContext` object by copying an existing one and optionally overriding some of its fields with keyword arguments.
#     """
#     function ServerContext(ctx::ServerContext; $([Expr(:kw ,k, :(ctx.$k)) for k in fieldnames(ServerContext)]...))
#         return ServerContext($(fieldnames(ServerContext)...))
#     end
# end

end
