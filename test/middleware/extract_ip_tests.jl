@testitem "Extract IP" tags=[:middleware] setup=[NitroCommon] begin
using HTTP
using Sockets
using Dates
using Nitro: setip!, getip, getpeerip, ExtractIP, RateLimiter
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
    # Trust matching folds the mapped form, and must keep doing so after #66. The transport no
    # longer hands this layer a mapped PEER (see the pass-through test below), but a mapped
    # address still reaches `_norm` from a chain hop, from a `trusted_proxies` literal, and from
    # any middleware that wrote one with `setip!` — which is what the peers below stand in for.
    # Without the fold these silently fail to match and every client collapses onto one bucket.
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

    # ExtractIP does NOT canonicalize the peer, and that is correct since #66: the socket
    # peer arrives already demoted from `_ipaddr_from_bytes` in src/core/transport.jl, so
    # this layer has nothing to do. Seeding a mapped address directly — which only a custom
    # middleware calling `setip!` can now produce — must therefore pass straight through.
    # This pins the pass-through property option (b) in #66 would have cost, and is what
    # stops the demotion being moved back up into the middleware later.
    MAPPED = IPv6("::ffff:203.0.113.7")
    ExtractIP()(handler)(create_request(String[], MAPPED))
    @test getip(seen[]) === MAPPED
    @test getpeerip(seen[]) === MAPPED

    # A request with no peer must not have `nothing` written into :ip.
    bare = HTTP.Request("GET", "/", String[], "")
    ExtractIP()(handler)(bare)
    @test getip(seen[]) === nothing
    @test !haskey(bare.context, :ip)
end

