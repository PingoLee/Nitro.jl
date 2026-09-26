@testitem "Server lifecycle: bounded shutdown, serve guard, reuseaddr" tags=[:core, :network] setup=[NitroCommon] begin

using Test
using HTTP
using Sockets
using Nitro
using Nitro: path

# Almost every testset here runs on a *private* `App`, so it mutates no global
# router/server state. That also means the `test_end_expr` net in `test/runtests.jl` (which
# calls the global `Nitro.terminate()`) does NOT cover these servers — each testset cleans
# up in its own `finally`.
#
# The one exception is "a rejected serve() does not tear down the server it was protecting",
# which *must* use the global `Nitro.serve()`: the defect it guards lives in that wrapper's
# cleanup `finally` (`src/methods.jl`), which the context-taking `Nitro.Core.serve` has no
# equivalent of. It restores global state with `resetstate()` in its own `finally`.

"""
Register a route whose handler parks inside the stream until `release` is notified, so its
connection is pinned `ACTIVE`. HTTP 2.4 declares `_ConnState.HIJACKED` and never assigns it,
so this is exactly the shape that made the pre-#73 `terminate()` spin forever.
"""
function _pinning_context(entered::Base.Event, release::Base.Event)
    ctx = Nitro.Core.App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/hang", function(stream::HTTP.Stream)
            HTTP.setheader(stream, "Content-Type" => "text/plain")
            startwrite(stream)
            write(stream, "open")
            notify(entered)
            wait(release)
            closewrite(stream)
            return nothing
        end, method="STREAM"),
    ])
    return ctx
end

_serve(ctx, port; kw...) = Nitro.Core.serve(ctx; port, host=HOST, async=true,
                                            show_banner=false, show_errors=false,
                                            access_log=nothing, kw...)

@testset "terminate() is bounded even with a connection pinned ACTIVE" begin
    entered, release = Base.Event(), Base.Event()
    ctx  = _pinning_context(entered, release)
    port = get_free_port()
    srv  = _serve(ctx, port)
    sock = nothing

    try
        # A raw socket, not HTTP.jl's client: no connection pool, no retry, no reconnect —
        # exactly one connection, held open, deterministically.
        sock = Sockets.connect(Sockets.localhost, port)
        write(sock, "GET /hang HTTP/1.1\r\nHost: $HOST\r\nConnection: keep-alive\r\n\r\n")
        flush(sock)
        wait(entered)   # the handler is inside the stream => its connection is ACTIVE

        # Run terminate on its own task and wait on the TASK, never inline: against an
        # unpatched `terminate()` this fails at 20s instead of wedging the whole suite.
        stopping = Threads.@spawn Nitro.Core.terminate(ctx; timeout = 1.0)

        # Liveness, not latency. 20s is ~20x the configured timeout, so this can only fail if
        # terminate() never returns. Do NOT tighten it into a stopwatch assertion — that buys
        # a flake on a loaded Windows/macOS runner.
        @test timedwait(() -> istaskdone(stopping), 20.0; pollint = 0.1) === :ok
        # `istaskdone` is also true for a task that DIED. Without this, the assertion above
        # passes vacuously against any build where terminate() throws immediately — which is
        # exactly what an unpatched Nitro does (no `timeout` kwarg => MethodError).
        @test !istaskfailed(stopping)
        @test !isopen(ctx.service)
        @test isnothing(ctx.service.server[])   # handle released, not left orphaned

        # The assertion that actually maps to the reported symptom: a stale process owning
        # the port. If the listener were still bound this would throw.
        probe = Sockets.listen(Sockets.localhost, port)
        close(probe)
    finally
        notify(release)
        isnothing(sock) || close(sock)
        # Survives even a regression in terminate() itself, so one failure here cannot
        # strand the port for every later test item.
        isnothing(srv) || HTTP.forceclose(srv)
    end
end

@testset "the forced path is actually taken, and warns" begin
    entered, release = Base.Event(), Base.Event()
    ctx  = _pinning_context(entered, release)
    port = get_free_port()
    srv  = _serve(ctx, port)
    sock = nothing

    try
        sock = Sockets.connect(Sockets.localhost, port)
        write(sock, "GET /hang HTTP/1.1\r\nHost: $HOST\r\nConnection: keep-alive\r\n\r\n")
        flush(sock)
        wait(entered)

        # Assert the escalation happened, not merely that we survived: without this, a
        # `terminate()` that silently dropped the graceful phase would still pass above.
        forced = nothing
        @test_logs (:warn, r"did not drain") match_mode=:any begin
            forced = Nitro.Core.AppContext._shutdown_server(srv; timeout = 0.2)
        end
        @test forced === false          # false == "had to be forced"
    finally
        notify(release)
        isnothing(sock) || close(sock)
        isnothing(srv) || HTTP.forceclose(srv)
        ctx.service.server[] = nothing
    end
end

@testset "a clean server drains gracefully instead of being forced" begin
    ctx  = Nitro.Core.App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/ok", (req) -> Res.send("ok"), method="GET"),
    ])
    port = get_free_port()
    srv  = _serve(ctx, port)
    try
        @test HTTP.get("http://$HOST:$port/ok"; retry=false).status == 200
        # Nothing is pinned, so this must return `true` (drained on its own) and emit no
        # warning — the counterpart to the forced case above. `Base.CoreLogging.Warn` rather
        # than `Logging.Warn`: Logging is not a test dependency. No `match_mode=:any` here —
        # with zero patterns that reduces to `all(())` and asserts nothing at all.
        drained = @test_logs min_level=Base.CoreLogging.Warn Nitro.Core.AppContext._shutdown_server(srv; timeout = 5.0)
        @test drained === true
    finally
        isnothing(srv) || HTTP.forceclose(srv)
        ctx.service.server[] = nothing
    end
end

@testset "serve() refuses to start over a live server" begin
    ctx  = Nitro.Core.App()
    port = get_free_port()
    srv  = _serve(ctx, port)
    try
        @test_throws ArgumentError _serve(ctx, get_free_port())
        @test ctx.service.server[] === srv        # the live handle was NOT overwritten
        @test isopen(ctx.service)
        # Proves the guard sits *before* serve()'s context mutations. This is the assertion
        # that catches a later refactor moving it below them.
        @test ctx.service.external_url[] == "http://$HOST:$port"
    finally
        Nitro.Core.terminate(ctx)
    end

    @test isnothing(ctx.service.server[])          # close(::Service) released the handle
    srv2 = _serve(ctx, get_free_port())            # a terminated context accepts a fresh serve
    try
        @test srv2 !== srv
    finally
        Nitro.Core.terminate(ctx)
    end
