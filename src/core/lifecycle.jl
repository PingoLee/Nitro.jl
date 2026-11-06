# ── Server lifecycle ────────────────────────────────────────────────────────────
# `serve`/`terminate`/`startserver`, the startup banner, and the Revise wiring.
# Included into `module Core` by src/core.jl — not a submodule; see the hub for why.
#
# What the serve task, a force-close or an eager revision threw is logged as `loggable(e)`, never
# the live exception (#658). `loggable` is in scope through src/core/transport.jl's import.

# ── What the process was started with (#299) ──────────────────────────────────────────────────────
#
# REPORT, NEVER ENFORCE. The two most common ways to misconfigure a production process — one
# thread, and no GC target — cannot be seen from inside it without these lines. Nothing in Nitro
# may depend on either value: it never refuses to start, never sets a hint itself, never sizes
# anything from what it reads. That is the same line `current_env()` holds (#55), and it is a
# deliberate, narrow exception to #241's "nothing in `src/` should read the heap hint".

# Julia's own "no target" is 2 PiB (2^51) on 1.12 and 1.13. Compared against a threshold rather
# than that exact value, which is a runtime constant that could move; no real host has 1 PiB.
const _NO_GC_TARGET_BYTES = UInt64(1) << 50

# The GC's effective target, in bytes: `--heap-size-hint`, else `JULIA_HEAP_SIZE_HINT`, else the
# cgroup memory limit — the runtime has already applied that precedence, and subtracted its own
# 250 MiB reserve. `nothing` when the runtime does not expose it: `jl_gc_get_max_memory` is exported
# (`julia/gc-interface.h`) but not documented API, so a GC build without it must cost only the
# banner field, never the server start.
function _gc_target_bytes()::Nullable{UInt64}
    try
        return ccall(:jl_gc_get_max_memory, UInt64, ())
    catch err
        # Narrow on purpose (group 1 in `src/errors.jl`): a `ccall` recurses into nothing.
        err isa InterruptException && rethrow()
        return nothing
    end
end

_has_gc_target(bytes::UInt64) = bytes < _NO_GC_TARGET_BYTES

function _format_gc_bytes(bytes::UInt64)::String
    gib = bytes / 2.0^30
    return gib >= 1 ? "$(round(gib; digits = 1)) GiB" : "$(round(bytes / 2.0^20; digits = 1)) MiB"
end

# `Threads.nthreads()` is the default pool only. Since 1.12, Julia also starts one interactive
# thread by default, and HTTP.jl runs its accept loop and every connection task there, so it is
# worth showing — but as a separate count, because handlers never run on it.
function _thread_summary()::String
    ndefault = Threads.nthreads(:default)
    ninteractive = Threads.nthreads(:interactive)
    summary = "$ndefault thread$(ndefault == 1 ? "" : "s")"
    return ninteractive > 0 ? "$summary + $ninteractive interactive" : summary
end

# The one environment-dependent output at startup, and it only logs. A prod process with no GC
# target is the documented cause of an OOM kill that leaves no Julia backtrace (Running in
# Production), and the banner alone is easy to miss — it goes to stdout, and `show_banner=false`
# suppresses it — so prod also gets a line at warning level, where log alerting sees it.
# Deliberately NOT for a single thread: that is a valid deployment (#149). And not when the value
# is unknown: guessing would warn about something that may well be set.
function _warn_if_no_gc_target(env::AbstractString, gc_target::Nullable{UInt64})::Nothing
    env == "prod" || return nothing
    (gc_target === nothing || _has_gc_target(gc_target)) && return nothing
    @warn "Nitro is running in prod with no GC target: no `--heap-size-hint`, no " *
          "`JULIA_HEAP_SIZE_HINT` and no cgroup memory limit. The heap can then grow until the " *
          "kernel OOM-kills the process, which leaves no Julia backtrace. Set one of the three; " *
          "see \"Running in Production\" in the Nitro docs."
    return nothing
end

# ── Writing to `stdout` under `juliac --trim` ─────────────────────────────────────────────────────
#
# Base declares the global `stdout::IO`, so every call on it is a dynamic dispatch, which a trimmed
# build rejects. `_with_stdout` hands `f` the stream as one of the concrete types Base installs
# there: `init_stdio` (a `TTY`, a `PipeEndpoint` or an `IOStream`), `redirect_stdout` (those, or
# `devnull`), and the `IOContext` that `--color=yes|no` puts around a stream that is not a
# terminal. Any other stream (a socket as `stdout`, say) gets the output through a dynamic call
# under the JIT. JuliaC's own examples print to `Core.stdout`
# instead, which has no `:color`, so the JIT keeps Base's `stdout` and the banner keeps its colours.
#
# A trimmed build always writes to Julia's `Core.stdout` (spelled `Base.Core`: inside this module,
# `Core` is Nitro's own). Its `stdout` is the stream object saved when the image was built, never
# initialized in the running executable, and a write to it throws "stream not initialized".
# `redirect_stdout` points both fd 1 and the handle `Core.stdout` writes through at its target, so
# the text still lands where a redirect sends it, only without colour.
function _with_stdout(f::F) where {F}
    Types._trimmed() && return f(Base.Core.stdout)
    out = stdout
    out isa Base.TTY && return f(out)
    out isa IOStream && return f(out)
    out isa Base.PipeEndpoint && return f(out)
    out isa IOContext{Base.TTY} && return f(out)
    out isa IOContext{IOStream} && return f(out)
    out isa IOContext{Base.PipeEndpoint} && return f(out)
    out isa Base.DevNull && return f(out)
    return f(out)
end

# What `printstyled(io, text; color, bold, reverse)` writes, byte for byte, for a single line of
# text. `printstyled` itself cannot be used: it hands `print` to `with_output_color` as a
# `@nospecialize`d function, and that call is one a trimmed build cannot resolve.
function _print_styled(io::IO, text::String, color::Bool, code::String;
                       bold::Bool = false, reverse::Bool = false)
    color || return print(io, text)
    print(io, code)
    bold && print(io, "\e[1m")
    reverse && print(io, "\e[7m")
    print(io, text)
    reverse && print(io, "\e[27m")
    bold && print(io, "\e[22m")
    print(io, "\e[39m")
    return nothing
end

# The stream's `:color`, as `printstyled` reads it. On a `TTY` that loads the terminal's terminfo
# entry, through a parser a trimmed build cannot type, so a trimmed build prints without colour.
_stdout_color(out::IO)::Bool = Types._trimmed() ? false : get(out, :color, false)::Bool

const _CYAN = "\e[36m"
const _LIGHT_BLACK = "\e[90m"
const _YELLOW = "\e[33m"

# `print(io, ::VersionNumber)` joins the prerelease and build parts over an untyped tuple; this is
# the same text, printed part by part.
function _print_version(io::IO, v::VersionNumber)
    print(io, v.major, '.', v.minor, '.', v.patch)
    _print_version_parts(io, '-', v.prerelease)
    _print_version_parts(io, '+', v.build)
    return nothing
end

# `@nospecialize`: the field is `Tuple{Vararg{Union{UInt64, String}}}`, which is not concrete, so
# the call resolves only to a method compiled for that declared type.
function _print_version_parts(io::IO, sep::Char, @nospecialize(parts::Tuple{Vararg{Union{UInt64, String}}}))
    isempty(parts) && return nothing
    print(io, sep)
    leading = true
    for part in parts
        leading || print(io, '.')
        print(io, part)
        leading = false
    end
    return nothing
end

# Parsed once, here. A format string passed to `Dates.format` at run time was parsed on every call,
# into a `DateFormat` whose type a trimmed build cannot know.
const _BANNER_TIME_FORMAT = dateformat"yyyy-mm-dd HH:MM:SS"

function serverwelcome(external_url::String, prefix::Nullable{String};
                       gc_target::Nullable{UInt64} = _gc_target_bytes())
    # Built whole, then written once, in colour exactly when the stream asks for it: the bytes are
    # the ones the `printstyled` calls on `stdout` used to write.
    banner = _with_stdout(out -> _render_banner(external_url, prefix, gc_target,
                                                _stdout_color(out)))
    _with_stdout(out -> print(out, banner))
    return nothing
end

