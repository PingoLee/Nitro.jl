# #341: global middleware runs before the route is chosen, so it can only authorize on
# `req.target` if that is the path the router matches. HTTP.jl's router drops empty segments
# (`//admin/users` reaches `/admin/users`) and routes absolute-form by the path after the
# authority, so a `startswith(req.target, "/admin")` gate was bypassed by both.
# `OriginFormMiddleware` refuses the first with a 400 and reduces the second to origin-form.

@testitem "Request target: _origin_form (#341)" tags=[:core] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro

const O = Nitro.Core._origin_form

@testset "well-formed origin-form is returned as the same object" begin
    for t in ("/", "/a", "/a/b", "/a/", "/a?x=1", "/a?x=//y", "/caf%C3%A9")
        @test O(t) === t
    end
end

@testset "an empty path segment is refused" begin
    for t in ("//", "//a", "/a//b", "/a/b//", "//api/admin", "/a#//b", "http://h//a", "a//b")
        @test O(t) === nothing
    end
end

@testset "absolute-form loses its scheme and authority" begin
    @test O("http://h/a?q=1") == "/a?q=1"
    @test O("https://h.example:8443/a/b") == "/a/b"
    @test O("http://u:pa55w0rd@h/a") == "/a"
    @test !occursin("pa55w0rd", O("http://u:pa55w0rd@h/a?k=1"))
    @test O("http://h:abc/a") == "/a"            # a malformed authority is never parsed (#326)
    @test O("http://h") == "/"
    @test O("http://") == "/"
    @test O("http://h?x=1") == "/?x=1"
    # The router took the first '/' after `://`, even inside the query, and routed this to
    # `/admin`. The authority ends at '?', so the path is `/`.
    @test O("http://h?x=/admin") == "/?x=/admin"
    @test O("http://h#/admin") == "/#/admin"
    @test O("http://h/café") == "/café"
end

@testset "asterisk-form, empty and relative targets" begin
    @test O("*") == "*"
    @test O("") == "/"
    @test O("admin/users") == "/admin/users"     # internalrequest only; the server refuses it
    @test O("?token=x") == "/?token=x"
end

# The property a URL gate relies on. For every accepted target the router's segments are
# exactly the path's own '/'-separated pieces -- nothing collapsed, nothing skipped -- and they
# are the segments the router would have matched on the ORIGINAL target, so accepting it
# changes no routing. The deliberate exceptions are the '/' held in an absolute-form query or
# fragment above, which the router took for the start of the path.
@testset "the router matches the path global middleware reads" begin
    rsegs(t) = split(HTTP.Handlers._router_request_path(t), '/'; keepempty = false)
    corpus = ("/", "/a", "/a/b/", "/a?x=//y", "/a;b/c", "http://h/a/b?q", "http://u:p@h:1/a",
              "https://h", "admin/users", "?q=1", "", "/%2F/a", "/a#f", "//a", "/a//b",
              "http://h//x")
    for t in corpus
        r = O(t)
        r === nothing && continue
        @test startswith(r, '/')
        q = findfirst('?', r)
        pieces = split(q === nothing ? r : r[1:prevind(r, q)], '/')[2:end]
        isempty(last(pieces)) && pop!(pieces)
        @test all(!isempty, pieces)
        @test rsegs(r) == pieces
        @test rsegs(t) == rsegs(r)
    end
end

end

@testitem "Request target: a URL gate in global middleware holds (#341)" tags=[:core] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro

app = App(mod = @__MODULE__)
urlpatterns(app, "", path("/admin/users", req -> "ADMIN DATA"), path("/", req -> "ROOT"))
gate = handle -> req -> startswith(req.target, "/admin") ? HTTP.Response(403) : handle(req)
status(t) = internalrequest(app, HTTP.Request("GET", t); middleware = [gate]).status

# The issue's reproduction. Before the fix the three bypasses answered 200 with ADMIN DATA.
@test status("/admin/users") == 403
@test status("//admin/users") == 400
@test status("/admin//users") == 400
@test status("http://x/admin/users") == 403
@test status("http://u:p@x:abc/admin/users") == 403
@test status("admin/users") == 403
@test status("/./admin/users") == 404             # dot segments were never a way in
@test status("http://x?y=/admin/users") == 200    # now the root, not /admin/users
@test text(internalrequest(app, HTTP.Request("GET", "http://x?y=/admin/users"); middleware = [gate])) == "ROOT"

# A refused target never reaches user middleware.
seen = String[]
spy = handle -> req -> (push!(seen, req.target); handle(req))
@test internalrequest(app, HTTP.Request("GET", "//admin/users"); middleware = [spy]).status == 400
@test isempty(seen)
end

@testitem "Request target: under serve(prefix) (#341)" tags=[:core] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro

app = App(mod = @__MODULE__)
urlpatterns(app, "", path("/admin/users", req -> "ADMIN DATA"))
app.service.prefix[] = "/api"
gate = handle -> req -> startswith(req.target, "/admin") ? HTTP.Response(403) : handle(req)
seen = String[]
spy = handle -> req -> (push!(seen, req.target); handle(req))
req(t; mw = [gate]) = internalrequest(app, HTTP.Request("GET", t); middleware = mw)

@test req("/api/admin/users").status == 403
@test req("/api//admin/users").status == 400
@test req("//api/admin/users").status == 400
@test req("http://x/api/admin/users").status == 403
# Absolute-form was a 404 under a prefix: the strip only matched origin-form.
r = req("http://x/api/admin/users"; mw = [spy])
@test r.status == 200
@test text(r) == "ADMIN DATA"
@test seen == ["/admin/users"]
@test req("http://x/apiadmin/users").status == 404
end

@testitem "Request target over a live server (#341)" tags=[:core, :network] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Sockets

app = App(mod = @__MODULE__)
urlpatterns(app, "", path("/admin/users", req -> "ADMIN DATA"))
gate = handle -> req -> startswith(req.target, "/admin") ? HTTP.Response(403) : handle(req)

port = get_free_port()
serve(app; middleware = [gate], port, host = HOST, async = true, show_errors = false,
      show_banner = false)
# Raw request lines: HTTP.jl's client would normalize `//` and absolute-form away before sending.
function status_of(target)
    sock = Sockets.connect(HOST, port)
    try
        write(sock, "GET $target HTTP/1.1\r\nHost: $HOST:$port\r\nConnection: close\r\n\r\n")
        m = match(r"^HTTP/1\.1 (\d{3})", read(sock, String))
        return m === nothing ? 0 : parse(Int, m.captures[1])
    finally
        close(sock)
    end
end
try
    @test status_of("/admin/users") == 403
    @test status_of("//admin/users") == 400
    @test status_of("/admin//users") == 400
    @test status_of("http://x/admin/users") == 403
finally
    terminate(app)
end
end
