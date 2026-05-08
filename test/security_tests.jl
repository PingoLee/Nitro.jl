@testitem "Security: Crypto Robustness" tags=[:security, :core] setup=[NitroCommon] begin
using Nitro
using Test
using HTTP

@testset "Security: Crypto Robustness" begin
    res = HTTP.Response(200)
    # This should succeed without error since cryptography is built-in
    set_cookie!(res, "session", "secret-data", secret_key="my-key")
    @test length(res.headers) == 1
    cookie_header = res.headers[1][2]
    @test contains(cookie_header, "session=")

    req = HTTP.Request("GET", "/", ["Cookie" => cookie_header])
    # Should decrypt properly
    val = get_cookie(req, "session", encrypted=true, secret_key="my-key")
    @test val == "secret-data"

    # Should fail if bad key
    @test_throws Nitro.Core.Errors.CookieError get_cookie(req, "session", encrypted=true, secret_key="wrong-key")

    # Encrypted operations should fail closed when the key is missing or empty
    @test_throws Nitro.Core.Errors.CookieError set_cookie!(HTTP.Response(200), "session", "secret-data", encrypted=true)
    @test_throws Nitro.Core.Errors.CookieError set_cookie!(HTTP.Response(200), "session", "secret-data", encrypted=true, secret_key="")
    @test_throws Nitro.Core.Errors.CookieError get_cookie(HTTP.Request("GET", "/", ["Cookie" => "session=plaintext"]), "session", encrypted=true)
    @test_throws Nitro.Core.Errors.CookieError get_cookie(HTTP.Request("GET", "/", ["Cookie" => "session=plaintext"]), "session", encrypted=true, secret_key="")
end

@testset "Security: Cookie Header Validation" begin
    @test_throws ArgumentError set_cookie!(HTTP.Response(200), "bad;name", "value", encrypted=false)
    @test_throws ArgumentError set_cookie!(HTTP.Response(200), "session", "abc; Domain=evil.com", encrypted=false)
    @test_throws ArgumentError set_cookie!(HTTP.Response(200), "session", "abc\r\nSet-Cookie: other=value", encrypted=false)
    @test_throws ArgumentError set_cookie!(HTTP.Response(200), "session", "value", path="/api;Secure", encrypted=false)
end
end
