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
    # The fragment stays in the path, where the canonical form escapes it (#351).
    @test O("http://h#/admin") == "/%23/admin"
    @test O("http://h/café") == "/caf%C3%A9"
end

@testset "asterisk-form, empty and relative targets" begin
    @test O("*") == "*"
    @test O("") == "/"
    @test O("admin/users") == "/admin/users"     # internalrequest only; the server refuses it
    @test O("?token=x") == "/?token=x"
end

# The property a URL gate relies on. For every accepted target the router's segments are
# exactly the path's own '/'-separated pieces -- nothing collapsed, nothing skipped -- and they
# DECODE to what the segments of the ORIGINAL target decoded to, so accepting it changes nothing
# a decoder downstream sees. Since #351 the raw segments themselves may differ: that is the
# canonicalization, and `test/request_target_tests.jl`'s #351 items pin it. The deliberate
# exceptions are the '/' held in an absolute-form query or fragment above, which the router took
# for the start of the path.
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
        @test HTTP.unescapeuri.(rsegs(t)) == HTTP.unescapeuri.(rsegs(r))
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
# Dot segments were never a way in; since #351 they are refused outright, like `//`.
@test status("/./admin/users") == 400
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

# #351: a static mount and a `{var}` param decode the path AFTER global middleware has run, so
# a gate keyed on a directory inside a mount saw one spelling while the mount served another:
# `/files/%70rivate/secret.txt` served `private/secret.txt` past a
# `startswith(req.target, "/files/private/")` gate. `_origin_form` now puts every path segment
# in one canonical encoding, so every spelling of a path reaches middleware as the same string.

@testitem "Request target: canonical percent-encoding (#351)" tags=[:core] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro

const O = Nitro.Core._origin_form

@testset "an escape of a pchar byte is decoded" begin
    @test O("/files/%70rivate/x") == "/files/private/x"       # the issue's reproduction
    @test O("/%66iles/private/x") == "/files/private/x"       # the mount root, too
    @test O("/%61dmin/users") == "/admin/users"
    @test O("/a%7eb") == "/a~b"                               # unreserved, lowercase hex
    @test O("/a%21b%3Ac%40d") == "/a!b:c@d"                   # sub-delims, ':' and '@'
    @test O("/%2A") == "/*"
end

@testset "every other byte becomes one uppercase triplet" begin
    @test O("/caf%c3%a9") == "/caf%C3%A9"                     # lowercase hex
    @test O("/café") == "/caf%C3%A9"                          # raw UTF-8
    @test O("/a%2fb") == "/a%2Fb"                             # an encoded '/' stays encoded
    @test O("/a%5Cb/%25/%3F/%23") == "/a%5Cb/%25/%3F/%23"
    @test O("/a b") == "/a%20b"                               # internalrequest only
    @test O("/a%80") == "/a%80"                               # invalid UTF-8 is not refused here
    @test O(String(UInt8[0x2f, 0x61, 0xff])) == "/a%FF"       # nor as a raw byte
end

@testset "the query is left as sent" begin
    @test O("/%70?q=%70&r=caf%c3%a9") == "/p?q=%70&r=caf%c3%a9"
    @test O("/p?x=/../%ZZ") == "/p?x=/../%ZZ"
    @test O("http://h/%70?q=%70") == "/p?q=%70"
end

@testset "a malformed escape is a ValidationError, the 400 every decoder gives it" begin
    for t in ("/%ZZ", "/a%", "/a%2", "/%G0/b", "/ok/%zz?q=1", "http://h/%")
        @test_throws Nitro.ValidationError O(t)
    end
end

@testset "a dot segment is refused, raw or encoded" begin
    for t in ("/.", "/..", "/./a", "/a/../b", "/a/.", "/a/..?q", "/%2E", "/%2e%2E/x", "/a/.%2e",
              "http://h/../x")
        @test O(t) === nothing
    end
    # Only a whole segment counts.
    @test O("/a..b/.env/...") == "/a..b/.env/..."
    @test O("/%2E%2E%2Fetc") == "/..%2Fetc"   # one segment: the '/' stays encoded
end

