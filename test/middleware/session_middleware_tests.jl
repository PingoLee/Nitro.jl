@testitem "Session middleware" tags=[:middleware] setup=[NitroCommon] begin
using HTTP
using Dates
using Nitro: SessionMiddleware, GET, set_cookie!, CookieConfig
using Nitro.Core.Types: MemoryStore, SessionPayload
using Nitro.Core.Cookies: storesession!, prunesessions!

@testset "SessionMiddleware" begin

    @testset "session creation on first write" begin
        # Create a dedicated store for testing
        store = MemoryStore{String, Dict{String,Any}}()

        # Create the middleware
        mw = SessionMiddleware(
            cookie_name="test_session",
            max_age=3600,
            store=store,
        ).middleware

        # A handler that finds an empty session and writes to it. Writing is what creates the
        # session since #317; the read-only case is the next testset.
        handler = function(req::HTTP.Request)
            session = getsession(req)
            @test !isnothing(session)       # session should be injected
            @test session isa Dict{String,Any}
            @test isempty(session)           # new session should be empty
            session["visited"] = true
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
        @test length(store.data) == 1
    end

    # #317. This used to be the first half of the testset above, asserting the OPPOSITE: a
    # read-only first request got a `Set-Cookie` and a 24 h stored session. That expectation
    # encoded the defect -- every cookieless request (a health check, a static file) stored a
    # session, growing `MemoryStore` without bound and costing a PormG store an INSERT each.
    # Django (`request.session.modified`) and express-session (`saveUninitialized: false`) both
    # save a new session only once it is used; that is the behaviour asserted now.
    @testset "a new session nobody writes is not saved (#317)" begin
        store = MemoryStore()
        mw = SessionMiddleware(cookie_name="lazy_session", max_age=3600, store=store).middleware

        seen_id = Ref{Any}(nothing)
        handler = mw(function (req::HTTP.Request)
            seen_id[] = req.context[:session_id]      # an id exists for the whole request...
            _ = get(getsession(req), "user_id", nothing)
            return HTTP.Response(200, "OK")
        end)

        for _ in 1:50                                 # a cookieless health-check loop
            response = handler(HTTP.Request("GET", "/health"))
            @test response.status == 200
            @test isempty(filter(h -> lowercase(h.first) == "set-cookie", response.headers))
        end
        @test seen_id[] isa String
        @test length(store.data) == 0                 # ...but nothing was stored
    end

    @testset "`:session_modified` saves a new session and refreshes an existing one (#317)" begin
        store = MemoryStore()
        mw = SessionMiddleware(cookie_name="pinned", max_age=3600, store=store, secure=false).middleware
        pin = mw(function (req::HTTP.Request)
            req.context[:session_modified] = true
            return HTTP.Response(200, "OK")
        end)

        # New and still empty, but marked: saved, and the cookie is set.
        response = pin(HTTP.Request("GET", "/"))
        sid = String(match(r"pinned=([^;]+)", HTTP.header(response, "Set-Cookie")).captures[1])
        @test Base.get(store, sid, nothing).data == Dict{String,Any}()

        # Existing and unchanged, but marked: written back, which moves its expiry forward.
        lock(store.lock) do
            store.data[sid] = SessionPayload(Dict{String,Any}(), Dates.now(Dates.UTC) + Dates.Second(5), Dates.now(Dates.UTC))
        end
        response = pin(HTTP.Request("GET", "/", ["Cookie" => "pinned=$sid"]))
        @test occursin("pinned=$sid", HTTP.header(response, "Set-Cookie"))
        @test Base.get(store, sid, nothing).expires > Dates.now(Dates.UTC) + Dates.Second(3000)
        # The update path marks its response private too, not only the insert path.
        @test HTTP.header(response, "Cache-Control") == "private"
        @test HTTP.header(response, "Vary") == "Cookie"
    end

    @testset "a response that sets the session cookie is never publicly cacheable (#317)" begin
        store = MemoryStore()
        mw = SessionMiddleware(cookie_name="cache_session", max_age=3600, store=store, secure=false).middleware

        headers_of(res, name) = [h.second for h in res.headers if lowercase(h.first) == lowercase(name)]
        writing(headers) = mw(function (req::HTTP.Request)
            getsession(req)["seen"] = true
            return HTTP.Response(200, headers, "asset")
        end)

        # The issue's case: an immutable static asset under a global SessionMiddleware.
        immutable = ["Cache-Control" => "public, max-age=31536000, immutable"]
        res = writing(immutable)(HTTP.Request("GET", "/app.js"))
        @test headers_of(res, "Cache-Control") == ["private, max-age=31536000, immutable"]
        @test headers_of(res, "Vary") == ["Cookie"]

        # No Cache-Control at all: `private` is added, not left to a heuristic freshness guess.
        res = writing(Pair{String,String}[])(HTTP.Request("GET", "/"))
        @test headers_of(res, "Cache-Control") == ["private"]

        # An existing `Vary` is kept and `Cookie` is added beside it; one naming it already, or
        # `*`, is left alone. Same for a response already `private` or `no-store`.
        res = writing(["Vary" => "Origin"])(HTTP.Request("GET", "/"))
        @test sort(headers_of(res, "Vary")) == ["Cookie", "Origin"]
        res = writing(["Vary" => "Accept-Encoding, cookie", "Cache-Control" => "no-store"])(HTTP.Request("GET", "/"))
        @test headers_of(res, "Vary") == ["Accept-Encoding, cookie"]
        @test headers_of(res, "Cache-Control") == ["no-store"]
        res = writing(["Vary" => "*", "Cache-Control" => "private, max-age=60"])(HTTP.Request("GET", "/"))
        @test headers_of(res, "Vary") == ["*"]
        @test headers_of(res, "Cache-Control") == ["private, max-age=60"]

        # Directive names are case-insensitive, and several `Cache-Control` lines are one list:
        # they collapse into a single private line, with `public` gone from wherever it was.
        # The `X-Other` between them is load-bearing: HTTP.jl merges ADJACENT same-name headers
        # into one entry when it builds a response, so without it the middleware would only
        # ever see one line.
        res = writing(["Cache-Control" => "PUBLIC, max-age=60"])(HTTP.Request("GET", "/"))
        @test headers_of(res, "Cache-Control") == ["private, max-age=60"]
        two_lines = ["Cache-Control" => "max-age=60", "X-Other" => "1", "Cache-Control" => "public, immutable"]
        @test count(h -> lowercase(h.first) == "cache-control", HTTP.Response(200, two_lines, "").headers) == 2
        res = writing(two_lines)(HTTP.Request("GET", "/"))
        @test headers_of(res, "Cache-Control") == ["private, max-age=60, immutable"]

        # The rotation path too: a handler-driven `regenerate_session!` on an existing session.
        sid0 = String(match(r"cache_session=([^;]+)",
                            HTTP.header(writing(Pair{String,String}[])(HTTP.Request("GET", "/")), "Set-Cookie")).captures[1])
        rotating = mw(function (req::HTTP.Request)
            Nitro.regenerate_session!(req, store; ttl=3600)
            return HTTP.Response(200, ["Cache-Control" => "public, max-age=60"], "rotated")
        end)
        res = rotating(HTTP.Request("GET", "/", ["Cookie" => "cache_session=$sid0"]))
        @test occursin("cache_session=", HTTP.header(res, "Set-Cookie"))     # a cookie IS set...
        @test !occursin("cache_session=$sid0", HTTP.header(res, "Set-Cookie"))   # ...for the new id
        @test headers_of(res, "Cache-Control") == ["private, max-age=60"]
        @test headers_of(res, "Vary") == ["Cookie"]

        # A response that sets NO session cookie is not touched: an existing visitor reading a
        # public asset keeps it publicly cacheable.
        sid = String(match(r"cache_session=([^;]+)",
                           HTTP.header(writing(immutable)(HTTP.Request("GET", "/")), "Set-Cookie")).captures[1])
        reader = mw(req -> HTTP.Response(200, immutable, "asset"))
        # The visitor's FIRST request back confirms the new anonymous session (#440): one write,
        # whose response carries the session cookie and is therefore private like any other.
        # Every request after that is the "existing visitor" this testset is about.
        res = reader(HTTP.Request("GET", "/app.js", ["Cookie" => "cache_session=$sid"]))
        @test occursin("cache_session=$sid", HTTP.header(res, "Set-Cookie"))
        @test headers_of(res, "Cache-Control") == ["private, max-age=31536000, immutable"]
        res = reader(HTTP.Request("GET", "/app.js", ["Cookie" => "cache_session=$sid"]))
        @test isempty(HTTP.header(res, "Set-Cookie"))
        @test headers_of(res, "Cache-Control") == ["public, max-age=31536000, immutable"]
        @test isempty(headers_of(res, "Vary"))

        # And the rewrite happens on the middleware's OWN copy: a shared `const` response the
        # handler returns is not mutated (nitro-core §4).
        shared = HTTP.Response(200, ["Cache-Control" => "public, max-age=60"], "shared")
        res = mw(function (req::HTTP.Request)
            getsession(req)["x"] = 1
            return shared
        end)(HTTP.Request("GET", "/"))
        @test headers_of(res, "Cache-Control") == ["private, max-age=60"]
        @test headers_of(shared, "Cache-Control") == ["public, max-age=60"]
        @test isempty(headers_of(shared, "Vary"))
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
            store.data[expired_id] = SessionPayload(expired_data, Dates.now(Dates.UTC) - Dates.Second(10), Dates.now(Dates.UTC))
        end

        mw = SessionMiddleware(
            cookie_name="exp_session",
            max_age=3600,
            store=store,
        ).middleware

        # Handler checks session is fresh (empty), then writes to it -- a new session is saved
        # only once it is used (#317).
        handler = function(req::HTTP.Request)
            session = getsession(req)
            @test isempty(session)  # expired session should yield a new empty session
            session["fresh"] = true
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
            store.data[key] = SessionPayload(val, Dates.now(Dates.UTC) + Dates.Second(ttl), Dates.now(Dates.UTC))
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

    # ── #339: no `secret_key` ────────────────────────────────────────────────
    #
    # The keyword was accepted and never used: the id cookie was always written and read raw, so a
    # caller passing one believed the session cookie was protected by it when nothing was.
    @testset "SessionMiddleware takes no secret_key (#339)" begin
        key = "k" ^ 32
        @test_throws MethodError SessionMiddleware(store = MemoryStore(), secret_key = key)

        # The same no-op smuggled in through a whole `config` is refused, not ignored -- and the
        # message explains why without echoing the key.
        err = try
            SessionMiddleware(store = MemoryStore(), config = CookieConfig(secret_key = key, secure = false))
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("#339", err.msg) && !occursin(key, err.msg)

        # A config without a key is fine, and the cookie is what it always was: the raw id.
        store = MemoryStore()
        mw = SessionMiddleware(store = store, cookie_name = "plain",
                               config = CookieConfig(secure = false)).middleware
        res = mw(req -> (getsession(req)["x"] = 1; HTTP.Response(200, "ok")))(HTTP.Request("GET", "/"))
        sid = String(match(r"plain=([^;]+)", HTTP.header(res, "Set-Cookie")).captures[1])
        @test Base.get(store, sid, nothing) !== nothing
    end

    # ── #318: concurrent requests on one session ─────────────────────────────
    #
    # Both interleavings are replayed DETERMINISTICALLY by running the second request to
    # completion from inside the first one's handler -- that is exactly the order the race
    # produces, without depending on a scheduler to produce it.
    @testset "a write to a session a concurrent logout deleted is dropped (#318)" begin
        store = MemoryStore()
        stolen = "stolen-session-id"
        storesession!(store, stolen, Dict{String,Any}("user_id" => 42); ttl=3600)

        mw = SessionMiddleware(cookie_name="sid", max_age=3600, store=store, secure=false).middleware

        # B: the documented logout -- clear the payload, then rotate the id.
        logout = mw(function (req::HTTP.Request)
            empty!(getsession(req))
            Nitro.regenerate_session!(req, store; ttl=3600)
            return HTTP.Response(200, "bye")
        end)

        logout_response = Ref{HTTP.Response}()
        # A: a slow request on the same session, still running when B logs out, that then writes
        # to the session (a flash message after an upload, in the issue's words).
        slow = mw(function (req::HTTP.Request)
            logout_response[] = logout(HTTP.Request("POST", "/logout", ["Cookie" => "sid=$stolen"]))
            getsession(req)["flash"] = "upload done"
            return HTTP.Response(200, "uploaded")
        end)

        response = slow(HTTP.Request("POST", "/upload", ["Cookie" => "sid=$stolen"]))
        @test response.status == 200

        # The logged-out session stays dead: not re-created in the store, and not handed back to
        # the browser. Before #318 both happened -- the upsert re-created `stolen` with
        # `user_id = 42` and the response re-set `sid=stolen`, logging the browser back in.
        @test Base.get(store, stolen, nothing) === nothing
        @test isempty(filter(h -> lowercase(h.first) == "set-cookie", response.headers))

        # B's own outcome is untouched: a fresh, empty session under a new id.
        fresh = String(match(r"sid=([^;]+)", HTTP.header(logout_response[], "Set-Cookie")).captures[1])
        @test fresh != stolen
        @test Base.get(store, fresh, nothing).data == Dict{String,Any}()
    end

    # ── #361: the same race, through the ROTATION path ─────────────────────────
    #
    # #318 closed the plain write-back. A request that ROTATES after the logout -- an explicit
    # `regenerate_session!` (the docs recommend it on any privilege change), or `rotate_on_auth`
    # on a user switch -- used to copy the logged-out session into a fresh id, and the middleware
    # handed the client that new cookie: the browser was logged back in as `user_id = 42`.
    @testset "a rotation after a concurrent logout revives nothing (#361)" begin
        for (label, rotate!) in (
                "explicit regenerate_session!" =>
                    (req, store) -> Nitro.regenerate_session!(req, store; ttl=3600),
                "rotate_on_auth on a user switch" =>
                    (req, store) -> (getsession(req)["user_id"] = 43; nothing))
            @testset "$label" begin
                store = MemoryStore()
                stolen = "stolen-session-id"
                storesession!(store, stolen, Dict{String,Any}("user_id" => 42); ttl=3600)

                mw = SessionMiddleware(cookie_name="sid", max_age=3600, store=store, secure=false).middleware

                logout = mw(function (req::HTTP.Request)
                    empty!(getsession(req))
                    Nitro.regenerate_session!(req, store; ttl=3600)
                    return HTTP.Response(200, "bye")
                end)

                logout_response = Ref{HTTP.Response}()
                # A loaded `stolen` (user_id = 42); B logs out before A rotates.
                slow = mw(function (req::HTTP.Request)
                    logout_response[] = logout(HTTP.Request("POST", "/logout", ["Cookie" => "sid=$stolen"]))
                    rotate!(req, store)
                    return HTTP.Response(200, "rotated")
                end)

                response = slow(HTTP.Request("POST", "/elevate", ["Cookie" => "sid=$stolen"]))
                @test response.status == 200

                # No cookie for any id: neither `stolen` nor a fresh one carrying its data.
                @test isempty(filter(h -> lowercase(h.first) == "set-cookie", response.headers))

                # The only session left is B's fresh, empty one. Nothing carries user 42 (or the
                # user A switched to) -- before #361 a second row did, under the rotated id.
                fresh = String(match(r"sid=([^;]+)", HTTP.header(logout_response[], "Set-Cookie")).captures[1])
                @test collect(keys(store.data)) == [fresh]
                @test Base.get(store, fresh, nothing).data == Dict{String,Any}()
            end
        end
    end

    @testset "a rotation that wins keeps the handler's later writes (#361)" begin
        # The rotated id is written back update-only, so what the handler changed AFTER rotating
        # still lands -- the row exists, because `rotate_session!` just made it.
        store = MemoryStore()
        storesession!(store, "S", Dict{String,Any}("user_id" => 42); ttl=3600)
        mw = SessionMiddleware(cookie_name="sid", max_age=3600, store=store, secure=false).middleware
        res = mw(function (req::HTTP.Request)
            Nitro.regenerate_session!(req, store; ttl=3600)
            getsession(req)["elevated"] = true
            return HTTP.Response(200, "ok")
        end)(HTTP.Request("POST", "/sudo", ["Cookie" => "sid=S"]))
        rotated = String(match(r"sid=([^;]+)", HTTP.header(res, "Set-Cookie")).captures[1])
        @test rotated != "S"
        @test Base.get(store, "S", nothing) === nothing
        @test Base.get(store, rotated, nothing).data == Dict{String,Any}("user_id" => 42, "elevated" => true)
    end

    @testset "same-session requests do not share nested values (#318)" begin
        store = MemoryStore()
        sid = "shared-cart-session"
        storesession!(store, sid, Dict{String,Any}("cart" => [1]); ttl=3600)

        mw = SessionMiddleware(cookie_name="sid", max_age=3600, store=store, secure=false).middleware
        add_to_cart(item) = mw(function (req::HTTP.Request)
            push!(getsession(req)["cart"], item)       # the docs' cart pattern, mutating in place
            return HTTP.Response(200, "added")
        end)

        seen_by_first = Ref{Vector{Int}}()
        first_request = mw(function (req::HTTP.Request)
            cart = getsession(req)["cart"]
            add_to_cart(2)(HTTP.Request("GET", "/add", ["Cookie" => "sid=$sid"]))
            # A shallow copy on load made this the SAME vector the other request just pushed to.
            seen_by_first[] = copy(cart)
            return HTTP.Response(200, "read")
        end)

        first_request(HTTP.Request("GET", "/cart", ["Cookie" => "sid=$sid"]))
        @test seen_by_first[] == [1]
        @test Base.get(store, sid, nothing).data["cart"] == [1, 2]
    end

    # A smoke test, not the pin: the two testsets above are what fail against the unpatched code.
    # On one thread this cannot race at all; under `-t 2` (CI runs both) the shallow copy it
    # replaced threw `ConcurrencyViolationError`/`UndefRefError` in the audit's reproduction.
    # Lost appends remain possible and correct -- a session is last-writer-wins -- so only
    # integrity is asserted.
    @testset "concurrent cart appends on one session stay well-formed (#318)" begin
        store = MemoryStore()
        sid = "hammered-session"
        storesession!(store, sid, Dict{String,Any}("cart" => Int[]); ttl=3600)

        mw = SessionMiddleware(cookie_name="sid", max_age=3600, store=store, secure=false).middleware
        handler = mw(function (req::HTTP.Request)
            cart = get(getsession(req), "cart", Int[])
            push!(cart, parse(Int, HTTP.header(req, "X-Item")))
            getsession(req)["cart"] = cart
            return HTTP.Response(200, "ok")
        end)

        tasks = [Threads.@spawn handler(HTTP.Request("GET", "/add",
                     ["Cookie" => "sid=$sid", "X-Item" => string(i)])) for i in 1:500]
        statuses = [fetch(t).status for t in tasks]
        @test all(==(200), statuses)

        cart = Base.get(store, sid, nothing).data["cart"]
        @test cart isa Vector{Int}
        @test allunique(cart)
        @test all(in(1:500), cart)
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
    # ── #362: absolute lifetime ──────────────────────────────────────────────
    #
    # Every write-back slid the expiry, so a session in use never ended and a stolen id stayed
    # valid for as long as the thief kept using it. Sessions are staged with a chosen `created`
    # directly in the store rather than waited out.
    seed!(store, sid, data; created, expires = Dates.now(Dates.UTC) + Dates.Hour(1)) =
        lock(store.lock) do
            store.data[sid] = SessionPayload(data, expires, created)
        end
    cookie_of(res, name) = (m = match(Regex("$name=([^;]+)"), HTTP.header(res, "Set-Cookie"));
                            m === nothing ? nothing : String(m.captures[1]))
    max_age_of(res) = parse(Int, match(r"Max-Age=(\d+)", HTTP.header(res, "Set-Cookie")).captures[1])

    @testset "the default cap is seven days (#362)" begin
        @test Nitro.Core.Middleware.SessionMiddleware_.DEFAULT_ABSOLUTE_MAX_AGE == 7 * 86400
        store = MemoryStore()
        mw = SessionMiddleware(cookie_name="sid", store=store, secure=false).middleware
        reader = mw(req -> HTTP.Response(200, string(get(getsession(req), "user_id", "none"))))

        # Just inside: served, however long ago it was created.
        seed!(store, "young", Dict{String,Any}("user_id" => 1);
              created = Dates.now(Dates.UTC) - Dates.Day(7) + Dates.Minute(5))
        @test String(reader(HTTP.Request("GET", "/", ["Cookie" => "sid=young"])).body) == "1"

        # Just past: absent, although its sliding expiry is an hour away.
        seed!(store, "old", Dict{String,Any}("user_id" => 2);
              created = Dates.now(Dates.UTC) - Dates.Day(7) - Dates.Second(1))
        @test String(reader(HTTP.Request("GET", "/", ["Cookie" => "sid=old"])).body) == "none"
    end

    @testset "a session past its absolute lifetime is refused and removed (#362)" begin
        store = MemoryStore()
        seed!(store, "stolen", Dict{String,Any}("user_id" => 42);
              created = Dates.now(Dates.UTC) - Dates.Day(8))
        mw = SessionMiddleware(cookie_name="sid", max_age=3600, store=store, secure=false).middleware

        res = mw(function (req::HTTP.Request)
            @test isempty(getsession(req))            # absent, like an expired session
            getsession(req)["fresh"] = true
            return HTTP.Response(200, "ok")
        end)(HTTP.Request("GET", "/", ["Cookie" => "sid=stolen"]))

        fresh = cookie_of(res, "sid")
        @test fresh !== nothing && fresh != "stolen"
        # Removed, not merely refused: the readers that bypass the middleware check only
        # `expires`, and this row's expiry was still an hour away.
        @test Base.get(store, "stolen", nothing) === nothing
        @test Nitro.Core.Types.get_session(store, "stolen") === nothing
        @test Base.get(store, fresh, nothing).data == Dict{String,Any}("fresh" => true)
    end

    @testset "writes never let the expiry pass the absolute deadline (#362)" begin
        store = MemoryStore()
        cap = 7 * 86400
        born = Dates.now(Dates.UTC) - Dates.Second(cap - 100)   # 100 s of lifetime left
        seed!(store, "S", Dict{String,Any}("user_id" => 1); created = born)
        mw = SessionMiddleware(cookie_name="sid", max_age=3600, store=store, secure=false).middleware

        res = mw(req -> (getsession(req)["n"] = 1; HTTP.Response(200, "ok")))(
            HTTP.Request("GET", "/", ["Cookie" => "sid=S"]))

        payload = Base.get(store, "S", nothing)
        deadline = born + Dates.Second(cap)
        # Clamped to the deadline -- not `max_age` (an hour) from now -- and `created` kept.
        @test deadline - Dates.Second(5) <= payload.expires <= deadline
        @test payload.created == born
        @test 95 <= max_age_of(res) <= 100
        # So a reader that never passes through the middleware -- `get_session`, the `Session{T}`
        # extractor, `session_user_validator` -- refuses it at the deadline through `is_expired`.
        @test Nitro.Types.is_expired(payload, deadline)

        # A new session gets `min(max_age, absolute_max_age)`.
        short = SessionMiddleware(cookie_name="sid", max_age=3600, absolute_max_age=60,
                                  store=store, secure=false).middleware
        res = short(req -> (getsession(req)["n"] = 1; HTTP.Response(200, "ok")))(HTTP.Request("GET", "/"))
        @test max_age_of(res) == 60
        @test Base.get(store, cookie_of(res, "sid"), nothing).expires <= Dates.now(Dates.UTC) + Dates.Second(60)
    end

    @testset "rotation carries the creation instant (#362)" begin
        store = MemoryStore()
        born = Dates.now(Dates.UTC) - Dates.Day(3)
        seed!(store, "anon", Dict{String,Any}("cart" => [1]); created = born)
        mw = SessionMiddleware(cookie_name="sid", max_age=3600, store=store, secure=false).middleware

        # `rotate_on_auth` on login, and an explicit `regenerate_session!` on the new id.
        login = mw(req -> (getsession(req)["user_id"] = 7; HTTP.Response(200, "in")))
        rotated = cookie_of(login(HTTP.Request("POST", "/login", ["Cookie" => "sid=anon"])), "sid")
        @test rotated != "anon"
        @test Base.get(store, rotated, nothing).created == born

        sudo = mw(req -> (Nitro.regenerate_session!(req, store; ttl=86400); HTTP.Response(200, "ok")))
        res = sudo(HTTP.Request("POST", "/sudo", ["Cookie" => "sid=$rotated"]))
        again = cookie_of(res, "sid")
        @test again != rotated
        @test Base.get(store, again, nothing).created == born
        # The handler asked for a day; the middleware's write-back cut it to the deadline's
        # remainder -- here the one-hour `max_age`, which is sooner.
        @test Base.get(store, again, nothing).expires <= Dates.now(Dates.UTC) + Dates.Second(3600)
    end

    @testset "logout starts a fresh clock; logging back in carries it (#362)" begin
        # Rotation carries `created`, and logout is a rotation, so logging out and back in on day 6
        # used to leave a day. An EMPTY session carries no identity, so it starts over instead.
        store = MemoryStore()
        born = Dates.now(Dates.UTC) - Dates.Day(6)
        seed!(store, "S", Dict{String,Any}("user_id" => 7, "cart" => [1]); created = born)
        mw = SessionMiddleware(cookie_name="sid", max_age=3600, store=store, secure=false).middleware

        logout = mw(function (req::HTTP.Request)
            empty!(getsession(req))
            Nitro.regenerate_session!(req, store; ttl=3600)
            return HTTP.Response(200, "bye")
        end)
        before = Dates.now(Dates.UTC)
        anon = cookie_of(logout(HTTP.Request("POST", "/logout", ["Cookie" => "sid=S"])), "sid")
        @test anon != "S" && Base.get(store, "S", nothing) === nothing
        @test Base.get(store, anon, nothing).created >= before

        login = mw(req -> (getsession(req)["user_id"] = 7; HTTP.Response(200, "in")))
        back = cookie_of(login(HTTP.Request("POST", "/login", ["Cookie" => "sid=$anon"])), "sid")
        @test back != anon
        @test Base.get(store, back, nothing).created >= before   # the new clock, carried

        # The fresh clock is decided on the session's FINAL contents. A handler that empties,
        # rotates, then puts the identity back -- a "reset but stay signed in" -- keeps the old
        # clock; deciding at rotation time handed such a session a fresh week.
        seed!(store, "T", Dict{String,Any}("user_id" => 7, "theme" => "dark"); created = born)
        reset = mw(function (req::HTTP.Request)
            uid = getsession(req)["user_id"]
            empty!(getsession(req))
            Nitro.regenerate_session!(req, store; ttl=3600)
            getsession(req)["user_id"] = uid
            return HTTP.Response(200, "reset")
        end)
        kept = cookie_of(reset(HTTP.Request("POST", "/reset", ["Cookie" => "sid=T"])), "sid")
        @test kept != "T"
        @test Base.get(store, kept, nothing).created == born

        # "Empty" is not "anonymous" when identity lives outside the dict: an app whose `validator`
        # resolves it by session id keeps an empty dict while signed in, and a rotation there must
        # not reset the clock either. Same question `rotate_on_auth` asks.
        seed!(store, "V", Dict{String,Any}(); created = born)
        by_id = SessionMiddleware(cookie_name="sid", max_age=3600, store=store, secure=false,
                                  validator = (sid, data) -> "user-9").middleware
        rotated = cookie_of(by_id(req -> (Nitro.regenerate_session!(req, store; ttl=3600);
                                          HTTP.Response(200, "ok")))(
            HTTP.Request("POST", "/sudo", ["Cookie" => "sid=V"])), "sid")
        @test rotated != "V"
        @test Base.get(store, rotated, nothing).created == born
    end

    @testset "absolute_max_age = nothing switches the cap off (#362)" begin
        store = MemoryStore()
        seed!(store, "ancient", Dict{String,Any}("user_id" => 9);
              created = Dates.now(Dates.UTC) - Dates.Day(365))
        mw = SessionMiddleware(cookie_name="sid", max_age=3600, absolute_max_age=nothing,
                               store=store, secure=false).middleware
        res = mw(req -> (getsession(req)["seen"] = true;
                         HTTP.Response(200, string(getsession(req)["user_id"]))))(
            HTTP.Request("GET", "/", ["Cookie" => "sid=ancient"]))
        @test String(res.body) == "9"
        @test max_age_of(res) == 3600
    end

    @testset "absolute_max_age must be positive and bounded (#362)" begin
        for bad in (0, -1)
            err = try SessionMiddleware(store=MemoryStore(), absolute_max_age=bad); nothing catch e; e end
            @test err isa ArgumentError && occursin("absolute_max_age", err.msg)
        end
        # A huge value was a plausible way to write "unbounded", and `created + Second(n)` wraps
        # round to the past for it -- every session refused. `nothing` is the way to say it.
        @test Dates.DateTime(2026, 9, 25) + Dates.Second(typemax(Int)) < Dates.DateTime(2026, 9, 25)
        err = try SessionMiddleware(store=MemoryStore(), absolute_max_age=typemax(Int)); nothing catch e; e end
        @test err isa ArgumentError && occursin("100 years", err.msg)
        @test SessionMiddleware(store=MemoryStore(), absolute_max_age=100 * 365 * 86400) isa Nitro.Core.Types.LifecycleMiddleware
    end

    @testset "a session that reaches its deadline mid-request ends with it (#362)" begin
        # Loaded with 1.5 s left; the handler outlives that. Writing it back with a TTL of 0 would
        # store a row expired on arrival -- and the login rotation would report success for a
        # session the next request cannot see. It ends instead: nothing written, no cookie.
        #
        # The load must land inside that 1.5 s, so the exact wrapped handler is warmed first: its
        # first call compiles the whole request path, and on a loaded CI runner that alone could
        # outlast the budget -- the session would then be refused at LOAD, and the assertions
        # would fail as if the fix had regressed.
        slow = Ref(false)
        for (label, write!) in (
                "a plain write" => (s -> (s["n"] = 1)),
                "a login (rotate_on_auth)" => (s -> (s["user_id"] = 7)))
            @testset "$label" begin
                store = MemoryStore()
                cap = 3600
                mw = SessionMiddleware(cookie_name="sid", max_age=600, absolute_max_age=cap,
                                       store=store, secure=false).middleware
                wrapped = mw(req -> (write!(getsession(req)); slow[] && sleep(1.7); HTTP.Response(200, "ok")))
                slow[] = false
                wrapped(HTTP.Request("POST", "/", ["Cookie" => "sid=warm"]))   # warm-up, discarded
                empty!(store.data)

                seed!(store, "S", Dict{String,Any}("cart" => [1]);
                      created = Dates.now(Dates.UTC) - Dates.Second(cap) + Dates.Millisecond(1500))
                slow[] = true
                res = wrapped(HTTP.Request("POST", "/", ["Cookie" => "sid=S"]))
                slow[] = false
                @test res.status == 200
                @test isempty(filter(h -> lowercase(h.first) == "set-cookie", res.headers))
                @test isempty(store.data)   # neither S nor a rotated id survives
            end
        end
    end

    @testset "a store that cannot delete an over-age session does not fail the request (#362)" begin
        # The session is refused whether or not the delete lands, so a store error there is logged
        # -- by type only; its message could quote the key -- and the request goes on without it.
        struct DeleteFailingStore <: Nitro.Core.Types.AbstractSessionStore{String, Dict{String,Any}}
            inner::MemoryStore{String, Dict{String,Any}}
        end
        Base.get(s::DeleteFailingStore, id::String, default) = Base.get(s.inner, id, default)
        Nitro.Core.Types.set_session!(s::DeleteFailingStore, id::String, d::Dict{String,Any}; ttl::Int=3600) =
            Nitro.Core.Types.set_session!(s.inner, id, d; ttl)
        Nitro.Core.Types.delete_session!(::DeleteFailingStore, ::String) = error("store down: sid=S")

        store = DeleteFailingStore(MemoryStore())
        seed!(store.inner, "S", Dict{String,Any}("user_id" => 42); created = Dates.now(Dates.UTC) - Dates.Day(8))
        mw = SessionMiddleware(cookie_name="sid", store=store, secure=false).middleware
        reader = mw(req -> HTTP.Response(200, string(get(getsession(req), "user_id", "none"))))
        logger = Test.TestLogger()
        res = Base.CoreLogging.with_logger(logger) do
            reader(HTTP.Request("GET", "/", ["Cookie" => "sid=S"]))
        end
        @test res.status == 200
        @test String(res.body) == "none"
        @test length(logger.logs) == 1
        @test logger.logs[1].level == Base.CoreLogging.Warn
        @test occursin("absolute lifetime", logger.logs[1].message)
        @test !occursin("store down", sprint(show, logger.logs[1].kwargs))   # nor the key it quotes

        # An unrecoverable error is not swallowed (#254).
        Nitro.Core.Types.delete_session!(::DeleteFailingStore, ::String) = throw(InterruptException())
        @test_throws InterruptException reader(HTTP.Request("GET", "/", ["Cookie" => "sid=S"]))
    end

    @testset "a store that cannot say when a session was created fails closed under a cap (#362)" begin
        # `Base.get` must return a `SessionPayload`. One that hands back bare data has no creation
        # instant, and serving it would switch the cap off without a word.
        struct BareDataStore <: Nitro.Core.Types.AbstractSessionStore{String, Dict{String,Any}} end
        Base.get(::BareDataStore, ::String, default) = Dict{String,Any}("user_id" => 5)

        reader(mw) = mw(req -> HTTP.Response(200, string(get(getsession(req), "user_id", "none"))))
        req() = HTTP.Request("GET", "/", ["Cookie" => "sid=any"])

        capped = SessionMiddleware(cookie_name="sid", store=BareDataStore(), secure=false).middleware
        res = @test_logs (:warn, r"SessionPayload") reader(capped)(req())
        @test String(res.body) == "none"

        uncapped = SessionMiddleware(cookie_name="sid", store=BareDataStore(), secure=false,
                                     absolute_max_age=nothing).middleware
        @test String(reader(uncapped)(req()).body) == "5"
    end

    # ── #391: signing out everywhere ─────────────────────────────────────────
    #
    # A per-session logout knows only the id in its own request, so a rotation that commits just
    # before it leaves the rotated session alive -- the second order of the #361 race. The
    # `session_auth_hash` hook ends every session of a user whatever its id. `versions` is the
    # app-side state the hook reads (a per-user counter), and `calls` counts hook calls.
    function auth_hash_fixture(; hook = nothing)
        store = MemoryStore()
        versions = Dict{Int,Int}(42 => 1, 43 => 7)
        calls = Ref(0)
        hook = something(hook, uid -> (calls[] += 1; haskey(versions, uid) ? "v$(versions[uid])" : nothing))
        mw = SessionMiddleware(cookie_name="sid", max_age=3600, store=store, secure=false,
                               session_auth_hash=hook).middleware
        return store, versions, calls, mw
    end
    send_as(mw, handler, sid) = mw(handler)(HTTP.Request("POST", "/",
        sid === nothing ? Pair{String,String}[] : ["Cookie" => "sid=$sid"]))
    sign_in(uid) = req -> (getsession(req)["user_id"] = uid; HTTP.Response(200, "in"))
    whoami = req -> HTTP.Response(200, string(get(getsession(req), "user_id", "anon")))
    who(mw, sid) = String(send_as(mw, whoami, sid).body)
    stamp_of(store, sid) = get(Base.get(store, sid, nothing).data, "_nitro_auth_hash", nothing)

    @testset "login stamps the session; clearing the identity removes the stamp (#391)" begin
        store, versions, calls, mw = auth_hash_fixture()
        sid = cookie_of(send_as(mw, sign_in(42), nothing), "sid")
        @test stamp_of(store, sid) == "v1"
        @test who(mw, sid) == "42"

        # Signing out while keeping the cart: the identity goes, and so does its stamp.
        res = send_as(mw, req -> (delete!(getsession(req), "user_id");
                                  getsession(req)["cart"] = [1]; HTTP.Response(200, "out")), sid)
        anon = cookie_of(res, "sid")
        @test Base.get(store, anon, nothing).data == Dict{String,Any}("cart" => [1])
    end

    @testset "the logout recipe still starts a fresh clock under the hook (#362, #391)" begin
        store, versions, calls, mw = auth_hash_fixture()
        born = Dates.now(Dates.UTC) - Dates.Day(6)
        seed!(store, "S", Dict{String,Any}("user_id" => 42, "_nitro_auth_hash" => "v1"); created = born)
        before = Dates.now(Dates.UTC)
        anon = cookie_of(send_as(mw, function (req::HTTP.Request)
            empty!(getsession(req))
            Nitro.regenerate_session!(req, store; ttl=3600)
            return HTTP.Response(200, "bye")
        end, "S"), "sid")
        @test Base.get(store, anon, nothing).data == Dict{String,Any}()
        @test Base.get(store, anon, nothing).created >= before
    end

    @testset "sign out everywhere ends every session of that user, and only theirs (#391)" begin
        store, versions, calls, mw = auth_hash_fixture()
        laptop = cookie_of(send_as(mw, sign_in(42), nothing), "sid")
        phone = cookie_of(send_as(mw, sign_in(42), nothing), "sid")
        other = cookie_of(send_as(mw, sign_in(43), nothing), "sid")

        versions[42] += 1                     # what the app's "sign out everywhere" does

        for sid in (laptop, phone)
            res = send_as(mw, whoami, sid)
            @test String(res.body) == "anon"
            @test Base.get(store, sid, nothing) === nothing     # deleted, not merely refused
            @test isempty(filter(h -> lowercase(h.first) == "set-cookie", res.headers))
        end
        @test who(mw, other) == "43"
    end

    @testset "the rotation-before-logout residual is closed (#391)" begin
        # A rotates S → N and commits FIRST. B's logout then targets S, which is gone. The
        # browser holds N. With a per-session logout N stays signed in; the control shows that.
        logout_everywhere(store, versions) = function (req::HTTP.Request)
            versions[42] += 1
            empty!(getsession(req))
            Nitro.regenerate_session!(req, store; ttl=3600)
            return HTTP.Response(200, "bye")
        end
        # (label, who S is signed in as, S's stamp, A's handler). The `rotate_on_auth` case is A
        # switching S from user 43 to 42, so N is also a fresh login that the logout must end.
        for (label, uid, stamp, rotate_A!) in (
                ("explicit regenerate_session!", 42, "v1",
                    store -> (req -> (Nitro.regenerate_session!(req, store; ttl=3600); HTTP.Response(200, "A")))),
                ("rotate_on_auth on a user switch", 43, "v7", store -> sign_in(42)))
            @testset "$label" begin
                # Control: no hook. The residual #391 describes.
                store = MemoryStore()
                storesession!(store, "S", Dict{String,Any}("user_id" => uid); ttl=3600)
                plain = SessionMiddleware(cookie_name="sid", max_age=3600, store=store, secure=false).middleware
                N = cookie_of(send_as(plain, rotate_A!(store), "S"), "sid")
                send_as(plain, logout_everywhere(store, Dict(42 => 1)), "S")
                @test who(plain, N) == "42"

                # With the hook, the same sequence ends N.
                store, versions, calls, mw = auth_hash_fixture()
                storesession!(store, "S", Dict{String,Any}("user_id" => uid, "_nitro_auth_hash" => stamp); ttl=3600)
                N = cookie_of(send_as(mw, rotate_A!(store), "S"), "sid")
                @test N !== nothing && N != "S"
                @test who(mw, N) == "42"                   # A's rotation really happened
                send_as(mw, logout_everywhere(store, versions), "S")
                @test who(mw, N) == "anon"
                @test Base.get(store, N, nothing) === nothing
            end
        end
    end

    @testset "a rotation does not re-stamp, so it cannot outlive a logout it raced (#391)" begin
        # The sign-out-everywhere lands while A is still running, before A rotates. Were the stamp
        # refreshed on rotation, N would carry the post-logout value and survive it.
        store, versions, calls, mw = auth_hash_fixture()
        storesession!(store, "S", Dict{String,Any}("user_id" => 42, "_nitro_auth_hash" => "v1"); ttl=3600)
        N = cookie_of(send_as(mw, function (req::HTTP.Request)
            versions[42] += 1
            Nitro.regenerate_session!(req, store; ttl=3600)
            return HTTP.Response(200, "A")
        end, "S"), "sid")
        @test N !== nothing && N != "S"
        @test stamp_of(store, N) == "v1"
        @test who(mw, N) == "anon"
    end

    @testset "a session signed in before the hook was switched on is refused (#391)" begin
        store, versions, calls, mw = auth_hash_fixture()
        storesession!(store, "legacy", Dict{String,Any}("user_id" => 42); ttl=3600)
        storesession!(store, "cart", Dict{String,Any}("cart" => [1]); ttl=3600)
        @test who(mw, "legacy") == "anon"
        @test Base.get(store, "legacy", nothing) === nothing
        # Anonymous sessions are untouched, and cost no hook call.
        before = calls[]
        @test String(send_as(mw, req -> HTTP.Response(200, string(getsession(req)["cart"])), "cart").body) == "[1]"
        @test calls[] == before
    end

    @testset "anonymous sessions never call the hook (#391)" begin
        store, versions, calls, mw = auth_hash_fixture()
        sid = cookie_of(send_as(mw, req -> (getsession(req)["cart"] = [1]; HTTP.Response(200, "ok")), nothing), "sid")
        for _ in 1:3
            send_as(mw, req -> (push!(getsession(req)["cart"], 2); HTTP.Response(200, "ok")), sid)
        end
        @test calls[] == 0
        @test !haskey(Base.get(store, sid, nothing).data, "_nitro_auth_hash")
    end

    @testset "a user the hook no longer knows is refused (#391)" begin
        store, versions, calls, mw = auth_hash_fixture()
        sid = cookie_of(send_as(mw, sign_in(42), nothing), "sid")
        delete!(versions, 42)                 # the user was deleted
        @test who(mw, sid) == "anon"

        # Signing in as someone the hook does not know leaves no stamp, so it never loads.
        ghost = cookie_of(send_as(mw, sign_in(99), nothing), "sid")
        @test stamp_of(store, ghost) === nothing
        @test who(mw, ghost) == "anon"
    end

    @testset "a user switch stamps the new user's value (#391)" begin
        store, versions, calls, mw = auth_hash_fixture()
        sid = cookie_of(send_as(mw, sign_in(42), nothing), "sid")
        switched = cookie_of(send_as(mw, sign_in(43), sid), "sid")
        @test switched != sid
        @test stamp_of(store, switched) == "v7"
        versions[42] += 1                     # signing 42 out everywhere does not touch 43
        @test who(mw, switched) == "43"
    end

    @testset "signing back in over a revoked session is a fresh login (#391)" begin
        # The load check runs BEFORE the pre-handler identity is taken. Were it after, the
        # handler's `user_id = 42` over the revoked `user_id = 42` would read as unchanged: no
        # stamp, and the new login refused on its next request.
        store, versions, calls, mw = auth_hash_fixture()
        storesession!(store, "S", Dict{String,Any}("user_id" => 42, "_nitro_auth_hash" => "v1"); ttl=3600)
        versions[42] = 2
        fresh = cookie_of(send_as(mw, sign_in(42), "S"), "sid")
        @test Base.get(store, "S", nothing) === nothing
        @test fresh !== nothing && fresh != "S"
        @test stamp_of(store, fresh) == "v2"
        @test who(mw, fresh) == "42"
    end

    @testset "an identity found by `validator` is stamped and checked too (#391)" begin
        # Identity under a key other than `auth_key`, resolved by a validator that reads the
        # session data it is handed -- the shape the docstring requires under the hook.
        store = MemoryStore()
        versions = Dict(42 => 1)
        hook = uid -> haskey(versions, uid) ? "v$(versions[uid])" : nothing
        mw = SessionMiddleware(cookie_name="sid", max_age=3600, store=store, secure=false,
                               validator=Nitro.Auth.session_user_validator(store; user_key="uid"),
                               session_auth_hash=hook).middleware
        sid = cookie_of(send_as(mw, req -> (getsession(req)["uid"] = 42; HTTP.Response(200, "in")), nothing), "sid")
        @test stamp_of(store, sid) == "v1"
        uid_of = req -> HTTP.Response(200, string(get(getsession(req), "uid", "anon")))
        @test String(send_as(mw, uid_of, sid).body) == "42"
        versions[42] += 1
        @test String(send_as(mw, uid_of, sid).body) == "anon"
        @test Base.get(store, sid, nothing) === nothing
    end

    @testset "a hook may return any string type (#391)" begin
        # `split` hands back `SubString`s; the stamp is stored as a plain `String`.
        store, versions, calls, mw = auth_hash_fixture(hook = uid -> first(split("v1 extra")))
        sid = cookie_of(send_as(mw, sign_in(42), nothing), "sid")
        @test stamp_of(store, sid) isa String
        @test stamp_of(store, sid) == "v1"
        @test who(mw, sid) == "42"
    end

    @testset "rehash_session! keeps the session that made the change (#391)" begin
        @test :rehash_session! in names(Nitro)
        store, versions, calls, mw = auth_hash_fixture()
        here = cookie_of(send_as(mw, sign_in(42), nothing), "sid")
        elsewhere = cookie_of(send_as(mw, sign_in(42), nothing), "sid")

        # "Sign out my other devices": bump, and keep this one.
        res = send_as(mw, req -> (versions[42] += 1; Nitro.rehash_session!(req); HTTP.Response(200, "ok")), here)
        @test stamp_of(store, here) == "v2"
        @test who(mw, here) == "42"
        @test who(mw, elsewhere) == "anon"

        # The same change without it signs this session out too.
        res = send_as(mw, req -> (versions[42] += 1; HTTP.Response(200, "ok")), here)
        @test who(mw, here) == "anon"

        # A flag, nothing more: without the hook it changes nothing.
        plain_store = MemoryStore()
        plain = SessionMiddleware(cookie_name="sid", store=plain_store, secure=false).middleware
        sid = cookie_of(send_as(plain, sign_in(42), nothing), "sid")
        send_as(plain, req -> (Nitro.rehash_session!(req); HTTP.Response(200, "ok")), sid)
        @test Base.get(plain_store, sid, nothing).data == Dict{String,Any}("user_id" => 42)
    end

    @testset "a hook returning a non-String is a TypeError (#391)" begin
        store, versions, calls, mw = auth_hash_fixture(hook = uid -> 1)
        @test_throws TypeError send_as(mw, sign_in(42), nothing)
    end

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

    # ── #440: unconfirmed anonymous sessions, and a store that bounds itself ──────────
    #
    # A cookieless request to a route that writes the session used to store a row live for the
    # whole `max_age` (24 h), so a flood grew a database store faster than the janitor could
    # reclaim it. A new anonymous session now lives `unconfirmed_max_age` until its cookie comes
    # back, and a store may refuse new anonymous sessions outright through `session_store_full`.

    # Wraps a `MemoryStore` and counts every write the middleware makes, by kind. `full` is what
    # `session_store_full` answers.
    struct CountingStore <: Nitro.Core.Types.AbstractSessionStore{String, Dict{String,Any}}
        inner::MemoryStore{String, Dict{String,Any}}
        writes::Dict{Symbol,Int}
        full::Base.RefValue{Bool}
    end
    CountingStore(; full = false) = CountingStore(MemoryStore(), Dict{Symbol,Int}(), Ref(full))
    _count!(s::CountingStore, k::Symbol) = (s.writes[k] = get(s.writes, k, 0) + 1)
    Base.get(s::CountingStore, id::String, default) = Base.get(s.inner, id, default)
    Nitro.Core.Types.set_session!(s::CountingStore, id::String, d::Dict{String,Any}; ttl::Int = 3600) =
        (_count!(s, :set); Nitro.Core.Types.set_session!(s.inner, id, d; ttl))
    Nitro.Core.Types.update_session!(s::CountingStore, id::String, d::Dict{String,Any}; ttl::Int = 3600) =
        (_count!(s, :update); Nitro.Core.Types.update_session!(s.inner, id, d; ttl))
    Nitro.Core.Types.rotate_session!(s::CountingStore, old::String, new::String, d::Dict{String,Any}; ttl::Int = 3600) =
        (_count!(s, :rotate); Nitro.Core.Types.rotate_session!(s.inner, old, new, d; ttl))
    Nitro.Core.Types.delete_session!(s::CountingStore, id::String) =
        (_count!(s, :delete); Nitro.Core.Types.delete_session!(s.inner, id))
    Nitro.Core.Types.session_store_full(s::CountingStore) = s.full[]
    total_writes(s::CountingStore) = sum(values(s.writes); init = 0)
    lifetime_of(store, sid) = (p = Base.get(store, sid, nothing);
                               Dates.value(p.expires - p.created) ÷ 1000)
    cart_writer(mw) = mw(req -> (push!(get!(getsession(req), "cart", Any[]), 1); HTTP.Response(200, "ok")))
    session_reader(mw) = mw(req -> HTTP.Response(200, string(length(getsession(req)))))

    @testset "a new anonymous session is saved unconfirmed (#440)" begin
        @test Nitro.Core.Middleware.SessionMiddleware_.DEFAULT_UNCONFIRMED_MAX_AGE == 3600
        store = MemoryStore()
        mw = SessionMiddleware(cookie_name="sid", store=store, secure=false).middleware   # max_age 1 day

        res = cart_writer(mw)(HTTP.Request("GET", "/add"))
        sid = cookie_of(res, "sid")
        @test sid !== nothing
        # An hour, not the day `max_age` gives: in the store and in the cookie alike.
        @test max_age_of(res) == 3600
        @test lifetime_of(store, sid) == 3600
    end

    @testset "its cookie coming back confirms it, with exactly one write (#440)" begin
        store = CountingStore()
        mw = SessionMiddleware(cookie_name="sid", store=store, secure=false).middleware
        sid = cookie_of(cart_writer(mw)(HTTP.Request("GET", "/add")), "sid")
        born = Base.get(store, sid, nothing).created
        @test store.writes == Dict(:set => 1)

        # The browser's next request -- a read, an asset -- is the confirmation: one update to the
        # full lifetime, the cookie re-set to match, the creation instant kept.
        res = session_reader(mw)(HTTP.Request("GET", "/page", ["Cookie" => "sid=$sid"]))
        @test String(res.body) == "1"                      # the cart survived
        @test store.writes == Dict(:set => 1, :update => 1)
        @test cookie_of(res, "sid") == sid
        @test max_age_of(res) == 86400
        @test lifetime_of(store, sid) >= 86400
        @test Base.get(store, sid, nothing).created == born

        # Confirmed: a read writes nothing from here on.
        res = session_reader(mw)(HTTP.Request("GET", "/page", ["Cookie" => "sid=$sid"]))
        @test store.writes == Dict(:set => 1, :update => 1)
        @test isempty(HTTP.header(res, "Set-Cookie"))
    end

    @testset "an unconfirmed session that is never returned lapses at its short lifetime (#440)" begin
        # What bounds the flood: once `expires` passes, the row is dead to every reader and the
        # janitor's prune deletes it. Staged with a past `expires` rather than waited out.
        store = MemoryStore()
        mw = SessionMiddleware(cookie_name="sid", store=store, secure=false).middleware
        sid = cookie_of(cart_writer(mw)(HTTP.Request("GET", "/add")), "sid")
        p = Base.get(store, sid, nothing)
        @test p.expires <= Dates.now(Dates.UTC) + Dates.Second(3600)
        seed!(store, sid, p.data; created = p.created - Dates.Hour(2), expires = p.expires - Dates.Hour(2))
        prunesessions!(store)
        @test Base.get(store, sid, nothing) === nothing
    end

    @testset "a new session that ends signed in gets the full lifetime (#440)" begin
        store = MemoryStore()
        mw = SessionMiddleware(cookie_name="sid", store=store, secure=false).middleware
        # A login from a cookieless client: the session is new and ends the request with an identity.
        res = mw(req -> (getsession(req)["user_id"] = 7; HTTP.Response(200, "in")))(
            HTTP.Request("POST", "/login"))
        @test max_age_of(res) == 86400
        @test lifetime_of(store, cookie_of(res, "sid")) == 86400

        # So does an identity found by `validator`, not `auth_key`.
        vmw = SessionMiddleware(cookie_name="sid", store=store, secure=false,
                                validator = (sid, data) -> get(data, "account", nothing)).middleware
        res = vmw(req -> (getsession(req)["account"] = "a-1"; HTTP.Response(200, "in")))(
            HTTP.Request("POST", "/login"))
        @test max_age_of(res) == 86400
    end

    @testset "logout leaves a full-lifetime session, not an unconfirmed one (#440)" begin
        store = MemoryStore()
        seed!(store, "in", Dict{String,Any}("user_id" => 7); created = Dates.now(Dates.UTC) - Dates.Hour(1),
              expires = Dates.now(Dates.UTC) + Dates.Hour(23))
        mw = SessionMiddleware(cookie_name="sid", store=store, secure=false).middleware
        res = mw(function (req::HTTP.Request)
            empty!(getsession(req))
            Nitro.regenerate_session!(req, store)
            return HTTP.Response(200, "out")
        end)(HTTP.Request("POST", "/logout", ["Cookie" => "sid=in"]))
        @test max_age_of(res) == 86400
        @test lifetime_of(store, cookie_of(res, "sid")) == 86400
    end

    @testset "`unconfirmed_max_age = nothing` switches it off (#440)" begin
        store = CountingStore()
        mw = SessionMiddleware(cookie_name="sid", store=store, secure=false,
                               unconfirmed_max_age=nothing).middleware
        res = cart_writer(mw)(HTTP.Request("GET", "/add"))
        sid = cookie_of(res, "sid")
        @test max_age_of(res) == 86400
        res = session_reader(mw)(HTTP.Request("GET", "/page", ["Cookie" => "sid=$sid"]))
        @test store.writes == Dict(:set => 1)                # no confirmation write
        @test isempty(HTTP.header(res, "Set-Cookie"))
    end

    @testset "the default follows the full lifetime, and bad values are refused (#440)" begin
        new_max_age(; kw...) = max_age_of(cart_writer(SessionMiddleware(;
            cookie_name="sid", store=MemoryStore(), secure=false, kw...).middleware)(HTTP.Request("GET", "/")))
        @test new_max_age() == 3600
        @test new_max_age(max_age = 3600) == 1800                    # half the full lifetime
        @test new_max_age(absolute_max_age = 1000) == 500            # the cap shortens it too
        @test new_max_age(max_age = 100) == 100                      # under two minutes: off
        @test new_max_age(unconfirmed_max_age = 60) == 60

        build(; kw...) = SessionMiddleware(; cookie_name="sid", store=MemoryStore(), secure=false, kw...)
        @test_throws ArgumentError build(unconfirmed_max_age = 0)
        @test_throws ArgumentError build(unconfirmed_max_age = -5)
        @test_throws ArgumentError build(max_age = 3600, unconfirmed_max_age = 1801)
        @test_throws ArgumentError build(absolute_max_age = 1000, unconfirmed_max_age = 501)
        @test build(max_age = 3600, unconfirmed_max_age = 1800) isa Nitro.Types.LifecycleMiddleware
    end

    @testset "a session stored with another short lifetime is not mistaken for unconfirmed (#440)" begin
        # Only a lifetime of exactly `unconfirmed_max_age` reads as unconfirmed, so a session an
        # app stored itself with a short ttl is not stretched to `max_age` by a read.
        store = CountingStore()
        Nitro.Core.Types.set_session!(store.inner, "short", Dict{String,Any}("k" => 1); ttl = 600)
        mw = SessionMiddleware(cookie_name="sid", store=store, secure=false).middleware
        res = session_reader(mw)(HTTP.Request("GET", "/", ["Cookie" => "sid=short"]))
        @test String(res.body) == "1"
        @test total_writes(store) == 0
        @test lifetime_of(store, "short") == 600
    end

    @testset "a full store refuses new anonymous sessions, and nothing else (#440)" begin
        store = CountingStore(full = true)
        mw = SessionMiddleware(cookie_name="sid", store=store, secure=false).middleware

        # Refused: no row, no cookie, one warning -- and the request still succeeds.
        res = @test_logs (:warn, r"session store is full") cart_writer(mw)(HTTP.Request("GET", "/add"))
        @test res.status == 200
        @test isempty(HTTP.header(res, "Set-Cookie"))
        @test total_writes(store) == 0
        # Once per middleware, not per refusal: a flood does not become a log flood.
        res = @test_logs min_level=Base.CoreLogging.Warn cart_writer(mw)(HTTP.Request("GET", "/add"))
        @test isempty(HTTP.header(res, "Set-Cookie"))

        # A cookieless login is never refused: a full store must not lock new users out of signing in.
        res = mw(req -> (getsession(req)["user_id"] = 7; HTTP.Response(200, "in")))(
            HTTP.Request("POST", "/login"))
        @test cookie_of(res, "sid") !== nothing
        @test store.writes[:set] == 1

        # An existing session keeps being written, and its rotation on login goes through.
        Nitro.Core.Types.set_session!(store.inner, "anon", Dict{String,Any}("cart" => [1]); ttl = 86400)
        mw(req -> (push!(getsession(req)["cart"], 2); HTTP.Response(200, "ok")))(
            HTTP.Request("GET", "/add", ["Cookie" => "sid=anon"]))
        @test store.writes[:update] == 1
        res = mw(req -> (getsession(req)["user_id"] = 8; HTTP.Response(200, "in")))(
            HTTP.Request("POST", "/login", ["Cookie" => "sid=anon"]))
        @test store.writes[:rotate] == 1
        @test cookie_of(res, "sid") ∉ (nothing, "anon")

        # A store that does not implement the hook is never full.
        @test Nitro.Core.Types.session_store_full(MemoryStore()) === false
    end

end

end
