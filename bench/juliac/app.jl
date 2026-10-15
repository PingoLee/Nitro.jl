# The smallest Nitro app `juliac` can be pointed at (#570): one exact route, no middleware, no
# access log, no banner.
#
# Routes are registered at TOP LEVEL on purpose. Under `juliac` this file is `include`d into the
# build process, so registration -- and the reflection `parse_func_params` needs -- runs at build
# time, and the router is a value in the image; `main` only serves. That is the placement #570
# proposes for every compiled app, and this file is the first test of it. Run as a script
# (`julia --project=bench/juliac bench/juliac/app.jl`) the same file is the JIT baseline: `@main`
# runs when the file is the program.
using Nitro

const PLAINTEXT = "Hello, World!"
const app = App()

urlpatterns(app, "", path("/plaintext", req -> Res.send(PLAINTEXT); method = "GET"))

function (@main)(args::Vector{String})::Cint
    port = parse(Int, get(ENV, "PORT", "8080"))
    serve(app; host = "127.0.0.1", port, async = false, show_banner = false, access_log = false)
    return Cint(0)
end
