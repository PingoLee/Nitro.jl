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
using Base.ScopedValues: @with
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
#
# The reference binds the seed layer's OWN key. An insert costs more when its key shares a HAMT slot
# with a key already bound around it, and a `ScopedValue` hashes by address, which differs per
# process. On 1.13, where Test binds its testset stack in ScopedValues, a reference under a key of
# its own read 6 while `REQUEST_SCOPE` collided and read 9 or 13 (#633); the same key gives both
# sides the same placement.
const REF_VALUE = RequestScope(nothing, Ref{Int64}(0))
reference(req::HTTP.Request) = @with REQUEST_SCOPE => REF_VALUE nothing

# One fresh request per call. The app context is pre-seeded so the layer's one-off `req.context`
# insert is not measured. The minimum of 5 runs of 1000 calls (`allocs`, #511).
function allocs_per_request(f; calls = 1000, runs = 5)
    reqs = [HTTP.Request("GET", "/") for _ in 1:(2 * runs * calls + 1)]   # as many as `allocs` calls
    foreach(r -> r.context[Nitro.Core.REQUEST_CONTEXT_KEY] = nothing, reqs)
    next = Ref(0)
    return allocs(() -> f(reqs[next[] += 1]); calls, runs)
end

@testset "one scope insert per request, nothing boxed" begin
    seed_layer = _app_context_seed(app)((req::HTTP.Request) -> nothing)
    @testset let seed = allocs_per_request(seed_layer), ref = allocs_per_request(reference)
        @test seed.count <= ref.count + 0.5
    end
end
end

@testitem "The app-context seed reads the context cell without a dynamic call" tags=[:core] setup=[NitroCommon] begin
    using Test
    using Nitro
    # `App.app_context` was declared `Ref{Any}`, which is abstract, so `ctx.app_context[]` was a
    # dynamic `getindex` on every request at both of its reads, `_app_context_seed` and
    # `internalrequest` (docs/design/juliac-trim.md §3.5). The field is now concrete.
    @test fieldtype(App, :app_context) === Base.RefValue{Any}
    @test isempty(dynamic_calls(app -> app.app_context[], (App,)))
    app = App()
    @test app.app_context[] === missing
end
