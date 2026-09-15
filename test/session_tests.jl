@testitem "Session" tags=[:core] setup=[NitroCommon] begin

using Nitro
using Nitro.Types
using Test
using HTTP
using Dates

struct User
    id::Int
    name::String
end

# A minimal store that implements only the `Base.get` half of the contract, so `get_session`
# resolves to the GENERIC `AbstractSessionStore` method rather than a specialisation. Mints on
# read for the same reason `SameTickStore` does (#173).
struct BoundaryStore <: Nitro.Types.AbstractSessionStore{String, Dict{String,Any}} end
Base.get(::BoundaryStore, ::String, default) =
    SessionPayload(Dict{String,Any}("user_id" => 7), Dates.now(Dates.UTC))

# Stages the boundary case `expires == now` against the real clock, which is otherwise
# unstageable: the payload is minted ON READ, so its `expires` clock read and the read path's
# own `Dates.now(UTC)` are microseconds apart. `DateTime` has millisecond resolution, so the
# two land in the SAME tick nearly every time -- exactly the payload `<` served and `<=`
# refuses. Deliberately NOT an AbstractSessionStore: that is what routes the `Session{T}`
# extractor down its `SessionPayload` fallback (#173).
struct SameTickStore end
Base.get(::SameTickStore, ::String, default) =
    SessionPayload(Dict{String,Any}("user_id" => 7), Dates.now(Dates.UTC))

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

    # ── #173: one expiry predicate, and the boundary belongs to the expired side ──
    #
    # Expiry was written out at six sites. Five spelled `<=`; the `Session{T}` extractor's
    # `SessionPayload` fallback spelled `<`, so a payload landing on exactly the current
    # instant was served there and refused everywhere else. Every read path calls
    # `Dates.now(UTC)` internally, so the boundary is only stageable through the two-arg
    # `is_expired` -- which is why the helper takes an `at`.
    @testset "is_expired: the boundary is expired (#173)" begin
        at = DateTime(2030, 1, 1, 12, 0, 0)
        d  = Dict{String,Any}("user_id" => 7)

        @test is_expired(SessionPayload(d, at), at) === true                      # the boundary
        @test is_expired(SessionPayload(d, at + Millisecond(1)), at) === false    # not yet
        @test is_expired(SessionPayload(d, at - Millisecond(1)), at) === true     # long gone

        # The one-arg form is the two-arg form against the clock.
        @test is_expired(SessionPayload(d, Dates.now(Dates.UTC) - Second(10))) === true
        @test is_expired(SessionPayload(d, Dates.now(Dates.UTC) + Hour(1))) === false

        # Public, so a third-party `AbstractSessionStore` has something to call instead of
        # re-deriving the comparison -- which is how the six sites drifted apart.
        @test :is_expired in names(Nitro)
    end

    @testset "every read path refuses a payload on the boundary (#173)" begin
        configcookies(secret_key=nothing)
        d = Dict{String,Any}("user_id" => 7)
        mint() = SessionPayload(d, Dates.now(Dates.UTC))
        N = 200

        # Every path below is exercised in a WARM loop with the payload minted immediately
        # before the read, so `expires` and the read path's own `Dates.now(UTC)` land in the
        # same millisecond tick -- the true `expires == now` boundary.
        #
        # Two things that look equivalent and are not, both of which silently turn this into
        # a past-dated test where `<` and `<=` agree:
        #   * `sleep()` before the read -- puts the payload strictly in the past.
        #   * a single COLD call -- JIT compilation between the two clock reads takes far
        #     more than the 1ms of DateTime resolution.
        # Zero tolerance: one served session means a read path is back on the lenient `<`.

        # 1. get_session(::MemoryStore, ...) -- the concrete store method.
        mem = MemoryStore()
        mem.data["sid"] = mint(); get_session(mem, "sid")                    # warm up
        @test count(1:N) do _
            mem.data["sid"] = mint()
            get_session(mem, "sid") !== nothing
        end == 0

        # 2. The generic get_session(::AbstractSessionStore, ...) fallback: `BoundaryStore`
        #    does not specialise `get_session`, so it resolves to the generic method.
        get_session(BoundaryStore(), "sid")                                  # warm up
        @test count(1:N) do _
            get_session(BoundaryStore(), "sid") !== nothing
        end == 0

        # 3. `_load_session`, the SessionMiddleware read path: a boundary payload must be
        #    treated as a brand-new session, not resumed. A resumed one carries the payload's
        #    data, so a non-empty session dict is a served session.
        store = MemoryStore()
        seen = Ref{Any}(nothing)
        wrapped = SessionMiddleware(cookie_name="b_session", store=store).middleware(
            function (req::HTTP.Request)
                seen[] = copy(getsession(req))
                return HTTP.Response(200, "ok")
            end)
        probe() = begin
            store.data["boundary-id"] = mint()
            wrapped(HTTP.Request("GET", "/", ["Cookie" => "b_session=boundary-id"]))
            seen[]
        end
        probe()                                                              # warm up
        @test count(_ -> !isempty(probe()), 1:N) == 0

        # 4. The `Session{T}` extractor's SessionPayload fallback -- the site that said `<`.
        #    Reachable ONLY through a store that is NOT an AbstractSessionStore but DOES hold
        #    SessionPayloads; an AbstractSessionStore takes the `get_session` branch above and
        #    never reaches it, which is why this line had no coverage at all before #173.
        urlpatterns("",
            path("/boundary", function(req, session::Session{Dict{String,Any}})
                return isnothing(session.payload) ? "Expired" : "Active"
            end, method="GET"),
        )

        # A payload comfortably in the past, and one comfortably in the future -- basic
        # regression cover for a branch that had none. NOTE: these two pass under `<` too;
        # they are coverage, not the boundary.
        raw = Dict{String, SessionPayload{Dict{String,Any}}}()
        raw["past-id"] = SessionPayload(d, Dates.now(Dates.UTC) - Second(10))
        raw["live-id"] = SessionPayload(d, Dates.now(Dates.UTC) + Hour(1))
        @test text(internalrequest(
            Request("GET", "/boundary", ["Cookie" => "session=past-id"]); context=raw)) == "Expired"
        @test text(internalrequest(
            Request("GET", "/boundary", ["Cookie" => "session=live-id"]); context=raw)) == "Active"

        # THE boundary, on the extractor. Assumes only that the wall clock does not step
        # BACKWARDS between the store's clock read and the extractor's; an NTP step back
        # between the two would serve one iteration and read as a mysterious flake.
        same_tick = SameTickStore()
        served = count(1:N) do _
            text(internalrequest(
                Request("GET", "/boundary", ["Cookie" => "session=any"]); context=same_tick)) == "Active"
        end
        @test served == 0
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
            store=store, secure=false,
            httponly=false,
            samesite="Strict"
        ).middleware

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
        # whether the session ID must be regenerated. It never populates the request user.

        cookie_of(resp) = match(r"app_session=([^;]+)", HTTP.header(resp, "Set-Cookie", "")).captures[1]

        # Helper: seed a store with an existing session under a known id, then drive one
        # request whose handler mutates the session, and report whether the id rotated.
        function run_with_existing(; validator, auth_key="user_id", seed::Dict{String,Any}, mutate!)
            store = MemoryStore{String, Dict{String,Any}}()
            set_session!(store, "existing-id", seed; ttl=120)
            mw = SessionMiddleware(cookie_name="app_session", store=store, secure=false, auth_key=auth_key, validator=validator).middleware
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
        # never writes the request user (it is not an auth-context populator).
        req_probe, resp_probe = run_with_existing(
            validator = session_id -> session_id,               # 1-arg form
            seed=Dict{String,Any}("cart" => [1]),
            mutate! = s -> (s["cart"] = [1, 2]),
        )
        @test resp_probe.status == 200
        @test !haskey(req_probe.context, :user)                 # never populates the user slot
        @test getuser(req_probe) === nothing                    # ... and the accessor agrees
    end

