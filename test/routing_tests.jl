@testitem "Django-style routing" tags=[:core, :network] setup=[NitroCommon] begin

using Test
using HTTP
using Nitro
using UUIDs
using Nitro: path, urlpatterns, include_routes, convert_django_path, RouteDefinition, GET, POST, PUT, DELETE, url

port = get_free_port()

# ─── Test: convert_django_path ────────────────────────────────────────

@testset "convert_django_path" begin
    # Basic integer converter
    nitro_path, hints = convert_django_path("/users/<int:id>")
    @test nitro_path == "/users/{id}"
    @test hints[:id] == Int

    # Multiple converters
    nitro_path, hints = convert_django_path("/posts/<str:slug>/comments/<int:comment_id>")
    @test nitro_path == "/posts/{slug}/comments/{comment_id}"
    @test hints[:slug] == String
    @test hints[:comment_id] == Int

    # Float converter
    nitro_path, hints = convert_django_path("/price/<float:amount>")
    @test nitro_path == "/price/{amount}"
    @test hints[:amount] == Float64

    # Bool converter
    nitro_path, hints = convert_django_path("/toggle/<bool:enabled>")
    @test nitro_path == "/toggle/{enabled}"
    @test hints[:enabled] == Bool

    # UUID converter
    nitro_path, hints = convert_django_path("/keys/<uuid:key>")
    @test nitro_path == "/keys/{key}"
    @test hints[:key] == UUID

    # No converters (plain path)
    nitro_path, hints = convert_django_path("/static/page")
    @test nitro_path == "/static/page"
    @test isempty(hints)

    # Invalid converter
    @test_throws ArgumentError convert_django_path("/bad/<unknown:x>")
end

# ─── Test: path() ─────────────────────────────────────────────────────

@testset "path() route definition" begin
    handler = (req) -> "hello"
    
    # Default method is GET
    rd = path("/test", handler)
    @test rd isa RouteDefinition
    @test rd.pattern == "/test"
    @test rd.methods == ["GET"]
    @test isnothing(rd.name)
    @test isnothing(rd.middleware)
    @test isempty(rd.type_hints)

    # Custom method
    rd = path("/test", handler, method="POST")
    @test rd.methods == ["POST"]

    # Multiple methods
    rd = path("/test", handler, methods=["GET", "POST"])
    @test rd.methods == ["GET", "POST"]

    # With converters
    rd = path("/users/<int:id>", handler)
    @test rd.pattern == "/users/{id}"
    @test rd.type_hints[:id] == Int

    rd = path("/keys/<uuid:key>", handler)
    @test rd.pattern == "/keys/{key}"
    @test rd.type_hints[:key] == UUID

    # With name
    rd = path("/users/<int:id>", handler, name="user-detail")
    @test rd.name == "user-detail"

    # With middleware
    mw = [(handler) -> (req) -> handler(req)]
    rd = path("/test", handler, middleware=mw)
    @test rd.middleware == mw
end

# ─── Test: include_routes() ───────────────────────────────────────────

@testset "include_routes" begin
    handler = (req) -> "hello"
    
    routes = [
        path("/users", handler, method="GET"),
        path("/users/<int:id>", handler, method="GET"),
    ]

    included = include_routes("/api/v1", routes)
    
    @test length(included) == 2
    @test included[1].pattern == "/api/v1/users"
    @test included[2].pattern == "/api/v1/users/{id}"
    @test included[2].type_hints[:id] == Int

    # Variadic form
    included2 = include_routes("/v2",
        path("/items", handler, method="GET"),
        path("/items/<int:id>", handler, method="GET"),
    )
    @test length(included2) == 2
    @test included2[1].pattern == "/v2/items"
end

# ─── Test: urlpatterns() with server ──────────────────────────────────

@testset "urlpatterns integration" begin
    # Register handlers using urlpatterns
    list_handler = (req) -> "list"
    detail_handler = (req, id) -> "detail: $id"
    inferred_handler = function(req::HTTP.Request, id)
        return Res.send(string(typeof(id)))
    end
    bool_handler = function(req::HTTP.Request, enabled)
        return Res.send("$(typeof(enabled)):$(enabled)")
    end
    uuid_handler = function(req::HTTP.Request, key)
        return Res.send("$(typeof(key)):$(key)")
    end
    create_handler = (req) -> "created"
    key_id = UUID("550e8400-e29b-41d4-a716-446655440000")
    
    urlpatterns("/api",
        path("/items", list_handler, method="GET"),
        path("/items/<int:id>", detail_handler, method="GET"),
        path("/typed/<int:id>", inferred_handler, method="GET"),
        path("/toggle/<bool:enabled>", bool_handler, method="GET"),
        path("/keys/<uuid:key>", uuid_handler, method="GET"),
        path("/items", create_handler, method="POST"),
    )

    # Test via internalrequest
    serve(port=port, async=true, show_banner=false)
    sleep(1)

    try
        # GET /api/items
        r = internalrequest(HTTP.Request("GET", "/api/items"))
        @test r.status == 200
        body = Nitro.text(r)
        @test body == "list" || body == "\"list\""

        # GET /api/items/42
        r = internalrequest(HTTP.Request("GET", "/api/items/42"))
        @test r.status == 200

        # GET /api/typed/42
        r = internalrequest(HTTP.Request("GET", "/api/typed/42"))
        @test r.status == 200
        @test Nitro.text(r) == string(Int)

        # GET /api/typed/not-an-int -- a converter mismatch is client input, so 400.
        # The converter is a *binding* declaration, not a routing filter: the route still
        # matches (HTTP.jl treats {id} as a bare wildcard) and then fails to bind.
        r = internalrequest(HTTP.Request("GET", "/api/typed/not-an-int"))
        @test r.status == 400

        # GET /api/toggle/true
        r = internalrequest(HTTP.Request("GET", "/api/toggle/true"))
        @test r.status == 200
        @test Nitro.text(r) == "Bool:true"

        # GET /api/toggle/not-a-bool
        r = internalrequest(HTTP.Request("GET", "/api/toggle/not-a-bool"))
        @test r.status == 400

        # GET /api/keys/<uuid>
        r = internalrequest(HTTP.Request("GET", "/api/keys/$key_id"))
        @test r.status == 200
        @test Nitro.text(r) == "Base.UUID:$key_id"

        # GET /api/keys/not-a-uuid
        r = internalrequest(HTTP.Request("GET", "/api/keys/not-a-uuid"))
        @test r.status == 400

        # POST /api/items
        r = internalrequest(HTTP.Request("POST", "/api/items"))
        @test r.status == 200
        body = Nitro.text(r)
        @test body == "created" || body == "\"created\""
    finally
        terminate()
        resetstate()
    end
