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
