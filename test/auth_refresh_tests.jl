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
