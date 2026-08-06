@testitem "Extract IP" tags=[:middleware] setup=[NitroCommon] begin
using HTTP
using Sockets
using Nitro: setip!, getip, getpeerip, ExtractIP
using Nitro.Middleware: extract_ip

# Helper function to create a request with specific headers and context IP
function create_request(headers, context_ip::IPAddr = IPv4("127.0.0.1"))
    req = HTTP.Request("GET", "/", headers, "")
    setip!(req, context_ip)
    return req
end

const PROXY  = IPv4("127.0.0.1")
const CLIENT = IPv4("203.0.113.7")
const SPOOF  = IPv4("9.9.9.9")

# Shorthand for the standard "one local proxy writing X-Forwarded-For" configuration.
xff(req; proxies = [PROXY]) =
    extract_ip(req; forwarded_header = :x_forwarded_for, trusted_proxies = proxies)

@testset "Secure default: forwarding headers are ignored" begin
    peer = IPv4("192.168.1.100")

    @test extract_ip(create_request(["X-Forwarded-For" => "203.0.113.1"], peer)) == peer
    @test extract_ip(create_request(["X-Real-IP" => "203.0.113.2"], peer)) == peer
    @test extract_ip(create_request(["CF-Connecting-IP" => "203.0.113.3"], peer)) == peer
    @test extract_ip(create_request(["True-Client-IP" => "203.0.113.4"], peer)) == peer

    # All four at once still cannot move the resolved address.
    @test extract_ip(create_request([
        "CF-Connecting-IP" => "203.0.113.3",
        "True-Client-IP"   => "203.0.113.4",
        "X-Forwarded-For"  => "203.0.113.1",
        "X-Real-IP"        => "203.0.113.2",
    ], peer)) == peer
end

@testset "Regression #16: a client cannot choose its own IP" begin
    # THE BUG. Under the old leftmost-wins rule this returned 9.9.9.9 — the value the client
    # prepended before nginx appended the address it actually saw.
    @test xff(create_request(["X-Forwarded-For" => "$SPOOF, $CLIENT"], PROXY)) == CLIENT

    # Rotating the spoofed prefix must not change the answer; this is what defeated per-IP
    # rate limiting, because every rotation minted a fresh bucket key.
    @test xff(create_request(["X-Forwarded-For" => "8.8.8.8, $CLIENT"], PROXY)) == CLIENT
    @test xff(create_request(["X-Forwarded-For" => "1.2.3.4, 5.6.7.8, $CLIENT"], PROXY)) == CLIENT

    # THE SECOND BUG. CF-Connecting-IP and True-Client-IP used to outrank X-Forwarded-For
    # unconditionally, so a client could bypass a correct XFF setup entirely. Only the header
    # the operator declared is read now.
    @test xff(create_request([
        "CF-Connecting-IP" => "$SPOOF",
        "True-Client-IP"   => "$SPOOF",
        "X-Real-IP"        => "$SPOOF",
        "X-Forwarded-For"  => "$CLIENT",
    ], PROXY)) == CLIENT

    # A declared vendor header is likewise the only one consulted.
    @test extract_ip(create_request([
        "X-Forwarded-For"  => "$SPOOF",
        "CF-Connecting-IP" => "$CLIENT",
    ], PROXY); forwarded_header = :cf_connecting_ip, trusted_proxies = [PROXY]) == CLIENT
end

@testset "Regression #16: a repeated header line cannot shadow the proxy's" begin
    # HTTP.jl folds duplicate header lines only when they are ADJACENT (`appendheader` compares
    # against `entries[end]`). A client-sent X-Forwarded-For separated from the proxy-appended
    # one by any other field therefore survives as its own entry — and reading only the first
    # handed the client the result. HAProxy's `option forwardfor` appends a new line rather than
    # rewriting, so this is a real topology.
    #
    # NOTE: build these with `push!`, not the HTTP.Request constructor — the constructor folds
    # the pairs into one comma-joined value, which would make this test pass either way.
    function raw_request(pairs, peer)
        req = HTTP.Request("GET", "/", [], "")
        empty!(req.headers)
        for (k, v) in pairs
            push!(req.headers, k => v)
        end
        setip!(req, peer)
        return req
    end

    split_xff = raw_request(["Host"            => "example.test",
                             "X-Forwarded-For" => "$SPOOF",     # written by the client
                             "User-Agent"      => "curl/8",     # breaks adjacency
                             "X-Forwarded-For" => "$CLIENT"],   # appended by the proxy
                            PROXY)
    # Sanity: the two lines really did survive separately, or this test proves nothing.
    @test count(p -> lowercase(first(p)) == "x-forwarded-for", split_xff.headers) == 2
    @test xff(split_xff) == CLIENT

    # Three lines, only the last written by our proxy.
    @test xff(raw_request(["X-Forwarded-For" => "$SPOOF",
                           "Accept"          => "*/*",
                           "X-Forwarded-For" => "8.8.8.8",
                           "Accept-Encoding" => "gzip",
                           "X-Forwarded-For" => "$CLIENT"], PROXY)) == CLIENT

    # Single-valued headers take the LAST instance — proxies append or replace, so the last one
    # present is the one written closest to us.
    @test extract_ip(raw_request(["X-Real-IP"  => "$SPOOF",
                                  "Host"       => "example.test",
                                  "X-Real-IP"  => "$CLIENT"], PROXY);
                     forwarded_header = :x_real_ip, trusted_proxies = [PROXY]) == CLIENT
