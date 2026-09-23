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

# ── The `warn_claims` observability tier (#134) ───────────────────────────────────
#
# A claim an app EXPECTS and intends to enforce, but cannot enforce yet because legacy
# issuers still omit it. Between `required_claims` (reject) and silence (learn nothing).
# Running that window by simply not asking for the claim means the app finds out who was
# non-compliant from the 401s after it flips `required_claims` -- in production.
#
# What an operator wants is the SET of non-compliant issuers, not a stream of events, so
# the signal is de-duplicated by `(claim, kid, iss)`. `maxlog=` cannot do this: it keys on
# the CALL SITE, not the message (see the note in `src/upgrading.jl`), so `maxlog=1` here
# would report the first offender and then hide every other one forever.
#
# Levels follow the house position set in `src/core/transport.jl`: the once-per-pair alarm
# goes to `@warn`, the per-request detail to `@debug`. An unbounded `@warn` on a path a
# chatty legacy issuer hits every request is a log-flood amplifier.

# `iss` is inside the verified payload, so a key-holder chooses it. Bound what reaches the
# de-dup set and the log; a 1MB `iss` is signed, not trusted.
const _WARN_ISS_MAX = 128
# And bound the set itself, so a high-cardinality `iss` cannot grow it without limit.
const _WARN_SEEN_CAP = 64

function _warn_iss(value)
    value === nothing && return nothing
    text = string(value)
    return length(text) > _WARN_ISS_MAX ? string(first(text, _WARN_ISS_MAX), "…") : text
end

function _report_missing_claim!(seen::Set{NTuple{3, Nullable{String}}}, seen_lock::ReentrantLock,
        claim::String, kid::Nullable{String}, iss::Nullable{String})
    # Every occurrence, for whoever is actually investigating.
    @debug("JWT is missing an expected claim", claim = claim, kid = kid, iss = iss)
    # First sighting of this issuer only. The lock is reached ONLY on a miss, which is a
    # subset of traffic during the rollout window and none of it afterwards -- so there is
    # no steady-state hot-path lock here to stripe (cf. #22, #36).
    key = (claim, kid, iss)
    first_sighting = lock(seen_lock) do
        key in seen && return false
        if length(seen) >= _WARN_SEEN_CAP
            length(seen) == _WARN_SEEN_CAP || return false
            # One more insert, of a sentinel, so this branch fires exactly once.
            push!(seen, (nothing, nothing, nothing))
            @warn("JWT warn_claims reporting is saturated; further offenders are at debug level only",
                  distinct_pairs = _WARN_SEEN_CAP)
            return false
        end
        push!(seen, key)
        return true
    end
    first_sighting && @warn(
        "JWT is missing an expected claim (warn_claims); this will be rejected once it is required",
        claim = claim, kid = kid, iss = iss)
    return nothing
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
  signer is the principal). Requires `secret_or_keyset` to be a keyset — a
  [`JWTKeyset`](@ref), or a `Dict` of `kid => secret` — because with a single string secret
  the header `kid` is an unverified label, so this mode throws an `ArgumentError` at
  construction.

# Keysets

`secret_or_keyset` is a string secret, a [`JWTKeyset`](@ref), or a `Dict` of
`kid => secret`. A `Dict` is lifted into a `JWTKeyset` **once, here**, so every keyset
misconfiguration — a multi-key `Dict` with no `"default"`, two entries that are the same
HMAC key, a non-string secret — is an `ArgumentError` at construction, which is app
startup. The validator keeps that snapshot: mutating the `Dict` afterwards has no effect.

A string secret is held to the same rule as a keyset secret: one that is empty, or that
HMAC treats as empty (a short run of `"\\0"` bytes), is an `ArgumentError` at construction.
Read the secret with a `nothing` default — `get(ENV, "JWT_SECRET", nothing)` — and fail at
startup when it is missing; a `""` default would otherwise authenticate every token signed
with the empty string. `encode_jwt` and `decode_jwt` refuse such a secret too.

# Profiles

- `profile = :default` — signature + time-bound validation, plus any explicitly passed
  `decode_jwt` kwargs (`issuer`, `audience`, `require_exp`, `required_claims`, ...).
- `profile = :strict` — production preset: requires `issuer` and `audience` to be
  configured (construction-time `ArgumentError` otherwise) and forces `require_exp=true`.
  Combine with `required_claims=["sub"]` to also demand a subject identity.

# Claim tiers

A claim can be in one of three positions, not two:

- **ignored** — not named anywhere. A token without it authenticates and nothing is said.
- **observed** — named in `warn_claims`. A token without it still authenticates, and the
  validator logs one `@warn` the first time it sees a given `(claim, kid, iss)` triple,
  plus an `@debug` on every occurrence. This is the tier for a claim you intend to
  enforce but cannot yet, because legacy issuers still omit it: it names the offending
  issuers *before* you close the door on them.
