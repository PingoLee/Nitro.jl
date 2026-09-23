function _base64url_encode(data::Vector{UInt8})
    encoded = Base64.base64encode(data)
    encoded = replace(encoded, '+' => '-', '/' => '_')
    return replace(encoded, '=' => "")
end

function _base64url_decode(data::AbstractString)
    normalized = replace(String(data), '-' => '+', '_' => '/')
    padding = mod(4 - mod(length(normalized), 4), 4)
    return Base64.base64decode(normalized * repeat("=", padding))
end

function _json_dict(data)
    if data isa AbstractDict
        # Widen to `Any` values so we can always stamp integer `iat`/`exp`
        # claims, even when the caller passed a string-only payload (which would
        # otherwise infer a narrow `Dict{String,String}`).
        return Dict{String, Any}(string(key) => value for (key, value) in pairs(data))
    end
    throw(ArgumentError("JWT payload must be a dictionary"))
end

# ── Key selection ────────────────────────────────────────────────────────────────
#
# Signing and verifying ask DIFFERENT questions of a keyset (#253):
#
#   sign   -- "which ONE key do I sign with?" The keyset's signing key; `JWTKeyset`
#             holds exactly one by construction, so there is nothing to decide here.
#   verify -- "which keys COULD have signed this?" For a token that names a `kid`, that
#             key. For a token that names none, every key: RFC 7517 treats `kid` as a
#             hint, and a recipient holding a set is expected to try it.
#
# Both used to be answered by hand against a bare `Dict`, three times over (#45, #253
# and its rider). They are now dispatch on the secret's type; a `Dict` is lifted into a
# `JWTKeyset` first, which is also where its values are checked -- before anything reads
# them (#260, `src/Auth/keyset.jl`).

const _JWT_SECRET_TYPES = "a string, a JWTKeyset, or a Dict of kid => secret"

"""
    _verify_candidates(secret_or_keyset, header_kid) -> Vector{Tuple{Nullable{String}, String}}

The ordered `(kid, secret)` pairs a token may be verified against. Concretely typed
because this is the request path (nitro-core §7).
"""
function _verify_candidates(secret::AbstractString, header_kid::Nullable{String})
    # A single secret verifies everything, and the header `kid` stays an unverified label
    # passed straight back -- `jwt_validator` discards it via `kid_trusted`. An empty key is
    # refused here as well as at `jwt_validator` construction, for direct callers (#264).
    return Tuple{Nullable{String}, String}[(header_kid, String(_check_string_secret(secret)))]
end

function _verify_candidates(keyset::JWTKeyset, header_kid::Nullable{String})
    if header_kid !== nothing
        # A token that names its key gets that key and no other: the steady-state path
        # has no trial loop, so a forged token still costs exactly one HMAC.
        position = get(keyset.index, header_kid, 0)
        position == 0 && throw(AuthError("Unknown JWT key id"))
        key = keyset.keys[position]
        return Tuple{Nullable{String}, String}[(key.kid, reveal(key.secret))]
    end
    # Kid-less: every key, in the order `JWTKeyset` fixed at construction -- the signing
    # key first, then the rest by kid. No two keys are the same HMAC key, so at most one
    # candidate can match and the order is for reproducibility, not correctness.
    candidates = Tuple{Nullable{String}, String}[]
    sizehint!(candidates, length(keyset.keys))
    for key in keyset.keys
        push!(candidates, (key.kid, reveal(key.secret)))
    end
    return candidates
end

_verify_candidates(keyset::AbstractDict, header_kid::Nullable{String}) =
    _verify_candidates(JWTKeyset(keyset), header_kid)

_verify_candidates(other, ::Nullable{String}) =
    throw(ArgumentError("JWT secret must be $_JWT_SECRET_TYPES, got a $(typeof(other))"))

# `(secret, kid to stamp into the header)`. A plain string secret signs a kid-less token;
# a keyset signs with, and stamps, its signing key. A token signed with an empty key is
# one anyone can forge, so it is refused rather than issued (#264).
_signing_secret(secret::AbstractString) = (String(_check_string_secret(secret)), nothing)

function _signing_secret(keyset::JWTKeyset)
    key = _signing_key(keyset)
    return (reveal(key.secret), key.kid)
end

_signing_secret(keyset::AbstractDict) = _signing_secret(JWTKeyset(keyset))

_signing_secret(other) =
    throw(ArgumentError("JWT secret must be $_JWT_SECRET_TYPES, got a $(typeof(other))"))

function _hmac_sha256(secret::String, message::String)
    return SHA.hmac_sha256(Vector{UInt8}(codeunits(secret)), Vector{UInt8}(codeunits(message)))
end

function _constant_time_equals(left::Vector{UInt8}, right::Vector{UInt8})
    length(left) == length(right) || return false
    diff = UInt8(0)
    for index in eachindex(left)
        diff |= xor(left[index], right[index])
    end
    return diff == 0