function _render_banner(external_url::String, prefix::Nullable{String},
                        gc_target::Nullable{UInt64}, color::Bool)::String
    io = IOBuffer()
    server_url = Util.join_url_path(external_url, prefix)
    curr_time = Dates.format(now(), _BANNER_TIME_FORMAT)
    # Renamed: `current_env` is now a function in this module (#55).
    env = current_env()

    # Read at CALL time, never folded into a `const` (#240). `const v = pkgversion(...)` is
    # evaluated in the precompile worker, and Julia does NOT treat `Project.toml`'s `version`
    # field as a staleness input for the cache -- so the const survives a release bump and the
    # banner freezes at whatever version the cache was built from. Measured: bumping a package
    # 0.4.0 -> 0.5.0 -> 0.6.0 left the const reading 0.4.0 while a call-time read tracked, both
    # as the active project and as a dependency. That is the exact defect class of the
    # `1.10.0` literal this replaces, just with a longer fuse.
    version = Base.pkgversion(@__MODULE__)
    title = sprint() do s
        print(s, " Nitro ")
        version === nothing ? print(s, "unknown") : _print_version(s, version)
        print(s, ' ')
    end
    _print_styled(io, title, color, _CYAN; reverse = true, bold = true)
    # `(8 threads + 1 interactive, GC target 2.8 GiB)`. The GC field is printed only when there
    # is something true to say: none at all when the runtime would not say (`nothing`) rather
    # than a guess.
    _print_styled(io, " ($(_thread_summary())", color, _LIGHT_BLACK)
    if gc_target !== nothing
        _print_styled(io, ", ", color, _LIGHT_BLACK)
        if _has_gc_target(gc_target)
            _print_styled(io, "GC target $(_format_gc_bytes(gc_target))", color, _LIGHT_BLACK)
        else
            # Not "2.0 PiB": that number is Julia's placeholder for "unset", and printing it would
            # read as a real, enormous limit.
            _print_styled(io, "GC target: none", color, _YELLOW)
        end
    end
    _print_styled(io, ")", color, _LIGHT_BLACK)
    println(io, "\n$curr_time")
    # ALWAYS printed, including the defaulted case. A prod box that forgot `NITRO_ENV` must
    # SEE that it is running as `dev` -- hiding the line when nobody set one reproduces exactly
    # the silent-wrong-environment failure this became functional to prevent (#55).
    println(io, "Environment: $env")

    if !isnothing(prefix)
        println(io, "Global prefix: $prefix")
    end

    print(io, "Starting server at ")
    _print_styled(io, server_url, color, _CYAN; bold = true)
    println(io)
    println(io, "Quit the server with CONTROL-C.")
    return String(take!(io))
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

# The stream handler `serve` hands HTTP.jl, built around an assembled pipeline, outermost last:
# Nitro's `stream_handler` (or a custom `handler`), the per-request spawn, and the
# `NitroStreamHandler` wrapper that gives it a secret-safe `show`.
# Returns `(listener, request_handler)`: what HTTP.jl calls on the connection task, and the
# handler the spawn runs on the request's own task.
#
# One function for `serve` AND the precompile workload (#450), so the types the workload compiles
# are the types `serve` builds. HTTP.jl specializes its connection loop on the listener's type,
# and every closure here is typed by what it captures, so a hand-copied chain that differs in one
# layer caches code no server ever runs. test/precompilation_test.jl asserts the two agree.
#
# `P`/`H` force specialization on both: `pipeline` is only passed on here, never called, so a
# `::Function` argument would be compiled for `Function` alone (#572).
function _serve_listener(pipeline::P, handler::H, body_limit::Int64, request_limit::Int64,
                         upgraded_limit::Int64, security_headers) where {P<:Function, H}
    request_handler = handler === stream_handler ?
        stream_handler(pipeline; max_body_bytes = body_limit,
                       max_concurrent_requests = request_limit,
                       max_upgraded_connections = upgraded_limit,
                       rejection_headers = security_headers === nothing ? Pair{String,String}[] :
                                                                         security_headers.headers) :
        handler(pipeline)
    return NitroStreamHandler(parallel_stream_handler(request_handler)), request_handler
end

# `_serve_listener` for an `App` served with every default `serve` has: no middleware, the access
# log on, Nitro's own stream handler, the default body cap, no request or WebSocket cap, no
# security headers. The shape the precompile workload warms (#450); a change to one of
# `serve`'s defaults that alters a type here makes test/precompilation_test.jl fail rather than
# leaving the workload silently caching the old shape.
_default_serve_listener(ctx::App) =
    _serve_listener(setupmiddleware(ctx; middleware = (), serialize = true, catch_errors = true,
                                    show_errors = true, access_log = true,
                                    access_log_query = false, access_log_skip = nothing,
                                    security_headers = nothing),
                    stream_handler, DEFAULT_MAX_BODY_BYTES, zero(Int64), zero(Int64), nothing)

# `_serve_listener` for the server `serve(ctx; kwargs...)` would build with `revise = :none`, for
# `precompile_server(app; …)` (#827). Only the keywords that reach the pipeline's or the
# listener's TYPE are read; every other `serve` keyword (`host`, `port`, `secret_key`, the
# timeouts) is accepted and ignored, so one `NamedTuple` can be splatted into both calls. The
# limits travel as `Int64` whatever their value, so they are passed as `serve`'s defaults.
# Binds nothing and registers nothing: `setupmiddleware` is the half `internalrequest` also runs
# per request; the lifecycle registration is `serve`'s alone.
#
# The same calls as `serve`'s `revise = :none` branch and `_serve_pipeline`, so the type is the
# one `serve` builds; test/precompilation_test.jl asserts it for non-default shapes, as it does
# `_default_serve_listener`'s for the default one.
function _serve_listener_for(ctx::App; middleware::Union{Tuple,Vector} = (), handler::H = stream_handler,
                             serialize = true, catch_errors = true, show_errors::Bool = true,
                             access_log = true, access_log_query = false, access_log_skip = nothing,
                             security_headers = nothing, kwargs...) where {H}
    security_headers === nothing || security_headers isa SecurityHeaders ||
        throw(ArgumentError("`security_headers` must be a `SecurityHeaders(...)` value or " *
                            "`nothing`, got $(repr(security_headers))"))
    pipeline = setupmiddleware(ctx; middleware, serialize, catch_errors, show_errors, access_log,
                               access_log_query, access_log_skip, security_headers)
    return _serve_listener(pipeline, handler, DEFAULT_MAX_BODY_BYTES, zero(Int64), zero(Int64),
                           security_headers)
end

# The transport layer of one `_serve_listener` result (#450), COMPILED, not run, and `false` when
# any signature stops applying, as `precompile` does. Running it would need a live connection:
# `stream_handler` closes the write side itself (#453), and HTTP's socket-free `Stream(request)`
# has no connection to close. `precompile` needs only the types.
#
# HTTP.jl's accept loop, connection loop and HTTP/2 stream task are specialized on the server's
# handler type, and `HTTP.precompile_server` (HTTP 2.15, #868) compiles all three for it. Before,
# nearly all of a fresh server's first request was that loop, ~1.46 s on Julia 1.13.2 (#827).
#
# One stream type covers every HTTP/1.1 request, with a body or without: HTTP builds each `Stream`
# around `_stream_request_metadata(request)`, which is always a `Request{EmptyBody}`, and keeps
# the live body in an abstract `request_body` field. What stays cold is only the body READ for
# `FixedLengthBody`/`ChunkedBody`, which dispatches at runtime off that field.
#
# Called by Nitro's own workload for the default shape (src/precompile.jl) and by the public
# `precompile_server(app; …)` for any other (src/methods.jl).
function _precompile_listener(listener::L, request_handler::R)::Bool where {L, R}
    stream = HTTP.Stream{false, HTTP.Request{HTTP.EmptyBody}}
    ok = precompile(listener, (stream,))
    ok &= HTTP.precompile_server(L)
    ok &= precompile(request_handler, (stream,))
    # What the spawn runs: a `@spawn` closure's body is not compiled with the listener.
    ok &= precompile(_handle_reporting, (R, stream))
    # The write half, once per body type Nitro builds (`Types.with_response`), for the two
    # requests the transport builds. The two streaming bodies (#551) cost ~120 ms each on a first
    # request when cold: a streamed file (`Res.file(req, path)` over 8 MiB or with `stream = true`,
    # and a mount's files over its threshold) and `Res.sse`'s `SSEStream`. The admission is
    # `nothing` unless `max_concurrent_requests` holds a slot.
    for B in (String, Vector{UInt8}, HTTP.EmptyBody, HTTP.BytesBody{Vector{UInt8}},
              HTTP.BytesBody{Types.RangeBytes}, Types.StreamedFileBody, HTTP.SSEStream),
        Q in (Types.EmptyRequest, Types.BytesRequest), A in (Nothing, _Admission)
        ok &= precompile(_send_response!, (HTTP.Response{B}, stream, Q, A))
    end
    return ok
