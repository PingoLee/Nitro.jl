# What registering a route costs, against the route count and the handler's type (#726).
#
#   julia --project=bench bench/regcost.jl <N> [distinct|onetype]
#
# `distinct` (the default) registers N handler FUNCTIONS, each a type of its own, as an
# application's handlers are; `onetype` registers N closures of ONE type, so whatever Nitro
# compiles per handler type is paid once. Both give three routes in four route middleware and leave
# the fourth bare, as #726's reproduction did. Its `tag(n)` ignores `n`, so the three stacks share
# one layer type and make two chain shapes (one layer, two layers); kept as is, so the numbers on
# #726 stay comparable. Prints one line:
#
#   regcost: mode=… n=… register_s=… first_s=… warm_ms=… compile_s=…
#
# `compile_s` is the compilation time inside the registration window (`Base.cumulative_compile_time_ns`),
# so `register_s - compile_s` is what registration costs once everything it calls is compiled.
# In process, no socket; the first and warm passes go through `setupmiddleware(app)`.
using Nitro
const HTTP = Nitro.Core.HTTP

const N = parse(Int, ARGS[1])
const MODE = length(ARGS) >= 2 ? ARGS[2] : "distinct"
MODE in ("distinct", "onetype") || error("regcost.jl: mode must be distinct or onetype, got $MODE")

if MODE == "distinct"
    for i in 1:N
        @eval $(Symbol(:h, i))(req::HTTP.Request) = Res.send($(string(i)))
    end
    handler(i) = getfield(Main, Symbol(:h, i))
else
    make_handler(s::String) = (req::HTTP.Request) -> Res.send(s)
    handler(i) = make_handler(string(i))
end

tag(n) = handler -> (req::HTTP.Request -> handler(req))
const A, B, C = tag("a"), tag("b"), tag("c")
const app = App()
const stacks = ([A], [A, B], [C, A])

Base.cumulative_compile_timing(true)
c0 = Base.cumulative_compile_time_ns()[1]
t_reg = @elapsed begin
    defs = [path("/r$i", handler(i); method = "GET",
                 middleware = i % 4 == 0 ? nothing : stacks[i % 3 + 1]) for i in 1:N]
    urlpatterns(app, "", defs)
end
c1 = Base.cumulative_compile_time_ns()[1]
Base.cumulative_compile_timing(false)

const p = Nitro.Core.setupmiddleware(app)
t_first = @elapsed for i in 1:N
    p(HTTP.Request("GET", "/r$i"))
end
t_warm = @elapsed for i in 1:N
    p(HTTP.Request("GET", "/r$i"))
end
println("regcost: mode=$MODE n=$N register_s=$(round(t_reg; digits = 3)) " *
        "first_s=$(round(t_first; digits = 3)) warm_ms=$(round(t_warm * 1e3; digits = 2)) " *
        "compile_s=$(round((c1 - c0) / 1e9; digits = 3))")
