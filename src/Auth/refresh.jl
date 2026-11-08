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

# ── Issuing and rotating ────────────────────────────────────────────────────────────────────

"""
    RefreshRotation(access_claims::Dict{String,Any}, refresh_token::String)

What [`rotate_refresh_token`](@ref) returns:

- `access_claims`: the claims for the new **access** token, which the application signs itself:
  `encode_jwt(rotation.access_claims, access_secret; expires_in = 900)`. They are the app claims
  given at sign-in, plus `sub` and `token_use = "access"`.
- `refresh_token`: the next refresh token in the same family. Send it to the client in place of
  the one it presented, which is now spent.

Its `show` redacts the token.
"""
struct RefreshRotation
    access_claims::Dict{String, Any}
    refresh_token::String
end

Base.show(io::IO, r::RefreshRotation) =
    print(io, "RefreshRotation(", length(r.access_claims), " access claims, <redacted refresh token>)")

# The claims an app attached at sign-in, without the ones rotation owns. Carried into each next
# refresh token and into the access claims.
function _app_claims(claims::AbstractDict)::Dict{String, Any}
    out = Dict{String, Any}()
    for (key, value) in pairs(claims)
        name = string(key)
        name in _REFRESH_RESERVED_CLAIMS && continue
        out[name] = value
    end
    return out
end

# Sign one refresh token and build the record that matches it, from ONE clock read.
function _mint_refresh(subject::String, family::String, ttl::Int, app_claims::Dict{String, Any},
                       secret)::Tuple{String, RefreshTokenRecord}
    now = _current_timestamp()
    jti = _refresh_id()
    payload = copy(app_claims)
    payload["sub"] = subject
    payload["jti"] = jti
    payload["fam"] = family
    payload["token_use"] = "refresh"
    payload["iat"] = now
    payload["exp"] = now + ttl
    token = encode_jwt(payload, secret)
    return (token, RefreshTokenRecord(jti, family, subject, now + ttl))
end

function _check_ttl(ttl::Integer)::Int
    ttl > 0 || throw(ArgumentError("refresh-token ttl must be a positive number of seconds, got $ttl"))
    return Int(ttl)
end

"""
    issue_refresh_token(store, subject; secret, ttl = 14 days, claims = Dict()) -> String

Mint the first refresh token of a new family for `subject` (at sign-in), record it in `store`, and
return the signed token.

The token is a JWT signed with `secret` (anything `encode_jwt` accepts) carrying `sub`, a fresh
random `jti`, its family id `fam`, `token_use = "refresh"`, `iat`, `exp = iat + ttl` and the app's
own `claims`. Those
claims are carried into every rotated token **and** into `RefreshRotation.access_claims`, so pass
only claims meant for both. An `iss` or `aud` here is checked by `rotate_refresh_token(...; issuer,
audience)` and then lands in the access claims too. Setting `jti`, `fam`, `sub`, `token_use`, `iat`,
`exp` or `nbf` through `claims` is an `ArgumentError`.

Each call starts a new family under a fresh random id: one family per sign-in. Rotation never
starts one. The id is signed into every token of the family (`fam`), which is what lets any old
token that comes back be recognized as a reuse. There is deliberately no way to choose it. A
caller-chosen id (a device id, say) could recreate a revoked family, which would bring its old
tokens back to life.

**Use a separate `secret` from your access tokens.** Then an access-token validator refuses a
refresh token by its signature. If you share one secret, guard ordinary routes with
`claim_required("token_use", "access")`.

```julia
refresh_store = MemoryRefreshTokenStore()
token = issue_refresh_token(refresh_store, string(driver.id); secret = REFRESH_SECRET,
                            claims = Dict("role" => driver.role))
```
"""
function issue_refresh_token(store::AbstractRefreshTokenStore, subject::AbstractString; secret,
                             ttl::Integer = DEFAULT_REFRESH_TTL_SECONDS,
                             claims::AbstractDict = Dict{String, Any}())::String
    isempty(subject) && throw(ArgumentError("issue_refresh_token: subject must be non-empty"))
    seconds = _check_ttl(ttl)
    app_claims = Dict{String, Any}()
    for (key, value) in pairs(claims)
        name = string(key)
        name in _REFRESH_RESERVED_CLAIMS && throw(ArgumentError(
            "issue_refresh_token: `$name` is set by rotation and cannot be passed in `claims`"))
        app_claims[name] = value
    end
    token, record = _mint_refresh(String(subject), _refresh_id(), seconds, app_claims, secret)
    # A fresh 128-bit family id is never already held, so `false` means a store that broke its
    # contract, not a collision.
    record_refresh_token!(store, record; new_family = true) || throw(ArgumentError(
        "issue_refresh_token: the store refused a new family; check its record_refresh_token! method"))
    return token
end

# Verify a presented refresh token: signature and time bounds through `decode_jwt`, then the
# claims rotation needs. Every refusal is `:invalid`, and the `AuthError`'s message is not kept:
# "expired" against "bad signature" is not a client's to learn (the same choice `BearerAuth` makes).
# Returns `(claims, family, jti, subject)`.
function _verify_refresh(token::AbstractString, secret, issuer,
                         audience)::Tuple{Dict{String, Any}, String, String, String}
    claims = try
        decode_jwt(token, secret; issuer = issuer, audience = audience, require_exp = true,
                   required_claims = _REFRESH_REQUIRED_CLAIMS)
    catch e
        e isa AuthError || rethrow()
        throw(RefreshTokenError(:invalid))
    end
    claims isa Dict{String, Any} || throw(RefreshTokenError(:invalid))
    token_use = get(claims, "token_use", nothing)
    (token_use isa String && token_use == "refresh") || throw(RefreshTokenError(:invalid))
    family = get(claims, "fam", nothing)
    (family isa String && !isempty(family)) || throw(RefreshTokenError(:invalid))
    jti = get(claims, "jti", nothing)
    (jti isa String && !isempty(jti)) || throw(RefreshTokenError(:invalid))
    subject = get(claims, "sub", nothing)
    (subject isa String && !isempty(subject)) || throw(RefreshTokenError(:invalid))
    return (claims, family, jti, subject)