end

@testset "Trust is gated on the socket peer" begin
    direct = IPv4("203.0.113.99")

    # Relayed by a trusted proxy → the declared header is honored.
    @test xff(create_request(["X-Forwarded-For" => "192.0.2.5"], PROXY)) == IPv4("192.0.2.5")

    # Same header, peer is NOT a trusted proxy → ignored entirely.
    @test xff(create_request(["X-Forwarded-For" => "192.0.2.5"], direct)) == direct
end

@testset "X-Forwarded-For walks right-to-left, peeling known hops" begin
    inner = IPv4("10.0.0.8")

    # Two of our own proxies in the chain; both peeled, the client is what remains.
    @test xff(create_request(["X-Forwarded-For" => "$CLIENT, $inner"], PROXY);
              proxies = [PROXY, inner]) == CLIENT
    @test xff(create_request(["X-Forwarded-For" => "$SPOOF, $CLIENT, $inner"], PROXY);
              proxies = [PROXY, inner]) == CLIENT

    # Every entry is one of ours → the request came from inside the estate; fall back to the
    # peer rather than believing the leftmost value.
    @test xff(create_request(["X-Forwarded-For" => "$inner"], PROXY);
              proxies = [PROXY, inner]) == PROXY
    @test xff(create_request(["X-Forwarded-For" => "10.0.0.9, $inner"], PROXY);
              proxies = [PROXY, "10.0.0.0/24"]) == PROXY

    # An unreadable hop aborts the walk. Skipping it would hand back the attacker's prefix.
    @test xff(create_request(["X-Forwarded-For" => "$SPOOF, junk"], PROXY)) == PROXY
    @test xff(create_request(["X-Forwarded-For" => "$SPOOF, junk, $CLIENT"], PROXY)) == CLIENT

    # Blank entries from ",," or a trailing comma are tolerated, not treated as opaque.
    @test xff(create_request(["X-Forwarded-For" => "$CLIENT, "], PROXY)) == CLIENT
    @test xff(create_request(["X-Forwarded-For" => "$CLIENT,,"], PROXY)) == CLIENT

    # ...but a NON-blank entry that normalizes to nothing is opaque, not blank. `[]` strips to
    # an empty string; skipping it would let an attacker step over the boundary entry and reach
    # the value they prepended.
    @test xff(create_request(["X-Forwarded-For" => "$SPOOF, []"], PROXY)) == PROXY
    @test xff(create_request(["X-Forwarded-For" => "$SPOOF, [ ]"], PROXY)) == PROXY
    @test xff(create_request(["X-Forwarded-For" => "$SPOOF, [junk]"], PROXY)) == PROXY

    # Nothing usable at all → peer.
    @test xff(create_request(["X-Forwarded-For" => ""], PROXY)) == PROXY
    @test xff(create_request(String[], PROXY)) == PROXY
end

@testset "Entries may carry a port" begin
    @test xff(create_request(["X-Forwarded-For" => "$CLIENT:1234"], PROXY)) == CLIENT
    @test xff(create_request(["X-Forwarded-For" => "[2001:db8::1]:443"], PROXY)) == IPv6("2001:db8::1")
    # A bare IPv6 address (more than one colon, no brackets) is untouched.
    @test xff(create_request(["X-Forwarded-For" => "2001:db8::1"], PROXY)) == IPv6("2001:db8::1")
end

