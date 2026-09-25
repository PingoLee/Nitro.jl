function _base64url_encode(data::Vector{UInt8})
    encoded = Base64.base64encode(data)
    encoded = replace(encoded, '+' => '-', '/' => '_')
    return replace(encoded, '=' => "")
end

# Strict: canonical base64url and nothing else (#321). This used to translate `-_` to `+/`
# and pad, so the standard alphabet, `=` padding, and -- in the last character -- any of the
# 4 (or 16) letters differing only in bits the decoder discards all decoded to the same bytes.
# Every such spelling of a signature verified, so one token had many strings, and anything
# keyed on the raw token (a denylist, a replay cache) could be walked around. RFC 7515 §2
# defines the encoding with no padding.
#
# Canonical means: the URL-safe alphabet only, no padding, a length that is not 1 mod 4, and
# zero in the bits of the last character that fall past the final byte -- the low 4 bits when
# 2 characters are left over, the low 2 when 3 are. That last rule is checked on the value
# directly rather than by re-encoding and comparing, which did the same job at three times
# the cost on every segment of every request. The test suite holds it to the re-encoding
# definition exhaustively over every 2- and 3-character input, so the two cannot drift.
#
# Throws ArgumentError, the one type both callers in `_decode_jwt` catch.
function _base64url_decode(data::AbstractString)
    units = codeunits(data)
    count = length(units)
    remainder = mod(count, 4)
    remainder == 1 && throw(ArgumentError("not base64url: impossible length"))
    # Translated to the standard alphabet and padded in one buffer, for `base64decode`.
    standard = Vector{UInt8}(undef, remainder == 0 ? count : count + 4 - remainder)
    last_value = 0x00
    for (index, byte) in enumerate(units)
        last_value, translated = if UInt8('A') <= byte <= UInt8('Z')
            byte - UInt8('A'), byte
        elseif UInt8('a') <= byte <= UInt8('z')
            byte - UInt8('a') + 0x1a, byte
        elseif UInt8('0') <= byte <= UInt8('9')
            byte - UInt8('0') + 0x34, byte
        elseif byte == UInt8('-')
            0x3e, UInt8('+')
        elseif byte == UInt8('_')
            0x3f, UInt8('/')
        else
            throw(ArgumentError("not base64url"))
        end
        standard[index] = translated
    end
    discarded = remainder == 2 ? 0x0f : remainder == 3 ? 0x03 : 0x00
    last_value & discarded == 0x00 || throw(ArgumentError("not canonical base64url"))
    for index in (count + 1):length(standard)
        standard[index] = UInt8('=')
    end
    return Base64.base64decode(standard)
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

