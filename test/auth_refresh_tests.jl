# The refresh-token lifecycle (#231): the store contract, rotation, reuse detection and the pruner.
# Every item builds its own store; nothing here touches the global app.

# ── The store: contract and `MemoryRefreshTokenStore` ───────────────────────────────────────

@testitem "refresh tokens: the store contract (#231)" tags=[:auth, :core] setup=[NitroCommon] begin
    using Test
    using Nitro.Auth

    struct EmptyRefreshStore <: AbstractRefreshTokenStore end
    @test Set(missing_refresh_store_methods(EmptyRefreshStore)) ==
          Set([:record_refresh_token!, :consume_refresh_token!, :revoke_refresh_family!, :prune_refresh_tokens!])
    @test isempty(missing_refresh_store_methods(MemoryRefreshTokenStore))
    s = EmptyRefreshStore()
    @test_throws Nitro.Errors.StoreInterfaceError consume_refresh_token!(s, "secret-fam", "secret-jti"; at = 0)
    @test_throws Nitro.Errors.StoreInterfaceError record_refresh_token!(s, RefreshTokenRecord("j", "f", "s", 0); new_family = true)
    @test_throws Nitro.Errors.StoreInterfaceError revoke_refresh_family!(s, "f")
    @test_throws Nitro.Errors.StoreInterfaceError prune_refresh_tokens!(s; at = 0)
    # The interface error names the store, never the family or jti it was handed.
    err = try; consume_refresh_token!(s, "secret-fam", "secret-jti"; at = 0); catch e; e; end
    @test !occursin("secret-jti", sprint(showerror, err))
    @test !occursin("secret-fam", sprint(showerror, err))
    @test occursin("missing_refresh_store_methods", sprint(showerror, err))

    @test_throws ArgumentError RefreshTokenMiss(:nope)
    @test RefreshTokenMiss(:reused).reason === :reused
    # The record type renders neither its jti nor its family.
    @test !occursin("secret-jti", repr(RefreshTokenRecord("secret-jti", "secret-fam", "7", 0)))
    @test !occursin("secret-fam", repr(RefreshTokenRecord("secret-jti", "secret-fam", "7", 0)))
end

