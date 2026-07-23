@testitem "Session" tags=[:core] setup=[NitroCommon] begin

using Nitro
using Nitro.Types
using Test
using HTTP

struct User
    id::Int
    name::String
end

@testset "Nitro Session via App Context Tests" begin

    # 1. Setup a simple store in App Context
    session_store = Dict{String, User}()
    user1 = User(1, "John Doe")
    session_store["session-abc-123"] = user1

    # 2. Define a route that uses the Session extractor
    # By default, it looks for a cookie named "session"
    urlpatterns("",
        path("/profile", function(req, session::Session{User})
            if isnothing(session.payload)
                return "Unauthorized"
            end
            return "Hello $(session.payload.name)"
        end, method="GET"),
    )

    @testset "Valid Session" begin
        # Create a request with the session cookie
        req = Request("GET", "/profile", ["Cookie" => "session=session-abc-123"])
        res = internalrequest(req; context=session_store)
        @test text(res) == "Hello John Doe"
    end

    @testset "Invalid Session ID" begin
        req = Request("GET", "/profile", ["Cookie" => "session=wrong-id"])
        res = internalrequest(req; context=session_store)
        @test text(res) == "Unauthorized"
    end

    @testset "Missing Session Cookie" begin
        req = Request("GET", "/profile")
        res = internalrequest(req; context=session_store)
        @test text(res) == "Unauthorized"
    end

    @testset "Custom Cookie Name" begin
        # Define a route with a custom cookie name
        urlpatterns("",
            path("/custom", function(req, session = Session{User}("auth_token"))
                if isnothing(session.payload)
                    return "Unauthorized"
                end
                return "ID: $(session.payload.id)"
            end, method="GET"),
        )

        req = Request("GET", "/custom", ["Cookie" => "auth_token=session-abc-123"])
        res = internalrequest(req; context=session_store)
        @test text(res) == "ID: 1"
    end

    @testset "Encrypted Session Cookie" begin
        # Setup encryption
        secret = "a" ^ 32
        configcookies(secret_key=secret)

        # We need to encrypt the session ID "session-abc-123"
        # Since encrypt_payload is internal, we can use it or just test the round-trip
        
        urlpatterns("",
            path("/login-success", function()
                res = Response("Logged in")
                set_cookie!(res, "session", "session-abc-123", encrypted=true)
                return res
            end, method="GET"),
        )

        # 1. Login to get the encrypted cookie
        login_res = internalrequest(Request("GET", "/login-success"))
        cookie_header = HTTP.header(login_res, "Set-Cookie")
        
        # 2. Use that cookie to access profile
        req = Request("GET", "/profile", ["Cookie" => cookie_header])
        profile_res = internalrequest(req; context=session_store)
        
        @test text(profile_res) == "Hello John Doe"

        # Cleanup
        configcookies(secret_key=nothing)
    end

    @testset "MemoryStore with TTL and Pruning" begin
        # Ensure encryption is off for this test
        configcookies(secret_key=nothing)

        # Create a typed MemoryStore
        store = MemoryStore{String, User}()
        user = User(5, "TTL User")
        
        # 1. Store with short TTL (1 second)
        # We need to use Cookies.storesession! since it's in that module
        Nitro.Cookies.storesession!(store, "temp-id", user, ttl=1)
        
        urlpatterns("",
            path("/ttl-profile", function(req, session::Session{User})
                if isnothing(session.payload)
                    return "Expired"
                end
                return "Active"
            end, method="GET"),
        )

        # Immediate check
        res1 = internalrequest(Request("GET", "/ttl-profile", ["Cookie" => "session=temp-id"]); context=store)
        @test text(res1) == "Active"

        # Wait for expiration
        sleep(1.1)
        res2 = internalrequest(Request("GET", "/ttl-profile", ["Cookie" => "session=temp-id"]); context=store)
        @test text(res2) == "Expired"

        # 2. Verify Pruning
        @test length(store.data) == 1
        Nitro.Cookies.prunesessions!(store)
        @test length(store.data) == 0
    end

    @testset "MemoryStore Thread Safety" begin
        store = MemoryStore{Int, String}()
        n = 1000
        
        # Concurrent writes
        @sync for i in 1:n
            Threads.@spawn Nitro.Cookies.storesession!(store, i, "user-$i")
        end
        
        @test length(store.data) == n
        
        # Concurrent reads
        results = Vector{String}(undef, n)
        @sync for i in 1:n
            Threads.@spawn begin
                session = get(store, i, nothing)
                results[i] = session.data
            end
        end
        
        @test all(results .== ["user-$i" for i in 1:n])
    end

    @testset "SessionMiddleware cookie configuration" begin
        store = MemoryStore{String, Dict{String,Any}}()
        middleware = SessionMiddleware(
            cookie_name="local_session",
            max_age=120,
            store=store,
            prune_probability=0.0,
            secure=false,
            httponly=false,
            samesite="Strict"
        )

        handler = function(req::HTTP.Request)
            getsession(req)["user_id"] = 77
            return HTTP.Response(200, "configured")
        end

        response = middleware(handler)(HTTP.Request("GET", "/login"))
        cookie_header = HTTP.header(response, "Set-Cookie")

        @test occursin("local_session=", cookie_header)
        @test !occursin("Secure", cookie_header)
        @test !occursin("HttpOnly", cookie_header)
        @test occursin("SameSite=Strict", cookie_header)
    end

    @testset "SessionMiddleware validator contract (#4)" begin
        # The `validator` kwarg is a FALLBACK identity resolver for session-fixation
        # detection: consulted only when `auth_key` is absent, used purely to decide
        # whether the session ID must be regenerated. It never populates req.user.

        cookie_of(resp) = match(r"app_session=([^;]+)", HTTP.header(resp, "Set-Cookie", "")).captures[1]

        # Helper: seed a store with an existing session under a known id, then drive one
        # request whose handler mutates the session, and report whether the id rotated.
        function run_with_existing(; validator, auth_key="user_id", seed::Dict{String,Any}, mutate!)
            store = MemoryStore{String, Dict{String,Any}}()
            set_session!(store, "existing-id", seed; ttl=120)
            mw = SessionMiddleware(cookie_name="app_session", store=store, prune_probability=0.0,
                                   secure=false, auth_key=auth_key, validator=validator)
            handler = function(req::HTTP.Request)
                mutate!(getsession(req))
                return HTTP.Response(200, "ok")
            end
            req = HTTP.Request("GET", "/", ["Cookie" => "app_session=existing-id"])
            return req, mw(handler)(req)
        end

        # An app that keys identity by a claim `sub` (no flat "user_id") supplies a
        # validator to derive the marker. Logging IN (marker nothing -> "u1") must rotate
        # the session id — fixation defense.
        identity_validator = (session_id, data) -> get(data, "sub", nothing)
        _, resp_login = run_with_existing(
            validator=identity_validator,
            seed=Dict{String,Any}("cart" => [1]),                 # anonymous, no identity yet
            mutate! = s -> (s["sub"] = "u1"),                     # ...becomes authenticated
        )
        @test cookie_of(resp_login) != "existing-id"             # regenerated

        # No auth-boundary crossing (identity stable) → id is preserved.
        _, resp_stable = run_with_existing(
            validator=identity_validator,
            seed=Dict{String,Any}("sub" => "u1"),
            mutate! = s -> (s["cart"] = [1, 2]),                 # non-auth mutation
        )
        @test cookie_of(resp_stable) == "existing-id"            # not rotated

        # Logging OUT (identity "u1" -> nothing) also crosses the boundary → rotate.
        _, resp_logout = run_with_existing(
            validator=identity_validator,
            seed=Dict{String,Any}("sub" => "u1"),
            mutate! = s -> delete!(s, "sub"),
        )
        @test cookie_of(resp_logout) != "existing-id"

        # `auth_key` takes precedence: when the flat key is present, the validator is not
        # consulted. A validator that would (wrongly) report a stable identity must not
        # suppress rotation driven by the real auth_key change.
        never = (_...) -> "constant"
        _, resp_authkey = run_with_existing(
            validator=never, auth_key="user_id",
            seed=Dict{String,Any}("user_id" => 1),
            mutate! = s -> (s["user_id"] = 2),                   # user switch via auth_key
        )
        @test cookie_of(resp_authkey) != "existing-id"

        # Single-arity validators are supported via arity dispatch, and the validator
        # never writes req.user (it is not an auth-context populator).
        req_probe, resp_probe = run_with_existing(
            validator = session_id -> session_id,               # 1-arg form
            seed=Dict{String,Any}("cart" => [1]),
            mutate! = s -> (s["cart"] = [1, 2]),
        )
        @test resp_probe.status == 200
        @test !haskey(req_probe.context, :user)                 # never populates req.user
    end

end
end