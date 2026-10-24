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
    ep = T.RouteEndpoint((req) -> "never", "nitro_contract_missing", nothing, C_NULL, C_NULL)
    err = try
        T._endpoint_fptr!(ep, true); nothing
    catch e
        e
    end
    @test err isa ErrorException && occursin("register routes at top level", err.msg)
end

# `LifecycleThunk{L}` (#719) is exported the same way, with a `Cint` in the middle: concrete, so
# `_ccallable` takes it.
struct ContractLifecycleThunk{L} end
(::ContractLifecycleThunk{Int})(a::Ptr{Cvoid}, up::Cint, c::Ptr{Cvoid}) = nothing

@testset "_ccallable exports the lifecycle thunk's shape" begin
    @test Base._ccallable("nitro_contract_lifecycle", Cvoid,
                          Tuple{ContractLifecycleThunk{Int}, Ptr{Cvoid}, Cint, Ptr{Cvoid}}) === nothing
    @test (Base.Experimental.entrypoint(ContractLifecycleThunk{Int}(), (Ptr{Cvoid}, Cint, Ptr{Cvoid})); true)
    # A lifecycle entry with no code in this process is refused, never called through `C_NULL`.
    lm = Nitro.Core.LifecycleMiddleware(middleware = h -> h, on_startup = () -> nothing)
    for sym in ("", "nitro_contract_lifecycle_missing")
        e = T.LifecycleEntry(lm, sym, C_NULL, C_NULL)
        err = try
            T._lifecycle_fptr!(e); nothing
        catch caught
            caught
        end
        @test err isa ErrorException && occursin("no code for this lifecycle middleware", err.msg)
    end
end
end

@testitem "juliac: the server handle's foreign calls" tags=[:core, :network] setup=[NitroCommon] begin
using Test
import Nitro

# ── `ServerHandle` (src/context.jl), which keeps `Service.server` concrete ─────────────────────
#
# In a trimmed build each call through the handle is a `ccall` to a static `@cfunction` that
# `ServerHandle(server)` takes where the server's type `S` is concrete: an argument declared
# `Ref{S}` on the shim's side and passed as `Any` on the caller's, an `Any` result, and a shim that
# hands an exception back instead of letting it unwind through the foreign frame. A failure means
# the trimmed path needs re-checking with `bench/juliac/build.sh`; docs/design/juliac-trim.md §3.3.

const AC = Nitro.Core.AppContext

@testset "under the JIT the handle holds only the server" begin
    app = Nitro.Core.App()
    try
        server = Nitro.serve(app; host = "127.0.0.1", port = get_free_port(), async = true,
                             show_banner = false, access_log = false)
        h = app.service.server[]
        @test h isa AC.ServerHandle && h.server === server
        @test h.isopen_c == C_NULL && h.wait_c == C_NULL && h.close_c == C_NULL
        @test isopen(app.service)
    finally
        Nitro.Core.terminate(app)
    end
    @test isnothing(app.service.server[])
end

# The trimmed branches themselves, in a child: `_trimmed()` is redefined to `true` there, as a
# `--trim` build's route registration redefines it, which would flip every `RouteEndpoint` in this
# process to its `ccall` path. The child registers no route and sends no request, so only the
# server handle takes it: `serve` builds it through the real constructor, and `isopen`, `wait`
# and `close(::Service)` make the real `ccall`s.
@testset "the trimmed branches make their foreign calls" begin
    script = """
    import Nitro
    const AC = Nitro.Core.AppContext
    Core.eval(Nitro.Core.Types, :(_trimmed() = true))
    app = Nitro.Core.App()
    server = Nitro.serve(app; host = "127.0.0.1", port = $(get_free_port()), async = true,
                         show_banner = false, access_log = false)
    h = app.service.server[]
    println("PTRS=", h.server === server && h.isopen_c != C_NULL && h.wait_c != C_NULL && h.close_c != C_NULL)
    println("OPEN=", isopen(app.service))
    # A throw inside the shim comes back as a value and is thrown again here, as itself.
    neg = try close(app.service; timeout = -1); "none" catch e; e isa ArgumentError ? "ArgumentError" : string(typeof(e)) end
    println("NEGATIVE=", neg, " ", app.service.server[] === h, " ", isopen(app.service))
    # A wait parked inside the foreign frame, then a graceful shutdown, which spawns its drain and
    # parks in `timedwait` inside another one.
    w = @async wait(app.service)
    sleep(0.5)
    println("PARKED=", istaskstarted(w) && !istaskdone(w))
    close(app.service; timeout = 5)
    println("CLOSED=", isnothing(app.service.server[]), " ", !isopen(server))
    println("WAITED=", fetch(w) === nothing)
    # A handle without pointers is refused, never called through `C_NULL`.
    bare = AC.ServerHandle(server, C_NULL, C_NULL, C_NULL)
    println("BARE=", try isopen(bare); "called" catch e; e isa ErrorException ? "refused" : "other" end)
    """
    cmd = `$(Base.julia_cmd()) --code-coverage=none --project=$(Base.active_project()) --startup-file=no -e $script`
    out, err = IOBuffer(), IOBuffer()
    p = run(pipeline(ignorestatus(cmd); stdout = out, stderr = err))
    out, err = String(take!(out)), String(take!(err))
    @test (p.exitcode, p.termsignal) == (0, 0) || (out, last(err, 2000))
    for line in ("PTRS=true", "OPEN=true", "NEGATIVE=ArgumentError true true", "PARKED=true",
                 "CLOSED=true true", "WAITED=true", "BARE=refused")
        @test occursin(line, out) || (line, out)
    end
