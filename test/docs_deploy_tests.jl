@testitem "docs deploy configuration" tags=[:core] setup=[NitroCommon] begin

# Why this file exists.
#
# `docs/make.jl` deployed to `github.com/NitroFramework/Nitro.jl.git` — an org that
# does not exist — for the whole life of the project, and nothing ever noticed.
# Documenter does not fail a build it cannot deploy; it logs the criteria it missed
# and returns normally, so CI stayed green while the site was never published and
# UPGRADING.md's "read the docs" link served a 404 (#105).
#
# That is the defining property of this defect class: it is invisible from inside a
# green build. So it gets a guard that reads the *shipped* file, the same way
# `upgrade_guide_tests.jl` parses the shipped UPGRADING.md, rather than trusting the
# docs build to complain.
#
# These are deliberately text assertions, not a Documenter call: Documenter lives in
# `docs/Project.toml`, not the package test env, and the failure being guarded is a
# misconfigured *literal*, which is exactly what text can check.

const MAKE_JL = joinpath(pkgdir(Nitro), "docs", "make.jl")

@testset "shipped docs/make.jl exists" begin
    @test isfile(MAKE_JL)
end

const MAKE_SRC = isfile(MAKE_JL) ? read(MAKE_JL, String) : ""

# Isolate the deploydocs(...) call, then strip its comment lines.
#
# Both halves are load-bearing, and each closes a hole the other leaves open:
#
#   * `^`-anchored, so the call must start a line. Prose above it discusses
#     `deploydocs` and has previously contained the literal "deploydocs()"; an
#     unanchored pattern matches *that* and captures the intervening comment text.
#   * comments dropped, so no assertion here can be satisfied by prose. That matters
#     specifically because the comment block above this call explains the bug by
#     naming both the old dead org and the branch — the exact strings asserted on
#     below. Matching against raw surrounding text would pass on a file whose actual
#     settings had been changed back.
const DEPLOY_CALL = let m = match(r"^deploydocs\((.*?)^\)"ms, MAKE_SRC)
    body = m === nothing ? "" : m.captures[1]
    join(filter(l -> !occursin(r"^\s*#", l), split(body, '\n')), '\n')
end

@testset "deploydocs targets this repository" begin
    # Guards the whole file being unparseable as well as a renamed/removed call.
    @test !isempty(DEPLOY_CALL)

    # The repo must be the one that actually exists and hosts the Pages site.
    @test occursin("github.com/PingoLee/Nitro.jl.git", DEPLOY_CALL)

    # `repo_ok` is the check that failed for the life of the project: Documenter tests
    # `occursin(ENV["GITHUB_REPOSITORY"], repo)`, and "PingoLee/Nitro.jl" does not occur
    # in a NitroFramework URL. Asserted against the *setting* only — the surrounding
    # comment names the dead org on purpose, to explain the history.
    @test !occursin("NitroFramework", DEPLOY_CALL)
end

@testset "devbranch is named explicitly" begin
    # `devbranch = nothing` resolves the branch via `git remote show origin` and falls
    # back to the literal "master" if that network call fails. This repo's branch is
    # `main`, so the fallback skips the deploy. Unlike the wrong-repo defect this one
    # does announce itself (Documenter emits a dedicated "main vs master" warning), and
    # the probe would usually succeed in CI — so this is hardening rather than the fix
    # itself. Asserted anyway: it costs nothing and the default is the wrong one here.
    @test occursin(r"devbranch\s*=\s*\"main\"", DEPLOY_CALL)
end

end
