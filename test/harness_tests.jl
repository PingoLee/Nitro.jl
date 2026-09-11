@testitem "Test harness manifest is honest" tags=[:core] begin

# Why this file exists.
#
# `test/runtests.jl` runs a hand-written list, `TEST_FILES`, and nothing ever checked that
# the list matched what is on disk. `test/middleware/simple_http_test.jl` contained a real
# `@testitem` and was absent from the list, so it never ran -- under `Pkg.test()`, under
# CI, under anything (#34).
#
# That omission is invisible in the worst possible way: rung 1 of the verify ladder runs a
# new test file BY PATH, so it passes locally whether or not it was ever registered. The
# file is green in every check its author makes and absent from every check CI makes.
#
# The tag half is a weaker version of the same problem. ReTestItems does fail on a
# zero-match filter (`NoTestException("No test items found.")`) -- #34 claimed it reported
# success, and that is false -- but the message names neither the vocabulary nor the
# AND/exact-match semantics, so `--tags workers` failed without ever hinting that
# `:workers` was simply a tag nobody had applied.
#
# Both guards read `harness_manifest.jl`, the same file `runtests.jl` reads, rather than
# text-parsing `runtests.jl`. A regex over source would decide for itself what "the list"
# is, and could be green while the coordinator ran something else entirely.

include(joinpath(pkgdir(Nitro), "test", "harness_manifest.jl"))
using .NitroTestHarness: TEST_FILES, UNLISTED_OK, SKIPS_OK, KNOWN_TAGS, discover_test_files,
                         testitems, skip_macros

const TEST_ROOT = joinpath(pkgdir(Nitro), "test")

@testset "every test file on disk is listed, or excluded on purpose" begin
    found  = discover_test_files(TEST_ROOT)
    listed = Set(TEST_FILES)

    # A file that exists, looks like a test to ReTestItems, and appears in neither list is
    # a test nobody runs. `UNLISTED_OK` is the escape hatch, and it is deliberately a
    # written-down decision rather than an accident.
    orphans = [f for f in found if f ∉ listed && f ∉ UNLISTED_OK]
    @test orphans == String[]

    # The reverse: an entry naming a file that does not exist kills the run at startup.
    @test setdiff(listed, Set(found)) == Set{String}()

    # This guard is itself in TEST_FILES, and the assertion above covers itself. That is
    # not circular -- it reads the LIST, not the run -- and an unlisted guard would be a
    # guard that never executes, which is the defect being prevented.
    @test "harness_tests.jl" ∈ listed

    # Sanity floor. If discovery silently returned nothing, every assertion above would
    # pass vacuously and this file would be pure decoration.
    @test length(found) > 50
end

@testset "the tag vocabulary is closed, in both directions" begin
    used     = Set{Symbol}()
    untagged = String[]
    items    = 0
    for f in TEST_FILES
        for (name, tags) in testitems(joinpath(TEST_ROOT, f))
            items += 1
            isempty(tags) && push!(untagged, string(f, " :: ", name))
            union!(used, tags)
        end
    end

    # Same vacuity floor as above: an AST walk that found nothing would make the set
    # comparisons trivially true. Note this must be an AST walk and not a regex -- 33 of
    # the 61 test files start with a UTF-8 BOM, so `^@testitem` misses over half of them.
    @test items > 50

    # A tag in use but undocumented: the `--tags` vocabulary lies about what exists.
    @test setdiff(used, KNOWN_TAGS) == Set{Symbol}()

    # A documented tag nobody applies: `--tags <it>` then fails for every caller while the
    # vocabulary this file guards claims it exists. This is the direction that would have
    # caught `:workers` before it was applied, and the direction that kept `:csrf` out of
    # KNOWN_TAGS until `middleware/csrf_middleware_tests.jl` existed to carry it (#118).
    @test setdiff(KNOWN_TAGS, used) == Set{Symbol}()

    # An untagged item is invisible to every filtered run, including `--tags core`.
    @test untagged == String[]
