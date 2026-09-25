# ── Typed JWT keyset (#260) ──────────────────────────────────────────────────────
#
# A keyset used to be a bare `Dict` of `kid => secret`, which cannot say which key signs,
# so `jwt.jl` re-answered "which key?" by hand three times (#45, #253 and its rider). This
# type answers it once, at construction: exactly one key signs, every key verifies. Roles
# describe USE (RFC 7517 `use`/`key_ops`), not lifecycle -- a keyset is as often a
# registry of client identities as it is a rotation window. See
# docs/design/typed-jwt-keyset.md.

# What one key may assert (#349): claim name => `nothing` (any value) or the allowed values.
# Values are Strings only -- `in` compares with `==`, under which `true == 1`, so a numeric or
# Bool pin would admit more than it names.
const ClaimScope = Dict{String, Union{Nothing, Set{String}}}

# Registered claims every token carries and none of which grants authority: the time bounds
# `validate_claims` enforces and the token id. Always allowed, so a scope never has to repeat
# them. `sub`, `iss` and `aud` are NOT here -- they say who the caller is and whom the token is
# from and for, so a scoped key asserts them only when its scope lists them.
const _JWT_ALWAYS_ALLOWED_CLAIMS = ("iat", "exp", "nbf", "jti")

struct JWTKey
    kid::String
    secret::SecretString
    use::Symbol          # :sign | :verify
    scope::Nullable{ClaimScope}   # `nothing`: trusted for every claim
end

Base.show(io::IO, key::JWTKey) = print(io, "JWTKey(", repr(key.kid), ", :", key.use,
                                       key.scope === nothing ? "" : ", scoped", ")")
Base.show(io::IO, ::MIME"text/plain", key::JWTKey) = show(io, key)