end

@testset "a serve() during the drain window is not stranded by the finishing terminate()" begin
    # `HTTP.close` releases the listener up front, so `isopen(service)` goes false while the
    # drain is still running and a concurrent `serve()` is admitted. If the finishing
    # `close(::Service)` then cleared `server[]` unconditionally it would strand that new
    # server: live, listening, and unreachable from `terminate()` — the exact leak this
    # change exists to remove, just through a narrower window.
    entered, release = Base.Event(), Base.Event()
    ctx  = _pinning_context(entered, release)
    p1   = get_free_port()
    srvA = _serve(ctx, p1)
    sock, srvB = nothing, nothing

    try
        sock = Sockets.connect(Sockets.localhost, p1)
        write(sock, "GET /hang HTTP/1.1\r\nHost: $HOST\r\n\r\n")
        flush(sock)
        wait(entered)

        stopping = Threads.@spawn Nitro.Core.terminate(ctx; timeout = 2.0)
        # Wait for the listener to be released — that is the window's opening edge.
        @test timedwait(() -> !isopen(ctx.service), 10.0; pollint = 0.05) === :ok

        srvB = _serve(ctx, get_free_port())
        @test ctx.service.server[] === srvB
        # Self-verifying: assert we really are inside the window. Without this, a pathological
        # runner where the drain finished first would silently degrade to green-without-testing.
        @test !istaskdone(stopping)

        @test timedwait(() -> istaskdone(stopping), 20.0; pollint = 0.1) === :ok
        @test !istaskfailed(stopping)

        # The decisive assertion: B's handle survived A's shutdown, so B is still reachable
        # from terminate() rather than being a permanently-bound orphan.
        @test ctx.service.server[] === srvB
        @test isopen(ctx.service)
    finally
        notify(release)
        isnothing(sock) || close(sock)
        isnothing(srvB) || HTTP.forceclose(srvB)
        isnothing(srvA) || HTTP.forceclose(srvA)
        ctx.service.server[] = nothing
    end
end

@testset "a rejected serve() does not tear down the server it was protecting" begin
    # The blocking `serve()` wrapper cleans up in a `finally`. That `finally` also fires when
    # the already-serving guard rejects the call — so without a "did this call actually start
    # anything" flag, a rejected `serve()` terminates the healthy server whose existence was
    # the reason for the rejection, after telling the caller to terminate it themselves.
    port = get_free_port()
    Nitro.serve(port = port, host = HOST, async = true, show_banner = false, access_log = nothing)
    try
        @test isopen(Nitro.CONTEXT[].service)

        # `async=false` on purpose: that is the path carrying the cleanup `finally`. Run it on
        # a TASK, never inline — today the guard throws before anything binds, but if the guard
        # ever regresses this call reaches `startserver` and blocks in `wait()` forever, and
        # `nworkers=0` (the in-process mode; the default has been 1 since #84) applies no
        # per-item timeout. Inline, a
        # regression would wedge the whole run and orphan a port-holding process — the very
        # #73 symptom. On a task it is a red test in 20 seconds.
        blocked = Threads.@spawn Nitro.serve(port = get_free_port(), host = HOST,
                                             async = false, show_banner = false,
                                             access_log = nothing)
        @test timedwait(() -> istaskdone(blocked), 20.0; pollint = 0.1) === :ok
        @test istaskfailed(blocked)
        rejection = try
            fetch(blocked)
            nothing
        catch e
            e isa TaskFailedException ? e.task.result : e
        end
        @test rejection isa ArgumentError
        # Distinguish the already-serving guard from `serve`'s other ArgumentErrors (an invalid
        # `revise`, a bad `shutdown_timeout`) — otherwise this passes on the wrong rejection.
        @test occursin("already serving", sprint(showerror, rejection))

        @test isopen(Nitro.CONTEXT[].service)          # still up
        @test !isnothing(Nitro.CONTEXT[].service.server[])
        @test HTTP.get("http://$HOST:$port/__nitro_probe__";
                       status_exception = false, retry = false).status == 404
    finally
        Nitro.terminate()
        Nitro.resetstate()
    end
end

@testset "an invalid shutdown_timeout is rejected at serve(), not at terminate()" begin
    # Validating only inside `_shutdown_server` would be far too late: the stored value is read
    # on every `terminate()`, so a bad one made `terminate()` throw *before* clearing the
    # handle — a running server that the normal API could never stop again.
    ctx = Nitro.Core.App()
    for bad in (-5, -0.001, NaN)
        @test_throws ArgumentError _serve(ctx, get_free_port(); shutdown_timeout = bad)
        @test !isopen(ctx.service)              # nothing was started
        @test isnothing(ctx.service.server[])
    end

    # And a good one still round-trips onto the service.
    srv = _serve(ctx, get_free_port(); shutdown_timeout = 2.5)
    try
        @test ctx.service.shutdown_timeout[] === 2.5
    finally
        Nitro.Core.terminate(ctx)
    end
end

@testset "reuseaddr platform default (unit)" begin
    # The primary assertion: deterministic on all three platforms, no sockets, no flake.
    # On Windows SO_REUSEADDR lets a second process bind a port another is actively
    # listening on, so Nitro defaults it off there.
    @test Nitro.Core.preprocesskwargs(pairs((;)))[:reuseaddr] == !Sys.iswindows()
    @test Nitro.Core.preprocesskwargs(pairs((; reuseaddr = true)))[:reuseaddr]  === true
    @test Nitro.Core.preprocesskwargs(pairs((; reuseaddr = false)))[:reuseaddr] === false
    # Existing behavior must survive the edit.
    @test !haskey(Nitro.Core.preprocesskwargs(pairs((; queuesize = 100))), :queuesize)
end

