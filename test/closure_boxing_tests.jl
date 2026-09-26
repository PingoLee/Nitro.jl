# A closure that assigns a variable from its enclosing scope -- or captures one the enclosing
# function assigns more than once -- stores that variable in a `Core.Box`, and every read of it
# through the box is an `Any`. On the request path that breaks nitro-core §7; anywhere else it is
# the same defect waiting for a caller on the hot path. #364 found it in the fixed-window rate
# limiter and, on a scan, in four more places, so a check scoped to one middleware would not
# have stopped it coming back.
#
# The box is visible without calling anything: Julia gives each closure its own type, bound in
# the defining module under a `#`-prefixed name, and a boxed capture is a field of type
# `Core.Box`. Reported with the captured variables' names, because an anonymous closure's own
# name (`#18#19`, the limiter's) says nothing about where it is defined.
@testitem "No Nitro closure captures a Core.Box (#364)" tags=[:core] begin
using Nitro
# Load the extension triggers so the extension half does not depend on which items ran first.
# Their own test files load these in-process already, so in a full run this is a no-op.
# Revise is left out on purpose: `revise_test.jl` only ever loads it in a subprocess, and
# loading it here would start its file watching in the shared worker.
using Mustache, OteraEngine, PormG, ProtoBuf, TimeZones

function boxed_closures(root::Module)
    seen = Set{Module}()
    closures = 0
    hits = Tuple{Module, Symbol, Vector{Symbol}}[]
    function walk(m::Module)
        m in seen && return
        push!(seen, m)
        for n in names(m; all = true, imported = false)
            isdefined(m, n) || continue
            v = getfield(m, n)
            if v isa Module
                parentmodule(v) === m && v !== m && walk(v)
            elseif v isa Type && startswith(String(n), "#")
                T = Base.unwrap_unionall(v)
                (T isa DataType && T <: Function) || continue
                closures += 1
                boxed = Symbol[f for (f, ft) in zip(fieldnames(T), fieldtypes(T)) if ft === Core.Box]
                isempty(boxed) || push!(hits, (m, n, boxed))
            end
        end
    end
    walk(root)
    return closures, hits
end

@testset "Nitro and its submodules" begin
    closures, hits = boxed_closures(Nitro)
    # Not vacuous: if Julia stopped binding closure types this way the walk would find none
    # and the emptiness check below would pass for the wrong reason.
    @test closures > 50
    @test hits == []
end

@testset "package extensions" begin
    for ext in (:NitroPormGExt, :MustacheExt, :OteraEngineExt, :ProtoBufExt, :TimeZonesExt)
        mod = Base.get_extension(Nitro, ext)
        @test (ext, mod isa Module) == (ext, true)
        mod isa Module || continue
        _, hits = boxed_closures(mod)
        @test (ext, hits) == (ext, [])
    end
end

end # @testitem "No Nitro closure captures a Core.Box (#364)"
