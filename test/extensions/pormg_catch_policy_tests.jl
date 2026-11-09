@testitem "PormG ext: every catch follows the wrapped-interrupt policy (#904)" tags=[:extension] begin

using Test

# PormG hands a Ctrl-C during a query back wrapped, as a `DatabaseError` whose `cause` is the
# `InterruptException`. `is_unrecoverable` alone does not see through that, and #904 was two
# catches that therefore read a Ctrl-C as "no session" and as a failed prune. The fix is one
# predicate and one rethrow shape, defined beside `_interrupted` in the ext:
#
#     _unrecoverable(e) && rethrow(_bare(e))
#
# This reads the source, so the NEXT catch someone adds is held to it too: a catch either opens
# with that line or says, with the marker, that it guards no PormG statement.

const EXT = joinpath(pkgdir(Nitro), "ext", "NitroPormGExt.jl")
const MARKER = "# not a PormG statement (#904)"
lines = readlines(EXT)
code(l) = (s = strip(l); isempty(s) || startswith(s, '#')) ? nothing : s
# The code lines that match `pattern`, as `(line number, stripped text)`.
function code_lines(pattern)
    out = Tuple{Int, String}[]
    for (i, l) in enumerate(lines)
        s = code(l)
        s !== nothing && occursin(pattern, s) && push!(out, (i, String(s)))
    end
    return out
end

@testset "is_unrecoverable is used only through _unrecoverable" begin
    uses = code_lines("is_unrecoverable")
    allowed(s) = startswith(s, "import Nitro.Core.Errors:") ||
                 startswith(s, "_unrecoverable(e) = _interrupted(e) || is_unrecoverable(e)")
    stray = [i for (i, s) in uses if !allowed(s)]
    @test isempty(stray)
    isempty(stray) || @info "is_unrecoverable outside the predicate" lines = stray
    # The definition is there, once.
    @test count(((_, s),) -> startswith(s, "_unrecoverable(e) ="), uses) == 1
end

@testset "no catch rethrows or rebuilds a wrapped interrupt by hand" begin
    old = first.(code_lines(r"_interrupted\(\w+\) && (rethrow|throw)\("))
    @test isempty(old)
    isempty(old) || @info "an old interrupt shape remains" lines = old
end

@testset "every catch opens with the policy line, or carries the marker" begin
    offenders = Int[]
    ncatch = 0
    for (i, l) in enumerate(lines)
        s = code(l)
        s === nothing && continue
        m = match(r"^catch(?:\s+(\w+))?$", s)
        m === nothing && continue
        ncatch += 1
        var = m.captures[1]
        # The catch line and the comment lines up to its first statement may carry the marker.
        marked = occursin(MARKER, l)
        first_stmt = nothing
        for j in (i + 1):length(lines)
            t = strip(lines[j])
            isempty(t) && continue
            if startswith(t, '#')
                marked |= occursin(MARKER, t)
                continue
            end
            first_stmt = t
            break
        end
        policy = var === nothing ? nothing : "_unrecoverable($var) && rethrow(_bare($var))"
        (marked || first_stmt == policy) || push!(offenders, i)
    end
    @test ncatch > 0                      # the scan found the ext's catches at all
    @test isempty(offenders)
    isempty(offenders) || @info "catches without the policy line or the marker" lines = offenders
end

end
