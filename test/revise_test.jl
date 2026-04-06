@testitem "Revise integration" tags=[:extension, :network] setup=[NitroCommon] begin

using Test
using Pkg: TOML
using Nitro
using HTTP

urlpatterns("",
    path("/", function() return text("Ok") end, method="GET"),
)

project_toml = TOML.parsefile(joinpath(pkgdir(Nitro), "Project.toml"))
@test get(project_toml["weakdeps"], "Revise", nothing) == "295af30f-e4ad-537b-8983-00126c2a3abe"
@test get(project_toml["extensions"], "NitroReviseExt", nothing) == "Revise"

revise_path = Base.find_package("Revise")
if revise_path === nothing
    @test_skip false
else
    integration_script = """
        using Revise
        using Nitro

        Nitro.has_revise_hooks() || error(\"Nitro did not register Revise hooks\")
        Base.get_extension(Nitro, :NitroReviseExt) !== nothing || error(\"NitroReviseExt was not loaded\")
        println(\"ok\")
    """
    integration_cmd = `$(Base.julia_cmd()) --project=$(pkgdir(Nitro)) -e $(integration_script)`
    @test success(integration_cmd)
end

original_revise_hooks = Nitro.revise_hooks()
Nitro.clear_revise_hooks!()

try
    @test_throws "Invalid `revise` value" serve(port=PORT, host=HOST, show_errors=false, show_banner=false, access_log=nothing, revise=:all)

    # Production path should not require Revise when hot reload is disabled.
    serve(port=PORT, host=HOST, show_errors=false, show_banner=false, access_log=nothing, async=true)
    @test String(HTTP.get("$localhost/").body) == "Ok"
    terminate()

    # Test error message when Revise support is unavailable.
    error_task = @async begin
        for revise in (:lazy, :eager)
            @test_throws "Revise support is unavailable" serve(port=PORT, host=HOST, show_errors=false, show_banner=false, access_log=nothing, revise=revise)
        end
    end

    if timedwait(() -> istaskdone(error_task), 60) == :timed_out
        error("Timed out waiting for Revise usage error")
    end

    function run_revise_mode_test(revise_mode::Symbol)
        revision_queue = [nothing] # non-empty
        revision_event = Channel{Nothing}(1)
        revise_mode == :eager && put!(revision_event, nothing)
        revise_called_count = Ref(0)
        invocation = []

        function revise()
            revise_called_count[] += 1
            empty!(revision_queue)
            return nothing
        end

        Nitro.register_revise_hooks!(;
            revise=revise,
            has_pending_revisions=() -> !isempty(revision_queue),
            wait_for_revision_event=() -> take!(revision_event),
        )

        function handler1(handler)
            return function(req::HTTP.Request)
                push!(invocation, 1)
                handler(req)
            end
        end

        try
            serve(port=PORT, host=HOST, show_errors=false, show_banner=false, access_log=nothing, revise=revise_mode, middleware=[handler1], async=true)

            if revise_mode == :eager
                @test timedwait(() -> revise_called_count[] == 1, 10) == :ok
            end

            @test String(HTTP.get("$localhost/").body) == "Ok"
            @test invocation == [1]
            @test revise_called_count[] == 1
        finally
            terminate()
            if revise_mode == :eager
                put!(revision_event, nothing)
            end
        end
    end

    run_revise_mode_test(:lazy)
    run_revise_mode_test(:eager)
finally
    if original_revise_hooks !== nothing
        Nitro.register_revise_hooks!(;
            revise=original_revise_hooks.revise,
            has_pending_revisions=original_revise_hooks.has_pending_revisions,
            wait_for_revision_event=original_revise_hooks.wait_for_revision_event,
        )
    else
        Nitro.clear_revise_hooks!()
    end
end

println()

end