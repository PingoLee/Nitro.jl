module CSRFMiddleware_

using HTTP
using SHA
using Base64

using ...Types: CookieConfig, Nullable
using ...Cookies: get_cookie, set_cookie!
using ...Crypto: secure_random_bytes
using ...Res: json
using ...Core: own_response_headers

export CSRFMiddleware, issue_csrf_token!, validate_csrf_token

const SAFE_METHODS = Set(("GET", "HEAD", "OPTIONS", "TRACE"))

# `__Host-` by default: the cookie is deliberately readable by JS (the SPA has to echo the
# token), so the browser-enforced prefix is what stops a sibling subdomain from writing a
# different origin's CSRF cookie. Signing alone cannot -- a signature proves the server minted
# the token, not that it minted it for *this* client, which is what the binding below adds.
const DEFAULT_COOKIE_NAME = "__Host-csrf_token"

const HOST_COOKIE_PREFIX = "__Host-"
const SECURE_COOKIE_PREFIX = "__Secure-"

function _base64url_encode(data::Vector{UInt8})
    encoded = Base64.base64encode(data)
    encoded = replace(encoded, '+' => '-', '/' => '_')
    return replace(encoded, '=' => "")
end

# The HMAC covers the random token AND the caller's binding (the session id), so a token minted
# for one client does not verify for another. `binding` never travels in the cookie -- only its
# HMAC does -- because the cookie is not httponly and the session id must stay off the JS side.
#
# The token is LENGTH-PREFIXED so that a (token, binding) pair has exactly one encoding. A plain
# `token * sep * binding` is ambiguous the moment either half can contain `sep`, and on the
# verification path `token` is the attacker-controlled half of the cookie: given a server-minted
# signature over `T|X|S`, an attacker re-slices it as token=`T|X`, binding=`S` and it verifies for
# session `S` -- the cross-client bypass this whole change exists to close. Nitro's own session
# ids are UUIDs and cannot contain a separator, but `binding` is a public parameter of
# `issue_csrf_token!`/`validate_csrf_token`, so the encoding has to guarantee this, not the caller.
function _csrf_signature(secret::String, token::AbstractString, binding::AbstractString)
    token_string = String(token)
    message = string(ncodeunits(token_string), ':', token_string, String(binding))
    signature = SHA.hmac_sha256(Vector{UInt8}(codeunits(secret)), Vector{UInt8}(codeunits(message)))
    return _base64url_encode(signature)
end

# Compare two strings without an early-exit, so attackers can't recover the
# expected signature/token byte-by-byte from response timing. The length check
# itself is not secret (token lengths are fixed and public).
function _constant_time_equals(left::AbstractString, right::AbstractString)
    left_bytes = codeunits(left)
    right_bytes = codeunits(right)
    length(left_bytes) == length(right_bytes) || return false
    diff = UInt8(0)
    @inbounds for index in eachindex(left_bytes)
        diff |= xor(left_bytes[index], right_bytes[index])
    end
    return diff == 0
end

function _generate_raw_token()
    return _base64url_encode(secure_random_bytes(32))
end

function _signed_token(secret::String, raw_token::String, binding::AbstractString)
    return string(raw_token, ".", _csrf_signature(secret, raw_token, binding))
end

function _parse_signed_token(value::AbstractString)
    parts = split(String(value), '.', limit=2)
    length(parts) == 2 || return nothing, nothing
    return parts[1], parts[2]
end

"""
Return the raw token carried by `cookie_value` if its signature verifies under `binding`,
otherwise `nothing`. A cookie signed for a *different* binding is indistinguishable from a
forged one on purpose -- both are simply not this client's token.
"""
function _verify_signed_token(secret::String, cookie_value::AbstractString, binding::AbstractString)
    raw_token, signature = _parse_signed_token(cookie_value)
    raw_token === nothing && return nothing
    _constant_time_equals(signature, _csrf_signature(secret, raw_token, binding)) || return nothing
    return String(raw_token)
end

"""
The value a token is bound to: the session id `SessionMiddleware` puts on the request context.

It is the only identifier present on *every* request, anonymous first visits included -- a user
id is not (`Principal.id` is nullable, and a session-only app never populates `req.user`).
`nothing` means the pipeline cannot bind, and every caller here fails closed on that.
"""
function _binding(req::HTTP.Request)::Nullable{String}
    value = Base.get(req.context, :session_id, nothing)
    return value isa AbstractString ? String(value) : nothing
end

function _warn_unbound()
    @warn "CSRFMiddleware has no session to bind tokens to: `:session_id` is missing from the " *
          "request context. Put SessionMiddleware OUTSIDE CSRFMiddleware in the pipeline " *
          "(`middleware=[SessionMiddleware(), CSRFMiddleware(secret)]`). Until then no token is " *
          "issued and every unsafe request is rejected." maxlog=1
    return nothing
end

