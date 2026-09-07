#!/usr/bin/env julia
#
# smoke_test.jl — verify Nitro loads and serves, without ReTestItems.
#
# Why this exists.
#
# The `test/` suite is driven by ReTestItems, which is a *test-only* dependency
# (`[extras]` / `[targets].test`). When ReTestItems cannot run on a given Julia
# version, `Pkg.test()` fails before executing a single assertion — and Nitro then
# has zero verification on that version, even though nothing in `src/` is at fault.
#
# That is not hypothetical: ReTestItems v1.35.2 cannot run on Julia 1.13 at all
# (`Test.TESTSET_PRINT_ENABLE` changed from `Ref{Bool}` to `ScopedValue{Bool}`, and
# ReTestItems assigns to it), nor on 1.14-DEV (`@testsetup` cannot parse a `module`).
# See the tracking issue for both.
#
# So this script deliberately depends on NOTHING test-only. It is Nitro plus HTTP
# plus stdlib, which is exactly the surface a consuming application has. It answers
# the question the suite cannot: *does Nitro actually work on this Julia?*
#
# It is a smoke test, not a substitute for the suite. It should stay small and stay
# green; when ReTestItems supports the version again, the real suite takes over and
# this keeps serving as the fast "does it load and serve" check.
#
# Run:  julia --project=. .github/scripts/smoke_test.jl

using Test
using Sockets
using HTTP
using Nitro
using Nitro: path

const HOST = "127.0.0.1"

"""Bind port 0, read what the OS assigned, release it. Racy in principle, fine here:
this script runs one server, alone, in a CI job."""
function free_port()
    server = Sockets.listen(Sockets.localhost, 0)
    port = Int(Sockets.getsockname(server)[2])
    close(server)
    return port
end

@testset "Nitro smoke test on Julia $(VERSION)" begin

    # ── 1. The package loads ──────────────────────────────────────────────────
    # Not a formality on a new Julia. `__init__` redefines
    # `Base.getproperty(::HTTP.Request, ::Symbol)` via `@eval` and pirates
    # `HTTP.queryparams` (src/core.jl); both are exactly the kind of thing a compiler
    # or Base change breaks. Reaching this line at all means load-time wiring survived.
    @testset "loads and exposes its public surface" begin
        @test isdefined(Nitro, :serve)
        @test isdefined(Nitro, :path)
        @test isdefined(Nitro, :json)
        @test Nitro.Core.ServerContext() isa Nitro.Core.ServerContext
    end

    # ── 2. Request property overrides still work ──────────────────────────────
    # The `getproperty` override is the single most version-fragile thing in src/.
    @testset "request property overrides" begin
        req = HTTP.Request("GET", "/x?a=1&b=2", ["X-Trace" => "abc"])
        @test req.query == Dict("a" => "1", "b" => "2")
        req2 = HTTP.Request("POST", "/x", [], "{\"n\":7}")
        @test req2.json["n"] == 7
    end

    # ── 3. Routing + the response write path, over a real socket ──────────────
    # The non-consuming response write path reaches into the `HTTP.BytesBody.data`
    # internal, so "a request came back with the right body" is a real assertion
    # about version compatibility, not a tautology.
    @testset "serves over a real socket" begin
        ctx = Nitro.Core.ServerContext()
        Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
            path("/ping", req -> "pong"),
            # Typed converter bound to a declared handler argument. Registration itself
            # validates that the signature matches the pattern, so this line exercises
            # the reflection machinery (`splitdef`/`parse_func_params`) before a request
            # is ever made.
            path("/echo/<int:n>", (req, n::Int) -> Nitro.json(Dict("n" => n))),
        ])

        port = free_port()
        Nitro.Core.serve(ctx; port, host = HOST, async = true,
                         show_banner = false, show_errors = false, access_log = nothing)
        try
            base = "http://$(HOST):$(port)"

            r = HTTP.get("$base/ping"; retry = false, status_exception = false)
            @test r.status == 200
            @test String(r.body) == "pong"

            # Typed path converter -> handler -> JSON response builder.
            r2 = HTTP.get("$base/echo/42"; retry = false, status_exception = false)
            @test r2.status == 200
            @test occursin("42", String(r2.body))

            # A value the converter cannot bind is a 400, not a 404 — the converter is a
            # binder, not a routing filter. Cheap to assert and it pins that distinction.
            r3 = HTTP.get("$base/echo/abc"; retry = false, status_exception = false)
            @test r3.status == 400

            # An unrouted path must 404 rather than hang or 500.
            r4 = HTTP.get("$base/nope"; retry = false, status_exception = false)
            @test r4.status == 404
        finally
            Nitro.Core.terminate(ctx)
        end

        # The listener must actually be released — a version where shutdown regressed
        # would leave the port bound and this would throw.
        probe = Sockets.listen(Sockets.localhost, port)
        close(probe)
        @test true
    end
end