@testset "reuseaddr reaches the Server" begin
    ctx = Nitro.Core.App()
    srv = _serve(ctx, get_free_port())
    try
        @test srv.reuseaddr == !Sys.iswindows()
    finally
        Nitro.Core.terminate(ctx)
    end

    # These two cover a *clobbering* regression — `get!` becoming `setindex!`, which would
    # overwrite whatever the caller asked for — and prove the kwarg pathway end to end. They do
    # NOT catch removing the injection entirely: `reuseaddr` is not a named parameter of
    # `serve`, so an explicit value rides `kwargs...` through to `HTTP.listen!` whether or not
    # `preprocesskwargs` mentions it. The unit assertion above (`preprocesskwargs(pairs((;)))`)
    # is what fails on a revert; the end-to-end revert guard is the platform-default check on
    # the previous server, which only discriminates on Windows.
    ctx2 = Nitro.Core.App()
    srv2 = _serve(ctx2, get_free_port(); reuseaddr = false)
    try
        @test srv2.reuseaddr === false
    finally
        Nitro.Core.terminate(ctx2)
    end

    ctx3 = Nitro.Core.App()
    srv3 = _serve(ctx3, get_free_port(); reuseaddr = true)
    try
        @test srv3.reuseaddr === true      # an explicit value always wins over the platform default
    finally
        Nitro.Core.terminate(ctx3)
    end
end

@testset "serve() warnings name serve(), never serveparallel() (#149)" begin
    # Every record `serve()` logs, at every level. The old guards keyed on an `is_test()` that
    # never returned true, so these warnings reached production -- asserting on the captured
    # records is what shows what an operator reads.
    function serve_logs(; kw...)
        ctx = Nitro.Core.App()
        logger = Test.TestLogger(min_level = Base.CoreLogging.Debug)
        try
            Base.CoreLogging.with_logger(() -> _serve(ctx, get_free_port(); kw...), logger)
        finally
            Nitro.Core.terminate(ctx)
        end
        return logger.logs
    end
    mentions(logs, pat) = any(r -> occursin(pat, string(r.message)), logs)

    for kw in ((; queuesize = 100), (; queuesize = 100, parallel = false))
        logs = serve_logs(; kw...)
        # `queuesize` is dropped whatever `parallel` is, so the warning is unconditional.
        @test any(r -> r.level == Base.CoreLogging.Warn &&
                       occursin("queuesize", string(r.message)) &&
                       occursin("serve()", string(r.message)), logs)
        @test !mentions(logs, "serveparallel")
    end

    # One thread is a valid deployment: nothing warns about it, on any thread count.
    logs = serve_logs()
    @test !mentions(logs, "serveparallel")
    @test !mentions(logs, "thread available")
    @test !mentions(logs, "queuesize")
end

@testset "serve() logs the no-GC-target warning in prod only, even with the banner off (#299)" begin
    # The helper is unit-tested in test/util_tests.jl; this pins the CALL SITE — that `serve`
    # makes it, with `show_banner = false`, and passes it the real environment and target.
    function gc_warnings(env)
        ctx = Nitro.Core.App()
        logger = Test.TestLogger(min_level = Base.CoreLogging.Warn)
        try
            withenv("NITRO_ENV" => env, "GENIE_ENV" => nothing) do
                Base.CoreLogging.with_logger(() -> _serve(ctx, get_free_port()), logger)
            end
        finally
            Nitro.Core.terminate(ctx)
        end
        return filter(r -> occursin("no GC target", string(r.message)), logger.logs)
    end

    target = Nitro.Core._gc_target_bytes()
    unset = target !== nothing && !Nitro.Core._has_gc_target(target)
    # Whichever this process is — CI runners usually have no hint and no cgroup limit, a
    # container does — the prod result must agree with it, and dev never warns.
    @test length(gc_warnings("prod")) == (unset ? 1 : 0)
    @test isempty(gc_warnings("dev"))
end

# ── Default server timeouts (#316) ──────────────────────────────────────────────────────────────

@testset "server timeout defaults (unit)" begin
    pk = Nitro.Core.preprocesskwargs
    d = pk(pairs((;)))
    @test d[:read_header_timeout] === Nitro.Core.DEFAULT_READ_HEADER_TIMEOUT_SECONDS
    @test d[:idle_timeout] === Nitro.Core.DEFAULT_IDLE_TIMEOUT_SECONDS
    # The two that could cut a legitimate stream stay opt-in.
    @test !haskey(d, :read_timeout)
    @test !haskey(d, :write_timeout)

    # An explicit value wins, including the two spellings of "disabled".
    @test pk(pairs((; read_header_timeout = 5)))[:read_header_timeout] === 5
    @test pk(pairs((; idle_timeout = 0)))[:idle_timeout] === 0
    @test pk(pairs((; read_header_timeout = nothing)))[:read_header_timeout] === nothing

    # HTTP.jl throws when it gets both `X` and `X_ns`, so a caller's `_ns` spelling must suppress
    # the default rather than collide with it.
    ns = pk(pairs((; read_header_timeout_ns = 10^9, idle_timeout_ns = 0)))
    @test !haskey(ns, :read_header_timeout)
    @test !haskey(ns, :idle_timeout)
end

@testset "an invalid server timeout is rejected at serve(), before any mutation" begin
    ctx = Nitro.Core.App()
    # Every call below is one HTTP.jl's `listen!` would refuse — after `serve` had mutated the App.
    for kw in ((; read_header_timeout = -1), (; read_header_timeout = NaN),
               (; idle_timeout = Inf), (; read_timeout = true), (; write_timeout = "5"),
               (; read_header_timeout = 1e20), (; idle_timeout_ns = -1),
               (; read_timeout_ns = 1.5), (; write_timeout_ns = true),
               # `typemax(Int64)` ns, as seconds, rounds up to 2^63 ns: one past what fits.
               (; idle_timeout = typemax(Int64) / 1.0e9),
               # Past Int128 once scaled, and past Float64: still an ArgumentError, not InexactError.
               (; read_header_timeout = 1e30), (; write_timeout = big"1e400"),
               (; read_header_timeout_ns = typemax(UInt64)),
               # Two spellings of one timeout, each carrying a value.
               (; read_header_timeout = 5, read_header_timeout_ns = 10^9),
               (; readtimeout = 5, read_timeout = 5),
               (; readtimeout = 5, read_timeout_ns = 10^9))
        err = try
            _serve(ctx, get_free_port(); kw...)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin(string(first(keys(kw))), sprint(showerror, err))
        @test !isopen(ctx.service)
        @test isnothing(ctx.service.external_url[])   # rejected before `serve` touched the App
    end

    # HTTP.jl's own reading of "both spellings": a seconds form of `nothing`, or an `_ns` form of
    # `0`, carries no value, so it combines with the other spelling freely.
    for kw in ((; read_header_timeout = nothing, read_header_timeout_ns = 10^9),
               (; idle_timeout = 5, idle_timeout_ns = 0))
        ok = Nitro.Core.App()
        _serve(ok, get_free_port(); kw...)
        try
            @test isopen(ok.service)
        finally
            Nitro.Core.terminate(ok)
        end
    end
