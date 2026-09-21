@testitem "Auth integration" tags=[:auth, :core] setup=[NitroCommon] begin

using Test
using HTTP
using JSON
using Nitro
using Nitro: BearerAuth, GuardMiddleware, SessionMiddleware, login_required, role_required, permission_required,
    claim_required, kid_required, Principal, CSRFMiddleware

@testset "Unified auth context" begin
    store = Nitro.Types.MemoryStore{String, Dict{String,Any}}()
    Nitro.Types.set_session!(store, "session-1", Dict{String,Any}(
        "user_id" => 11,
        "role" => "admin",
        "permissions" => ["reports:read"],
    ); ttl=60)

    middleware = SessionMiddleware(cookie_name="auth_session", store=store).middleware
    handler = GuardMiddleware(
        login_required(),
        role_required("admin"),
        permission_required("reports:read"),
    )(req -> HTTP.Response(200, "session-ok"))

    req = HTTP.Request("GET", "/secure", ["Cookie" => "auth_session=session-1"])
    res = middleware(handler)(req)
    @test res.status == 200
    @test Nitro.text(res) == "session-ok"
end

@testset "Bearer auth populates getuser(req)" begin
    validator = Nitro.Auth.jwt_validator("jwt-secret")
    token = Nitro.Auth.encode_jwt(Dict(
        "sub" => "17",
        "role" => "admin",
        "permissions" => ["reports:read"],
        "exp" => trunc(Int, time()) + 60,
    ), "jwt-secret")

    handler = BearerAuth(validator)(GuardMiddleware(
        login_required(),
        role_required("admin"),
        permission_required("reports:read"),
    )(req -> HTTP.Response(200, getuser(req)["sub"])))

    req = HTTP.Request("GET", "/secure", ["Authorization" => "Bearer $token"])
    res = handler(req)
    @test res.status == 200
    @test Nitro.text(res) == "17"

    # getuser(req) is the normalized Principal: claims read through, identity is typed
    @test req.context[:user] isa Principal
    @test req.context[:user].id == "17"
end

# The app's own domain user — deliberately NOT a dict, which is the whole point of #24.
struct AppUser
    id::Int
    name::String
end

@testset "user_validator returning a struct still passes the claim guards (#24)" begin
    # The issue's literal failure scenario: a `user_validator` returns a domain struct, so
    # `req.context[:user]` is not a claims source and the verified `Principal` rides along
    # at `req.context[:auth_claims]`. Before the fix every claim guard returned 403 here
    # while `kid_required` on the same request worked.
    validator = Nitro.Auth.jwt_validator(
        "struct-secret";
        user_validator = principal -> AppUser(parse(Int, principal.id), "alice"),
    )
    token = Nitro.Auth.encode_jwt(Dict(
        "sub" => "42",
        "role" => "admin",
        "permissions" => ["reports:read"],
        "exp" => trunc(Int, time()) + 60,
    ), "struct-secret")

    handler = BearerAuth(validator)(GuardMiddleware(
        login_required(),
        role_required("admin"),
        permission_required("reports:read"),
        claim_required("sub", "42"),
    )(req -> HTTP.Response(200, getuser(req).name)))

    req = HTTP.Request("GET", "/secure", ["Authorization" => "Bearer $token"])
    res = handler(req)
    @test res.status == 200
    @test Nitro.text(res) == "alice"

    # Both slots are populated, and the handler sees the APP's user, not the Principal.
    @test req.context[:user] isa AppUser
    @test req.context[:user].id == 42
    @test req.context[:auth_claims] isa Principal
    @test req.context[:auth_claims]["role"] == "admin"

    # A claim the token does not carry is still a 403 on the same wiring.
    denied_handler = BearerAuth(validator)(GuardMiddleware(
        role_required("superuser"),
    )(req -> HTTP.Response(200, "unreachable")))
    denied = denied_handler(HTTP.Request("GET", "/secure", ["Authorization" => "Bearer $token"]))
    @test denied.status == 403
end

