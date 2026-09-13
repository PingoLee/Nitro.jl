# ── Server lifecycle ────────────────────────────────────────────────────────────
# `serve`/`terminate`/`startserver`, the startup banner, and the Revise wiring.
# Included into `module Core` by src/core.jl — not a submodule; see the hub for why.

function serverwelcome(external_url::String, prefix::Nullable{String}, parallel::Bool)
    server_url = Util.join_url_path(external_url, prefix)
    curr_time = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
    # Renamed: `current_env` is now a function in this module (#55).
    env = current_env()
    
    printstyled(" Nitro 1.10.0 ", color=:cyan, reverse=true, bold=true)
    if parallel
        printstyled(" (parallel mode: $(Threads.nthreads()) threads)", color=:light_black)
    end
    println("\n$curr_time")
    # ALWAYS printed, including the defaulted case. A prod box that forgot `NITRO_ENV` must
    # SEE that it is running as `dev` -- hiding the line when nobody set one reproduces exactly
    # the silent-wrong-environment failure this became functional to prevent (#55).
    println("Environment: $env")
    
    if !isnothing(prefix)
        println("Global prefix: $prefix")
    end
    
    print("Starting server at ")
    printstyled("$server_url\n", color=:cyan, bold=true)
    println("Quit the server with CONTROL-C.")
end

function ReviseHandler()
    return function(handle)
        return function(req::HTTP.Request)
            hooks = revise_hooks()
            if hooks !== nothing && Base.invokelatest(hooks.has_pending_revisions)
                @info "🔴 Starting pre-request revision"
                Base.invokelatest(hooks.revise)
                @info "🟢 Pre-request revision finished"
            end
            invokelatest(handle, req)
        end
    end
end

# Nominal wrapper for the composed stream handler. Its only job is to give the handler
# stored in `HTTP.Server.handler` a *Nitro-owned* type, so we can attach a secret-safe
# `show` (below) without pirating `show` for every `HTTP.Server` in the session.
struct NitroStreamHandler{F} <: Function
    f::F
end
(h::NitroStreamHandler)(stream) = h.f(stream)

# SECURITY: `HTTP.Server` has no custom `show`, so Julia's default walks its fields —
# including `handler`, whose closures capture the cookie/JWT `secret_key`, DB creds, and
# API keys. Displaying a server (REPL auto-display, `@show`, a pasted session) would
# print all of them. Constrained to `NitroStreamHandler`, this override is *not* type
# piracy and never touches a non-Nitro `HTTP.Server`; it prints only the address.
# (`dump` bypasses `show` entirely and still walks raw fields — explicit introspection
# can't be, and isn't, prevented here.)
Base.show(io::IO, s::Server{<:NitroStreamHandler}) =
    print(io, "HTTP.Server(", something(s.bound_address, s.address), ")")
Base.show(io::IO, ::MIME"text/plain", s::Server{<:NitroStreamHandler}) = show(io, s)