end

@testset "the timeout defaults reach the Server, and an explicit 0 disables them" begin
    ctx = Nitro.Core.App()
    srv = _serve(ctx, get_free_port())
    try
        @test srv.read_header_timeout_ns == round(Int64, 1e9 * Nitro.Core.DEFAULT_READ_HEADER_TIMEOUT_SECONDS)
        @test srv.idle_timeout_ns == round(Int64, 1e9 * Nitro.Core.DEFAULT_IDLE_TIMEOUT_SECONDS)
        @test srv.read_timeout_ns == 0
        @test srv.write_timeout_ns == 0
    finally
        Nitro.Core.terminate(ctx)
    end

    ctx2 = Nitro.Core.App()
    srv2 = _serve(ctx2, get_free_port(); read_header_timeout = 0, idle_timeout = nothing)
    try
        @test srv2.read_header_timeout_ns == 0
        @test srv2.idle_timeout_ns == 0
    finally
        Nitro.Core.terminate(ctx2)
    end
end

"""
Write `parts` to a fresh raw connection, `gap` seconds apart, and return everything the server
sends back until it closes the connection (or `limit` seconds pass). A raw socket rather than
HTTP.jl's client: no pool, no retry, and no way for the client to paper over a slow send.
"""
function _raw_exchange(port, parts; gap = 0.0, limit = 15.0)
    sock = Sockets.connect(Sockets.localhost, port)
    try
        for (i, part) in enumerate(parts)
            i > 1 && sleep(gap)
            try
                write(sock, part)
                flush(sock)
            catch
                break          # the server already hung up; read whatever it said first
            end
        end
        reader = @async try
            String(read(sock))
        catch
            ""
        end
        timedwait(() -> istaskdone(reader), limit; pollint = 0.05)
        return istaskdone(reader) ? fetch(reader) : "(no close within $(limit)s)"
    finally
        close(sock)
    end
end

function _echo_context()
    ctx = Nitro.Core.App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/echo", req -> String(req.body); method = "POST"),
    ])
    return ctx
end

@testset "read_header_timeout bounds the head (Slowloris)" begin
    # A behavior pin, not a regression test: an explicit value was forwarded to HTTP.jl before
    # #316 too. It pins that the head bound still holds through Nitro's deadline clearing, which
    # must never run before a head has been parsed.
    ctx = _echo_context()
    port = get_free_port()
    _serve(ctx, port; read_header_timeout = 0.5)
    try
        t0 = time()
        reply = _raw_exchange(port, ["GET /echo HTTP/1.1\r\nHost: $HOST\r\n"])   # never finished
        @test startswith(reply, "HTTP/1.1 408")
        @test time() - t0 < 10.0
    finally
        Nitro.Core.terminate(ctx)
    end
end

@testset "read_header_timeout does not bound the body (Go semantics)" begin
    # The regression this cluster exists for. HTTP.jl leaves the header deadline armed through
    # the body read when `read_timeout` is unset, so against unpatched Nitro a body that finishes
    # after the header timeout is cut mid-read — and surfaced as a 500, see the next testset.
    ctx = _echo_context()
    port = get_free_port()
    _serve(ctx, port; read_header_timeout = 0.5)
    try
        head = "POST /echo HTTP/1.1\r\nHost: $HOST\r\nContent-Length: 5\r\nConnection: close\r\n\r\n"
        reply = _raw_exchange(port, [head, "hello"]; gap = 1.5)
        @test startswith(reply, "HTTP/1.1 200")
        @test endswith(reply, "hello")
    finally
        Nitro.Core.terminate(ctx)
    end
end

@testset "an explicit read_timeout still bounds the body, and answers 408 rather than 500" begin
    # `parallel_stream_handler` used to rethrow HTTP's `DeadlineExceededError` wrapped in a
    # `TaskFailedException`, which HTTP's stream path cannot classify, so it answered 500.
    ctx = _echo_context()
    port = get_free_port()
    _serve(ctx, port; read_header_timeout = 0.5, read_timeout = 0.5)
    try
        # The head alone: the body never comes. Sending it late would write into a socket the
        # server has already closed, and on Windows the RST that draws discards the unread 408
        # from the client's receive buffer.
        head = "POST /echo HTTP/1.1\r\nHost: $HOST\r\nContent-Length: 5\r\nConnection: close\r\n\r\n"
        reply = _raw_exchange(port, [head])
        @test startswith(reply, "HTTP/1.1 408")
    finally
        Nitro.Core.terminate(ctx)
    end
end

@testset "a malformed chunked body is answered 400, not 500" begin
    # The same unwrapping, for a different HTTP.jl error: its chunk parser raises an error HTTP.jl
    # maps to 400, which the `TaskFailedException` wrapper used to turn into a 500.
    ctx = _echo_context()
    port = get_free_port()
    _serve(ctx, port)
    try
        req = "POST /echo HTTP/1.1\r\nHost: $HOST\r\nTransfer-Encoding: chunked\r\n" *
              "Connection: close\r\n\r\nzz\r\nhello\r\n0\r\n\r\n"
        @test startswith(_raw_exchange(port, [req]), "HTTP/1.1 400")
    finally
        Nitro.Core.terminate(ctx)
    end
end

# ── The in-flight request cap (#298) ────────────────────────────────────────────────────────────

@testset "max_concurrent_requests is validated at serve(), before any mutation" begin
    ctx = Nitro.Core.App()
    for bad in (0, -1, true, 1.5, "2")
        err = try
            _serve(ctx, get_free_port(); max_concurrent_requests = bad)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("max_concurrent_requests", sprint(showerror, err))
        @test !isopen(ctx.service)
        @test isnothing(ctx.service.external_url[])
    end
    # A custom handler reads its own body, so Nitro cannot hold a slot around it.
    err = try
        _serve(ctx, get_free_port(); max_concurrent_requests = 4,
               handler = mw -> (stream -> nothing), max_body_bytes = nothing)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("custom `handler`", sprint(showerror, err))
    @test !isopen(ctx.service)
end

