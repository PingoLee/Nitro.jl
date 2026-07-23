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

    middleware = SessionMiddleware(cookie_name="auth_session", store=store, prune_probability=0.0)
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

@testset "Bearer auth populates req.user" begin
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
    )(req -> HTTP.Response(200, req.user["sub"])))

    req = HTTP.Request("GET", "/secure", ["Authorization" => "Bearer $token"])
    res = handler(req)
    @test res.status == 200
    @test Nitro.text(res) == "17"

    # req.user is the normalized Principal: claims read through, identity is typed
    @test req.context[:user] isa Principal
    @test req.context[:user].id == "17"
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

@testset "Keyset auth: kid_required authorization" begin
    keyset = Dict("service-a" => "ka-secret", "service-b" => "kb-secret")
    validator = Nitro.Auth.jwt_validator(keyset; identity_from=:kid)

    handler = BearerAuth(validator)(GuardMiddleware(
        kid_required(["service-a"]),
    )(req -> HTTP.Response(200, req.user.id)))

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

@testset "Handler returning req.user serializes as the claims object" begin
    validator = Nitro.Auth.jwt_validator("jwt-secret")
    token = Nitro.Auth.encode_jwt(Dict("sub" => "17", "role" => "admin"), "jwt-secret"; expires_in=60)

    handler = BearerAuth(validator)(req -> Nitro.Res.json(req.user))
    req = HTTP.Request("GET", "/me", ["Authorization" => "Bearer $token"])
    res = handler(req)
    @test res.status == 200
    body = JSON.parse(Nitro.text(res))
    # id/kid/source metadata never leaks into the wire shape
    @test body["sub"] == "17" && body["role"] == "admin"
    @test !haskey(body, "id") && !haskey(body, "claims") && !haskey(body, "source")
end

@testset "CSRF middleware" begin
    middleware = CSRFMiddleware("csrf-secret"; config=Nitro.CookieConfig(httponly=false, secure=false, samesite="Lax", path="/", maxage=3600))
    wrapped = middleware(req -> HTTP.Response(200, "ok"))

    get_res = wrapped(HTTP.Request("GET", "/form"))
    cookie_header = HTTP.header(get_res, "Set-Cookie")
    cookie_value = match(r"csrf_token=([^;]+)", cookie_header).captures[1]
    raw_token = split(cookie_value, ".", limit=2)[1]

    post_req = HTTP.Request("POST", "/form", [
        "Cookie" => "csrf_token=$cookie_value",
        "X-CSRF-Token" => raw_token,
    ])
    post_res = wrapped(post_req)
    @test post_res.status == 200

    bad_req = HTTP.Request("POST", "/form", ["Cookie" => "csrf_token=$cookie_value"])
    bad_res = wrapped(bad_req)
    @test bad_res.status == 403
end

end