end

# The refusal `serve` throws when `ctx` is not idle, worded for the phase it is in (#812).
function _not_idle_error(ctx::App)::ArgumentError
    phase = AppContext._phase(ctx.service.phase[])
    if phase === AppContext.PHASE_CANCELLING
        return ArgumentError(
            "This App is still stopping: `terminate` cancelled its start, which is unwinding the " *
            "startup hooks that already ran. Wait for `terminate` to return, then call `serve` again.")
    elseif phase === AppContext.PHASE_STOPPING
        return ArgumentError(
            "This App is still stopping: `terminate` is draining its previous run and has " *
            "teardown hooks still to run, which would release what a new run starts using. Wait " *
            "for `terminate` to return, then call `serve` again.")
    elseif phase === AppContext.PHASE_STARTING
        return ArgumentError(
            "This App is already starting: another `serve()` call is bringing it up. Wait for " *
            "that call, and `terminate` it before serving again, or give the second listener " *
            "its own: `app = App(mod = @__MODULE__); serve(app; …)`.")
    end
    return ArgumentError(
        "This App is already serving on " *
        "$(something(ctx.service.external_url[], "an open listener")). A second `serve()` " *
        "would overwrite the running server's handle, leaving it unreachable and its port " *
        "bound until the process exits. Terminate THIS app first, or give the second " *
        "listener its own: `app = App(mod = @__MODULE__); serve(app; …)`.")
end

# What one `serve` call holds of the run it claimed (#812, #834): the run's generation, and whether
# this call still owns `PHASE_STARTING`. `startserver` clears `owns` at the moment it moves the
# phase on (to `SERVING`, or back to `IDLE` through its own unwind), and from then on `serve`'s
# `catch` must leave the phase alone: once it is `IDLE` again another `serve` may already have
# claimed it, and resetting that claim would admit a third.
mutable struct StartClaim
    const gen::UInt64
    owns::Bool
end

# Whether `terminate` has cancelled the start `claim` holds (#834).
_start_cancelled(ctx::App, claim::StartClaim)::Bool =
    ctx.service.phase[] === AppContext._word(claim.gen, AppContext.PHASE_CANCELLING)

# Set while a lifecycle broadcast runs, on the broadcasting task and on every task it spawns
# (#834). A `terminate` called from inside a hook still cancels or stops the run, but never waits
# for it: the run it would be waiting for is the one running that hook.
const IN_LIFECYCLE_HOOK = ScopedValue(false)

# Undo a `serve` that failed while it still owned `PHASE_STARTING` (#812): no startup hook has
# run and no listener is open, so the `serve(middleware = …)` lifecycle this call registered
# belongs to a run that never existed. Cleared, or the next `serve` would start it alongside its
# own. Then the phase goes back to `IDLE`, last, so a retry finds the App as it was, and a
# `terminate` that cancelled this start (#834) is woken.
#
# The settle is in a `finally`: `serve`'s own `catch` skips this once `owns` is cleared, so an
# interrupt landing in the clears would otherwise leave the run `STARTING` or `CANCELLING` for good,
# and a `terminate` waiting on it parked forever (#834). The eager-Revise watcher this start may
# have started is closed BEFORE the settle, while the App is still this call's: once it is `IDLE`
# the slot may already hold the watcher of the next `serve` (#427).
function _abandon_start!(ctx::App, claim::StartClaim)
    claim.owns = false
    try
        lock(() -> empty!(ctx.service.serve_lifecycle), ctx.service.lifecycle_lock)
        ctx.service.external_url[] = nothing
        AppContext._close_eager_revise(ctx.service)
    finally
        AppContext._settle_idle!(ctx.service, claim.gen)
    end
    return nothing
end

# The cookie config `serve` installs: the App's current one, with `serve`'s `secret_key`,
# `httponly`, `secure` and `samesite` where they were passed. Through `CookieConfig`'s `base` form
# rather than its keyword form, so a trimmed `serve` builds it with a static call (#856):
# the keyword form with `current`'s `Nullable` fields was static only when the compiler inlined
# the constructor, which Julia 1.14 does not. `test/cookies_tests.jl` pins the call.
_serve_cookies(current::CookieConfig, secret_key, httponly, secure, samesite)::CookieConfig =
    CookieConfig(current,
                 isnothing(secret_key) ? current.secret_key : secret_key,
                 isnothing(httponly) ? current.httponly : httponly,
                 isnothing(secure) ? current.secure : secure,
                 isnothing(samesite) ? current.samesite : samesite)