@testset "_is_streaming_body tells a cursor from a buffer" begin
    @test !Nitro.Core._is_streaming_body(HTTP.BytesBody(UInt8[1, 2]))
    @test !Nitro.Core._is_streaming_body(HTTP.EmptyBody())
    @test !Nitro.Core._is_streaming_body(UInt8[1, 2])
    @test !Nitro.Core._is_streaming_body("text")
    events = Nitro.Res.sse().body
    try
        @test Nitro.Core._is_streaming_body(events)
    finally
        close(events)
    end
end

@testset "only a streaming body with no length releases its slot early" begin
    sse = Nitro.Res.sse()
    try
        @test Nitro.Core._releases_slot_early(sse)
    finally
        close(sse.body)
    end
    @test !Nitro.Core._releases_slot_early(HTTP.Response(200, "buffered"))
    # A streamed file is a cursor, but it has a Content-Length, and HTTP.jl buffers a response
    # with a length WHOLE on HTTP/1.1 — so it must keep its slot until it is on the wire.
    path_ = tempname()
    write(path_, rand(UInt8, 1024))
    streamed = Nitro.Res.file(HTTP.Request("GET", "/f"), path_; stream = true)
    try
        @test Nitro.Core._is_streaming_body(streamed.body)
        @test !Nitro.Core._releases_slot_early(streamed)
    finally
        Nitro.Core._release_response_body!(streamed.body)
        rm(path_; force = true)
    end
end

@testset "_try_acquire_slot! never exceeds the limit and never over-counts" begin
    counter = Threads.Atomic{Int64}(0)
    @test Nitro.Core._try_acquire_slot!(counter, Int64(2))
    @test Nitro.Core._try_acquire_slot!(counter, Int64(2))
    @test !Nitro.Core._try_acquire_slot!(counter, Int64(2))
    @test counter[] == 2          # a refusal leaves the count where it was
    Threads.atomic_sub!(counter, Int64(1))
    @test Nitro.Core._try_acquire_slot!(counter, Int64(2))
end

"""
A context whose `/park` handler signals `entered` and then blocks until `release` is notified,
so one request can be held in flight on purpose. `/ok`, `/echo` and `/events` answer at once,
`/boom` throws inside the handler, and `/big` returns a 48 MiB buffered body.
"""
function _capacity_context(entered::Threads.Atomic{Bool}, release::Base.Event;
                           big_entered::Threads.Atomic{Bool} = Threads.Atomic{Bool}(false))
    ctx = Nitro.Core.App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        # More than a Linux or macOS loopback socket buffers, so a client that does not read it
        # leaves the server's write blocked. Built per request, so only the testset that asks
        # for it pays. `big_entered` says the handler — and so the slot — has been reached.
        path("/big", function(req)
            big_entered[] = true
            return HTTP.Response(200, fill(UInt8('x'), 48 * 1024 * 1024))
        end; method = "GET"),
        path("/park", function(req)
            entered[] = true
            wait(release)
            return "parked"
        end; method = "GET"),
        path("/ok", req -> "ok"; method = "GET"),
        path("/echo", req -> String(req.body); method = "POST"),
        path("/boom", req -> error("boom"); method = "GET"),
        path("/events", req -> Nitro.Res.sse() do events
            for i in 1:40
                isopen(events) || break
                write(events, Nitro.SSEEvent("tick-$i"))
                sleep(0.1)
            end
        end; method = "GET"),
    ])
    return ctx
end

_get(port, target) = _raw_exchange(port, ["GET $target HTTP/1.1\r\nHost: $HOST\r\nConnection: close\r\n\r\n"])

@testset "over max_concurrent_requests: 503 + Retry-After, and the slot frees when the request ends" begin
    entered, release = Threads.Atomic{Bool}(false), Base.Event()
    ctx = _capacity_context(entered, release)
    port = get_free_port()
    _serve(ctx, port; max_concurrent_requests = 1)
    parked = nothing
    try
        parked = @async _get(port, "/park")
        @test timedwait(() -> entered[], 20.0; pollint = 0.02) === :ok

        refused = _get(port, "/ok")
        @test startswith(refused, "HTTP/1.1 503")
        @test occursin(r"\r\nRetry-After: 1\r\n"i, refused)
        @test occursin(r"\r\nConnection: close\r\n"i, refused)
        # A body sent with the refused request is not read into memory, and the refusal still
        # reaches the client rather than an RST (the swallow budget covers this small body).
        refused_post = _raw_exchange(port, ["POST /echo HTTP/1.1\r\nHost: $HOST\r\n" *
            "Content-Length: 5\r\nConnection: close\r\n\r\nhello"])
        @test startswith(refused_post, "HTTP/1.1 503")

        notify(release)
        @test timedwait(() -> istaskdone(parked), 20.0; pollint = 0.02) === :ok
        @test startswith(fetch(parked), "HTTP/1.1 200")
        @test startswith(_get(port, "/ok"), "HTTP/1.1 200")   # the slot came back
    finally
        notify(release)
        Nitro.Core.terminate(ctx)
    end
end

@testset "a request that fails still gives its slot back" begin
    entered, release = Threads.Atomic{Bool}(false), Base.Event()
    ctx = _capacity_context(entered, release)
    port = get_free_port()
    _serve(ctx, port; max_concurrent_requests = 1)
    try
        # A handler error, caught and answered by the middleware chain.
        @test startswith(_get(port, "/boom"), "HTTP/1.1 500")
        @test startswith(_get(port, "/ok"), "HTTP/1.1 200")
        # An error that escapes `stream_handler` itself — HTTP.jl's chunk parser — so only the
        # outer `finally` can return the slot.
        bad = "POST /echo HTTP/1.1\r\nHost: $HOST\r\nTransfer-Encoding: chunked\r\n" *
              "Connection: close\r\n\r\nzz\r\nhello\r\n0\r\n\r\n"
        @test startswith(_raw_exchange(port, [bad]), "HTTP/1.1 400")
        @test startswith(_get(port, "/ok"), "HTTP/1.1 200")
        # And the 413 path, which returns from inside the permit's `try`. `Expect: 100-continue`
        # so the refusal does not wait to swallow a body this client never sends.
        big = "POST /echo HTTP/1.1\r\nHost: $HOST\r\nContent-Length: 999999999999\r\n" *
              "Expect: 100-continue\r\nConnection: close\r\n\r\n"
        @test startswith(_raw_exchange(port, [big]), "HTTP/1.1 413")
        @test startswith(_get(port, "/ok"), "HTTP/1.1 200")
    finally
        notify(release)
        Nitro.Core.terminate(ctx)
    end
