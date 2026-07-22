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

@testitem "Security: SecretString redaction" tags=[:security, :core] setup=[NitroCommon] begin
using Nitro
using Test

const RAW = "NITRO-RAW-SECRET-77aa1e"

# App-config shape from docs/src/tutorial/secrets.md: the secret sits in a struct
# whose default recursive `show` must hit the SecretString mask at the leaf.
struct SecretTestConfig
    name::String
    api_key::SecretString
end

@testset "every display path masks the value" begin
    s = SecretString(RAW)
    for rendered in (sprint(show, s),
                     sprint((io, x) -> show(io, MIME("text/plain"), x), s),
                     repr(s),
                     string(s),
                     "interpolated: $s")
        @test !occursin(RAW, rendered)
        @test occursin("****", rendered)
    end
end

@testset "containing structs mask through default recursive show" begin
    cfg = SecretTestConfig("app", SecretString(RAW))
    shown = sprint(show, cfg)
    @test !occursin(RAW, shown)
    @test occursin("****", shown)
    @test occursin("app", shown)            # non-secret fields still display normally
end

@testset "reveal is the explicit unwrap" begin
    @test reveal(SecretString(RAW)) == RAW
    @test reveal(SecretString(SubString("abc-def", 1, 3))) == "abc"   # AbstractString ctor
    s = SecretString(RAW)
    @test SecretString(s) === s             # idempotent — no double wrapping
end

@testset "constant-time equality semantics" begin
    @test SecretString("k1") == SecretString("k1")
    @test SecretString("k1") != SecretString("k2")
    @test SecretString("k1") == "k1"        # auth shape: stored secret vs client token
    @test "k1" == SecretString("k1")
    @test SecretString("k1") != "k1-longer" # length mismatch
    @test SecretString("") == SecretString("")
end

@testset "hash honors the == contract" begin
    @test hash(SecretString("k1")) == hash(SecretString("k1"))
    @test hash(SecretString("k1")) == hash("k1")    # consistent with mixed ==
    d = Dict(SecretString("k1") => 1)
    @test d[SecretString("k1")] == 1
end
end