# Documented on the public `Nitro.serve` (src/methods.jl), which is the binding users call and
# the one `docs/` renders. A docstring here is a second copy Documenter counts as missing (#186).
function serve(ctx::App;
    middleware::Union{Tuple,Vector}=(),
    # `::H`, a type parameter: `serve` only compares and passes `handler`, never calls it, so a
    # plain keyword is compiled for `Function` and the call into `_serve_pipeline` is dynamic (#572).
    handler::H=stream_handler,
    host="127.0.0.1",
    port=8080,
    async=false,
    serialize=true,
    catch_errors=true,
    show_errors::Bool=true,
    show_banner=true,
    access_log=true,
    access_log_query=false,
    access_log_skip=nothing,
    security_headers=nothing,
    external_url=nothing,
    prefix=nothing,
    context=missing,
    revise::Symbol=:none,
    secret_key=nothing,
    httponly=nothing,
    secure=nothing,
    samesite=nothing,
    shutdown_timeout=SHUTDOWN_TIMEOUT_SECONDS,
    max_body_bytes=missing,
    max_fields=DEFAULT_MAX_FIELDS,
    max_concurrent_requests=nothing,
    max_upgraded_connections=nothing,
    # Internal (#834): the blocking `Nitro.serve` wrappers pass a `Ref` and read back the
    # generation of the run THIS call claimed, or `0` if it claimed none, so their cleanup stops
    # exactly that run. Named here so it never reaches `HTTP.listen!` through `kwargs`.
    _won_run::Nullable{Base.RefValue{UInt64}}=nothing,
    kwargs...)::Union{Server, Nothing} where {H}

    # FIRST, before any validation or context mutation, so a rejected call leaves the context
    # byte-for-byte untouched. `startserver` assigns `ctx.service.server[]` unconditionally, so
    # without this guard a second `serve()` would overwrite the handle of a *live* server —
    # leaving it unreachable and its port bound for the life of the process, with nothing left
    # to close it. That is a programming error, not something to paper over by silently killing
    # the first server's in-flight requests.
    #
    # On the PHASE, not on `isopen` alone (#812): `terminate` closes the listener when its drain
    # starts, and a `serve` admitted from then on ran while the old run's `on_stopped` hooks were
    # still to come, so they released what the new run had just started using. This is the
    # read-only half; the claim itself is the compare-and-swap below, after validation.
    AppContext._idle(ctx.service) && !isopen(ctx.service) || throw(_not_idle_error(ctx))

    # Before any mutation (#401): the hook runs on every logged request, so a wrong shape -- a
    # non-function, or the old pre-handler `req -> Bool` -- is refused at the call that has it.
    access_log_skip === nothing || access_log_skip isa Function ||
        throw(ArgumentError("`access_log_skip` must be a `(req, resp) -> Bool` function or " *
                            "`nothing`, got $(repr(access_log_skip))"))
    _check_access_log_skip(access_log_skip, "serve(access_log_skip = …)")

    # Before any mutation too (#402). A bare header vector is the likely mistake: it would skip the
    # validation `SecurityHeaders(...)` does (HSTS preload rules), so it is refused, not wrapped.
    security_headers === nothing || security_headers isa SecurityHeaders ||
        throw(ArgumentError("`security_headers` must be a `SecurityHeaders(...)` value or " *
                            "`nothing`, got $(repr(security_headers))"))

    # Before any mutation as well (#718): a leaf put on the router without `path()` would be
    # refused on every request it matched, so the server is refused instead.
    _refuse_foreign_leaves(ctx.service.router)

    # `:$revise`, not `repr(revise)` (#571): `repr` of a `Symbol` goes through Base's
    # `show_unquoted` on an `Any`, which pulled the whole `show` machinery into every compiled
    # `serve` -- 310 of the 408 errors in the first `juliac --trim` build. Interpolating the
    # `Symbol` only `print`s its name.
    if revise ∉ (:none, :lazy, :eager)
        throw(ArgumentError("Invalid `revise` value :$revise. Expected one of :none, :lazy, or :eager."))
    end
    # Revise is a development tool and reaches the revised world through `invokelatest`, which a
    # trimmed image cannot make. Refused there, so every `revise` branch below folds away in one.
    if revise != :none && Types._trimmed()
        throw(ArgumentError(
            "`revise = :$revise` is not available in a trimmed build; serve with `revise = :none`."))
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

    # Same reasoning again (#298). Opt-in: `nothing` is unlimited, like Go's `net/http` and like
    # every Nitro before it. A count must be a real integer >= 1 — `0` would refuse every request,
    # which is never what a caller meant, and `true` would silently mean 1.
    if max_concurrent_requests !== nothing
        (max_concurrent_requests isa Integer && !(max_concurrent_requests isa Bool) &&
         1 <= max_concurrent_requests <= typemax(Int64)) ||
            throw(ArgumentError("`max_concurrent_requests` must be an integer >= 1, or `nothing` " *
                                "for no limit, got $(repr(max_concurrent_requests))"))
        # Mirrors `max_body_bytes`: the permit lives in Nitro's own `stream_handler`, around the
        # body read and the response write, so a custom `handler` cannot be capped by it.
        handler === stream_handler || throw(ArgumentError(
            "`max_concurrent_requests` cannot be applied to a custom `handler`: the cap is " *
            "enforced by Nitro's own `stream_handler`. Drop `handler`, or bound concurrency " *
            "inside it."))
    end
    request_limit = max_concurrent_requests === nothing ? zero(Int64) : Int64(max_concurrent_requests)

    # The WebSocket budget (#376), validated by the same rules for the same reasons: a socket
    # takes one of these at the upgrade and gives its `max_concurrent_requests` slot back, which
    # happens in Nitro's own `stream_handler` and WebSocket branch, so a custom `handler` cannot
    # have it either.
    if max_upgraded_connections !== nothing
        (max_upgraded_connections isa Integer && !(max_upgraded_connections isa Bool) &&
         1 <= max_upgraded_connections <= typemax(Int64)) ||
            throw(ArgumentError("`max_upgraded_connections` must be an integer >= 1, or `nothing` " *
                                "for no limit, got $(repr(max_upgraded_connections))"))
        handler === stream_handler || throw(ArgumentError(
            "`max_upgraded_connections` cannot be applied to a custom `handler`: the budget is " *
            "enforced by Nitro's own `stream_handler`. Drop `handler`, or bound WebSockets " *
            "inside it."))
    end
    upgraded_limit = max_upgraded_connections === nothing ? zero(Int64) : Int64(max_upgraded_connections)

    # Same reasoning as the checks above (#316): HTTP.jl only sees these at `listen!`, which runs
    # after the App has been mutated, so a typo'd timeout would otherwise fail half-way through.
    _validate_server_timeouts(kwargs)
    _validate_allow_h2c(kwargs)

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
    cookies = _serve_cookies(ctx.service.cookies[], secret_key, httponly, secure, samesite)

    # The claim (#812). Here, after every refusal above and before the first mutation below, so a
    # refused call leaves the App untouched and a call that loses the race to another `serve` is
    # refused the same way. From here on every failure before the server is up hands the phase
    # back to `PHASE_IDLE` (`_abandon_start!`), or the App could never serve again.
    # The new run's generation is the idle word's plus one (#834).
    idle_word = ctx.service.phase[]
    AppContext._phase(idle_word) === AppContext.PHASE_IDLE || throw(_not_idle_error(ctx))
    # Built before the swap, so no allocation (a safepoint) lies between winning it and the `try`.
    claim = StartClaim(AppContext._gen(idle_word) + one(UInt64), true)
    AppContext._claim_phase!(ctx.service, idle_word,
                             AppContext._word(claim.gen, AppContext.PHASE_STARTING)) ||
        throw(_not_idle_error(ctx))
    try
        isnothing(_won_run) || (_won_run[] = claim.gen)
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
            if Threads.nthreads() > 1
                @warn "You are attempting to use Revise with multiple threads. Please note that Revise 3.5.18 and earlier are not threadsafe."
            end
            if !has_revise_hooks()
                error("Revise support is unavailable. Load Revise.jl in your development session before using the `revise` option")
            end
            if ctx.mod === nothing
                @warn "`revise` was requested but this App tracks no module, so code in `Main` may not be revised. Construct it as `App(mod = @__MODULE__)` from the module you want tracked."
            end
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
        # The user's list only: `ReviseHandler()`, prepended below, is a plain closure, not a
        # `LifecycleMiddleware`, so it has nothing to register.
        register_serve_lifecycle!(ctx, middleware)

        # No warning for running on one thread (#149): single-threaded is a valid deployment, not a
        # misconfiguration, and the banner already reports the thread count. `preprocesskwargs` drops
        # `queuesize` unconditionally, so the warning that it is ignored is unconditional too.
        if haskey(kwargs, :queuesize)
            @warn "Deprecated: serve() ignores `queuesize`; remove the argument."
        end

        # One `setupmiddleware` call per branch, each handing its pipeline to `_serve_pipeline`
        # (#572). Prepending `ReviseHandler()` to `middleware` and building once made the list's type
        # a `Union` of the two, and a keyword call over a `Union` is one `juliac --trim` cannot
        # resolve, so the production path lost its typed pipeline to a dev-only option. Split like
        # this, the `revise = :none` branch is concrete all the way to `HTTP.listen!`.
        pipeline_kwargs = (; serialize, catch_errors, show_errors, access_log, access_log_query,
                           access_log_skip, security_headers)
        # `Types._trimmed()` first: Revise was refused above in a trimmed image, so the branch below is
        # dead there.
        if Types._trimmed() || revise == :none
            return _serve_pipeline(ctx, setupmiddleware(ctx; middleware, pipeline_kwargs...),
                                   handler, body_limit, request_limit, upgraded_limit, security_headers,
                                   revise, host, port, show_banner, async, kwargs, claim)
        end
        # Prepended without `insert!`, so the `Tuple` form works too. Dev-only, and dynamic on
        # purpose: `ReviseHandler` reaches the revised world through `invokelatest`.
        return _serve_pipeline(ctx, setupmiddleware(ctx; middleware = (ReviseHandler(), middleware...),
                                                    pipeline_kwargs...),
                               handler, body_limit, request_limit, upgraded_limit, security_headers,
                               revise, host, port, show_banner, async, kwargs, claim)
    catch
        claim.owns && _abandon_start!(ctx, claim)
        rethrow()
    end
end

