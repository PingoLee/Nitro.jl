@testitem "Guards" tags=[:middleware, :auth] setup=[NitroCommon] begin
using HTTP
using Nitro: GuardMiddleware, login_required, role_required, permission_required, GET

@testset "GuardMiddleware" begin

    @testset "guard blocks unauthenticated" begin
        # A guard that checks for a custom header as a simple auth proxy
        function require_auth(req::HTTP.Request)
            auth = HTTP.header(req, "X-Auth-Token", "")
            if isempty(auth)
                return HTTP.Response(401, ["Content-Type" => "application/json"],
                    codeunits("{\"error\":\"Unauthorized\"}"))
            end
            nothing
        end

        # Create the middleware and compose it with a handler
        mw = GuardMiddleware(require_auth)
        handler = function(req::HTTP.Request)
            return HTTP.Response(200, "OK")
        end
        wrapped = mw(handler)

        # Request without auth header → blocked
        r = wrapped(HTTP.Request("GET", "/guarded"))
        @test r.status == 401

        # Request with auth header → allowed
        r2 = wrapped(HTTP.Request("GET", "/guarded", ["X-Auth-Token" => "valid-token"]))
        @test r2.status == 200
    end

    @testset "multiple stacked guards" begin
        function guard_one(req::HTTP.Request)
            # Always passes
            nothing
        end

        function guard_two(req::HTTP.Request)
            # Blocks if no X-Role header
            role = HTTP.header(req, "X-Role", "")
            if role != "admin"
                return HTTP.Response(403, ["Content-Type" => "text/plain"],
                    codeunits("Forbidden"))
            end
            nothing
        end

        mw = GuardMiddleware(guard_one, guard_two)
        handler = function(req::HTTP.Request)
            return HTTP.Response(200, "Welcome admin!")
        end
        wrapped = mw(handler)

        # No role → blocked by guard_two
        r = wrapped(HTTP.Request("GET", "/multi-guard"))
        @test r.status == 403

        # With admin role → passes both guards
        r2 = wrapped(HTTP.Request("GET", "/multi-guard", ["X-Role" => "admin"]))
        @test r2.status == 200
    end

    @testset "login_required guard" begin
        guard = login_required(redirect_url="/login")

        # No user context → should redirect
        req_no_session = HTTP.Request("GET", "/test")
        result = guard(req_no_session)
        @test result isa HTTP.Response
        @test result.status == 302
        location = HTTP.header(result, "Location", "")
        @test location == "/login"

        # With user context → should pass
        req_with_session = HTTP.Request("GET", "/test")
        req_with_session.context[:user] = Dict{String,Any}("user_id" => 42)
        result2 = guard(req_with_session)
        @test isnothing(result2)

        # An explicitly-set identity WITHOUT the session_key (e.g. JWT claims keyed by
        # `sub`, not `user_id`) is still authenticated — a middleware vouched for it.
        # Requiring the marker here would lock out legitimate token-authenticated users.
        req_claims = HTTP.Request("GET", "/test")
        req_claims.context[:user] = Dict{String,Any}("sub" => "user-123", "exp" => 9999999999)
        @test isnothing(guard(req_claims))

        # A non-Dict identity object set by middleware (e.g. a user struct / NamedTuple)
        # is authenticated too.
        req_struct = HTTP.Request("GET", "/test")
        req_struct.context[:user] = (id = 7, name = "alice")
        @test isnothing(guard(req_struct))

        # Defensive: an EMPTY context[:user] Dict carries no identity → redirect.
        req_empty_user = HTTP.Request("GET", "/test")
        req_empty_user.context[:user] = Dict{String,Any}()
        result_empty = guard(req_empty_user)
        @test result_empty isa HTTP.Response
        @test result_empty.status == 302

        # Auth bypass (regression): an ANONYMOUS visitor with session data but no
        # context[:user] must be redirected — the raw session is NOT an authenticated
        # identity, so it counts only when it carries the login marker.
        req_anon_session = HTTP.Request("GET", "/test")
        req_anon_session.context[:session] = Dict{String,Any}("cart" => [1, 2, 3], "prefs" => "dark")
        result_anon = guard(req_anon_session)
        @test result_anon isa HTTP.Response
        @test result_anon.status == 302

        # Session-based auth via the fallback: a session carrying the session_key (and
        # no context[:user]) is a logged-in user → pass.
        req_session_auth = HTTP.Request("GET", "/test")
        req_session_auth.context[:session] = Dict{String,Any}("user_id" => 7, "cart" => [1])
        @test isnothing(guard(req_session_auth))

        # Custom session_key is honored on the fallback path.
        guard_custom = login_required(redirect_url="/login", session_key="uid")
        req_custom_ok = HTTP.Request("GET", "/test")
        req_custom_ok.context[:session] = Dict{String,Any}("uid" => 99)
        @test isnothing(guard_custom(req_custom_ok))
        req_custom_no = HTTP.Request("GET", "/test")
        req_custom_no.context[:session] = Dict{String,Any}("user_id" => 99)  # wrong key for this guard
        @test guard_custom(req_custom_no).status == 302
    end

    @testset "role_required guard" begin
        guard = role_required("admin")

        # No user → blocked
        req_no_session = HTTP.Request("GET", "/test")
        result = guard(req_no_session)
        @test result isa HTTP.Response
        @test result.status == 403

        # Wrong role → blocked
        req_wrong_role = HTTP.Request("GET", "/test")
        req_wrong_role.context[:user] = Dict{String,Any}("role" => "user")
        result2 = guard(req_wrong_role)
        @test result2 isa HTTP.Response
        @test result2.status == 403

        # Correct role → passes
        req_admin = HTTP.Request("GET", "/test")
        req_admin.context[:user] = Dict{String,Any}("role" => "admin")
        result3 = guard(req_admin)
        @test isnothing(result3)
    end

    @testset "permission_required guard" begin
        guard = permission_required("reports:read")

        req_missing = HTTP.Request("GET", "/test")
        req_missing.context[:user] = Dict{String,Any}("permissions" => ["reports:write"])
        result = guard(req_missing)
        @test result isa HTTP.Response
        @test result.status == 403

        req_allowed = HTTP.Request("GET", "/test")
        req_allowed.context[:user] = Dict{String,Any}("permissions" => ["reports:read", "reports:write"])
        @test isnothing(guard(req_allowed))
    end

end

end
