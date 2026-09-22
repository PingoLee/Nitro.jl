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

function _lookup_key(keyset::AbstractDict, kid::String)
    if haskey(keyset, kid)
        return String(keyset[kid])
    elseif haskey(keyset, Symbol(kid))
        return String(keyset[Symbol(kid)])
    end
    return nothing
end

# ── Key selection ────────────────────────────────────────────────────────────────
#
# Signing and verifying ask DIFFERENT questions of a keyset, and one helper used to
# answer both. `_resolve_kid` returned exactly one key, which is the right shape for
# signing and the wrong shape for verifying (#253):
#
#   sign   -- "which ONE key do I sign with?" There has to be exactly one answer.
#   verify -- "which keys COULD have signed this?" For a token that names a `kid`,
#             that is one key. For a token that names none it is every distinct key
#             NAME in the set: RFC 7517 treats `kid` as a hint, and a recipient holding
#             a set is expected to try it. Trying only `"default"` rejected valid tokens
#             for the whole of a rotation window -- exactly when a keyset holds more
#             than one entry and an external issuer may still be signing with the old
#             key. ("Name", not "entry", because `_lookup_key` resolves `"a"` and `:a`
#             to one name and prefers the String; a keyset mixing both shadows one.)
#
# Both helpers are guards around a keyset type that does not exist. A JWK Set gives
# each key a role (`use`, `key_ops`), so "which key signs" has one answer by
# construction and "which keys verify" is a filter rather than a fallback chain. A
# bare `Dict{String,String}` can express neither, which is why the question has been
# answered three times in this file by hand. See the typed-keyset design issue.

function _signing_kid(keyset::AbstractDict, header_kid::Union{String, Nothing})
    if header_kid !== nothing
        _lookup_key(keyset, header_kid) === nothing && throw(AuthError("Unknown JWT key id"))
        return header_kid
    end
    _lookup_key(keyset, "default") === nothing || return "default"
    # An empty keyset has no key to fall back to. `first(keys(...))` raises a BoundsError
    # here, which escapes as something no caller catches -- auth middleware renders any
    # throw as 401, but a direct caller sees the wrong type.
    isempty(keyset) && throw(AuthError("Unknown JWT key id"))
    first_key = first(keys(keyset))
    return string(first_key)
end

"""
    _verify_candidates(secret_or_keyset, header_kid) -> Vector{Tuple{Nullable{String}, String}}

The ordered `(kid, secret)` pairs a token may be verified against. Concretely typed
because this is the request path (nitro-core §7).
"""
function _verify_candidates(secret_or_keyset, header_kid::Nullable{String})
    if secret_or_keyset isa AbstractString
        # A single secret verifies everything, and the header `kid` stays an unverified
        # label passed straight back -- `jwt_validator` discards it via `kid_trusted`.
        return Tuple{Nullable{String}, String}[(header_kid, String(secret_or_keyset))]
    elseif secret_or_keyset isa AbstractDict
        if header_kid !== nothing
            # A token that names its key gets that key and no other. Unchanged, and
            # deliberately so: the steady-state path gains no trial loop, so a forged
            # token still costs exactly one HMAC.
            secret = _lookup_key(secret_or_keyset, header_kid)
            secret === nothing && throw(AuthError("Unknown JWT key id"))
            return Tuple{Nullable{String}, String}[(header_kid, secret)]
        end
        isempty(secret_or_keyset) && throw(AuthError("Unknown JWT key id"))
        candidates = Tuple{Nullable{String}, String}[]
        sizehint!(candidates, length(secret_or_keyset))
        # `"default"` first, then the rest by name. The sort costs one small allocation
        # on a path that is BY DEFINITION the rotation window; a token bearing a `kid`
        # returned above without reaching it. Order is not load-bearing for
        # correctness -- `jwt_validator` refuses a keyset whose entries share a secret,
        # so at most one candidate can match -- but it is load-bearing for
        # reproducibility, of tests and of the `kid` that reaches an operator's log.
        default_secret = _lookup_key(secret_or_keyset, "default")
        default_secret === nothing || push!(candidates, ("default", default_secret))
        for name in sort!(unique!(String[string(k) for k in keys(secret_or_keyset)]))
            name == "default" && continue
            secret = _lookup_key(secret_or_keyset, name)
            secret === nothing && continue
            push!(candidates, (name, secret))
        end
        isempty(candidates) && throw(AuthError("Unknown JWT key id"))
        return candidates
    end
    throw(ArgumentError("JWT secret must be a string or dictionary"))
end

function _resolve_secret(secret_or_keyset, kid::Union{String, Nothing}=nothing)
    if secret_or_keyset isa AbstractString
        return (String(secret_or_keyset), kid)
    elseif secret_or_keyset isa AbstractDict
        resolved_kid = _signing_kid(secret_or_keyset, kid)
        secret = _lookup_key(secret_or_keyset, resolved_kid)
        secret === nothing && throw(AuthError("Unknown JWT key id"))
        return (secret, resolved_kid)
    end
    throw(ArgumentError("JWT secret must be a string or dictionary"))
end

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

function encode_jwt(payload::AbstractDict, secret_or_keyset; kid=nothing, expires_in::Union{Int, Nothing}=nothing)
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

    secret, resolved_kid = _resolve_secret(secret_or_keyset, kid)
    if resolved_kid !== nothing
        header["kid"] = resolved_kid
    end

    signing_input = string(
        _base64url_encode(Vector{UInt8}(codeunits(JSON.json(header)))), ".",
        _base64url_encode(Vector{UInt8}(codeunits(JSON.json(claims))))
    )
    signature = _base64url_encode(_hmac_sha256(secret, signing_input))
    return string(signing_input, ".", signature)
end

function decode_jwt(token::AbstractString, secret_or_keyset; issuer=nothing, audience=nothing, exp_timeout::Union{Int, Nothing}=DEFAULT_JWT_MAX_AGE_SECONDS, iat_skew::Int=30, verify::Bool=true, with_kid::Bool=false, require_exp::Bool=false, required_claims::Union{AbstractVector{<:AbstractString}, Nothing}=nothing)
    segments = split(String(token), '.')
    length(segments) == 3 || throw(AuthError("Invalid JWT format"))

    # Every byte past the segment count is attacker-supplied, and BOTH decoders are sinks:
    # `base64decode` throws ArgumentError on a bad alphabet or a length that cannot be
    # padded, and `JSON.parse` throws ArgumentError on anything that is not JSON. Guarding
    # only the parsed VALUE would leave the class half closed -- and length-dependently so,
    # which is what makes a partial fix read as complete: a 4-char garbage signature decodes
    # to bytes and lands on a clean AuthError, while a 1-char one does not.
    header, claims = try
        (JSON.parse(String(_base64url_decode(segments[1]))),
         JSON.parse(String(_base64url_decode(segments[2]))))
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
    # middleware renders any throw as 401 -- but a direct `decode_jwt` caller was getting
    # exceptions the API does not document.
    header isa AbstractDict || throw(AuthError("Invalid JWT header"))
    claims isa AbstractDict || throw(AuthError("Invalid JWT claims"))

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
        # also happens to be malformed. That is the error ordering `_resolve_secret`
        # had when it stood here, and it is worth preserving.
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
    return with_kid ? (claims, kid) : claims
end
