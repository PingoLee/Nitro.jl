@testitem "internalrequest from an abstractly typed caller infers no pipeline (#737)" tags=[:core, :middleware] begin
using Test
using HTTP
using Nitro
import Nitro: App, path, text, urlpatterns

# The pipeline `internalrequest` builds is fully typed (#572). A caller whose request is inferred
# as the abstract `HTTP.Request` (a closure over a global, a struct field, an unspecialized
# helper) used to infer every layer of it for that abstract type the first time it compiled:
# 75-170 ms, where a concrete request reuses what was compiled already. `_run_pipeline`
# (src/core/pipeline.jl) stops that inference at one dynamic call.
#
# What that inference leaves behind is a method instance of a pipeline layer whose request
# argument is the abstract type itself. A global middleware layer of this item's own type is one
# such layer that nothing else in the suite can have inferred, so it reads this item's caller only.
struct Issue737Layer{H} <: Function
    handler::H
end
(l::Issue737Layer)(req::HTTP.Request) = l.handler(req)
issue737_layer(handler) = Issue737Layer(handler)

const APP737 = App()
urlpatterns(APP737, "", path("/737", (req::HTTP.Request) -> Res.send("737"); method = "GET"))

# Unspecialized, so it is compiled for the abstract `HTTP.Request` whatever it is called with.
abstract_hit(@nospecialize(r::HTTP.Request)) =
    Nitro.Core.internalrequest(APP737, r; middleware = (issue737_layer,))

abstract_instances() = [mi for m in methods(Issue737Layer(identity)) for mi in Base.specializations(m)
                        if mi isa Core.MethodInstance && mi.specTypes.parameters[2] === HTTP.Request]

@testset "compiling the abstract caller infers no layer over the abstract request" begin
    @test precompile(abstract_hit, (HTTP.Request,))
    @test isempty(abstract_instances())
end

@testset "the call itself still runs the whole pipeline" begin
    res = abstract_hit(HTTP.Request("GET", "/737"))
    @test res.status == 200 && text(res) == "737"
    # A body the transport never builds takes the barrier's dynamic call: same answer.
    res = abstract_hit(HTTP.Request("GET", "/737", [], "a body"))
    @test res.status == 200 && text(res) == "737"
    # The layer ran, at the request's concrete type.
    @test any(mi -> isconcretetype(mi.specTypes.parameters[2]),
              [mi for m in methods(Issue737Layer(identity)) for mi in Base.specializations(m)
               if mi isa Core.MethodInstance])
end
end
