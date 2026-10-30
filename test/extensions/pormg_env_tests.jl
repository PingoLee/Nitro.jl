@testitem "PormG environment bridge" tags=[:extension, :pormg] setup=[NitroCommon] begin
using Test
using Nitro

# Load the extension the same way `extensions/pormg_worker_tests.jl` does.
@eval using PormG

# NOTE ON WHAT THIS TESTS, AND WHY IT IS NOT `__init__`.
#
# The bridge reaches `ENV["PORMG_ENV"]` from `NitroPormGExt.__init__`, but `__init__` runs
# ONCE PER PROCESS and the whole suite runs in one process (test/runtests.jl). Whether this
# item would see the extension's first load depends on what ran before it in that process, and
# once the module is loaded a second `using PormG` is a no-op. Driving `__init__` in-process
# would test nothing, and
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

    # The GENIE_ENV fallback reaches PormG too.
    withenv("NITRO_ENV" => nothing, "GENIE_ENV" => "test", "PORMG_ENV" => nothing) do
        @test Nitro.sync_pormg_env!() == "test"
        @test ENV["PORMG_ENV"] == "test"
    end
end

@testset "Nitro's \"dev\" fallback is never published (#331)" begin
    # This used to seed "dev" -- and PORMG_ENV outranks `default_env:` in connection.yml, so a
    # prod box relying on `default_env: prod` with no NITRO_ENV silently connected to dev. The
    # fallback is not a choice anyone made; `default_env:` is. So nothing is written, and PormG
    # resolves its own environment.
    withenv("NITRO_ENV" => nothing, "GENIE_ENV" => nothing, "PORMG_ENV" => nothing) do
        @test Nitro.current_env() == "dev"            # Nitro still REPORTS its fallback...
        @test Nitro.sync_pormg_env!() === nothing     # ...but does not publish it
        @test !haskey(ENV, "PORMG_ENV")
        # `force` overrides an existing value; with no environment set it has nothing to write.
        @test Nitro.sync_pormg_env!(force=true) === nothing
        @test !haskey(ENV, "PORMG_ENV")
    end
    withenv("NITRO_ENV" => nothing, "GENIE_ENV" => nothing, "PORMG_ENV" => "test") do
        @test Nitro.sync_pormg_env!(force=true) == "test"
        @test ENV["PORMG_ENV"] == "test"
    end
    # A blank PORMG_ENV counts as unset, as below -- and with nothing to publish over it, it is
    # removed rather than left for PormG to read as a `""` environment.
    withenv("NITRO_ENV" => "  ", "GENIE_ENV" => nothing, "PORMG_ENV" => "") do
        @test Nitro.sync_pormg_env!() === nothing
        @test !haskey(ENV, "PORMG_ENV")
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
    # ...but only when there is something to publish: a set PORMG_ENV means the variables are
    # never resolved, so the typo is `serve()`'s to report, not this function's.
    withenv("NITRO_ENV" => "prodution", "GENIE_ENV" => nothing, "PORMG_ENV" => "test") do
        @test Nitro.sync_pormg_env!() == "test"
    end
end

@testset "__init__ actually calls the bridge (subprocess)" begin
    # Everything above tests `sync_pormg_env!` directly. That leaves the wiring untested:
    # delete the call from `NitroPormGExt.__init__` and every assertion above still passes,
    # while the documented promise -- `load_many([...])` with no `env=` -- is gone. `__init__`
    # runs once per process, so the only way to exercise it is a fresh process. This also
    # pins that the `jl_generating_output` guard does not suppress the RUNTIME path.
    script = "using Nitro, PormG; print(get(ENV, \"PORMG_ENV\", \"<unset>\"))"
    # `--code-coverage=none` explicitly: CI runs the suite under coverage in the job that
    # uploads it (#244), `Base.julia_cmd()` propagates that flag, and coverage disables pkgimages
    # -- so without this each child re-JITs Nitro + PormG + the extension from source there.
    # Everything else must come FROM `julia_cmd()` (notably `--check-bounds=yes`, which
    # `Pkg.test` sets): dropping it would send the child to a different cache and cause
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

    # ...and with no environment set, loading PormG leaves PORMG_ENV alone (#331).
    out = withenv("NITRO_ENV" => nothing, "GENIE_ENV" => nothing, "PORMG_ENV" => nothing) do
        read(cmd, String)
    end
    @test out == "<unset>"
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
    # With no environment set the bridge publishes nothing (#331), so PormG's own rule applies.
    # In a REPL (`fallback = true`) that is the file's `default_env:`, else "dev" -- the case the
    # bridge used to override with Nitro's "dev" fallback. Everywhere else, which is what `load`
    # passes outside an interactive session since PormG 0.9 (PormG #1228), it is a refusal
    # naming the `env=` to add: why the generated boot names one, with
    # `env = something(sync_pormg_env!(), current_env())` (#790).
    withenv("NITRO_ENV" => nothing, "GENIE_ENV" => nothing, "PORMG_ENV" => nothing) do
        Nitro.sync_pormg_env!()
        @test PormG.Configuration._effective_env(nothing, "prod") == "prod"
        @test PormG.Configuration._effective_env(nothing, nothing) == "dev"
        @test_throws PormG.InvalidConfigurationError PormG.Configuration._effective_env(
            nothing, "prod"; fallback = false)
        @test PormG.Configuration._effective_env(Nitro.current_env(), "prod"; fallback = false) ==
              "dev"
    end
    # With `NITRO_ENV` set, the bridged value satisfies the service rule as well.
    withenv("NITRO_ENV" => "prod", "GENIE_ENV" => nothing, "PORMG_ENV" => nothing) do
        Nitro.sync_pormg_env!()
        @test PormG.Configuration._effective_env(nothing, "dev"; fallback = false) == "prod"
    end
end

@testset "the generated boot's environment keeps a deployment's PORMG_ENV (#790)" begin
    # `Nitro.newapp` passes `env = something(sync_pormg_env!(), current_env())`. A bare
    # `current_env()` would outrank a `PORMG_ENV` the deployment exported -- with `NITRO_ENV`
    # unset, a box on `PORMG_ENV=prod` would load `dev`, the wrong-database class #331 fixed --
    # and would make a block Nitro has no name for (`staging:`) unreachable.
    boot_env() = something(Nitro.sync_pormg_env!(), Nitro.current_env())
    cases = [
        (nitro = nothing, pormg = nothing,   want = "dev"),      # nothing chosen: Nitro's fallback
        (nitro = "prod",  pormg = nothing,   want = "prod"),     # NITRO_ENV, published by the bridge
        (nitro = nothing, pormg = "prod",    want = "prod"),     # the deployment's PORMG_ENV survives
        (nitro = nothing, pormg = "staging", want = "staging"),  # ...including one Nitro cannot name
        (nitro = "prod",  pormg = "test",    want = "test"),     # a default, never a force
        (nitro = "prod",  pormg = "  ",      want = "prod"),     # blank is unset
        (nitro = nothing, pormg = "",        want = "dev"),
    ]
    for c in cases
        withenv("NITRO_ENV" => c.nitro, "GENIE_ENV" => nothing, "PORMG_ENV" => c.pormg) do
            @test boot_env() == c.want
            # ...and PormG's service rule (no REPL fallback) resolves the named value as is.
            @test PormG.Configuration._effective_env(boot_env(), "dev"; fallback = false) == c.want
        end
    end
end

end