end

@testset "a buffered response holds its slot until it is on the wire" begin
    # Review finding on #298. On HTTP/1.1 HTTP.jl buffers a fixed-length response whole and sends
    # it at `closewrite`, which its loop ran AFTER `stream_handler` returned and the slot was
    # released — so a client that stopped reading held the whole response, and the request body
    # it pins, with its slot already free. Unpatched, the `/ok` below is a 200.
    entered, release = Threads.Atomic{Bool}(false), Base.Event()
    big_entered = Threads.Atomic{Bool}(false)
    ctx = _capacity_context(entered, release; big_entered)
    port = get_free_port()
    srv = _serve(ctx, port; max_concurrent_requests = 1)
    sock = nothing
    try
        sock = Sockets.connect(Sockets.localhost, port)
        write(sock, "GET /big HTTP/1.1\r\nHost: $HOST\r\nConnection: close\r\n\r\n")
        flush(sock)
        # Read nothing. Wait for the handler rather than a fixed sleep: a slow runner otherwise
        # reaches `/ok` before `/big` has even taken the slot.
        @test timedwait(() -> big_entered[], 20.0; pollint = 0.02) === :ok

        # Whether the 48 MiB write actually stalled, observed on the server's own connection
        # table: a `Connection: close` exchange whose write completed is untracked within
        # moments, while a stalled one stays tracked for as long as the client does not read.
        # Checked rather than assumed, because it is the platform's call, not Nitro's: Linux and
        # macOS loopback sockets buffer a few MiB, but the first Windows CI run of this test
        # served `/ok` while the write should have been blocked.
        stalled = timedwait(() -> isempty(HTTP._server_conns(srv)), 2.0; pollint = 0.05) !== :ok
        # Where the premise is known to hold, require it — this path must not go untested there.
        Sys.iswindows() || @test stalled
        # The assertion that discriminates, wherever the write is really in flight: unpatched,
        # the slot was already released and this `/ok` is a 200.
        stalled && @test startswith(_get(port, "/ok"), "HTTP/1.1 503")
        close(sock)                 # the write fails (or already finished), and the slot comes back
        sock = nothing
        @test timedwait(() -> startswith(_get(port, "/ok"), "HTTP/1.1 200"), 20.0;
                        pollint = 0.25) === :ok
    finally
        isnothing(sock) || close(sock)
        notify(release)
        Nitro.Core.terminate(ctx)
    end
end

@testset "a refusal does not wait forever for a body that never comes" begin
    # Review finding on #298. The swallow before a 413 or 503 was bounded in bytes but not in
    # time, and no deadline is armed after the head (#316). A client declaring a body and never
    # sending it held the refusal open — for the 413, inside a slot. Unpatched, neither refusal
    # below is ever written, and each read gives up at 15 seconds.
    entered, release = Threads.Atomic{Bool}(false), Base.Event()
    ctx = _capacity_context(entered, release)
    port = get_free_port()
    _serve(ctx, port; max_concurrent_requests = 1)
    parked = nothing
    try
        # The 413: a declared length over `max_body_bytes`, no `Expect`, and no body.
        big = "POST /echo HTTP/1.1\r\nHost: $HOST\r\nContent-Length: 999999999999\r\n" *
              "Connection: close\r\n\r\n"
        t0 = time()
        @test startswith(_raw_exchange(port, [big]), "HTTP/1.1 413")
        @test time() - t0 < 12.0
        @test startswith(_get(port, "/ok"), "HTTP/1.1 200")   # and its slot came back

        # The 503: the slot is held, and the refused request declares a body it never sends.
        parked = @async _get(port, "/park")
        @test timedwait(() -> entered[], 20.0; pollint = 0.02) === :ok
        head = "POST /echo HTTP/1.1\r\nHost: $HOST\r\nContent-Length: 100\r\nConnection: close\r\n\r\n"
        t0 = time()
        @test startswith(_raw_exchange(port, [head]), "HTTP/1.1 503")
        @test time() - t0 < 12.0
    finally
        notify(release)
        isnothing(parked) || timedwait(() -> istaskdone(parked), 20.0)
        Nitro.Core.terminate(ctx)
    end
end

@testset "a live SSE stream does not hold a max_concurrent_requests slot" begin
    entered, release = Threads.Atomic{Bool}(false), Base.Event()
    ctx = _capacity_context(entered, release)
    port = get_free_port()
    _serve(ctx, port; max_concurrent_requests = 1)
    sock = nothing
    try
        sock = Sockets.connect(Sockets.localhost, port)
        write(sock, "GET /events HTTP/1.1\r\nHost: $HOST\r\nConnection: close\r\n\r\n")
        flush(sock)
        seen = IOBuffer()
        reader = @async while !occursin("data: tick-2", String(seen.data[1:seen.size]))
            chunk = readavailable(sock)
            isempty(chunk) && break      # the server closed early: stop, don't spin on EOF
            write(seen, chunk)
        end
        @test timedwait(() -> istaskdone(reader), 20.0; pollint = 0.02) === :ok
        @test occursin("data: tick-2", String(seen.data[1:seen.size]))   # live, not closed early
        # The stream is live (it runs ~4s) and the cap is 1, yet a second request is served.
        @test startswith(_get(port, "/ok"), "HTTP/1.1 200")
    finally
        isnothing(sock) || close(sock)
        notify(release)
        Nitro.Core.terminate(ctx)
    end
end

# ── The WebSocket budget (#376) ─────────────────────────────────────────────────────────────────

@testset "max_upgraded_connections is validated at serve(), before any mutation" begin
    ctx = Nitro.Core.App()
    for bad in (0, -1, true, 1.5, "2")
        err = try
            _serve(ctx, get_free_port(); max_upgraded_connections = bad)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("max_upgraded_connections", sprint(showerror, err))
        @test !isopen(ctx.service)
        @test isnothing(ctx.service.external_url[])
    end
    err = try
        _serve(ctx, get_free_port(); max_upgraded_connections = 4,
               handler = mw -> (stream -> nothing), max_body_bytes = nothing)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("custom `handler`", sprint(showerror, err))
    @test !isopen(ctx.service)
end