# The rest of `serve`, once the pipeline exists: a function barrier, so everything below is
# specialized on the pipeline's concrete type (#572). `listener` and the `start` closure that
# captures it are typed by it.
#
# `P` and `H` are type parameters, not `::Function`, because Julia does not specialize a method
# on a `Function` argument it only passes on and never calls: this one would be compiled for
# `::Function` alone, and the call into `_serve_listener` would be dynamic again.
function _serve_pipeline(ctx::App, configured_middelware::P, handler::H, body_limit::Int64,
                         request_limit::Int64, upgraded_limit::Int64, security_headers,
                         revise::Symbol, host, port, show_banner, async,
                         kwargs, claim::StartClaim) where {P<:Function, H}
    # Once-assigned, because the `start` closure below captures it: a name reassigned before
    # capture is boxed (#364).
    listener = first(_serve_listener(configured_middelware, handler, body_limit, request_limit,
                                     upgraded_limit, security_headers))

    if !Types._trimmed() && revise == :eager
        # Never overwrite a live watcher: its handle is the only way to stop it (#427). `close`
        # is idempotent, so closing one `terminate` already closed costs nothing.
        previous = ctx.service.eager_revise[]
        previous === nothing || close(previous)
        ctx.service.eager_revise[] = start_revise_service()
    end

    # After every check Nitro itself makes, so a call Nitro refuses never warns (#299). HTTP.jl's
    # `listen!` can still refuse below (an address in use, say), after the warning has been
    # logged; that costs one accurate line about the process, which is harmless.
    _warn_if_no_gc_target(current_env(), _gc_target_bytes())

    # No close of the eager-Revise watcher here any more (#834). A start that never got its listener
    # up (an address in use, a cancel) returns no handle to `terminate`, so its watcher must stop
    # with it (#427), and `_abandon_start!`/`_unwind_start!` now close it before they hand the
    # App back to `IDLE`. Closing it here, after that, could close the watcher a racing `serve` had
    # just started. A run that served is stopped by `terminate`, whose `close` closes it.
    return startserver(ctx; host, port, show_banner, async, kwargs, claim, start=(kwargs) ->
        HTTP.listen!(listener, host, port; kwargs...))
end

# The `revise=:eager` watcher (#372). It used to be a bare `@async` loop, and each part of the
# spawn below answers one way that failed:
#
#   * `Threads.@spawn :default`, not `@async`. With `exit_on_sigint(false)` -- every REPL -- Julia
#     throws SIGINT into whichever task parked LAST on thread 1, and an `@async` task started from
#     `serve` is pinned there. This one re-parks after every revision, so the first Ctrl-C after a
#     file save killed the watcher instead of stopping `serve`; the second landed in the dead task
#     and aborted the process ("fatal: error thrown and no exception handler available"). Under
#     the default layout (since 1.12) thread 1 is the interactive thread, which the `:default` pool
#     never runs on, so the watcher cannot take a press at all. Running `revise()` off thread 1 is
#     not new: `revise=:lazy` already calls it from `Threads.@spawn`ed request tasks, and Revise
#     serializes it behind its own `ReentrantLock`. The only thing ever thrown into this task is
#     `close`'s `ReviseWaitCancelled` (#427), and only while it is parked in the hooks' own wait
#     (see `_cancel_revision_wait`, ext/NitroReviseExt.jl), so it may migrate freely.
#   * `errormonitor`, because nothing waits on this task. A throw used to be stored in the `Task`
#     and never seen, and eager revision stopped without a word.
#
# The hooks are read ONCE, here, and the loop and the service share them, so `close` cancels the
# wait the task is actually parked in, even if the hooks are re-registered in the meantime.
function start_revise_service()
    hooks = revise_hooks()
    done = Threads.Atomic{Bool}(false)
    revise_task = errormonitor(Threads.@spawn :default _eager_revise_loop(done, hooks))
    cancel = hooks === nothing ? (_ -> false) : hooks.cancel_revision_wait
    EagerReviseService(revise_task, done, cancel)
end

# The loop, named for the reason `_janitor_loop` is (src/middleware/janitor.jl): the placement of
# its `try`s is the whole point, and a named function lets a test drive it over hooks that throw.
#
# ── An interrupt that lands here anyway ──
#
# Only reachable with no interactive thread (`julia -t 1`), where every task shares thread 1. The
# answer is the one the Workers retention scheduler records next to `_cleanup_scheduler_loop`
# (src/Workers/api.jl), and the reasoning there is canonical: STOP, say so, and return normally.
# Rethrowing kills the task while `serve` keeps running; swallowing and looping re-parks it as the
# last task on thread 1, so it eats every later press too.
function _eager_revise_loop(done::Threads.Atomic{Bool}, hooks = revise_hooks())
    hooks === nothing && return nothing
    try
        while !done[]
            Base.invokelatest(hooks.wait_for_revision_event)
            done[] && break
            # INSIDE the `while`, as in `_janitor_loop`: a revision that throws costs that revision,
            # never the watcher. Revise reports a syntax error in a saved file itself and returns,
            # so this is the backstop for anything else.
            try
                @info "🗘  Starting eager revision"
                Base.invokelatest(hooks.revise)
                @info "👍 Eager revision finished"
            catch e
                # Rethrow guard, per the idiom in src/utilities/misc.jl: it routes an interrupt
                # that lands mid-revision to the handler below rather than looping on.
                e isa InterruptException && rethrow()
                @error "Nitro: eager revision failed" exception=(loggable(e), catch_backtrace())
            end
        end
    catch e
        # `close` woke us out of the wait (#427): the server that started this watcher is gone.
        # That is the normal way to stop, so there is nothing to report.
        e isa ReviseWaitCancelled && return nothing
        e isa InterruptException || rethrow()
        @warn "Nitro: an interrupt (Ctrl-C) reached the eager-Revise watcher instead of the " *
              "server. Eager revision has stopped until the server is started again. Press " *
              "Ctrl-C again to stop the server. Outside a REPL, that press can end the process " *
              "without running its shutdown hooks."
    end
    return nothing
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
#
# Every hook runs inside `IN_LIFECYCLE_HOOK` (#834), so a `terminate` it calls never waits for the
# run that is running it.
#
# `hook::F`, a type parameter: this method only passes `hook` on, so a `::Function` argument would
# not be specialized, and the call in `_broadcast_entries` would be dynamic on the serve path (#572).
function _broadcast_lifecycle(hook::F, entries,
                              interrupt::Nullable{InterruptException} = nothing
                             )::Nullable{InterruptException} where {F<:Function}
    return @with IN_LIFECYCLE_HOOK => true _broadcast_entries(hook, entries, interrupt)
end

function _broadcast_entries(hook::F, entries,
                            interrupt::Nullable{InterruptException}
                           )::Nullable{InterruptException} where {F<:Function}
    for lf in entries
        raised = hook(lf)
        isnothing(interrupt) && (interrupt = raised)
    end
    return interrupt
end

# `startserver`'s startup broadcast: route-owned hooks first, then serve-owned (#82).
_startup_hooks(route_lf, serve_lf)::Nullable{InterruptException} =
    _broadcast_lifecycle(startup, serve_lf, _broadcast_lifecycle(startup, route_lf))

# Outside a REPL, the startup broadcast runs on a `:default` task, not on thread 1 (#824). A
# SIGTERM ends a script by running the `atexit` hooks on thread 1, on top of whatever thread 1 was
# running (`jl_exit_thread0`), and that frame never resumes. Startup hooks compile a great deal the
# first time they run: the Workers boot sweep, a store's first queries, the log records they write.
# A signal that lands mid-compile leaves the exit path behind the JIT state the frozen frame holds,
# and the process never exits: a served PormG app hung that way on every SIGTERM sent while its
# boot sweep ran. On a `:default` thread the compile goes on to the end and thread 1 waits in the
# scheduler, where the same signal exits at once.
#
# Two conditions. Thread 1 is in the interactive pool, so a `:default` task can never land on it:
# under `-t 1` (`1,0`) or an `N,0` layout every thread is a default one, and the broadcast stays
# where it is. And not in a REPL, where Ctrl-C is how an operator aborts a hook that hangs, and the
# press reaches the task parked on thread 1, which would be the wait below and not the hook.
# Outside one a press ends the process the way a SIGTERM does, unless the script has turned that
# off with `Base.exit_on_sigint(false)`. Then the press reaches the wait below, which defers it
# until the hooks return, so it no longer aborts a hook that hangs; a SIGTERM still ends the process.
#
# The hooks are not stopped by the exit. While thread 1 runs the `atexit` hooks (PormG's closes
# its pools), the broadcast goes on running on its own thread, and a hook mid-query can log the
# error the closed pool gives it before the process ends.
_startup_off_thread1() = !isinteractive() && Threads.threadpool(1) === :interactive

