@testitem "Multiple Apps in one process" tags=[:core, :network] setup=[NitroCommon] begin

using Test
using HTTP
using Nitro

# Acceptance test for the public `App` handle (#31). This file is the converted
# `instance_tests.jl`: `instance()` used to be the only way to get two independent Nitro
# apps, and it bought that by `include_string`ing the WHOLE package into a gensym module —
# a full recompile per instance, and broken on any deployment where the source tree is not
# readable at runtime. Every assertion below is the one it made, now expressed against two
# `App` values in a single loaded copy of Nitro.
#
# What this pins, beyond "it runs": the two apps must not share a router. That is the whole
# capability, and it is what the process-wide `CONTEXT[]` singleton cannot give you.

app1 = App(mod = @__MODULE__)
app2 = App(mod = @__MODULE__)

urlpatterns(app1, "",
    path("/", () -> "welcome to server #1"),
    path("/subtract/<int:a>/<int:b>", (req, a::Int, b::Int) -> Dict("answer" => a - b) |> Res.json)
)

urlpatterns(app2, "",
    path("/", () -> "welcome to server #2"),
    path("/add/<int:a>/<int:b>", (req, a::Int, b::Int) -> Dict("answer" => a + b) |> Res.json)
)

# Start both together on their own ports, exactly as the instance() version did.
port1 = get_free_port()
port2 = get_free_port()
serve(app1; port=port1, async=true, show_errors=false, show_banner=false)
serve(app2; port=port2, async=true, show_errors=false, show_banner=false)

try
    @testset "unique apps" begin
        r = internalrequest(app1, HTTP.Request("GET", "/"))
        @test r.status == 200
        @test text(r) == "welcome to server #1"

        r = internalrequest(app2, HTTP.Request("GET", "/"))
        @test r.status == 200
        @test text(r) == "welcome to server #2"
    end

    @testset "add and subtract endpoints" begin
        r = internalrequest(app1, HTTP.Request("GET", "/subtract/10/5"))
        @test r.status == 200
        @test json(r)["answer"] == 5

        r = internalrequest(app2, HTTP.Request("GET", "/add/10/5"))
        @test r.status == 200
        @test json(r)["answer"] == 15

        r = internalrequest(app1, HTTP.Request("GET", "/subtract/5/10"))
        @test r.status == 200
        @test json(r)["answer"] == -5

        r = internalrequest(app2, HTTP.Request("GET", "/add/-10/-5"))
        @test r.status == 200
        @test json(r)["answer"] == -15
    end

    @testset "route tables do not leak between apps" begin
        # The instance() version never asserted this, because separate modules made it true
        # by construction. With one loaded Nitro it is a real claim about `App`, so pin it:
        # each app 404s the other's route.
        @test internalrequest(app1, HTTP.Request("GET", "/add/1/2")).status == 404
        @test internalrequest(app2, HTTP.Request("GET", "/subtract/1/2")).status == 404
    end

    @testset "neither app touched the global singleton" begin
        # The point of the handle: no global mutation. `resetstate()` is not called anywhere
        # in this item, so a leak here would be a real regression.
        @test internalrequest(HTTP.Request("GET", "/")).status == 404
    end

    @testset "an App does not leak secrets when displayed" begin
        # `App` is public now, so it reaches REPL auto-display and interpolated log lines.
        # Its `service` holds router/middleware closures that capture the cookie and JWT
        # `secret_key`; the custom `show` must not walk them.
        shown = sprint(show, app1)
        @test occursin("App(", shown)
        @test !occursin("Service", shown)
        @test !occursin("secret_key", shown)
    end
finally
    terminate(app1)
    terminate(app2)
end

end
