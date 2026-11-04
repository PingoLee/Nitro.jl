function _claim_value(claims::AbstractDict, key::AbstractString, default=nothing)
    if haskey(claims, key)
        return claims[key]
    elseif haskey(claims, Symbol(key))
        return claims[Symbol(key)]
    end
    return default
end

# The container `decode_jwt` parses into (#274). A `Dict{String, Any}` cannot hold a
# `Symbol` key, so the fallback above would only intern a Symbol and miss, per claim read.
_claim_value(claims::Dict{String, Any}, key::AbstractString, default=nothing) = get(claims, key, default)

# Every caller holds a claim read out of a `Dict{String, Any}`, so `value` is `Any` at the call
# site, and three things together keep that from boxing an `Int` per claim -- three allocations
# per token in `validate_claims` (#456). Each was measured; none is enough alone:
#
# - `@nospecialize`: compiled once for `Any`, the call is static. Specialized, it was a dynamic
#   dispatch, and a dynamic call's `Int` comes back boxed whatever inference knows of it.
# - `::Int`: inference could not prove the abstract branches below return an `Int`, so the
#   caller's `+ iat_skew` was a dynamic call too, boxing ITS result.
# - The concrete `Int` branch first: JSON.jl parses every integer claim to an `Int64`, and it is
#   the only branch that returns without a call. The abstract ones narrow `value` no further
#   than `Integer`, so their `Int(value)` dispatches dynamically -- fine for the float and string
#   spellings another issuer might use, measurably worse for the common one.
#
# The float and string spellings come next at the types JSON.jl parses them into, `Float64` and
# `String`, so that `trunc` and `tryparse` are static calls: on an `AbstractFloat` or an
# `AbstractString` they were not, which `juliac --trim` rejects (docs/design/juliac-trim.md
# §3.11). Other numbers and strings, which only a claims dict an application built can hold, go
# to `_claim_int_abstract`.
function _claim_int(@nospecialize(value), field::String)::Int
    value isa Int && return value
    value isa Float64 && return trunc(Int, value)
    value isa String && return _claim_int_parse(value, field)
    # `Int(value)` on an abstract `Integer` resolves statically only while few `Integer` methods are
    # loaded, so it is out of line too: in a full test run, it was a dynamic call.
    (value isa Integer || value isa AbstractFloat || value isa AbstractString) &&
        return _claim_int_abstract(value, field)
    throw(AuthError("Invalid $field claim"))
end

function _claim_int_parse(value::String, field::String)::Int
    parsed = tryparse(Int, value)
    isnothing(parsed) && throw(AuthError("Invalid $field claim"))
    return parsed
end

@noinline function _claim_int_abstract(@nospecialize(value), field::String)::Int
    _trimmed() && throw(ArgumentError(
        "Nitro: a trimmed image reads a time claim as an Int64, a Float64 or a String; got a $(nameof(typeof(value)))"))
    value isa Integer && return Int(value)
    value isa AbstractFloat && return trunc(Int, value)
    parsed = tryparse(Int, value)
    isnothing(parsed) && throw(AuthError("Invalid $field claim"))
    return parsed
end

# `string(value)` for a claim value, which is `Any`. JSON's scalars are listed, so their `string` is
# static; a container or a value outside the list keeps the JIT's dynamic call, and a trimmed image
# refuses it (`with_json_value`). Used for the principal's `id` and the `iss` that `warn_claims`
# reports.
_claim_string(@nospecialize(value))::String = with_json_value(_claim_string_typed, value)

_claim_string_typed(value::Union{String, Int64, Float64, Bool}) = string(value)
_claim_string_typed(value) = _claim_string_other(value)

@noinline function _claim_string_other(@nospecialize(value))::String
    _trimmed() && throw(ArgumentError(
        "Nitro: a trimmed image reads a claim as a string only from a JSON scalar; got a $(nameof(typeof(value)))"))
    return string(value)
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
