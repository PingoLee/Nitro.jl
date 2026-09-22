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
        user = getuser(req)
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

@testset "Reused const error Response survives repeated requests (HTTP.jl footgun guard)" begin
    # `BearerAuth` returns the module-level `const EXPIRED_TOKEN` / `INVALID_HEADER`
    # `Response` objects (String bodies) on every rejection. HTTP.jl's own write path would
    # consume the String body's single-use `BytesBody` cursor on first send and serve an
    # empty/truncated body on every reuse afterwards; Nitro's `_write_response_body!`
    # (src/core/transport.jl) writes `BytesBody.data` directly, non-destructively. Hit each shared
    # const several times on a kept-alive connection and assert the body is intact every
    # time — a regression to HTTP's consuming writer would empty or truncate these here.
    for _ in 1:4
        r = HTTP.get("$localhost/auth/protected";
                     headers=Dict("Authorization" => "Bearer badtoken"), status_exception=false)
        @test r.status == 401
        @test text(r) == "Unauthorized: Invalid or expired token"     # const EXPIRED_TOKEN
    end
    for _ in 1:4
        r = HTTP.get("$localhost/auth/protected"; status_exception=false)
        @test r.status == 401
        @test text(r) == "Unauthorized: Missing or invalid Authorization header"  # const INVALID_HEADER
    end
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

    # Case F (error contract regression): a THROWING validator (e.g. jwt_validator on an
    # expired/malformed token) must be a clean 401, never an unhandled exception → 500.
    throwing_mw = CookieAuthMiddleware(_ -> error("boom"), cookie_name="my_auth_cookie")
    throwing_handler = throwing_mw(req->HTTP.Response(200, "ok"))
    reqF = HTTP.Request("GET", "/")
    HTTP.setheader(reqF, "Cookie" => "my_auth_cookie=whatever")
    resF = throwing_handler(reqF)
    @test resF.status == 401
    @test contains(text(resF), "Invalid or expired token")

    # Case G: a (user, claims) tuple return populates both context slots (same contract
    # as BearerAuth).
    tuple_mw = CookieAuthMiddleware(token -> (Dict("uid" => 1), Dict("sub" => "1")), cookie_name="my_auth_cookie")
    tuple_handler = tuple_mw(req->HTTP.Response(200, "ok"))
    reqG = HTTP.Request("GET", "/")
    HTTP.setheader(reqG, "Cookie" => "my_auth_cookie=$good_token")
    @test tuple_handler(reqG).status == 200
    @test reqG.context[:user] == Dict("uid" => 1)
    @test reqG.context[:auth_claims] == Dict("sub" => "1")

    # Case H: a two-argument validator receives the request (arity dispatch, like
    # BearerAuth).
    seen_req = Ref{Any}(nothing)
    twoarg_mw = CookieAuthMiddleware((token, req) -> (seen_req[] = req; Dict("uid" => 2)), cookie_name="my_auth_cookie")
    twoarg_handler = twoarg_mw(req->HTTP.Response(200, "ok"))
    reqH = HTTP.Request("GET", "/")
    HTTP.setheader(reqH, "Cookie" => "my_auth_cookie=$good_token")
    @test twoarg_handler(reqH).status == 200
    @test seen_req[] === reqH

    # Case I (#24): a tuple whose USER half is nothing is unauthenticated, not a request
    # with a nil user. This matches `jwt_validator`, which maps a `user_validator`
    # returning nothing to a 401 rather than to a `(nothing, principal)` tuple.
    nil_user_mw = CookieAuthMiddleware(token -> (nothing, Dict("sub" => "1")), cookie_name="my_auth_cookie")
    nil_user_handler = nil_user_mw(req->HTTP.Response(200, "ok"))
    reqI = HTTP.Request("GET", "/")
    HTTP.setheader(reqI, "Cookie" => "my_auth_cookie=$good_token")
    resI = nil_user_handler(reqI)
    @test resI.status == 401
    @test contains(text(resI), "Invalid or expired token")
    # Neither slot is populated — the handler never ran.
    @test !haskey(reqI.context, :user)
    @test !haskey(reqI.context, :auth_claims)
