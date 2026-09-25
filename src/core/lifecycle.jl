# ── Server lifecycle ────────────────────────────────────────────────────────────
# `serve`/`terminate`/`startserver`, the startup banner, and the Revise wiring.
# Included into `module Core` by src/core.jl — not a submodule; see the hub for why.

function serverwelcome(external_url::String, prefix::Nullable{String}, parallel::Bool)
    server_url = Util.join_url_path(external_url, prefix)
    curr_time = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
    # Renamed: `current_env` is now a function in this module (#55).
    env = current_env()
    
    # Read at CALL time, never folded into a `const` (#240). `const v = pkgversion(...)` is
    # evaluated in the precompile worker, and Julia does NOT treat `Project.toml`'s `version`
    # field as a staleness input for the cache -- so the const survives a release bump and the
    # banner freezes at whatever version the cache was built from. Measured: bumping a package
    # 0.4.0 -> 0.5.0 -> 0.6.0 left the const reading 0.4.0 while a call-time read tracked, both
    # as the active project and as a dependency. That is the exact defect class of the
    # `1.10.0` literal this replaces, just with a longer fuse.
    version = something(Base.pkgversion(@__MODULE__), "unknown")
    printstyled(" Nitro $version ", color=:cyan, reverse=true, bold=true)
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