end

@testset "named routes" begin
    user_handler = function(req::HTTP.Request, id::Int)
        return Res.send("ok")
    end
    flag_handler = function(req::HTTP.Request, enabled::Bool)
        return Res.send("ok")
    end
    key_handler = function(req::HTTP.Request, key::UUID)
        return Res.send("ok")
    end
    key_id = UUID("550e8400-e29b-41d4-a716-446655440000")

    try
        urlpatterns("/api",
            path("/users/<int:id>", user_handler, method="GET", name="user-detail"),
            path("/flags/<bool:enabled>", flag_handler, method="GET", name="flag-detail"),
            path("/keys/<uuid:key>", key_handler, method="GET", name="key-detail"),
        )

        @test url("user-detail"; id=42) == "/api/users/42"
        @test url("flag-detail"; enabled=true) == "/api/flags/true"
        @test url("key-detail"; key=key_id) == "/api/keys/$key_id"
        @test_throws ArgumentError url("user-detail")
        @test_throws ArgumentError url("user-detail"; id=42, extra=1)
        @test_throws ArgumentError url("missing-route"; id=42)
    finally
        resetstate()
    end
end

@testset "duplicate route names" begin
    handler = function(req::HTTP.Request)
        return Res.send("ok")
    end

    try
        @test_throws ArgumentError urlpatterns("",
            path("/users", handler, method="GET", name="dup-route"),
            path("/admins", handler, method="GET", name="dup-route"),
        )
    finally
        resetstate()
    end
end

@testset "converter type conflicts" begin
    bad_handler = function(req::HTTP.Request, id::String)
        return Res.send(id)
    end
    bad_bool_handler = function(req::HTTP.Request, id::Bool)
        return Res.send(string(id))
    end

    try
        @test_throws ArgumentError urlpatterns("",
            path("/conflict/<int:id>", bad_handler, method="GET"),
        )
        @test_throws ArgumentError urlpatterns("",
            path("/bool-conflict/<int:id>", bad_bool_handler, method="GET"),
        )
    finally
        resetstate()
    end
end

# ─── Test: include_routes() integration ───────────────────────────────

@testset "include_routes integration" begin
    get_profile = (req) -> "profile"
    get_settings = (req) -> "settings"
    
    user_routes = [
        path("/profile", get_profile, method="GET"),
        path("/settings", get_settings, method="GET"),
    ]

    urlpatterns("",
        include_routes("/user", user_routes)...,
    )

    serve(port=port, async=true, show_banner=false)
    sleep(1)

    try
        r = internalrequest(HTTP.Request("GET", "/user/profile"))
        @test r.status == 200
        body = Nitro.text(r)
        @test body == "profile" || body == "\"profile\""
        
        r = internalrequest(HTTP.Request("GET", "/user/settings"))
        @test r.status == 200
        body = Nitro.text(r)
        @test body == "settings" || body == "\"settings\""
    finally
        terminate()
        resetstate()
    end
end

end

@testitem "Scalar path & query params reject bad input with 400" tags=[:core] setup=[NitroCommon] begin

using Test
using HTTP
using Nitro
using UUIDs
using Nitro: path

# Uses a *local* App + internalrequest, so this item mutates no global
# router/server state and is safe to run in parallel with other test items.

ctx = Nitro.Core.App()
Nitro.Core.Routing.urlpatterns(ctx, "/api", Nitro.RouteDefinition[
    path("/items/<int:id>",   (req, id::Int)   -> Res.send(string(id)),   method="GET"),
    path("/toggle/<bool:on>", (req, on::Bool)  -> Res.send(string(on)),   method="GET"),
    path("/keys/<uuid:key>",  (req, key::UUID) -> Res.send(string(key)),  method="GET"),
    path("/mixed/{v}",        (req, v::Union{Int, UUID}) -> Res.send(string(typeof(v))), method="GET"),
    path("/search",           (req, q::String, limit::Int) -> Res.send("$q:$limit"),     method="GET"),
    path("/page",             (req, page::Int = 1) -> Res.send(string(page)),            method="GET"),
    path("/cursor",           (req, cursor::Nullable{Int} = nothing) ->
                                  Res.send(isnothing(cursor) ? "none" : "got:$cursor"),  method="GET"),
    path("/boom",             (req) -> error("boom"),                                    method="GET"),
])