@testitem "refresh tokens: MemoryRefreshTokenStore records, consumes, revokes and prunes (#231)" tags=[:auth, :core] setup=[NitroCommon] begin
    using Test
    using Dates
    using Nitro.Auth

    rec(jti, fam, exp) = RefreshTokenRecord(jti, fam, "7", exp)
    store = MemoryRefreshTokenStore()

    # `new_family` decides whether the family must be absent, or present with no current token.
    @test record_refresh_token!(store, rec("a1", "A", 1_000); new_family = true)
    @test !record_refresh_token!(store, rec("a2", "A", 1_000); new_family = true)    # exists
    @test !record_refresh_token!(store, rec("x1", "X", 1_000); new_family = false)   # absent
    @test !record_refresh_token!(store, rec("a2", "A", 2_000); new_family = false)   # A still has a current token

    # Consume takes the current token once; the family then waits for its successor.
    first = consume_refresh_token!(store, "A", "a1"; at = 500)
    @test first isa RefreshTokenRecord && first.jti == "a1" && first.family == "A" && first.subject == "7"
    @test consume_refresh_token!(store, "A", "a1"; at = 500).reason === :reused       # second presentation
    @test record_refresh_token!(store, rec("a2", "A", 2_000); new_family = false)    # the successor
    @test consume_refresh_token!(store, "A", "a1"; at = 500).reason === :reused       # still recognized
    @test consume_refresh_token!(store, "Z", "a1"; at = 500).reason === :unknown
    @test consume_refresh_token!(store, "A", "a2"; at = 2_000).reason === :expired    # boundary is expired

    # Revoking removes the family: its tokens are unknown and nothing can be recorded into it.
    revoke_refresh_family!(store, "A")
    revoke_refresh_family!(store, "A")                                               # idempotent
    revoke_refresh_family!(store, "never-seen")                                      # a no-op
    @test consume_refresh_token!(store, "A", "a2"; at = 500).reason === :unknown
    @test !record_refresh_token!(store, rec("a3", "A", 3_000); new_family = false)

    # Prune at a chosen instant -- the janitor's tick, called directly: deterministic, no sleep.
    # A family lives until its LATEST token's expiry, so an old token with a longer `ttl` than the
    # current one is still caught as a reuse after the current one has expired.
    @test record_refresh_token!(store, rec("b1", "B", 5_000); new_family = true)
    @test consume_refresh_token!(store, "B", "b1"; at = 0) isa RefreshTokenRecord
    @test record_refresh_token!(store, rec("b2", "B", 1_500); new_family = false)
    prune_refresh_tokens!(store; at = 2_500)
    @test consume_refresh_token!(store, "B", "b1"; at = 2_500).reason === :reused
    prune_refresh_tokens!(store; at = 5_000)
    @test consume_refresh_token!(store, "B", "b1"; at = 0).reason === :unknown
    @test isempty(store.families)

    # The count bound: a new sign-in evicts the least recently used family, which then fails closed.
    small = MemoryRefreshTokenStore(max_tokens = 3)
    for i in 1:4
        @test record_refresh_token!(small, rec("t$i", "F$i", 1_000); new_family = true)
    end
    @test consume_refresh_token!(small, "F1", "t1"; at = 0).reason === :unknown
    @test consume_refresh_token!(small, "F4", "t4"; at = 0) isa RefreshTokenRecord
    @test_throws ArgumentError MemoryRefreshTokenStore(max_tokens = 0)
    @test !occursin("F4", repr(small))

    # The bound counts sign-ins, never refreshes. Ten rotations of B add no row, so A's live token
    # survives in a store that holds two families, and B's oldest token is still a reuse.
    churn = MemoryRefreshTokenStore(max_tokens = 2)
    @test record_refresh_token!(churn, rec("a", "A", 1_000); new_family = true)
    @test record_refresh_token!(churn, rec("b0", "B", 1_000); new_family = true)
    for i in 1:10
        @test consume_refresh_token!(churn, "B", "b$(i - 1)"; at = 0) isa RefreshTokenRecord
        @test record_refresh_token!(churn, rec("b$i", "B", 1_000); new_family = false)
    end
    @test consume_refresh_token!(churn, "A", "a"; at = 0) isa RefreshTokenRecord
    @test consume_refresh_token!(churn, "B", "b0"; at = 0).reason === :reused

    # Sign-in/sign-out cycles do not fill the table either: revoking deletes the family.
    cycle = MemoryRefreshTokenStore(max_tokens = 2)
    @test record_refresh_token!(cycle, rec("idle", "I", 1_000); new_family = true)
    for i in 1:5
        @test record_refresh_token!(cycle, rec("l$i", "L$i", 1_000); new_family = true)
        revoke_refresh_family!(cycle, "L$i")
    end
    @test consume_refresh_token!(cycle, "I", "idle"; at = 0) isa RefreshTokenRecord

    # The CAS: N concurrent consumes of one token, exactly one record.
    shared = MemoryRefreshTokenStore()
    @test record_refresh_token!(shared, rec("c1", "C", 1_000); new_family = true)
    outcomes = fetch.([Threads.@spawn consume_refresh_token!(shared, "C", "c1"; at = 0) for _ in 1:16])
    @test count(o -> o isa RefreshTokenRecord, outcomes) == 1
    @test all(o -> o isa RefreshTokenRecord || o.reason === :reused, outcomes)

    # The janitor: `RefreshTokenPruner` is the shared `_janitor` discipline, so it ticks the store's
    # prune, its hooks are idempotent, and it stops on shutdown.
    struct CountingStore <: AbstractRefreshTokenStore
        calls::Threads.Atomic{Int}
    end
    Nitro.Auth.prune_refresh_tokens!(s::CountingStore; at::Int) = (Threads.atomic_add!(s.calls, 1); nothing)
    counting = CountingStore(Threads.Atomic{Int}(0))
    lf = RefreshTokenPruner(counting; interval = Millisecond(20))
    @test lf isa Nitro.LifecycleMiddleware
    task = lf.on_startup()
    @test task isa Task
    @test lf.on_startup() === nothing
    @test timedwait(() -> counting.calls[] > 0, 10.0) === :ok
    lf.on_shutdown()
    @test timedwait(() -> istaskdone(task), 10.0) === :ok
    @test_throws ArgumentError RefreshTokenPruner(counting; interval = Month(1))
