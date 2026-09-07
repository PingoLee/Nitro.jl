@testitem "CI workflow keeps least privilege and a pinned PormG" tags=[:security, :core] setup=[NitroCommon] begin

# Why this file exists.
#
# `.github/workflows/ci.yml` cloned `PingoLee/PormG.jl` at default-branch HEAD, unpinned,
# and then BUILT AND EXECUTED that code (`julia-actions/julia-buildpkg` -> `julia-runtest`)
# in jobs that carried `contents: write` + `actions: write` and a `GITHUB_TOKEN` in their
# environment. A force-push or account compromise on that third-party repo would have run
# arbitrary Julia in Nitro's CI with write access to this repository (#21).
#
# Every property below is invisible from inside a green CI run: a workflow that quietly
# regained `contents: write`, or went back to cloning a branch tip, passes all 8 matrix
# legs exactly as before. That is the same defect class `docs_deploy_tests.jl` guards
# against, and it gets the same treatment -- assertions against the *shipped* file rather
# than trust in the build going green.
#
# Text assertions, not a YAML parse: the package test env has no YAML parser, adding one
# would need a `[compat]` entry (and an answer for Aqua), and what is guarded here is a set
# of literals -- which is exactly what text can check.

const CI_YML = joinpath(pkgdir(Nitro), ".github", "workflows", "ci.yml")

@testset "shipped ci.yml exists" begin
    @test isfile(CI_YML)
end

# Normalise the two things the file actually has (a UTF-8 BOM and CRLF endings), then drop
# whole-line comments.
#
# The comment stripping is load-bearing, not tidiness. ci.yml's comments explain this fix
# by NAMING the very strings asserted on below -- `contents: write`, `persist-credentials`,
# `GITHUB_TOKEN`, the old clone command. Against the raw text, a file whose real settings
# had been reverted would still satisfy several of these assertions from its prose alone.
const CI_SRC = let raw = isfile(CI_YML) ? read(CI_YML, String) : ""
    s = replace(raw, '﻿' => "", "\r\n" => "\n")
    join(filter(l -> !occursin(r"^\s*#", l), split(s, '\n')), '\n')
end

@testset "no write scope outside the one job that deploys" begin
    # `docs` is the sole writer. It fetches no PormG, which is why the scope lives there
    # rather than at workflow level.
    #
    # It is NOT third-party-code-free, and this comment must not imply otherwise:
    # `docs/Manifest.toml` is gitignored, so Documenter and its transitive tree resolve
    # from the General registry at floating versions and then run, holding DOCUMENTER_KEY.
    # That is the residual exposure after #21 and is tracked in ci.yml's own comment.
    #
    # Counting rather than asserting absence keeps this honest -- a second occurrence
    # means some other job regained write.
    @test count(r"contents:\s*write", CI_SRC) == 1
    @test count(r"actions:\s*write", CI_SRC) == 1
    # The workflow-level floor. Two-space indent pins it to the top-level block; a job's
    # own `permissions:` is indented four.
    @test occursin(r"(?m)^permissions:\n  contents: read$", CI_SRC)
end

@testset "secrets are job-scoped, never workflow-level" begin
    # A workflow-level `env:` entry reaches every step of every job, PormG's build and test
    # steps included. Job-level (six-space indent, under `docs`) is the whole point, so
    # these anchor on indent -- two spaces would mean workflow level.
    @test !occursin(r"(?m)^  GITHUB_TOKEN:", CI_SRC)
    @test !occursin(r"(?m)^  DOCUMENTER_KEY:", CI_SRC)
    # Present-and-job-scoped, not merely absent from the top. Asserting only the absence
    # above would stay green if the line were deleted outright -- which would silently
    # remove Documenter's fallback auth, and the first rotation of DOCUMENTER_KEY would
    # then reproduce #105: a green docs job that published nothing.
    @test count(r"(?m)^      DOCUMENTER_KEY:", CI_SRC) == 1
    @test count(r"(?m)^      GITHUB_TOKEN:", CI_SRC) == 1
end

# How many jobs materialise the pinned PormG tree. Every assertion below scales off this
# rather than hard-coding 2, so adding a third such job cannot leave a hardening step
# behind -- the counts have to keep up with it.
#
# Two independent counters, and the larger wins. The fetch line is the direct evidence, but
# it only matches when `fetch` and a bare `$PORMG_REV` share a line; a future job spelling
# it `"${PORMG_REV}"` or `${{ env.PORMG_REV }}` would count zero and quietly shrink the
# floor. `git init ../PormG.jl` is invariant to how the revision is spelled.
const PORMG_JOBS = max(count(r"fetch[^\n]*\$PORMG_REV", CI_SRC),
                       count(r"init[^\n]*\.\./PormG\.jl", CI_SRC))

@testset "PormG is pinned to an immutable commit, defined exactly once" begin
    revs = collect(eachmatch(r"PORMG_REV:\s*([0-9a-f]{40})\b", CI_SRC))
    # Exactly one definition, so the jobs consuming it cannot drift apart. This one IS an
    # equality on purpose -- a second definition is the drift being prevented.
    @test length(revs) == 1
    # ...and it is consumed by the `test` and `smoke` jobs.
    @test PORMG_JOBS >= 2
    @test count(r"\$PORMG_REV", CI_SRC) >= PORMG_JOBS
    # A branch-tip clone is the defect being guarded: `--depth 1` can only fetch a tip,
    # which is why the pinned form is init + fetch-by-SHA instead.
    @test !occursin(r"clone[^\n]*PormG\.jl\.git", CI_SRC)
end

@testset "every job that fetches the PormG tree is hardened" begin
    # These are `>=`, not `==`, and the direction matters in both ways.
    #
    # `==` would go RED when someone hardens an ADDITIONAL job (a strictly safer change) --
    # and a guard that punishes hardening is a guard that gets deleted. It would also stay
    # GREEN if a third PormG-fetching job were added WITHOUT hardening, which is the defect
    # this file exists to catch. Scaling off PORMG_JOBS is blind in neither direction.
    #
    # The floor is repeated here on purpose. `>=` against a PORMG_JOBS of 0 passes
    # vacuously -- which is exactly what happens against the pre-fix file, where nothing
    # matches either counter. Without this line the whole testset would go green on the
    # very workflow it exists to reject, and stay green if the floor in the testset above
    # were ever relaxed or reordered.
    @test PORMG_JOBS >= 2

    # `actions/checkout` defaults to `persist-credentials: true`, which writes an
    # `AUTHORIZATION: basic <token>` extraheader into `$GITHUB_WORKSPACE/.git/config` --
    # on disk, readable by any process in the job. `permissions:` decides what that token
    # can do; only this decides whether it is there at all.
    @test count(r"persist-credentials:\s*false", CI_SRC) >= PORMG_JOBS
    # `actions: write` exists solely so julia-actions/cache can evict old caches. These
    # jobs give up eviction so they can give up the scope; save and restore need no
    # permissions at all.
    @test count(r"delete-old-caches:\s*'false'", CI_SRC) >= PORMG_JOBS
end

end