function _startup_broadcast(route_lf, serve_lf)::Nullable{InterruptException}
    _startup_off_thread1() || return _startup_hooks(route_lf, serve_lf)
    # Whatever escapes the broadcast is handed back rather than thrown (`startup` itself catches a
    # hook's own exception, so this is something structural, see `startserver`), so the wait below
    # raises only an interrupt of its own. The caller gets the exception itself, its type and value,
    # not wrapped in a `TaskFailedException`; its backtrace starts here, not in the broadcast.
    task = Threads.@spawn :default try
        _startup_hooks(route_lf, serve_lf)
    catch e
        e
    end
    interrupt = nothing
    while true
        try
            wait(task)
            break
        catch e
            # A Ctrl-C reaches this wait only under `exit_on_sigint(false)` (see above). The hooks
            # run on to the end, as the broadcast always does, and the interrupt is deferred with
            # theirs (#185).
            e isa InterruptException || rethrow()
            interrupt = something(interrupt, e)
        end
    end
    result = fetch(task)
    result isa InterruptException && return something(interrupt, result)
    isnothing(result) || throw(result)
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
                Types._trimmed_note("Nitro: a second interrupt during the force-close; the listener " *
                                    "may still be open")  # a trimmed build drops the record (#846)
            else
                @error "Nitro: force-close after an interrupted drain failed" exception=(loggable(forced), catch_backtrace())
                Types._trimmed_failure("force-close after an interrupted drain", forced)  # #846
            end
        end
        return something(interrupt, e)
    end
    return interrupt
end

# The teardown both ends of a run share: `terminate` stopping a run that is serving, and
# `_unwind_start!` undoing one whose startup hooks ran but which never got its listener (#799).
# Every hook in the snapshot gets its `on_shutdown`, then its `on_stopped`, LIFO, with the
# listener closed between the two when there is one. Returns the first interrupt any of it raised
# (#185), for the caller to re-raise once everything else is done; it never throws one itself.
#
# LIFO (#74): the exact reverse of `startserver`'s startup sequence, which ran route-owned then
# serve-owned, each in registration order. So: serve-owned reversed, then route-owned reversed.
# Teardown order is a specified contract, not hash order — see `Service` (src/context.jl) for why
# LIFO and not something else.
function _teardown!(context::App, route_lf, serve_lf,
                    interrupt::Nullable{InterruptException};
                    listener::Bool, timeout::Real)::Nullable{InterruptException}
    # Deferred, not broadcast-and-pray (#185): an interrupt from any hook is carried past the
    # rest of the sequence and handed back, so the clears and the `close` below are
    # unconditional.
    #
    # The `try` is around the broadcasts, not inside them, because `startup`/`shutdown` can
    # only catch an interrupt that lands INSIDE a hook frame. SIGINT is delivered at
    # safepoints, and the loop itself has several — so a press between two hooks would
    # otherwise escape bare and skip everything below. Catching here costs the remaining hooks
    # (they are unreachable once the stack has unwound) but never the teardown *below*.
    #
    # The clears below stay bare, deliberately. No user code runs in them, so the window is
    # bounded by `lifecycle_lock` contention rather than by a hook, and extending the `try` over
    # them would be protecting statements that are themselves partial-state transitions — a
    # half-run clear is worse than a skipped one.
    try
        interrupt = _broadcast_lifecycle(shutdown, Iterators.reverse(serve_lf), interrupt)
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
    # Post-drain (#161), in the `finally`: the listener is closed and no request is served any
    # more, so this is where a hook releases what a request could still have been using — a
    # pool closed in `on_shutdown` was cut from under the drain, and reopened by the next
    # request it served. A `finally` so that a `close` that throws something other than an
    # interrupt still releases them, and so no safepoint lies between the close and the hooks.
    # Over the caller's snapshot, in the same LIFO order: `serve_lifecycle` is empty by now, and
    # the snapshot is exactly the set this run started. The inner `try` is the shutdown
    # broadcasts' own, for the same between-hooks interrupt.
    try
        listener && (interrupt = _close_deferring_interrupt(context.service, timeout, interrupt))
    finally
        try
            interrupt = _broadcast_lifecycle(stopped, Iterators.reverse(serve_lf), interrupt)
            interrupt = _broadcast_lifecycle(stopped, Iterators.reverse(route_lf), interrupt)
        catch e
            e isa InterruptException || rethrow()
            interrupt = something(interrupt, e)
        end
    end
    return interrupt
end

# Documented on the public `Nitro.terminate` (src/methods.jl); see the note on `serve` above.
#
# It stops the run that is current when it is called, and only that one (#834): the generation is
# read once, here, and `_terminate_run` gives up as soon as it has moved on.
terminate(context::App; timeout::Nullable{Real} = nothing) =
    _terminate_run(context, AppContext._gen(context.service.phase[]); timeout)

# Stop run `gen` of `context`, whatever phase it is in, and return once it is idle (#834).
#
# - SERVING: claim `STOPPING` and stop it here. The phase, not `isopen` (#812): the claim makes a
#   second, concurrent `terminate` wait rather than run every hook again, and it is what keeps
#   `serve` refused until the very end of the stop.
# - STARTING: claim `CANCELLING`. The start sees it at its next check (`startserver`), unwinds
#   whatever hooks ran without ever opening the port, and settles the run back to `IDLE`, which is
#   what this waits for. Spring's `close()` waits out a `refresh()` in progress the same way; Go's
#   `Shutdown` before `Serve` makes `Serve` return `ErrServerClosed` — here `serve` returns `nothing`.
# - CANCELLING or STOPPING: another call is already doing it; wait for it to finish. Returning at
#   once, as #812 did, let a caller that then followed `serve`'s own advice ("wait for `terminate`
#   to return") be refused as still stopping.
#
# Every wait is skipped inside a lifecycle hook (`IN_LIFECYCLE_HOOK`), where the run being waited
# for is the one running the hook. A failed compare-and-swap means the run moved on between the
# read and the claim, so the word is read again, and a new generation means the run is over.
function _terminate_run(context::App, gen::UInt64; timeout::Nullable{Real} = nothing)
    service = context.service
    while true
        word = service.phase[]
        AppContext._gen(word) === gen || return nothing
        phase = AppContext._phase(word)
        if phase === AppContext.PHASE_SERVING
            AppContext._claim_phase!(service, word,
                                     AppContext._word(gen, AppContext.PHASE_STOPPING)) || continue
            return _stop_serving!(context, gen, timeout)
        elseif phase === AppContext.PHASE_STARTING
            cancelling = AppContext._word(gen, AppContext.PHASE_CANCELLING)
            AppContext._claim_phase!(service, word, cancelling) || continue
            IN_LIFECYCLE_HOOK[] || AppContext._await_phase_change(service, cancelling)
            return nothing
        elseif phase === AppContext.PHASE_CANCELLING || phase === AppContext.PHASE_STOPPING
            IN_LIFECYCLE_HOOK[] || AppContext._await_phase_change(service, word)
            return nothing
        end
        return nothing
    end
end

# The stop itself, once `_terminate_run` holds `STOPPING` for run `gen`.
function _stop_serving!(context::App, gen::UInt64, timeout::Nullable{Real})
    interrupt = nothing
    try
        # First, before any hook can block: every in-flight request now reads `:shutdown` from
        # `cancel_reason(req)` (#466), so a handler that polls it winds down during the drain
        # below instead of being force-closed at its end, and every `Res.pause` parked on this
        # run returns `false` at once (#815). Swap, then signal: the pipelines of this run
        # captured the old signal, and anything built from now on gets the fresh one.
        stopping = context.service.shutting_down[]
        context.service.shutting_down[] = Constants.ShutdownSignal()
        Constants.signal_shutdown!(stopping)
        route_lf, serve_lf = lifecycle_snapshot(context)
        interrupt = _teardown!(context, route_lf, serve_lf, nothing; listener = true,
                               timeout = something(timeout, context.service.shutdown_timeout[]))
    finally
        # After the last `on_stopped` hook, and in a `finally`: whatever escapes above, an App left
        # in `PHASE_STOPPING` could never serve again. It also wakes every `terminate` that found
        # this one running (#834).
        AppContext._settle_idle!(context.service, gen)
    end
    # Re-raised only now: everything a later `serve()` depends on has already been done.
    isnothing(interrupt) || throw(interrupt)
    return nothing
end

