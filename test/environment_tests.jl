@testitem "Environment resolution" tags=[:core] setup=[NitroCommon] begin
using Test
using Nitro
using Nitro.Core.Environment: _resolve_env, _present, NITRO_ENVS

# Every `withenv` here sets BOTH variables. `GENIE_ENV` is a real fallback now, so a block that
# only pins `NITRO_ENV` passes in CI and fails on any machine that exports `GENIE_ENV` -- a
# migrating Genie app's dev container being the obvious one.

@testset "the pure resolver" begin
    # `_resolve_env` takes the raw values rather than reading ENV, so the whole precedence
    # table is testable without mutating the process environment.

    @testset "precedence: NITRO_ENV > GENIE_ENV > \"dev\"" begin
        @test _resolve_env("prod", nothing) == "prod"
        @test _resolve_env(nothing, "prod") == "prod"
        @test _resolve_env(nothing, nothing) == "dev"
        # NITRO_ENV wins outright -- it does not merge with, or defer to, GENIE_ENV.
        @test _resolve_env("dev", "prod") == "dev"
        @test _resolve_env("test", "prod") == "test"
    end

    @testset "every recognised value round-trips from both variables" begin
        for e in NITRO_ENVS
            @test _resolve_env(e, nothing) == e
            @test _resolve_env(nothing, e) == e
        end
    end

    @testset "empty and whitespace-only count as UNSET, not as invalid" begin
        # `export NITRO_ENV=$SOME_UNSET_VAR` yields "" from `get(ENV, ...)`, not `nothing`.
        # Treating that as a typo would make a stray shell assignment fatal at every serve().
        @test _resolve_env("", nothing) == "dev"
        @test _resolve_env("   ", nothing) == "dev"
        @test _resolve_env("\t", nothing) == "dev"
        @test _resolve_env("", "prod") == "prod"      # falls through to GENIE_ENV
        @test _resolve_env("", "") == "dev"
        # ...and a padded real value is still that value.
        @test _resolve_env("  prod  ", nothing) == "prod"

        @test _present(nothing) === nothing
        @test _present("") === nothing
        @test _present("  ") === nothing
        @test _present(" prod ") == "prod"
    end

    @testset "an unknown value throws rather than defaulting silently" begin
        err = try; _resolve_env("prodution", nothing); catch e; e; end
        @test err isa ArgumentError
        msg = sprint(showerror, err)
        @test occursin("NITRO_ENV", msg)
        @test occursin("prodution", msg)        # names the offending value
        @test occursin("\"dev\", \"prod\", or \"test\"", msg)   # names the allowed set

        # It must NOT quietly fall back -- that is the whole point of #55.
        @test_throws ArgumentError _resolve_env("staging", nothing)
        @test_throws ArgumentError _resolve_env("production", nothing)
    end

    @testset "case mismatch gets a did-you-mean hint" begin
        msg = sprint(showerror, try; _resolve_env("PROD", nothing); catch e; e; end)
        @test occursin("did you mean \"prod\"?", msg)
        # A genuine typo has no hint to give, and must not invent one.
        @test !occursin("did you mean", sprint(showerror,
            try; _resolve_env("prodution", nothing); catch e; e; end))
    end

    @testset "a bad GENIE_ENV points at NITRO_ENV, not at Genie" begin
        # Genie permits names Nitro does not (`staging` is legal Genie). Still an error --
        # falling through to "dev" is the permissive direction -- but the message must offer a
        # fix that does not break the caller's Genie half.
        msg = sprint(showerror, try; _resolve_env(nothing, "staging"); catch e; e; end)
        @test occursin("GENIE_ENV", msg)
        @test occursin("staging", msg)
        @test occursin("set `NITRO_ENV` to override it", msg)

        # An invalid GENIE_ENV is irrelevant when NITRO_ENV is valid: it is never consulted.
        @test _resolve_env("prod", "staging") == "prod"
    end
end

@testset "current_env() reads the live environment" begin
    withenv("NITRO_ENV" => "prod", "GENIE_ENV" => nothing) do
        @test current_env() == "prod"
    end
    withenv("NITRO_ENV" => nothing, "GENIE_ENV" => "test") do
        @test current_env() == "test"
    end
    withenv("NITRO_ENV" => nothing, "GENIE_ENV" => nothing) do
        @test current_env() == "dev"
    end
    withenv("NITRO_ENV" => "prodution", "GENIE_ENV" => nothing) do
        @test_throws ArgumentError current_env()
    end

    # Deliberately NOT memoised: two calls straddling a change must disagree. A cached
    # implementation passes every assertion above and fails this one.
    withenv("NITRO_ENV" => "prod", "GENIE_ENV" => nothing) do
        @test current_env() == "prod"
        withenv("NITRO_ENV" => "test") do
            @test current_env() == "test"
        end
        @test current_env() == "prod"
    end

end

@testset "the public surface is exactly `current_env`" begin
    @test :current_env in names(Nitro)
    # The module's internals stay internal: a `@reexport` that pulled these up would make
    # `NITRO_ENVS` and the private resolver part of Nitro's API by accident.
    @test :NITRO_ENVS ∉ names(Nitro)
    @test :_resolve_env ∉ names(Nitro)
    @test :Environment ∉ names(Nitro)
end

@testset "serve() validates the environment even with the banner suppressed" begin
    # The regression guard for the real gap: `startserver` runs `serverwelcome` only
    # `if show_banner`. Validating only in the banner would let any caller that passes
    # `show_banner=false` -- embedded servers, most async starts, much of this suite -- run
    # with a typo'd NITRO_ENV and never notice, which is exactly the silent-wrong-environment
    # bug #55 exists to close. `serve` must reject it, and before binding a listener.
    port = get_free_port()
    err = withenv("NITRO_ENV" => "prodution", "GENIE_ENV" => nothing) do
        try
            serve(port=port, host=HOST, async=true, show_banner=false)
            nothing
        catch e
            e
        end
    end
    @test err isa ArgumentError
    # Assert on the MESSAGE, not just the type. `serve` throws a bare `ArgumentError` at three
    # earlier points -- the already-serving guard, the `revise` check, and `shutdown_timeout`.
    # The first is live risk here, not hypothetical: this item shares the global `CONTEXT[]`
    # with every other test file, so a leaked open server from an earlier item would satisfy
    # `@test_throws ArgumentError` and silently kill the regression guard for #55's headline
    # behavior.
    msg = sprint(showerror, err)
    @test occursin("NITRO_ENV", msg)
    @test occursin("prodution", msg)

    # ...and the same port still binds afterwards. `serve` runs the env check before it ever
    # reaches `startserver`, so a rejected call must leave no listener behind; if it bound and
    # then threw, this second `serve` would hit `EADDRINUSE` instead.
    withenv("NITRO_ENV" => "prod", "GENIE_ENV" => nothing) do
        server = serve(port=port, host=HOST, async=true, show_banner=false, show_errors=false)
        @test !isnothing(server)
        terminate()
    end
end

end
