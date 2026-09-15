@testitem "Session middleware" tags=[:middleware] setup=[NitroCommon] begin
using HTTP
using Dates
using Nitro: SessionMiddleware, GET, set_cookie!
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
        ).middleware

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
            secure=false,
            httponly=false,
            samesite="Strict"
        ).middleware

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
        ).middleware

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
        session_id = String(match(r"mod_session=([^;]+)", cookie_str).captures[1])

        # Verify the data was stored in the MemoryStore
        payload = Base.get(store, session_id, nothing)
        @test !isnothing(payload)
        @test payload.data["user_id"] == 42
        @test payload.data["username"] == "testuser"
    end

    @testset "session middleware preserves existing Set-Cookie headers" begin
        store = MemoryStore{String, Dict{String,Any}}()

        mw = SessionMiddleware(
            cookie_name="stacked_session",
            max_age=3600,
            store=store,
            secure=false,
        ).middleware

        handler = function(req::HTTP.Request)
            response = HTTP.Response(200, "OK")
            set_cookie!(response, "flash", "saved"; encrypted=false, secure=false)
            getsession(req)["user_id"] = 42
            return response
        end

        response = mw(handler)(HTTP.Request("GET", "/stacked"))
        set_cookie_headers = [header.second for header in response.headers if lowercase(header.first) == "set-cookie"]

        @test length(set_cookie_headers) == 2
        @test any(occursin("flash=saved", header) for header in set_cookie_headers)
        @test any(occursin("stacked_session=", header) for header in set_cookie_headers)
    end

    @testset "existing authenticated session rotates session id" begin
        store = MemoryStore{String, Dict{String,Any}}()
        original_session_id = "anon-session-id"
        storesession!(store, original_session_id, Dict{String,Any}("cart" => [1, 2]); ttl=3600)

        mw = SessionMiddleware(
            cookie_name="auth_session",
            max_age=3600,
            store=store,
            secure=false,
        ).middleware

        handler = function(req::HTTP.Request)
            getsession(req)["user_id"] = 99
            return HTTP.Response(200, "OK")
        end

        response = mw(handler)(HTTP.Request("GET", "/login", ["Cookie" => "auth_session=$original_session_id"]))
        cookie_header = HTTP.header(response, "Set-Cookie")
        rotated_session_id = String(match(r"auth_session=([^;]+)", cookie_header).captures[1])

        @test rotated_session_id != original_session_id
        @test Base.get(store, original_session_id, nothing) === nothing

        payload = Base.get(store, rotated_session_id, nothing)
        @test !isnothing(payload)
        @test payload.data["user_id"] == 99
        @test payload.data["cart"] == [1, 2]
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
        ).middleware

        # Handler that reads the session
        read_handler = function(req::HTTP.Request)
            session = getsession(req)
            @test session["user_id"] == 99
            @test session["role"] == "admin"
            # Note: SessionMiddleware populates the session, not the user (getuser stays nothing)
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
        ).middleware

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
        ).middleware

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
                if Nitro.Types.is_expired(v, current_time)
                    delete!(store.data, k)
                end
            end
        end

        store = MockStore{String, Dict{String,Any}}()

        mw = SessionMiddleware(
            cookie_name="custom_session",
            store=store,
        ).middleware

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

    # ── #171: no implicit process-global store ────────────────────────────────
    #
    # `const DEFAULT_STORE = MemoryStore{String, Dict{String,Any}}()` used to be the `store`
    # default, so every `SessionMiddleware()` in the process shared one session table.
    #
    # What pins #171 is the `@test_throws` pair: restore the const and the default kwarg and
    # those two fail, because the call succeeds. NOTE: the isolation block at the end passes
    # under the old design too -- it hands both middlewares an explicit store, so its outcome
    # never depended on whether a default existed. It is regression cover for explicit-store
    # isolation, not a demonstration of the defect.
    @testset "store is required — no shared process-global (#171)" begin
        @test_throws UndefKeywordError SessionMiddleware()
        @test_throws UndefKeywordError SessionMiddleware(cookie_name="no_store", max_age=60)

        # `MemoryStore()` builds exactly the parameters the `store` keyword is pinned to.
        @test MemoryStore() isa MemoryStore{String, Dict{String,Any}}
        @test MemoryStore() !== MemoryStore()      # a fresh table every call, never shared

        # Both types must be EXPORTED, not merely present in `Nitro`'s namespace: they were
        # already reachable as `Nitro.MemoryStore` before #171 (via `using .Core`), so
        # `isdefined` would pass against the unpatched code. `names()` lists exports only,
        # and that is what makes a required `store` satisfiable after a bare `using Nitro`.
        @test :MemoryStore in names(Nitro)
        @test :AbstractSessionStore in names(Nitro)
        @test MemoryStore() isa Nitro.AbstractSessionStore{String, Dict{String,Any}}

        # Two middlewares built the way an app with two `App`s would build them.
        storeA, storeB = MemoryStore(), MemoryStore()
        write_session(mw, marker) = begin
            wrapped = mw.middleware(function (req::HTTP.Request)
                getsession(req)["marker"] = marker
                return HTTP.Response(200, "ok")
            end)
            wrapped(HTTP.Request("GET", "/"))
        end

        write_session(SessionMiddleware(cookie_name="app_a", store=storeA), "A")
        write_session(SessionMiddleware(cookie_name="app_b", store=storeB), "B")

        @test length(storeA.data) == 1
        @test length(storeB.data) == 1
        @test first(values(storeA.data)).data["marker"] == "A"
        @test first(values(storeB.data)).data["marker"] == "B"
        # The session ids are distinct, so neither store can be holding the other's row.
        @test isempty(intersect(keys(storeA.data), keys(storeB.data)))
    end

end

end