"""
A context for the WebSocket budget. `/ws/hold` counts itself into `ws_entered` and reads until the
client goes away; `/ws/quick` returns at once; `/ws/boom` throws after the 101. `/park` holds an
ordinary request in flight until `release`, and `/ok` answers at once.
"""
function _ws_capacity_context(ws_entered::Threads.Atomic{Int}, entered::Threads.Atomic{Bool},
                              release::Base.Event)
    ctx = Nitro.Core.App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/ws/hold", function(ws::HTTP.WebSockets.WebSocket)
            Threads.atomic_add!(ws_entered, 1)
            try
                for _ in ws end
            catch e
                e isa HTTP.WebSockets.WebSocketError || rethrow()
            end
        end; method = "WEBSOCKET"),
        path("/ws/quick", ws -> nothing; method = "WEBSOCKET"),
        path("/ws/boom", ws -> error("boom"); method = "WEBSOCKET"),
        path("/park", function(req)
            entered[] = true
            wait(release)
            return "parked"
        end; method = "GET"),
        path("/ok", req -> "ok"; method = "GET"),
    ])
    return ctx
end

_ws_head(target; origin = nothing) =
    "GET $target HTTP/1.1\r\nHost: $HOST\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" *
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n" *
    (origin === nothing ? "" : "Origin: $origin\r\n") * "\r\n"

# A raw handshake whose socket stays open — after a 101 that is a live WebSocket the server holds —
# returned with the status line. `_raw_exchange` would wait for a close that a 101 never sends.
function _ws_open(port, target; kw...)
    sock = Sockets.connect(Sockets.localhost, port)
    write(sock, _ws_head(target; kw...))
    flush(sock)
    reader = @async try readline(sock) catch; "" end
    timedwait(() -> istaskdone(reader), 15.0; pollint = 0.02)
    return sock, (istaskdone(reader) ? fetch(reader) : "(no reply within 15s)")
end

function _ws_status(port, target; kw...)
    sock, line = _ws_open(port, target; kw...)
    close(sock)
    return line
end

_upgraded(line) = startswith(line, "HTTP/1.1 101")

# Slots are handed back in `finally` blocks that run after the client has its answer, so "the slot
# came back" is always polled. Returns the held socket, or `nothing` if no upgrade was accepted.
function _hold_ws(port; timeout = 20.0)
    held = Ref{Any}(nothing)
    timedwait(timeout; pollint = 0.05) do
        sock, line = _ws_open(port, "/ws/hold")
        _upgraded(line) && (held[] = sock; return true)
        close(sock)
        return false
    end
    return held[]
end

_eventually(f; timeout = 20.0) = timedwait(f, timeout; pollint = 0.05) === :ok

@testset "under max_upgraded_connections an open WebSocket no longer holds a request slot" begin
    ws_entered, entered, release = Threads.Atomic{Int}(0), Threads.Atomic{Bool}(false), Base.Event()
    ctx = _ws_capacity_context(ws_entered, entered, release)
    port = get_free_port()
    _serve(ctx, port; max_concurrent_requests = 1, max_upgraded_connections = 2)
    sock = nothing
    try
        sock, line = _ws_open(port, "/ws/hold")
        @test _upgraded(line)
        @test _eventually(() -> ws_entered[] >= 1)
        # THE STARVATION #376 is about: with the cap at 1, this was a 503 for as long as the
        # socket stayed open.
        @test startswith(_get(port, "/ok"), "HTTP/1.1 200")
    finally
        isnothing(sock) || close(sock)
        notify(release)
        Nitro.Core.terminate(ctx)
    end
end

@testset "without max_upgraded_connections a WebSocket keeps its request slot" begin
    # The budget is opt-in. A socket released from the request cap with no budget of its own would
    # be bounded by neither.
    ws_entered, entered, release = Threads.Atomic{Int}(0), Threads.Atomic{Bool}(false), Base.Event()
    ctx = _ws_capacity_context(ws_entered, entered, release)
    port = get_free_port()
    _serve(ctx, port; max_concurrent_requests = 1)
    sock = nothing
    try
        sock, line = _ws_open(port, "/ws/hold")
        @test _upgraded(line)
        @test _eventually(() -> ws_entered[] >= 1)
        @test startswith(_get(port, "/ok"), "HTTP/1.1 503")
    finally
        isnothing(sock) || close(sock)
        notify(release)
        Nitro.Core.terminate(ctx)
    end
end

@testset "a handshake that carried a body keeps its request slot" begin
    # The body was buffered into `req` (up to `max_body_bytes`) and stays reachable from the handler
    # for the socket's life. Handing the slot back would let every socket in the budget pin one —
    # body memory the request cap exists to bound. Review finding on #376.
    ws_entered, entered, release = Threads.Atomic{Int}(0), Threads.Atomic{Bool}(false), Base.Event()
    ctx = _ws_capacity_context(ws_entered, entered, release)
    port = get_free_port()
    _serve(ctx, port; max_concurrent_requests = 1, max_upgraded_connections = 2)
    sock = nothing
    try
        sock = Sockets.connect(Sockets.localhost, port)
        head = replace(_ws_head("/ws/hold"), r"\r\n\r\n$" => "\r\nContent-Length: 5\r\n\r\n")
        write(sock, head * "hello")
        flush(sock)
        reader = @async try readline(sock) catch; "" end
        timedwait(() -> istaskdone(reader), 15.0; pollint = 0.02)
        @test istaskdone(reader) && _upgraded(fetch(reader))
        @test _eventually(() -> ws_entered[] >= 1)
        @test startswith(_get(port, "/ok"), "HTTP/1.1 503")
    finally
        isnothing(sock) || close(sock)
        notify(release)
        Nitro.Core.terminate(ctx)
    end
end

@testset "over max_upgraded_connections: 503 before the handshake, and the slot comes back once" begin
    ws_entered, entered, release = Threads.Atomic{Int}(0), Threads.Atomic{Bool}(false), Base.Event()
    ctx = _ws_capacity_context(ws_entered, entered, release)
    port = get_free_port()
    _serve(ctx, port; max_upgraded_connections = 1)
    held = nothing
    try
        held, line = _ws_open(port, "/ws/hold")
        @test _upgraded(line)
        refused = _raw_exchange(port, [_ws_head("/ws/hold")]; limit = 5.0)
        @test startswith(refused, "HTTP/1.1 503")
        @test occursin(r"\r\nRetry-After: 1\r\n"i, refused)
        @test occursin(r"\r\nConnection: close\r\n"i, refused)
        @test !occursin(r"Sec-WebSocket-Accept"i, refused)      # no handshake was completed
        # Ordinary requests are not part of that budget.
        @test startswith(_get(port, "/ok"), "HTTP/1.1 200")

        # Released when the socket closes...
        close(held)
        held = _hold_ws(port)
        @test held !== nothing
        # ...exactly once: with one held again, the next is refused. A double release would have
        # pushed the count below zero and admitted it.
        @test startswith(_raw_exchange(port, [_ws_head("/ws/quick")]; limit = 5.0), "HTTP/1.1 503")
    finally
        isnothing(held) || close(held)
        notify(release)
        Nitro.Core.terminate(ctx)
    end
