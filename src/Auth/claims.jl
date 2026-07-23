function _claim_value(claims::AbstractDict, key::AbstractString, default=nothing)
    if haskey(claims, key)
        return claims[key]
    elseif haskey(claims, Symbol(key))
        return claims[Symbol(key)]
    end
    return default
end

function _claim_int(value, field::String)
    if value isa Integer
        return Int(value)
    elseif value isa AbstractFloat
        return trunc(Int, value)
    elseif value isa AbstractString
        parsed = tryparse(Int, value)
        isnothing(parsed) && throw(AuthError("Invalid $field claim"))
        return parsed
    end
    throw(AuthError("Invalid $field claim"))
end

_current_timestamp() = trunc(Int, Dates.datetime2unix(Dates.now(Dates.UTC)))

const DEFAULT_JWT_MAX_AGE_SECONDS = 15 * 60

function validate_iat(claims::AbstractDict; timeout::Int=300, skew::Int=30, now_ts::Int=_current_timestamp())
    iat = _claim_value(claims, "iat", nothing)
    iat === nothing && throw(AuthError("Missing iat claim"))

    issued_at = _claim_int(iat, "iat")
    if now_ts < issued_at - skew
        throw(AuthError("JWT issued in the future"))
    end
    if now_ts > issued_at + timeout + skew
        throw(AuthError("JWT expired (iat too old)"))
    end
    return true
end

function _normalize_audience(value)
    if value === nothing
        return String[]
    elseif value isa AbstractString
        return [String(value)]
    elseif value isa AbstractVector || value isa Tuple || value isa Set
        return [string(item) for item in value]
    end
    return [string(value)]
end

function validate_claims(claims::AbstractDict; exp_timeout::Union{Int, Nothing}=DEFAULT_JWT_MAX_AGE_SECONDS, iat_skew::Int=30, issuer=nothing, audience=nothing, require_exp::Bool=false, required_claims::Union{AbstractVector{<:AbstractString}, Nothing}=nothing, now_ts::Int=_current_timestamp())
    exp = _claim_value(claims, "exp", nothing)
    if exp === nothing
        if require_exp
            throw(AuthError("JWT missing required exp claim"))
        end
        exp_timeout === nothing && throw(AuthError("JWT missing exp claim and no fallback max age was configured"))
        # A token without `exp` is still accepted, but only as a short-lived
        # access token bounded by iat + exp_timeout.
        validate_iat(claims; timeout=exp_timeout, skew=iat_skew, now_ts=now_ts)
    elseif now_ts > _claim_int(exp, "exp") + iat_skew
        throw(AuthError("JWT expired"))
    end

    nbf = _claim_value(claims, "nbf", nothing)
    if nbf !== nothing && now_ts + iat_skew < _claim_int(nbf, "nbf")
        throw(AuthError("JWT not yet valid"))
    end

    iat = _claim_value(claims, "iat", nothing)
    if iat !== nothing
        issued_at = _claim_int(iat, "iat")
        if now_ts + iat_skew < issued_at
            throw(AuthError("JWT issued in the future"))
        end
    end

    if issuer !== nothing
        token_issuer = _claim_value(claims, "iss", nothing)
        token_issuer == issuer || throw(AuthError("Invalid JWT issuer"))
    end

    if audience !== nothing
        expected = _normalize_audience(audience)
        actual = _normalize_audience(_claim_value(claims, "aud", nothing))
        any(item in actual for item in expected) || throw(AuthError("Invalid JWT audience"))
    end

    if required_claims !== nothing
        for name in required_claims
            if _claim_value(claims, name, nothing) === nothing
                throw(AuthError("JWT missing required claim: $name"))
            end
        end
    end

    return claims
end