get_(target) = Nitro.Core.internalrequest(ctx, HTTP.Request("GET", target))

@testset "happy paths are unchanged" begin
    @test get_("/api/items/42").status == 200
    @test Nitro.text(get_("/api/items/42")) == "42"
    @test get_("/api/toggle/true").status == 200
    @test get_("/api/search?q=x&limit=3").status == 200
    @test Nitro.text(get_("/api/search?q=x&limit=3")) == "x:3"

    # A query param with a declared default still falls back when absent.
    r = get_("/api/page")
    @test r.status == 200
    @test Nitro.text(r) == "1"
end

@testset "malformed path params are 400, not 500" begin
    for target in ("/api/items/abc", "/api/toggle/nope", "/api/keys/not-a-uuid")
        r = get_(target)
        @test r.status == 400
        @test Nitro.json(r)["message"] == "400: Bad Request"
    end

    # OverflowError: a value a route-level regex could never reject, which is why the
    # converter stays a binding declaration rather than becoming a routing filter.
    @test get_("/api/items/99999999999999999999").status == 400

    # No union member parses -> 400, instead of the raw String reaching the handler.
    # Assert the bound TYPE, not just the status: a regression to the wrong union member
    # would still be a 200.
    r = get_("/api/mixed/42")
    @test r.status == 200
    @test Nitro.text(r) == string(Int)

    key = "550e8400-e29b-41d4-a716-446655440000"
    r = get_("/api/mixed/$key")
    @test r.status == 200
    @test Nitro.text(r) == string(UUID)

    @test get_("/api/mixed/notanumber").status == 400
end

@testset "Nullable scalar params bind the value the client sent" begin
    # `Base.uniontypes` puts Nothing first and JSON.parse(str, Nothing) succeeds for any
    # valid JSON, so this used to bind `nothing` and discard the 5 outright.
    r = get_("/api/cursor?cursor=5")
    @test r.status == 200
    @test Nitro.text(r) == "got:5"

    # Absence is still absence -- that is what the declared default is for.
    r = get_("/api/cursor")
    @test r.status == 200
    @test Nitro.text(r) == "none"

    # Present but unparseable is a client error, not a silent `nothing`.
    @test get_("/api/cursor?cursor=abc").status == 400
end

struct MalformedBox; v::String; end

@testset "percent-encoded values are decoded exactly once (#70)" begin
    # `HTTP.queryparams` already decodes, and `parseparam` used to decode AGAIN, so any query
    # value carrying a `%` was silently mangled. Each case below asserts the handler receives
    # exactly what the client encoded -- one decode, no more.

    # The issue's own reproducer: "100% off".
    @test Nitro.text(get_("/api/search?q=100%25%20off&limit=1")) == "100% off:1"

    # An encoded plus must survive as an encoded plus. Under the double decode `%252B`
    # collapsed to a literal `+`, so this is the regression that names the bug.
    @test Nitro.text(get_("/api/search?q=a%252Bb&limit=1")) == "a%2Bb:1"

    # Double-encoded traversal: ONE decode yields `%2e%2e%2f`. A second would reconstitute
    # `../` -- the OWASP double-encoding class this invariant exists to foreclose.
    @test Nitro.text(get_("/api/search?q=%252e%252e%252f&limit=1")) == "%2e%2e%2f:1"

    # A bare `%` that is not a valid escape sequence must not be eaten.
    @test Nitro.text(get_("/api/search?q=50%25&limit=1")) == "50%:1"

    # Path params come in still-encoded from HTTP.jl's router, so they get their single
    # decode at the accessor. Same one-decode rule, opposite starting state.
    ctx2 = Nitro.Core.App()
    Nitro.Core.Routing.urlpatterns(ctx2, "", Nitro.RouteDefinition[
        path("/p/{v}", (req, v::String) -> Res.send(v), method="GET"),
        # Reads the scalar binding and the `getparams(req)` accessor in one handler: both must
        # agree, since they are now the same decoded value.
        path("/agree/{v}", (req, v::String) -> Res.send("$v|$(getparams(req)["v"])"), method="GET"),
    ])
    g2(t) = Nitro.Core.internalrequest(ctx2, HTTP.Request("GET", t))

    @test Nitro.text(g2("/p/a%20b"))     == "a b"
    @test Nitro.text(g2("/p/a%2Fb"))     == "a/b"
    @test Nitro.text(g2("/p/a%252Bb"))   == "a%2Bb"     # one decode, not two
    @test Nitro.text(g2("/agree/a%20b")) == "a b|a b"
end

