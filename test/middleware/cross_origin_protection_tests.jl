@testitem "CrossOriginProtection — tokenless Fetch Metadata check (#437)" tags=[:middleware, :security, :csrf] setup=[NitroCommon] begin

using HTTP
using Nitro
using Nitro: CrossOriginProtection
using Nitro.Core: internalrequest
import Nitro: App, path, text

# Go 1.25's `net/http.CrossOriginProtection`, check for check: `Sec-Fetch-Site` first, then the
# `Origin`-vs-`Host` fallback for older browsers, then the exemptions. Every testset drives the
# layer directly, except the last, which goes through a real app pipeline.

reached = Ref(0)
ok_handler(req) = (reached[] += 1; HTTP.Response(200, "ok"))
layer(; kwargs...) = CrossOriginProtection(; kwargs...)(ok_handler)
req(method, headers...; target = "/form") = HTTP.Request(method, target, Pair{String,String}[headers...])
status(l, r) = l(r).status

const H = "Host" => "api.example.com"

@testset "safe methods always pass" begin
    l = layer()
    for m in ("GET", "HEAD", "OPTIONS", "TRACE")
        @test status(l, req(m, H, "Sec-Fetch-Site" => "cross-site", "Origin" => "https://evil.example")) == 200
    end
end

@testset "Sec-Fetch-Site decides when present" begin
    l = layer()
    @test status(l, req("POST", H, "Sec-Fetch-Site" => "same-origin")) == 200
    @test status(l, req("POST", H, "Sec-Fetch-Site" => "none")) == 200          # typed URL, bookmark
    @test status(l, req("POST", H, "Sec-Fetch-Site" => "cross-site")) == 403
    @test status(l, req("PUT",  H, "Sec-Fetch-Site" => "same-site")) == 403     # a sibling subdomain
    @test status(l, req("DELETE", H, "Sec-Fetch-Site" => "garbage")) == 403
    # The header wins over a same-host Origin: a cross-site page cannot argue its way in.
    @test status(l, req("POST", H, "Sec-Fetch-Site" => "cross-site",
                        "Origin" => "https://api.example.com")) == 403
    # Two adjacent Sec-Fetch-Site lines: HTTP.jl folds them into "same-origin,cross-site", which
    # is no allowed value, so the request is refused.
    @test status(l, req("POST", H, "Sec-Fetch-Site" => "same-origin", "Sec-Fetch-Site" => "cross-site")) == 403
    # Non-adjacent ones stay separate entries; the layer joins them itself, with the same result.
    @test status(l, req("POST", H, "Sec-Fetch-Site" => "same-origin", "X-Other" => "1",
                        "Sec-Fetch-Site" => "cross-site")) == 403
    @test status(l, req("POST", H, "Origin" => "https://api.example.com", "X-Other" => "1",
                        "Origin" => "https://api.example.com")) == 403

    r = l(req("POST", H, "Sec-Fetch-Site" => "cross-site"))
    @test r.status == 403
    @test occursin("Cross-origin request refused", String(r.body))
end

@testset "without Sec-Fetch-Site, Origin must match Host" begin
    l = layer()
    @test status(l, req("POST", H, "Origin" => "https://api.example.com")) == 200
    @test status(l, req("POST", H, "Origin" => "https://API.Example.COM")) == 200       # case-folded
    @test status(l, req("POST", "Host" => "API.example.com", "Origin" => "https://api.example.com")) == 200
    @test status(l, req("POST", H, "Origin" => "http://api.example.com")) == 200        # scheme ignored, as Go
    @test status(l, req("POST", "Host" => "api.example.com:8443", "Origin" => "https://api.example.com:8443")) == 200
    @test status(l, req("POST", "Host" => "api.example.com:443", "Origin" => "https://api.example.com")) == 200
    @test status(l, req("POST", "Host" => "[::1]:8080", "Origin" => "http://[0:0::1]:8080")) == 200

    @test status(l, req("POST", H, "Origin" => "https://evil.example")) == 403
    @test status(l, req("POST", H, "Origin" => "https://api.example.com:8443")) == 403  # port differs
    @test status(l, req("POST", "Host" => "api.example.com:8443", "Origin" => "https://api.example.com")) == 403
    @test status(l, req("POST", H, "Origin" => "https://evil-api.example.com")) == 403
    @test status(l, req("POST", H, "Origin" => "null")) == 403                          # sandboxed frame
    @test status(l, req("POST", "Origin" => "https://api.example.com")) == 403              # no Host to match
    @test status(l, req("POST", "Host" => "api.example.com/x", "Origin" => "https://api.example.com")) == 403
end