# `===` on two `String`s compares content, so it cannot tell a copy from the original. What the
# fast path promises is that nothing is BUILT, so measure that: a canonical target, escapes
# included, allocates nothing.
@testset "a canonical target is handed back without building anything" begin
    alloc(t) = (O(t); @allocated O(t))
    for t in ("/", "/a/b", "/a/", "/a?q=%70", "/a!b~c", "/caf%C3%A9", "/a%2Fb/%25", "/a..b",
              "/files/caf%C3%A9/s.txt?v=1")
        @test O(t) == t
        @test alloc(t) == 0
    end
    # ...and one that needs rewriting does build, so the measurement can fail.
    @test alloc("/caf%c3%a9") > 0
    @test alloc("/%70") > 0
end

# The invariant: canonicalizing never changes what a decoder sees, only the spelling. Every
# accepted target decodes segment-for-segment to what the original decoded to, and every
# spelling of one decoded path canonicalizes to one string.
@testset "decoding the canonical form gives back the original's bytes" begin
    dec(t) = [HTTP.unescapeuri(String(s)) for s in split(split(t, '?')[1], '/'; keepempty = false)]
    corpus = ("/files/%70rivate/secret.txt", "/caf%c3%a9", "/café", "/a%21b", "/a%2fb", "/%25",
              "/a%7E", "/x/%2A/**", "/p?q", "/u/%61b%21", "/a%20b", "/%7B%7d")
    for t in corpus
        r = O(t)
        @test r !== nothing
        @test dec(r) == dec(t)
        @test O(r) === r                                      # idempotent
    end
    spellings = ("/files/private/caf%C3%A9", "/files/%70rivate/caf%c3%a9", "/%66iles/private/café",
                 "/fil%65s/priv%61te/caf%C3%a9")
    @test allequal(O.(spellings))
end
end

@testitem "Request target: a gate inside a mount holds (#351)" tags=[:core] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro

d = mktempdir()
mkpath(joinpath(d, "private")); write(joinpath(d, "private", "secret.txt"), "SECRET")
mkpath(joinpath(d, "café"));    write(joinpath(d, "café", "s.txt"), "CAFE SECRET")
write(joinpath(d, "public.txt"), "PUBLIC")

app = App(mod = @__MODULE__)
staticfiles(app, d, "files")
urlpatterns(app, "",
    path("/admin/users", req -> "ADMIN DATA"),
    path("/u/{name}", (req, name::String) -> "USER $name"))
denied = ("/files/private/", "/files/caf%C3%A9/", "/admin/", "/u/root")
gate = handle -> req -> any(p -> startswith(req.target, p), denied) ? HTTP.Response(403) : handle(req)
r(t) = internalrequest(app, HTTP.Request("GET", t); middleware = [gate])

# The issue's reproduction, and the spellings the review of it found: before the fix every
# `200` here served the protected body.
for t in ("/files/private/secret.txt", "/files/%70rivate/secret.txt", "/%66iles/private/secret.txt",
          "/files/priv%61te/secret.txt", "/files/PRIVATE/../private/secret.txt",
          "/files/caf%C3%A9/s.txt", "/files/caf%c3%a9/s.txt", "/files/café/s.txt",
          "/admin/users", "/%61dmin/users", "/admin/%75sers", "/u/root", "/u/%72oot")
    res = r(t)
    @test res.status in (400, 403)
    @test !occursin("SECRET", text(res))
    @test !occursin("ADMIN", text(res))
end
@test r("/files/%70rivate/secret.txt").status == 403
@test r("/files/caf%c3%a9/s.txt").status == 403
@test r("/%61dmin/users").status == 403

# Dot segments and malformed escapes are refused before any middleware runs. The malformed
# escape keeps the JSON body a mount or a path param gave it before (#18, #70).
for t in ("/files/%2E%2E/private/secret.txt", "/files/./private/secret.txt", "/files/%ZZ.txt")
    @test r(t).status == 400
end
@test Nitro.json(r("/files/%ZZ.txt"))["message"] == "400: Bad Request"
seen = String[]
spy = handle -> req -> (push!(seen, req.target); handle(req))
internalrequest(app, HTTP.Request("GET", "/files/%ZZ.txt"); middleware = [spy])
@test isempty(seen)

# Not a mount that simply serves nothing: an ungated file answers, by any spelling.
@test text(r("/files/public.txt")) == "PUBLIC"
@test text(r("/files/p%75blic.txt")) == "PUBLIC"
@test text(r("/u/%61lice")) == "USER alice"

