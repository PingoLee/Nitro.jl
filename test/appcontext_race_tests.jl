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
# observe mid-flight. These items pin that shut from both sides: one asserts a live HTTP
# request keeps its own context, the other asserts the shared cell is never written at all.
#
# Both are DETERMINISTIC — they synchronise on `Base.Event`, never on sleeps. The trick that
# makes the window observable without racing the test itself is parking an `internalrequest`
# *inside its own handler*: under the old code the global is swapped at that moment and stays
# swapped until the handler returns, so the concurrent observation lands squarely in the gap.

struct Tenant
    name::String
end

tenant_a = Tenant("A")
tenant_b = Tenant("B")

# `Base.Event` is single-use, and both testsets park the same route, so the latches live
# behind Refs the handler dereferences at call time and each testset installs fresh ones.
parked  = Ref(Base.Event())
release = Ref(Base.Event())

port = get_free_port()
localhost = "http://$HOST:$port"

urlpatterns("",
    path("/park", function(req)
        notify(parked[])
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
        parked[]  = Base.Event()
        release[] = Base.Event()

        # Park an `internalrequest(context = tenant_b)` inside its handler. On the unpatched
        # code the process-wide cell reads tenant_b from here until the handler returns.
        call = Threads.@spawn internalrequest(HTTP.Request("GET", "/park"); context = tenant_b)
        wait(parked[])

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
        parked[]  = Base.Event()
        release[] = Base.Event()

        cell = Nitro.CONTEXT[].app_context[]
        @test cell isa Nitro.Context
        @test cell.payload == tenant_a

        call = Threads.@spawn internalrequest(HTTP.Request("GET", "/park"); context = tenant_b)
        wait(parked[])

        # Observed from a concurrent task, mid-call. Two overlapping `internalrequest`s used
        # to be able to clobber this permanently, because `old_ctx` was snapshotted without
        # synchronisation and the second `finally` wrote back the first's installed value.
        @test Nitro.CONTEXT[].app_context[].payload == tenant_a

        notify(release[])
        fetch(call)
        @test Nitro.CONTEXT[].app_context[].payload == tenant_a
    end
finally
    terminate()
    resetstate()
end
end
