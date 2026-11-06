@testitem "juliac: the trimmed-only branches, run under the JIT (#858)" tags=[:core, :security] setup=[NitroCommon] begin
using Test

# ── The branches a trimmed image takes, in CI ───────────────────────────────────────────────────
#
# Under the JIT `_trimmed()` is the constant `false`, so inference deletes every branch it guards
# and no test process runs one. The probe build (`bench/juliac/probe.jl`) does, by hand. This item
# runs them in one child, `test/.helpers/trimmed_child.jl`, with `_trimmed()` redefined to `true`
# as a `--trim` build redefines it. The sites and how each is checked are listed in
# `test/.helpers/trimmed_sites.jl`:
#   A  the trimmed result equals the JIT result on the same inputs (the session copy and change
#      check, MemoryStore's copy, the JWT claims parse, the validator's arity);
#   B  a refusal makes no dynamic call and names a type, never a value; a fallback answers what
#      its comment says.
# The child calls each function directly, never through a request: with `_trimmed()` true a
# `RouteEndpoint` `ccall`s a thunk only a `--trim` build exports (src/routeendpoint.jl).

include(joinpath(@__DIR__, ".helpers", "trimmed_sites.jl"))

child = joinpath(@__DIR__, ".helpers", "trimmed_child.jl")
cmd = `$(Base.julia_cmd()) --code-coverage=none --project=$(Base.active_project()) --startup-file=no $child`
out, err = IOBuffer(), IOBuffer()
p = run(pipeline(ignorestatus(cmd); stdout = out, stderr = err))
out, err = String(take!(out)), String(take!(err))
lines = split(out, '\n'; keepempty = false)

@test (p.exitcode, p.termsignal) == (0, 0) || (last(out, 2000), last(err, 2000))
@test "DONE" in lines || last(out, 2000)
# The redefinition reached code compiled before it: a method the child compiled under the JIT now
# takes the trimmed branch.
@test "FLIP=true" in lines || out

@testset "no check failed, and every listed site has its checks" begin
    for line in lines
        startswith(line, "FAIL ") || startswith(line, "NOCHECK ") || continue
        @test false || line
    end
end

passed = Set(String(first(split(line[4:end], " | "; limit = 2))) for line in lines if startswith(line, "OK "))
@testset "every A and B site reported at least one passing check" begin
    for ((file, func), kind) in TRIMMED_SITES
        kind in (:A, :B) || continue
        @test "$file:$func" in passed || "$file:$func"
    end
end
end

@testitem "juliac: every _trimmed() site in src/ and ext/ is listed (#858)" tags=[:core] begin
using Test

# The guard that keeps the list above complete. A new `_trimmed()` site fails here until it is
# listed in `test/.helpers/trimmed_sites.jl`: as A or B, which the child item then checks, or as
# exempt with the reason. The sites are found by parsing, so a comment or a docstring that names
# `_trimmed()` is not one.

include(joinpath(@__DIR__, ".helpers", "trimmed_sites.jl"))

root = dirname(@__DIR__)
found = trimmed_sites(root)

@testset "the scanner finds the sites" begin
    # A floor, so a scanner that silently finds nothing cannot pass the set comparison below.
    @test length(found) >= length(TRIMMED_SITES)
end

@testset "every site is listed" begin
    for site in found
        @test haskey(TRIMMED_SITES, (site.file, site.func)) ||
              "$(site.file):$(site.line) in $(site.func) is a `_trimmed()` site not in " *
              "test/.helpers/trimmed_sites.jl: list it as :A, :B or exempt"
    end
end

@testset "every listed function holds the sites it is listed with" begin
    counts = Dict{Tuple{String, String}, Int}()
    for s in found
        counts[(s.file, s.func)] = get(counts, (s.file, s.func), 0) + 1
    end
    for (key, n) in counts
        haskey(TRIMMED_SITES, key) || continue        # reported above
        want = get(TRIMMED_SITE_COUNTS, key, 1)
        @test n == want || "$(key[1]): $(key[2]) holds $n `_trimmed()` sites, listed with $want; " *
                           "decide how the new one is tested, then update TRIMMED_SITE_COUNTS"
    end
    @test issubset(keys(TRIMMED_SITE_COUNTS), keys(TRIMMED_SITES))
end

@testset "every listed site still exists" begin
    keys_found = Set((s.file, s.func) for s in found)
    for key in keys(TRIMMED_SITES)
        @test key in keys_found || "$(key[1]): no `_trimmed()` site in $(key[2]) any more; remove it from the list"
    end
end

@testset "every exempt entry gives its reason" begin
    for (key, kind) in TRIMMED_SITES
        kind in (:A, :B) && continue
        @test kind isa Tuple && kind[1] === :exempt && kind[2] isa String && !isempty(kind[2]) || key
    end
end

@testset "a comment, a docstring or a quote is not a site; a function body is" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "src"))
        write(joinpath(dir, "src", "sample.jl"), """
            # `_trimmed()` in a comment
            \"\"\"
                described()

            The docstring mentions `_trimmed()` too.
            \"\"\"
            described() = nothing
            redefine() = Core.eval(@__MODULE__, :(_trimmed() = true))
            function refusing(@nospecialize(x))
                _trimmed() && throw(ArgumentError("refused"))
                return x
            end
            @noinline branching(x) = Types._trimmed() ? 1 : x
            Base.show(io::IO, ::Int8) = _trimmed() || print(io)
            """)
        sites = trimmed_sites(dir)
        @test [(s.func, s.line) for s in sites] == [("refusing", 10), ("branching", 13), ("Base.show", 14)]
        @test all(s -> s.file == "src/sample.jl", sites)
    end
end
end