@testset "malformed percent-encoding is 400, not 500 (#18 guarantee at the new decode site)" begin
    # `HTTP.unescapeuri` throws on a bad escape (EOFError for a trailing "%", ArgumentError
    # for "%ZZ"), and `HTTP.queryparams` decodes internally and throws the same way. Both
    # decodes now happen in the `Types.*` accessors -- OUTSIDE `parseparam_checked`, which is
    # what used to convert those into a 400. Without the guard in the accessors this is a 500
    # with a logged backtrace, which is exactly what #18 removed.
    ctx3 = Nitro.Core.App()
    Nitro.Core.Routing.urlpatterns(ctx3, "", Nitro.RouteDefinition[
        path("/m/{v}", (req, v::String) -> Res.send(v), method="GET"),
        path("/mq",    (req, v::String) -> Res.send(v), method="GET"),
        # `Path{T}` is a genuinely separate binding path, and one that returned 200 with the
        # raw value before this change -- pin it, or a refactor moving the decode back inside
        # `parseparam_checked` leaves this testset green while re-breaking the extractor.
        path("/ex/{v}", (req, p::Nitro.Path{MalformedBox}) -> Res.send(p.payload.v), method="GET"),
    ])
    g3(t) = Nitro.Core.internalrequest(ctx3, HTTP.Request("GET", t))

    for target in ("/m/%ZZ", "/m/%", "/m/%2", "/mq?v=%ZZ", "/mq?v=%", "/ex/%ZZ", "/ex/%80")
        r = g3(target)
        @test r.status == 400
        @test Nitro.json(r)["message"] == "400: Bad Request"
    end

    @test Nitro.text(g3("/ex/a%20b")) == "a b"

    # `getparams(req)` and `payload(req)` cannot be pinned through a route -- registration requires a
    # declared handler parameter for every brace, and that parameter's own decode throws first.
    # Assert at the accessor instead, with the router's slot populated by hand.
    bad = HTTP.Request("GET", "/raw/%ZZ")
    bad.context[:params] = Dict("v" => "%ZZ")
    @test_throws Nitro.ValidationError Nitro.Types.pathparams(bad)

    # #130: these two accessors are the third and fourth sites that attach a `.cause`, and the
    # default render must not show it. Structural rather than sentinel-based on purpose —
    # `unescapeuri` fails inside `parse(UInt8, "ZZ"; base=16)`, so this cause carries the two
    # hex digits and never the segment; a `!occursin("SUPERSECRET", …)` assertion here would
    # pass against the unpatched renderer and prove nothing. The invariant that DOES generalize
    # across all four sites is "a cause is attached, and no default render shows it".
    perr = try Nitro.Types.pathparams(bad); nothing catch e; e end
    @test perr.cause isa Exception
    @test !occursin("Caused by", sprint(showerror, perr))
    @test !occursin("ZZ", sprint(show, perr))
    @test occursin("Caused by", sprint(io -> showerror(io, perr; cause = true)))

    # The query accessor has no direct-accessor test at all today — only the end-to-end
    # `g3("/mq?v=%ZZ")` status check above. Pin it here so a fifth wrap site lands next to a
    # test that states the rule.
    qerr = try Nitro.Types.queryvars(HTTP.Request("GET", "/mq?v=%ZZ")); nothing catch e; e end
    @test qerr isa Nitro.ValidationError
    @test qerr.cause isa Exception
    @test !occursin("Caused by", sprint(showerror, qerr))

    # #132: the query KEY is percent-decoded client input, unlike the path-parameter name just
    # above, and it was interpolated into `.msg` raw -- which #72 put on the `@debug` log path.
    # `?a%0AFAKE=%80` therefore wrote a literal newline into a log field.
    #
    # `isvalid(k)` alone would NOT have caught this: `isvalid("a\nFAKE") === true`, so the fix
    # escapes through `repr` instead. The assertion is pinned on the newline rather than on the
    # key text for that reason -- a UTF-8-only fix passes a `!occursin(raw_key, …)` test and
    # still leaves the injection open.
    keyerr = try
        Nitro.Types.queryvars(HTTP.Request("GET", "/mq?a%0AFAKE=%80"))
        nothing
    catch e
        e
    end
    @test keyerr isa Nitro.ValidationError
    @test !occursin("\n", keyerr.msg)                      # THE defect: no raw control char
    @test !occursin("a\nFAKE", keyerr.msg)                 # nor the raw key
    @test occursin("a\\nFAKE", keyerr.msg)                 # ...but escaped, so still diagnosable
    @test !occursin("\n", sprint(showerror, keyerr))       # showerror is app-reachable too
    # Guard the premise: a control character IS valid UTF-8, so this test proves something a
    # key-side `isvalid` check would not have delivered.
    @test isvalid("a\nFAKE")

    # An over-long key degrades to a positional report rather than writing 4 KB into one log
    # line. The value must still be the thing that fails, so the key is well-formed here.
    longkey = repeat("k", Nitro.Types.MAX_QUERY_KEY_REPORT + 1)
    longerr = try
        Nitro.Types.queryvars(HTTP.Request("GET", "/mq?$longkey=%80"))
        nothing
    catch e
        e
    end
    @test longerr isa Nitro.ValidationError
    @test occursin("(name too long)", longerr.msg)
    @test !occursin(longkey, longerr.msg)

    # A well-formed key on a rejected value is still named, so the fix costs no diagnostics.
    namederr = try Nitro.Types.queryvars(HTTP.Request("GET", "/mq?token=%80")); nothing catch e; e end
    @test namederr isa Nitro.ValidationError
    @test occursin("token", namederr.msg)

    # These assert the TYPE again. The old spelling was `bad.params`, which had to be matched
    # on MESSAGE: it went through the process-wide `Base.getproperty(::HTTP.Request, ::Symbol)`
    # override, and the since-deleted `test/instance_tests.jl` built a second Nitro via `instance()` whose
    # `__init__` re-installed *its* override -- so under the full suite the thrown value was
    # that instance's `ValidationError`, a distinct type from this module's, and a type
    # assertion was order-dependent (green alone, red in the suite). #151 deleted the override
    # and the call sites here now name `getparams`/`payload`, ordinary generics that always
    # resolved in this module. So the constraint is gone, not merely relaxed.
    # (These would pass under the unpatched code too -- `getparams` was never pirated. What
    # changed is that the test can be *written* this way now.)
    @test_throws Nitro.ValidationError getparams(bad)
    @test_throws Nitro.ValidationError payload(bad)
    @test_throws "Malformed percent-encoding in path parameter 'v'" getparams(bad)

    bad8 = HTTP.Request("GET", "/raw/%80")
    bad8.context[:params] = Dict("v" => "%80")
    @test_throws Nitro.ValidationError Nitro.Types.pathparams(bad8)
    @test_throws "Invalid UTF-8 in path parameter 'v'" getparams(bad8)

    ok = HTTP.Request("GET", "/raw/a%20b")
    ok.context[:params] = Dict("v" => "a%20b")
    @test getparams(ok)["v"] == "a b"

    # `unescapeuri` does NOT throw on "%80" -- it returns an invalid-UTF-8 String, which would
    # surface as a 500 the moment anything serialized it. The boundary rejects it instead.
    @test g3("/m/%80").status == 400
    @test !isvalid(HTTP.unescapeuri("%80"))    # guards the premise

    # The query accessor must apply the SAME rule. It did not at first: `?v=%80` returned 200
    # and `Res.json` emitted an invalid-UTF-8 body. Two accessors disagreeing about what counts
    # as well-formed is the exact divergence #70 exists to remove.
    @test g3("/mq?v=%80").status == 400
    @test g3("/mq?v=caf%E9").status == 400

    # Well-formed escapes are unaffected by the guard.
    @test Nitro.text(g3("/m/a%20b"))  == "a b"
    @test Nitro.text(g3("/mq?v=a%20b")) == "a b"

    # And -- the actual point of #18 -- a rejected request must not be logged as a server
    # error. A spray of malformed URLs used to write one stack trace per request.
    @test_logs min_level=Base.CoreLogging.Error begin
        @test g3("/m/%ZZ").status == 400
        @test g3("/mq?v=%").status == 400
    end
