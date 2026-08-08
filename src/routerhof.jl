module RouterHOF

using HTTP

using ..Util: join_url_path
using ..AppContext: ServerContext
using ..Types: Nullable, LifecycleMiddleware, CopyOnWriteDict, snapshot, cache!, publish!

export router, compose, genkey, process_middleware, HOFRouter, OuterRouter, InnerRouter

"""
    normalize_middleware(middleware::Vector) -> Vector{Function}

Flatten a middleware list to plain middleware functions, unwrapping each
`LifecycleMiddleware` to its `.middleware`. **Pure — registers nothing.** This is what the
per-request path (`setupmiddleware`, src/core.jl) uses.
"""
function normalize_middleware(middleware::Vector) :: Vector{Function}
    processed = Function[]
    for mw in middleware
        push!(processed, mw isa LifecycleMiddleware ? mw.middleware : mw)
    end
    return processed
end

"""
    register_lifecycle!(ctx::ServerContext, middleware::Vector) -> ServerContext

Register every `LifecycleMiddleware` in `middleware` for the server lifecycle, so
`startserver` runs its `on_startup` and `terminate` its `on_shutdown` (src/core.jl).

Call this ONLY from paths that run once per server or once per route registration: `serve`,
`router()`, `OuterRouter`, and `register_route`. **`internalrequest` deliberately does
not** (#68).

`internalrequest` never reaches `startup.` — that lives in `startserver` — so a lifecycle
middleware registered from there got an `on_shutdown` at the next `terminate` whose paired
`on_startup` had never run; and because `internalrequest` calls `setupmiddleware` per call,
that `push!` landed on an unsynchronized `Set` that `startup.`/`shutdown.` broadcast over.
Not fixing that with a lock is the point: the writer had no business existing.

Note also that "route registration" is not a synonym for "single-threaded startup": under
`revise=:lazy` a re-registration can run on a request-handling task, so the `Set` this writes
to is not *proven* free of concurrent writers. Closing that, along with the `Set`'s
unspecified iteration order, is tracked separately; what #68 removed was the per-request
writer.

Dedup is load-bearing and comes from `Set`: one shared `RateLimiter()` passed to N routes is
one registration, so its cleanup task starts once, not N times. `LifecycleMiddleware` is an
immutable struct, so `Set` dedups it structurally.
"""
function register_lifecycle!(ctx::ServerContext, middleware::Vector)
    for mw in middleware
        mw isa LifecycleMiddleware && push!(ctx.service.lifecycle_middleware, mw)
    end
    return ctx
end

"""
    process_middleware(ctx::ServerContext, middleware) -> Vector{Function}

Registration-path helper: [`register_lifecycle!`](@ref) then [`normalize_middleware`](@ref).
Semantics unchanged by #68 — the per-request path stopped calling *this*; it did not change
what this does.
"""
function process_middleware(ctx::ServerContext, middleware::Vector) :: Vector{Function}
    register_lifecycle!(ctx, middleware)
    return normalize_middleware(middleware)
end

# Do nothing if we have no middleware to append.
#
# Returns `nothing`, NOT `Function[]`, and that is load-bearing twice over: callers store the
# result into the `Nullable{Vector}` fields of `OuterRouter`/`InnerRouter`, and the guard in
# `(inner::InnerRouter)(http_method)` below reads those fields via `isnothing`. Return `[]`
# here and that guard becomes always-true, so every HOF route publishes a
# `(Function[], Function[])` entry into `custommiddleware` — which makes the table non-empty
# and installs `compose` for apps that have no per-route middleware at all.
function process_middleware(::ServerContext, ::Nothing) end


"""
This function is used to generate dictionary keys which lookup middleware for routes
"""
function genkey(http_method::String, path::String)::String
    return "$http_method|$path"
end

"""
This function is used to build up the middleware chain for all our endpoints
"""
function buildmiddleware(key::String, handler::Function, globalmiddleware::Vector,
                         custommiddleware::CopyOnWriteDict{Tuple}) :: Function

    # lookup the middleware for this path.
    #
    # `snapshot` is taken HERE — not by `compose`, not by the caller. This function runs on
    # EVERY request whenever `use_cache` is false: `serve(middleware=[...])`,
    # `internalrequest(...; middleware=[...])`, and every `revise=:lazy|:eager` session
    # (serve injects `ReviseHandler`). A snapshot hoisted to compose time would freeze the
    # route table for the life of the server, so routes registered later — Revise re-running
    # `urlpatterns` — would silently lose their middleware, with no error.
    #
    # Taking the wrapper rather than a pre-snapshotted `Dict` is the point: it leaves no
    # `snapshot(...)` expression at any call site for a future refactor to lift out of the
    # request path. See `CopyOnWriteDict` (src/types.jl) for why this read needs no lock.
    routermiddleware, routemiddleware = get(snapshot(custommiddleware), key, (nothing, nothing))

    # sanitize outputs (either value can be nothing)
    routermiddleware = isnothing(routermiddleware) ? [] : routermiddleware
    routemiddleware = isnothing(routemiddleware) ? [] : routemiddleware

    # initialize our middleware layers
    layers::Vector{Function} = [handler]

    # append the middleware in reverse order (so when we reduce over it, it's in the correct order)
    append!(layers, routemiddleware)
    append!(layers, routermiddleware)
    append!(layers, globalmiddleware)

    # combine all the middleware functions together
    return reduce(|>, layers)