end

@testset "no test file skips its way to a pass" begin
    # The generalisation of #128. That issue was one skip in one file, but the defect
    # class is "missing coverage reports as success", and it recurs the moment someone
    # writes another `if <dependency missing> @test_skip ... end`. Both `@test_skip` and
    # `@test_broken` report as `Broken`, which never changes the exit code -- so the
    # suite is green while running short, and nobody reads line 2,900 of the summary.
    #
    # Scanned over TEST_FILES rather than over disk on purpose: a skip in a file nobody
    # runs is already covered by the orphan assertion above, and scanning the run list is
    # what makes this guard about the SUITE rather than about the directory.
    offenders = String[]
    for f in TEST_FILES
        f ∈ SKIPS_OK && continue
        for (macroname, line) in skip_macros(joinpath(TEST_ROOT, f))
            push!(offenders, string(f, ":", line, " :: ", macroname))
        end
    end
    @test offenders == String[]

    # The other direction, matching how KNOWN_TAGS is checked: an entry in SKIPS_OK whose
    # file no longer skips anything is a stale permission slip, and leaving it there
    # re-opens the hole for the next edit to that file.
    stale = [f for f in SKIPS_OK if isempty(skip_macros(joinpath(TEST_ROOT, f)))]
    @test stale == String[]

    # Vacuity floor. `skip_macros` is an AST walk; if it silently returned nothing for
    # every input -- a parser change, a rename -- the assertions above would pass without
    # inspecting anything. Assert it finds every spelling in a string it is given directly.
    #
    # All four are floored on purpose. The KEYWORD forms are the ones most likely to be
    # lost in a refactor of `skip_macros`: they are matched in a different AST branch from
    # the `@test_skip` macros, and losing that branch silently re-opens #128 through the
    # idiom Test.jl documentation reaches for first.
    probe = tempname() * "_probe_tests.jl"
    write(probe, """
        @testset "p" begin
            @test_skip false
            Test.@test_broken false
            @test false skip=true
            @test false broken=true
        end
        """)
    try
        @test Set(first.(skip_macros(probe))) == Set([Symbol("@test_skip"),
                                                      Symbol("@test_broken"),
                                                      Symbol("@test skip="),
                                                      Symbol("@test broken=")])

        # An ordinary `@test` with an unrelated keyword must NOT be flagged, or the ban
        # fires on innocent code and gets deleted for crying wolf.
        clean = tempname() * "_clean_tests.jl"
        write(clean, "@test 1 == 1\n@test isempty([]) atol=0\n")
        try
            @test skip_macros(clean) == Tuple{Symbol, Int}[]
        finally
            rm(clean; force = true)
        end
    finally
        rm(probe; force = true)
    end
end