"""
    serve(; middleware=[], host="127.0.0.1", port=8080, kwargs...) -> Union{Server, Nothing}

Start the Nitro HTTP server with the registered routes. Runs until `terminate()`
(or `Ctrl-C`); pass `async=true` to return immediately and serve in the background.

Returns the running `Server` in `async=true` mode; in blocking mode it returns
`nothing`, since the server has already shut down by the time control returns and a
shut-down handle is not useful. The returned handle is safe to display: Nitro gives
its servers a custom `show` that prints only the address (see `NitroStreamHandler`),
so secrets captured in the handler closures — cookie/JWT `secret_key`, API keys, DB
credentials — are never printed by an accidental REPL auto-display, `@show`, string
interpolation, or logging. (`dump` bypasses `show` and still walks raw fields; that
is explicit introspection, not accidental disclosure.)

# Keyword arguments
- `middleware=[]`: global middleware applied to every request, outermost first.
- `host="127.0.0.1"`, `port=8080`: listen address. Keep `host` on loopback when a
  reverse proxy terminates TLS in front of Nitro.
- `async=false`: when `true`, return the running `Server` instead of blocking.
- `parallel=true`: handle requests on the thread pool via `Threads.@spawn`.
- `serialize=true`: auto-format handler return values into responses (see `Res`).
- `catch_errors=true`: convert a thrown handler error into a generic
  `500 Internal Server Error`. **Stack traces are never sent to the client** —
  the body is always `{"message": "500: Internal Server Error"}`.
- `show_errors=true`: gate **server-side** error logging only (not the client
  response). Leave it `true` in production so failures are recorded in your logs;
  `false` merely silences those logs and does *not* harden the already-generic response.
- `access_log=true`: emit one log line per request. By default only the request
  **path** is logged — query strings are redacted so tokens, API keys, and OAuth
  `code`/`state` carried in URLs never reach the logs.
- `access_log_query=false`: set `true` to log the full target including the query
  string. Only enable when you are certain no secrets travel in query strings.
- `prefix=nothing`: strip a global URL prefix (e.g. `"/api"`) before routing.
- `revise=:none`: `:lazy`/`:eager` enable Revise-based hot reload (dev only).
- `secret_key`, `httponly`, `secure`, `samesite`: override cookie defaults for this run.
- `shutdown_timeout=10.0`: seconds `terminate` waits for in-flight requests to drain
  before force-closing what remains. `0` skips the graceful phase entirely.
- `reuseaddr`: forwarded to `HTTP.listen!`. Defaults to `true` on Linux/macOS, where it
  allows rebinding a port still in `TIME_WAIT`, and to **`false` on Windows**, where
  `SO_REUSEADDR` instead lets a second process bind a port another is actively listening
  on — turning a port conflict into two servers silently splitting the traffic.

Calling `serve` on an app that is **already serving** throws an `ArgumentError`: the second
call would overwrite the running server's handle and strand its port. Terminate that app
first, or give the second listener its own `App`.

IP-based controls (rate limiting, audit logging) key on the socket peer address,
resolved for both plain-HTTP and direct-TLS listeners. Behind a reverse proxy,
configure `ExtractIP`/`RateLimiter` with both `trusted_proxies` and the
`forwarded_header` your proxy writes so per-client limits work.

See also `terminate`, `RateLimiter`, and `ExtractIP`.
"""
function serve(ctx::App;
    middleware=[],
    handler=stream_handler,
    host="127.0.0.1",
    port=8080,
    async=false,
    parallel=true,
    serialize=true,
    catch_errors=true,
    show_errors::Bool=true,
    show_banner=true,
    access_log=true,
    access_log_query=false,
    external_url=nothing,
    prefix=nothing,
    context=missing,
    revise=:none,
    secret_key=nothing,
    httponly=nothing,
    secure=nothing,
    samesite=nothing,
    shutdown_timeout=SHUTDOWN_TIMEOUT_SECONDS,
    kwargs...)::Union{Server, Nothing}

    # FIRST, before any validation or context mutation, so a rejected call leaves the context
    # byte-for-byte untouched. `startserver` assigns `ctx.service.server[]` unconditionally, so
    # without this guard a second `serve()` would overwrite the handle of a *live* server —
    # leaving it unreachable and its port bound for the life of the process, with nothing left
    # to close it. That is a programming error, not something to paper over by silently killing
    # the first server's in-flight requests.
    if isopen(ctx.service)
        throw(ArgumentError(
            "This App is already serving on " *
            "$(something(ctx.service.external_url[], "an open listener")). A second `serve()` " *
            "would overwrite the running server's handle, leaving it unreachable and its port " *
            "bound until the process exits. Terminate THIS app first, or give the second " *
            "listener its own: `app = App(mod = @__MODULE__); serve(app; …)`."))
    end

    if revise ∉ (:none, :lazy, :eager)
        throw(ArgumentError("Invalid `revise` value $(repr(revise)). Expected one of :none, :lazy, or :eager."))
    end

    # Validate HERE rather than only at shutdown. `_shutdown_server` also rejects a bad value,
    # but by then it is far too late: the stored timeout is read on every `terminate()`, so a
    # typo'd `shutdown_timeout` would make `terminate()` throw *before* it clears the handle —
    # leaving a running server that can never be stopped through the normal API. Rejecting the
    # value at the call site that contains the typo keeps the failure recoverable.
    # (`NaN >= 0` is false, so NaN is rejected here too.)
    shutdown_timeout >= 0 ||
        throw(ArgumentError("`shutdown_timeout` must be >= 0 seconds, got $shutdown_timeout"))

    # Resolve (and therefore VALIDATE) the environment exactly once per `serve`, here rather
    # than only in `serverwelcome`. The banner is the sole other caller and `startserver` runs
    # it only `if show_banner` -- so any caller passing `show_banner=false` (embedded servers,
    # most async starts, much of this suite) would never validate `NITRO_ENV` at all, and a
    # typo would silently do nothing. That is the precise bug #55 exists to close, so the
    # check belongs at the point the process commits to being a server, not in its console
    # output.
    current_env()

    if !ismissing(context)
        ctx.app_context[] = Context(context)
    end

    current = ctx.service.cookies[]
    ctx.service.cookies[] = CookieConfig(
        secret_key=isnothing(secret_key) ? current.secret_key : secret_key,
        httponly=isnothing(httponly) ? current.httponly : httponly,
        secure=isnothing(secure) ? current.secure : secure,
        samesite=isnothing(samesite) ? current.samesite : samesite,
        path=current.path,
        domain=current.domain,
        maxage=current.maxage,
        expires=current.expires,
        max_cookie_size=current.max_cookie_size,
    )

    ctx.service.external_url[] = external_url isa String ? external_url : "http://$host:$port"
    ctx.service.prefix[] = prefix isa String ? prefix : nothing
    # Stored rather than passed through, because the *blocking* `serve()` calls `terminate()`
    # from its own `finally` (the Ctrl-C path) with no way to hand it a keyword.
    ctx.service.shutdown_timeout[] = Float64(shutdown_timeout)

    if revise == :lazy || revise == :eager
        if parallel && Threads.nthreads() > 1
            @warn "You are attempting to use Revise with multiple threads. Please note that Revise 3.5.18 and earlier are not threadsafe."
        end
        if !has_revise_hooks()
            error("Revise support is unavailable. Load Revise.jl in your development session before using the `revise` option")
        end
        if ctx.mod === nothing
            @warn "`revise` was requested but this App tracks no module, so code in `Main` may not be revised. Construct it as `App(mod = @__MODULE__)` from the module you want tracked."
        end
        middleware = convert(Vector{Any}, middleware)
        insert!(middleware, 1, ReviseHandler())
    end

    # Lifecycle registration lives HERE — once per server — not in `setupmiddleware`, which
    # `internalrequest` also calls, per request (#68). `startup.` runs only in `startserver`,
    # so a middleware registered from the request path got an `on_shutdown` at `terminate`
    # with no paired `on_startup` — deterministic, needing no race at all — and additionally
    # wrote to an unsynchronized `Set` that `startup.`/`shutdown.` broadcast over, which a
    # concurrent `internalrequest` could overlap.
    #
    # SERVE-owned (#82): this list belongs to this server run, so `terminate` clears it. Route
    # middleware registers itself as route-owned at `urlpatterns()` time instead, and survives.
    #
    # Placed after the `revise` block above so it operates on the final `middleware` vector.
    # (Inert today — `ReviseHandler()` is a plain closure, not a `LifecycleMiddleware`, so
    # the resulting `Set` is the same either way — but the ordering is the correct default.)
    register_serve_lifecycle!(ctx, middleware)

    configured_middelware = setupmiddleware(ctx; middleware, serialize, catch_errors, show_errors, access_log, access_log_query)
    handle_stream = handler(configured_middelware)

    if parallel
        if Threads.nthreads() <= 1 && !is_test()
            @warn "serveparallel() only has 1 thread available to use, try launching julia like this: \"julia -t auto\" to leverage multiple threads"
        end

        if haskey(kwargs, :queuesize) && !is_test()
            @warn "Deprecated: The `queuesize` parameter is no longer used / supported in serveparallel()"
        end

        handle_stream = parallel_stream_handler(handle_stream)
    end

    # Wrap last, so the handler HTTP stores gets our secret-safe `show` (see NitroStreamHandler).
    handle_stream = NitroStreamHandler(handle_stream)

    if revise == :eager
        ctx.service.eager_revise[] = start_revise_service()
    end

    try
        return startserver(ctx; host, port, show_banner, parallel, async, kwargs, start=(kwargs) ->
            HTTP.listen!(handle_stream, host, port; kwargs...))
    finally
        if ctx.service.eager_revise[] !== nothing && async == false
            close(ctx.service.eager_revise[])
        end
    end
