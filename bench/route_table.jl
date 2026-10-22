# A route table of a chosen size and shape, shared by bench/socket/server.jl (the JIT server) and
# bench/juliac/app.jl (the compiled one), so both measure the same app (#718). Include it after
# `using Nitro`, then call `bench_routes!(app)`.
#
#   FILLER_ROUTES=N   N more routes, each with its own handler FUNCTION (a type of its own, as an
#                     application's handlers are), spread over three `include_routes` groups whose
#                     middleware stacks differ; a third of them add route middleware of their own.
#                     So a table carries at least three distinct chain types whatever N is.
#   ROUTE_MW=1        `/mw`: one route behind group AND route middleware, for the per-request cost
#                     of a chained route (bench/socket/run.sh ROUTES="/mw").
#
# Both default off, and then this adds nothing. Read at top level: under `juliac` that is build
# time, so the table is a value in the image.

const FILLER_ROUTES = parse(Int, get(ENV, "FILLER_ROUTES", "0"))
const ROUTE_MW = get(ENV, "ROUTE_MW", "0") == "1"

# Three pass-through layers, each its own function, so each makes a closure of its own type.
layer_a(handler) = req -> handler(req)
layer_b(handler) = req -> handler(req)
layer_c(handler) = req -> handler(req)

for i in 1:FILLER_ROUTES
    @eval $(Symbol(:filler_route_, i))(req) = Res.send($(string("filler ", i)))
end

function bench_routes!(app)
    if ROUTE_MW
        urlpatterns(app, "", include_routes("", [
            path("/mw", req -> Res.send("Hello, World!"); method = "GET", middleware = [layer_c]),
        ]; middleware = [layer_a, layer_b]))
    end
    stacks = ([layer_a], [layer_a, layer_b], [layer_c, layer_a])
    for g in 1:3
        ids = g:3:FILLER_ROUTES
        isempty(ids) && continue
        defs = [path("/fill/$i", getfield(@__MODULE__, Symbol(:filler_route_, i)); method = "GET",
                     middleware = i % 3 == 0 ? [layer_b] : nothing)
                for i in ids]
        urlpatterns(app, "", include_routes("/g$g", defs; middleware = stacks[g]))
    end
    return app
end