@testset "An inner auth layer does not inherit an outer layer's :auth_claims" begin
    # Two stacked auth middlewares. The outer one authenticates identity 1 and parks its
    # Principal at :auth_claims; the inner one re-authenticates as identity 2 and, having
    # produced no claims of its own, must CLEAR that slot. Otherwise identity 2 would be
    # authorized off identity 1's token — the claim guards read :auth_claims whenever
    # :user is not itself a claims source.
    outer = BearerAuth(_ -> ((id = 1,), Principal(Dict{String,Any}("role" => "admin"); id="1")))
    inner = Nitro.CookieAuthMiddleware(_ -> (id = 2,), cookie_name="c")

    handler = outer(inner(GuardMiddleware(
        role_required("admin"),
    )(req -> HTTP.Response(200, "granted"))))

    req = HTTP.Request("GET", "/secure", [
        "Authorization" => "Bearer outer-token",
        "Cookie" => "c=inner-token",
    ])
    res = handler(req)
    @test res.status == 403
    @test req.context[:user] == (id = 2,)
    @test !haskey(req.context, :auth_claims)

    # A nil claims half clears the slot too, rather than parking `nothing` in it, so
    # `haskey` stays a truthful signal for "this request carries verified claims".
    nil_claims = Nitro.CookieAuthMiddleware(_ -> ((id = 3,), nothing), cookie_name="c")
    nil_handler = outer(nil_claims(GuardMiddleware(
        role_required("admin"),
    )(req -> HTTP.Response(200, "granted"))))
    req_nil = HTTP.Request("GET", "/secure", [
        "Authorization" => "Bearer outer-token",
        "Cookie" => "c=inner-token",
    ])
    @test nil_handler(req_nil).status == 403
    @test !haskey(req_nil.context, :auth_claims)

    # And an inner layer that DOES produce claims replaces the outer layer's, rather than
    # merging with them: the inner viewer must not inherit the outer admin.
    inner_claims = Nitro.CookieAuthMiddleware(
        _ -> ((id = 4,), Principal(Dict{String,Any}("role" => "viewer"); id="4")),
        cookie_name="c",
    )
    replaced_handler = outer(inner_claims(GuardMiddleware(
        role_required("admin"),
    )(req -> HTTP.Response(200, "granted"))))
    req_replaced = HTTP.Request("GET", "/secure", [
        "Authorization" => "Bearer outer-token",
        "Cookie" => "c=inner-token",
    ])
    @test replaced_handler(req_replaced).status == 403
    @test req_replaced.context[:auth_claims]["role"] == "viewer"
end

@testset "Service tokens: claim-based authorization" begin
    validator = Nitro.Auth.jwt_validator("svc-secret")
    token = Nitro.Auth.encode_jwt(Dict("action" => "reports:generate"), "svc-secret"; expires_in=60)

    handler = BearerAuth(validator)(GuardMiddleware(
        login_required(),
        claim_required("action", "reports:generate"),
    )(req -> HTTP.Response(200, "generated")))

    req = HTTP.Request("GET", "/reports", ["Authorization" => "Bearer $token"])
    @test handler(req).status == 200

    # Same token, different capability → 403
    denied_handler = BearerAuth(validator)(GuardMiddleware(
        claim_required("action", "reports:delete"),
    )(req -> HTTP.Response(200, "never")))
    req_denied = HTTP.Request("GET", "/reports", ["Authorization" => "Bearer $token"])
    @test denied_handler(req_denied).status == 403
end

@testset "A mislabeled alg is a 401 at the middleware, not a 500 (#45)" begin
    # The upgrade entry promises that through BearerAuth the symptom of a non-HS256 `alg`
    # is a 401. Everything else in #45 asserts on `decode_jwt` directly, so without this
    # the promise is untested -- and `_handle_validated`'s catch-all is what turns the
    # AuthError into a 401 rather than letting it escape as a 500.
    validator = Nitro.Auth.jwt_validator("jwt-secret")
    handler = BearerAuth(validator)(req -> HTTP.Response(200, "reached"))

    # Hand-built so the header can lie while the HMAC stays genuinely valid -- the shape
    # `encode_jwt` cannot produce and the shape that used to be accepted.
    b64(d) = Nitro.Auth._base64url_encode(Vector{UInt8}(codeunits(JSON.json(d))))
    claims = Dict("sub" => "17", "exp" => trunc(Int, time()) + 60)
    function mint(alg)
        input = string(b64(Dict("alg" => alg, "typ" => "JWT")), ".", b64(claims))
        return string(input, ".", Nitro.Auth._base64url_encode(Nitro.Auth._hmac_sha256("jwt-secret", input)))
    end

    # Control: identical machinery, honest label -> the request goes through, so a 401
    # below cannot be blamed on the hand-rolled signing.
    ok = HTTP.Request("GET", "/x", ["Authorization" => "Bearer $(mint("HS256"))"])
    @test handler(ok).status == 200

    for alg in ("RS256", "none")
        req = HTTP.Request("GET", "/x", ["Authorization" => "Bearer $(mint(alg))"])
        res = handler(req)
        @test (alg, res.status) == (alg, 401)
    end

    # Everything below this line is a PIN, not a guard, and it is worth stating once rather
    # than per-assertion: at the middleware level a malformed token can only ever prove
    # "not a 500". `_handle_validated`'s catch-all erases the exception type, so a
    # MethodError, an ArgumentError and an AuthError all arrive as the same 401 -- these
    # cases were 401 before #45 too. The alg cases ABOVE are categorically different and do
    # discriminate, because there the pre-fix behavior was 200.
    #
    # They earn their place anyway: a 500 is what a reader fears from a hand-built token,
    # and nothing else in the suite asserts it cannot happen through the middleware.
    bad = HTTP.Request("GET", "/x", ["Authorization" => "Bearer W10.W10.x"])
    @test handler(bad).status == 401

    # A well-formed header and claims with one junk character of signature -- what a
    # truncated token looks like. Built by replacing the third segment so the token keeps
    # exactly three.
    segs = split(mint("HS256"), '.')
    truncated = join([segs[1], segs[2], "x"], '.')
    bad_sig = HTTP.Request("GET", "/x", ["Authorization" => "Bearer $truncated"])
    @test handler(bad_sig).status == 401