"""
Reject a cookie-name prefix the surrounding config would make undeliverable.

Browsers match `__Host-`/`__Secure-` case-insensitively and *silently discard* a cookie that
violates the prefix rules, so a misconfigured pipeline looks healthy and then rejects every
mutation with no cookie ever reaching the client. Failing at construction turns that into an
error the developer sees once.
"""
function _validate_cookie_prefix(cookie_name::AbstractString, config::CookieConfig)
    lowered = lowercase(String(cookie_name))
    is_host = startswith(lowered, lowercase(HOST_COOKIE_PREFIX))
    (is_host || startswith(lowered, lowercase(SECURE_COOKIE_PREFIX))) || return nothing
    prefix = is_host ? HOST_COOKIE_PREFIX : SECURE_COOKIE_PREFIX

    config.secure || throw(ArgumentError(
        "CSRF cookie \"$cookie_name\" carries the $prefix prefix, which browsers accept only on a " *
        "Secure cookie. Pass `secure=true` in `config`, or use a cookie_name without the prefix " *
        "(e.g. `cookie_name=\"csrf_token\"`) when serving over plain HTTP."))

    if is_host
        config.domain === nothing || throw(ArgumentError(
            "CSRF cookie \"$cookie_name\" carries the $prefix prefix, which browsers accept only " *
            "when no Domain attribute is set (got domain=\"$(config.domain)\")."))
        config.path == "/" || throw(ArgumentError(
            "CSRF cookie \"$cookie_name\" carries the $prefix prefix, which browsers accept only " *
            "with Path=/ (got path=\"$(config.path)\")."))
    end
    return nothing
end

"""
    issue_csrf_token!(res, secret; binding, cookie_name, ttl, config) -> String

Mint a token bound to `binding` and set it on `res`. Returns the raw (unsigned) token, which is
what the client must echo in the `X-CSRF-Token` header.

`binding` is required and has no default on purpose: an unbound token is the defect this
function used to have, so there must be no way to ask for one by omission.
"""
function issue_csrf_token!(res::HTTP.Response, secret::String; binding::AbstractString, cookie_name::String=DEFAULT_COOKIE_NAME, ttl::Int=3600, config::CookieConfig=CookieConfig(httponly=false, secure=true, samesite="Lax", path="/", maxage=ttl))
    _validate_cookie_prefix(cookie_name, config)
    raw_token = _generate_raw_token()
    set_cookie!(res, cookie_name, _signed_token(secret, raw_token, binding); config=config, encrypted=false, maxage=ttl)
    return raw_token
end

function _presented_token(req::HTTP.Request, header_name::String, form_field::String)
    header_token = HTTP.header(req, header_name, "")
    if !isempty(header_token)
        return String(strip(header_token))
    end

    form = try
        req.form
    catch
        nothing
    end
    if form isa AbstractDict
        if haskey(form, form_field)
            return string(form[form_field])
        elseif haskey(form, Symbol(form_field))
            return string(form[Symbol(form_field)])
        end
    end

    json = try
        req.json
    catch
        nothing
    end
    if json isa AbstractDict
        if haskey(json, form_field)
            return string(json[form_field])
        elseif haskey(json, Symbol(form_field))
            return string(json[Symbol(form_field)])
        end
    end

    return nothing
end

"""
Is the presented token the cookie's own raw half (or the whole signed value)?

This is `validate_csrf_token` minus the signature check. It says **nothing about authenticity**:
the cookie need not have been minted by us, so a client that plants a self-consistent pair
(`x.y` + `x`) satisfies it. It exists only to tell "this client's own token went stale" apart from
a blind replay, and to keep the re-issue below off the path of a request that never held a token.

What actually makes re-issuing on a rejection safe is *not* this check — it is that the minted
token is bound to **the requester's own session** and delivered only in **their own** response, so
it conveys nothing a `GET` would not have already given them. What stops an attacker using it to
churn a third party's cookie is the cookie's own configuration: `__Host-` means they cannot plant
one, and `SameSite=Lax` means a cross-site unsafe request does not carry one — so `get_cookie`
below returns `nothing` and this returns `false` at its first line. (Note the binding is *not*
`nothing` in that case: `SessionMiddleware` mints a fresh session id whenever the presented cookie
is absent or unknown, so an unauthenticated stranger still has one. The request is refused because
the token does not verify, not because there is nothing to bind to.) An app that opts out of
**both** — an unprefixed `cookie_name` *and* `samesite="None"` — re-opens a token-churn nuisance
against its own users.
"""
function _client_echoed_own_cookie(req::HTTP.Request, cookie_name::String, header_name::String, form_field::String)
    cookie_value = get_cookie(req, cookie_name, nothing; encrypted=false)
    cookie_value === nothing && return false
    raw_token, _ = _parse_signed_token(cookie_value)
    raw_token === nothing && return false
    presented = _presented_token(req, header_name, form_field)
    presented === nothing && return false
    return _constant_time_equals(presented, raw_token) || _constant_time_equals(presented, cookie_value)