# Middleware sees the canonical target, and the query as sent.
empty!(seen)
internalrequest(app, HTTP.Request("GET", "/files/p%75blic.txt?v=%70"); middleware = [spy])
@test seen == ["/files/public.txt?v=%70"]
end

@testitem "Request target: routes are registered in canonical form (#351)" tags=[:core] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro

app = App(mod = @__MODULE__)
urlpatterns(app, "",
    path("/a%7eb", req -> "TILDE"),
    path("/caf%c3%a9", req -> "CAFE"),
    path("/raw/café", req -> "RAW"),
    path("/x/{id}/%2F", (req, id::String) -> "ID $id"))
get_(t) = internalrequest(app, HTTP.Request("GET", t))

for t in ("/a~b", "/a%7Eb", "/a%7eb")
    @test text(get_(t)) == "TILDE"
end
for t in ("/caf%C3%A9", "/caf%c3%a9", "/café")
    @test text(get_(t)) == "CAFE"
end
@test text(get_("/raw/caf%C3%A9")) == "RAW"
@test text(get_("/x/%41/%2f")) == "ID A"

for bad in ("/a/%ZZ", "/a/%", "/a/./b", "/a/%2E%2E", "/a/%2A", "/%2a%2a")
    @test_throws ArgumentError urlpatterns(App(mod = @__MODULE__), "", path(bad, req -> "x"))
end
# A pattern segment is not touched.
papp = App(mod = @__MODULE__)
urlpatterns(papp, "", path("/p/{id}/**", (req, id::String) -> "P $id"))
@test text(internalrequest(papp, HTTP.Request("GET", "/p/7/x"))) == "P 7"
@test text(internalrequest(papp, HTTP.Request("GET", "/p/%37/x"))) == "P 7"

# A mount prefix and a serve prefix are canonicalized the same way.
@test Nitro.Core.Util.mount_segments("my%7estatic/caf%c3%a9") == ["my~static", "caf%C3%A9"]
@test_throws ArgumentError Nitro.Core.Util.mount_segments("a/%2E%2E")
@test_throws ArgumentError Nitro.Core.Util.mount_segments("%2A")
@test Nitro.Core._normalize_prefix("/%61pi/caf%c3%a9") == "/api/caf%C3%A9"
@test_throws ArgumentError Nitro.Core._normalize_prefix("/api/%2e")
end

# The route middleware table is keyed by `genkey(method, route)` and read back with the route the
# router matched. Keying it by the AUTHORED spelling while registering the canonical one silently
# dropped every guard on a route written with a lowercase or unnecessary escape, or raw UTF-8 --
# found in review of the first cut of #351.
@testitem "Request target: route middleware survives canonicalization (#351)" tags=[:core] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro

deny = handle -> req -> HTTP.Response(403)
ok = req -> "HANDLER RAN"

app = App(mod = @__MODULE__)
urlpatterns(app, "",
    path("/caf%c3%a9", ok; middleware = [deny]),
    path("/raw/café", ok; middleware = [deny]),
    path("/a%7eb", ok; middleware = [deny]),
    path("/plain", ok; middleware = [deny]))
# Through a higher-order router too, whose key is built in `InnerRouter`, not `register_route`.
guarded = router(app, "/r%7e"; middleware = [deny])
Nitro.Core.register(app, "GET", guarded("/caf%c3%a9"), ok)

for t in ("/caf%C3%A9", "/caf%c3%a9", "/café", "/raw/caf%C3%A9", "/raw/café",
          "/a~b", "/a%7Eb", "/a%7eb", "/plain", "/pl%61in",
          "/r~/caf%C3%A9", "/r%7E/café")
    res = internalrequest(app, HTTP.Request("GET", t))
    @test res.status == 403
    @test !occursin("HANDLER RAN", text(res))
end
end

@testitem "Request target over a live server (#341, #351)" tags=[:core, :network] setup=[NitroCommon] begin
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
    # #351: a spelling the client did not normalize is gated like the plain one.
    @test status_of("/%61dmin/users") == 403
    @test status_of("/admin/%2E%2E/admin/users") == 400
finally
    terminate(app)
end
end