end

# ── Rotation ────────────────────────────────────────────────────────────────────────────────

@testitem "refresh tokens: rotation spends the old jti and issues a new one (#231)" tags=[:auth, :core] setup=[NitroCommon] begin
    using Test
    using Nitro.Auth

    ts() = Nitro.Auth._current_timestamp()
    secret = jwtkey("refresh")
    store = MemoryRefreshTokenStore()
    token = issue_refresh_token(store, "42"; secret, claims = Dict("role" => "driver"))
    claims = decode_jwt(token, secret)
    @test claims["token_use"] == "refresh"
    @test claims["sub"] == "42"
    @test claims["role"] == "driver"
    @test claims["exp"] - claims["iat"] == Nitro.Auth.DEFAULT_REFRESH_TTL_SECONDS
    @test claims["jti"] isa String && length(claims["jti"]) == 22   # 128 bits, base64url
    @test claims["fam"] isa String && length(claims["fam"]) == 22

    rotation = rotate_refresh_token(store, token; secret, ttl = 600)
    @test rotation isa RefreshRotation
    next = decode_jwt(rotation.refresh_token, secret)
    @test next["jti"] != claims["jti"]
    @test next["fam"] == claims["fam"]
    @test next["sub"] == "42" && next["role"] == "driver" && next["token_use"] == "refresh"
    @test next["exp"] - next["iat"] == 600
    # The access claims are the app's to sign: its claims, `sub`, and the access discriminator.
    @test rotation.access_claims == Dict{String, Any}("sub" => "42", "role" => "driver",
                                                       "token_use" => "access")
    @test !occursin(rotation.refresh_token, repr(rotation))

    # The old token is no longer current, the new one is -- read straight off the store.
    old = consume_refresh_token!(store, claims["fam"], claims["jti"]; at = ts())
    @test old isa RefreshTokenMiss && old.reason === :reused
    fresh = consume_refresh_token!(store, next["fam"], next["jti"]; at = ts())
    @test fresh isa RefreshTokenRecord && fresh.subject == "42"

    # The issuance contract.
    @test_throws ArgumentError issue_refresh_token(store, "42"; secret, claims = Dict("jti" => "x"))
    @test_throws ArgumentError issue_refresh_token(store, "42"; secret, claims = Dict("fam" => "x"))
    @test_throws ArgumentError issue_refresh_token(store, "42"; secret, claims = Dict(:token_use => "access"))
    @test_throws ArgumentError issue_refresh_token(store, ""; secret)
    @test_throws ArgumentError issue_refresh_token(store, "42"; secret, ttl = 0)
    # Family ids are never caller-chosen (a chosen one could revive a revoked family).
    @test_throws MethodError issue_refresh_token(store, "42"; secret, family = "device-1")

    # A store at its bound: a token of an evicted family is refused, never honoured.
    small = MemoryRefreshTokenStore(max_tokens = 3)
    tokens = [issue_refresh_token(small, string(i); secret) for i in 1:4]
    err = try; rotate_refresh_token(small, tokens[1]; secret); nothing; catch e; e; end
    @test err isa RefreshTokenError && err.reason === :unknown
    @test rotate_refresh_token(small, tokens[4]; secret) isa RefreshRotation

    @test_throws ArgumentError RefreshTokenError(:nope)
end