end

# A store's answer to `consume_refresh_token!` as a record, or the refusal it means. The one place
# the family rule lives: `:reused` revokes the family BEFORE the error leaves, so by the time the
# caller sees it, the legitimate client's current token is dead too (RFC 9700 §4.14.2). The family
# is the token's own signed `fam`, so no store answer can leave it out.
function _admit(store::AbstractRefreshTokenStore, outcome, family::String,
                subject::String)::RefreshTokenRecord
    if outcome isa RefreshTokenMiss
        outcome.reason === :reused && revoke_refresh_family!(store, family)
        throw(RefreshTokenError(outcome.reason))
    end
    outcome isa RefreshTokenRecord || throw(ArgumentError(
        "consume_refresh_token! must return a RefreshTokenRecord or a RefreshTokenMiss, got a $(typeof(outcome))"))
    # The signed `sub` and the stored subject must agree. They can only disagree if the store is
    # wrong or two issuers share a secret and a family space, and either way the token is not this
    # store's to honour.
    (outcome.subject == subject && outcome.family == family) || throw(RefreshTokenError(:invalid))
    return outcome
end

"""
    rotate_refresh_token(store, token; secret, ttl = 14 days, issuer = nothing, audience = nothing) -> RefreshRotation

Spend the refresh `token` and issue the next one in its family. This is the body of a refresh
endpoint.

1. Verifies `token` with `decode_jwt` (signature, `exp` required, `issuer`/`audience` when given),
   and requires `token_use = "refresh"`, a `jti`, a `fam` and a `sub`.
2. Consumes it in `store`, atomically: it must be its family's current token. Exactly one of any
   number of concurrent rotations of one token gets past this point.
3. Records the next token in the same family, valid for `ttl` seconds from now.
4. Returns a [`RefreshRotation`](@ref): the access claims for the application to sign with
   `encode_jwt`, and the new refresh token. This function never mints an access token.

A refusal throws [`RefreshTokenError`](@ref)`(reason)`. **A token that is not its family's current
one revokes the whole family** (`:reused`): it was rotated away already, so two parties hold the
lineage. The attacker's copy and the legitimate client's current token both stop working, and the
user signs in again. This holds for as long as the family lives, however long ago the old token
was rotated away. It includes a client that sends one token twice at once, for example from two
tabs, so a client must serialize its refreshes.

The claims handed back are the ones given at sign-in. Re-check the subject before you sign them,
because a disabled or demoted account should not get a fresh access token with yesterday's role:

```julia
function refresh(req, body::Json{RefreshRequest})
    rotation = rotate_refresh_token(refresh_store, body.payload.refresh_token; secret = REFRESH_SECRET)
    driver = find_driver(rotation.access_claims["sub"])
    (driver === nothing || !driver.active) && return Res.status(401)
    claims = merge(rotation.access_claims, Dict("role" => driver.role))   # the current role
    access = encode_jwt(claims, ACCESS_SECRET; expires_in = 900)
    return Res.json(Dict("access_token" => access, "refresh_token" => rotation.refresh_token))
end
```

Uncaught, a `RefreshTokenError` is a fixed `401`.
"""
function rotate_refresh_token(store::AbstractRefreshTokenStore, token::AbstractString; secret,
                              ttl::Integer = DEFAULT_REFRESH_TTL_SECONDS, issuer = nothing,
                              audience = nothing)::RefreshRotation
    seconds = _check_ttl(ttl)
    claims, family, jti, subject = _verify_refresh(token, secret, issuer, audience)
    record = _admit(store, consume_refresh_token!(store, family, jti; at = _current_timestamp()),
                    family, subject)
    app_claims = _app_claims(claims)
    next, next_record = _mint_refresh(subject, record.family, seconds, app_claims, secret)
    # `false` means the family was revoked between our consume and now -- a concurrent reuse or a
    # logout. The new token is not stored, so it is refused if it is ever presented.
    record_refresh_token!(store, next_record; new_family = false) ||
        throw(RefreshTokenError(:revoked))
    access_claims = app_claims
    access_claims["sub"] = subject
    access_claims["token_use"] = "access"
    return RefreshRotation(access_claims, next)
end

"""
    revoke_refresh_token(store, token; secret, issuer = nothing, audience = nothing) -> Nothing

Sign-out: verify the refresh `token` and revoke its whole family (its signed `fam`), so neither it
nor any token rotated from it can be used again. Revoking one token and revoking its family are the
same call, because under rotation a family holds at most one live token.

It is idempotent. A token of a family that is already gone, or one that was rotated away, still
signs its family out and returns normally, since holding any token of the family is enough to end
it. A token that does not verify throws [`RefreshTokenError`](@ref)`(:invalid)`.
"""
function revoke_refresh_token(store::AbstractRefreshTokenStore, token::AbstractString; secret,
                              issuer = nothing, audience = nothing)::Nothing
    _, family, _, _ = _verify_refresh(token, secret, issuer, audience)
    revoke_refresh_family!(store, family)
    return nothing
end