end

@testset "missing and malformed query params are 400, not 500" begin
    # Required query param absent: this used to be a KeyError -> 500.
    @test get_("/api/search?q=x").status == 400
    @test get_("/api/search").status == 400

    # Present but unparseable, with and without a declared default.
    @test get_("/api/search?q=x&limit=abc").status == 400
    @test get_("/api/page?page=abc").status == 400
end

@testset "client input is not logged as a server error" begin
    # A rejected request must not emit an @error/backtrace: under a spray of malformed
    # URLs the old behavior wrote one stack trace per request.
    # `Base.CoreLogging.Error` rather than `Logging.Error`: Logging is not a test dep.
    # Do NOT add `match_mode=:any` here: with zero patterns it reduces to `all(())`, which
    # is vacuously true and would pass even with an @error inside. The default `:all` mode
    # requires `length(logs) == length(patterns) == 0`, which is the actual assertion.
    @test_logs min_level=Base.CoreLogging.Error begin
        @test get_("/api/items/abc").status == 400
        @test get_("/api/search?q=x").status == 400
    end

    # Negative control: a genuine handler fault is still a 500 and still logs at :error.
    @test_logs (:error,) match_mode=:any begin
        @test get_("/api/boom").status == 500
    end
end

end

@testitem "Middleware may read path params before the router runs (#38)" tags=[:core] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core: App, internalrequest
using Nitro.Core.Routing: urlpatterns

# Regression for the per-request caches. `HTTP.getparams` reads a context slot the ROUTER
# fills, but middleware -- global, per-route and guards alike -- runs before the router. Two
# distinct caches had to be taught that:
#
#   * `pathparams` must not memoize the pre-router `nothing`, or the path binder indexes into
#     it and every parameterized route 500s.
#   * `request_input` must not memoize a merge performed before the params existed, or every
#     later reader gets an input map with the path params silently missing.
#
# The route echoes BOTH maps, so the assertions observe what the handler actually sees rather
# than only that the request survived: a handler binding `id::Int` goes through the path
# binder, never through `payload(req)`, so asserting on the bound value alone would pass even
# with `payload(req)` poisoned.
ctx = App()
urlpatterns(ctx, "", Nitro.RouteDefinition[
    Nitro.path("/items/<int:id>", function (req, id::Int)
        Res.json(Dict("id" => id, "params" => getparams(req), "input" => payload(req)))
    end, method="GET"),
])

expected = Dict("id" => 42,
                "params" => Dict("id" => "42"),
                "input" => Dict("id" => "42"))

