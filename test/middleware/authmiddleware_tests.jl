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
    secret = "auth-secret-0123456789abcdefghijklmnop"
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
    set_cookie!(wrong_res, "my_auth_cookie", good_token, encrypted=true, secret_key="wrong-secret-0123456789abcdefghijklmnop")
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
# end-to-end path — a real `[[[[…` bearer token or cookie through `jwt_validator` — runs in
# disposable child processes: the AUTH* steps of the deeply-nested-request testitem in
# test/bodyparser_tests.jl. Since #314 that token is an ordinary 401: `decode_jwt` caps the
# header segment, bounds JSON depth, and decodes the claims only after the signature.
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

# ── #314 ────────────────────────────────────────────────────────────────────────────────────
#
# The header cap through both auth middlewares and the stock `jwt_validator`. The oversized
# token is GENUINELY signed and only ~1 KB, far too shallow to overflow anything: what rejects
# it is the cap alone, and the pre-#314 decoder accepted it. Direct closure calls, no socket.
@testitem "Auth middleware — an oversized JWT header is a 401 (#314)" tags=[:middleware, :auth, :security] setup=[NitroCommon] begin
using HTTP, JSON
using Nitro

key = "k"^32
raw64(str) = Nitro.Crypto.base64url_encode(Vector{UInt8}(codeunits(str)))
sign(input) = string(input, ".", Nitro.Crypto.base64url_encode(Nitro.Auth._hmac_sha256(key, input)))
claims = raw64(JSON.json(Dict("sub" => "1", "iat" => trunc(Int, time()), "exp" => trunc(Int, time()) + 60)))
oversized = sign(string(raw64(JSON.json(Dict("alg" => "HS256", "typ" => "JWT", "x" => "a"^800))), ".", claims))
control = Nitro.Auth.encode_jwt(Dict("sub" => "1"), key; expires_in = 60)
@test ncodeunits(first(split(oversized, '.'))) > 1024

ok(req) = HTTP.Response(200, "ok")
bearer = BearerAuth(Nitro.Auth.jwt_validator(key))(ok)
cookie = CookieAuthMiddleware(Nitro.Auth.jwt_validator(key))(ok)
via_bearer(tok) = bearer(HTTP.Request("GET", "/", ["Authorization" => "Bearer " * tok])).status
via_cookie(tok) = cookie(HTTP.Request("GET", "/", ["Cookie" => "auth_token=" * tok])).status

@test via_bearer(control) == 200
@test via_cookie(control) == 200
@test via_bearer(oversized) == 401
@test via_cookie(oversized) == 401
end

# ── #310 ────────────────────────────────────────────────────────────────────────────────────
#
# `session_user_validator` through the real request path: any anonymous visitor can hold a stored
# session -- one a cart write created, or an empty one `CSRFMiddleware` kept for its token (#317) --
# so the validator's answer for an anonymous one is what decides whether `CookieAuthMiddleware`
# authenticates everybody. In-process (`internalrequest`), no socket.
@testitem "Auth middleware — an anonymous session does not authenticate (#310)" tags=[:middleware, :auth, :security] setup=[NitroCommon] begin
using HTTP
using Nitro

session_cookie(r) = match(r"nitro_session=([^;]+)", HTTP.header(r, "Set-Cookie"))[1]

app = App(mod = @__MODULE__)
store = MemoryStore()
session_auth = CookieAuthMiddleware(Nitro.Auth.session_user_validator(store); cookie_name = "nitro_session")
urlpatterns(app, "",
    path("/cart/add", req -> (push!(get!(getsession(req), "cart", Int[]), 101); "added")),
    path("/login", req -> (getsession(req)["user_id"] = 42; "in")),
    # Keeps an EMPTY session, the way `CSRFMiddleware` does for an anonymous visitor's token.
    # Since #317 a new session nothing marks or writes is not saved at all -- there would be no
    # empty session to test.
    path("/touch", req -> (req.context[:session_modified] = true; "touched")),
    path("/api/me", req -> repr(getuser(req)); middleware = [session_auth]))
mw = [SessionMiddleware(store = store, secure = false)]
get_with(target, sid) = internalrequest(app, HTTP.Request("GET", target, ["Cookie" => "nitro_session=$sid"]); middleware = mw)

@testset "an anonymous cart session is a 401, not the cart as a user" begin
    sid = session_cookie(internalrequest(app, HTTP.Request("GET", "/cart/add"); middleware = mw))
    r = get_with("/api/me", sid)
    @test r.status == 401
    @test contains(text(r), "Invalid or expired token")
end

@testset "an empty anonymous session is a 401" begin
    sid = session_cookie(internalrequest(app, HTTP.Request("GET", "/touch"); middleware = mw))
    @test get_with("/api/me", sid).status == 401
end

@testset "a logged-in session authenticates as the stored id" begin
    sid = session_cookie(internalrequest(app, HTTP.Request("GET", "/login"); middleware = mw))
    r = get_with("/api/me", sid)
    @test r.status == 200
    @test text(r) == "42"
end

end

# ── #313 ────────────────────────────────────────────────────────────────────────────────────
#
# A validator's return value is an identity or a rejection, never a yes/no. Before #313 only
# `nothing`/`missing` were rejections, so a predicate validator that answered `false` for a
# WRONG key authenticated the request with `getuser(req) == false`. Direct closure calls plus
# one in-process request; no socket.
@testitem "Auth middleware — a non-identity never authenticates (#313)" tags=[:middleware, :auth, :security] setup=[NitroCommon] begin
using HTTP
using Nitro

const NON_IDENTITIES = (false, true, "", missing, Dict{String,Any}(), Principal(Dict{String,Any}()))

bearer_req() = HTTP.Request("GET", "/", ["Authorization" => "Bearer whatever"])
cookie_req() = HTTP.Request("GET", "/", ["Cookie" => "auth_token=whatever"])