end

@testset "a refused handshake and a handler that throws both give the WebSocket slot back" begin
    ws_entered, entered, release = Threads.Atomic{Int}(0), Threads.Atomic{Bool}(false), Base.Event()
    ctx = _ws_capacity_context(ws_entered, entered, release)
    port = get_free_port()
    _serve(ctx, port; max_concurrent_requests = 1, max_upgraded_connections = 1)
    held = nothing
    try
        # Refused by the Origin check after the slot was taken (#374's 403).
        @test startswith(_ws_status(port, "/ws/quick"; origin = "https://evil.example"), "HTTP/1.1 403")
        held = _hold_ws(port)
        @test held !== nothing
        @test startswith(_raw_exchange(port, [_ws_head("/ws/quick")]; limit = 5.0), "HTTP/1.1 503")
        close(held)
        held = nothing

        # The handler throws after the 101.
        @test _eventually(() -> _upgraded(_ws_status(port, "/ws/boom")))
        held = _hold_ws(port)
        @test held !== nothing
        close(held)
        held = nothing
        @test _eventually(() -> startswith(_get(port, "/ok"), "HTTP/1.1 200"))
    finally
        isnothing(held) || close(held)
        notify(release)
        Nitro.Core.terminate(ctx)
    end
end

@testset "_release_request_slot! releases exactly once" begin
    # The deterministic half of the next testset: whichever release site runs second is a no-op.
    in_flight = Threads.Atomic{Int64}(1)
    adm = Nitro.Core._Admission(true, in_flight, Threads.Atomic{Int64}(0), 1)
    @test Nitro.Core._release_request_slot!(adm)
    @test !Nitro.Core._release_request_slot!(adm)
    @test in_flight[] == 0
    # And a request that never held a slot releases nothing.
    idle = Nitro.Core._Admission(false, in_flight, Threads.Atomic{Int64}(0), 1)
    @test !Nitro.Core._release_request_slot!(idle)
    @test in_flight[] == 0
end

@testset "a WebSocket hands its request slot back exactly once" begin
    ws_entered, entered, release = Threads.Atomic{Int}(0), Threads.Atomic{Bool}(false), Base.Event()
    ctx = _ws_capacity_context(ws_entered, entered, release)
    port = get_free_port()
    # Set once `/ws/quick`'s whole chain has returned, which leaves only `stream_handler`'s own
    # `finally` — the second release site — between it and the assertions below. Without it, a
    # slow runner could check before that `finally` ran, and pass whether it released twice or not.
    quick_done = Threads.Atomic{Bool}(false)
    mark = handle -> req -> begin
        try
            handle(req)
        finally
            req.target == "/ws/quick" && (quick_done[] = true)
        end
    end
    _serve(ctx, port; max_concurrent_requests = 1, max_upgraded_connections = 1, middleware = [mark])
    parked = nothing
    try
        # The socket gives its request slot back at the 101, and `stream_handler`'s `finally` then
        # runs for the same request: that must not give it back a second time.
        @test _upgraded(_ws_status(port, "/ws/quick"))
        @test timedwait(() -> quick_done[], 20.0; pollint = 0.02) === :ok
        @test _eventually(() -> startswith(_get(port, "/ok"), "HTTP/1.1 200"))
        parked = @async _get(port, "/park")
        @test _eventually(() -> entered[])
        # With `/park` in the one slot, a double release would have left room for this.
        @test startswith(_get(port, "/ok"), "HTTP/1.1 503")
    finally
        notify(release)
        isnothing(parked) || timedwait(() -> istaskdone(parked), 20.0)
        Nitro.Core.terminate(ctx)
    end
end

"""
Send one request on a fresh connection and read its response, then send a second request on the
SAME connection whose body arrives `gap` seconds after its head. Returns the second response.
"""
function _second_request_late_body(port; gap)
    sock = Sockets.connect(Sockets.localhost, port)
    try
        write(sock, "POST /echo HTTP/1.1\r\nHost: $HOST\r\nContent-Length: 5\r\n\r\nfirst")
        seen = IOBuffer()
        reader = @async while !endswith(String(seen.data[1:seen.size]), "first")
            chunk = readavailable(sock)
            isempty(chunk) && break
            write(seen, chunk)
        end
        timedwait(() -> istaskdone(reader), 15.0; pollint = 0.02) === :ok ||
            return "(first response incomplete)"
        startswith(String(take!(seen)), "HTTP/1.1 200") || return "(first request failed)"

        write(sock, "POST /echo HTTP/1.1\r\nHost: $HOST\r\nContent-Length: 6\r\nConnection: close\r\n\r\n")
        sleep(gap)
        try
            write(sock, "second")
        catch
        end
        rest = @async try
            String(read(sock))
        catch
            ""
        end
        timedwait(() -> istaskdone(rest), 15.0; pollint = 0.05)
        return istaskdone(rest) ? fetch(rest) : "(no close within 15s)"
    finally
        close(sock)
    end
end

@testset "a keep-alive request's body is not cut by the idle deadline" begin
    # Review finding on #316. After each response HTTP.jl arms the IDLE deadline, and with
    # `read_header_timeout = 0` nothing replaces it before the next request's body is read. The
    # clear used to be skipped whenever the header timeout was 0 ("nothing was armed"), so every
    # request after the first on a connection had its body cut `idle_timeout` after the previous
    # response — 120 seconds by default. Unpatched, the second request below is a 408.
    for kw in ((; read_header_timeout = 0, idle_timeout = 0.5),
               (; read_header_timeout = 0.5, idle_timeout = 0.5))
        ctx = _echo_context()
        port = get_free_port()
        _serve(ctx, port; kw...)
        try
            reply = _second_request_late_body(port; gap = 1.5)
            @test startswith(reply, "HTTP/1.1 200")
            @test endswith(reply, "second")
        finally
            Nitro.Core.terminate(ctx)
        end
    end
end

end
