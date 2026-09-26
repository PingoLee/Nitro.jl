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

@testset "secrets are scoped to the one step that deploys" begin
    # A workflow-level `env:` entry reaches every step of every job, PormG's build and test
    # steps included; a job-level one reaches every step of `docs`, including the instantiate
    # and doctest steps that resolve and run Documenter's floating dependency tree. Only
    # `deploydocs`, in `docs/make.jl`, reads either secret -- so they sit on that step (#332).
    # These anchor on indent: two spaces is workflow level, six is job level.
    @test !occursin(r"(?m)^  GITHUB_TOKEN:", CI_SRC)
    @test !occursin(r"(?m)^  DOCUMENTER_KEY:", CI_SRC)
    @test !occursin(r"(?m)^      GITHUB_TOKEN:", CI_SRC)
    @test !occursin(r"(?m)^      DOCUMENTER_KEY:", CI_SRC)
    # Present, once, on the deploy step -- not merely absent from the wider scopes. Asserting
    # only the absences above would stay green if the lines were deleted outright, which
    # would silently remove Documenter's fallback auth; the first rotation of DOCUMENTER_KEY
    # would then reproduce #105: a green docs job that published nothing.
    @test count(r"(?m)^\s+DOCUMENTER_KEY:", CI_SRC) == 1
    @test count(r"(?m)^\s+GITHUB_TOKEN:", CI_SRC) == 1
    # The step's own lines are indented eight or more; the next step (`      - `) or job ends it.
    deploy = match(
        r"(?m)^      - (?:name: .*\n        )?run: julia --project=docs docs/make\.jl\n((?:        .*(?:\n|$))*)",
        CI_SRC,
    )
    @test deploy !== nothing
    step = deploy === nothing ? "" : deploy[1]
    @test occursin(r"(?m)^        env:$", step)
    @test occursin(r"(?m)^          DOCUMENTER_KEY:\s*\$\{\{\s*secrets\.DOCUMENTER_KEY\s*\}\}", step)
    @test occursin(r"(?m)^          GITHUB_TOKEN:\s*\$\{\{\s*secrets\.GITHUB_TOKEN\s*\}\}", step)
end

@testset "the docs job does not leave the job token on disk" begin
    # Step-scoping the env is moot if checkout's default `persist-credentials: true` writes the
    # job token (here `contents: write`) into `.git/config`, where the instantiate and doctest
    # steps can read it. `deploydocs` pushes from its own tempdir clone, so nothing needs it.
    docs = match(r"(?m)^  docs:\n((?:(?:    .*|)\n)*?)(?=^  [\w-]+:$)", CI_SRC)
    @test docs !== nothing
    @test docs !== nothing && occursin(r"persist-credentials:\s*false", docs[1])
end

# How many jobs materialise the pinned PormG tree. Every assertion below scales off this
# rather than hard-coding 2, so adding a third such job cannot leave a hardening step
# behind -- the counts have to keep up with it.
#
# The counter moved with the mechanism. It used to key off the hand-rolled checkout step
# (`git init ../PormG.jl` + `fetch $PORMG_REV`), which no longer exists: `[sources]` pins
# PormG by url + rev, so whatever instantiates the project fetches it. That is
# `julia-actions/julia-buildpkg`, and it is therefore the honest marker for "this job
# materialises and may execute PormG's code". `docs` does not use it -- it instantiates
# `--project=docs`, which does not carry Nitro's `[sources]` -- which is what keeps the
# write scope and both secrets parked there, exactly as before.
const PORMG_JOBS = count(r"julia-actions/julia-buildpkg", CI_SRC)

@testset "PormG is pinned to an immutable commit, defined exactly once" begin
    # The pin lives in Project.toml now, not in the workflow. Read the SHIPPED file, for
    # the same reason every other assertion here does.
    project_src = read(joinpath(pkgdir(Nitro), "Project.toml"), String)
    sources = collect(eachmatch(r"(?m)^PormG\s*=\s*\{(.+)\}\s*$", project_src))
    # Exactly one `[sources]` entry for PormG, so nothing can drift apart.
    @test length(sources) == 1
    entry = sources[1][1]
    # A url + a full 40-hex commit. A TAG would satisfy "pinned" to the eye and not in
    # fact: tags are mutable and can be re-pointed, which is the whole property this is
    # for. So is a branch name.
    @test occursin("https://github.com/PingoLee/PormG.jl.git", entry)
    @test occursin(r"rev\s*=\s*\"[0-9a-f]{40}\"", entry)
    # ...and it is not a path dep any more. A path dep is what made the second, out-of-band
    # pin necessary (#21), and it is also what made resolution depend on whatever state a
    # sibling working tree happened to be in.
    @test !occursin("path", entry)

    # The workflow carries no PormG pin of its own. A second one is the drift being
    # prevented -- `PORMG_REV` had to be moved in lockstep with `[compat]` or CI tested a
    # configuration nobody ships.
    @test !occursin("PORMG_REV", CI_SRC)
    # ...and no hand-rolled checkout creeps back in, by clone or by init+fetch.
    @test !occursin(r"clone[^\n]*PormG\.jl\.git", CI_SRC)
    @test !occursin(r"init[^\n]*\.\./PormG\.jl", CI_SRC)

    # The jobs that build the project are still the two that did.
    @test PORMG_JOBS >= 2
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

