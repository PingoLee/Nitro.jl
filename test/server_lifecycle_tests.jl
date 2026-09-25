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
    for (name, bad) in ((:read_header_timeout, -1), (:read_header_timeout, NaN),
                        (:idle_timeout, Inf), (:read_timeout, true), (:write_timeout, "5"),
                        (:read_header_timeout, 1e20), (:idle_timeout_ns, -1),
                        (:read_timeout_ns, 1.5), (:write_timeout_ns, true))
        err = try
            _serve(ctx, get_free_port(); (name => bad,)...)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin(string(name), sprint(showerror, err))
        @test !isopen(ctx.service)
        @test isnothing(ctx.service.external_url[])   # rejected before `serve` touched the App
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
        path("/events", req -> Nitro.Res.sse() do events
            for i in 1:6
                isopen(events) || break
                write(events, Nitro.SSEEvent("tick-$i"))
                sleep(0.25)
            end
        end; method = "GET"),
    ])
    return ctx
end

@testset "read_header_timeout bounds the head (Slowloris)" begin
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
        head = "POST /echo HTTP/1.1\r\nHost: $HOST\r\nContent-Length: 5\r\nConnection: close\r\n\r\n"
        reply = _raw_exchange(port, [head, "hello"]; gap = 1.5)
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

@testset "a short read_header_timeout does not cut an SSE stream" begin
    # The docs promise the defaults leave streams alone. The stream below runs ~1.5s against a
    # 0.5s header timeout; on HTTP/1.1 nothing reads the socket while it streams, and the header
    # deadline is cleared as soon as the head is parsed.
    ctx = _echo_context()
    port = get_free_port()
    _serve(ctx, port; read_header_timeout = 0.5)
    try
        reply = _raw_exchange(port, ["GET /events HTTP/1.1\r\nHost: $HOST\r\nConnection: close\r\n\r\n"])
        @test startswith(reply, "HTTP/1.1 200")
        @test count("data: tick-", reply) == 6
    finally
        Nitro.Core.terminate(ctx)
    end
end

end