reads_params(handler) = function (req::HTTP.Request)
    @test getparams(req) === nothing        # pre-router: genuinely not populated yet
    handler(req)
end

reads_input(handler) = function (req::HTTP.Request)
    _ = payload(req)                       # merges path params -- so it touches them too
    handler(req)
end

reads_payload(handler) = function (req::HTTP.Request)
    _ = Nitro.payload(req)              # the public spelling of the same read
    handler(req)
end

roundtrip(mw) = Nitro.json(internalrequest(ctx, HTTP.Request("GET", "/items/42"); middleware=mw))

@testset "no middleware" begin
    @test roundtrip(Function[]) == expected
end

@testset "middleware reading getparams(req) does not brick the route" begin
    # Pre-fix: `pathparams` cached the `nothing`, the binder did `nothing["id"]`, 500.
    @test roundtrip([reads_params]) == expected
end

@testset "middleware reading payload(req) keeps path params in the handler's input" begin
    # Pre-fix: 200, but `input` came back `{}` -- silently wrong rather than loud.
    @test roundtrip([reads_input]) == expected
end

@testset "the same holds through the public payload(req)" begin
    @test roundtrip([reads_payload]) == expected
end
end

@testitem "HEAD is auto-routed from GET (#277)" tags=[:core] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core: App, Service, internalrequest, DeclaredMethodHandler
using Nitro.Core.Routing: urlpatterns

# In-process and a local `App` per case: routing and middleware keying are what change here, and
# `internalrequest` runs the same `compose` a server does. The wire half (empty body, the GET's
# Content-Type and Content-Length) is in "Response builders on the wire", test/response_tests.jl.

head(ctx, target) = internalrequest(ctx, HTTP.Request("HEAD", target))
leaf(ctx, method, target) = first(HTTP.Handlers.gethandler(ctx.service.router, HTTP.Request(method, target)))
# The auto-HEAD leaf keys its middleware on the GET route's (#282 generalized it). An explicit HEAD
# route's leaf is registered bare.
is_auto_head(h) = h isa DeclaredMethodHandler && h.method == "GET"

seen_method(req::HTTP.Request) = HTTP.Response(200, ["X-Seen-Method" => req.method], "get body")
explicit_head(req::HTTP.Request) = Res.status(299)
deny = handle -> (req -> HTTP.Response(403))
tag(value) = handle -> (req -> Nitro.Core.Util.add_response_headers(handle(req), "X-Tag" => value))

@testset "a GET-only route answers HEAD through its GET handler" begin
    ctx = App()
    urlpatterns(ctx, "", path("/g", seen_method), path("/v/<int:id>", (req::HTTP.Request, id::Int) -> Res.json(Dict("id" => id))))
    r = head(ctx, "/g")
    @test r.status == 200
    @test HTTP.header(r, "X-Seen-Method") == "HEAD"
    @test head(ctx, "/v/7").status == 200
    @test is_auto_head(leaf(ctx, "HEAD", "/g"))
    # HEAD only. Every other method on a GET route is refused as before.
    @test internalrequest(ctx, HTTP.Request("POST", "/g")).status == 405
end

@testset "an explicit HEAD route wins, in either order, and neither order warns" begin
    ctx = App()
    # `@test_logs` with no patterns asserts that NOTHING at or above Warn was logged. HTTP.jl
    # warns on every leaf replacement, and HEAD-after-GET replaces the auto leaf.
    @test_logs min_level = Base.CoreLogging.Warn urlpatterns(ctx, "",
        path("/before", explicit_head; method = "HEAD"),
        path("/before", seen_method),
        path("/after",  seen_method),
        path("/after",  explicit_head; method = "HEAD"),
        path("/both",   seen_method; methods = ["GET", "HEAD"]),
    )
    @test head(ctx, "/before").status == 299
    @test head(ctx, "/after").status == 299
    @test HTTP.header(head(ctx, "/both"), "X-Seen-Method") == "HEAD"
    @test !(leaf(ctx, "HEAD", "/both") isa DeclaredMethodHandler)
end

@testset "precedence is per route shape, as HTTP.jl's tree stores it" begin
    # `/s/{id}` and `/s/{x}` are one leaf in the tree, whatever the variable is called.
    ctx = App()
    explicit_x(req::HTTP.Request, x::Int) = Res.status(299)
    @test_logs min_level = Base.CoreLogging.Warn urlpatterns(ctx, "",
        path("/s1/<int:x>",  explicit_x; method = "HEAD"),
        path("/s1/<int:id>", (req::HTTP.Request, id::Int) -> Res.json(Dict("id" => id))),
        path("/s2/<int:id>", (req::HTTP.Request, id::Int) -> Res.json(Dict("id" => id))),
        path("/s2/<int:x>",  explicit_x; method = "HEAD"),
    )
    @test head(ctx, "/s1/1").status == 299
    @test head(ctx, "/s2/1").status == 299
end

@testset "two explicit HEAD routes on one shape still warn" begin
    ctx = App()
    @test_logs (:warn, r"replacing existing registered route") urlpatterns(ctx, "",
        path("/dup", explicit_head; method = "HEAD"),
        path("/dup", explicit_head; method = "HEAD"),
    )
end

