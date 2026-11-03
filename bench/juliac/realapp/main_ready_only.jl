# The #744 realapp's entry with `serve(middleware = (ready,))`: the Workers layer is built but not
# served, which makes the `serve` call static from `main` (see `RealApp.main`). A diagnostic, not
# a deploy shape. Build it with `ENTRY=main_ready_only bench/juliac/realapp/build.sh no`.
using RealApp

function (@main)(args::Vector{String})::Cint
    RealApp.main(; host = "127.0.0.1", async = false, middleware_form = Val(:ready_only))
    return Cint(0)
end