end

@testset "Keyset auth: kid_required authorization" begin
    keyset = Dict("service-a" => "ka-secret", "service-b" => "kb-secret")
    validator = Nitro.Auth.jwt_validator(keyset; identity_from=:kid)

    handler = BearerAuth(validator)(GuardMiddleware(
        kid_required(["service-a"]),
    )(req -> HTTP.Response(200, getuser(req).id)))

    # Token signed by an allowed key → pass, and the signer is the principal
    token_a = Nitro.Auth.encode_jwt(Dict("action" => "sync"), keyset; kid="service-a", expires_in=60)
    req_a = HTTP.Request("GET", "/sync", ["Authorization" => "Bearer $token_a"])
    res_a = handler(req_a)
    @test res_a.status == 200
    @test Nitro.text(res_a) == "service-a"

    # Verified token from a key OUTSIDE the route's allowlist → 403 (authorization,
    # not authentication: the signature checked out)
    token_b = Nitro.Auth.encode_jwt(Dict("action" => "sync"), keyset; kid="service-b", expires_in=60)
    req_b = HTTP.Request("GET", "/sync", ["Authorization" => "Bearer $token_b"])
    @test handler(req_b).status == 403
end

@testset "Handler returning getuser(req) serializes as the claims object" begin
    validator = Nitro.Auth.jwt_validator("jwt-secret")
    token = Nitro.Auth.encode_jwt(Dict("sub" => "17", "role" => "admin"), "jwt-secret"; expires_in=60)

    handler = BearerAuth(validator)(req -> Nitro.Res.json(getuser(req)))
    req = HTTP.Request("GET", "/me", ["Authorization" => "Bearer $token"])
    res = handler(req)
    @test res.status == 200
    body = JSON.parse(Nitro.text(res))
    # id/kid/source metadata never leaks into the wire shape
    @test body["sub"] == "17" && body["role"] == "admin"
    @test !haskey(body, "id") && !haskey(body, "claims") && !haskey(body, "source")
end

@testset "CSRF middleware" begin
    # SessionMiddleware goes OUTSIDE: CSRF tokens are bound to the session id it puts on the
    # request context, so without it there is nothing to bind to and every mutation is refused.
    store = Nitro.Types.MemoryStore{String, Dict{String,Any}}()
    wrapped = SessionMiddleware(cookie_name="csrf_session", store=store).middleware(
        CSRFMiddleware("csrf-secret")(req -> HTTP.Response(200, "ok")))

    set_cookies(res) = join([h.second for h in res.headers if lowercase(h.first) == "set-cookie"], "\n")
    cookie_named(res, name) = String(match(Regex("$(name)=([^;]+)"), set_cookies(res)).captures[1])

    get_res = wrapped(HTTP.Request("GET", "/form"))
    session_id = cookie_named(get_res, "csrf_session")
    cookie_value = cookie_named(get_res, "__Host-csrf_token")
    raw_token = split(cookie_value, ".", limit=2)[1]
    jar = "csrf_session=$session_id; __Host-csrf_token=$cookie_value"

    post_req = HTTP.Request("POST", "/form", [
        "Cookie" => jar,
        "X-CSRF-Token" => raw_token,
    ])
    post_res = wrapped(post_req)
    @test post_res.status == 200

    bad_req = HTTP.Request("POST", "/form", ["Cookie" => jar])
    bad_res = wrapped(bad_req)
    @test bad_res.status == 403

    # The binding itself. A second visitor gets their own session; replaying the FIRST visitor's
    # validly-signed cookie and matching header under it must fail. Every assertion above passes
    # identically against the unbound implementation -- this one is the regression test for #23.
    other_session = cookie_named(wrapped(HTTP.Request("GET", "/form")), "csrf_session")
    @test other_session != session_id
    stolen_req = HTTP.Request("POST", "/form", [
        "Cookie" => "csrf_session=$other_session; __Host-csrf_token=$cookie_value",
        "X-CSRF-Token" => raw_token,
    ])
    @test wrapped(stolen_req).status == 403
end

end