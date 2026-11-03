# The #744 realapp's entry with `serve(middleware = (workers, ready))`, a `Tuple`, in place of
# main.jl's `[workers, ready]`. Everything else is main.jl's: build it with
# `ENTRY=main_tuple bench/juliac/realapp/build.sh no`, or run it under the JIT with
# `JIT_ENTRY=main_tuple bench/juliac/realapp/measure.sh … jit`.
using RealApp

function (@main)(args::Vector{String})::Cint
    RealApp.main(; host = "127.0.0.1", async = false, middleware_form = Val(:tuple))
    return Cint(0)
end
