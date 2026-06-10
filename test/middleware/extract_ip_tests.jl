@testitem "Extract IP" tags=[:middleware] setup=[NitroCommon] begin
using HTTP
using Sockets
using Nitro: setip!
using Nitro.Middleware: extract_ip

# Helper function to create a request with specific headers and context IP
function create_request(headers, context_ip::IPAddr = IPv4("127.0.0.1"))
    req = HTTP.Request("GET", "/", headers, "")
    setip!(req, context_ip)
    return req
end

@testset "Secure default: forwarding headers are ignored" begin
    # Without trust configured, spoofable headers must NOT influence the result.
    # The socket peer address always wins. This is what prevents rate-limit /
    # audit-log bypass via a forged X-Forwarded-For.
    peer = IPv4("198.51.100.7")

    @test extract_ip(create_request(["CF-Connecting-IP" => "192.168.1.100"], peer)) == peer
    @test extract_ip(create_request(["True-Client-IP" => "10.0.0.50"], peer)) == peer
    @test extract_ip(create_request(["X-Forwarded-For" => "203.0.113.1"], peer)) == peer
    @test extract_ip(create_request(["X-Real-IP" => "172.16.0.10"], peer)) == peer

    # Explicit opt-out is equivalent to the default.
    @test extract_ip(create_request(["X-Forwarded-For" => "203.0.113.1"], peer); trust_forwarded=false) == peer
end

@testset "trust_forwarded=true honors headers in priority order" begin
    @testset "CF-Connecting-IP header (highest priority)" begin
        req = create_request(["CF-Connecting-IP" => "192.168.1.100"])
        @test extract_ip(req; trust_forwarded=true) == IPv4("192.168.1.100")
    end

    @testset "True-Client-IP header (priority 2)" begin
        req = create_request(["True-Client-IP" => "10.0.0.50"])
        @test extract_ip(req; trust_forwarded=true) == IPv4("10.0.0.50")
    end

    @testset "X-Forwarded-For header (priority 3, single IP)" begin
        req = create_request(["X-Forwarded-For" => "203.0.113.1"])
        @test extract_ip(req; trust_forwarded=true) == IPv4("203.0.113.1")
    end

    @testset "X-Forwarded-For header (priority 3, multiple IPs, use first)" begin
        req = create_request(["X-Forwarded-For" => "203.0.113.1, 198.51.100.2, 192.0.2.3"])
        @test extract_ip(req; trust_forwarded=true) == IPv4("203.0.113.1")
    end

    @testset "X-Forwarded-For header (priority 3, with spaces)" begin
        req = create_request(["X-Forwarded-For" => " 203.0.113.1 , 198.51.100.2 "])
        @test extract_ip(req; trust_forwarded=true) == IPv4("203.0.113.1")
    end

    @testset "X-Real-IP header (priority 4)" begin
        req = create_request(["X-Real-IP" => "172.16.0.10"])
        @test extract_ip(req; trust_forwarded=true) == IPv4("172.16.0.10")
    end

    @testset "Priority order: CF-Connecting-IP overrides others" begin
        req = create_request([
            "X-Forwarded-For" => "203.0.113.1",
            "CF-Connecting-IP" => "192.168.1.100",
            "True-Client-IP" => "10.0.0.50"
        ])
        @test extract_ip(req; trust_forwarded=true) == IPv4("192.168.1.100")
    end

    @testset "Priority order: True-Client-IP overrides X-Forwarded-For and X-Real-IP" begin
        req = create_request([
            "X-Forwarded-For" => "203.0.113.1",
            "X-Real-IP" => "172.16.0.10",
            "True-Client-IP" => "10.0.0.50"
        ])
        @test extract_ip(req; trust_forwarded=true) == IPv4("10.0.0.50")
    end

    @testset "Priority order: X-Forwarded-For overrides X-Real-IP" begin
        req = create_request([
            "X-Real-IP" => "172.16.0.10",
            "X-Forwarded-For" => "203.0.113.1"
        ])
        @test extract_ip(req; trust_forwarded=true) == IPv4("203.0.113.1")
    end

    @testset "Fallback to getip(req) when no headers" begin
        req = create_request([], IPv4("127.0.0.1"))
        @test extract_ip(req; trust_forwarded=true) == IPv4("127.0.0.1")
    end

    @testset "Fallback to getip(req) when headers are empty" begin
        req = create_request(["X-Forwarded-For" => ""], IPv4("127.0.0.1"))
        @test extract_ip(req; trust_forwarded=true) == IPv4("127.0.0.1")
    end

    @testset "Malformed header falls back to peer instead of throwing" begin
        req = create_request(["X-Forwarded-For" => "not-an-ip"], IPv4("127.0.0.1"))
        @test extract_ip(req; trust_forwarded=true) == IPv4("127.0.0.1")
    end

    @testset "IPv6 support" begin
        req = create_request(["CF-Connecting-IP" => "2001:db8::1"])
        @test extract_ip(req; trust_forwarded=true) == IPv6("2001:db8::1")
    end

    @testset "Case insensitive header matching" begin
        req = create_request(["cf-connecting-ip" => "192.168.1.100"])  # lowercase
        @test extract_ip(req; trust_forwarded=true) == IPv4("192.168.1.100")
    end
end

@testset "trusted_proxies gates header trust by socket peer" begin
    proxy = IPv4("127.0.0.1")
    direct_client = IPv4("203.0.113.99")

    # Request relayed by a trusted proxy → forwarding header is honored.
    req = create_request(["X-Forwarded-For" => "192.0.2.5"], proxy)
    @test extract_ip(req; trusted_proxies=[proxy]) == IPv4("192.0.2.5")

    # Same header, but the peer is NOT a trusted proxy → header is ignored.
    req = create_request(["X-Forwarded-For" => "192.0.2.5"], direct_client)
    @test extract_ip(req; trusted_proxies=[proxy]) == direct_client
end

end
