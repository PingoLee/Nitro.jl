# ── Refresh-token lifecycle (#231) ──────────────────────────────────────────────────────────
#
# The opt-in that #7's scope decision left on the table. `Nitro.Auth` stays the resource-server
# half: it never mints an ACCESS token here (the app signs `RefreshRotation.access_claims` with
# `encode_jwt`, as #7 decided). What this file adds is the server-side state a stateless verifier
# cannot have: a store holding each family's current token (its `jti`), rotation (a new refresh
# token per use), and reuse detection (a rotated-away token coming back revokes its whole family).
#
# Prior art, and where each rule comes from:
#   * RFC 6749 §6 -- the refresh grant itself; the server MAY issue a new refresh token and then
#     MUST be able to revoke the old one.
#   * RFC 9700 (OAuth 2.0 Security BCP) §4.14.2 -- rotation with reuse detection: "If a refresh
#     token is compromised and subsequently used by both the attacker and the legitimate client,
#     one of them will present an invalidated refresh token, which will inform the authorization
#     server of the breach", which then revokes the active refresh token, i.e. the family.
#   * Auth0's "refresh token rotation with automatic reuse detection" -- the same family rule,
#     including that two concurrent uses of one token ARE a reuse (Auth0 offers a leeway interval
#     on top; Nitro does not, yet).
#   * Spring Authorization Server -- where Spring puts this, apart from Spring Security's verifier.
#     Same split here: `decode_jwt` verifies, this file keeps state.
#
# Policy lives HERE; the store is data access only (`AbstractRefreshTokenStore`, src/types.jl).
#
# Nothing in this file logs. No message, exception field or `show` carries a token, a jti, a family
# id or a secret: the refusals are `RefreshTokenError(reason)`, a closed set of symbols.

"""
The `max_tokens` a [`MemoryRefreshTokenStore`](@ref) is built with when none is given, sized like
`MemoryStore`'s `max_sessions`.
"""
const DEFAULT_MAX_REFRESH_TOKENS = 100_000

"""
The refresh-token lifetime `issue_refresh_token` and `rotate_refresh_token` use when no `ttl` is
given: 14 days, in seconds. Each rotation issues a token with a fresh `ttl`, so this is the
**inactivity** bound: a client that refreshes at least this often stays signed in.
"""
const DEFAULT_REFRESH_TTL_SECONDS = 14 * 24 * 60 * 60

# The claims rotation owns. An app's own claims may not set them: a caller-chosen `fam` would let a
# token speak for another sign-in's family, a caller-chosen `jti` would collide with a current
# token, and a caller-chosen `token_use` would mint a refresh token that reads as an access token.
const _REFRESH_RESERVED_CLAIMS = ("jti", "fam", "sub", "token_use", "iat", "exp", "nbf")
const _REFRESH_REQUIRED_CLAIMS = ["jti", "fam", "sub", "token_use"]

# 128 random bits, base64url (22 characters): a jti or a family id. Unguessable, so a family id the
# store hands back carries no ordering or count.
_refresh_id() = base64url_encode(secure_random_bytes(16))

# ── The in-memory store ─────────────────────────────────────────────────────────────────────

# One live family: its current token (or `nothing` between a rotation's consume and its record),
# that token's subject and expiry, and `lives_until`, the latest expiry of ANY token the family was
# given. An old token must keep reading as a reuse until it has expired, so the row lives that long
# even if a later token was issued with a shorter `ttl`. There is no `revoked` flag: revoking
# DELETES the row, and a family the store does not know reads as `:unknown` on every path.
struct _Family
    current::Nullable{String}
    subject::String
    expires_at::Int
    lives_until::Int
end

"""
    MemoryRefreshTokenStore(; max_tokens = 100_000)

An in-process [`AbstractRefreshTokenStore`](@ref): the store to pass to `issue_refresh_token` and
`rotate_refresh_token` when one process holds every refresh token.

**For development or a single process.** Tokens live in this process only, so a restart signs
every client out, and a second process cannot see the first's tokens. Behind more than one
process, use a persistent store.

**One row per family, at most `max_tokens` families**: roughly your concurrent sign-ins. A
rotation rewrites its family's row and never adds one, and a revocation (a logout, a detected
reuse) removes it. So the bound counts sign-ins, never refreshes. Reuse detection lasts as long as
a family lives, however many refreshes other clients make. Once full, a new sign-in evicts the
least recently used family. Eviction **fails closed**: every token of an evicted family is refused
as `:unknown`, the attacker's copy included. Run a [`RefreshTokenPruner`](@ref), which removes
expired families before the bound has to.

One `ReentrantLock` guards the table. `consume_refresh_token!` holds it for the check and the
clear, which is the compare-and-swap rotation depends on.
"""
struct MemoryRefreshTokenStore <: AbstractRefreshTokenStore
    families::BoundedLRU{String, _Family, typeof(_count_one)}
    lock::ReentrantLock
    max_tokens::Int

    function MemoryRefreshTokenStore(; max_tokens::Integer = DEFAULT_MAX_REFRESH_TOKENS)
        max_tokens > 0 || throw(ArgumentError(
            "MemoryRefreshTokenStore: max_tokens must be positive, got $max_tokens"))
        n = Int(max_tokens)
        return new(BoundedLRU{String, _Family}(n), ReentrantLock(), n)
    end