@testset "Single-value headers are taken as written by the proxy" begin
    for (sym, name) in ((:x_real_ip, "X-Real-IP"),
                        (:cf_connecting_ip, "CF-Connecting-IP"),
                        (:true_client_ip, "True-Client-IP"))
        @test extract_ip(create_request([name => "$CLIENT"], PROXY);
                         forwarded_header = sym, trusted_proxies = [PROXY]) == CLIENT
        # Unparseable → peer, never a throw.
        @test extract_ip(create_request([name => "not-an-ip"], PROXY);
                         forwarded_header = sym, trusted_proxies = [PROXY]) == PROXY
        # Absent → peer.
        @test extract_ip(create_request(String[], PROXY);
                         forwarded_header = sym, trusted_proxies = [PROXY]) == PROXY
    end

    # Header names match case-insensitively.
    @test extract_ip(create_request(["cf-connecting-ip" => "$CLIENT"], PROXY);
                     forwarded_header = :cf_connecting_ip, trusted_proxies = [PROXY]) == CLIENT
end

@testset "CIDR ranges in trusted_proxies" begin
    # A k8s-style pod CIDR: the peer is a proxy only if it falls inside the range.
    @test extract_ip(create_request(["X-Forwarded-For" => "$CLIENT"], IPv4("10.244.3.9"));
                     forwarded_header = :x_forwarded_for,
                     trusted_proxies = ["10.244.0.0/16"]) == CLIENT
    @test extract_ip(create_request(["X-Forwarded-For" => "$CLIENT"], IPv4("10.245.3.9"));
                     forwarded_header = :x_forwarded_for,
                     trusted_proxies = ["10.244.0.0/16"]) == IPv4("10.245.3.9")

    # Boundary prefix lengths.
    @test xff(create_request(["X-Forwarded-For" => "$CLIENT"], IPv4("10.1.2.3"));
              proxies = ["10.0.0.0/8"]) == CLIENT
    @test xff(create_request(["X-Forwarded-For" => "$CLIENT"], IPv4("10.0.0.1"));
              proxies = ["10.0.0.0/31"]) == CLIENT
    @test xff(create_request(["X-Forwarded-For" => "$CLIENT"], IPv4("10.0.0.2"));
              proxies = ["10.0.0.0/31"]) == IPv4("10.0.0.2")
    @test xff(create_request(["X-Forwarded-For" => "$CLIENT"], IPv4("10.0.0.1"));
              proxies = ["10.0.0.1/32"]) == CLIENT

    # Host bits in the literal are masked off, as in Python's ipaddress(strict=false).
    @test xff(create_request(["X-Forwarded-For" => "$CLIENT"], IPv4("10.1.2.3"));
              proxies = ["10.0.0.1/8"]) == CLIENT

    # IPv6 ranges, e.g. a published CDN prefix.
    @test xff(create_request(["X-Forwarded-For" => "$CLIENT"], IPv6("2400:cb00::1"));
              proxies = ["2400:cb00::/32"]) == CLIENT

    # Families never cross: an IPv4 range must not match an IPv6 peer or vice versa.
    @test xff(create_request(["X-Forwarded-For" => "$CLIENT"], IPv6("2400:cb00::1"));
              proxies = ["10.0.0.0/8"]) == IPv6("2400:cb00::1")
    @test xff(create_request(["X-Forwarded-For" => "$CLIENT"], IPv4("10.1.2.3"));
              proxies = ["2400:cb00::/32"]) == IPv4("10.1.2.3")

    # A trusted proxy appearing mid-chain is peeled by CIDR too.
    @test xff(create_request(["X-Forwarded-For" => "$CLIENT, 10.244.9.9"], IPv4("10.244.3.9"));
              proxies = ["10.244.0.0/16"]) == CLIENT
end

@testset "IPv4-mapped IPv6 peers match IPv4 proxies" begin
    # A dual-stack listener reports an IPv4 peer as ::ffff:127.0.0.1 on some platforms. Without
    # demotion this silently fails to match and every client collapses onto one bucket.
    @test xff(create_request(["X-Forwarded-For" => "$CLIENT"], IPv6("::ffff:127.0.0.1"))) == CLIENT
    @test xff(create_request(["X-Forwarded-For" => "$CLIENT"], IPv6("::ffff:10.244.3.9"));
              proxies = ["10.244.0.0/16"]) == CLIENT
    # A mapped address in the chain is peeled against its IPv4 form as well.
    @test xff(create_request(["X-Forwarded-For" => "$CLIENT, ::ffff:10.0.0.8"], PROXY);
              proxies = [PROXY, "10.0.0.0/24"]) == CLIENT

    # A mapped client is RETURNED in canonical IPv4 form. Otherwise the four spellings of one
    # host become four distinct rate-limit bucket keys and four access-log strings.
    @test xff(create_request(["X-Forwarded-For" => "::ffff:203.0.113.7"], PROXY)) == CLIENT
    @test xff(create_request(["X-Forwarded-For" => "::ffff:203.0.113.7"], PROXY)) isa IPv4
    @test extract_ip(create_request(["X-Real-IP" => "::ffff:203.0.113.7"], PROXY);
                     forwarded_header = :x_real_ip, trusted_proxies = [PROXY]) == CLIENT
    # A genuine IPv6 client is untouched.
    @test xff(create_request(["X-Forwarded-For" => "2001:db8::1"], PROXY)) == IPv6("2001:db8::1")