end

function encode_jwt(payload::AbstractDict, secret_or_keyset; expires_in::Union{Int, Nothing}=nothing)
    header = Dict("alg" => "HS256", "typ" => "JWT")
    claims = _json_dict(payload)
    if !haskey(claims, "iat")
        claims["iat"] = _current_timestamp()
    end
    # Stamp an expiration when a TTL is requested and the caller didn't set one
    # explicitly, so issued tokens are time-bounded by default.
    if expires_in !== nothing && !haskey(claims, "exp")
        claims["exp"] = _claim_int(claims["iat"], "iat") + expires_in
    end

    secret, signing_kid = _signing_secret(secret_or_keyset)
    if signing_kid !== nothing
        header["kid"] = signing_kid
    end

    signing_input = string(
        _base64url_encode(Vector{UInt8}(codeunits(JSON.json(header)))), ".",
        _base64url_encode(Vector{UInt8}(codeunits(JSON.json(claims))))
    )
    signature = _base64url_encode(_hmac_sha256(secret, signing_input))
    return string(signing_input, ".", signature)
end

function decode_jwt(token::AbstractString, secret_or_keyset; issuer=nothing, audience=nothing, exp_timeout::Union{Int, Nothing}=DEFAULT_JWT_MAX_AGE_SECONDS, iat_skew::Int=30, verify::Bool=true, with_kid::Bool=false, require_exp::Bool=false, required_claims::Union{AbstractVector{<:AbstractString}, Nothing}=nothing)
    claims, kid = _decode_jwt(token, secret_or_keyset; issuer=issuer, audience=audience,
        exp_timeout=exp_timeout, iat_skew=iat_skew, verify=verify, require_exp=require_exp,
        required_claims=required_claims)
    return with_kid ? (claims, kid) : claims
end