end

    # ── Background pruning (#36) ──────────────────────────────────────────────
    # Pruning used to happen inline on ~1% of requests, holding MemoryStore's single
    # lock across a full O(N) scan. It is a lifecycle-owned background janitor now, so
    # these testsets drive the hooks directly rather than sending traffic.

    @testset "Session janitor prunes with no request traffic at all" begin
        store = MemoryStore{String, Dict{String,Any}}()
        for i in 1:5
            Nitro.Cookies.storesession!(store, "gone-$i", Dict{String,Any}("i" => i), ttl=1)
        end
        Nitro.Cookies.storesession!(store, "stays", Dict{String,Any}("i" => 0), ttl=3600)
        @test length(store.data) == 6

        lf = SessionMiddleware(store=store, prune_interval=Millisecond(50))
        @test lf isa Nitro.LifecycleMiddleware

        sleep(1.1)                      # let the five short-TTL entries expire
        @test length(store.data) == 6   # still there: nothing prunes until the janitor runs

        task = lf.on_startup()
        @test task isa Task
        try
            # The janitor ticks every 50ms; give it several ticks of headroom.
            deadline = time() + 5.0
            while length(store.data) > 1 && time() < deadline
                sleep(0.05)
            end
            @test length(store.data) == 1
            @test haskey(store.data, "stays")
        finally
            lf.on_shutdown()
        end
    end

    @testset "Session janitor hooks are idempotent across a restart" begin
        # Same shape as the RateLimiter regression in lifecycle_middleware_tests.jl: a
        # single shared `running` flag leaked one task per serve/terminate cycle, because
        # the stale task woke and read the flag the NEW activation had just set.
        store = MemoryStore{String, Dict{String,Any}}()
        lf = SessionMiddleware(store=store, prune_interval=Millisecond(50))

        t1 = lf.on_startup()
        @test t1 isa Task
        @test lf.on_startup() === nothing     # already running: no second task
        @test lf.on_shutdown() === t1

        t2 = lf.on_startup()                  # restart gets its own token and task
        @test t2 isa Task
        @test t2 !== t1
        lf.on_shutdown()
        @test lf.on_shutdown() === nothing    # idempotent when already stopped

        # The first activation's task must actually exit rather than loop forever.
        deadline = time() + 5.0
        while !istaskdone(t1) && time() < deadline
            sleep(0.05)
        end
        @test istaskdone(t1)
    end

    @testset "SessionPruner prunes a store used without SessionMiddleware" begin
        # The `Session{T}` extractor reads the store straight off the app context, so an
        # app on that path never installs SessionMiddleware and nothing ever pruned.
        store = MemoryStore{String, Dict{String,Any}}()
        Nitro.Cookies.storesession!(store, "expired", Dict{String,Any}("a" => 1), ttl=1)
        Nitro.Cookies.storesession!(store, "live", Dict{String,Any}("a" => 2), ttl=3600)
        sleep(1.1)
        @test length(store.data) == 2

        pruner = SessionPruner(store; interval=Millisecond(50))
        @test pruner isa Nitro.LifecycleMiddleware
        # It is a pass-through: the request function must not alter the response.
        @test pruner.middleware(req -> "untouched")(Request("GET", "/")) == "untouched"

        pruner.on_startup()
        try
            deadline = time() + 5.0
            while length(store.data) > 1 && time() < deadline
                sleep(0.05)
            end
            @test length(store.data) == 1
            @test haskey(store.data, "live")
        finally
            pruner.on_shutdown()
        end
    end

    @testset "prune_interval is validated at construction, not in the janitor" begin
        store = MemoryStore{String, Dict{String,Any}}()
        @test_throws ArgumentError SessionMiddleware(store=store, prune_interval=Second(0))
        @test_throws ArgumentError SessionPruner(store; interval=Second(-1))

        # Calendar periods are the dangerous case, and `Dates.value(p) > 0` does NOT catch
        # them: `Dates.value(Month(1))` is 1, so it passes — and then `sleep(Month(1))` throws
        # a MethodError inside the spawned task, where nothing is waiting on it. The janitor
        # would be dead for the life of the process while `serve()` reported success, i.e.
        # exactly the unbounded growth #36 exists to remove, silent instead of slow.
        for bad in (Month(1), Year(1), Quarter(1))
            @test_throws ArgumentError SessionMiddleware(store=store, prune_interval=bad)
            @test_throws ArgumentError SessionPruner(store; interval=bad)
        end
        # Sub-millisecond rounds to a zero-length sleep and spins.
        @test_throws ArgumentError SessionMiddleware(store=store, prune_interval=Nanosecond(500))

        # Fixed periods, including sub-second ones the tests above rely on, still build.
        @test SessionMiddleware(store=store, prune_interval=Millisecond(50)) isa Nitro.LifecycleMiddleware
        @test SessionMiddleware(store=store, prune_interval=Minute(10)) isa Nitro.LifecycleMiddleware
        @test SessionPruner(store; interval=Second(1)) isa Nitro.LifecycleMiddleware
    end

    @testset "A throwing store does not kill the janitor" begin
        # The `try` sits INSIDE the janitor's loop so a transient store failure costs one tick,
        # not the process's remaining pruning. Hoisting it outside the loop would turn a single
        # DB blip into a permanently dead janitor with a still-green suite — this is the test
        # that would catch that refactor.
        mutable struct FlakyStore <: Nitro.Types.AbstractSessionStore{String, Dict{String,Any}}
            inner::MemoryStore{String, Dict{String,Any}}
            failures_left::Int
            calls::Int
        end
        Nitro.Types.cleanup_expired_sessions!(s::FlakyStore) = begin
            s.calls += 1
            if s.failures_left > 0
                s.failures_left -= 1
                error("simulated store failure")
            end
            Nitro.Types.cleanup_expired_sessions!(s.inner)
        end

        inner = MemoryStore{String, Dict{String,Any}}()
        Nitro.Cookies.storesession!(inner, "dead", Dict{String,Any}("i" => 1), ttl=1)
        Nitro.Cookies.storesession!(inner, "live", Dict{String,Any}("i" => 2), ttl=3600)
        sleep(1.1)

        flaky = FlakyStore(inner, 3, 0)
        pruner = SessionPruner(flaky; interval=Millisecond(50))
        task = pruner.on_startup()
        try
            # It must survive the first three throwing ticks and still prune afterwards.
            @test timedwait(() -> length(inner.data) == 1, 10.0) === :ok
            @test haskey(inner.data, "live")
            @test flaky.calls > 3          # it really did keep ticking past the failures
            @test !istaskdone(task)        # and the janitor is still alive
        finally
            pruner.on_shutdown()
        end
    end

    @testset "cleanup_expired_sessions! removes every expired entry" begin
        # NOTE: this does NOT discriminate the one-pass/two-pass rewrite in
        # `cleanup_expired_sessions!` — measured, Julia's `delete!` only tombstones a slot and
        # never rehashes, so the old one-pass form skipped nothing. It is kept as a plain
        # behavioural assertion on the prune (every expired row goes, every live row stays) at
        # a store size the other tests do not cover.
        store = MemoryStore{String, Dict{String,Any}}()
        for i in 1:200
            Nitro.Cookies.storesession!(store, "dead-$i", Dict{String,Any}("i" => i), ttl=1)
        end
        for i in 1:50
            Nitro.Cookies.storesession!(store, "live-$i", Dict{String,Any}("i" => i), ttl=3600)
        end
        sleep(1.1)

        Nitro.Cookies.prunesessions!(store)

        @test length(store.data) == 50
        @test all(i -> haskey(store.data, "live-$i"), 1:50)
        @test !any(i -> haskey(store.data, "dead-$i"), 1:200)
    end

end

