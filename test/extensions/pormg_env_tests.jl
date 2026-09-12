@testitem "PormG environment bridge" tags=[:extension, :pormg] setup=[NitroCommon] begin
using Test
using Nitro

# Load the extension the same way `extensions/pormg_worker_tests.jl` does.
@eval using PormG

# NOTE ON WHAT THIS TESTS, AND WHY IT IS NOT `__init__`.
#
# The bridge reaches `ENV["PORMG_ENV"]` from `NitroPormGExt.__init__`, but `__init__` runs
# ONCE PER PROCESS and ReTestItems runs the whole suite in a single worker
# (`nworkers = 1`, test/runtests.jl). `extensions/pormg_worker_tests.jl` already triggers the
# extension load earlier in TEST_FILES, so by the time this item runs the module is loaded and
# a second `using PormG` is a no-op. Driving `__init__` in-process would test nothing, and
# could not reach both branches (seeds-a-default vs. respects-a-pre-set-value) anyway.
#
# So the bridge logic lives in `sync_pormg_env!` -- a named function declared as a stub in
# `src/exts.jl` and given its method by the extension -- and `__init__` is a one-line call to
# it. That is what makes the behavior testable in-process at all, and it is public API in its
# own right for the set-NITRO_ENV-late case. The wiring itself (that `__init__` really calls
# it) is covered separately, in a subprocess, at the bottom of this file.

ext = Base.get_extension(Nitro, :NitroPormGExt)
@test !isnothing(ext)

@testset "sync_pormg_env! is wired through the exts.jl stub seam" begin
    @test :sync_pormg_env! in names(Nitro)
    # The stub in src/exts.jl carries no method until the extension supplies one.
    @test !isempty(methods(Nitro.sync_pormg_env!))
end

# Every block pins all three variables, and `withenv` restores them on exit, so nothing leaks
# into the next test item sharing this worker process.

@testset "seeds PORMG_ENV as a default" begin
    withenv("NITRO_ENV" => "prod", "GENIE_ENV" => nothing, "PORMG_ENV" => nothing) do
        @test Nitro.sync_pormg_env!() == "prod"
        @test ENV["PORMG_ENV"] == "prod"
    end

    # Unset resolves through to Nitro's default rather than leaving PORMG_ENV absent.
    withenv("NITRO_ENV" => nothing, "GENIE_ENV" => nothing, "PORMG_ENV" => nothing) do
        @test Nitro.sync_pormg_env!() == "dev"
        @test ENV["PORMG_ENV"] == "dev"
    end

    # The GENIE_ENV fallback reaches PormG too.
    withenv("NITRO_ENV" => nothing, "GENIE_ENV" => "test", "PORMG_ENV" => nothing) do
        @test Nitro.sync_pormg_env!() == "test"
        @test ENV["PORMG_ENV"] == "test"
    end
end

@testset "a DEFAULT, never a force -- a pre-set PORMG_ENV survives" begin
    # This is the issue's hard constraint. An implementation that unconditionally assigns
    # passes every assertion in the testset above and fails here.
    withenv("NITRO_ENV" => "prod", "GENIE_ENV" => nothing, "PORMG_ENV" => "test") do
        @test Nitro.sync_pormg_env!() == "test"
        @test ENV["PORMG_ENV"] == "test"
        # Repeated calls stay idempotent -- no drift on a second load.
        @test Nitro.sync_pormg_env!() == "test"
        @test ENV["PORMG_ENV"] == "test"
    end

    # ...but BLANK is not "a value the app set" -- it is the same `$SOME_UNSET_VAR` shell
    # accident `current_env` already treats as unset, and honouring it would hand PormG an
    # empty `app_env` that matches no section in connection.yml. The two variables agree.
    withenv("NITRO_ENV" => "prod", "GENIE_ENV" => nothing, "PORMG_ENV" => "") do
        @test Nitro.sync_pormg_env!() == "prod"
        @test ENV["PORMG_ENV"] == "prod"
    end
    withenv("NITRO_ENV" => "prod", "GENIE_ENV" => nothing, "PORMG_ENV" => "   ") do
        @test Nitro.sync_pormg_env!() == "prod"
    end
end

@testset "force=true is the explicit override" begin
    withenv("NITRO_ENV" => "prod", "GENIE_ENV" => nothing, "PORMG_ENV" => "test") do
        @test Nitro.sync_pormg_env!(force=true) == "prod"
        @test ENV["PORMG_ENV"] == "prod"
    end
end

@testset "an unresolvable environment propagates rather than writing a bad value" begin
    # `sync_pormg_env!` itself throws; it is `__init__` that downgrades this to a warning, so
    # a typo can never make `using PormG` an InitError. The fatal check lives in `serve()`.
    withenv("NITRO_ENV" => "prodution", "GENIE_ENV" => nothing, "PORMG_ENV" => nothing) do
        @test_throws ArgumentError Nitro.sync_pormg_env!()
        @test !haskey(ENV, "PORMG_ENV")   # nothing half-written
    end
end

@testset "__init__ actually calls the bridge (subprocess)" begin
    # Everything above tests `sync_pormg_env!` directly. That leaves the wiring untested:
    # delete the call from `NitroPormGExt.__init__` and every assertion above still passes,
    # while the documented promise -- `load_many([...])` with no `env=` -- is gone. `__init__`
    # runs once per process, so the only way to exercise it is a fresh process. This also
    # pins that the `jl_generating_output` guard does not suppress the RUNTIME path.
    script = "using Nitro, PormG; print(get(ENV, \"PORMG_ENV\", \"<unset>\"))"
    # `--code-coverage=none` explicitly: CI runs `julia-actions/julia-runtest` with its default
    # `coverage: true`, `Base.julia_cmd()` propagates that flag, and coverage disables pkgimages
    # -- so without this each child re-JITs Nitro + PormG + the extension from source, on every
    # matrix job. Everything else must come FROM `julia_cmd()` (notably `--check-bounds=yes`,
    # which `Pkg.test` sets): dropping it would send the child to a different cache and cause
    # the very recompile this avoids.
    cmd = `$(Base.julia_cmd()) --code-coverage=none --project=$(Base.active_project()) --startup-file=no -e $script`

    out = withenv("NITRO_ENV" => "prod", "GENIE_ENV" => nothing, "PORMG_ENV" => nothing) do
        read(cmd, String)
    end
    @test out == "prod"

    # ...and it is still a default there, not a force.
    out = withenv("NITRO_ENV" => "prod", "GENIE_ENV" => nothing, "PORMG_ENV" => "test") do
        read(cmd, String)
    end
    @test out == "test"
end

@testset "the value Nitro publishes is the one PormG's own resolver would pick" begin
    # Guards the contract against drift on PormG's side: `_effective_env` consults
    # `ENV["PORMG_ENV"]` at precedence position 2, below an explicit `env=` kwarg.
    withenv("NITRO_ENV" => "prod", "GENIE_ENV" => nothing, "PORMG_ENV" => nothing) do
        Nitro.sync_pormg_env!()
        @test PormG.Configuration._effective_env(nothing, nothing) == "prod"
        # A file-level `default_env:` loses to the bridged value...
        @test PormG.Configuration._effective_env(nothing, "dev") == "prod"
        # ...but an explicit `env=` at the call site still wins over everything.
        @test PormG.Configuration._effective_env("test", nothing) == "test"
    end
end

end