end

function start_revise_service()
    revise_task_done = Ref(false)
    revise_task = @async begin
        hooks = revise_hooks()
        if hooks === nothing
            return nothing
        end
        while true
            if revise_task_done[]
                break
            end
            Base.invokelatest(hooks.wait_for_revision_event)
            if revise_task_done[]
                break
            end
            @info "🗘  Starting eager revision"
            Base.invokelatest(hooks.revise)
            @info "👍 Eager revision finished"
        end
    end
    EagerReviseService(revise_task, revise_task_done)
end

"""
    terminate(context::App; timeout = nothing)
    terminate(; timeout = nothing)

Stop the running server: run every `LifecycleMiddleware` shutdown hook, drop the composed
middleware cache, and close the listener. A no-op when nothing is serving.

Shutdown is a **bounded graceful drain**, modeled on Go's `http.Server.Shutdown(ctx)`. The
listening socket is released immediately — the port is free as soon as `terminate` is entered
— then Nitro waits up to `timeout` seconds for in-flight requests to finish and force-closes
whatever remains.

`timeout` defaults to the server's own `serve(shutdown_timeout = …)`, itself defaulting to
`Nitro.Core.SHUTDOWN_TIMEOUT_SECONDS` (10 seconds). `timeout = 0` skips the graceful phase.

**Long-lived connections are always cut at the timeout.** A WebSocket, SSE, or STREAM handler
holds its connection for its whole lifetime, so the drain can never wait it out. If such a
handler has to finish cleanly, give it a shutdown signal of its own — an `Event` or `Channel`
notified from a `LifecycleMiddleware`'s `on_shutdown`, which runs *before* the drain begins.

!!! warning
    Do not call `terminate()` from inside a request handler. The handler's own connection is
    what the drain is waiting on, so the graceful phase is guaranteed to reach its timeout.

See also `serve`.
"""
function terminate(context::App; timeout::Nullable{Real} = nothing)
    if isopen(context.service)
        # LIFO (#74): the exact reverse of `startserver`'s startup sequence, which ran
        # route-owned then serve-owned, each in registration order. So: serve-owned reversed,
        # then route-owned reversed. Teardown order is a specified contract now, not hash
        # order — see `Service` (src/context.jl) for why LIFO and not something else.
        route_lf, serve_lf = lifecycle_snapshot(context)
        shutdown.(Iterators.reverse(serve_lf))
        shutdown.(Iterators.reverse(route_lf))
        # Only the SERVE-owned half is cleared (#82). These came from this run's
        # `serve(middleware = ...)` list and `serve` re-registers them on the next call, so
        # keeping them would start a previous run's middleware alongside the new one.
        #
        # `route_lifecycle` is deliberately NOT emptied. Those entries were declared once, at
        # `urlpatterns()` time, and nothing re-adds them — routes are not re-registered on a
        # second `serve()`. Emptying them is what made every route-level `on_startup` silently
        # skipped for the rest of the process's life, which for a route-level `RateLimiter`
        # meant its bucket-pruning task never restarted while the store kept growing. They are
        # cleared only by replacing the context (`resetstate()`, src/methods.jl).
        lock(() -> empty!(context.service.serve_lifecycle), context.service.lifecycle_lock)
        # Do NOT "symmetrize" this by also emptying `custommiddleware`: that table is route
        # *registration* state, not cache state. test/original_tests.jl re-serves after a
        # `terminate()` and expects the registered routes and their middleware to survive.
        # `empty!(::CopyOnWriteDict)`, not `empty!(::Dict)`: publishes a fresh table under
        # the cache's lock. Requests are still in `compose` here — the server is not closed
        # until the `close` a couple of lines below — so an in-flight reader must be able to
        # finish against a table nobody mutates.
        empty!(context.service.middleware_cache)
        context.service.external_url[] = nothing
        close(context.service; timeout = something(timeout, context.service.shutdown_timeout[]))
    end
    return nothing