@testitem "CI runs under coverage only in the job that uploads it" tags=[:core] setup=[NitroCommon] begin

# Why this item exists (#244).
#
# `julia-actions/julia-runtest` defaults its `coverage` input to `true`. ci.yml called it
# with no `with:` block and gated only the processing and upload steps, so all eight matrix
# jobs ran under `--code-coverage` while one published the result. `test/runtests.jl` sets
# `nworkers = 0` whenever it is covering, and ReTestItems applies `testitem_timeout` only on
# the worker path -- so no CI job had a per-item hang ceiling, the condition #84 closed.
#
# Nothing about that is visible from a green run: the suite passes exactly as before, it
# just cannot be stopped if an item hangs. So the three conditions are asserted equal here,
# against the shipped file, the same way the item above guards least privilege.

const CI_SRC = let raw = read(joinpath(pkgdir(Nitro), ".github", "workflows", "ci.yml"), String)
    s = replace(raw, '﻿' => "", "\r\n" => "\n")
    # Drop whole-line comments: ci.yml's own explanation names `coverage` and the action.
    join(filter(l -> !occursin(r"^\s*#", l), split(s, '\n')), '\n')
end

@testset "julia-runtest's coverage is gated like the upload" begin
    # One test step. A second would need its own gate, and nothing below would see it.
    @test count(r"julia-actions/julia-runtest@", CI_SRC) == 1

    # The input must be PRESENT -- absent means the action's `true` default. Other keys may
    # precede it in the `with:` block; the next step (`- uses:`) ends the search. `[^\n]*`
    # after the ref admits the trailing `# vX.Y.Z` a SHA pin carries (#332).
    run = match(
        r"julia-actions/julia-runtest@\S+[^\n]*\n\s+with:\n(?:\s+[\w-]+:.*\n)*?\s+coverage:\s*\$\{\{\s*(.+?)\s*\}\}",
        CI_SRC,
    )
    @test run !== nothing
    cond = run === nothing ? "" : strip(run[1])
    # A literal `true` would be the old bug spelled out; the gate has to name the matrix.
    @test occursin("matrix.", cond)

    # ...and it is the SAME job that processes and uploads coverage. If these drift, either
    # the uploader finds no `.cov` files, or a second job is back under coverage with no
    # timeout.
    uploads = [strip(m[1]) for m in eachmatch(
        r"(?:julia-actions/julia-processcoverage|coverallsapp/github-action)@\S+[^\n]*\n\s+if:\s*(.+)",
        CI_SRC,
    )]
    @test length(uploads) == 2
    @test all(==(cond), uploads)
end

end

@testitem "every workflow action is pinned to a commit SHA" tags=[:security, :core] setup=[NitroCommon] begin

# Why this item exists (#332).
#
# `uses: owner/repo@v2` names a TAG, and a tag is mutable: whoever controls the action's repo
# can re-point it, and every workflow resolving it runs the new code on its next trigger --
# the tj-actions/changed-files compromise (CVE-2025-30066) was exactly that. Nitro's jobs hand
# those actions a write-scoped token, the Documenter deploy key, and a PAT. The repo already
# refuses a tag for the PormG `[sources]` pin for this reason (see the first item above), so
# the same rule applies to actions: a full 40-hex commit, with the release as a comment.
#
# Every workflow file is scanned, not just ci.yml. A new workflow that goes back to a tag is
# the regression this catches, and it is invisible from a green run.

const WORKFLOWS_DIR = joinpath(pkgdir(Nitro), ".github", "workflows")
const WORKFLOWS = isdir(WORKFLOWS_DIR) ?
    sort(filter(f -> endswith(f, ".yml") || endswith(f, ".yaml"), readdir(WORKFLOWS_DIR; join = true))) :
    String[]

# Same normalisation as the items above: BOM, CRLF, and whole-line comments, which in these
# files name the very refs being asserted on.
function workflow_src(path)
    s = replace(read(path, String), '﻿' => "", "\r\n" => "\n")
    join(filter(l -> !occursin(r"^\s*#", l), split(s, '\n')), '\n')
end

@testset "every `uses:` names a full commit SHA" begin
    @test !isempty(WORKFLOWS)
    refs = [(basename(f), String(m[1])) for f in WORKFLOWS
            for m in eachmatch(r"(?m)^\s*(?:-\s+)?uses:\s*(\S+)", workflow_src(f))]
    # A floor, so a parser that silently matches nothing cannot pass vacuously.
    @test length(refs) >= 10
    # A local action (`./path`) is pinned by this repository's own history.
    unpinned = [(file, ref) for (file, ref) in refs
                if !startswith(ref, "./") && !occursin(r"^[\w.-]+/[\w./-]+@[0-9a-f]{40}$", ref)]
    @test isempty(unpinned)
end

@testset "Dependabot keeps the pins current" begin
    # Without it a SHA never moves, so the pins only age -- security fixes included.
    path = joinpath(pkgdir(Nitro), ".github", "dependabot.yml")
    @test isfile(path)
    @test isfile(path) && occursin(r"package-ecosystem:\s*\"?github-actions\"?", workflow_src(path))
end

end