@testset "the coordinator guards are still installed" begin
    # `test/runtests.jl`'s three guards cannot be @testitems by construction -- ReTestItems
    # applies `--tags`/`--name` at AST level while including each file, so a guard item
    # would be removed by the very filter it exists to catch, and `validate_paths` is a
    # keyword on the `runtests` call itself. They are therefore verified by invocation,
    # by hand, and nothing would notice if one were deleted.
    #
    # These are text assertions against the shipped file -- the same technique
    # `ci_workflow_tests.jl` and `docs_deploy_tests.jl` use, and for the same reason: the
    # property is invisible from a green run. They check the guard is PRESENT, not that it
    # behaves; behaviour is the manual matrix recorded in the commit message.
    #
    # WHAT TO ANCHOR ON, if you add one: a presence assertion earns its keep when the thing
    # it names has exactly ONE spelling, and over-fits when the thing has many. A keyword
    # argument (`validate_paths = true`) has one spelling and its name IS the contract. A
    # condition does not -- `nworkers > 1`, `nworkers >= 2` and a hoisted variable are all
    # the same guard, so anchoring on the condition cries wolf on an innocent rewrite.
    # Anchor on the user-visible message instead: that text is what a confused caller
    # actually reads, so it is the part that must not silently disappear.
    #
    # The BOM strip is not cosmetic. `runtests.jl` begins with U+FEFF, which is category
    # Cf and NOT matched by `\s`, so the first comment line survives `^\s*#` and leaks into
    # `body`. Harmless for today's patterns, but a future assertion whose text happened to
    # appear in that leading comment would pass falsely.
    src  = replace(read(joinpath(pkgdir(Nitro), "test", "runtests.jl"), String), '﻿' => "")
    body = join(filter(l -> !occursin(r"^\s*#", l), split(src, '\n')), '\n')

    # Without this, a mistyped path is warned-and-dropped and the run still reports success
    # having never executed the file you named. That is the genuinely silent zero-test hole
    # (#34); ReTestItems defaults it to `false`. One spelling, so anchor on it directly.
    @test occursin(r"validate_paths\s*=\s*true", body)

    # `--workers N > 1` gives each process its own `CONTEXT[]`. Anchored on the refusal
    # message rather than on `nworkers > 1`, per the note above.
    @test occursin("is not supported", body)
    @test occursin("Use `--workers 0`", body)

    # The unknown-tag layer of the filter guard. NOT anchored on `KNOWN_TAGS`: that string
    # also appears in the `using .NitroTestHarness: ...` import at the top of the file,
    # which survives deleting the entire guard -- so it was green theater. This text exists
    # only inside the guard body.
    @test occursin("Unknown test tag(s)", body)

    # The incomplete-environment guard (#128). Both anchors are user-visible message text
    # with one spelling each, per the note above -- NOT the condition, which has many
    # equivalent spellings (`filter`/`setdiff`/`any`, `isempty(missing_deps)` either way
    # round). An earlier draft asserted `error(` immediately followed by the message; that
    # over-fits, because hoisting the string into a local is an innocent rewrite.
    #
    # "Refusing to run" is the load-bearing half. Re-dispatching was the behaviour that
    # ALREADY existed and still lost 112 assertions when the probe was satisfiable from the
    # global environment; what is new is that a still-missing dependency is refused rather
    # than tolerated. Like every assertion in this testset it checks the guard is PRESENT,
    # not that it behaves -- behaviour is the acceptance matrix in the commit message.
    @test occursin("Nitro test environment is incomplete", body)
    @test occursin("Refusing to run", body)

    # The probe must DERIVE its package list from `[targets].test` rather than naming a
    # package. This is the exception to "never anchor on the condition": the defect WAS
    # that one hardcoded package stood in for the whole set, so "where does the list come
    # from" is the property, not an implementation detail.
    #
    # Anchored on the FILENAME, not on `parsefile`. Any implementation that reads the
    # declared list must name `Project.toml`, whereas the reader itself has several honest
    # spellings (`TOML.parsefile`, `TOML.parse(read(p, String))`, `Pkg.Types.read_project`)
    # and pinning one would cry wolf on a refactor that preserves the property. Split
    # rather than `&&`-ed, so a failure says which half broke.
    #
    # Only the first and third of these three discriminate: mutation-checked against the
    # pre-fix file, `Project.toml` and the literal-name ban both FAIL there while the
    # middle line PASSES, because `Base.identify_package("Suppressor")` satisfies it too.
    # It is a sanity assertion that the probe still exists at all -- not a #128 guard.
    # Recorded so a later reader does not over-credit it.
    @test occursin("Project.toml", body)
    @test occursin(r"(identify|find)_package", body)

    # No literal package name is probed, in ANY spelling -- not just the `"Suppressor"`
    # that caused #128, and not just `identify_package`. Swapping in
    # `find_package("ReTestItems")` as the new proxy is the same defect wearing a different
    # name, and would sail past a check coupled to the old spelling (`test/revise_test.jl`
    # already uses `Base.find_package`, so that is a live alternative, not a hypothetical).
    # The shipped call passes a variable, so it does not match.
    @test !occursin(r"(identify|find)_package\(\s*\"", body)
end

end
