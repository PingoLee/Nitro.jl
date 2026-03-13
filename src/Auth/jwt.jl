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
        return Dict(string(key) => value for (key, value) in pairs(data))
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

function _resolve_kid(keyset::AbstractDict, header_kid::Union{String, Nothing})
    if header_kid !== nothing
        _lookup_key(keyset, header_kid) === nothing && throw(AuthError("Unknown JWT key id"))
        return header_kid
    end
    fallback = _lookup_key(keyset, "default")
    if fallback !== nothing
        return "default"
    end
    first_key = first(keys(keyset))
    return string(first_key)
end

function _resolve_secret(secret_or_keyset, kid::Union{String, Nothing}=nothing)
    if secret_or_keyset isa AbstractString
        return (String(secret_or_keyset), kid)
    elseif secret_or_keyset isa AbstractDict
        resolved_kid = _resolve_kid(secret_or_keyset, kid)
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

function encode_jwt(payload::AbstractDict, secret_or_keyset; kid=nothing)
    header = Dict("alg" => "HS256", "typ" => "JWT")
    claims = _json_dict(payload)
    if !haskey(claims, "iat")
        claims["iat"] = _current_timestamp()
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

function decode_jwt(token::AbstractString, secret_or_keyset; issuer=nothing, audience=nothing, exp_timeout::Union{Int, Nothing}=nothing, iat_skew::Int=30, verify::Bool=true, with_kid::Bool=false)
    segments = split(String(token), '.')
    length(segments) == 3 || throw(AuthError("Invalid JWT format"))

    header = JSON.parse(String(_base64url_decode(segments[1])))
    claims = JSON.parse(String(_base64url_decode(segments[2])))
    kid = get(header, "kid", nothing)

    if verify
        secret, resolved_kid = _resolve_secret(secret_or_keyset, kid)
        signature = _hmac_sha256(secret, string(segments[1], ".", segments[2]))
        provided = _base64url_decode(segments[3])
        _constant_time_equals(signature, provided) || throw(AuthError("Invalid JWT signature"))
        kid = resolved_kid
    end

    validate_claims(claims; exp_timeout=exp_timeout, iat_skew=iat_skew, issuer=issuer, audience=audience)
    return with_kid ? (claims, kid) : claims
end