end

function startserver(ctx::App; host, port, show_banner=false, parallel=false, async=false, kwargs, start)::Union{Server, Nothing}
    show_banner && serverwelcome(ctx.service.external_url[], ctx.service.prefix[], parallel)
    ctx.service.server[] = start(preprocesskwargs(kwargs))
    # Route-owned first, then serve-owned: that is declaration order — routes are registered at
    # `urlpatterns()` time, the `serve(middleware = ...)` list only at `serve()` time (#82).
    # Within each half, registration order. `terminate` unwinds the exact reverse (#74).
    #
    # Over a snapshot, not the live vectors: a `revise=:lazy` re-registration runs on a
    # request-handling task and could otherwise `push!` while this broadcast iterates.
    route_lf, serve_lf = lifecycle_snapshot(ctx)
    startup.(route_lf)
    startup.(serve_lf)

    if !async
        try
            wait(ctx.service)
        catch error
            !isa(error, InterruptException) && @error "ERROR: " exception=(error, catch_backtrace())
        finally
            println()
        end
        # The blocking path only returns after shutdown (Ctrl-C), so a server handle here
        # would be useless. Return `nothing` to keep the REPL clean. (Secret disclosure via
        # the handle is handled separately by the `NitroStreamHandler` `show` override — that
        # covers the `async=true` handle too; this early return is just tidiness.)
        # The server stays reachable via `ctx.service.server[]` for `terminate`.
        return nothing
    end

    return ctx.service.server[]