@testset "Regression #330: a second extractor cannot rewrite the socket peer" begin
    seen = Ref{Union{HTTP.Request, Nothing}}(nothing)
    handler = req -> (seen[] = req; HTTP.Response(200))
    FORWARDED = IPv4("6.6.6.6")
    trusted() = ExtractIP(forwarded_header = :x_forwarded_for, trusted_proxies = ["127.0.0.0/8"])
    proxied() = create_request(["X-Forwarded-For" => "$FORWARDED"], PROXY)

    # THE BUG: the second extractor read `getip` -- by then the forwarded address -- and
    # recorded it as the socket peer, so a client-chosen value reached `getpeerip`.
    trusted()(ExtractIP()(handler))(proxied())
    @test getip(seen[]) == FORWARDED
    @test getpeerip(seen[]) == PROXY

    # Two identical trusted extractors: the second judges the client the first resolved, does
    # not trust it, and leaves it alone.
    trusted()(trusted()(handler))(proxied())
    @test getip(seen[]) == FORWARDED
    @test getpeerip(seen[]) == PROXY

    # Reversed: a no-trust extractor first changes nothing the trusted one relies on.
    ExtractIP()(trusted()(handler))(proxied())
    @test getip(seen[]) == FORWARDED
    @test getpeerip(seen[]) == PROXY

    # The shape the issue reports: a global ExtractIP plus a RateLimiter at its default
    # `auto_extract_ip = true`, which builds an extractor of its own with no trust configured.
    # The limiter must key on the resolved client, and the peer must stay the proxy.
    limiter = RateLimiter(rate_limit = 100, window = Minute(1)).middleware
    trusted()(limiter(handler))(proxied())
    @test getip(seen[]) == FORWARDED
    @test getpeerip(seen[]) == PROXY

    # A client talking to the server directly is unaffected by the stacking: both addresses
    # stay the socket peer, whatever it sends.
    trusted()(ExtractIP()(handler))(create_request(["X-Forwarded-For" => "$SPOOF"], CLIENT))
    @test getip(seen[]) == CLIENT
    @test getpeerip(seen[]) == CLIENT

    # Mismatched trust lists: a global extractor trusting a k8s ingress CIDR, and a limiter
    # whose own `trusted_proxies` names only loopback. The limiter does not trust the client
    # the global one resolved, so it keeps it -- judging the socket peer instead would reset
    # `getip` to the ingress and put every client in one bucket.
    INGRESS = IPv4("10.244.1.1")
    k8s = ExtractIP(forwarded_header = :x_forwarded_for, trusted_proxies = ["10.244.0.0/16"])
    local_limiter = RateLimiter(rate_limit = 100, window = Minute(1),
                                forwarded_header = :x_forwarded_for,
                                trusted_proxies = [ip"127.0.0.1"]).middleware
    k8s(local_limiter(handler))(create_request(["X-Forwarded-For" => "$CLIENT"], INGRESS))
    @test getip(seen[]) == CLIENT
    @test getpeerip(seen[]) == INGRESS

    # Two tiers with different headers chain: nginx on loopback writes X-Real-IP with the CDN
    # edge it saw, and the CDN writes CF-Connecting-IP. The second extractor believes its header
    # only because the first established a CDN address as the hop.
    EDGE = IPv4("173.245.48.5")
    nginx_tier = ExtractIP(forwarded_header = :x_real_ip, trusted_proxies = [PROXY])
    cdn_tier   = ExtractIP(forwarded_header = :cf_connecting_ip, trusted_proxies = ["173.245.48.0/20"])
    tiers(req) = nginx_tier(cdn_tier(handler))(req)
    tiers(create_request(["X-Real-IP" => "$EDGE", "CF-Connecting-IP" => "$CLIENT"], PROXY))
    @test getip(seen[]) == CLIENT
    @test getpeerip(seen[]) == PROXY
    # The same headers from a client outside both tiers' ranges, connecting directly, are
    # believed by neither tier.
    tiers(create_request(["X-Real-IP" => "$EDGE", "CF-Connecting-IP" => "$SPOOF"], CLIENT))
    @test getip(seen[]) == CLIENT
    @test getpeerip(seen[]) == CLIENT
    # What the docstring warns about: a direct connection FROM the CDN's own ranges is believed
    # by the CDN tier, because the chain has nothing better than the socket peer to judge. Only
    # network placement (nginx the sole way in) keeps this out. Pinned so the docs and the code
    # cannot drift apart.
    tiers(create_request(["CF-Connecting-IP" => "$SPOOF"], EDGE))
    @test getip(seen[]) == SPOOF
    @test getpeerip(seen[]) == EDGE

    # The bare resolver chains the same way: with no trust configured it answers `getip` as the
    # chain left it.
    trusted()(handler)(proxied())
    @test extract_ip(seen[]) == FORWARDED
    @test xff(seen[]) == FORWARDED
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

    # #374 — the scheme header follows the same rules as the address header.
    # A scheme header with no boundary is honored from any client.
    @test_throws ArgumentError ExtractIP(forwarded_proto = :x_forwarded_proto)
    # A typo, and RFC 7239 `Forwarded`, which is not parsed for the address either.
    @test_throws ArgumentError ExtractIP(forwarded_proto = :x_forwaded_proto, trusted_proxies = [PROXY])
    @test_throws "Forwarded" ExtractIP(forwarded_proto = :forwarded, trusted_proxies = [PROXY])
    # A boundary with only the scheme named is a complete configuration: V2 no longer applies.
    @test ExtractIP(forwarded_proto = :x_forwarded_proto, trusted_proxies = [PROXY]) isa Function
    @test ExtractIP(forwarded_header = :x_forwarded_for, forwarded_proto = :x_forwarded_proto,
                    trusted_proxies = [PROXY]) isa Function
end

