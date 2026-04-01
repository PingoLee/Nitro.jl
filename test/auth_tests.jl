@testitem "Auth integration" tags=[:auth, :core] setup=[NitroCommon] begin

using Test
using HTTP
using Nitro
using Nitro: BearerAuth, GuardMiddleware, SessionMiddleware, login_required, role_required, permission_required, CSRFMiddleware

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