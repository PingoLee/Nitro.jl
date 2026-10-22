@testitem "juliac internals contract" tags=[:core] setup=[NitroCommon] begin
using Test
import Nitro

# ── Canary for Nitro's coupling to Base's compiled-image surface (#718) ─────────────────────
#
# `RouteEndpoint` (src/routeendpoint.jl) is the one erasure point per route that lets a request
# through `juliac --trim=safe`. In a `--trim` build its registration makes three calls into Base
# that no stable API covers, and the request path makes one into libc:
#
#   • `Base._ccallable(name::String, rt::Type, sigt::Type)` — `@ccallable`'s function form: exports
#       a method under a C symbol. Undocumented and underscore-prefixed. Nitro relies on two of its
#       refusals as well as on its success: it looks the method up by its EXACT signature (not by
#       dispatch), and it refuses an argument type that is not concrete. That is why the endpoint
#       `Core.eval`s one concrete thunk method per chain type, and why the thunk takes `Ptr{Cvoid}`s.
#   • `Base.Experimental.entrypoint(f, argtypes::Tuple)` — roots a specialization in a trimmed image.
#       Experimental. On 1.12 it calls `jl_add_entrypoint` unconditionally; on 1.13 it does so only
#       while generating output. Either way it must accept the call shape below outside a build.
#   • `Base.JLOptions().trim` — how registration knows it is running inside a `--trim` build.
#   • `Base.Libc.Libdl.dlsym_e` on `cglobal(:jl_exe_handle)` — how the first call in a trimmed image
#       finds the exported thunk again, since an image does not keep a pointer. Julia's own `jl_dlsym`,
#       so it works where libc's `dlsym` does not exist (Windows). A symbol `_ccallable` registers
#       OUTSIDE a build is not in the executable's table, which is why the JIT never takes that path.
#
# Every assertion here is about what Nitro calls, in the shape it calls it. Must pass on Julia
# 1.12 (the release whose juliac the trimmed build is measured with) and 1.13 (CI). A failure means
# the trimmed path needs re-checking with `bench/juliac/build.sh` on the new release before
# anything else; docs/design/juliac-trim.md §3.2.

const T = Nitro.Core.Types

@testset "the methods Nitro calls exist with the signatures it calls" begin
    @test hasmethod(Base._ccallable, Tuple{String, Type, Type})
    @test hasmethod(Base.Experimental.entrypoint, Tuple{Any, Tuple})
    @test hasfield(Base.JLOptions, :trim)
    @test Base.JLOptions().trim isa Integer
    # The JIT that runs this suite is not a `--trim` build, so nothing was exported and the
    # endpoint's branch is the direct call.
    @test Base.JLOptions().trim == 0
    @test T._trimmed() === false
end

# A thunk shaped like `EndpointThunk{C,R}`, with its concrete method defined the way
# `_export_thunk` defines one. A local type, so nothing here touches Nitro's own export table.
struct ContractThunk{C} end
_contract_body(::Type{C}, a::Ptr{Cvoid}, b::Ptr{Cvoid}, c::Ptr{Cvoid}) where {C} = nothing
(::ContractThunk{C})(a::Ptr{Cvoid}, b::Ptr{Cvoid}, c::Ptr{Cvoid}) where {C} = _contract_body(C, a, b, c)
(::ContractThunk{Int})(a::Ptr{Cvoid}, b::Ptr{Cvoid}, c::Ptr{Cvoid}) = _contract_body(Int, a, b, c)
const ARGS3 = (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid})

@testset "entrypoint accepts the call shape outside a build" begin
    # Its return value differs by release (1.12: `jl_add_entrypoint`'s `Int32`; 1.13: `nothing`
    # outside a build), and Nitro ignores it. Only that it accepts the call is pinned.
    @test (Base.Experimental.entrypoint(ContractThunk{Int}(), ARGS3); true)
end

@testset "_ccallable exports a concrete method, and refuses what Nitro works around" begin
    sig(C, args...) = Tuple{ContractThunk{C}, args...}
    @test Base._ccallable("nitro_contract_concrete", Cvoid, sig(Int, ARGS3...)) === nothing
    # Exact signature, not dispatch: `ContractThunk{Float64}` is covered by the `where {C}`
    # method, and that does not count. This refusal is why `_export_thunk` `Core.eval`s.
    err = try
        Base._ccallable("nitro_contract_generic", Cvoid, sig(Float64, ARGS3...)); nothing
    catch e
        e
    end
    @test err isa ErrorException && occursin("could not find requested method", err.msg)
    # Concrete C argument types only: this refusal is why the thunk takes three `Ptr{Cvoid}`s
    # and the caller passes `Any`s through `ccall`.
    err = try
        Base._ccallable("nitro_contract_any", Cvoid, Tuple{ContractThunk{Int}, Any, Ptr{Cvoid}, Ptr{Cvoid}})
        nothing
    catch e
        e
    end
    @test err isa ErrorException && occursin("must be concrete", err.msg)
end

@testset "the image lookup finds no symbol exported outside a build" begin
    @test hasmethod(Base.Libc.Libdl.dlsym_e, Tuple{Ptr{Cvoid}, String})
    @test unsafe_load(cglobal(:jl_exe_handle, Ptr{Cvoid})) != C_NULL
    @test T._image_symbol("nitro_contract_concrete") == C_NULL
    # ...so a trimmed-image call that finds no code says so, rather than calling NULL.
    ep = T.RouteEndpoint((req) -> "never", "nitro_contract_missing", C_NULL, C_NULL)
    err = try
        T._endpoint_fptr!(ep, true); nothing
    catch e
        e
    end
    @test err isa ErrorException && occursin("register routes at top level", err.msg)
end
end
