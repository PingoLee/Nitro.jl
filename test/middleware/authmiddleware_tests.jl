@testitem "Auth middleware" tags=[:middleware, :auth, :network] setup=[NitroCommon] begin
using HTTP
using Nitro

port = get_free_port()
localhost = "http://$HOST:$port"

good_token = "goodtoken"
validate_token(token) = token == good_token ? Dict(:id => 1, :name => "TestUser") : nothing

@testset "BearerAuth unit tests (direct middleware calls)" begin
    # Build middleware around a simple handler that returns 200
    mw = BearerAuth(validate_token)
    handler = mw(req->HTTP.Response(200, "ok"))

    # Case A: header == "Bearer " (exactly the scheme + single space) -> header_len == scheme_prefix_len -> invalid
    reqA = HTTP.Request("GET", "/")
    HTTP.setheader(reqA, "Authorization" => "Bearer ")
    resA = handler(reqA)
    @test isa(resA, HTTP.Response)
    @test resA.status == 401

    # Case B: header == "Bearer  " (scheme + two spaces) -> token portion is whitespace, stripped to empty -> invalid
    reqB = HTTP.Request("GET", "/")
    HTTP.setheader(reqB, "Authorization" => "Bearer  ")
    resB = handler(reqB)
    @test isa(resB, HTTP.Response)
    @test resB.status == 401

    # Case C: valid token but invalid (validator returns nothing) -> EXPIRED_TOKEN (401)
    reqC = HTTP.Request("GET", "/")
    HTTP.setheader(reqC, "Authorization" => "Bearer badtoken")
    resC = handler(reqC)
    @test isa(resC, HTTP.Response)
    @test resC.status == 401

    # Case D: valid token -> handler should be invoked and return 200
    reqD = HTTP.Request("GET", "/")
    HTTP.setheader(reqD, "Authorization" => "Bearer $good_token")
    resD = handler(reqD)
    @test isa(resD, HTTP.Response)
    @test resD.status == 200
    @test text(resD) == "ok"
end


# Set up route with AuthMiddleware
urlpatterns("/auth",
    path("/protected", function(req)
        # Return user info from context
        user = req.user
        return HTTP.Response(200, "Hello, $(user[:name])!")
    end, method="GET", middleware=[BearerAuth(validate_token)]),
)

# Start server for tests
serve(port=port, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

@testset "BearerAuth Middleware Tests" begin

    # No Authorization header
    @test_throws HTTP.StatusError HTTP.get("$localhost/auth/protected")

    # Malformed header (wrong scheme)
    @test_throws HTTP.StatusError HTTP.get("$localhost/auth/protected"; headers=Dict("Authorization" => "Basic abcdef"))

    # Malformed header (empty token)
    @test_throws HTTP.StatusError HTTP.get("$localhost/auth/protected"; headers=Dict("Authorization" => "Bearer "))

    # Malformed header (passes length check but token is whitespace -> stripped to empty)
    @test_throws HTTP.StatusError HTTP.get("$localhost/auth/protected"; headers=Dict("Authorization" => "Bearer  "))

    # Malformed header (no trailing space - wrong format)
    @test_throws HTTP.StatusError HTTP.get("$localhost/auth/protected"; headers=Dict("Authorization" => "Bearer"))

    # Invalid token
    @test_throws HTTP.StatusError HTTP.get("$localhost/auth/protected"; headers=Dict("Authorization" => "Bearer badtoken"))

    r = HTTP.get("$localhost/auth/protected"; headers=Dict("Authorization" => "Bearer $good_token"))
    @test r.status == 200
    @test text(r) == "Hello, TestUser!"
end

@testset "CookieAuthMiddleware unit tests" begin
    # Build middleware
    mw = CookieAuthMiddleware(validate_token, cookie_name="my_auth_cookie")
    handler = mw(req->HTTP.Response(200, "ok"))
    secret = "auth-secret"
    encrypted_mw = CookieAuthMiddleware(validate_token, cookie_name="my_auth_cookie", secret_key=secret)
    encrypted_handler = encrypted_mw(req->HTTP.Response(200, "ok"))

    # Case A: Missing cookie
    reqA = HTTP.Request("GET", "/")
    resA = handler(reqA)
    @test resA.status == 401
    @test contains(text(resA), "Missing or invalid authentication cookie")

    # Case B: Invalid token (validator returns nothing)
    reqB = HTTP.Request("GET", "/")
    HTTP.setheader(reqB, "Cookie" => "my_auth_cookie=badtoken")
    resB = handler(reqB)
    @test resB.status == 401
    @test contains(text(resB), "Invalid or expired token")

    # Case C: Valid token
    reqC = HTTP.Request("GET", "/")
    HTTP.setheader(reqC, "Cookie" => "my_auth_cookie=$good_token")
    resC = handler(reqC)
    @test resC.status == 200
    @test text(resC) == "ok"
    @test reqC.context[:user][:name] == "TestUser"

    # Case D: Valid encrypted cookie
    login_res = HTTP.Response(200)
    set_cookie!(login_res, "my_auth_cookie", good_token, encrypted=true, secret_key=secret)
    reqD = HTTP.Request("GET", "/")
    HTTP.setheader(reqD, "Cookie" => HTTP.header(login_res, "Set-Cookie"))
    resD = encrypted_handler(reqD)
    @test resD.status == 200
    @test text(resD) == "ok"
    @test reqD.context[:user][:name] == "TestUser"

    # Case E: Invalid encrypted cookie should be rejected as unauthorized, not raise
    wrong_res = HTTP.Response(200)
    set_cookie!(wrong_res, "my_auth_cookie", good_token, encrypted=true, secret_key="wrong-secret")
    reqE = HTTP.Request("GET", "/")
    HTTP.setheader(reqE, "Cookie" => HTTP.header(wrong_res, "Set-Cookie"))
    resE = encrypted_handler(reqE)
    @test resE.status == 401
    @test contains(text(resE), "Missing or invalid authentication cookie")
end

terminate()


end