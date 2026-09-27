@testitem "WebSocketOrigins middleware (#382)" tags=[:middleware, :security] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core.Types: WebSocketOriginPolicy, REQUEST_WS_ORIGINS_KEY, _parse_origin, _origin_listed

# In-process: the constructor's validation, the canonical form both sides of the comparison share,
# and what the middleware writes. The handshake itself — what the Origin check does with the
# policy — is exercised over a socket in test/websocket_tests.jl.

canonical(s) = first(_parse_origin(s))
problem(s) = last(_parse_origin(s))

@testset "the canonical form" begin
    @test canonical("https://app.example.com") == "https://app.example.com:443"
    @test canonical("http://app.example.com") == "http://app.example.com:80"
    @test canonical("HTTPS://App.Example.COM") == "https://app.example.com:443"
    @test canonical("https://app.example.com:443") == canonical("https://app.example.com")
    @test canonical("https://app.example.com:0443") == canonical("https://app.example.com")
    @test canonical("https://app.example.com:8443") == "https://app.example.com:8443"
    @test canonical("http://127.0.0.1:8080") == "http://127.0.0.1:8080"
    # IPv6: one serialization however it was written.
    @test canonical("http://[::1]:8080") == "http://[::1]:8080"
    @test canonical("http://[0:0:0:0:0:0:0:1]:8080") == "http://[::1]:8080"
    @test canonical("https://[2001:DB8::1]") == "https://[2001:db8::1]:443"
    # Punycode is ASCII, and is what a browser sends for an IDN host.
    @test canonical("https://xn--bcher-kva.example") == "https://xn--bcher-kva.example:443"
    # IPv4, and IPv4 embedded in IPv6, in the forms a browser sends.
    @test canonical("http://10.0.0.1:8080") == "http://10.0.0.1:8080"
    @test canonical("http://[::ffff:1.2.3.4]") == canonical("http://[::ffff:102:304]")
    @test canonical("https://[1:2:3:4:5:6:7:8]") == "https://[1:2:3:4:5:6:7:8]:443"
    @test canonical("https://1a.example.com") == "https://1a.example.com:443"
end

@testset "what is not an origin" begin
    for bad in ("*", "null", "NULL", "", "app.example.com", "//app.example.com",
                "wss://app.example.com", "ws://app.example.com", "ftp://app.example.com",
                "file:///etc/passwd", "https://", "https://app.example.com/",
                "https://app.example.com/chat", "https://app.example.com?x=1",
                "https://app.example.com#top", "https://user:pw@app.example.com",
                "https://app.example.com:", "https://app.example.com:0",
                "https://app.example.com:65536", "https://app.example.com:44x",
                "https://bücher.example", "https://app example.com", " https://app.example.com",
                "https://app.example.com\r\n", "https://::1", "https://[::1", "https://[::1]x",
                "https://[not-an-ip]", "https://[::1]:", "https://[]", "https://[1::2::3]",
                "https://[fe80::1%eth0]", "https://app*.example.com",
# `Sockets.parse` accepts every one of these as SOME address (#382 review).
"https://[:1]", "https://[1:]", "https://[1.2.3.4]", "https://[00000::1]",
"https://[1:2:3:4:5:6:7]", "https://[1:2:3:4:5:6:7:8:9]", "https://[::ffff:1.2.3]",
"https://[1.2.3.4::]",
# Spellings a browser never sends, which would never match (WHATWG normalizes them).
"https://app.example.com.", "https://.app.example.com", "https://app..example.com",
"http://0x7f.1", "http://127.1", "http://0177.0.0.1", "http://256.0.0.1",
"http://example.123")
        @test canonical(bad) === nothing
        @test !isempty(problem(bad))
    end
end

@testset "the constructor names the fix" begin
    msg(x) = sprint(showerror, (try WebSocketOrigins([x]); nothing catch e; e end))
    @test_throws ArgumentError WebSocketOrigins(["*"])
    @test occursin("every site", msg("*"))
    @test occursin("sandboxed", msg("null"))
    @test occursin("use `https://`", msg("wss://app.example.com"))
    @test occursin("use `http://`", msg("ws://app.example.com"))
    @test occursin("trailing", msg("https://app.example.com/"))
    @test occursin("punycode", msg("https://bücher.example"))
    # One bad entry refuses the whole list: a half-applied allow-list is a config nobody wrote.
    @test_throws ArgumentError WebSocketOrigins(["https://app.example.com", "https://app.example.com/"])
end

@testset "membership is exact, never a substring or suffix" begin
    policy = WebSocketOriginPolicy(["https://app.example.com", "http://localhost:5173"])
    @test _origin_listed(policy, "https://app.example.com")
    @test _origin_listed(policy, "https://APP.example.com:443")
    @test _origin_listed(policy, "http://localhost:5173")
    for other in ("http://app.example.com", "https://app.example.com:8443",
                  "https://evil-app.example.com", "https://app.example.com.evil.example",
                  "https://example.com", "https://sub.app.example.com", "http://localhost:5174",
                  "http://localhost", "null", "", "https://app.example.com/")
        @test !_origin_listed(policy, other)
    end
    # An empty list is valid and lists nothing: same-origin only.
    @test !_origin_listed(WebSocketOriginPolicy(String[]), "https://app.example.com")
end

@testset "the middleware only records the policy, and the innermost layer wins" begin
    seen = Ref{Any}(nothing)
    handler = req -> (seen[] = get(req.context, REQUEST_WS_ORIGINS_KEY, nothing); HTTP.Response(200))
    outer = WebSocketOrigins(["https://app.example.com"])
    inner = WebSocketOrigins(["https://other.example.com"])
    narrow = WebSocketOrigins(String[])

    resp = outer(handler)(HTTP.Request("GET", "/ws"))
    @test resp.status == 200                     # it never rejects
    @test seen[] isa WebSocketOriginPolicy
    @test seen[].origins == Set(["https://app.example.com:443"])

    outer(inner(handler))(HTTP.Request("GET", "/ws"))
    @test seen[].origins == Set(["https://other.example.com:443"])   # replaced, not merged

    outer(narrow(handler))(HTTP.Request("GET", "/ws"))
    @test isempty(seen[].origins)                # a route can narrow back to same-origin
end

@testset "The middleware is reachable through `using Nitro`" begin
    # Three files have to agree for a middleware to be public: its own `export`, the
    # `@reexport using` in src/middleware.jl, and the explicit list in src/Nitro.jl.
    @test isdefined(Nitro, :WebSocketOrigins)
    @test :WebSocketOrigins in names(Nitro)
end

end