- **required** — named in `required_claims` (a `decode_jwt` passthrough). A token without
  it is rejected.

A claim may not be in both `warn_claims` and `required_claims`; that is a construction-time
`ArgumentError`. The signal carries the claim name, the *keyset-verified* `kid`, and `iss`
— never the token and never any other claim value. De-duplication is capped, so a
high-cardinality `iss` cannot grow it without bound.

```julia
# Observe now, enforce next quarter.
jwt_validator(keyset; required_claims = ["iss"], warn_claims = ["sub"])
```

`identity_claim` is just a claim name, so this is also how you observe the
`identity_from = :claim` case where a token yields a `Principal` with no `id`:
put that claim in `warn_claims`.

# Return value

Without `user_validator`, the validator returns a [`Principal`](@ref). With
`user_validator`, it is called as `user_validator(principal[, req])` — the `Principal` is
dict-like, so validators written against claims dictionaries keep working — and the
validator returns `(user, principal)`, so auth middleware attaches the app user at
`req.context[:user]` and the normalized principal at `req.context[:auth_claims]`.

A `user_validator` returning `nothing` — "the token verified, but there is no such user" —
makes the whole validator return `nothing`, which auth middleware renders as a `401`. That
is the precedent custom validators follow: never hand back a `(nothing, claims)` tuple,
because a nil user is no user and is rejected the same way.

The validator is a pure function of the token: it never mutates the request.
"""
function jwt_validator(secret_or_keyset;
        user_validator::Union{Function, Nothing}=nothing,
        identity_from::Symbol=:claim,
        identity_claim::String="sub",
        profile::Symbol=:default,
        warn_claims::Union{AbstractVector{<:AbstractString}, Nothing}=nothing,
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

    # Lift a Dict ONCE, here, so every keyset check runs at app startup and the closure
    # holds a snapshot: mutating the caller's Dict afterwards no longer changes which keys
    # verify under a running server -- a change the checks could never have seen (#260).
    # `JWTKeyset` owns those checks now (distinct kids, distinct HMAC keys, string-or-
    # SecretString values refused before they are read), so a direct `decode_jwt` caller
    # gets them too.
    keyset = secret_or_keyset isa AbstractDict ? JWTKeyset(secret_or_keyset) : secret_or_keyset
    keyset isa Union{AbstractString, JWTKeyset} || throw(ArgumentError(
        "jwt_validator: the secret must be $_JWT_SECRET_TYPES, got a $(typeof(keyset))"))
    # At construction, which is app startup: an empty string secret -- typically an unset
    # env var read with a "" default -- makes every token forged with "" authenticate
    # (#264). `JWTKeyset` already refused this for its own secrets; a plain string did not.
    keyset isa AbstractString && _check_string_secret(keyset)

    # Only a keyset-resolved kid is verified; `decode_jwt` with a single string secret
    # passes the attacker-chosen header kid through as an unverified label.
    kid_trusted = keyset isa JWTKeyset
    if identity_from === :kid && !kid_trusted
        throw(ArgumentError("identity_from=:kid requires a keyset (a JWTKeyset, or a Dict of kid => secret); a header kid is not verified against a single secret"))
    end

    # The warn tier lives HERE, not in `decode_jwt`/`validate_claims`: those are free
    # functions with no instance to hang de-dup state on, so putting it there would force
    # either a module-global registry or a state argument threaded through every caller.
    # This closure is already built once per validator per app, which is exactly the
    # non-global, per-app state the tier needs -- the same shape `FixedRateLimiter` and
    # `SessionMiddleware` use for theirs. `decode_jwt` stays a pure function of the token.
    warn_list = warn_claims === nothing ? String[] : String[String(name) for name in warn_claims]
    if !isempty(warn_list)
        required = get(kwargs, :required_claims, nothing)
        if required !== nothing
            overlap = intersect(Set(warn_list), Set(String(name) for name in required))
            isempty(overlap) || throw(ArgumentError(
                "jwt_validator: $(join(sort!(collect(overlap)), ", ")) appears in both required_claims " *
                "and warn_claims; a claim is either enforced or observed, not both"))
        end
    end
    seen_warned = Set{NTuple{3, Nullable{String}}}()
    seen_lock = ReentrantLock()

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
        claims, kid = decode_jwt(token, keyset; with_kid=true, decode_kwargs...)
        resolved_kid = kid_trusted && kid !== nothing ? String(kid) : nothing
        # `resolved_kid`, never the raw header kid: the header value is attacker-chosen,
        # and this one has been resolved against the keyset. An unverified kid must not
        # reach an operator's log as though it identified a signer.
        if !isempty(warn_list)
            iss = _warn_iss(_claim_value(claims, "iss", nothing))
            for name in warn_list
                _claim_value(claims, name, nothing) === nothing || continue
                _report_missing_claim!(seen_warned, seen_lock, name, resolved_kid, iss)
            end
        end
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
