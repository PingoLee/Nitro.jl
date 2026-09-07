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
using .NitroTestHarness: TEST_FILES, UNLISTED_OK, KNOWN_TAGS, discover_test_files, testitems

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
    # caught `:workers` before it was applied, and the reason `:csrf` is not in KNOWN_TAGS
    # -- there is no CSRF test item to carry it, which is #118 rather than something to
    # paper over here.
    @test setdiff(KNOWN_TAGS, used) == Set{Symbol}()

    # An untagged item is invisible to every filtered run, including `--tags core`.
    @test untagged == String[]
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
end

end
