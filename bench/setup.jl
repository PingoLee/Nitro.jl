# Bench route table on an isolated ServerContext (no global CONTEXT[] mutation).
# All requests go through Nitro.Core.internalrequest — the full middleware +
# serializer + router pipeline, minus the socket/task layer (see taskpattern.jl
# for a synthetic measurement of that layer).

using Nitro
using HTTP

const BENCH_CTX = Nitro.Core.ServerContext()

Nitro.Core.Routing.urlpatterns(BENCH_CTX, "", Nitro.RouteDefinition[
    Nitro.path("/bench/ping", (req) -> "pong", method="GET"),
    Nitro.path("/bench/items/<int:id>", (req, id::Int) -> Res.json(Dict("id" => id)), method="GET"),
    Nitro.path("/bench/q", function (req)
        q1 = req.query   # first touch
        q2 = req.query   # second touch — measures repeated queryvars cost
        return Res.json(Dict("n" => length(q2), "a" => get(q1, "a", "")))
    end, method="GET"),
    Nitro.path("/bench/json", (req) -> Res.json(req.json), method="POST"),
])

bench_request(method::String, target::String; body::String="") =
    isempty(body) ? HTTP.Request(method, target) :
        HTTP.Request(method, target, ["Content-Type" => "application/json"], body)

run_bench_request(req::HTTP.Request) = Nitro.Core.internalrequest(BENCH_CTX, req)
