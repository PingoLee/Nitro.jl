# The Ctrl-C child harness itself (#473). The #369 and #372 items trust `ctrl_c_child` to tell a
# child that took the press from one that never could, and to say where a wedged child is
# parked. Both of those failure shapes are rare on CI and never happen on a healthy child, so
# they are forced here with pure-Base children, which also keeps this item fast.
#
# Not on Windows, for the reason the #369 item gives: there is no SIGINT to send.
@testitem "Ctrl-C child harness: proves an ignored SIGINT, dumps a wedged child (#473)" tags=[:core, :slow] setup=[CtrlCChild] begin
using Test

# The only task is main, so the press can only land there.
const TAKES_THE_PRESS = SIGINT_PROBE * raw"""
Base.exit_on_sigint(false)
const TERMINAL_STANDIN = Timer(3600)   # an active libuv handle, as in the #372 children
println("READY"); flush(stdout)
got = try
    wait(Base.Event())
    :never
catch e
    e isa InterruptException ? :interrupted : rethrow()
end
println("RESULT ", got)
"""

# What the #473 Julia bug leaves behind, made deterministic: SIGINT ignored for good.
const SIGINT_IGNORED = raw"""
ccall(:signal, Ptr{Cvoid}, (Cint, Ptr{Cvoid}), Base.SIGINT, Ptr{Cvoid}(1))
""" * SIGINT_PROBE * raw"""
println("READY"); flush(stdout)
wait(Base.Event())
"""

# Takes every press and parks again: the "permanent sink" a swallowing loop becomes. It never
# exits on its own, so only the watchdog ends it.
const SWALLOWS_THE_PRESS = SIGINT_PROBE * raw"""
Base.exit_on_sigint(false)
const TERMINAL_STANDIN = Timer(3600)
println("READY"); flush(stdout)
while true
    try
        wait(Base.Event())
    catch e
        e isa InterruptException || rethrow()
    end
end
"""

if !Sys.iswindows()
    @testset "a child that takes the press exits cleanly, first time" begin
        r = ctrl_c_child(TAKES_THE_PRESS, "1,0"; cue="READY", settle=0.5, deadline=60)
        report(r)
        @test r.pressed
        @test r.attempts == 1
        @test !r.sigint_ignored
        @test r.sigint_disposition ∉ (nothing, 0, 1)   # Julia's own handler, not SIG_DFL/SIG_IGN
        @test !r.timed_out
        @test r.exitcode == 0
        @test r.termsignal == 0
        @test contains(r.out, "RESULT interrupted")
    end

    @testset "an ignored SIGINT is proven, never pressed, and replaced" begin
        r = ctrl_c_child(SIGINT_IGNORED, "1,0"; cue="READY", deadline=60, attempts=3)
        @test r.sigint_ignored
        @test r.sigint_disposition == 1
        @test r.attempts == 3
        @test !r.pressed
        @test !r.timed_out            # killed on the proof, not at the deadline
        @test r.termsignal == Base.SIGKILL
    end

    @testset "a wedged child is dumped with SIGQUIT before it is killed" begin
        r = ctrl_c_child(SWALLOWS_THE_PRESS, "1,0"; cue="READY", settle=0.5, deadline=15)
        @test r.pressed
        @test r.timed_out
        @test r.termsignal == Base.SIGQUIT
        # `jl_critical_error`'s banner, then `jl_print_task_backtraces`' per-thread header.
        @test occursin("signal 3", r.err)
        @test occursin("==== Thread", r.err)
    end

    @testset "a child must report its SIGINT disposition before its cue" begin
        @test_throws "printed its cue before its SIGINT disposition" ctrl_c_child(raw"""
            println("READY"); flush(stdout)
            wait(Base.Event())
            """, "1,0"; cue="READY", deadline=60)
    end
end

end
