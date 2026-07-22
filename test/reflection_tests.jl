@testitem "Reflection self-reference matching" tags=[:core] setup=[NitroCommon] begin
using Base: @kwdef
using Test
using Nitro
using Nitro.Core.Reflection: splitdef, _is_self_reference

# Regression coverage for the self-reference check in `Reflection.reconstruct`.
# The old implementation substring-matched the function name against the
# *stringified, module-qualified* node (`contains("$x", "$func_name")`), so an
# unrelated name that merely contained the function's name — e.g. testitem module
# `##Extractors#360` against anonymous handler `#36` — silently discarded a
# parameter's default value and the param degraded to a required query param.

@kwdef struct RSample
    limit::Int
    skip::Int = 33
end

@testset "_is_self_reference token shapes" begin
    # Genuine self-references: exact name and gensym derivatives.
    @test _is_self_reference("#36", "#36")
    @test _is_self_reference("#36#37", "#36")          # anonymous closure pair
    @test _is_self_reference("##36#40", "#36")         # nested gensym derivative
    @test _is_self_reference("myhandler", "myhandler")
    @test _is_self_reference("myhandler##kw", "myhandler")   # kwsorter
    @test _is_self_reference("#myhandler#12", "myhandler")   # inner closure of named fn

    # The collision class the old substring check got wrong.
    @test !_is_self_reference("#360", "#36")           # module ##Extractors#360 vs handler #36
    @test !_is_self_reference("#365#366", "#36")       # unrelated closure pair
    @test !_is_self_reference("myhandler2", "myhandler")
    @test !_is_self_reference("sample_guard_fn", "sample_guard")
    @test !_is_self_reference("Header", "#36")
    @test !_is_self_reference("", "#36")
end

# Integration: the default must survive when another symbol in the default
# expression CONTAINS the handler's name as a substring. With the old check,
# `sample_guard_fn` matched handler `sample_guard` and the Header default was
# dropped (handler then 500s at request time as a missing query param).
sample_guard_fn(s) = s.limit > 5
function sample_guard(req, headers = Header(RSample, sample_guard_fn))
    return headers.payload
end

@testset "default survives substring-colliding names" begin
    info = splitdef(sample_guard, start = 2)
    p = only(filter(p -> p.name == :headers, info.sig))
    @test p.hasdefault
    @test p.type <: Header
end

# The plain anonymous-handler case (mirrors extractor_tests' /headers route).
@testset "anonymous handler keeps extractor default" begin
    handler = function (req, headers = Header(RSample, s -> s.limit > 5))
        return headers.payload
    end
    info = splitdef(handler, start = 2)
    p = only(filter(p -> p.name == :headers, info.sig))
    @test p.hasdefault
    @test p.type <: Header
end

end # @testitem
