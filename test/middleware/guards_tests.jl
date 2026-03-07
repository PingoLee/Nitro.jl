module GuardsTests

using Test
using HTTP
using Nitro
using Nitro: GuardMiddleware, login_required, role_required, GET

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

        # No session context → should redirect
        req_no_session = HTTP.Request("GET", "/test")
        result = guard(req_no_session)
        @test result isa HTTP.Response
        @test result.status == 302
        location = HTTP.header(result, "Location", "")
        @test location == "/login"

        # With session context → should pass
        req_with_session = HTTP.Request("GET", "/test")
        req_with_session.context[:session] = Dict{String,Any}("user_id" => 42)
        result2 = guard(req_with_session)
        @test isnothing(result2)
    end

    @testset "role_required guard" begin
        guard = role_required("admin")

        # No session → blocked
        req_no_session = HTTP.Request("GET", "/test")
        result = guard(req_no_session)
        @test result isa HTTP.Response
        @test result.status == 403

        # Wrong role → blocked
        req_wrong_role = HTTP.Request("GET", "/test")
        req_wrong_role.context[:session] = Dict{String,Any}("role" => "user")
        result2 = guard(req_wrong_role)
        @test result2 isa HTTP.Response
        @test result2.status == 403

        # Correct role → passes
        req_admin = HTTP.Request("GET", "/test")
        req_admin.context[:session] = Dict{String,Any}("role" => "admin")
        result3 = guard(req_admin)
        @test isnothing(result3)
    end

end

end