"""
    JWTKeyset(signer::Pair; verify = (), claims = ())
    JWTKeyset(keyset::AbstractDict; claims = ())

A set of HS256 keys for `encode_jwt`, `decode_jwt` and `jwt_validator`:
exactly **one signing key**, plus any number of **verify-only** keys. The signing key also
verifies.

```julia
keyset = JWTKeyset("current" => current_secret; verify = ["previous" => previous_secret])

encode_jwt(claims, keyset)        # signed with, and stamped kid = "current"
decode_jwt(token, keyset)         # verified by "current" or "previous"
```

Every pair is `kid => secret`. A `kid` is a `String` or `Symbol`; a secret is an
`AbstractString` or a [`SecretString`](@ref). The constructor refuses, with an
`ArgumentError`:

- a secret of any other type — a `Vector{UInt8}` in particular is refused **without being
  read**, so the caller's buffer is left intact;
- an empty secret, or one HMAC treats as empty (a short run of `"\\0"` bytes);
- a secret shorter than 32 bytes — RFC 7518 §3.2's floor for an HS256 key. Generate one with
  `bytes2hex(Nitro.Crypto.secure_random_bytes(32))`;
- two keys with the same `kid`;
- two keys that are the same HMAC key. The comparison is by HMAC key, not by string:
  HMAC-SHA256 pre-hashes a key longer than its block and zero-pads a shorter one, so `K` and
  `sha256(K)` are one key, and so are `"a"` and `"a\\0"`.

# Lifting a `Dict`

`JWTKeyset(d::AbstractDict)` lifts the `Dict` form, which `encode_jwt`, `decode_jwt` and
`jwt_validator` all still accept:

| `Dict` shape | Result |
|---|---|
| has a `"default"` entry | `"default"` signs; every other entry verifies |
| exactly one entry | that entry signs |
| two or more entries, no `"default"` | `ArgumentError` |
| empty | `ArgumentError` |

A `Dict` holding both `"a"` and `:a` is refused rather than silently shadowed.

# Scoping what a key may claim

By default a key is trusted for **every** claim. Whoever holds any key in the keyset — verify-only
ones included — can sign `{"role": "admin"}`, and under the default `identity_from = :claim` any
`sub`. `identity_from = :kid` pins *who* the principal is, not *what it may claim*. That is right
for a rotation window, where every key belongs to one issuer, and wrong for a registry of
partner keys.

`claims` scopes a key to the claims it may assert:

```julia
keyset = JWTKeyset("self" => own_secret;
    verify = ["partner" => partner_secret],
    claims = Dict("partner" => ["sub", "action", "role" => ["reader"]]))
```

Each entry of a scope is a claim name, which allows any value, or `name => values`, which allows
only those values. A pinned value is a `String` (or `Symbol`), and one value can stand alone:
`"role" => "reader"`. A claim holding a list, such as a `permissions` array, passes a pin only
when every element is allowed — so an empty list always passes, which is right for
`permission_required` but not for an app that reads `[]` as "unrestricted". Any other value
under a pin is refused, whether it is a number, `null` or an object.

A token verified by a scoped key is **rejected** — `decode_jwt` throws an `AuthError`, and the
auth middleware answers `401` — when it asserts a claim the scope does not list, or a pinned
claim with a value the pin does not allow. The claims are never dropped. `decode_jwt` and
`jwt_validator` both enforce it; `decode_jwt(...; verify = false)` has no verified key and does
not. `iat`, `exp`, `nbf` and `jti` are always allowed — so a scoped key still picks its own
`jti`, and a replay cache should key on `(kid, jti)`, not `jti` alone. `sub`, `iss` and `aud` are
not: list them for a key whose tokens carry them. A `jwt_validator` that requires a claim — via
`issuer` (`iss`), `audience` (`aud`) or `required_claims` — that some scoped key may not assert
is an `ArgumentError` at construction, since that key could never authenticate. A scoped
*signing* key is held to its own scope by `encode_jwt`, which refuses to mint a token its
keyset would reject.

A kid with no scope stays trusted for every claim. The constructor refuses, with an
`ArgumentError`, a scope for a kid the keyset does not hold, an empty name, a name listed twice,
an empty value list, a non-string value, and any of the always-allowed claims (a pin on one of
them would silently do nothing). [`kid_required`](@ref) remains the per-route alternative.

Build the keyset **once**, at configuration time. `jwt_validator` lifts a `Dict` once and
keeps that snapshot; a direct `decode_jwt` or `encode_jwt` call with a `Dict` lifts — and
re-runs every check above — on each call.

# Signing as a peer

`encode_jwt` has no `kid=` keyword: a keyset signs with its signing key. To call another
service *as* one identity of a shared registry, build a one-key keyset for that purpose:

```julia
outbound = JWTKeyset("partner-caller" => partner_secret)
encode_jwt(claims, outbound; expires_in = 60)
```

# Display

`show` and `JSON.lower` report key ids, roles, and which claim names each scoped key may
assert — never a secret, and never a pinned value.
"""
struct JWTKeyset
    # Internal. The constructor's invariants hold only for what it built; code that mutates
    # these containers directly is outside the contract, like reflection on a SecretString.
    keys::Vector{JWTKey}         # keys[1] signs; the rest are sorted by kid
    index::Dict{String, Int}

    function JWTKeyset(signer::Pair; verify = (), claims = ())
        entries = Tuple{String, SecretString, Symbol}[_keyset_entry(signer, :sign)]
        for pair in verify
            pair isa Pair || throw(ArgumentError(
                "JWTKeyset: verify must hold kid => secret pairs, got a $(typeof(pair))"))
            push!(entries, _keyset_entry(pair, :verify))
        end
        # Signing key first, then the rest by kid: this IS the kid-less trial order, fixed
        # once here rather than sorted on every request. Order is not load-bearing for
        # correctness -- no two keys are the same HMAC key, so at most one can match -- but
        # it is for reproducibility, of tests and of the kid that reaches an operator's log.
        sort!(@view(entries[2:end]); by = first)
        scopes = _claim_scopes(claims)
        keys = JWTKey[JWTKey(kid, secret, use, get(scopes, kid, nothing)) for (kid, secret, use) in entries]
        # A scope naming a kid that is not here is a typo, and silently accepting it would leave
        # the key it meant to restrict trusted for every claim.
        for kid in Base.keys(scopes)
            any(key -> key.kid == kid, keys) || throw(ArgumentError(
                "JWTKeyset: claims names kid $(repr(kid)), which is not in the keyset, so the key " *
                "it was meant to scope would stay trusted for every claim"))
        end
        index = Dict{String, Int}()
        by_hmac = Dict{Vector{UInt8}, String}()
        for (position, key) in enumerate(keys)
            haskey(index, key.kid) && throw(ArgumentError(
                "JWTKeyset: kid $(repr(key.kid)) appears more than once"))
            index[key.kid] = position
            # Keyed on HMAC-of-empty-message, NOT on the secret string, because string
            # equality is the wrong equivalence (see the docstring). Two entries that are
            # one key make a kid-less token attributable to either, depending on order.
            # Hashing also keeps plaintext secrets out of this Dict's keys.
            fingerprint = _hmac_fingerprint(key.secret)
            previous = get(by_hmac, fingerprint, nothing)
            previous === nothing || throw(ArgumentError(
                "JWTKeyset: $(repr(previous)) and $(repr(key.kid)) are the same HMAC key, so a " *
                "token carrying no kid could not be attributed to either; give them distinct " *
                "secrets or drop one"))
            by_hmac[fingerprint] = key.kid
        end
        return new(keys, index)
    end