end

function preprocesskwargs(kwargs)
    # HTTP.jl v2's `listen!` is already Stream-based, so the v1 `stream=true` flag is
    # gone. Access logging (the old `logfmt`/`access_log` default) is now handled by
    # `AccessLogMiddleware` in the middleware chain instead.
    kwargs_dict = Dict{Symbol,Any}(kwargs)
    # `listen!` rejects unknown keyword arguments. Drop v1-only server kwargs that Nitro
    # still tolerates for back-compat (a deprecation warning is emitted in `serve`).
    delete!(kwargs_dict, :queuesize)
    # `SO_REUSEADDR` means something fundamentally different on Windows. On POSIX it only lets
    # you bind over sockets in TIME_WAIT, which is load-bearing for restarting onto a port you
    # just shut down. On Windows it lets a second process bind a port another process is
    # *actively listening on*, with indeterminate delivery between the two — which is why
    # Microsoft had to add SO_EXCLUSIVEADDRUSE. HTTP.jl defaults it to `true` everywhere, so on
    # Windows an orphaned Nitro process turns "port already taken" from a loud bind failure into
    # a silent split-brain where some requests are answered by the corpse, out of *its* router.
    # `get!` writes only when the key is absent, so an explicit `serve(reuseaddr = …)` wins.
    Base.get!(kwargs_dict, :reuseaddr, !Sys.iswindows())
    return kwargs_dict
end