@testset "STREAM and WEBSOCKET routes get no HEAD" begin
    ctx = App()
    urlpatterns(ctx, "",
        path("/stream", (stream::HTTP.Stream) -> nothing; method = "STREAM"),
        path("/ws", (ws::HTTP.WebSockets.WebSocket) -> nothing; method = "WEBSOCKET"),
    )
    @test leaf(ctx, "GET", "/stream") isa Function
    @test leaf(ctx, "HEAD", "/stream") === missing
    @test leaf(ctx, "HEAD", "/ws") === missing

    # Re-registering a GET path as STREAM or WEBSOCKET (Revise, a re-run `urlpatterns`) replaces
    # the GET leaf. The auto-HEAD it left behind must not keep serving the old GET handler.
    for (method, handler) in (("STREAM", (stream::HTTP.Stream) -> nothing),
                              ("WEBSOCKET", (ws::HTTP.WebSockets.WebSocket) -> nothing))
        ctx = App()
        urlpatterns(ctx, "", path("/swap", seen_method))
        @test head(ctx, "/swap").status == 200
        urlpatterns(ctx, "", path("/swap", handler; method = method))
        @test head(ctx, "/swap").status == 405
        # ... and a GET registered there again gets its auto-HEAD back.
        urlpatterns(ctx, "", path("/swap", seen_method))
        @test head(ctx, "/swap").status == 200
    end
end

@testset "a method=\"*\" route registered after the GET no longer receives its HEAD" begin
    # HTTP.jl gives a HEAD to the first leaf that accepts it, and the auto-HEAD now sits before a
    # later `"*"` leaf. The GET route answers the HEAD; every other method still reaches `"*"`.
    ctx = App()
    urlpatterns(ctx, "",
        path("/any", seen_method),
        path("/any", (req::HTTP.Request) -> Res.status(298); method = "*"),
    )
    @test HTTP.header(head(ctx, "/any"), "X-Seen-Method") == "HEAD"
    @test internalrequest(ctx, HTTP.Request("PUT", "/any")).status == 298
end

@testset "a router with HTTP.jl-level middleware gets no auto-HEAD" begin
    # `register!` wraps the handler in the router's own middleware, so the leaf could no longer
    # be told apart from an explicit HEAD, and would lose the GET route's guards. A 405 is safe.
    ctx = App(service = Service(router = HTTP.Router(HTTP.Handlers.default404, HTTP.Handlers.default405, h -> (req -> h(req)))))
    urlpatterns(ctx, "", path("/g", seen_method; middleware = [deny]))
    @test leaf(ctx, "HEAD", "/g") === missing
    @test head(ctx, "/g").status == 405
end

@testset "route middleware on the GET route gates its HEAD" begin
    # The auto-HEAD keys its middleware on `GET|path`. Keyed on `HEAD|path` it would find none,
    # and a guarded GET route would answer an unguarded HEAD.
    ctx = App()
    urlpatterns(ctx, "", path("/guarded", seen_method; middleware = [deny]))
    @test internalrequest(ctx, HTTP.Request("GET", "/guarded")).status == 403
    @test head(ctx, "/guarded").status == 403
end

@testset "HEAD follows a re-published GET middleware, and an explicit HEAD drops it" begin
    ctx = App()
    urlpatterns(ctx, "", path("/r", seen_method; middleware = [tag("one")]))
    @test HTTP.header(head(ctx, "/r"), "X-Tag") == "one"        # warms the cached chain

    # Re-registering the GET (what Revise does) re-publishes `GET|/r` and invalidates its cached
    # chain. The auto-HEAD shares that key, so it must see the new middleware too.
    urlpatterns(ctx, "", path("/r", seen_method; middleware = [tag("two")]))
    @test HTTP.header(head(ctx, "/r"), "X-Tag") == "two"

    # An explicit HEAD with no middleware of its own replaces the auto leaf. It must not keep
    # the GET route's middleware, from the table or from the chain the HEADs above cached.
    urlpatterns(ctx, "", path("/r", explicit_head; method = "HEAD"))
    r = head(ctx, "/r")
    @test r.status == 299
    @test !HTTP.hasheader(r, "X-Tag")
end
end

@testitem "A 405 carries Allow (#281)" tags=[:core] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core: App, Service, internalrequest, RetiredHeadHandler
using Nitro.Core.Routing: urlpatterns

# In-process and a local `App` per case. The wire half is in "Response builders on the wire",
# test/response_tests.jl.

send(ctx, method, target) = internalrequest(ctx, HTTP.Request(method, target))
allow(r) = HTTP.header(r, "Allow", nothing)
leaf(ctx, method, target) = first(HTTP.Handlers.gethandler(ctx.service.router, HTTP.Request(method, target)))

ok(req::HTTP.Request) = Res.status(200)
ok_name(req::HTTP.Request, name::String) = Res.status(200)
passthrough = handle -> (req -> handle(req))

@testset "Allow lists the path's methods, with the auto-HEAD and without OPTIONS" begin
    ctx = App()
    urlpatterns(ctx, "", path("/items", ok; methods = ["GET", "POST"]))
    r = send(ctx, "DELETE", "/items")
    @test r.status == 405
    @test allow(r) == "GET, HEAD, POST"
    # The query string is not part of the path the tree is walked with.
    @test allow(send(ctx, "PUT", "/items?x=1")) == "GET, HEAD, POST"
    # The methods that are allowed still answer.
    @test send(ctx, "GET", "/items").status == 200
    @test send(ctx, "HEAD", "/items").status == 200
