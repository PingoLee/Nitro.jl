# #745 step 1: what a trimmed image does at a dynamic call, with and without the callee rooted by
# `Base.Experimental.entrypoint`. Nothing of Nitro's: one deliberate dynamic call, `g` on the
# contents of a `Ref{Any}`, with a method for `Int` and one for `String`.
#
#   ROOTS=none OUT=/tmp/rp-none ENTRY=rootprobe bench/juliac/build.sh unsafe-warn
#   ROOTS=int  OUT=/tmp/rp-int  ENTRY=rootprobe bench/juliac/build.sh unsafe-warn
#   ROOTS=both OUT=/tmp/rp-both ENTRY=rootprobe bench/juliac/build.sh unsafe-warn
#   /tmp/rp-none/nitro-rootprobe-unsafe-warn int      # then `string`: one call per process
#
# ROOTS is read while the image is built. The argument picks the value `g` is called on, one per
# process, so a call that kills the process cannot hide what the other one does. Each call sits in
# a `try`; the output says whether the call ran, whether `catch` saw something and what, and a
# last line says the process got past it. Everything prints to `Core.stdout` with no dynamic call
# of its own (a trimmed image's `Base.stdout` is stale), so the probe's only dynamic call is `g`'s.

const ROOTS = get(ENV, "ROOTS", "none")
ROOTS in ("none", "int", "both") || error("ROOTS must be none, int or both, got $ROOTS")

@noinline g(x::Int) = x + 1
@noinline g(x::String) = ncodeunits(x)
# More methods than inference splits a call over (`max_methods`, 3): with only the two above, it
# turned `g(BOX[])` into `isa` branches to both, and the call was not dynamic at all.
@noinline g(x::Float64) = 1
@noinline g(x::Symbol) = 2
@noinline g(x::Char) = 3
@noinline g(x::Nothing) = 4

ROOTS in ("int", "both") && Base.Experimental.entrypoint(g, (Int,))
ROOTS == "both" && Base.Experimental.entrypoint(g, (String,))

const BOX = Ref{Any}(0)

@noinline call_g() = g(BOX[])

function (@main)(args::Vector{String})::Cint
    which = isempty(args) ? "int" : args[1]
    if which == "int"
        BOX[] = 41
    elseif which == "string"
        BOX[] = "four"
    else
        println(Core.stdout, "usage: rootprobe int|string")
        return Cint(2)
    end
    println(Core.stdout, "rootprobe: roots=", ROOTS, " calling g(", which, ")")
    try
        r = call_g()
        if r isa Int
            println(Core.stdout, "ran: g returned ", r)
        else
            println(Core.stdout, "ran: g returned a non-Int")
        end
    catch e
        println(Core.stdout, "caught: ", String(nameof(typeof(e))))
        if e isa ErrorException
            msg = e.msg
            println(Core.stdout, "message: ", msg isa String ? msg : "(not a String)")
        elseif e isa MethodError
            println(Core.stdout, "message: MethodError for a function of type ", String(nameof(typeof(e.f))))
        end
    end
    println(Core.stdout, "survived")
    return Cint(0)
end
