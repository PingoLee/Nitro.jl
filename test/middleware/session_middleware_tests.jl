@testitem "Session middleware" tags=[:middleware] setup=[NitroCommon] begin
using HTTP
using Dates
using Nitro: SessionMiddleware, GET
using Nitro.Core.Types: MemoryStore, SessionPayload
using Nitro.Core.Cookies: storesession!, prunesessions!

@testset "SessionMiddleware" begin

    @testset "session creation on first request" begin
        # Create a dedicated store for testing
        store = MemoryStore{String, Dict{String,Any}}()

        # Create the middleware
        mw = SessionMiddleware(
            cookie_name="test_session",
            max_age=3600,
            store=store,
            prune_probability=0.0  # disable probabilistic pruning in tests
        )

        # Simulate a handler that reads the session
        handler = function(req::HTTP.Request)
            session = getsession(req)
            @test !isnothing(session)       # session should be injected
            @test session isa Dict{String,Any}
            @test isempty(session)           # new session should be empty
            return HTTP.Response(200, "OK")
        end

        # Compose middleware with handler
        wrapped = mw(handler)
        
        # Create a request without any session cookie
        req = HTTP.Request("GET", "/test")
        response = wrapped(req)
        
        @test response.status == 200
        
        # Should have a Set-Cookie header (new session)
        set_cookie_headers = filter(h -> lowercase(h.first) == "set-cookie", response.headers)
        @test length(set_cookie_headers) >= 1
        @test occursin("test_session=", set_cookie_headers[1].second)
        @test occursin("HttpOnly", set_cookie_headers[1].second)
        @test occursin("Secure", set_cookie_headers[1].second)
        @test occursin("SameSite=Lax", set_cookie_headers[1].second)
    end

    @testset "session cookie attributes are configurable" begin
        store = MemoryStore{String, Dict{String,Any}}()

        mw = SessionMiddleware(
            cookie_name="dev_session",
            max_age=3600,
            store=store,
            prune_probability=0.0,
            secure=false,
            httponly=false,
            samesite="Strict"
        )

        handler = function(req::HTTP.Request)
            getsession(req)["mode"] = "dev"
            return HTTP.Response(200, "OK")
        end

        response = mw(handler)(HTTP.Request("GET", "/test"))

        @test response.status == 200

        set_cookie_headers = filter(h -> lowercase(h.first) == "set-cookie", response.headers)
        @test length(set_cookie_headers) == 1

        cookie_header = set_cookie_headers[1].second
        @test occursin("dev_session=", cookie_header)
        @test !occursin("HttpOnly", cookie_header)
        @test !occursin("Secure", cookie_header)
        @test occursin("SameSite=Strict", cookie_header)
    end

    @testset "session data modification" begin
        store = MemoryStore{String, Dict{String,Any}}()

        mw = SessionMiddleware(
            cookie_name="mod_session",
            max_age=3600,
            store=store,
            prune_probability=0.0
        )

        # Handler that sets session data
        set_handler = function(req::HTTP.Request)
            getsession(req)["user_id"] = 42
            getsession(req)["username"] = "testuser"
            return HTTP.Response(200, "set")
        end

        wrapped_set = mw(set_handler)
        req1 = HTTP.Request("GET", "/set")
        response1 = wrapped_set(req1)

        @test response1.status == 200

        # Extract the session ID from Set-Cookie header
        set_cookie_headers = filter(h -> lowercase(h.first) == "set-cookie", response1.headers)
        @test length(set_cookie_headers) >= 1
        
        cookie_str = set_cookie_headers[1].second
        session_id = match(r"mod_session=([^;]+)", cookie_str).captures[1]

        # Verify the data was stored in the MemoryStore
        payload = Base.get(store, session_id, nothing)
        @test !isnothing(payload)
        @test payload.data["user_id"] == 42
        @test payload.data["username"] == "testuser"
    end

    @testset "session retrieval on subsequent request" begin
        store = MemoryStore{String, Dict{String,Any}}()

        # Pre-populate the store with a session
        session_id = "test-session-id-12345"
        session_data = Dict{String,Any}("user_id" => 99, "role" => "admin")
        storesession!(store, session_id, session_data; ttl=3600)

        mw = SessionMiddleware(
            cookie_name="retrieve_session",
            max_age=3600,
            store=store,
            prune_probability=0.0
        )

        # Handler that reads the session
        read_handler = function(req::HTTP.Request)
            session = getsession(req)
            @test session["user_id"] == 99
            @test session["role"] == "admin"
            # Note: SessionMiddleware populates req.session, not req.user
            return HTTP.Response(200, "read")
        end

        wrapped_read = mw(read_handler)
        
        # Create a request with the session cookie
        req = HTTP.Request("GET", "/read", ["Cookie" => "retrieve_session=$session_id"])
        response = wrapped_read(req)
        
        @test response.status == 200
    end

    @testset "expired session creates new session" begin
        store = MemoryStore{String, Dict{String,Any}}()

        # Add an expired session
        expired_id = "expired-session-id"
        expired_data = Dict{String,Any}("old" => true)
        # Store with a past expiry
        lock(store.lock) do
            store.data[expired_id] = SessionPayload(expired_data, Dates.now(Dates.UTC) - Dates.Second(10))
        end

        mw = SessionMiddleware(
            cookie_name="exp_session",
            max_age=3600,
            store=store,
            prune_probability=0.0
        )

        # Handler checks session is fresh (empty)
        handler = function(req::HTTP.Request)
            session = getsession(req)
            @test isempty(session)  # expired session should yield a new empty session
            return HTTP.Response(200, "fresh")
        end

        wrapped = mw(handler)
        req = HTTP.Request("GET", "/test", ["Cookie" => "exp_session=$expired_id"])
        response = wrapped(req)
        
        @test response.status == 200
        
        # Should have a new Set-Cookie (different session ID)
        set_cookie_headers = filter(h -> lowercase(h.first) == "set-cookie", response.headers)
        @test length(set_cookie_headers) >= 1
        @test !occursin(expired_id, set_cookie_headers[1].second)
    end

    @testset "unmodified session not re-saved" begin
        store = MemoryStore{String, Dict{String,Any}}()

        session_id = "unchanged-session-id"
        session_data = Dict{String,Any}("key" => "value")
        storesession!(store, session_id, session_data; ttl=3600)

        mw = SessionMiddleware(
            cookie_name="nomod_session",
            max_age=3600,
            store=store,
            prune_probability=0.0
        )

        # Handler that doesn't modify the session
        handler = function(req::HTTP.Request)
            _ = getsession(req)  # read but don't modify
            return HTTP.Response(200, "no-change")
        end

        wrapped = mw(handler)
        req = HTTP.Request("GET", "/test", ["Cookie" => "nomod_session=$session_id"])
        response = wrapped(req)

        @test response.status == 200

        # Should NOT have a Set-Cookie header (session not modified, not new)
        set_cookie_headers = filter(h -> lowercase(h.first) == "set-cookie", response.headers)
        @test length(set_cookie_headers) == 0
    end

    @testset "custom session store backend" begin
        # 1. Define a custom store
        struct MockStore{K,V} <: Nitro.Core.Types.AbstractSessionStore{K,V}
            data::Dict{K, SessionPayload{V}}
            MockStore{K,V}() where {K,V} = new{K,V}(Dict{K, SessionPayload{V}}())
        end

        # 2. Implement the interface
        function Base.get(store::MockStore, key, default)
            return Base.get(store.data, key, default)
        end
        function Nitro.Core.Cookies.storesession!(store::MockStore{K,V}, key::K, val::V; ttl::Int=3600) where {K,V}
            store.data[key] = SessionPayload(val, Dates.now(Dates.UTC) + Dates.Second(ttl))
        end
        function Nitro.Core.Cookies.prunesessions!(store::MockStore)
            current_time = Dates.now(Dates.UTC)
            for (k,v) in store.data
                if v.expires <= current_time
                    delete!(store.data, k)
                end
            end
        end

        store = MockStore{String, Dict{String,Any}}()

        mw = SessionMiddleware(
            cookie_name="custom_session",
            store=store,
            prune_probability=0.0
        )

        handler = function(req::HTTP.Request)
            getsession(req)["custom_backend"] = true
            return HTTP.Response(200, "custom")
        end

        wrapped = mw(handler)
        req = HTTP.Request("GET", "/custom")
        response = wrapped(req)

        @test response.status == 200
        
        # Verify it went into our custom store
        @test length(store.data) == 1
        payload = first(values(store.data))
        @test payload.data["custom_backend"] == true
    end

end

end