end

JWTKeyset(keyset::JWTKeyset) = keyset

function JWTKeyset(keyset::AbstractDict; claims = ())
    isempty(keyset) && throw(ArgumentError(
        "JWTKeyset: the keyset is empty, so there is no key to sign or verify with"))
    names = Dict{String, Any}()
    for (name, secret) in pairs(keyset)
        # Kid type first, and never `string(name)` on anything else: an integer-keyed Dict
        # could never resolve a header kid, so every request would 401 with no signal.
        name isa Union{AbstractString, Symbol} || throw(ArgumentError(
            "JWTKeyset: keyset key $(repr(name)) is a $(typeof(name)); a kid must be a String or Symbol"))
        kid = string(name)
        haskey(names, kid) && throw(ArgumentError(
            "JWTKeyset: the keyset holds both \"$kid\" and :$kid; one kid, one entry"))
        names[kid] = secret      # the RAW value -- `_keyset_entry` checks it before reading
    end
    if haskey(names, "default")
        signer = "default"
    elseif length(names) == 1
        signer = first(keys(names))
    else
        throw(ArgumentError(
            "JWTKeyset: the keyset has $(length(names)) keys and no \"default\" entry, so no key " *
            "is marked to sign. Name the signing key \"default\", or build " *
            "JWTKeyset(\"<signing kid>\" => secret; verify = [...]) to say which one signs"))
    end
    verify = Pair{String, Any}[kid => secret for (kid, secret) in names if kid != signer]
    return JWTKeyset(signer => names[signer]; verify = verify, claims = claims)
end

# `claims = ...` normalized to kid => ClaimScope. Every check runs here, at construction.
function _claim_scopes(claims)
    scopes = Dict{String, ClaimScope}()
    claims isa Union{AbstractDict, AbstractVector, Tuple} || throw(ArgumentError(
        "JWTKeyset: claims must be a Dict (or list) of kid => claim scope, got a $(typeof(claims))"))
    for pair in claims
        pair isa Pair || throw(ArgumentError(
            "JWTKeyset: claims must hold kid => claim scope pairs, got a $(typeof(pair))"))
        pair.first isa Union{AbstractString, Symbol} || throw(ArgumentError(
            "JWTKeyset: claims kid $(repr(pair.first)) is a $(typeof(pair.first)); a kid must be a String or Symbol"))
        kid = string(pair.first)
        haskey(scopes, kid) && throw(ArgumentError(
            "JWTKeyset: claims scopes kid $(repr(kid)) more than once"))
        scopes[kid] = _claim_scope(kid, pair.second)
    end
    return scopes
end

function _claim_scope(kid::String, spec)
    spec isa Union{AbstractVector, Tuple} || throw(ArgumentError(
        "JWTKeyset: the claim scope for kid $(repr(kid)) must be a list of claim names and " *
        "name => values pairs, got a $(typeof(spec))"))
    scope = ClaimScope()
    for entry in spec
        raw_name, raw_values = entry isa Pair ? (entry.first, entry.second) : (entry, nothing)
        raw_name isa Union{AbstractString, Symbol} || throw(ArgumentError(
            "JWTKeyset: the claim scope for kid $(repr(kid)) holds $(repr(entry)); an entry is a " *
            "claim name, or name => values"))
        name = string(raw_name)
        isempty(name) && throw(ArgumentError(
            "JWTKeyset: the claim scope for kid $(repr(kid)) names an empty claim"))
        name in _JWT_ALWAYS_ALLOWED_CLAIMS && throw(ArgumentError(
            "JWTKeyset: the claim scope for kid $(repr(kid)) lists $(repr(name)), which every key " *
            "may always assert ($(join(_JWT_ALWAYS_ALLOWED_CLAIMS, ", "))); drop it"))
        haskey(scope, name) && throw(ArgumentError(
            "JWTKeyset: the claim scope for kid $(repr(kid)) lists $(repr(name)) more than once"))
        scope[name] = entry isa Pair ? _pinned_values(kid, name, raw_values) : nothing
    end
    return scope
end