end

"""
Is `res` already setting `cookie_name` itself? A handler is allowed to mint its own token (and to
return the raw value in its body); the middleware must not then append a second, different cookie
that shadows it — `set_cookie!` appends, and the browser takes the last one, so the client would
end up holding a token that does not match what the handler told it to send.
"""
function _response_sets_cookie(res::HTTP.Response, cookie_name::String)
    prefix = cookie_name * "="
    for header in res.headers
        lowercase(header.first) == "set-cookie" && startswith(header.second, prefix) && return true
    end
    return false
end

"""
    validate_csrf_token(req, secret; cookie_name, header_name, form_field, binding) -> Bool

`false` unless the cookie's signature verifies **under this request's binding** and the presented
token matches it. With no binding available the answer is `false`, never "unbound but valid".
"""
function validate_csrf_token(req::HTTP.Request, secret::String; cookie_name::String=DEFAULT_COOKIE_NAME, header_name::String="X-CSRF-Token", form_field::String="_csrf", binding::Nullable{String}=_binding(req))
    binding === nothing && return false

    cookie_value = get_cookie(req, cookie_name, nothing; encrypted=false)
    cookie_value === nothing && return false

    raw_token = _verify_signed_token(secret, cookie_value, binding)
    raw_token === nothing && return false

    presented = _presented_token(req, header_name, form_field)
    presented === nothing && return false
    return _constant_time_equals(presented, raw_token) || _constant_time_equals(presented, cookie_value)
end

function CSRFMiddleware(secret::String; cookie_name::String=DEFAULT_COOKIE_NAME, header_name::String="X-CSRF-Token", form_field::String="_csrf", ttl::Int=3600, config::CookieConfig=CookieConfig(httponly=false, secure=true, samesite="Lax", path="/", maxage=ttl))
    _validate_cookie_prefix(cookie_name, config)
    return function(handle::Function)
        return function(req::HTTP.Request)
            method = uppercase(String(req.method))
            binding = _binding(req)

            if !(method in SAFE_METHODS)
                binding === nothing && _warn_unbound()
                if !validate_csrf_token(req, secret; cookie_name, header_name, form_field, binding)
                    rejection = json(Dict("error" => "Invalid CSRF token"); status=403)
                    # Hand a stale-but-genuine client a working token back, or a login is a
                    # lockout: `SessionMiddleware`'s `rotate_on_auth` rotates the session id
                    # AFTER this middleware has returned, so the login response cannot carry the
                    # replacement, and an SPA that only ever POSTs would 403 forever.
                    #
                    # The token goes to the REQUESTER, bound to THEIR session, so it hands out
                    # nothing a plain GET would not have. `_client_echoed_own_cookie` keeps a
                    # blind replay off this path but proves no authenticity -- see its docstring
                    # for what actually bounds the churn risk (`__Host-` and `SameSite`).
                    # `own_response_headers` because a module-level `const` error response is an
                    # endorsed Nitro pattern, and this one must not become a shared object we
                    # mutate per request.
                    if binding !== nothing && _client_echoed_own_cookie(req, cookie_name, header_name, form_field)
                        rejection = own_response_headers(rejection)
                        issue_csrf_token!(rejection, secret; binding, cookie_name, ttl, config)
                    end
                    return rejection
                end
            else
                cookie_value = get_cookie(req, cookie_name, nothing; encrypted=false)
                req.context[:csrf_token] = (binding === nothing || cookie_value === nothing) ?
                    nothing : _verify_signed_token(secret, cookie_value, binding)
            end

            response = handle(req)

            # Re-read the binding: a handler may have called `regenerate_session!`, which orphans
            # a token bound to the pre-rotation id. Re-issuing whenever the cookie would NOT
            # verify next time -- rather than only when it is absent -- gives Django-style CSRF
            # rotation on session rotation.
            #
            # This catches a HANDLER-driven rotation only. `SessionMiddleware`'s own
            # `rotate_on_auth` runs after this closure returns and is therefore invisible here;
            # the rejection path above is what recovers from that one.
            binding = _binding(req)
            if binding === nothing
                _warn_unbound()
                return response
            end

            cookie_value = get_cookie(req, cookie_name, nothing; encrypted=false)
            if (cookie_value === nothing || _verify_signed_token(secret, cookie_value, binding) === nothing) &&
               !_response_sets_cookie(response, cookie_name)
                # Own the headers before issuing the cookie: `response` may be a shared/`const`
                # object, and `issue_csrf_token!` mutates the headers in place.
                response = own_response_headers(response)
                raw_token = issue_csrf_token!(response, secret; binding, cookie_name, ttl, config)
                req.context[:csrf_token] = raw_token
            end
            return response
        end
    end
end

end
