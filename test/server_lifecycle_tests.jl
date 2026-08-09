@testitem "Server lifecycle: bounded shutdown, serve guard, reuseaddr" tags=[:core, :network] setup=[NitroCommon] begin

using Test
using HTTP
using Sockets
using Nitro
using Nitro: path

# Almost every testset here runs on a *private* `ServerContext`, so it mutates no global
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
    ctx = Nitro.Core.ServerContext()
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
    ctx  = Nitro.Core.ServerContext()
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
    ctx  = Nitro.Core.ServerContext()
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
        # `nworkers=0` (the default, and what CI uses) applies no per-item timeout. Inline, a
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
    ctx = Nitro.Core.ServerContext()
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
    ctx = Nitro.Core.ServerContext()
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
    ctx2 = Nitro.Core.ServerContext()
    srv2 = _serve(ctx2, get_free_port(); reuseaddr = false)
    try
        @test srv2.reuseaddr === false
    finally
        Nitro.Core.terminate(ctx2)
    end

    ctx3 = Nitro.Core.ServerContext()
    srv3 = _serve(ctx3, get_free_port(); reuseaddr = true)
    try
        @test srv3.reuseaddr === true      # an explicit value always wins over the platform default
    finally
        Nitro.Core.terminate(ctx3)
    end
end

end