@testset "forwarded_proto records a trusted proxy's scheme (#374)" begin
    KEY = Nitro.Core.Types.REQUEST_FORWARDED_PROTO_KEY
    seen = Ref{HTTP.Request}()
    handler = req -> (seen[] = req; HTTP.Response(200))
    scheme(req) = get(req.context, KEY, nothing)
    proto_only = ExtractIP(forwarded_proto = :x_forwarded_proto, trusted_proxies = [PROXY])
    through(mw, headers, peer = PROXY) = (mw(handler)(create_request(headers, peer)); seen[])
    via_proxy(value) = scheme(through(proto_only, ["X-Forwarded-Proto" => value]))

    @test via_proxy("https") == "https"
    @test via_proxy("HTTPS") == "https"
    @test via_proxy("http") == "http"
    # A list: the leftmost value is the scheme the client used at the edge.
    @test via_proxy(" https , http") == "https"
    @test scheme(through(proto_only, ["X-Forwarded-Proto" => "https", "X-Other" => "1",
                                      "X-Forwarded-Proto" => "http"])) == "https"
    # Traefik writes the WebSocket schemes on an upgrade.
    @test via_proxy("wss") == "https"
    @test via_proxy("ws") == "http"
    # Not a scheme this server is reachable over: ignored, never guessed.
    @test via_proxy("ftp") === nothing
    @test via_proxy("") === nothing
    @test scheme(through(proto_only, Pair{String,String}[])) === nothing

    # A client connecting directly is not the trusted proxy: its header is ignored.
    @test scheme(through(proto_only, ["X-Forwarded-Proto" => "https"], CLIENT)) === nothing
    # Without `forwarded_proto` the header is never read, trusted peer or not.
    addr_only = ExtractIP(forwarded_header = :x_forwarded_for, trusted_proxies = [PROXY])
    @test scheme(through(addr_only, ["X-Forwarded-Proto" => "https"])) === nothing

    # Scheme-only trust leaves the address alone. Before the fix to `_trust_policy`/`_resolve`
    # this configuration could not be built, and a trusted request would have thrown.
    r = through(proto_only, ["X-Forwarded-Proto" => "https", "X-Forwarded-For" => "$SPOOF"])
    @test getip(r) == PROXY
    @test getpeerip(r) == PROXY
    # Both headers named: both apply.
    both = ExtractIP(forwarded_header = :x_forwarded_for, forwarded_proto = :x_forwarded_proto,
                     trusted_proxies = [PROXY])
    r = through(both, ["X-Forwarded-For" => "$CLIENT", "X-Forwarded-Proto" => "https"])
    @test getip(r) == CLIENT
    @test scheme(r) == "https"

    # A later extractor that reads the scheme but does not trust its hop never clears an earlier
    # one's answer. (A plain `ExtractIP()` would prove nothing: it never looks at the scheme.)
    distrusting = ExtractIP(forwarded_proto = :x_forwarded_proto, trusted_proxies = ["10.0.0.0/8"])
    proto_only(distrusting(handler))(create_request(["X-Forwarded-Proto" => "https"], PROXY))
    @test scheme(seen[]) == "https"
    # Nor does a trusted one whose proxy sent no scheme, or one that is not a scheme.
    for headers in (Pair{String,String}[], ["X-Forwarded-Proto" => "gopher"])
        req = create_request(headers, PROXY)
        req.context[KEY] = "https"          # as an earlier extractor would have left it
        proto_only(handler)(req)
        @test scheme(seen[]) == "https"
    end
end

end

@testitem "internalrequest keeps a caller's client IP (#330)" tags=[:core, :middleware] setup=[NitroCommon] begin
using HTTP
using Sockets
using Nitro: setip!, getip

app = App(mod = @__MODULE__)
stamp = handle -> req -> Nitro.Core.Util.add_response_headers(handle(req), "X-Route-Middleware" => "ran")
urlpatterns(app, "",
    path("/ip", req -> string(getip(req))),
    path("/guarded", req -> "ok"; middleware = [stamp]),
)

# A request with no address is an in-process call, so it is loopback, as before.
@test text(internalrequest(app, HTTP.Request("GET", "/ip"))) == "127.0.0.1"

# THE BUG: an address the caller already set was replaced with loopback, which every
# loopback-trusting check accepts.
req = HTTP.Request("GET", "/ip")
setip!(req, IPv4("203.0.113.7"))
@test text(internalrequest(app, req)) == "203.0.113.7"

# An explicit `nothing` is no address: it still becomes loopback.
blank = HTTP.Request("GET", "/ip")
blank.context[:ip] = nothing
@test text(internalrequest(app, blank)) == "127.0.0.1"

# What the docstring promises: route middleware still runs on an internal request.
res = internalrequest(app, HTTP.Request("GET", "/guarded"))
@test HTTP.header(res, "X-Route-Middleware") == "ran"
end