@testitem "refresh tokens: only verified refresh tokens reach the store (#231)" tags=[:auth, :core] setup=[NitroCommon] begin
    using Test
    using Nitro.Auth

    reason(f) = try; f(); nothing; catch e; e isa RefreshTokenError ? e.reason : rethrow(); end
    ts() = Nitro.Auth._current_timestamp()

    secret = jwtkey("refresh")
    store = MemoryRefreshTokenStore()

    # `decode_jwt`'s time bound still holds: a token past its `exp` (beyond the skew) is refused
    # before the store is asked, so the family's current token is NOT taken by the attempt.
    @test record_refresh_token!(store, RefreshTokenRecord("jti-old", "fam-old", "42", ts() - 3600);
                                new_family = true)
    stale = encode_jwt(Dict("sub" => "42", "jti" => "jti-old", "fam" => "fam-old",
                            "token_use" => "refresh", "iat" => ts() - 7200, "exp" => ts() - 3600), secret)
    @test reason(() -> rotate_refresh_token(store, stale; secret)) === :invalid
    @test consume_refresh_token!(store, "fam-old", "jti-old"; at = ts() - 7200) isa RefreshTokenRecord

    token = issue_refresh_token(store, "42"; secret)
    claims = decode_jwt(token, secret)
    jti, fam = claims["jti"], claims["fam"]
    # Wrong key, forged signature, not a JWT.
    @test reason(() -> rotate_refresh_token(store, token; secret = jwtkey("other"))) === :invalid
    parts = split(token, '.')
    @test reason(() -> rotate_refresh_token(store, join([parts[1], parts[2], "AAAA"], '.'); secret)) === :invalid
    @test reason(() -> rotate_refresh_token(store, "not-a-jwt"; secret)) === :invalid
    # An access token signed with the same secret is not a refresh token, even with a jti and fam.
    access = encode_jwt(Dict("sub" => "42", "jti" => jti, "fam" => fam, "token_use" => "access"), secret; expires_in = 600)
    @test reason(() -> rotate_refresh_token(store, access; secret)) === :invalid
    # A refresh token without a jti, a fam, or an exp does not verify.
    no_jti = encode_jwt(Dict("sub" => "42", "fam" => fam, "token_use" => "refresh"), secret; expires_in = 600)
    @test reason(() -> rotate_refresh_token(store, no_jti; secret)) === :invalid
    no_fam = encode_jwt(Dict("sub" => "42", "jti" => jti, "token_use" => "refresh"), secret; expires_in = 600)
    @test reason(() -> rotate_refresh_token(store, no_fam; secret)) === :invalid
    no_exp = encode_jwt(Dict("sub" => "42", "jti" => jti, "fam" => fam, "token_use" => "refresh"), secret)
    @test reason(() -> rotate_refresh_token(store, no_exp; secret)) === :invalid
    # A signed `sub` that disagrees with the store's record. Only a holder of the secret can sign
    # one, and the attempt takes that family's current token, so it uses a token of its own.
    victim = decode_jwt(issue_refresh_token(store, "42"; secret), secret)
    swapped = encode_jwt(Dict("sub" => "43", "jti" => victim["jti"], "fam" => victim["fam"],
                              "token_use" => "refresh"), secret; expires_in = 600)
    @test reason(() -> rotate_refresh_token(store, swapped; secret)) === :invalid
    # A family this store never issued.
    foreign = issue_refresh_token(MemoryRefreshTokenStore(), "42"; secret)
    @test reason(() -> rotate_refresh_token(store, foreign; secret)) === :unknown
    # Issuer and audience are checked when given.
    iss = issue_refresh_token(store, "42"; secret, claims = Dict("iss" => "fleet"))
    @test reason(() -> rotate_refresh_token(store, iss; secret, issuer = "other")) === :invalid
    @test rotate_refresh_token(store, iss; secret, issuer = "fleet") isa RefreshRotation

    # None of those refusals took the real token.
    @test rotate_refresh_token(store, token; secret) isa RefreshRotation
end

# ── Reuse detection ─────────────────────────────────────────────────────────────────────────