# The encoded JOSE header segment `_decode_jwt` accepts, in bytes. Nitro's own header --
# `{"alg":"HS256","typ":"JWT","kid":…}` -- is well under 100 bytes; 1 KB leaves room for a
# long `kid` and for another issuer's extra members while bounding what an unsigned token
# can make the server decode and parse (#314). `encode_jwt` refuses to mint past it.
const _JWT_MAX_HEADER_SEGMENT_BYTES = 1024

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

    encoded_header = _base64url_encode(Vector{UInt8}(codeunits(JSON.json(header))))
    # Only a keyset's `kid` can grow the header, and a token `_decode_jwt` would refuse is
    # not one to issue (#314). The kid is not echoed: it names a key.
    ncodeunits(encoded_header) <= _JWT_MAX_HEADER_SEGMENT_BYTES || throw(ArgumentError(
        "JWT header would exceed $_JWT_MAX_HEADER_SEGMENT_BYTES bytes encoded; use a shorter kid"))
    signing_input = string(
        encoded_header, ".",
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

    # The order below is RFC 7519 §7.2's: the JOSE header is decoded and checked (steps
    # 3-5), the JWS is validated (step 7), and only THEN is the claims set decoded (steps
    # 9-10). It used to parse both segments up front, which put the claims parser -- a
    # recursive-descent `JSON.parse` -- in front of anyone who could send a header, signed
    # or not (#314). Now an unsigned token reaches exactly one JSON parse, of a header
    # capped at `_JWT_MAX_HEADER_SEGMENT_BYTES`, and even that one is depth-bounded.
    #
    # The cap holds on the `verify=false` path too. That path promises to parse whatever
    # `alg` says, not whatever size the header is; an HS256 header is under 100 bytes.
    ncodeunits(segments[1]) <= _JWT_MAX_HEADER_SEGMENT_BYTES ||
        throw(AuthError("Invalid JWT header: longer than $_JWT_MAX_HEADER_SEGMENT_BYTES bytes"))
    header = _jwt_segment_json(segments[1])

    # Decoding succeeding does not make the segment an object. A header of `[]` (`W10`)
    # makes `get(::Vector{Any}, "alg", nothing)` a MethodError. None of this is an authz
    # hole -- auth middleware renders it as 401 -- but a direct `decode_jwt` caller was
    # getting exceptions the API does not document.
    header isa AbstractDict || throw(AuthError("Invalid JWT header"))

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

        # RFC 7515 §4.1.11: a recipient that does not understand an extension listed in
        # `crit` MUST reject the token -- the issuer is saying "do not accept this unless
        # you enforce X". Nitro understands no extensions, so any `crit` at all, malformed
        # ones included, is one it cannot honour (#321). Ignoring it used to accept tokens
        # whose issuer had made acceptance conditional.
        haskey(header, "crit") &&
            throw(AuthError("Unsupported critical JWT header extension"))

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

    # The claims set, decoded only now that the signature has verified (or the caller asked
    # for `verify=false`). It parses into a CONCRETE container (#274): untyped, `JSON.parse`
    # infers `Any` and an `AbstractDict` check narrows it no further, so every per-request
    # consumer -- `validate_claims`, `_claim_value`, `Principal` -- dispatched dynamically
    # (nitro-core §7). `Dict{String, Any}` is also what `Principal` stores, so the validator
    # does not copy the claims per request either. The VALUES stay `Any`: a claim is
    # whatever the token's author typed.
    claims = _jwt_segment_json(segments[2]; dicttype = Dict{String, Any})
    # Checking the concrete type is what narrows the slot -- assigned exactly once, so
    # `_decode_jwt` infers `Tuple{Dict{String, Any}, Nullable{String}}`.
    claims isa Dict{String, Any} || throw(AuthError("Invalid JWT claims"))

    validate_claims(claims; exp_timeout=exp_timeout, iat_skew=iat_skew, issuer=issuer, audience=audience, require_exp=require_exp, required_claims=required_claims)
    return (claims, kid)
end

"""
    _jwt_segment_json(segment; kwargs...)

Base64url-decode one JWT segment and parse it as JSON through `_parse_json_bounded`, so its
nesting is bounded before the parser recurses (#314). Either decoder failing is
`AuthError("Invalid JWT encoding")`.
"""
function _jwt_segment_json(segment::AbstractString; kwargs...)
    try
        # No field cap (#327): a segment is already size-bounded, and the cap's `ValidationError`
        # is not the `AuthError` this function promises. The depth bound still applies.
        return _parse_json_bounded(String(_base64url_decode(segment)); max_fields = 0, kwargs...)
    catch e
        # Every byte of the segment is attacker-supplied, and BOTH decoders are sinks:
        # `base64decode` throws ArgumentError on a bad alphabet or a length that cannot be
        # padded, and `JSON.parse` -- or the depth bound in front of it -- throws
        # ArgumentError on anything that is not acceptable JSON. Guarding only the parsed
        # VALUE would leave the class half closed.
        #
        # Catch the ONE type this guard exists for, and let everything else through. An
        # allow-list is not stylistic: `StackOverflowError`, `OutOfMemoryError` and
        # `InterruptException` are not "a bad token" (#254), and neither is a `MethodError`
        # introduced by a later edit inside this block. Naming the exceptions to rethrow
        # means keeping that list correct forever; naming the one to catch cannot rot. It
        # also makes an `AuthError` rethrow unnecessary by construction: `AuthError <:
        # Exception`, not `<: ArgumentError`, so it is not caught.
        e isa ArgumentError || rethrow()
        throw(AuthError("Invalid JWT encoding"))
    end
end
