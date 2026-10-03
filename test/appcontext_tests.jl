@testitem "App context" tags=[:core, :network] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro

port = get_free_port()
localhost = "http://$HOST:$port"

struct Person
    name::String
    age::Int
end

urlpatterns("",
    path("/test", function(req) return "Hello World" end, method="GET"),
    path("/injected", function(req, ctx::Context{Person}) return Res.json(ctx.payload) end, method="GET"),
    path("/getcontext", function(req) return Res.json(getcontext(req)) end, method="GET"),
    path("/getcontext-typed", function(req) return Res.json(getcontext(req, Person)) end, method="GET"),
    path("/kwarg-only", function(req; context) return Res.json(context) end, method="GET"),
    path("/both-kwargs", function(; request::Request, context::Person) return Res.json(context) end, method="GET"),
    # No positional argument at all, reaching the app context through the `context` kwarg.
    # This is `no_args && has_ctx_kwarg && !has_req_kwarg` in `select_handler` — a distinct
    # dispatch branch from `/kwarg-only` (which takes `req`) and `/both-kwargs`. It used to
    # call the global `context()`, removed in #31.
    path("/method-only", function(; context) return Res.json(context) end, method="GET"),
)

serve(port=port, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

@testset "null context tests" begin 
    try
        response = HTTP.get("$localhost/injected")
    catch e
        @test e isa HTTP.Exception
        @test e.status == 500
    end

    # The `context` kwarg resolves to `getcontext(req)`, which is `nothing` when no context
    # was configured — so these two do NOT fail, they serve `null`. Asserted directly rather
    # than left in a `try`/`catch` that runs no assertion on the non-throwing path (#31).
    response = HTTP.get("$localhost/method-only")
    @test response.status == 200
    @test text(response) == "null"

    response = HTTP.get("$localhost/kwarg-only")
    @test response.status == 200
    @test text(response) == "null"
end

@testset "getcontext null context" begin
    # No context configured: getcontext(req) is nothing ...
    response = HTTP.get("$localhost/getcontext")
    @test response.status == 200
    @test text(response) == "null"

    # ... and the typed accessor raises (→ 500)
    try
        HTTP.get("$localhost/getcontext-typed")
        @test false
    catch e
        @test e isa HTTP.Exception
        @test e.status == 500
    end
end

terminate()

person = Person("John", 25)

serve(port=port, host=HOST, async=true, show_errors=true, show_banner=false, access_log=nothing, context=person)

@testset "standard get requests" begin 
    response = HTTP.get("$localhost/test")
    @test response.status == 200
    @test text(response) == "Hello World"
end

@testset "accessing injected context from a function handler" begin
    response = HTTP.get("$localhost/injected")
    @test response.status == 200
    @test json(response, Person) == person
end

@testset "getcontext(req) reaches the typed config without a Context param" begin
    response = HTTP.get("$localhost/getcontext")
    @test response.status == 200
    @test json(response, Person) == person

    response = HTTP.get("$localhost/getcontext-typed")
    @test response.status == 200
    @test json(response, Person) == person
end

@testset "accessing injected context from kwargs" begin 
    response = HTTP.get("$localhost/kwarg-only")
    @test response.status == 200
    @test json(response, Person) == person
end

@testset "accessing injected context from kwargs (both request and context)" begin 
    response = HTTP.get("$localhost/both-kwargs")
    @test response.status == 200
    @test json(response, Person) == person
end

@testset "context kwarg on a no-argument handler" begin
    response = HTTP.get("$localhost/method-only")
    @test response.status == 200
    @test json(response, Person) == person
end

terminate()

# The app context is seeded before the middleware pipeline, so getcontext(req)
# is available inside global/custom middleware — not only at handler dispatch.
function _ctx_probe(handler)
    return function(req::HTTP.Request)
        resp = handler(req)
        cfg = getcontext(req)
        HTTP.setheader(resp, "X-Ctx-Name" => cfg === nothing ? "none" : cfg.name)
        return resp
    end
end

serve(port=port, host=HOST, async=true, show_errors=false, show_banner=false,
      access_log=nothing, context=person, middleware=[_ctx_probe])

@testset "getcontext available inside middleware" begin
    response = HTTP.get("$localhost/test")
    @test response.status == 200
    @test HTTP.header(response, "X-Ctx-Name") == "John"
end

terminate()

end
@testitem "request scope binds the serving app and its field cap, once (#444)" tags=[:core] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Base.ScopedValues: ScopedValue, @with
using Nitro.Core: serving_app, _app_context_seed
using Nitro.Core.Constants: REQUEST_SCOPE, RequestScope, request_max_fields, DEFAULT_MAX_FIELDS

app = App(mod = @__MODULE__)
app.service.max_fields[] = 7
seen = Ref{Any}(nothing)
urlpatterns(app, "",
    path("/scope", function(req)
        # A spawned task inherits the scope, which is what makes it `Threads.@spawn`-safe.
        seen[] = fetch(Threads.@spawn (serving_app(), request_max_fields()))
        return "ok"
    end, method = "GET"),
)

@testset "inside a request: the serving app and ITS cap" begin
    @test internalrequest(app, HTTP.Request("GET", "/scope")).status == 200
    @test seen[][1] === app
    @test seen[][2] == 7
end

@testset "outside a request: no app, the default cap" begin
    @test serving_app() === nothing
    @test request_max_fields() == DEFAULT_MAX_FIELDS
end

@testset "a cap set after the pipeline is built is still seen" begin
    # `serve` writes `max_fields` once at startup; the scope shares the app's cell, not a copy.
    pipeline = _app_context_seed(app)((req::HTTP.Request) -> request_max_fields())
    app.service.max_fields[] = 11
    @test pipeline(HTTP.Request("GET", "/")) == 11
end

# The seed layer binds ONE prebuilt heap object per request (#444). Measured against the cheapest
# possible binding -- one `@with` of a prebuilt `RequestScope` -- rather than a constant, so the
# bound tracks the Julia version's `PersistentDict` cost. A second `ScopedValue`, or a value that is
# boxed on insert, makes the seed layer strictly more expensive than the reference.
const REF_SCOPE = ScopedValue{RequestScope}(RequestScope(nothing, Ref{Int64}(0)))
const REF_VALUE = RequestScope(nothing, Ref{Int64}(0))
reference(req::HTTP.Request) = @with REF_SCOPE => REF_VALUE nothing

function allocs_per_call(f, n)
    # The app context is pre-seeded so the layer's one-off `req.context` insert is not measured.
    reqs = [HTTP.Request("GET", "/") for _ in 1:n]
    foreach(r -> r.context[Nitro.Core.REQUEST_CONTEXT_KEY] = nothing, reqs)
    f(reqs[1])
    return @allocations(foreach(f, reqs)) / n
end

@testset "one scope insert per request, nothing boxed" begin
    seed = _app_context_seed(app)((req::HTTP.Request) -> nothing)
    allocs_per_call(reference, 10); allocs_per_call(seed, 10)
    @test allocs_per_call(seed, 1000) <= allocs_per_call(reference, 1000) + 0.5
end
end