@testset "neither header: a non-browser client passes" begin
    @test status(layer(), req("POST", H)) == 200
    @test status(layer(), req("POST")) == 200
    # An empty value is absent, as Go's `Header.Get` reads it.
    @test status(layer(), req("POST", H, "Sec-Fetch-Site" => "", "Origin" => "")) == 200
end

@testset "trusted origins admit a cross-origin page" begin
    l = layer(trusted_origins = ["https://app.example.com", "https://admin.example.com:8443"])
    @test status(l, req("POST", H, "Sec-Fetch-Site" => "same-site", "Origin" => "https://app.example.com")) == 200
    @test status(l, req("POST", H, "Sec-Fetch-Site" => "cross-site", "Origin" => "https://APP.example.com")) == 200
    @test status(l, req("POST", H, "Origin" => "https://app.example.com")) == 200           # fallback path too
    @test status(l, req("POST", H, "Origin" => "https://admin.example.com:8443")) == 200
    # Exact on scheme, host and port.
    @test status(l, req("POST", H, "Sec-Fetch-Site" => "same-site", "Origin" => "http://app.example.com")) == 403
    @test status(l, req("POST", H, "Sec-Fetch-Site" => "same-site", "Origin" => "https://app.example.com:444")) == 403
    @test status(l, req("POST", H, "Sec-Fetch-Site" => "cross-site", "Origin" => "https://evil-app.example.com")) == 403
    # A trusted origin needs an Origin header to name it.
    @test status(l, req("POST", H, "Sec-Fetch-Site" => "cross-site")) == 403
end

@testset "exempt paths cover whole segments" begin
    l = layer(exempt_paths = ["/hooks"])
    cross = "Sec-Fetch-Site" => "cross-site"
    @test status(l, req("POST", H, cross; target = "/hooks")) == 200
    @test status(l, req("POST", H, cross; target = "/hooks/github")) == 200
    @test status(l, req("POST", H, cross; target = "/hooks?id=1")) == 200
    @test status(l, req("POST", H, cross; target = "/hooksadmin")) == 403
    @test status(l, req("POST", H, cross; target = "/form")) == 403
end

@testset "construction refuses what could never match" begin
    for bad in ("*", "null", "https://app.example.com/", "app.example.com", "wss://app.example.com",
                "https://app.example.com/path", "https://user@app.example.com", "https://café.example")
        @test_throws ArgumentError CrossOriginProtection(trusted_origins = [bad])
    end
    @test_throws ArgumentError CrossOriginProtection(exempt_paths = ["hooks"])
    @test CrossOriginProtection(trusted_origins = ["https://app.example.com:443"]) isa Function
    # Any vector of strings, as `WebSocketOrigins` takes.
    sub = SubString("https://app.example.com/hooks", 1, 23)
    l = layer(trusted_origins = [sub], exempt_paths = [SubString("/hooks/x", 1, 6)])
    @test status(l, req("POST", H, "Sec-Fetch-Site" => "cross-site", "Origin" => "https://app.example.com")) == 200
    @test status(l, req("POST", H, "Sec-Fetch-Site" => "cross-site"; target = "/hooks")) == 200
end

@testset "malformed UTF-8 in a header is a refusal, never a 500" begin
    l = layer(trusted_origins = ["https://app.example.com"])
    reached[] = 0
    @test status(l, req("POST", H, "Origin" => "https://a\xffb.example.com")) == 403
    @test status(l, req("POST", H, "Origin" => "http://api.example.com\xff")) == 403
    @test status(l, req("POST", "Host" => "api.example.com\xff", "Origin" => "https://api.example.com")) == 403
    @test status(l, req("POST", H, "Sec-Fetch-Site" => "same-origin\xff")) == 403
    @test status(l, req("POST", H, "Sec-Fetch-Site" => "cross-site", "Origin" => "https://app.example.com\xff")) == 403
    @test reached[] == 0
    # The shared parser behind it, which the WebSocket origin list reads through as well.
    @test Nitro.Core.Types._parse_origin("https://a\xffb.example.com")[1] === nothing
end

@testset "in a real app pipeline" begin
    app = App(mod = @__MODULE__)
    urlpatterns(app, "", path("/items", r -> "made"; method = "POST"))
    mw = [CrossOriginProtection()]
    same = HTTP.Request("POST", "/items", ["Host" => "shop.example", "Sec-Fetch-Site" => "same-origin"])
    cross = HTTP.Request("POST", "/items", ["Host" => "shop.example", "Sec-Fetch-Site" => "cross-site"])
    r = internalrequest(app, same; middleware = mw)
    @test r.status == 200
    @test text(r) == "made"
    @test internalrequest(app, cross; middleware = mw).status == 403
end

end
