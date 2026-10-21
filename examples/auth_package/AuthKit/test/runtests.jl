using Test, HTTP, Nitro, AuthKit

# A cheap hash keeps the suite fast; production code takes `make_password`'s default cost.
cheap_hash(password) = Auth.make_password(password; iterations = 1_000)

@testset "AuthKit" begin
    secret = "s"^32
    accounts = Dict("1" => Account("1", "alice", cheap_hash("wonderland"), "member"))
    function by_username(name)
        id = findfirst(a -> a.username == name, accounts)
        return id === nothing ? nothing : accounts[id]
    end
    config = AuthConfig(secret = secret,
                        find_by_username = by_username,
                        find_by_id = id -> get(accounts, id, nothing),
                        ttl = 600)

    app = App(mod = AuthKit)
    urlpatterns(app, "", routes(config))

    login(username, password) = internalrequest(app, HTTP.Request("POST", "/auth/login",
        ["Content-Type" => "application/json"], """{"username": "$username", "password": "$password"}"""))
    me(token) = internalrequest(app, HTTP.Request("GET", "/auth/me", ["Authorization" => "Bearer $token"]))
    token_for(username, password) = Nitro.json(login(username, password))["token"]

    @testset "routes() returns definitions and registers nothing" begin
        defs = routes(config; prefix = "/accounts", namespace = "accounts")
        @test defs isa Vector{RouteDefinition}
        @test sort([(d.pattern, d.name) for d in defs]) == [
            ("/accounts/login", "accounts.login"),
            ("/accounts/logout", "accounts.logout"),
            ("/accounts/me", "accounts.me"),
        ]
        # Building them registered nothing: not on the app-less global layer, the one place a
        # package without an `App` argument could register.
        @test internalrequest(HTTP.Request("POST", "/accounts/login")).status == 404
        @test url(app, "auth.me") == "/auth/me"
    end

    @testset "the config never prints its secret" begin
        @test !occursin(secret, sprint(show, config))
        @test !occursin(secret, repr(config))
    end

    @testset "login" begin
        res = login("alice", "wonderland")
        @test res.status == 200
        body = Nitro.json(res)
        @test body["token_type"] == "Bearer"
        @test body["expires_in"] == 600
        @test HTTP.header(res, "Cache-Control") == "no-store"
        claims = Auth.decode_jwt(body["token"], secret)
        @test claims["sub"] == "1"
        @test claims["iss"] == "authkit"
        @test claims["exp"] - claims["iat"] == 600
        @test claims["jti"] != Auth.decode_jwt(token_for("alice", "wonderland"), secret)["jti"]

        @test login("alice", "wrong").status == 401
        @test login("nobody", "wonderland").status == 401   # same answer as a wrong password
        res = internalrequest(app, HTTP.Request("POST", "/auth/login",
            ["Content-Type" => "application/json"], """{"username": "alice"}"""))
        @test res.status == 400                              # Json{Credentials} refused it
    end

    @testset "me" begin
        res = me(token_for("alice", "wonderland"))
        @test res.status == 200
        @test Nitro.json(res) == Dict("id" => "1", "username" => "alice", "role" => "member")

        @test internalrequest(app, HTTP.Request("GET", "/auth/me")).status == 401
        @test me("not-a-token").status == 401
        claims(extra...) = Dict{String,Any}("iss" => "authkit", "sub" => "1", "jti" => "x", extra...)
        @test me(Auth.encode_jwt(claims(), secret; expires_in = 600)).status == 200   # the shape below
        forged = Auth.encode_jwt(claims(), "f"^32; expires_in = 600)
        @test me(forged).status == 401                       # signed with another key
        expired = Auth.encode_jwt(claims("exp" => round(Int, time()) - 3600), secret)
        @test me(expired).status == 401
        other_issuer = Auth.encode_jwt(claims("iss" => "billing"), secret; expires_in = 600)
        @test me(other_issuer).status == 401                 # the same key, another component
        no_jti = Auth.encode_jwt(delete!(claims(), "jti"), secret; expires_in = 600)
        @test me(no_jti).status == 401                       # not one AuthKit issued
    end

    @testset "logout revokes that token and no other" begin
        token = token_for("alice", "wonderland")
        other = token_for("alice", "wonderland")
        res = internalrequest(app, HTTP.Request("POST", "/auth/logout", ["Authorization" => "Bearer $token"]))
        @test res.status == 204
        @test me(token).status == 401
        @test me(other).status == 200
        @test internalrequest(app, HTTP.Request("POST", "/auth/logout")).status == 401
    end

    @testset "a token outlives no deleted account" begin
        accounts["2"] = Account("2", "bob", cheap_hash("builder"), "member")
        token = token_for("bob", "builder")
        @test me(token).status == 200
        delete!(accounts, "2")
        @test me(token).status == 401
    end

    @test_throws ArgumentError AuthConfig(secret = secret, find_by_username = identity,
                                          find_by_id = identity, ttl = 0)
    # Too short a key is refused when the middleware is built, which is app startup.
    short = AuthConfig(secret = "short", find_by_username = identity, find_by_id = identity)
    @test_throws "the JWT secret is 5 bytes" TokenAuth(config = short)
end
