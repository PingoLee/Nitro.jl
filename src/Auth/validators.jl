function _invoke_user_validator(validator::Function, claims)
    methods = Base.methods(validator)
    if any(length(method.sig.parameters) - 1 == 2 for method in methods)
        return validator(claims, nothing)
    end
    return validator(claims)
end

# Build the normalized principal for a verified token. `kid` must already be trusted
# (keyset-resolved) or `nothing`.
function _principal(claims::AbstractDict, kid::Union{String, Nothing}, identity_from::Symbol, identity_claim::String)
    id = if identity_from === :kid
        kid
    else
        value = _claim_value(claims, identity_claim, nothing)
        value === nothing ? nothing : string(value)
    end
    return Principal(claims; id=id, kid=kid, source=identity_from)
end

"""
    jwt_validator(secret_or_keyset; user_validator=nothing, identity_from=:claim,
                  identity_claim="sub", profile=:default, kwargs...)

Build a token-validation function for `BearerAuth`/`CookieAuthMiddleware` that verifies a
JWT and returns the authenticated principal.

Safe by default: every token is signature-verified and time-bounded (`exp`, or `iat` +
`exp_timeout` fallback). Hardening is opt-in on top — never the other way around.

# Identity

- `identity_from = :claim` (default) — the principal's `id` comes from `identity_claim`
  (default `"sub"`). A token without that claim still authenticates; its `id` is `nothing`
  (typical for service/capability tokens).
- `identity_from = :kid` — the principal's `id` is the *keyset-verified* key id (the
  signer is the principal). Requires `secret_or_keyset` to be a keyset (`Dict` of
  `kid => secret`); with a single string secret the header `kid` is an unverified label,
  so this mode throws an `ArgumentError` at construction.

# Profiles

- `profile = :default` — signature + time-bound validation, plus any explicitly passed
  `decode_jwt` kwargs (`issuer`, `audience`, `require_exp`, `required_claims`, ...).
- `profile = :strict` — production preset: requires `issuer` and `audience` to be
  configured (construction-time `ArgumentError` otherwise) and forces `require_exp=true`.
  Combine with `required_claims=["sub"]` to also demand a subject identity.

# Return value

Without `user_validator`, the validator returns a [`Principal`](@ref). With
`user_validator`, it is called as `user_validator(principal[, req])` — the `Principal` is
dict-like, so validators written against claims dictionaries keep working — and the
validator returns `(user, principal)`, so auth middleware attaches the app user at
`req.context[:user]` and the normalized principal at `req.context[:auth_claims]`.

The validator is a pure function of the token: it never mutates the request.
"""
function jwt_validator(secret_or_keyset;
        user_validator::Union{Function, Nothing}=nothing,
        identity_from::Symbol=:claim,
        identity_claim::String="sub",
        profile::Symbol=:default,
        kwargs...)

    identity_from in (:claim, :kid) ||
        throw(ArgumentError("identity_from must be :claim or :kid, got $(repr(identity_from))"))
    profile in (:default, :strict) ||
        throw(ArgumentError("profile must be :default or :strict, got $(repr(profile))"))
    haskey(kwargs, :with_kid) &&
        throw(ArgumentError("with_kid is managed internally by jwt_validator"))
    # Signature verification is the validator's entire purpose; it must never be disabled
    # through the passthrough kwargs, or a forged token (and its attacker-chosen kid)
    # would be trusted. `decode_jwt(...; verify=false)` remains available for the rare
    # offline-inspection case, but not via an auth validator.
    haskey(kwargs, :verify) &&
        throw(ArgumentError("verify cannot be disabled on a jwt_validator; it always verifies signatures"))

    # Only a keyset-resolved kid is verified; `decode_jwt` with a single string secret
    # passes the attacker-chosen header kid through as an unverified label.
    kid_trusted = secret_or_keyset isa AbstractDict
    if identity_from === :kid && !kid_trusted
        throw(ArgumentError("identity_from=:kid requires a keyset (Dict of kid => secret); a header kid is not verified against a single secret"))
    end

    # Concrete NamedTuple capture — all profile resolution happens here, once, at
    # construction; the per-request closure does no configuration branching.
    decode_kwargs = values(kwargs)
    if profile === :strict
        get(kwargs, :issuer, nothing) === nothing &&
            throw(ArgumentError("profile=:strict requires issuer=..."))
        get(kwargs, :audience, nothing) === nothing &&
            throw(ArgumentError("profile=:strict requires audience=..."))
        get(kwargs, :require_exp, true) === false &&
            throw(ArgumentError("profile=:strict forces require_exp=true; do not pass require_exp=false"))
        decode_kwargs = merge(decode_kwargs, (require_exp = true,))
    end

    return function(token::AbstractString, req::Union{HTTP.Request, Nothing}=nothing)
        claims, kid = decode_jwt(token, secret_or_keyset; with_kid=true, decode_kwargs...)
        resolved_kid = kid_trusted && kid !== nothing ? String(kid) : nothing
        principal = _principal(claims, resolved_kid, identity_from, identity_claim)
        if user_validator === nothing
            return principal
        end
        user = if req === nothing
            _invoke_user_validator(user_validator, principal)
        else
            methods = Base.methods(user_validator)
            if any(length(method.sig.parameters) - 1 == 2 for method in methods)
                user_validator(principal, req)
            else
                user_validator(principal)
            end
        end
        return user === nothing ? nothing : (user, principal)
    end
end

function session_user_validator(store::AbstractSessionStore; user_key::String="user")
    return function(session_id::String, session_data=nothing)
        # The second argument doubles as the middleware arity-dispatch slot: auth
        # middleware passes the `HTTP.Request` there, which is not session data.
        resolved = (session_data === nothing || session_data isa HTTP.Request) ?
            get_session(store, session_id) : session_data
        resolved === nothing && return nothing
        if resolved isa AbstractDict
            if haskey(resolved, user_key)
                return resolved[user_key]
            elseif haskey(resolved, Symbol(user_key))
                return resolved[Symbol(user_key)]
            end
        end
        return resolved
    end
end

no_auth_validator() = _ -> nothing
