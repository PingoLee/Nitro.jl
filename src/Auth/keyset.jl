# ── Typed JWT keyset (#260) ──────────────────────────────────────────────────────
#
# A keyset used to be a bare `Dict` of `kid => secret`, which cannot say which key signs,
# so `jwt.jl` re-answered "which key?" by hand three times (#45, #253 and its rider). This
# type answers it once, at construction: exactly one key signs, every key verifies. Roles
# describe USE (RFC 7517 `use`/`key_ops`), not lifecycle -- a keyset is as often a
# registry of client identities as it is a rotation window. See
# docs/design/typed-jwt-keyset.md.

struct JWTKey
    kid::String
    secret::SecretString
    use::Symbol          # :sign | :verify
end

Base.show(io::IO, key::JWTKey) = print(io, "JWTKey(", repr(key.kid), ", :", key.use, ")")
Base.show(io::IO, ::MIME"text/plain", key::JWTKey) = show(io, key)

"""
    JWTKeyset(signer::Pair; verify = ())
    JWTKeyset(keyset::AbstractDict)

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

`show` and `JSON.lower` report key ids and roles only, never a secret.
"""
struct JWTKeyset
    # Internal. The constructor's invariants hold only for what it built; code that mutates
    # these containers directly is outside the contract, like reflection on a SecretString.
    keys::Vector{JWTKey}         # keys[1] signs; the rest are sorted by kid
    index::Dict{String, Int}

    function JWTKeyset(signer::Pair; verify = ())
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
        keys = JWTKey[JWTKey(kid, secret, use) for (kid, secret, use) in entries]
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

function JWTKeyset(keyset::AbstractDict)
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
    return JWTKeyset(signer => names[signer]; verify = verify)
end

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
    # By HMAC key, not by `isempty`, for the same reason the duplicate check is: HMAC
    # zero-pads a short key, so "\0" (or any run of NULs up to the block size) IS the empty
    # key, and a token signed with "" would verify against it.
    _hmac_fingerprint(wrapped) == _EMPTY_KEY_FINGERPRINT && throw(ArgumentError(
        "JWTKeyset: the secret for kid $(repr(kid)) is empty, or equivalent to the empty HMAC " *
        "key; a token signed with the empty string would verify against it"))
    return (kid, wrapped, use)
end

# HMAC-of-empty-message under a key: equal fingerprints mean the same HMAC key.
_hmac_fingerprint(secret::SecretString) =
    SHA.hmac_sha256(Vector{UInt8}(codeunits(reveal(secret))), UInt8[])

const _EMPTY_KEY_FINGERPRINT = SHA.hmac_sha256(UInt8[], UInt8[])

_signing_key(keyset::JWTKeyset) = @inbounds keyset.keys[1]

function _keyset_summary(io::IO, keyset::JWTKeyset)
    print(io, "JWTKeyset(sign=", repr(_signing_key(keyset).kid))
    if length(keyset.keys) > 1
        print(io, ", verify=", repr(String[key.kid for key in @view(keyset.keys[2:end])]))
    end
    print(io, ")")
end

# SECURITY: kids and roles only. The default `show` would print each `JWTKey`, which is
# already masked through `SecretString` -- but a keyset lands in REPL auto-display, `@show`
# and interpolated config dumps, so it states its own contract rather than inheriting one.
Base.show(io::IO, keyset::JWTKeyset) = _keyset_summary(io, keyset)
Base.show(io::IO, ::MIME"text/plain", keyset::JWTKeyset) = show(io, keyset)
JSON.lower(keyset::JWTKeyset) = Dict{String, Any}(
    "sign" => _signing_key(keyset).kid,
    "verify" => String[key.kid for key in @view(keyset.keys[2:end])])
