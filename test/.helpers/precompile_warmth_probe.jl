# Probe for `test/precompile_warmth_tests.jl` (#242).
#
# Measures the cost of the FIRST request of one handler shape, then prints it. One shape per
# process, on purpose: the whole quantity under test is time-to-first-request, and any shape
# measured second in a process is reading a path the first one already warmed.
#
# Lives under `test/.helpers/` so ReTestItems' discovery walk prunes it (dot-directory) —
# it is named `*_probe.jl` rather than `*_tests.jl` for the same reason, belt and braces.
#
# Usage: julia --project=<env> precompile_warmth_probe.jl <shape>   # prints e.g. "0.183"

using Nitro, HTTP
using Nitro: Res, RouteDefinition, path, Query, Json

# Deliberately NOT `Nitro.PrecompileRecord`: this stands in for an application's own type, so
# it must be one the workload has never seen. Only the generic binding machinery is shared,
# and that sharing is exactly what the test asserts.
Base.@kwdef struct ProbeRecord
    id::Int = 0
    name::String = ""
end

const SHAPE = ARGS[1]

app = App()
reg(p, h; kw...) = Nitro.Core.Routing.urlpatterns(app, "", RouteDefinition[path(p, h; kw...)])
hit(m, p, hs = Pair{String,String}[], b = ""; kw...) =
    Nitro.Core.internalrequest(app, HTTP.Request(m, p, hs, b); kw...)

# Each branch yields (request thunk, expected body fragment).
#
# The body fragment is not decoration. `formdata` and `multipart` both CATCH a parse failure
# and return an empty result (`src/utilities/bodyparsers.jl`), so a total parse regression
# still answers 200 — and answers it FASTER, which would make the ratio this test computes
# look better at the moment the parser broke. Asserting the parsed value closes that.
go, expected = if SHAPE == "dict_int"
    # The BASELINE. Covered by the workload both before and after #242, so it measures this
    # machine's fixed cost for "a warm first request" — the denominator every ratio uses.
    reg("/x/<int:id>", (r::HTTP.Request, id::Int) -> Res.json(Dict("id" => id)))
    (() -> hit("GET", "/x/1"; catch_errors = false)), "\"id\":1"
elseif SHAPE == "dict_any"
    reg("/x/<int:id>", (r::HTTP.Request, id::Int) ->
        Res.json(Dict{String,Any}("id" => id, "name" => "x", "ok" => true)))
    (() -> hit("GET", "/x/1"; catch_errors = false)), "\"name\":\"x\""
elseif SHAPE == "query_ext"
    reg("/x", (r::HTTP.Request, q::Query{ProbeRecord}) -> Res.json(q.payload))
    (() -> hit("GET", "/x?id=1&name=a"; catch_errors = false)), "\"name\":\"a\""
elseif SHAPE == "json_ext"
    reg("/x", (r::HTTP.Request, j::Json{ProbeRecord}) -> Res.json(j.payload), method = "POST")
    (() -> hit("POST", "/x", ["Content-Type" => "application/json"],
               "{\"id\":1,\"name\":\"a\"}"; catch_errors = false)), "\"name\":\"a\""
elseif SHAPE == "formdata"
    reg("/x", (r::HTTP.Request) -> Res.json(Dict{String,Any}("n" => length(Nitro.formdata(r)))),
        method = "POST")
    (() -> hit("POST", "/x", ["Content-Type" => "application/x-www-form-urlencoded"],
               "a=1&b=2"; catch_errors = false)), "\"n\":2"
elseif SHAPE == "multipart"
    reg("/x", (r::HTTP.Request) -> Res.json(Dict{String,Any}("n" => length(Nitro.multipart(r)))),
        method = "POST")
    bnd = "probeboundary"
    body = string("--", bnd, "\r\n",
                  "Content-Disposition: form-data; name=\"f\"\r\n\r\nv\r\n",
                  "--", bnd, "--\r\n")
    (() -> hit("POST", "/x", ["Content-Type" => "multipart/form-data; boundary=$bnd"],
               body; catch_errors = false)), "\"n\":1"
# The #551 shapes. POST bodies are `Vector{UInt8}`, as a socket delivers them.
elseif SHAPE == "cookie_ext"
    reg("/x", (r::HTTP.Request, sid::Nitro.Cookie{String}) -> Res.send(sid.value))
    (() -> hit("GET", "/x", ["Cookie" => "sid=abc"]; catch_errors = false)), "abc"
elseif SHAPE == "files_ext"
    reg("/x", (r::HTTP.Request, doc::Nitro.Files{Nitro.FormFile}) -> Res.send(doc.payload.filename),
        method = "POST")
    bnd = "probeboundary"
    body = string("--", bnd, "\r\n",
                  "Content-Disposition: form-data; name=\"doc\"; filename=\"r.txt\"\r\n",
                  "Content-Type: text/plain\r\n\r\nv\r\n", "--", bnd, "--\r\n")
    (() -> hit("POST", "/x", ["Content-Type" => "multipart/form-data; boundary=$bnd"],
               Vector{UInt8}(body); catch_errors = false)), "r.txt"
elseif SHAPE == "payload"
    reg("/x", (r::HTTP.Request) -> Res.send(string(length(Nitro.payload(r)))), method = "POST")
    (() -> hit("POST", "/x", ["Content-Type" => "application/x-www-form-urlencoded"],
               Vector{UInt8}("a=1&b=2"); catch_errors = false)), "2"
elseif SHAPE == "url"
    reg("/item/<int:id>", (r::HTTP.Request, id::Int) -> Res.status(204); name = "item")
    reg("/x", (r::HTTP.Request) -> Res.send(Nitro.url(app, "item"; id = 3)))
    (() -> hit("GET", "/x"; catch_errors = false)), "/item/3"
else
    error("unknown shape: $SHAPE")
end

elapsed = @elapsed resp = go()
resp.status == 200 || error("shape $SHAPE returned $(resp.status), expected 200")
body = Nitro.text(resp)
occursin(expected, body) || error("shape $SHAPE body $(repr(body)) lacks $(repr(expected))")
println(elapsed)