# The body of `decode_jwt`, always returning `(claims, kid)`. `with_kid` is a runtime
# Bool that is not constant-propagated, so `decode_jwt(...; with_kid=true)` infers a
# `Union` of its two return shapes; `jwt_validator` calls this instead, and its per-request
# path sees one concrete tuple shape (#265, nitro-core §7).
function _decode_jwt(token::AbstractString, secret_or_keyset; issuer=nothing, audience=nothing, exp_timeout::Union{Int, Nothing}=DEFAULT_JWT_MAX_AGE_SECONDS, iat_skew::Int=30, verify::Bool=true, require_exp::Bool=false, required_claims::Union{AbstractVector{<:AbstractString}, Nothing}=nothing)
    segments = split(String(token), '.')
    length(segments) == 3 || throw(AuthError("Invalid JWT format"))

    # Every byte past the segment count is attacker-supplied, and BOTH decoders are sinks:
    # `base64decode` throws ArgumentError on a bad alphabet or a length that cannot be
    # padded, and `JSON.parse` throws ArgumentError on anything that is not JSON. Guarding
    # only the parsed VALUE would leave the class half closed -- and length-dependently so,
    # which is what makes a partial fix read as complete: a 4-char garbage signature decodes
    # to bytes and lands on a clean AuthError, while a 1-char one does not.
    #
    # The claims segment parses into a CONCRETE container (#274). Untyped, `JSON.parse`
    # infers `Any` and the object check below narrows it only to `AbstractDict`, so every
    # per-request consumer -- `validate_claims`, `_claim_value`, `Principal` -- dispatched
    # dynamically (nitro-core §7). `Dict{String, Any}` is also what `Principal` stores, so
    # the validator no longer copies the claims once per request either. The VALUES stay
    # `Any`: a claim is whatever the token's author typed. The header stays untyped -- it is
    # read for `alg` and `kid` and never passed on.
    header, claims = try
        (JSON.parse(String(_base64url_decode(segments[1]))),
         JSON.parse(String(_base64url_decode(segments[2])); dicttype = Dict{String, Any}))
    catch e
        # Catch the ONE type this guard exists for, and let everything else through. An
        # allow-list is not stylistic here: `JSON.parse` on a deeply-nested segment raises
        # `StackOverflowError`, which Julia itself reports as "program state may be
        # corrupted, so further execution might be unreliable" -- and a base64url header of
        # `[[[[...` reaches it from a bearer token at a depth well inside any header limit.
        # A broad catch turned that into a routine 401 and carried on. `OutOfMemoryError`
        # and `InterruptException` are the same class; so is a `MethodError` introduced by
        # a later edit inside this block. Naming the exceptions to rethrow means keeping
        # that list correct forever; naming the one to catch cannot rot.
        #
        # This also makes an `AuthError` rethrow unnecessary by construction rather than by
        # inspection: `AuthError <: Exception`, not `<: ArgumentError`, so it is not caught.
        e isa ArgumentError || rethrow()
        throw(AuthError("Invalid JWT encoding"))
    end

    # Decoding succeeding does not make either segment an object. A header of `[]` (`W10`)
    # makes `get(::Vector{Any}, "alg", nothing)` a MethodError; a non-object claims segment
    # makes `validate_claims(::AbstractDict)` one. None of this is an authz hole -- auth
    # middleware renders these as 401 -- but a direct `decode_jwt` caller was getting
    # exceptions the API does not document. (It used to render ANY throw as 401; since #254
    # the three in `is_unrecoverable` propagate instead. Every type on this path is an
    # `AuthError` or a `MethodError`, so none of them is affected.)
    header isa AbstractDict || throw(AuthError("Invalid JWT header"))
    # Checking the concrete type is what narrows the slot: `_decode_jwt` then infers
    # `Tuple{Dict{String, Any}, Nullable{String}}`.
    claims isa Dict{String, Any} || throw(AuthError("Invalid JWT claims"))

    # Same class, one level down: a JSON `kid` is whatever the token's author typed --
    # `123`, `["a"]`, `null`. Anything but a string is a MethodError on
    # `_verify_candidates`, whose `header_kid` parameter is itself typed -- so it fires
    # for a plain string secret just as it does for a keyset.
    raw_kid = get(header, "kid", nothing)
    (raw_kid === nothing || raw_kid isa AbstractString) ||
        throw(AuthError("Invalid JWT key id"))
    # A fresh binding, not a reassignment of `raw_kid`: Julia types a slot by the join over
    # every assignment to it, so narrowing in place would leave the slot `Any` and keep
    # `with_kid`'s return `Tuple{Any, Any}` on the per-request path through `jwt_validator`.
    kid::Nullable{String} = raw_kid === nothing ? nothing : String(raw_kid)

    if verify
        # Nitro signs and verifies with HMAC-SHA256 and nothing else, so the header's `alg`
        # used to be parsed and never read -- safe, but only by omission. A token claiming
        # `alg=RS256` whose signature was a valid HS256 HMAC was accepted, and `alg=none`
        # failed only incidentally, on the signature length check. Reject the mismatch
        # explicitly so the guarantee is stated rather than emergent (#45).
        #
        # Inside `verify` on purpose: `decode_jwt(...; verify=false)` is the offline
        # inspection path and must keep parsing a token whatever its header says.
        get(header, "alg", nothing) == "HS256" ||
            throw(AuthError("Unsupported JWT algorithm"))

        # Resolved BEFORE the signature is decoded, so a token naming an unknown `kid`
        # still reports "Unknown JWT key id" and is not pre-empted by a signature that
        # also happens to be malformed. That ordering predates the trial loop, and it is
        # worth preserving.
        candidates = _verify_candidates(secret_or_keyset, kid)

        # The third sink, and the sharpest one: a well-formed header and claims with a
        # signature segment that is not decodable base64 -- `Bearer <hdr>.<claims>.x` --
        # reached `base64decode` as an ArgumentError on the authenticated path.
        provided = try
            _base64url_decode(segments[3])
        catch e
            e isa ArgumentError || rethrow()
            # Deliberately NOT the same message as a signature that decodes but does not
            # match. Nothing leaks: the middleware replies with a fixed string, and the
            # attacker built the token, so they already know whether their own base64 is
            # well-formed. Meanwhile a truncated token -- a cookie past the 4KB limit, a
            # proxy trimming a long header -- is the classic way to produce a well-formed
            # header and claims with a mangled signature, and "encoding" sends the operator
            # to check transport rather than key rotation and clock skew.
            throw(AuthError("Invalid JWT signature encoding"))
        end

        # Hoisted: one string for the whole trial, not one per candidate. Decoding
        # `provided` ahead of the loop also means a garbage signature costs zero HMACs
        # rather than one per key.
        signing_input = string(segments[1], ".", segments[2])
        matched_kid::Nullable{String} = nothing
        verified = false
        for (candidate_kid, secret) in candidates
            _constant_time_equals(_hmac_sha256(secret, signing_input), provided) || continue
            matched_kid = candidate_kid
            verified = true
            break
        end
        if !verified
            # The message names key selection ONLY when key selection was actually in
            # play. With one candidate -- a string secret, a single-key keyset, or any
            # token that named its `kid` -- the answer is still "the signature does not
            # match", byte-identical to before, so the common case does not churn. It
            # reaches no client either way: auth middleware answers with a fixed 401.
            throw(AuthError(length(candidates) == 1 ?
                "Invalid JWT signature" :
                "No key in the JWT keyset verified this token"))
        end
        kid = matched_kid
    end

    validate_claims(claims; exp_timeout=exp_timeout, iat_skew=iat_skew, issuer=issuer, audience=audience, require_exp=require_exp, required_claims=required_claims)
    return (claims, kid)
end