end
end

@testitem "juliac: the lifecycle hooks' foreign calls, and Revise refused" tags=[:core, :network] setup=[NitroCommon] begin
using Test
import Nitro

# ── `LifecycleEntry` (src/routeendpoint.jl), which keeps the lifecycle registry concrete (#719) ──
#
# In a trimmed build a serve-owned entry's hooks are a `ccall` to a static `@cfunction` that
# `serve_lifecycle_entry` takes where the middleware's type is concrete: `Ref{L}` and a `Cint` on
# the shim's side, `Any` and a `Cint` on the caller's, an `Any` result. A route-owned entry's are a
# thunk exported while the image is built, which this process, not being a build, cannot export.
# docs/design/juliac-trim.md §3.4.

const T = Nitro.Core.Types
const RH = Nitro.Core.RouterHOF

@testset "under the JIT an entry holds no pointer and calls the hook directly" begin
    up = Ref(0)
    lm = Nitro.Core.LifecycleMiddleware(middleware = h -> h, on_startup = () -> (up[] += 1))
    app = Nitro.Core.App()
    RH.register_serve_lifecycle!(app, (lm,))
    RH.register_route_lifecycle!(app, Any[Nitro.Core.LifecycleMiddleware(middleware = h -> h)])
    route_lf, serve_lf = RH.lifecycle_snapshot(app)
    for e in (only(route_lf), only(serve_lf))
        @test e isa T.LifecycleEntry && e.sym == "" && e.shim == C_NULL && e.thunk == C_NULL
    end
    @test only(serve_lf).mw === lm
    @test T.startup(only(serve_lf)) === nothing && up[] == 1
end

# The trimmed branches, in a child with `_trimmed()` redefined to `true` (see the server handle's
# item above for why a child). It registers no route.
@testset "the trimmed branches make their foreign calls" begin
    script = """
    import Nitro
    const T = Nitro.Core.Types
    const RH = Nitro.Core.RouterHOF
    using Nitro.Core: LifecycleMiddleware, App, startup, shutdown
    Core.eval(T, :(_trimmed() = true))
    up, down = Ref(0), Ref(0)
    lm = LifecycleMiddleware(middleware = h -> h, on_startup = () -> (up[] += 1),
                             on_shutdown = () -> (down[] += 1))
    boom = LifecycleMiddleware(middleware = h -> h, on_startup = () -> error("hook failed"))
    intr = LifecycleMiddleware(middleware = h -> h, on_startup = () -> throw(InterruptException()))
    app = App()
    RH.register_serve_lifecycle!(app, (lm, boom, intr, h -> h))
    _, s = RH.lifecycle_snapshot(app)
    println("PTRS=", length(s) == 3 && all(e -> e.shim != C_NULL && e.sym == "", s))
    println("UP=", startup(s[1]) === nothing, " ", up[])
    # A hook's own throw is logged and swallowed by `startup`, on the far side of the foreign frame.
    println("BOOM=", startup(s[2]) === nothing)
    # An interrupt comes back as a value, as it does from a direct call (#185).
    println("INTERRUPT=", startup(s[3]) isa InterruptException)
    println("DOWN=", shutdown(s[1]) === nothing, " ", down[])
    # A `Vector` member has no compiled hooks in an image, so it is refused.
    vec = try RH.register_serve_lifecycle!(App(), Any[lm]); "accepted" catch e; e isa ArgumentError ? "refused" : "other" end
    println("VECTOR=", vec)
    # A route-owned entry gets its thunk only from a `--trim` build; this process is not one, so
    # registration refuses it, before the registry changes, rather than `startserver` later.
    app2 = App()
    route = try RH.register_route_lifecycle!(app2, Any[lm]); "registered" catch e; e isa ArgumentError ? "refused" : "other" end
    println("ROUTE=", route, " ", isempty(RH.lifecycle_snapshot(app2)[1]))
    # End to end: `serve` registers the tuple and starts it, `terminate` stops it, both by `ccall`.
    up[] = 0; down[] = 0
    app3 = App()
    Nitro.serve(app3; middleware = (lm,), host = "127.0.0.1", port = $(get_free_port()), async = true,
                show_banner = false, access_log = false)
    Nitro.Core.terminate(app3)
    println("SERVE=", up[], " ", down[])
    # Revise is refused, before anything starts: a trimmed image cannot make its `invokelatest`.
    rev = try
        Nitro.serve(App(); revise = :lazy, host = "127.0.0.1", port = $(get_free_port()), async = true,
                    show_banner = false, access_log = false)
        "served"
    catch e
        e isa ArgumentError && occursin("trimmed build", e.msg) ? "refused" : string(typeof(e))
    end
    println("REVISE=", rev)
    """
    cmd = `$(Base.julia_cmd()) --code-coverage=none --project=$(Base.active_project()) --startup-file=no -e $script`
    out, err = IOBuffer(), IOBuffer()
    p = run(pipeline(ignorestatus(cmd); stdout = out, stderr = err))
    out, err = String(take!(out)), String(take!(err))
    @test (p.exitcode, p.termsignal) == (0, 0) || (out, last(err, 2000))
    for line in ("PTRS=true", "UP=true 1", "BOOM=true", "INTERRUPT=true", "DOWN=true 1",
                 "VECTOR=refused", "ROUTE=refused true", "SERVE=1 1", "REVISE=refused")
        @test occursin(line, out) || (line, out)
    end
end
end
