@testitem "Reflection self-reference matching" tags=[:core] setup=[NitroCommon] begin
using Base: @kwdef
using Test
using Nitro
using Nitro.Core.Reflection: splitdef

# Regression coverage for how `Reflection.reconstruct` tells a handler's self-reference
# apart from its default values. It used to match lowered *names*: first a substring
# test over the stringified, module-qualified node (testitem module `##Extractors#360`
# swallowed anonymous handler `#36`'s defaults), then exact gensym token shapes -- which
# Julia 1.12 broke by naming a closure written in `f`'s default arguments `#f##0#f##1`
# (#423). It now goes by position: only the forwarded call's callee is the self-reference.

@kwdef struct RSample
    limit::Int
    skip::Int = 33
end

extractor_default(f, name) = only(filter(p -> p.name == name, splitdef(f, start = 2).sig))

# A closure in a NAMED function's default argument -- named `#named_predicate##0#…` on 1.12.
named_predicate(req, q = Query{RSample}(s -> s.limit > 5)) = q
named_type_predicate(req, body = Json(RSample, s -> s.limit > 5)) = body
named_bare(req, q = Query{RSample}()) = q
named_with_kwargs(req, q = Query{RSample}(s -> s.limit > 5); n = 3) = q

@testset "named handler keeps a closure-bearing extractor default (#423)" begin
    for (f, name, X) in ((named_predicate, :q, Query), (named_type_predicate, :body, Json),
                         (named_with_kwargs, :q, Query))
        p = extractor_default(f, name)
        @test p.hasdefault
        @test p.type <: X
        @test p.default.validate isa Function
    end
    @test extractor_default(named_with_kwargs, :n).default == 3
end

@testset "a bare X{T}() default binds (#423)" begin
    p = extractor_default(named_bare, :q)
    @test p.hasdefault
    @test p.type == Query{RSample}
    @test isnothing(p.default.validate)
end

@testset "anonymous handler with kwargs keeps its defaults" begin
    handler = function (req, q = Query{RSample}(s -> s.limit > 5); n = 3)
        return q
    end
    @test extractor_default(handler, :q).hasdefault
    @test extractor_default(handler, :n).default == 3
end

# A default that cannot be evaluated at registration must hold its slot: defaults are
# mapped to names by position, so dropping it shifted `c`'s default onto `b`.
positional(req, a, b = a + 1, c = 5) = c
throwing(req, a = error("not at registration"), c = 5) = c

@testset "an unevaluable default does not shift later ones" begin
    for f in (positional, throwing)
        @test extractor_default(f, :c).hasdefault
        @test extractor_default(f, :c).default == 5
    end
    @test !extractor_default(positional, :b).hasdefault
    @test !extractor_default(throwing, :a).hasdefault
    @test isempty(splitdef(positional, start = 2).unevaluable)   # refers to a param, not an extractor
    @test !splitdef(throwing, start = 2).unevaluable[:a].builds_extractor
end

# A closure's captured variable reaches a default through `#self#`, which is not a parameter.
captured_factory(lim) = function (req, q = Query{RSample}(s -> s.limit < lim); n = lim)
    return q
end

@testset "a default that uses a captured variable evaluates" begin
    handler = captured_factory(7)
    q = extractor_default(handler, :q)
    @test q.hasdefault
    @test q.default.validate(RSample(limit = 6))
    @test !q.default.validate(RSample(limit = 7))
    @test extractor_default(handler, :n).default == 7
    @test isempty(splitdef(handler, start = 2).unevaluable)
end

unevaluable_extractor(req, q = Query{RSample}("x", "y")) = q
captures_param(req, n::Int, q = Query{RSample}(s -> s.limit < n)) = q

@testset "an unevaluable extractor default is reported, not dropped (#423)" begin
    for (f, name) in ((unevaluable_extractor, :q), (captures_param, :q))
        info = splitdef(f, start = 2)
        @test !info.sig_map[name].hasdefault
        @test info.unevaluable[name].builds_extractor
    end
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