@testitem "refresh tokens: a replayed token revokes its whole family (#231)" tags=[:auth, :core] setup=[NitroCommon] begin
    using Test
    using Nitro.Auth

    reason(f) = try; f(); nothing; catch e; e isa RefreshTokenError ? e.reason : rethrow(); end

    secret = jwtkey("refresh")
    store = MemoryRefreshTokenStore()
    first = issue_refresh_token(store, "42"; secret)
    second = rotate_refresh_token(store, first; secret).refresh_token
    third = rotate_refresh_token(store, second; secret).refresh_token

    # An unrelated sign-in of the same subject is a different family and is not touched.
    other = issue_refresh_token(store, "42"; secret)

    # The attacker replays a spent token: refused as a reuse...
    @test reason(() -> rotate_refresh_token(store, first; secret)) === :reused
    # ...and the legitimate client's CURRENT token is now dead too (RFC 9700 §4.14.2).
    @test reason(() -> rotate_refresh_token(store, third; secret)) === :unknown
    # A further replay is not another breach: the family is simply gone.
    @test reason(() -> rotate_refresh_token(store, second; secret)) === :unknown

    @test rotate_refresh_token(store, other; secret) isa RefreshRotation

    # The case reuse detection exists for: the thief rotates the stolen token at once, and the real
    # client comes back with it much later, after any amount of unrelated refresh traffic. Its old
    # token is still recognized, and the thief's lineage dies with it.
    busy = MemoryRefreshTokenStore(max_tokens = 2)
    stolen = issue_refresh_token(busy, "42"; secret)
    thief = rotate_refresh_token(busy, stolen; secret).refresh_token
    bystander = issue_refresh_token(busy, "7"; secret)
    for _ in 1:50
        bystander = rotate_refresh_token(busy, bystander; secret).refresh_token
    end
    @test reason(() -> rotate_refresh_token(busy, stolen; secret)) === :reused
    @test reason(() -> rotate_refresh_token(busy, thief; secret)) === :unknown
    @test rotate_refresh_token(busy, bystander; secret) isa RefreshRotation

    # Sign-out is the same store call: revoking one token revokes its family.
    store2 = MemoryRefreshTokenStore()
    a = issue_refresh_token(store2, "7"; secret)
    b = rotate_refresh_token(store2, a; secret).refresh_token
    @test revoke_refresh_token(store2, b; secret) === nothing
    @test reason(() -> rotate_refresh_token(store2, b; secret)) === :unknown
    # It is idempotent: again, through a rotated-away token, or against a store that never saw it.
    @test revoke_refresh_token(store2, a; secret) === nothing
    @test revoke_refresh_token(store2, b; secret) === nothing
    @test revoke_refresh_token(MemoryRefreshTokenStore(), b; secret) === nothing
    # A token that does not verify signs nobody out.
    @test reason(() -> revoke_refresh_token(store2, "not-a-jwt"; secret)) === :invalid
end

@testitem "refresh tokens: concurrent rotations of one token are a reuse (#231)" tags=[:auth, :core] setup=[NitroCommon] begin
    using Test
    using Nitro.Auth

    # Concurrent use IS reuse (Auth0, no leeway interval). At most one rotation returns a token, at
    # least one caller is told `:reused`, and whatever token was returned is dead afterwards because
    # the loser revoked the family. The winner's own `record!` may even lose that race and report
    # `:revoked`, and later losers find the family gone (`:unknown`): that is the revoke-vs-rotate
    # guard working, not a lost update. The store-level CAS (exactly one consume) is pinned by the
    # `MemoryRefreshTokenStore` item.
    secret = jwtkey("refresh")
    store = MemoryRefreshTokenStore()
    token = issue_refresh_token(store, "42"; secret)
    attempt() = try
        rotate_refresh_token(store, token; secret)
    catch e
        e isa RefreshTokenError || rethrow()
        e.reason
    end
    results = fetch.([Threads.@spawn attempt() for _ in 1:16])
    winners = filter(r -> r isa RefreshRotation, results)
    @test length(winners) <= 1
    @test count(==(:reused), results) >= 1
    @test all(r -> r isa RefreshRotation || r in (:reused, :revoked, :unknown), results)
    for w in winners
        err = try; rotate_refresh_token(store, w.refresh_token; secret); nothing; catch e; e; end
        @test err isa RefreshTokenError && err.reason === :unknown
    end
end