end

# The capacity only: the table holds family ids and jtis, and a count read without the lock would
# be a race for no benefit.
Base.show(io::IO, store::MemoryRefreshTokenStore) =
    print(io, "MemoryRefreshTokenStore(max_tokens = ", store.max_tokens, ")")

function record_refresh_token!(store::MemoryRefreshTokenStore, record::RefreshTokenRecord;
                               new_family::Bool)
    return lock(store.lock) do
        state = get(store.families, record.family, nothing)
        if new_family
            state === nothing || return false
            store.families[record.family] =
                _Family(record.jti, record.subject, record.expires_at, record.expires_at)
        else
            # Only the rotation that consumed the current token may record its successor: the row
            # must be present (not revoked, which deletes it) with no current token. A family
            # revoked between this rotation's consume and now refuses here, so a concurrent reuse
            # cannot be outrun.
            (state === nothing || state.current !== nothing) && return false
            store.families[record.family] = _Family(record.jti, record.subject, record.expires_at,
                                                    max(state.lives_until, record.expires_at))
        end
        return true
    end
end

function consume_refresh_token!(store::MemoryRefreshTokenStore, family::String, jti::String;
                                at::Int = _current_timestamp())
    return lock(store.lock) do
        state = get(store.families, family, nothing)
        state === nothing && return RefreshTokenMiss(:unknown)
        # Not the current token -- including while a rotation holds the row between its consume
        # and its record: it was rotated away already, so this is its second presentation.
        current = state.current
        (current === nothing || current != jti) && return RefreshTokenMiss(:reused)
        state.expires_at <= at && return RefreshTokenMiss(:expired)
        # The check above and this clear are one lock hold: the CAS.
        store.families[family] = _Family(nothing, state.subject, state.expires_at, state.lives_until)
        return RefreshTokenRecord(current, family, state.subject, state.expires_at)
    end
end

function revoke_refresh_family!(store::MemoryRefreshTokenStore, family::String)
    # Revoking is deleting: a family the store does not know reads as `:unknown` on every path, and
    # a random 128-bit family id is never issued twice, so nothing can bring it back. Idempotent.
    lock(() -> delete!(store.families, family), store.lock)
    return nothing
end

function prune_refresh_tokens!(store::MemoryRefreshTokenStore; at::Int = _current_timestamp())
    lock(store.lock) do
        # Collect first, delete after: a `BoundedLRU`'s iteration throws on mutation (#850), as in
        # `cleanup_expired_sessions!(::MemoryStore)`. Iterating does not refresh recency.
        dead = String[]
        for (family, state) in store.families
            state.lives_until <= at && push!(dead, family)
        end
        for family in dead
            delete!(store.families, family)
        end
        return nothing
    end
    return nothing
end

"""
    RefreshTokenPruner(store::AbstractRefreshTokenStore; interval::Period = Minute(10))

A `LifecycleMiddleware` that calls `prune_refresh_tokens!(store)` every `interval` and does nothing
else to the request. It is the same background-janitor discipline `SessionPruner` uses.

```julia
refresh_store = MemoryRefreshTokenStore()
serve(app; middleware = [RefreshTokenPruner(refresh_store)])
```

Expired tokens are refused whether or not anything prunes. Pruning keeps the store's bound for
live tokens, so expired ones are not what pushes a live one out. The janitor starts on `serve()`
and stops on `terminate()`, and its hooks are idempotent across a restart.
"""
function RefreshTokenPruner(store::AbstractRefreshTokenStore; interval::Period = Minute(10))
    on_startup, on_shutdown = _janitor(() -> prune_refresh_tokens!(store; at = _current_timestamp()),
                                       interval, "RefreshTokenPruner", "refresh-token prune",
                                       "interval")
    return LifecycleMiddleware(;
        middleware = handle -> (req -> handle(req)),
        on_startup = on_startup,
        on_shutdown = on_shutdown)
end
