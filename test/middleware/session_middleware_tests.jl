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
            store.data[sid] = SessionPayload(Dict{String,Any}(), Dates.now(Dates.UTC) + Dates.Second(5))
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
        res = reader(HTTP.Request("GET", "/app.js", ["Cookie" => "cache_session=$sid"]))
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
            store.data[expired_id] = SessionPayload(expired_data, Dates.now(Dates.UTC) - Dates.Second(10))
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