end

terminate()


end
# ── #254 ────────────────────────────────────────────────────────────────────────────────────
#
# Deliberately a SEPARATE testitem, and deliberately NOT tagged `:network`: every assertion
# calls the middleware closure directly, so it binds no socket and the `--skip-tags network`
# fast pass over the suite covers it.
#
# These all throw the exception SYNTHETICALLY rather than exhausting a real stack. That is not
# a shortcut around a hazard, it is the correct test: the narrowing is `isa` dispatch inside a
# catch block, so `throw(StackOverflowError())` exercises the identical branch, while a real
# stack overflow would leave the ReTestItems worker in the state Julia itself describes as
# "possibly corrupted" — poisoning every item scheduled after it in that process. The
# end-to-end path (a real `[[[[…` bearer token through `jwt_validator`) is verified outside
# the suite, in a disposable process; see the PR.
@testitem "Auth middleware — unrecoverable errors are not swallowed (#254)" tags=[:middleware, :auth] setup=[NitroCommon] begin
using HTTP
using Nitro

# The three conditions the runtime raises about ITSELF, not about the token.
const UNRECOVERABLE = (InterruptException(), StackOverflowError(), OutOfMemoryError())

@testset "BearerAuth propagates $(typeof(ex))" for ex in UNRECOVERABLE
    handler = BearerAuth(_ -> throw(ex))(req -> HTTP.Response(200, "ok"))
    req = HTTP.Request("GET", "/")
    HTTP.setheader(req, "Authorization" => "Bearer whatever")
    @test_throws typeof(ex) handler(req)
end

@testset "CookieAuthMiddleware propagates $(typeof(ex))" for ex in UNRECOVERABLE
    handler = CookieAuthMiddleware(_ -> throw(ex), cookie_name="my_auth_cookie")(req -> HTTP.Response(200, "ok"))
    req = HTTP.Request("GET", "/")
    HTTP.setheader(req, "Cookie" => "my_auth_cookie=whatever")
    @test_throws typeof(ex) handler(req)
end

# The contract that must NOT regress. The carve-out is three named types, not "throwing
# validators now 500" — an ordinary failure (a DB lookup, an expired token, a bad secret) is
# still the documented 401, and that is the whole reason this is a deny-list and not the
# allow-list `decode_jwt` uses one layer down.
@testset "ordinary validator failures are still 401" begin
    for thrower in (_ -> error("boom"),
                    _ -> throw(ArgumentError("bad")),
                    _ -> throw(KeyError(:missing)),
                    _ -> throw(Nitro.Auth.AuthError("expired")))
        bearer = BearerAuth(thrower)(req -> HTTP.Response(200, "ok"))
        reqB = HTTP.Request("GET", "/")
        HTTP.setheader(reqB, "Authorization" => "Bearer whatever")
        resB = bearer(reqB)
        @test resB.status == 401
        @test contains(text(resB), "Invalid or expired token")

        cookie = CookieAuthMiddleware(thrower, cookie_name="my_auth_cookie")(req -> HTTP.Response(200, "ok"))
        reqC = HTTP.Request("GET", "/")
        HTTP.setheader(reqC, "Cookie" => "my_auth_cookie=whatever")
        resC = cookie(reqC)
        @test resC.status == 401
        @test contains(text(resC), "Invalid or expired token")
    end
end

# A validator that succeeds is untouched by any of this.
@testset "a working validator is unaffected" begin
    handler = BearerAuth(t -> Dict(:id => 1))(req -> HTTP.Response(200, "ok"))
    req = HTTP.Request("GET", "/")
    HTTP.setheader(req, "Authorization" => "Bearer good")
    @test handler(req).status == 200
    @test req.context[:user] == Dict(:id => 1)
end

end
