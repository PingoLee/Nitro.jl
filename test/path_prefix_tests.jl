@testitem "Path prefix" tags=[:core, :network] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro

urlpatterns("",
    path("/test", function() return "Hello World" end, method="GET"),
)

port = get_free_port()
serve(prefix="/custom-api", port=port, host=HOST, async=true,  show_errors=false, show_banner=false)

@testset "Valid Prefixed requests" begin 
    r = internalrequest(HTTP.Request("GET", "/custom-api/test"))
    @test r.status == 200
    @test text(r) == "Hello World"

end


# 404 related tests (direct hits which shouldn't work)
@testset "Invalid Non-Prefixed requests" begin 

    r = internalrequest(HTTP.Request("GET", "/test"))
    @test r.status == 404

end

terminate()

end

@testitem "Path prefix: segment boundary and shape (#315)" tags=[:core] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core: PrefixStripMiddleware, _normalize_prefix

# Drive the layer directly: (status, the target the next layer saw).
function strip_through(target; prefix = "/api")
    seen = Ref{Union{String, Nothing}}(nothing)
    inner = req -> (seen[] = req.target; HTTP.Response(200))
    res = PrefixStripMiddleware(prefix)(inner)(HTTP.Request("GET", target))
    return (res.status, seen[])
end

@testset "a prefix covers whole path segments only" begin
    @test strip_through("/api/admin/users") == (200, "/admin/users")
    # THE BUG: a bare `startswith` turned this into `admin/users`, which the router resolved to
    # `/admin/users`, past any control keyed on `/api/admin`.
    @test strip_through("/apiadmin/users") == (404, nothing)
    @test strip_through("/api-v2/users") == (404, nothing)
    @test strip_through("/api#top") == (404, nothing)
    @test strip_through("/ap") == (404, nothing)
    @test strip_through("/admin/users") == (404, nothing)

    @test strip_through("/api") == (200, "/")
    @test strip_through("/api/") == (200, "/")
    @test strip_through("/api?x=1") == (200, "/?x=1")
    @test strip_through("/v1/api/x"; prefix = "/v1/api") == (200, "/x")
    @test strip_through("/v1/apix"; prefix = "/v1/api") == (404, nothing)
end

@testset "the rewritten target keeps its leading slash" begin
    # A trailing-slash prefix used to cut the '/' off every target it rewrote.
    @test strip_through("/api/users"; prefix = "/api/") == (200, "/users")
    @test strip_through("/api"; prefix = "/api/") == (200, "/")
    @test strip_through("/apiusers"; prefix = "/api/") == (404, nothing)
end

@testset "prefixes are matched and sliced by bytes" begin
    # `length` counted characters and was used as a byte index, so a multi-byte prefix sliced
    # mid-character on every request. On the wire it is percent-encoded, and that works.
    @test strip_through("/caf%C3%A9/menu"; prefix = "/caf%C3%A9") == (200, "/menu")
    @test strip_through("/caf%C3%A9x/menu"; prefix = "/caf%C3%A9") == (404, nothing)
    @test_throws ArgumentError PrefixStripMiddleware("/café")
end

@testset "_normalize_prefix" begin
    @test _normalize_prefix(nothing) === nothing
    @test _normalize_prefix("/api") == "/api"
    @test _normalize_prefix("/api/") == "/api"
    @test _normalize_prefix("/api//") == "/api"
    @test _normalize_prefix(SubString(" /api", 2)) == "/api"
    @test _normalize_prefix("/v1/caf%C3%A9") == "/v1/caf%C3%A9"
    @test _normalize_prefix("/a:b@c/~x;y=1") == "/a:b@c/~x;y=1"
    @test _normalize_prefix("/api") isa String
end

# `serve` owns the check, before it mutates anything: a rejected call must leave the app exactly
# as it was, not half-configured and not listening.
function rejects(app, prefix)
    try
        serve(app; prefix, port = get_free_port(), host = HOST, async = true,
              show_errors = false, show_banner = false)
    catch e
        return e isa ArgumentError
    finally
        isopen(app.service) && terminate(app)
    end
    return false
end

@testset "serve rejects a malformed prefix before touching the app" begin
    app = App(mod = @__MODULE__)
    for bad in ("", "/", "//", "api", "api/v1", "/api?x=1", "/api#top", "/a//b", "/a/./b",
                "/a/../b", "/..", "/café", "/a b", "/a%zz", 42, :api)
        @test rejects(app, bad)
        @test app.service.prefix[] === nothing
        @test !isopen(app.service)
    end
end

end

@testitem "Path prefix over a live server (#315)" tags=[:core, :network] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro

app = App(mod = @__MODULE__)
urlpatterns(app, "",
    path("/", req -> "ROOT"),
    path("/admin/users", req -> "ADMIN DATA"),
)
# The issue's reproduction: a global control keyed on the URL rather than on the matched route.
gate = handle -> req -> startswith(req.target, "/admin") ? HTTP.Response(403) : handle(req)

port = get_free_port()
# A `SubString` with a trailing slash. `serve` used to drop any prefix that was not a `String`,
# leaving every route unprefixed, and a trailing slash cut the '/' off every rewritten target.
serve(app; prefix = SubString(" /api/", 2), middleware = [gate], port, host = HOST,
      async = true, show_errors = false, show_banner = false)
try
    @test app.service.prefix[] == "/api"

    @test internalrequest(app, HTTP.Request("GET", "/api/admin/users"); middleware = [gate]).status == 403
    @test internalrequest(app, HTTP.Request("GET", "/apiadmin/users"); middleware = [gate]).status == 404

    base = "http://$HOST:$port"
    fetch_path(p) = HTTP.get(base * p; status_exception = false, retry = false, connect_timeout = 3)
    @test fetch_path("/api/admin/users").status == 403
    @test fetch_path("/apiadmin/users").status == 404
    r = fetch_path("/api")
    @test r.status == 200
    @test text(r) == "ROOT"
    @test fetch_path("/admin/users").status == 404
finally
    terminate(app)
end

end