end

"""
This function dynamically determines which middleware functions to apply to a request at runtime. 
If router or route specific middleware is defined, then it's used instead of the globally defined
middleware. 
"""
function compose(router::HTTP.Router, globalmiddleware::Vector,
                 custommiddleware::CopyOnWriteDict{Tuple},
                 middleware_cache::CopyOnWriteDict{Function})
    use_cache = isempty(globalmiddleware)
    return function (handler)
        # NOTE: `middleware_cache` is captured as an *object*; `snapshot` is called per
        # request below. Hoisting the `snapshot` call out to here would freeze the table at
        # compose time and silently disable caching — every request would rebuild its chain.
        # `custommiddleware` is captured the same way and for the same reason; it is
        # snapshotted per call inside `buildmiddleware` — see its own NOTE.
        return function (req::HTTP.Request)

            innerhandler, path, _ = HTTP.Handlers.gethandler(router, req)

            # Check if the current request matches one of our predefined routes 
            if innerhandler !== nothing

                # Check if we already have a cached middleware function for this specific route.
                # Skip cache when per-call global middleware is present: caching would bake in
                # caller-specific settings (e.g. catch_errors=false) and corrupt future requests.
                key = genkey(req.method, path)
                if use_cache
                    # One acquire-load, then a lookup on a table no writer will ever mutate.
                    # See `CopyOnWriteDict` (src/types.jl) for why this read needs no lock.
                    func = get(snapshot(middleware_cache), key, nothing)
                    if !isnothing(func)
                        return func(req)
                    end
                end

                # Combine all the middleware functions together
                strategy = buildmiddleware(key, handler, globalmiddleware, custommiddleware)

                # Warmup only. Reaching here with `use_cache` means the key was absent from
                # this request's snapshot, so `cache!` (first-writer-wins, under the lock) *is*
                # the second half of the double check. The old unlocked `haskey` pre-check was
                # a deliberate lock-avoidance optimization — it skipped the lock when another
                # thread published between the read and here — traded away on purpose: it was
                # a racy read, and the lock it avoided is warmup-bounded with a short critical
                # section.
                use_cache && cache!(middleware_cache, key, strategy)

                return strategy(req)
            end
    
            return handler(req)
        end
    end
end


"""
This functions assists registering routes with a specific prefix.
You can optionally assign tags either at the prefix and/or route level which
are used to group and organize the autogenerated documentation
"""
function router(ctx::ServerContext, prefix::String="";
    tags::Vector{String}=Vector{String}(),
    middleware::Nullable{Vector}=nothing)

    # ensure we collect & process any lifecycle-middleware functions
    router_middleware = process_middleware(ctx, middleware)

    return OuterRouter(ctx, prefix, tags, router_middleware)
end


"""
Abstract supertype for higher-order function (HOF) routers in Nitro.

This type serves as the base for `OuterRouter` and `InnerRouter`, enabling composable routing patterns
with features like prefixes, middleware, tags, intervals, and cron jobs. HOF routers allow building
nested route configurations by chaining callable instances.
"""
abstract type HOFRouter end

"""
This struct represents the data passed to the top level "router()" call.
These properties can be shared bewteen any other endpoints that reuse the router

ex.) 

@get router("/repeat/one", interval = 1, tags=["repeat"]) function(req)
    return "one"
end

The router() function itself can be passed to routes and returns the OuterRouter struct
"""
struct OuterRouter <: HOFRouter
    ctx::ServerContext
    prefix::String
    tags::Vector{String}
    middleware::Nullable{Vector}
end

function (outer::OuterRouter)(
    path=nothing;
    tags::Vector{String}=Vector{String}(),
    middleware::Nullable{Vector}=nothing)

    # ensure we collect & process any lifecycle-middleware functions
    processed_middleware = process_middleware(outer.ctx, middleware)

    return InnerRouter(outer.ctx, outer, path, tags, processed_middleware)
end


"""
The InnerRouter struct represents the returned function from the outer router, that
lets you override properties on a route by route basis.

ex.)

repeat = router("/repeat", interval = 1, tags=["repeat"])

@get repeat("/one") function(req)
    return "one"
end

The "repeat()" function returns the InnerRouter function

"""
struct InnerRouter <: HOFRouter
    ctx::ServerContext
    outer::OuterRouter
    path::Union{Nothing, String}
    tags::Vector{String}
    middleware::Nullable{Vector}
end

function (inner::InnerRouter)(http_method::String)

    # Pull out the "router" level information 
    outer = inner.outer

    final_path = !isnothing(inner.path) ? join_url_path(outer.prefix, inner.path) : join_url_path(outer.prefix, "")

    if !(isnothing(outer.middleware) && isnothing(inner.middleware))
        publish!(inner.ctx.service.custommiddleware,
                 genkey(http_method, final_path),
                 (outer.middleware, inner.middleware))
    end



    return final_path
end



end