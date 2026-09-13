@testitem "App context isolation under concurrency" tags=[:core, :network] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro

# Regression net for #31.
#
# `internalrequest(context = ...)` used to inject its per-call context by WRITING the
# process-shared `ServerContext.app_context[]` Ref and restoring it in a `finally`. `serve()`
# dispatches every request on `Threads.@spawn` (nitro-core §2) and the outermost pipeline
# layer seeded each request out of that same cell, so any request that entered the pipeline
# during the window was stamped with the *caller's* context — and `getcontext(req)` then
# returned the wrong tenant's object for that request's whole lifetime.
#
# The fix carries the app context on the REQUEST instead, so there is no shared cell left to
# observe mid-flight. Three items pin that shut: a live HTTP request keeps its own context, the
# shared cell is never written at all, and — because the context is now state that outlives a
# call — a reused request object does not inherit a previous call's override.
#
# The first two are DETERMINISTIC: they synchronise on a latch, never on sleeps. What makes the
# window observable without racing the test itself is parking an `internalrequest` *inside its
# own handler* — under the old code the global is swapped at that moment and stays swapped until
# the handler returns, so the concurrent observation lands squarely in the gap.

struct Tenant
    name::String
end

tenant_a = Tenant("A")
tenant_b = Tenant("B")

# The latches are single-use and both testsets park the same route, so they live behind Refs
# the handler dereferences at call time; each testset installs fresh ones.
#
# `parked` is a Channel rather than an Event so the test can wait on it with a TIMEOUT. A test
# that hangs is strictly worse than one that fails: `runtests.jl`'s `testitem_timeout` covers
# the default worker path but not `--workers 0`, so a handler that never reaches `put!` (route
# gone, 404, a throw before this line) would otherwise wedge the run instead of reporting.
parked  = Ref(Channel{Nothing}(1))
release = Ref(Base.Event())

# Returns true if the parked handler signalled within the budget.
reached_handler(ch) = timedwait(() -> isready(ch), 30.0) === :ok

port = get_free_port()
localhost = "http://$HOST:$port"

urlpatterns("",
    path("/park", function(req)
        put!(parked[], nothing)
        wait(release[])
        c = getcontext(req)
        return Res.json(Dict("tenant" => c === nothing ? "none" : c.name))
    end, method="GET"),
    path("/probe", function(req)
        c = getcontext(req)
        return Res.json(Dict("tenant" => c === nothing ? "none" : c.name))
    end, method="GET"),
)

serve(port=port, host=HOST, async=true, show_errors=false, show_banner=false,
      access_log=nothing, context=tenant_a)

try
    @testset "a live request is not stamped with a concurrent internalrequest's context" begin
        parked[]  = Channel{Nothing}(1)
        release[] = Base.Event()

        # Park an `internalrequest(context = tenant_b)` inside its handler. On the unpatched
        # code the process-wide cell reads tenant_b from here until the handler returns.
        call = Threads.@spawn internalrequest(HTTP.Request("GET", "/park"); context = tenant_b)
        @test reached_handler(parked[])

        # A real HTTP request, served by the live server off the same context, entering the
        # pipeline squarely inside that window.
        resp = HTTP.get("$localhost/probe")
        @test resp.status == 200
        @test json(resp)["tenant"] == "A"

        notify(release[])
        parked_resp = fetch(call)

        # The override must still reach its OWN request — the fix isolates it, it does not
        # drop it. Without this the first assertion could be satisfied by ignoring `context=`.
        @test parked_resp.status == 200
        @test json(parked_resp)["tenant"] == "B"
    end

    @testset "internalrequest never mutates the shared app context cell" begin
        parked[]  = Channel{Nothing}(1)
        release[] = Base.Event()

        cell = Nitro.CONTEXT[].app_context[]
        @test cell isa Nitro.Context
        @test cell.payload == tenant_a

        call = Threads.@spawn internalrequest(HTTP.Request("GET", "/park"); context = tenant_b)
        @test reached_handler(parked[])

        # Observed from a concurrent task, mid-call. Two overlapping `internalrequest`s used
        # to be able to clobber this permanently, because `old_ctx` was snapshotted without
        # synchronisation and the second `finally` wrote back the first's installed value.
        @test Nitro.CONTEXT[].app_context[].payload == tenant_a

        notify(release[])
        fetch(call)
        @test Nitro.CONTEXT[].app_context[].payload == tenant_a
    end

    @testset "a reused request object does not inherit a previous call's context" begin
        # Carrying the context ON the request means the request is now state that outlives a
        # call. `_app_context_seed` seeds only when the key is absent, so if `internalrequest`
        # stamped only when given an override, re-running a request object that had picked one
        # up would keep the STALE context — the same defect as the race, reached by reuse.
        # `internalrequest` therefore stamps unconditionally.
        req = HTTP.Request("GET", "/probe")

        overridden = internalrequest(req; context = tenant_b)
        @test json(overridden)["tenant"] == "B"

        # Same object, no override: must resolve to the server's context, not tenant_b.
        plain = internalrequest(req)
        @test json(plain)["tenant"] == "A"
    end
finally
    # Free any still-parked handler before tearing down. A plain `@test` failure is safe,
    # but an EXCEPTION inside a testset would otherwise skip the `notify` and strand the task.
    notify(release[])
    terminate()
    resetstate()
end
end
