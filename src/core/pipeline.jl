# ── Middleware pipeline assembly ────────────────────────────────────────────────
# Builds the per-request chain, and runs one request through it in-process.
# Included into `module Core` by src/core.jl — not a submodule; see the hub for why.

# Outermost wrapper that seeds the per-request context with the application
# context (`serve(context = ...)`), so `getcontext(req)` works everywhere in the
# pipeline — global/custom middleware, per-route middleware, and handlers alike.
# Runs before any other middleware, so the app context is visible from the very
# first hook a request passes through.
function _app_context_seed(ctx::ServerContext)
    return function(handler::Function)
        return function(req::HTTP.Request)
            req.context[REQUEST_CONTEXT_KEY] = ctx.app_context[]
            return handler(req)
        end
    end
end

function setupmiddleware(ctx::ServerContext; middleware::Vector=[], serialize::Bool=true, catch_errors::Bool=true, show_errors::Bool=true, access_log=false, access_log_query::Bool=false)::Function
    raw_middleware = reverse(middleware)
    # `normalize_middleware`, NOT `process_middleware`: this runs once per `serve` but ONCE
    # PER CALL from `internalrequest`, so it must have no registration side effect. `serve`
    # registers explicitly, just before it calls this. (#68)
    processed_middleware = normalize_middleware(raw_middleware)

    global_prefix_middleware = !isnothing(ctx.service.prefix[]) ? [PrefixStripMiddleware(ctx.service.prefix[])] : []
    serializer = serialize ? [DefaultSerializer(catch_errors; show_errors)] : []
    # Accept `true` to enable; `nothing`/`false` (or the old logfmt value) disable it.
    access_log_middleware = access_log === true ? [AccessLogMiddleware(; log_query=access_log_query)] : []

    # `compose` is installed UNCONDITIONALLY (#71). The old gate here — install it only if
    # `custommiddleware` was already non-empty — was evaluated once, and `serve` calls this
    # once, so an app whose first per-route middleware was registered AFTER the server started
    # (Revise re-running `urlpatterns`, a runtime `include_routes`) never got `compose` at all
    # and that middleware silently never ran. The emptiness test now lives inside `compose`,
    # per request, where it also short-circuits to a prebuilt global-middleware-only chain
    # BEFORE `gethandler` — so an app with no per-route middleware does strictly less routing
    # work here than the old compose branch did (one `gethandler`, not two). Against the old
    # non-compose branch it costs one closure call, one acquire-load and an `isempty` per
    # request, and no extra allocation. (Deliberately no wall-clock figure: this comment already
    # carried one that went stale the moment `router_entry` was added below.)
    #
    # `processed_middleware` travels SIDEWAYS into `compose` rather than being spliced into the
    # list below: `compose` applies it inside `buildmiddleware` and inside that fast path,
    # which lands it outside route middleware and inside the serializer — the same effective
    # position it held in this list. Do NOT do both, or every global middleware runs twice.
    # `HTTP.Router` is a *callable struct*, not a `Function` — `HTTP.Handlers.Router <: Function`
    # is false. Three of the layers that can end up wrapping it are typed on `Function` and so
    # reject it outright: `_app_context_seed` below, and `foldlayers`/`buildmiddleware` in
    # src/routerhof.jl. (`DefaultSerializer`, `PrefixStripMiddleware` and user middleware are
    # untyped and accept it fine.) So start the fold from an adapter rather than the bare router.
    #
    # `serialize=false` is what exposes this, because the serializer is otherwise the thing that
    # wraps the router into a closure on the first fold step. On `serve` it used to survive by
    # luck — `access_log` defaults to true, and `AccessLogMiddleware` accepts the raw router —
    # while `internalrequest(...; serialize=false)`, which defaults `access_log` to false, threw
    # a `MethodError` out of `_app_context_seed` even before #71. Now that `compose` is always
    # installed it receives the accumulator directly, so without this adapter every
    # `serialize=false` app would fail at pipeline-construction time, before any request.
    #
    # `let`-bound rather than closing over `ctx`: `Service.router` is declared as the
    # unparameterized `Router` (an abstract UnionAll), so reading it per request would put a
    # dynamic dispatch at the innermost layer of every request. `Service` is immutable, so the
    # value is fixed at construction and hoisting it out is free.
    router_entry = let r = ctx.service.router
        (req::HTTP.Request) -> r(req)
    end

    return reduce(|>, [
        router_entry,
        serializer...,
        # `catch_errors`/`show_errors`/`serialize` travel into `compose` because the chain it
        # caches closes over them, via `serializer` above — so they belong in the cache key
        # (#79). They are not otherwise used there.
        #
        # `show_errors` is declared `::Bool` above for this reason: `DefaultSerializer` converts
        # whatever it gets, so an untyped truthy value (`1`) would bake `true` into the chain
        # while `cachetag` recorded `e` — two pipelines with different behaviour sharing one
        # cache key, which is the exact failure #79 removed. Typing it makes the projection
        # lossless by construction rather than by luck.
        compose(ctx.service.router, processed_middleware,
                ctx.service.custommiddleware, ctx.service.middleware_cache;
                catch_errors, show_errors, serialize),
        global_prefix_middleware...,
        access_log_middleware...,
        _app_context_seed(ctx),
    ])
end

function internalrequest(ctx::ServerContext, req::HTTP.Request; middleware::Vector=[], serialize::Bool=true, catch_errors=true, context=missing)::HTTP.Response
    req.context[:ip] = IPv4("127.0.0.1")

    old_ctx = ctx.app_context[]
    if !ismissing(context)
        ctx.app_context[] = Context(context)
    end

    try
        return req |> setupmiddleware(ctx; middleware, serialize, catch_errors)
    finally
        if !ismissing(context)
            ctx.app_context[] = old_ctx
        end
    end
end