@testitem "refresh tokens: a family revoked mid-rotation refuses the new token (#231)" tags=[:auth, :core] setup=[NitroCommon] begin
    using Test
    using Nitro.Auth

    # The revoke-vs-rotate guard, deterministically: a store whose consume is followed at once by
    # a revocation of the same family -- what a concurrent reuse does, without the race. The
    # rotation must not hand out a token the store will never honour.
    struct RevokingStore <: AbstractRefreshTokenStore
        inner::MemoryRefreshTokenStore
    end
    Nitro.Auth.record_refresh_token!(s::RevokingStore, r::RefreshTokenRecord; new_family::Bool) =
        record_refresh_token!(s.inner, r; new_family)
    function Nitro.Auth.consume_refresh_token!(s::RevokingStore, family::String, jti::String; at::Int)
        outcome = consume_refresh_token!(s.inner, family, jti; at)
        outcome isa RefreshTokenRecord && revoke_refresh_family!(s.inner, family)
        return outcome
    end
    Nitro.Auth.revoke_refresh_family!(s::RevokingStore, family::String) = revoke_refresh_family!(s.inner, family)
    Nitro.Auth.prune_refresh_tokens!(s::RevokingStore; at::Int) = prune_refresh_tokens!(s.inner; at)
    @test isempty(missing_refresh_store_methods(RevokingStore))

    secret = jwtkey("refresh")
    store = RevokingStore(MemoryRefreshTokenStore())
    token = issue_refresh_token(store, "42"; secret)
    err = try; rotate_refresh_token(store, token; secret); nothing; catch e; e; end
    @test err isa RefreshTokenError && err.reason === :revoked
    # Nothing came back to life in the store.
    @test isempty(store.inner.families)
end

@testitem "refresh tokens: nothing logs or renders a token, jti or family (#231)" tags=[:auth, :core] setup=[NitroCommon] begin
    using Test
    using HTTP
    using JSON
    using Nitro.Auth

    secret = jwtkey("refresh")
    store = MemoryRefreshTokenStore()
    token = issue_refresh_token(store, "42"; secret)
    claims = decode_jwt(token, secret)
    jti, family = claims["jti"], claims["fam"]
    rotation = rotate_refresh_token(store, token; secret)
    sentinels = (token, jti, family, rotation.refresh_token, secret)
    clean(text) = !any(s -> occursin(s, text), sentinels)

    record = RefreshTokenRecord(jti, family, "42", 0)
    @test clean(repr(record)) && clean(sprint(show, MIME"text/plain"(), record))
    @test clean(repr(rotation))
    @test clean(repr(store))
    err = RefreshTokenError(:reused)
    @test clean(sprint(showerror, err)) && clean(repr(err)) && clean(JSON.json(err))

    # Uncaught from a handler: a 401 with a fixed body, logged at @debug with the reason only. The
    # replay goes through the request path, so the family is revoked there too.
    app = App()
    urlpatterns(app, "",
        path("/auth/refresh", req -> begin
            presented = HTTP.header(req, "X-Refresh", "")
            r = rotate_refresh_token(store, presented; secret)
            Res.json(Dict("refresh_token" => r.refresh_token))
        end; method = "POST"))
    logger = Test.TestLogger(min_level = Base.CoreLogging.Debug)
    response = Base.CoreLogging.with_logger(logger) do
        internalrequest(app, HTTP.Request("POST", "/auth/refresh", ["X-Refresh" => token]))
    end
    @test response.status == 401
    body = String(response.body)
    @test occursin("401", body) && clean(body)
    records = lock(() -> copy(logger.logs), logger.lock)
    @test any(l -> occursin("refresh token", string(l.message)) && get(l.kwargs, :reason, nothing) === :reused, records)
    @test all(l -> clean(string(l.message)) && clean(string(l.kwargs)), records)
    @test !any(l -> l.level >= Base.CoreLogging.Warn, records)

    refused = try; rotate_refresh_token(store, rotation.refresh_token; secret); nothing; catch e; e; end
    @test refused isa RefreshTokenError && refused.reason === :unknown
end