function _pinned_values(kid::String, name::String, values)
    listed = values isa Union{AbstractString, Symbol} ? (values,) : values
    listed isa Union{AbstractVector, Tuple, AbstractSet} || throw(ArgumentError(
        "JWTKeyset: the values pinned for $(repr(name)) on kid $(repr(kid)) must be a String or " *
        "a list of Strings, got a $(typeof(values))"))
    isempty(listed) && throw(ArgumentError(
        "JWTKeyset: no values are pinned for $(repr(name)) on kid $(repr(kid)), so no token " *
        "could carry it; list the allowed values, or drop the claim to refuse it outright"))
    allowed = Set{String}()
    for value in listed
        value isa Union{AbstractString, Symbol} || throw(ArgumentError(
            "JWTKeyset: the values pinned for $(repr(name)) on kid $(repr(kid)) include a " *
            "$(typeof(value)); a pinned value must be a String, because `==` would let `true` " *
            "pass a pin of `1`"))
        push!(allowed, string(value))
    end
    return allowed
end

# Checked in `_decode_jwt` once the signature has verified against the key that owns `scope`
# and the claims set has parsed, before anything reads a claim (#349). Rejecting rather than
# dropping is deliberate: a dropped `sub` is a Principal with `id = nothing`, and the issuer
# never learns its tokens are out of policy.
function _check_claim_scope(scope::ClaimScope, claims::Dict{String, Any}, kid::Nullable{String})
    # Neither the claim name nor its value is echoed: both are the token's, and a key holder
    # can make them as long as the header allows.
    _claims_in_scope(scope, claims) ||
        throw(AuthError("JWT key $(repr(kid)) is not permitted to assert every claim in this token"))
    return nothing
end

# The predicate both directions share: `_check_claim_scope` on decode, and `encode_jwt`, which
# refuses to mint a token its own keyset would reject.
function _claims_in_scope(scope::ClaimScope, claims::Dict{String, Any})::Bool
    for (name, value) in claims
        name in _JWT_ALWAYS_ALLOWED_CLAIMS && continue
        haskey(scope, name) || return false
        pinned = scope[name]
        pinned === nothing || _pin_admits(pinned, value) || return false
    end
    return true
end

# Claims that a validator REQUIRES but a scoped key may not assert (#349 review): such a key
# can never produce a token that passes both checks. Construction-time, like the
# `required_claims`/`warn_claims` overlap, because at request time it is only a stream of 401s.
# `expected` holds the one value a claim must have when the validator fixes it -- `issuer`, or
# a single-string `audience` -- so a pin that excludes that value counts as unassertable too.
function _unassertable_required(keyset::JWTKeyset, required::Vector{String},
                                expected::Dict{String, String} = Dict{String, String}())
    missing_by_kid = Pair{String, Vector{String}}[]
    unassertable(scope, name) = !haskey(scope, name) ||
        (scope[name] !== nothing && haskey(expected, name) && !(expected[name] in scope[name]))
    for key in keyset.keys
        key.scope === nothing && continue
        missing_names = String[name for name in required
                               if !(name in _JWT_ALWAYS_ALLOWED_CLAIMS) && unassertable(key.scope, name)]
        isempty(missing_names) || push!(missing_by_kid, key.kid => missing_names)
    end
    return missing_by_kid
end

# A claim value is `Any` by nature. A String must be pinned; a list passes only when every
# element is a pinned String; anything else -- a number, `null`, an object -- never does.
function _pin_admits(pinned::Set{String}, value)::Bool
    value isa AbstractString && return value in pinned
    value isa AbstractVector || return false
    for element in value
        (element isa AbstractString && element in pinned) || return false
    end
    return true
end

# The scope of the key that verified a token: only a `JWTKeyset` key carries one. A `Dict`
# lifted per call has no `claims`, and a string secret has no keys.
_key_scope(keyset::JWTKeyset, kid::String)::Nullable{ClaimScope} = keyset.keys[keyset.index[kid]].scope
_key_scope(_, _)::Nullable{ClaimScope} = nothing

function _keyset_entry(pair::Pair, use::Symbol)
    name, secret = pair.first, pair.second
    name isa Union{AbstractString, Symbol} || throw(ArgumentError(
        "JWTKeyset: kid $(repr(name)) is a $(typeof(name)); a kid must be a String or Symbol"))
    kid = string(name)
    isempty(kid) && throw(ArgumentError("JWTKeyset: a kid must not be empty"))
    # `isa` BEFORE any read. `String(::Vector{UInt8})` takes ownership of the buffer and
    # empties it, so merely reading such a value would destroy the caller's secret -- after
    # which it is `""`, and a token signed with the empty string authenticates. Refuse the
    # shape without touching it. Deliberately no `repr(secret)` in the message.
    wrapped = if secret isa SecretString
        secret
    elseif secret isa AbstractString
        SecretString(secret)
    else
        throw(ArgumentError(
            "JWTKeyset: the secret for kid $(repr(kid)) is a $(typeof(secret)); a secret must be " *
            "an AbstractString or a SecretString. A Vector{UInt8} in particular is refused " *
            "without being read -- converting one empties the caller's buffer"))
    end
    _empty_hmac_key(reveal(wrapped)) && throw(ArgumentError(
        "JWTKeyset: the secret for kid $(repr(kid)) is empty, or equivalent to the empty HMAC " *
        "key; a token signed with the empty string would verify against it"))
    _short_hmac_key(reveal(wrapped)) && throw(ArgumentError(
        "JWTKeyset: the secret for kid $(repr(kid)) is $(ncodeunits(reveal(wrapped))) bytes; " *
        _SHORT_SECRET_ADVICE))
    return (kid, wrapped, use)