# Undo a start whose startup hooks ran but which never got as far as serving (#799): an interrupt
# in a hook, something structural escaping the broadcast, or a listener that would not bind. No
# request was ever served, so there is nothing to drain and no shutdown flag to set; every hook
# in the snapshot still gets its `on_shutdown` and `on_stopped`, including an interrupted one,
# whose `on_startup` only got part-way. That is what the idempotency contract on
# `LifecycleMiddleware` (src/types.jl) exists to make safe — `_janitor` and `AccessLog` both no-op
# on an inactive activation.
#
# The unwind hands the phase back to `IDLE` itself, last, and tells `serve` it no longer owns the
# start first, so `serve`'s own reset cannot undo a later claim. Settling to `IDLE` also wakes a
# `terminate` that cancelled this start (#834). Returns the first interrupt, `interrupt` included,
# for the caller to raise.
function _unwind_start!(ctx::App, claim::StartClaim, route_lf, serve_lf,
                        interrupt::Nullable{InterruptException})::Nullable{InterruptException}
    claim.owns = false
    try
        interrupt = _teardown!(ctx, route_lf, serve_lf, interrupt; listener = false, timeout = 0)
    finally
        # Before the settle, for the reason `_abandon_start!` gives (#427, #834), and nested so
        # that a close that throws still settles: `owns` is already clear, so nothing else would.
        try
            AppContext._close_eager_revise(ctx.service)
        finally
            AppContext._settle_idle!(ctx.service, claim.gen)
        end
    end
    return interrupt
end

# Close a listener `startserver` opened but never handed over (#834): the start was cancelled, or
# something threw before the run reached `SERVING`. The listener has been accepting since the
# bind, so a request may be in flight; it is cut, not drained, as a start that never began serving
# owes nobody a graceful stop. The handle is cleared only if it is still this listener's.
function _drop_listener!(ctx::App, server::Server)
    try
        HTTP.forceclose(server)
    catch e
        # Never rethrown: the caller unwinds the hooks next, and whatever it carries is what
        # `serve` reports. Shutdown code never throws (concurrency §4); a second interrupt is
        # dropped here, like the shutdown paths' (#185).
        if !(e isa InterruptException)
            @error "Nitro: closing a listener whose start was abandoned failed" exception=(loggable(e), catch_backtrace())
            Types._trimmed_failure("closing a listener whose start was abandoned", e)  # #846
        end
    end
    handle = ctx.service.server[]
    !isnothing(handle) && handle.server === server && (ctx.service.server[] = nothing)
    return nothing
end

function startserver(ctx::App; host, port, show_banner=false, async=false, kwargs,
                     claim::StartClaim, start)::Union{Server, Nothing}
    # Cancelled by `terminate` before a single hook ran (#834): nothing to unwind but the claim.
    if _start_cancelled(ctx, claim)
        _abandon_start!(ctx, claim)
        return nothing
    end
    # The startup hooks run FIRST, and the listener opens only once they have all returned
    # (#799). A port that answers is then an app that is ready: its worker runtime installed, its
    # janitors running, what its hooks compile compiled. Opening it first, as `serve` used to, let
    # a TCP probe, a proxy's upstream check or a client in while the app was still initialising.
    # The lineage agrees: Spring finishes bean initialisation before the embedded server accepts a
    # connection, and Django runs every `AppConfig.ready()` before it serves.
    #
    # Route-owned first, then serve-owned: that is declaration order — routes are registered at
    # `urlpatterns()` time, the `serve(middleware = ...)` list only at `serve()` time (#82).
    # Within each half, registration order. `terminate` unwinds the exact reverse (#74).
    #
    # Over a snapshot, not the live vectors: a `revise=:lazy` re-registration runs on a
    # request-handling task and could otherwise `push!` while this broadcast iterates.
    route_lf, serve_lf = lifecycle_snapshot(ctx)
    # Around the broadcasts for the same reason `_teardown!` wraps its own: a hook frame is the
    # only place `startup` can catch an interrupt, and a press landing between two hooks would
    # otherwise skip the unwind below.
    interrupt = nothing
    try
        interrupt = _startup_broadcast(route_lf, serve_lf)
    catch e
        # Something structural (a throwing logger, an async failure): `startup` catches whatever a
        # hook throws, so reaching this line means the broadcast itself broke. It used to strand
        # the open listener, on purpose, as the loud signal; with no listener yet, the hooks that
        # ran are unwound and the error is raised as it was.
        if !(e isa InterruptException)
            _unwind_start!(ctx, claim, route_lf, serve_lf, nothing)
            rethrow()
        end
        interrupt = something(interrupt, e)
    end
    if !isnothing(interrupt)
        # Unwind the hooks that ran, then re-raise once (#185). A SECOND Ctrl-C during the unwind
        # is folded into the first: one `InterruptException` is indistinguishable from another.
        throw(something(_unwind_start!(ctx, claim, route_lf, serve_lf, interrupt), interrupt))
    end
    # Cancelled by `terminate` while the hooks ran (#834): they all returned, so each gets its
    # teardown, and the port is never opened.
    if _start_cancelled(ctx, claim)
        # An interrupt raised in the teardown is re-raised once it is done, as every unwind does (#185).
        unwound = _unwind_start!(ctx, claim, route_lf, serve_lf, nothing)
        isnothing(unwound) || throw(unwound)
        return nothing
    end

    # Concrete here, so this is where a trimmed build takes the handle's pointers (src/context.jl).
    server = try
        start(preprocesskwargs(kwargs))
    catch
        # An address in use, a refused bind, or a Ctrl-C landing here: the hooks above all ran, so
        # each gets its teardown, and the bind's own error is what the caller sees.
        _unwind_start!(ctx, claim, route_lf, serve_lf, nothing)
        rethrow()
    end
    # The hand-over to `terminate` (#812): the handle first, so a `terminate` that sees `SERVING`
    # always finds a listener to close, then the phase, by compare-and-swap. A plain store would
    # overwrite a `CANCELLING` that landed after the check above (#834); the swap fails on it
    # instead, and the start is dropped here exactly as it would have been before the bind.
    #
    # Guarded, because building the handle allocates and so is a safepoint: an interrupt landing
    # there left the hooks started and the listener open, with no teardown (#834). Until the swap
    # succeeds this call still owns the start, so whatever happens in the block, it closes the
    # listener and unwinds the hooks itself.
    serving = try
        ctx.service.server[] = AppContext.ServerHandle(server)
        AppContext._claim_phase!(ctx.service, AppContext._word(claim.gen, AppContext.PHASE_STARTING),
                                 AppContext._word(claim.gen, AppContext.PHASE_SERVING))
    catch
        _drop_listener!(ctx, server)
        _unwind_start!(ctx, claim, route_lf, serve_lf, nothing)
        rethrow()
    end
    if !serving
        _drop_listener!(ctx, server)
        unwound = _unwind_start!(ctx, claim, route_lf, serve_lf, nothing)
        isnothing(unwound) || throw(unwound)
        return nothing
    end
    # The run is `terminate`'s to stop from here on, so `serve` no longer owns the start. A field
    # store, no safepoint: an interrupt landing before it would reach `serve`'s reset while it
    # still owned the start, which hands the phase back to `IDLE` over an open listener.
    claim.owns = false
    # Every exit from here on goes through `terminate`, whose `close` releases it. A no-op outside
    # the Julia versions JuliaLang/julia#63882 affects (src/context.jl).
    AppContext._hold_wake_guard!(ctx.service)
    # Once the port answers, so the banner never announces a server that is not there yet.
    show_banner && serverwelcome(ctx.service.external_url[], ctx.service.prefix[])

    if !async
        try
            # This run's own server, whose type is concrete here, rather than through the handle.
            wait(server)
        catch error
            if !isa(error, InterruptException)
                @error "ERROR: " exception=(loggable(error), catch_backtrace())
                Types._trimmed_failure("the serve task", error)  # a trimmed build drops the record (#846)
            end
        finally
            _with_stdout(out -> println(out))
            # Ctrl-C out of the blocking wait is THE documented way to stop a blocking `serve` —
            # the banner says so. Without this the listener survives the interrupt and only a
            # process restart clears it. THIS run only (#834): it is a no-op once the run is over,
            # so this is safe on the normal exit path too, and idempotent against the blocking
            # wrappers' own cleanup in `src/methods.jl`. If another task's `terminate` is what
            # ended the wait, this waits for that stop to finish, so a blocking `serve` returns
            # only once its run's last `on_stopped` hook has.
            try
                _terminate_run(ctx, claim.gen)
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

    return server
end