@testset "$(repr(bogus)) is a 401, alone or as the user half of a tuple" for bogus in NON_IDENTITIES
    for (mw, mkreq) in ((BearerAuth, bearer_req), (CookieAuthMiddleware, cookie_req))
        for returned in (bogus, (bogus, Dict("sub" => "1")))
            ran = Ref(false)
            handler = mw(_ -> returned)(req -> (ran[] = true; HTTP.Response(200, "ok")))
            req = mkreq()
            res = handler(req)
            @test res.status == 401
            @test contains(text(res), "Invalid or expired token")
            @test !ran[]
            @test !haskey(req.context, :user)
            @test !haskey(req.context, :auth_claims)
        end
    end
end

@testset "0, a string id, an id-less Principal and a claim-less signer are still identities" begin
    for real in (0, "alice", Principal(Dict{String,Any}("action" => "sync")),
                 Principal(Dict{String,Any}(); id = "service-a", kid = "service-a", source = :kid))
        handler = BearerAuth(_ -> real)(req -> HTTP.Response(200, "ok"))
        req = bearer_req()
        @test handler(req).status == 200
        @test req.context[:user] == real
    end
end

# The issue's reproduction, through `path(...; middleware=...)`.
@testset "a predicate validator with the wrong key is a 401" begin
    app = App(mod = @__MODULE__)
    urlpatterns(app, "",
        path("/pred", req -> "user = $(repr(getuser(req)))"; middleware = [BearerAuth(t -> t == "s3cr3t")]),
        path("/named", req -> "user = $(repr(getuser(req)))";
             middleware = [BearerAuth(t -> t == "s3cr3t" ? "api-client" : nothing)]))
    wrong = internalrequest(app, HTTP.Request("GET", "/pred", ["Authorization" => "Bearer WRONG"]))
    @test wrong.status == 401
    # The predicate authenticates nobody, the right key included — that is the contract.
    @test internalrequest(app, HTTP.Request("GET", "/pred", ["Authorization" => "Bearer s3cr3t"])).status == 401
    # Naming the caller is the fix the docs give.
    named = internalrequest(app, HTTP.Request("GET", "/named", ["Authorization" => "Bearer s3cr3t"]))
    @test named.status == 200
    @test text(named) == "user = \"api-client\""
    @test internalrequest(app, HTTP.Request("GET", "/named", ["Authorization" => "Bearer WRONG"])).status == 401
end

end

@testitem "Auth middleware — a non-ASCII Authorization header is a 401, not a 500 (#326)" tags=[:middleware, :auth, :security] setup=[NitroCommon] begin
using HTTP
using Nitro

# `_extract_token` measured the header with `length` (characters) and sliced it by that count
# (bytes): `Bearer éé` ended the slice mid-character -> StringIndexError -> a 500 with a logged
# backtrace, once per request, for anyone.
seen = String[]
validator(token) = (push!(seen, token); token == "ключ" ? Dict("sub" => "u") : nothing)
handler = BearerAuth(validator)(req -> HTTP.Response(200, "ok"))
call(value) = handler(HTTP.Request("GET", "/", ["Authorization" => value]))

@test call("Bearer éé").status == 401
@test call("Bearer abcé").status == 401            # ends in a multibyte character
@test call("Bearer é").status == 401
@test seen == ["éé", "abcé", "é"]                  # the token reached the validator whole
@test call("Bearer ключ").status == 200

# A non-ASCII scheme, configured by the app.
handler2 = BearerAuth(t -> t == "tok" ? Dict("sub" => "u") : nothing; scheme = "Tökén")(
    req -> HTTP.Response(200, "ok"))
@test handler2(HTTP.Request("GET", "/", ["Authorization" => "Tökén tok"])).status == 200
@test handler2(HTTP.Request("GET", "/", ["Authorization" => "Tökén ü"])).status == 401

# `extract_auth_token` had the same character/byte mix-up (latent for an ASCII scheme).
req = HTTP.Request("GET", "/", ["Authorization" => "Tökén ключ"])
@test Nitro.Auth.extract_auth_token(req; scheme = "Tökén", cookie_name = nothing) == "ключ"
end

@testitem "extract_auth_token reads a cookie only when told to (#321)" tags=[:middleware, :auth, :security] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro

# The auth cookie is an AMBIENT credential: a browser attaches it to a cross-site request
# too. The helper used to fall back to `auth_token` by default, so a "bearer-only" API
# built on it quietly accepted the cookie -- and with it, CSRF. It now matches `BearerAuth`.
cookie_only = HTTP.Request("GET", "/", ["Cookie" => "auth_token=from-cookie"])
@test Nitro.Auth.extract_auth_token(cookie_only) === nothing
@test Nitro.Auth.extract_auth_token(cookie_only; cookie_name = "auth_token") == "from-cookie"
@test Nitro.Auth.extract_auth_token(cookie_only; cookie_name = "other") === nothing

# The header still wins when both are present, with or without the opt-in.
both = HTTP.Request("GET", "/", ["Authorization" => "Bearer from-header", "Cookie" => "auth_token=from-cookie"])
@test Nitro.Auth.extract_auth_token(both) == "from-header"
@test Nitro.Auth.extract_auth_token(both; cookie_name = "auth_token") == "from-header"

# A statement of agreement, not a guard: BearerAuth did not change, so these two pass on the
# old code too. The `=== nothing` line above is what fails without the fix. They pin that the
# helper and the middleware agree -- neither reads a cookie unless given its name.
accept_any = BearerAuth(t -> Dict("sub" => t))(req -> HTTP.Response(200, "ok"))
@test accept_any(cookie_only).status == 401
@test accept_any(both).status == 200
end