# Documented on the public `Nitro.serve` (src/methods.jl), which is the binding users call and
# the one `docs/` renders. A docstring here is a second copy Documenter counts as missing (#186).
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
    max_body_bytes=missing,
    max_fields=DEFAULT_MAX_FIELDS,
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

    # Same reasoning as above, one layer earlier: `max_body_bytes` is read on every request, so a
    # bad value must be refused at the call site that contains the typo rather than per-request.
    #
    # The default is `missing`, NOT `DEFAULT_MAX_BODY_BYTES`, so that "the caller said nothing" and
    # "the caller asked for the default value" stay distinguishable — the custom-handler check
    # below is only meaningful if it can tell them apart. (`context=missing` above is the same
    # idea.) `nothing` means no cap; internally the limit travels as `0`, the convention the
    # bundled fork's own `max_body_bytes` uses, which keeps the hot-path check a plain integer
    # comparison rather than a branch on `Union{Nothing, Int64}` (nitro-core §7).
    if !ismissing(max_body_bytes)
        max_body_bytes === nothing || max_body_bytes >= 0 ||
            throw(ArgumentError("`max_body_bytes` must be >= 0 bytes or `nothing`, got $max_body_bytes"))

        # A custom `handler` does its own body reading, so Nitro cannot cap it. Erroring makes that
        # boundary explicit; silently dropping the limit would hand back a server the caller
        # believes is protected. `nothing` is exempt on purpose — it asks for no ceiling, which is
        # precisely what a custom handler already provides, so refusing it would be a false alarm.
        if max_body_bytes !== nothing && handler !== stream_handler
            throw(ArgumentError(
                "`max_body_bytes` cannot be applied to a custom `handler`: the request body is " *
                "read inside the handler, so only Nitro's own `stream_handler` can enforce a " *
                "ceiling. Either cap the body inside your handler and pass " *
                "`max_body_bytes = nothing`, or drop `handler`."
            ))
        end
    end

    body_limit = ismissing(max_body_bytes) ? DEFAULT_MAX_BODY_BYTES :
                 max_body_bytes === nothing ? zero(Int64) : Int64(max_body_bytes)

    # Same reasoning again (#327): read on every request, so refused here. An integer count, not
    # a `Bool` (`true` would silently mean 1) and not negative; `0` means unlimited.
    # The upper bound is checked here too, so the `Int64(max_fields)` below cannot throw after
    # the App has already been mutated.
    (max_fields isa Integer && !(max_fields isa Bool) && 0 <= max_fields <= typemax(Int64)) ||
        throw(ArgumentError("`max_fields` must be an integer >= 0 (0 means unlimited), got $(repr(max_fields))"))

    # Same reasoning as the checks above (#316): HTTP.jl only sees these at `listen!`, which runs
    # after the App has been mutated, so a typo'd timeout would otherwise fail half-way through.
    _validate_server_timeouts(kwargs)

    # Before any mutation, like the checks above (#315). A malformed prefix is refused here
    # rather than served as a listener that answers 404 to every request.
    global_prefix = _normalize_prefix(prefix)

    # Resolve (and therefore VALIDATE) the environment exactly once per `serve`, here rather
    # than only in `serverwelcome`. The banner is the sole other caller and `startserver` runs
    # it only `if show_banner` -- so any caller passing `show_banner=false` (embedded servers,
    # most async starts, much of this suite) would never validate `NITRO_ENV` at all, and a
    # typo would silently do nothing. That is the precise bug #55 exists to close, so the
    # check belongs at the point the process commits to being a server, not in its console
    # output.
    current_env()

    # Built BEFORE any mutation: `CookieConfig` validates the key (#307, #309 -- a non-string or
    # sub-32-byte `secret_key` is an `ArgumentError`), and a rejected `serve` must leave the app
    # untouched, as the guards above do.
    current = ctx.service.cookies[]
    cookies = CookieConfig(
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

    if !ismissing(context)
        ctx.app_context[] = Context(context)
    end
    ctx.service.cookies[] = cookies

    ctx.service.external_url[] = external_url isa String ? external_url : "http://$host:$port"
    ctx.service.prefix[] = global_prefix
    # Stored rather than passed through, because the *blocking* `serve()` calls `terminate()`
    # from its own `finally` (the Ctrl-C path) with no way to hand it a keyword.
    ctx.service.shutdown_timeout[] = Float64(shutdown_timeout)
    ctx.service.max_fields[] = Int64(max_fields)

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
    handle_stream = handler === stream_handler ?
        stream_handler(configured_middelware; max_body_bytes = body_limit) :
        handler(configured_middelware)

    # No warning for running on one thread (#149): single-threaded is a valid deployment, not a
    # misconfiguration, and the banner already reports the thread count. `preprocesskwargs` drops
    # `queuesize` whatever `parallel` is, so the warning that it is ignored is unconditional too.
    if haskey(kwargs, :queuesize)
        @warn "Deprecated: serve() ignores `queuesize`; remove the argument."
    end

    if parallel
        handle_stream = parallel_stream_handler(handle_stream)
    end

    # Outside the parallel spawn, so the header deadline is cleared on the connection task the
    # moment the head is parsed (#316; see `header_deadline_handler`, src/core/transport.jl).
    handle_stream = header_deadline_handler(handle_stream)

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

# Broadcast `hook` (`startup` or `shutdown`) over `entries`, deferring any interrupt (#185).
#
# `startup`/`shutdown` (src/types.jl) HAND BACK an `InterruptException` instead of throwing it,
# precisely so this loop decides what happens next: the sequence always runs to completion, and
# the FIRST interrupt is carried out to the caller, which re-raises it once the sequence is
# settled. Later ones were already logged by `_report_interrupt` at the moment they happened, and
# an `InterruptException` carries no payload, so which one escapes is not observable.
#
# Named rather than written out at each of the four broadcast halves for two reasons: the
# "first one wins" guard is easy to get wrong four times, and a named function is testable
# without binding a port — the same argument `_janitor_loop` makes in src/middleware/janitor.jl.
function _broadcast_lifecycle(hook::Function, entries,
                              interrupt::Nullable{InterruptException} = nothing)
    for lf in entries
        raised = hook(lf)
        isnothing(interrupt) && (interrupt = raised)
    end
    return interrupt
end

# The same deferral for the LAST step of the teardown, which is not a broadcast but is just as
# abandonable: `close(::Service)` blocks the calling task in `timedwait` for up to
# `shutdown_timeout` (`_shutdown_server`, src/context.jl), and an interrupt there escapes before
# the compare-and-clear that follows it — leaving `service.server[]` populated, so the next
# `terminate()` is a silent no-op, and leaking the eager-Revise watcher.
function _close_deferring_interrupt(service, timeout::Real,
                                    interrupt::Nullable{InterruptException})
    try
        close(service; timeout)
    catch e
        e isa InterruptException || rethrow()
        # Ctrl-C during the drain IS the operator saying "stop waiting", so the retry skips the
        # graceful phase rather than re-entering a fresh full budget. `close`/`forceclose`
        # overlap safely and `close(::EagerReviseService)` is a flag write, so the retry is
        # idempotent against whatever the first call already got through.
        @warn "Nitro: interrupt during the shutdown drain — force-closing the remaining connections."
        try
            close(service; timeout = 0)
        catch forced
            # Both arms leave `service.server[]` populated, because the compare-and-clear is the
            # last statement of `close` and was never reached. Say so out loud in each: the
            # interrupt this function returns is swallowed by every caller on the Ctrl-C path, so
            # a log line is the ONLY signal a half-closed listener ever produces. Contrast
            # `_shutdown_server` (src/context.jl), which can afford to stay loud because nothing
            # is already unwinding through it.
            if forced isa InterruptException
                @warn "Nitro: a second interrupt during the force-close — the server handle may \
                       still be set and the listener may still be open. Check before re-serving."
            else
                @error "Nitro: force-close after an interrupted drain failed" exception=(forced, catch_backtrace())
            end
        end
        return something(interrupt, e)
    end
    return interrupt
end

# Documented on the public `Nitro.terminate` (src/methods.jl); see the note on `serve` above.
function terminate(context::App; timeout::Nullable{Real} = nothing)
    if isopen(context.service)
        # LIFO (#74): the exact reverse of `startserver`'s startup sequence, which ran
        # route-owned then serve-owned, each in registration order. So: serve-owned reversed,
        # then route-owned reversed. Teardown order is a specified contract now, not hash
        # order — see `Service` (src/context.jl) for why LIFO and not something else.
        route_lf, serve_lf = lifecycle_snapshot(context)
        # Deferred, not broadcast-and-pray (#185): an interrupt from any hook is carried past the
        # rest of the sequence and re-raised at the very bottom of this function, so the clears
        # and the `close` below are unconditional exactly as they were before.
        #
        # The `try` is around the broadcasts, not inside them, because `startup`/`shutdown` can
        # only catch an interrupt that lands INSIDE a hook frame. SIGINT is delivered at
        # safepoints, and the loop itself has several — so a press between two hooks would
        # otherwise escape bare and skip everything below, which is the exact failure this issue
        # is about, reached by a different door. Catching here costs the remaining hooks (they
        # are unreachable once the stack has unwound) but never the teardown *below*.
        #
        # The snapshot above and the clears below stay bare, deliberately. No user code runs in
        # either, so the window is bounded by `lifecycle_lock` contention rather than by a hook,
        # and extending the `try` over them would be protecting statements that are themselves
        # partial-state transitions — a half-run clear is worse than a skipped one.
        interrupt = nothing
        try
            interrupt = _broadcast_lifecycle(shutdown, Iterators.reverse(serve_lf))
            interrupt = _broadcast_lifecycle(shutdown, Iterators.reverse(route_lf), interrupt)
        catch e
            e isa InterruptException || rethrow()
            interrupt = something(interrupt, e)
        end
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
        # There is no chain cache to clear either: each pipeline owns its own (#255), so the
        # next `serve()` builds a new pipeline and starts cold, while requests still in flight
        # here finish against the old one untouched.
        context.service.external_url[] = nothing
        interrupt = _close_deferring_interrupt(context.service,
            something(timeout, context.service.shutdown_timeout[]), interrupt)
        # Re-raised only now: everything a later `serve()` depends on has already been done.
        isnothing(interrupt) || throw(interrupt)
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
    # Around the broadcasts for the same reason `terminate` wraps its own: a hook frame is the
    # only place `startup` can catch an interrupt, and a press landing between two hooks would
    # otherwise skip the unwind below and strand the listener `start(...)` just opened.
    interrupt = nothing
    try
        interrupt = _broadcast_lifecycle(startup, route_lf)
        interrupt = _broadcast_lifecycle(startup, serve_lf, interrupt)
    catch e
        # A non-interrupt escaping here strands the listener, because the unwind below is gated
        # on `!isnothing(interrupt)`. Deliberate: `startup` catches everything from the hook
        # frame, so reaching this line at all means something structural is broken (a throwing
        # logger, an async failure), and a loud strand is a more honest signal than a quiet
        # cleanup that hides it. Pre-existing behavior; named here because the `catch` now makes
        # unwinding look like it would be one line away.
        e isa InterruptException || rethrow()
        interrupt = something(interrupt, e)
    end
    if !isnothing(interrupt)
        # `start(...)` above already opened the listener. Throwing bare here strands it: live,
        # with half its middleware started, no `on_shutdown` ever run, and every later `serve()`
        # rejected by the already-serving guard with nothing left able to close it. Unwind
        # through the REAL teardown — it pairs every hook that just ran and closes the listener
        # — then re-raise once (#185).
        #
        # "Pairs every hook" includes the INTERRUPTED one, whose `on_startup` only got part-way.
        # Its `on_shutdown` is called against half-built state, which is exactly what the
        # idempotency contract on `LifecycleMiddleware` (src/types.jl) exists to make safe —
        # `_janitor` and `AccessLog` both no-op on an inactive activation.
        try
            terminate(ctx)
        catch e
            # A SECOND Ctrl-C during the unwind. `terminate` finishes its own sequence BEFORE it
            # rethrows, so by the time this lands there is nothing left to clean up, and one
            # `InterruptException` is indistinguishable from another. Anything else is a real
            # teardown failure: it stays loud and supersedes the interrupt.
            e isa InterruptException || rethrow()
        end
        throw(interrupt)
    end

    if !async
        try
            wait(ctx.service)
        catch error
            !isa(error, InterruptException) && @error "ERROR: " exception=(error, catch_backtrace())
        finally
            println()
            # Ctrl-C out of the blocking wait is THE documented way to stop a blocking `serve` —
            # the banner says so. Without this the listener survives the interrupt and only a
            # process restart clears it, which also made an interrupt one instant earlier (in the
            # startup broadcast above, which unwinds) behave better than one an instant later.
            # `terminate` is a no-op when nothing is serving, so this is safe on the normal exit
            # path too, and idempotent against the `finally terminate()` in `src/methods.jl`.
            try
                terminate(ctx)
            catch e
                # `terminate` completes its teardown before rethrowing, so a second interrupt
                # here has nothing left to do and should not print over a clean shutdown.
                e isa InterruptException || rethrow()
            end
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
    # HTTP.jl disables every server timeout by default, which leaves a half-sent head or a silent
    # connection holding its socket forever (#316). Nitro defaults the two that cannot cut a
    # legitimate stream; `read_timeout` and `write_timeout` stay opt-in. The values, and why they
    # are 120 seconds, are on the constants (src/constants.jl).
    #
    # Written only when NEITHER spelling is present: HTTP.jl takes each timeout in seconds (`X`)
    # or nanoseconds (`X_ns`) and throws when it gets both, so defaulting `X` next to a caller's
    # `X_ns` would turn a valid call into an error. An explicit `0` or `nothing` is a value, so it
    # wins — both mean "disabled" to HTTP.jl.
    for (name, default) in ((:read_header_timeout, DEFAULT_READ_HEADER_TIMEOUT_SECONDS),
                            (:idle_timeout, DEFAULT_IDLE_TIMEOUT_SECONDS))
        haskey(kwargs_dict, name) || haskey(kwargs_dict, Symbol(name, :_ns)) ||
            (kwargs_dict[name] = default)
    end
    return kwargs_dict
end

# The server timeouts HTTP.jl's `listen!` accepts, in their seconds spelling (#316). `readtimeout`
# is HTTP.jl's deprecated alias for `read_timeout` and still accepted there.
const _SERVER_TIMEOUT_KWARGS = (:read_header_timeout, :read_timeout, :idle_timeout, :write_timeout,
                                :readtimeout)
const _SERVER_TIMEOUT_NS_KWARGS = (:read_header_timeout_ns, :read_timeout_ns, :idle_timeout_ns,
                                   :write_timeout_ns)

# The largest seconds value HTTP.jl can hold: it stores every timeout as `Int64` nanoseconds.
const _MAX_TIMEOUT_SECONDS = typemax(Int64) / 1.0e9

# Refuse a timeout HTTP.jl would reject, at the `serve` call that contains it. HTTP.jl checks the
# same things (`_timeout_ns_from_seconds`), but only inside `listen!` — after `serve` has already
# mutated the App. Seconds may be any finite real in range, or `nothing`; `Inf` is refused rather
# than read as "never", because `0`/`nothing` is how HTTP.jl spells never.
function _validate_server_timeouts(kwargs)
    for (name, value) in pairs(kwargs)
        if name in _SERVER_TIMEOUT_KWARGS
            value === nothing ||
                (value isa Real && !(value isa Bool) && isfinite(value) &&
                 0 <= value <= _MAX_TIMEOUT_SECONDS) ||
                throw(ArgumentError("`$name` must be a finite number of seconds >= 0, or " *
                    "`nothing` (`0` and `nothing` both disable it), got $(repr(value))"))
        elseif name in _SERVER_TIMEOUT_NS_KWARGS
            (value isa Integer && !(value isa Bool) && value >= 0) ||
                throw(ArgumentError("`$name` must be an integer number of nanoseconds >= 0 " *
                    "(`0` disables it), got $(repr(value))"))
        end
    end
    return nothing
end