# The keywords `serve` hands `HTTP.listen!`, as a `NamedTuple`. `serve`'s `kwargs...` already have
# a concrete type, and a `NamedTuple` keeps it all the way into the keyword call: a `Dict{Symbol,Any}`
# made the call `juliac --trim` cannot resolve, the last wall in front of the request path
# (docs/design/juliac-trim.md §3). Every key the caller passed still reaches `listen!`, so a keyword
# it does not take is still refused by its own `MethodError` (#525), and every value still meets its
# own type checks. Each step below is a function of the key NAMES alone, which are part of the type,
# so inference folds every branch.
function preprocesskwargs(kwargs::Base.Pairs)
    # HTTP.jl v2's `listen!` is already Stream-based, so the v1 `stream=true` flag is
    # gone. Access logging (the old `logfmt`/`access_log` default) is now handled by
    # `AccessLogMiddleware` in the middleware chain instead.
    #
    # `listen!` rejects unknown keyword arguments. Drop v1-only server kwargs that Nitro
    # still tolerates for back-compat (a deprecation warning is emitted in `serve`).
    kw = Base.structdiff(values(kwargs), NamedTuple{(:queuesize,)})
    # `SO_REUSEADDR` means something fundamentally different on Windows. On POSIX it only lets
    # you bind over sockets in TIME_WAIT, which is load-bearing for restarting onto a port you
    # just shut down. On Windows it lets a second process bind a port another process is
    # *actively listening on*, with indeterminate delivery between the two — which is why
    # Microsoft had to add SO_EXCLUSIVEADDRUSE. HTTP.jl defaults it to `true` everywhere, so on
    # Windows an orphaned Nitro process turns "port already taken" from a loud bind failure into
    # a silent split-brain where some requests are answered by the corpse, out of *its* router.
    # Merged in FIRST, so an explicit `serve(reuseaddr = …)` overrides it.
    kw = merge((reuseaddr = !Sys.iswindows(),), kw)
    # HTTP.jl disables every server timeout by default, which leaves a half-sent head or a silent
    # connection holding its socket forever (#316). Nitro defaults the two that cannot cut a
    # legitimate stream; `read_timeout` and `write_timeout` stay opt-in. The values, and why
    # they are what they are, are on the constants (src/constants.jl).
    #
    # Written only when NEITHER spelling is present: HTTP.jl takes each timeout in seconds (`X`)
    # or nanoseconds (`X_ns`) and throws when it gets both, so defaulting `X` next to a caller's
    # `X_ns` would turn a valid call into an error. An explicit `0` or `nothing` is a value, so it
    # wins — both mean "disabled" to HTTP.jl.
    kw = _default_timeout(kw, Val(:read_header_timeout), Val(:read_header_timeout_ns),
                          DEFAULT_READ_HEADER_TIMEOUT_SECONDS)
    kw = _default_timeout(kw, Val(:idle_timeout), Val(:idle_timeout_ns),
                          DEFAULT_IDLE_TIMEOUT_SECONDS)
    # Nitro speaks HTTP/1.1 only (#375). HTTP.jl serves a plaintext connection that opens with the
    # cleartext HTTP/2 (h2c) prior-knowledge preface as HTTP/2 unless told otherwise, and Nitro's
    # stream-level code was written for HTTP/1.1: on an h2 stream a 413 or 503 refusal cannot bound
    # its swallow in time (an announced body that never arrives holds a `max_concurrent_requests`
    # slot indefinitely), and HTTP.jl's h2 server leaks flow-control credit and stream state when
    # it discards a body. No browser speaks h2c, and `serve` binds plaintext only, so HTTP/2
    # belongs at the TLS-terminating proxy. Go (`Protocols.SetUnencryptedHTTP2`) and Node (a
    # separate `http2.createServer`) also keep h2c off a plain listener by default.
    #
    # With `allow_h2c = false` (HTTP.jl 2.9) every plain connection goes to the HTTP/1.1 parser
    # untouched; a preface fails as a request line with no `Host` and is answered 400 with the
    # connection closed. Before 2.9 there was no switch, and Nitro overrode HTTP's private preface
    # probe instead. Written unconditionally: `_validate_allow_h2c` has already refused a caller
    # who asked for anything else.
    return merge(kw, (allow_h2c = false,))
end

# `kw` with `name = default` added, unless the caller passed `name` or `ns_name`. The names travel
# as `Val`s so the test is on the type: it folds, and so does the shape of the result.
@inline function _default_timeout(kw::NamedTuple{names}, ::Val{name}, ::Val{ns_name},
                                  default) where {names, name, ns_name}
    (name in names || ns_name in names) && return kw
    return merge(NamedTuple{(name,)}((default,)), kw)
end

# Refuse `serve(allow_h2c = true)` at the call, rather than quietly overriding it in
# `preprocesskwargs` (#375). HTTP.jl accepts the keyword since 2.9, so without this check it
# would ride `kwargs...` to `listen!` and look like a supported way to turn h2c back on.
function _validate_allow_h2c(kwargs)
    Base.get(kwargs, :allow_h2c, false) === false || throw(ArgumentError(
        "`allow_h2c` must be `false`: Nitro serves HTTP/1.1 only on its plaintext listener " *
        "(#375). Terminate HTTP/2 at a TLS proxy in front of Nitro instead."))
    return nothing
end

# The server timeouts HTTP.jl's `listen!` accepts, in their seconds spelling (#316). `readtimeout`
# is HTTP.jl's deprecated alias for `read_timeout` and still accepted there.
const _SERVER_TIMEOUT_KWARGS = (:read_header_timeout, :read_timeout, :idle_timeout, :write_timeout,
                                :readtimeout)
const _SERVER_TIMEOUT_NS_KWARGS = (:read_header_timeout_ns, :read_timeout_ns, :idle_timeout_ns,
                                   :write_timeout_ns)

# Refuse a timeout HTTP.jl would reject, at the `serve` call that contains it. HTTP.jl makes the
# same checks (`_timeout_ns_from_seconds`, `_resolve_server_timeouts`), but only inside `listen!` —
# after `serve` has already mutated the App. Each rule below mirrors one of HTTP.jl's, so the two
# agree on exactly which calls are valid. Seconds may be any finite real `>= 0` that fits in
# `Int64` nanoseconds, or `nothing`; `Inf` is refused rather than read as "never", because
# `0`/`nothing` is how HTTP.jl spells never.
function _validate_server_timeouts(kwargs)
    for (name, value) in pairs(kwargs)
        if name in _SERVER_TIMEOUT_KWARGS
            # Compared in Float64, as HTTP.jl converts it: `Float64(value) * 1e9` must stay below
            # 2^63 to round into `Int64` nanoseconds. Rounding first would throw `InexactError`
            # rather than this `ArgumentError` for a value near 1e30, or a `BigFloat` past Float64.
            value === nothing ||
                (value isa Real && !(value isa Bool) && isfinite(Float64(value)) && value >= 0 &&
                 Float64(value) * 1.0e9 < 2.0^63) ||
                throw(ArgumentError("`$name` must be a finite number of seconds >= 0, or " *
                    "`nothing` (`0` and `nothing` both disable it), got $(repr(value))"))
        elseif name in _SERVER_TIMEOUT_NS_KWARGS
            (value isa Integer && !(value isa Bool) && 0 <= value <= typemax(Int64)) ||
                throw(ArgumentError("`$name` must be an integer number of nanoseconds >= 0 " *
                    "(`0` disables it), got $(repr(value))"))
        end
    end
    # One timeout, two spellings: HTTP.jl throws when both carry a value. "Carries a value" is
    # HTTP.jl's own test — a seconds form that is not `nothing`, an `_ns` form that is not `0`.
    given(name) = get(kwargs, name, nothing) !== nothing
    given_ns(name) = get(kwargs, name, 0) != 0
    for name in (:read_header_timeout, :read_timeout, :idle_timeout, :write_timeout)
        ns_name = Symbol(name, :_ns)
        given(name) && given_ns(ns_name) &&
            throw(ArgumentError("`$name` cannot be combined with `$ns_name`; pass one of them"))
    end
    if given(:readtimeout) && (given(:read_timeout) || given_ns(:read_timeout_ns))
        throw(ArgumentError("`readtimeout` (deprecated) cannot be combined with `read_timeout` " *
                            "or `read_timeout_ns`; pass `read_timeout`"))
    end
    return nothing
end