end

# HMAC-of-empty-message under a key: equal fingerprints mean the same HMAC key.
_hmac_fingerprint(secret::SecretString) =
    SHA.hmac_sha256(Vector{UInt8}(codeunits(reveal(secret))), UInt8[])

const _EMPTY_SECRET_MESSAGE =
    "the JWT secret is empty, or equivalent to the empty HMAC key, so a token signed with " *
    "the empty string would verify against it. An unset environment variable read as " *
    "get(ENV, \"JWT_SECRET\", \"\") is the usual cause -- read it with a `nothing` default " *
    "and fail at startup instead"

# RFC 7518 §3.2: an HS256 key is at least as long as the hash output, 256 bits. One issued
# token is enough to test guesses against a short key offline, so `"secret"` is as good as
# no key to anyone holding a token (#321). The same floor `MIN_COOKIE_SECRET_BYTES` sets for
# cookie secrets (#309). Checked AFTER `_empty_hmac_key`, so an unset env var still gets
# the message that names it -- and 32+ NUL bytes, which is long enough, is still empty.
const MIN_JWT_SECRET_BYTES = 32

_short_hmac_key(secret::AbstractString) = ncodeunits(secret) < MIN_JWT_SECRET_BYTES

const _SHORT_SECRET_ADVICE =
    "an HS256 key must be at least $MIN_JWT_SECRET_BYTES random bytes (RFC 7518 §3.2), or one " *
    "issued token is enough to brute-force it offline. Generate one once -- e.g. " *
    "`bytes2hex(Nitro.Crypto.secure_random_bytes(32))` -- and read it from the environment " *
    "rather than writing it in source"

# The plain-string counterpart of `_keyset_entry`'s checks. Deliberately no `repr(secret)`
# in either message.
function _check_string_secret(secret::AbstractString)
    _empty_hmac_key(secret) && throw(ArgumentError(_EMPTY_SECRET_MESSAGE))
    _short_hmac_key(secret) && throw(ArgumentError(
        "the JWT secret is $(ncodeunits(secret)) bytes; " * _SHORT_SECRET_ADVICE))
    return secret
end

_signing_key(keyset::JWTKeyset) = @inbounds keyset.keys[1]

# kid => the claim names it may assert, sorted, for each scoped key. Names only: a pinned
# value is policy, not a secret, but a summary that lists names says what it needs to.
_scoped_names(keyset::JWTKeyset) = Dict{String, Vector{String}}(
    key.kid => sort!(collect(Base.keys(key.scope))) for key in keyset.keys if key.scope !== nothing)

function _keyset_summary(io::IO, keyset::JWTKeyset)
    print(io, "JWTKeyset(sign=", repr(_signing_key(keyset).kid))
    if length(keyset.keys) > 1
        print(io, ", verify=", repr(String[key.kid for key in @view(keyset.keys[2:end])]))
    end
    scoped = String[key.kid for key in keyset.keys if key.scope !== nothing]
    isempty(scoped) || print(io, ", scoped=", repr(scoped))
    print(io, ")")
end

# SECURITY: kids, roles and scoped claim names only. The default `show` would print each
# `JWTKey`, which is already masked through `SecretString` -- but a keyset lands in REPL
# auto-display, `@show` and interpolated config dumps, so it states its own contract rather
# than inheriting one.
Base.show(io::IO, keyset::JWTKeyset) = _keyset_summary(io, keyset)
Base.show(io::IO, ::MIME"text/plain", keyset::JWTKeyset) = show(io, keyset)
function JSON.lower(keyset::JWTKeyset)
    lowered = Dict{String, Any}(
        "sign" => _signing_key(keyset).kid,
        "verify" => String[key.kid for key in @view(keyset.keys[2:end])])
    scoped = _scoped_names(keyset)
    isempty(scoped) || (lowered["claims"] = scoped)
    return lowered
end