end

@testset "the same Allow when per-route middleware sends the request through compose" begin
    # With a non-empty middleware table, `compose` runs `gethandler` first and the 405 reaches
    # the router terminal through its unmatched branch.
    ctx = App()
    urlpatterns(ctx, "", path("/items", ok; methods = ["GET", "POST"], middleware = [passthrough]))
    r = send(ctx, "DELETE", "/items")
    @test r.status == 405
    @test allow(r) == "GET, HEAD, POST"
end

@testset "OPTIONS, an explicit HEAD and a custom method are listed when registered" begin
    ctx = App()
    urlpatterns(ctx, "",
        path("/o", ok; methods = ["POST", "OPTIONS"]),
        path("/h", ok; method = "HEAD"),
        path("/dav", ok; method = "PROPFIND"),
    )
    @test allow(send(ctx, "GET", "/o")) == "OPTIONS, POST"
    @test allow(send(ctx, "GET", "/h")) == "HEAD"
    @test allow(send(ctx, "GET", "/dav")) == "PROPFIND"
end

@testset "a STREAM route lists GET and POST, and no HEAD" begin
    ctx = App()
    urlpatterns(ctx, "", path("/stream", (stream::HTTP.Stream) -> nothing; method = "STREAM"))
    r = send(ctx, "PUT", "/stream")
    @test r.status == 405
    @test allow(r) == "GET, POST"
end

@testset "a retired auto-HEAD answers 405 with Allow, and is not in it" begin
    # A STREAM route replacing a GET leaves a HEAD leaf behind that refuses HEAD (#277). The router
    # resolves HEAD to that leaf, so HEAD must be left out of the list by hand.
    ctx = App()
    urlpatterns(ctx, "", path("/swap", ok))
    urlpatterns(ctx, "", path("/swap", (stream::HTTP.Stream) -> nothing; method = "STREAM"))
    @test leaf(ctx, "HEAD", "/swap") isa RetiredHeadHandler
    r = send(ctx, "HEAD", "/swap")
    @test r.status == 405
    @test allow(r) == "GET, POST"
    @test allow(send(ctx, "PUT", "/swap")) == "GET, POST"
end

@testset "a path matched by an exact and a variable route lists both" begin
    ctx = App()
    urlpatterns(ctx, "",
        path("/u/me", ok),
        path("/u/<str:name>", ok_name; method = "DELETE"),
    )
    # Each method goes to the first route that has it, so both routes' methods are allowed.
    @test send(ctx, "DELETE", "/u/me").status == 200
    @test allow(send(ctx, "PUT", "/u/me")) == "DELETE, GET, HEAD"
    @test allow(send(ctx, "PUT", "/u/other")) == "DELETE"
end

@testset "a method mismatch HTTP.jl reports as a miss is a 405, not a 404" begin
    ctx = App()
    urlpatterns(ctx, "",
        path("/users/me", ok),
        path("/users/<str:name>/posts", ok_name),
    )
    # HTTP.jl's `match` overwrites its `anymissing` flag per branch: the exact `/users/me` node
    # has GET, and the variable node tried after it has no leaf at this depth, so upstream
    # reports a miss. If this starts failing, upstream has fixed it and the re-check in
    # `_route_unresolved` is no longer needed.
    @test leaf(ctx, "POST", "/users/me") === nothing
    r = send(ctx, "POST", "/users/me")
    @test r.status == 405
    @test allow(r) == "GET, HEAD"

    # The same through `compose`: it sees upstream's `nothing` and takes its unmatched branch, which
    # must still reach the router terminal rather than answer 404 itself.
    ctx = App()
    urlpatterns(ctx, "",
        path("/users/me", ok; middleware = [passthrough]),
        path("/users/<str:name>/posts", ok_name),
    )
    r = send(ctx, "POST", "/users/me")
    @test r.status == 405
    @test allow(r) == "GET, HEAD"
end

@testset "a true miss is still a 404 with no Allow" begin
    ctx = App()
    urlpatterns(ctx, "", path("/users/<str:name>/posts", ok_name))
    for target in ("/nowhere", "/users", "/users/x", "/users/x/posts/extra")
        r = send(ctx, "GET", target)
        @test r.status == 404
        @test !HTTP.hasheader(r, "Allow")
    end
end

@testset "a custom _405 gets Allow unless it set its own, and is never mutated" begin
    shared = HTTP.Response(405)
    ctx = App(service = Service(router = HTTP.Router(HTTP.Handlers.default404, req -> shared)))
    urlpatterns(ctx, "", path("/c", ok))
    r = send(ctx, "POST", "/c")
    @test r.status == 405
    @test allow(r) == "GET, HEAD"
    # A new response, not the router's own object with a header appended.
    @test r !== shared
    @test !HTTP.hasheader(shared, "Allow")

    ctx = App(service = Service(router = HTTP.Router(HTTP.Handlers.default404,
        req -> HTTP.Response(418, ["Allow" => "BREW"]))))
    urlpatterns(ctx, "", path("/c", ok))
    r = send(ctx, "POST", "/c")
    @test r.status == 418
    @test [v for (k, v) in r.headers if k == "Allow"] == ["BREW"]
end
end