end

@testset "Requests with no peer address" begin
    # A hand-built request that never went through the server has no :ip at all.
    bare = HTTP.Request("GET", "/", ["X-Forwarded-For" => "$SPOOF"], "")
    @test extract_ip(bare) === nothing
    @test extract_ip(bare; forwarded_header = :x_forwarded_for,
                     trusted_proxies = [PROXY]) === nothing
end

@testset "The ExtractIP middleware closure" begin
    seen = Ref{Union{HTTP.Request, Nothing}}(nothing)
    handler = req -> (seen[] = req; HTTP.Response(200))

    # Proxied request: :ip becomes the client, the socket peer is preserved.
    mw = ExtractIP(forwarded_header = :x_forwarded_for, trusted_proxies = [PROXY])
    mw(handler)(create_request(["X-Forwarded-For" => "$SPOOF, $CLIENT"], PROXY))
    @test getip(seen[]) == CLIENT
    @test getpeerip(seen[]) == PROXY

    # Default configuration: the client IP is the peer, and getpeerip agrees.
    ExtractIP()(handler)(create_request(["X-Forwarded-For" => "$SPOOF"], CLIENT))
    @test getip(seen[]) == CLIENT
    @test getpeerip(seen[]) == CLIENT

    # Without ExtractIP at all, getpeerip still reports what serve() seeded.
    @test getpeerip(create_request(String[], CLIENT)) == CLIENT

    # A request with no peer must not have `nothing` written into :ip.
    bare = HTTP.Request("GET", "/", String[], "")
    ExtractIP()(handler)(bare)
    @test getip(seen[]) === nothing
    @test !haskey(bare.context, :ip)
end

@testset "Misconfiguration is rejected at construction" begin
    # trust_forwarded trusted headers from any peer and guessed the header — removed outright.
    @test_throws ArgumentError ExtractIP(trust_forwarded = true)
    @test_throws ArgumentError ExtractIP(trust_forwarded = false)

    # V1 — a typo would silently never match.
    @test_throws ArgumentError ExtractIP(forwarded_header = :x_forwaded_for,
                                         trusted_proxies = [PROXY])
    # V2 — a trust boundary with no header named reads nothing.
    @test_throws ArgumentError ExtractIP(trusted_proxies = [PROXY])
    # V3 — a header with no trust boundary is honored from any client.
    @test_throws ArgumentError ExtractIP(forwarded_header = :x_forwarded_for)
    # V4 — an empty list looks configured but trusts nobody.
    @test_throws ArgumentError ExtractIP(forwarded_header = :x_forwarded_for,
                                         trusted_proxies = [])
    # V5 — an unparseable entry would silently leave a proxy untrusted.
    @test_throws ArgumentError ExtractIP(forwarded_header = :x_forwarded_for,
                                         trusted_proxies = ["nope"])
    @test_throws ArgumentError ExtractIP(forwarded_header = :x_forwarded_for,
                                         trusted_proxies = [42])
    @test_throws ArgumentError ExtractIP(forwarded_header = :x_forwarded_for,
                                         trusted_proxies = ["10.0.0.0/xx"])
    # V6 — prefix length outside the family's range.
    @test_throws ArgumentError ExtractIP(forwarded_header = :x_forwarded_for,
                                         trusted_proxies = ["10.0.0.0/33"])
    @test_throws ArgumentError ExtractIP(forwarded_header = :x_forwarded_for,
                                         trusted_proxies = ["2400:cb00::/129"])
    # V7 — a catch-all range trusts the header from every peer on the internet.
    @test_throws ArgumentError ExtractIP(forwarded_header = :x_forwarded_for,
                                         trusted_proxies = ["0.0.0.0/0"])
    @test_throws ArgumentError ExtractIP(forwarded_header = :x_forwarded_for,
                                         trusted_proxies = ["::/0"])

    # The same rules apply to the bare resolver, not just the middleware.
    @test_throws ArgumentError extract_ip(create_request(String[], PROXY); trust_forwarded = true)
    @test_throws ArgumentError extract_ip(create_request(String[], PROXY);
                                          trusted_proxies = [PROXY])

    # The safe configuration stays the default one — this must not throw.
    @test ExtractIP() isa Function
    # Mixed IPAddr / CIDR-string literals are accepted.
    @test ExtractIP(forwarded_header = :x_real_ip,
                    trusted_proxies = [PROXY, "10.244.0.0/16"]) isa Function
end

end
