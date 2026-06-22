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

@testitem "Security: Access log redacts query strings" tags=[:security, :core] setup=[NitroCommon] begin
using Nitro
using Test
using HTTP

# AccessLogMiddleware must not leak query strings — reset tokens, API keys, OAuth
# `code`/`state`, signed-URL signatures routinely ride there and access logs are
# frequently shipped to third-party aggregators. Only the path is logged by default.
run_once(mw, req) = begin
    logger = Test.TestLogger()
    Base.CoreLogging.with_logger(logger) do
        mw(_req -> HTTP.Response(200))(req)
    end
    logger.logs
end

@testset "query string redacted by default" begin
    logs = run_once(Nitro.Core.AccessLogMiddleware(),
                    HTTP.Request("GET", "/reset?token=SECRET-XYZ&api_key=abc123"))
    @test length(logs) == 1
    msg = logs[1].message
    @test occursin("/reset", msg)        # path is kept
    @test !occursin("SECRET-XYZ", msg)   # token value gone
    @test !occursin("api_key", msg)      # query keys gone
    @test !occursin("token=", msg)
    @test !occursin('?', msg)
end

@testset "log_query=true opts back into the full target" begin
    logs = run_once(Nitro.Core.AccessLogMiddleware(log_query=true),
                    HTTP.Request("GET", "/reset?token=SECRET-XYZ"))
    @test occursin("token=SECRET-XYZ", logs[1].message)
end
end
