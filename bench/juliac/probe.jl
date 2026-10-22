# The request-path probe `juliac` is pointed at with `ENTRY=probe` (#718). `app.jl` reaches the
# request path only through `serve` → `HTTP.listen!`, and the verifier stops at the first dynamic
# call on each path, so a wall in front of the listener hides everything behind it. This file
# calls the pipeline itself: `@main` builds it with `setupmiddleware` and hands it requests, so the
# verifier walks `compose`, the per-route chains and the router terminal whatever the listener does.
#
# Routes are registered at TOP LEVEL, as in `app.jl`: under `juliac` that runs at build time and
# the route table is a value in the image. They cover the shapes a route table mixes: an exact
# route, a converter route, and three distinct middleware stacks, two of them through an
# `include_routes` group. Run as a script it is the JIT check that the same requests serve.
using Nitro
const HTTP = Nitro.Core.HTTP     # not a dependency of bench/juliac in its own right

const PLAINTEXT = "Hello, World!"
const app = App()

# A user middleware in its documented shape, `handler -> (req -> response)`. Each `tag` is a
# closure of its own type, as an application's middleware would be.
tag(name::String) = handler -> function (req::HTTP.Request)
    res = handler(req)
    return res
end
const MW_A, MW_B, MW_C = tag("a"), tag("b"), tag("c")

urlpatterns(app, "",
    path("/plaintext", req -> Res.send(PLAINTEXT); method = "GET"),
    path("/users/<int:id>", (req, id::Int) -> Res.send(string(id)); method = "GET"),
    path("/mw", req -> Res.send("mw"); method = "GET", middleware = [MW_C, MW_A]),
)
urlpatterns(app, "", include_routes("/api", [
    path("/items", req -> Res.send("items"); method = "GET"),
    path("/admin", req -> Res.send("admin"); method = "GET", middleware = [MW_B]),
]; middleware = [MW_A]))

const TARGETS = ("/plaintext", "/users/7", "/mw", "/api/items", "/api/admin", "/missing")

function (@main)(args::Vector{String})::Cint
    pipeline = Nitro.Core.setupmiddleware(app)
    for target in TARGETS
        res = pipeline(HTTP.Request("GET", target))
        println(Core.stdout, target, " ", res.status)
    end
    return Cint(0)
end
