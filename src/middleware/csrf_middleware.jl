module CSRFMiddleware_

using HTTP

using ...Types: CookieConfig, Nullable
using ...Cookies: get_cookie, set_cookie!
import ...Cookies
using ...Crypto: secure_random_bytes, _empty_hmac_key, _hmac_sha256, SecretString, reveal, base64url_encode
using ...Errors: is_unrecoverable
using ...Res: json
using ...Core: own_response_headers, getjson, getform
using ...Util: _mark_private!

export CSRFMiddleware, csrf_token!, issue_csrf_token!, validate_csrf_token

const SAFE_METHODS = Set(("GET", "HEAD", "OPTIONS", "TRACE"))

# `__Host-` by default: the cookie is deliberately readable by JS (the SPA has to echo the
# token), so the browser-enforced prefix is what stops a sibling subdomain from writing a
# different origin's CSRF cookie. Signing alone cannot -- a signature proves the server minted
# the token, not that it minted it for *this* client, which is what the binding below adds.
const DEFAULT_COOKIE_NAME = "__Host-csrf_token"

# The cookie's default `Max-Age`: seven days, `SessionMiddleware`'s default `absolute_max_age`, so
# the cookie never expires before a default session can (#441). A longer lifetime protects nothing
# less: the token verifies only under the session it was minted for (#23), so a cookie that
# outlives its session is inert, and the next request on the new session gets a fresh one. It used
# to be one hour, which sent an idle single-page app down the 403-and-retry path every hour.
# This layer cannot read the session middleware's lifetimes; a test pins the two defaults equal.
const DEFAULT_TTL = 7 * 86400

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
    return base64url_encode(_hmac_sha256(secret, message))
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

const _EMPTY_SECRET_MESSAGE =
    "the CSRF secret is empty, or equivalent to the empty HMAC key, so anyone could sign a " *
    "valid CSRF token with the empty string. An unset environment variable read as " *
    "get(ENV, \"CSRF_SECRET\", \"\") is the usual cause -- read it with a `nothing` default " *
    "and fail at startup instead"

# Refuse the key `_csrf_signature` would sign under before any token is minted or checked
# (#269), by the same HMAC rule `Auth` applies to a JWT secret (#264). Every public entry
# point calls it: the middleware once at construction, and the two primitives on each call,
# since a handler may reach them directly. Deliberately no `repr(secret)` in the message.
function _check_csrf_secret(secret::AbstractString)
    _empty_hmac_key(secret) && throw(ArgumentError(_EMPTY_SECRET_MESSAGE))
    return nothing
end

function _generate_raw_token()
    return base64url_encode(secure_random_bytes(32))
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
id is not (`Principal.id` is nullable, and a session-only app never populates `getuser(req)`).
`nothing` means the pipeline cannot bind, and every caller here fails closed on that.
"""
function _binding(req::HTTP.Request)::Nullable{String}
    value = Base.get(req.context, :session_id, nothing)
    return value isa AbstractString ? String(value) : nothing
end

function _warn_unbound()
    @warn "CSRFMiddleware has no session to bind tokens to: `:session_id` is missing from the " *
          "request context. Put SessionMiddleware OUTSIDE CSRFMiddleware in the pipeline " *
          "(`middleware=[SessionMiddleware(store = MemoryStore()), CSRFMiddleware(secret)]`). Until " *
          "then no token is issued and every unsafe request is rejected." maxlog=1
    return nothing
end

_validate_cookie_prefix(cookie_name::AbstractString, config::CookieConfig) =
    Cookies._validate_cookie_prefix(cookie_name, config; label = "CSRF cookie",
                                    plain_name = "csrf_token")

"""
    issue_csrf_token!(res, secret; binding, cookie_name, ttl, config) -> String

Mint a token bound to `binding` and set it on `res`. Returns the raw (unsigned) token, which is
what the client must echo in the `X-CSRF-Token` header.

`binding` is required and has no default on purpose: an unbound token is the defect this
function used to have, so there must be no way to ask for one by omission.

Throws `ArgumentError` when `secret` is empty or equivalent to the empty HMAC key (a run of
up to 64 NUL bytes) -- a token signed under it is one anyone can sign.
"""
function issue_csrf_token!(res::HTTP.Response, secret::String; binding::AbstractString, cookie_name::String=DEFAULT_COOKIE_NAME, ttl::Int=DEFAULT_TTL, config::CookieConfig=CookieConfig(httponly=false, secure=true, samesite="Lax", path="/", maxage=ttl))
    _check_csrf_secret(secret)
    _validate_cookie_prefix(cookie_name, config)
    raw_token = _generate_raw_token()
    _set_token_cookie!(res, secret, raw_token, binding, cookie_name, ttl, config)
    return raw_token
end

# Signs `raw_token` under `binding` and sets it on `res`. Split out of `issue_csrf_token!` so the
# middleware can sign a token it did NOT just generate: the one `csrf_token!` already handed the
# handler, which may have gone into the response body (#431).
function _set_token_cookie!(res::HTTP.Response, secret::String, raw_token::String,
                            binding::AbstractString, cookie_name::String, ttl::Int,
                            config::CookieConfig)
    set_cookie!(res, cookie_name, _signed_token(secret, raw_token, binding); config=config, encrypted=false, maxage=ttl)
    return nothing
end

# `req.context` keys. `:csrf_token` is long-standing and read by handlers; the others are the
# middleware's private handshake with `csrf_token!`.
#   :csrf_active        -- set by the middleware before the handler: `csrf_token!` may be called.
#   :csrf_binding       -- the session id the client's verified token is bound to (the binding at
#                          entry). A rotation since then makes that token the PRE-rotation one.
#   :csrf_requested     -- set by `csrf_token!`: the response must carry the token it returned.
#   :csrf_minted_here   -- set by `csrf_token!` when it generated the token in this request, so no
#                          one but this response has seen it.
const _ACTIVE_KEY = :csrf_active
const _BINDING_KEY = :csrf_binding
const _REQUESTED_KEY = :csrf_requested
const _MINTED_HERE_KEY = :csrf_minted_here

"""
    csrf_token!(req::HTTP.Request) -> String

Return this client's CSRF token, minting one if it has none. Call it from a handler behind
`CSRFMiddleware` wherever the client needs the token: a hidden `_csrf` form field, a JSON body
for a single-page app, a `<meta>` tag.

`CSRFMiddleware` creates a token on its own only when the visitor already has a session, or this
request saves one anyway. A first visit that nothing else gives a session gets no token unless a
handler calls this (#431). That is Django's `get_token`, and it is what keeps health checks,
bearer clients and scanners from creating a session per request.

The returned value is the raw token the client sends back in the `X-CSRF-Token` header, the
`_csrf` form field, or the `_csrf` JSON key. The middleware sets the matching cookie on the
response, and keeps the session the token is bound to. A client that already holds a valid
token gets that one back, and its cookie is re-sent so its `Max-Age` starts again: a token just
put in a page does not expire before the page is used.

**Call it after any `regenerate_session!` in the same handler**, as a login does. A rotation
retires the client's existing token, the way Django's `rotate_token` does on login, so a token
taken *before* the rotation is replaced in the cookie and the one the handler embedded stops
working. A token this call minted in the same request is kept across a rotation, since no one
else can have seen it.

```julia
login_form(req) = Res.html(\"\"\"
    <form method="post" action="/login">
      <input type="hidden" name="_csrf" value="\$(csrf_token!(req))">
      ...
    </form>\"\"\")

# A single-page app fetches it at startup, and again after a login, a logout or a 403, and
# echoes it in `X-CSRF-Token`.
path("/api/csrf", req -> Res.json(Dict("token" => csrf_token!(req))); method = "GET")
```

The token is URL-safe base64 (`A-Z a-z 0-9 - _`), so it needs no escaping in HTML.

Throws `ArgumentError` if `CSRFMiddleware` did not run on this request, or if it has no session
to bind the token to (put `SessionMiddleware` outside `CSRFMiddleware`). It never returns an
unbound token.
"""
function csrf_token!(req::HTTP.Request)::String
    Base.get(req.context, _ACTIVE_KEY, false) === true || throw(ArgumentError(
        "csrf_token! was called on a request CSRFMiddleware did not handle. Add " *
        "CSRFMiddleware(secret) to the pipeline, inside SessionMiddleware (#431)."))
    _binding(req) === nothing && throw(ArgumentError(
        "csrf_token! has no session to bind the token to: `:session_id` is missing from the " *
        "request context. Put SessionMiddleware OUTSIDE CSRFMiddleware in the pipeline."))
    token = Base.get(req.context, :csrf_token, nothing)
    # The client's own token is reused only while the session it is bound to is still the
    # session. After a rotation it is the pre-login token, and re-binding it to the new session
    # would let whoever knew it before the login keep using it after (#431 review).
    minted_here = Base.get(req.context, _MINTED_HERE_KEY, false) === true
    stale = !minted_here && Base.get(req.context, _BINDING_KEY, nothing) != _binding(req)
    if !(token isa String) || stale
        token = _generate_raw_token()
        req.context[:csrf_token] = token
        req.context[_MINTED_HERE_KEY] = true
    end
    req.context[_REQUESTED_KEY] = true
    return token
end

# Will the session outlive this response without CSRF's help? Then a token costs no extra store
# row, and the middleware mints one unasked (#431). Otherwise only `csrf_token!` makes it mint:
# keeping a session just to bind a token to it is what turned every cookieless GET into a store
# write under a global `CSRFMiddleware`, undoing #317.
#
# An ABSENT `:session_new` counts as an existing session. Only `SessionMiddleware` sets it; a
# pipeline that supplies `:session_id` some other way saves nothing on CSRF's behalf, so there is
# no growth to avoid, and minting as before keeps it working.
function _session_persists(req::HTTP.Request, binding_before::Nullable{String},
                           binding_after::String)::Bool
    Base.get(req.context, :session_new, false) === true || return true
    Base.get(req.context, :session_modified, false) === true && return true
    binding_before == binding_after || return true          # rotated: saved under the new id
    session = Base.get(req.context, :session, nothing)
    return session isa AbstractDict && !isempty(session)
end

function _presented_token(req::HTTP.Request, header_name::String, form_field::String)
    header_token = HTTP.header(req, header_name, "")
    if !isempty(header_token)
        return String(strip(header_token))
    end

    form = try
        getform(req)
    catch e
        # A body that will not parse carries no CSRF token, which is a 403 either way. A
        # corrupted process is not a missing token (#254).
        is_unrecoverable(e) && rethrow()
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
        getjson(req)
    catch e
        is_unrecoverable(e) && rethrow()
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

# A token going out in this response is bound to the session id, so that session must outlive the
# response. `SessionMiddleware` saves a NEW session only when something marks it modified (#317).
# Without this, an anonymous visitor's token was bound to an id nobody stored: the next request
# got a fresh id, the token no longer verified, and every POST was a 403. Called only when a token
# actually goes out -- never just because a safe request passed through (#431).
_keep_session!(req::HTTP.Request) = (req.context[:session_modified] = true; nothing)

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

Throws `ArgumentError` when `secret` is empty or equivalent to the empty HMAC key, on every
call -- not `false`, because that is a misconfiguration rather than a bad request.
"""
function validate_csrf_token(req::HTTP.Request, secret::String; cookie_name::String=DEFAULT_COOKIE_NAME, header_name::String="X-CSRF-Token", form_field::String="_csrf", binding::Nullable{String}=_binding(req))
    # Before any early `false`: an unusable secret is a configuration error on every call,
    # not only on the ones that happen to carry a cookie.
    _check_csrf_secret(secret)
    binding === nothing && return false

    cookie_value = get_cookie(req, cookie_name, nothing; encrypted=false)
    cookie_value === nothing && return false

    raw_token = _verify_signed_token(secret, cookie_value, binding)
    raw_token === nothing && return false

    presented = _presented_token(req, header_name, form_field)
    presented === nothing && return false
    return _constant_time_equals(presented, raw_token) || _constant_time_equals(presented, cookie_value)
end

"""
    CSRFMiddleware(secret; cookie_name = "__Host-csrf_token", header_name = "X-CSRF-Token",
                   form_field = "_csrf", ttl = 604800, config = CookieConfig(...))

CSRF protection with a signed double-submit cookie, bound to the session. `secret` is a
`String` or a `SecretString`; an empty one is an `ArgumentError`.

Every unsafe request (anything but `GET`, `HEAD`, `OPTIONS`, `TRACE`) must send the token back
in the `X-CSRF-Token` header, a `_csrf` form field, or a `_csrf` JSON key, or it gets `403`.

# When a token is issued

The token cookie is set on a response only when the client will need it and keeping it costs
nothing extra (#431):

- a handler called [`csrf_token!`](@ref Nitro.Core.Middleware.CSRFMiddleware_.csrf_token!)
  for it, to put it in a form or hand it to a single-page app;
- or the request's session is saved anyway: the visitor already had one, or this request wrote
  to it or rotated it.

A cookieless request nobody asked a token for, such as a health check, a bearer-token API call or
a scanner, gets no token and no session. So the middleware can sit in the global pipeline
without creating a session per request. That is Django's model. It used to mint on every safe
response and keep a session for each one, which made every cookieless `GET` a store write.

The cookie is re-issued whenever the client's token would not verify on the next request,
including after the handler rotates the session with `regenerate_session!`. A rejected request
from a client that echoed its own stale token gets a fresh one with the `403`, so a login that
rotates the session cannot lock the client out.

# Placement

```julia
serve(app, middleware = [
    SessionMiddleware(store = MemoryStore()),   # OUTSIDE: the token is bound to its session id
    CSRFMiddleware(ENV["CSRF_SECRET"]),
])
```

With no session id on the request the middleware fails closed: it issues no token, and rejects
every unsafe request.

# Keywords

- `cookie_name`: the `__Host-` prefix stops a sibling subdomain planting a token. Browsers
  accept it only on a `Secure`, `Path=/`, `Domain`-less cookie, so a `config` that cannot carry
  it is an `ArgumentError`. For plain-HTTP development pass `cookie_name = "csrf_token"` and a
  `config` with `secure = false`.
- `header_name`, `form_field`: where the token is read from on unsafe requests.
- `ttl`: the cookie's `Max-Age`, in seconds. Seven days by default, the default `absolute_max_age`
  of `SessionMiddleware`, so the cookie does not expire before its session does (#441). Keep it
  at least as long as your session's `max_age` and `absolute_max_age`: a shorter cookie sends an
  idle single-page app or an open form into a `403` while its session is still alive. A longer
  one costs nothing, because the token stops verifying when its session ends. With no absolute
  cap (`absolute_max_age = nothing`) no `ttl` covers every session; the `403` retry does.
- `config`: the cookie's attributes. It is not `httponly`, so a browser script can read the token.
"""
function CSRFMiddleware(key::Union{AbstractString, SecretString}; cookie_name::String=DEFAULT_COOKIE_NAME, header_name::String="X-CSRF-Token", form_field::String="_csrf", ttl::Int=DEFAULT_TTL, config::CookieConfig=CookieConfig(httponly=false, secure=true, samesite="Lax", path="/", maxage=ttl))
    # The closures below capture `sealed`, never the raw key: `repr` of a closure prints its
    # captures, so a plain `String` here was published by any `@info … middleware = mw` (#307).
    # The unwrap happens per request, into a local the closure does not hold.
    sealed = key isa SecretString ? key : SecretString(key)
    _check_csrf_secret(reveal(sealed))
    _validate_cookie_prefix(cookie_name, config)
    return function(handle::Function)
        return function(req::HTTP.Request)
            secret = reveal(sealed)
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
                        _keep_session!(req)
                    end
                    return rejection
                end
            end
            # The client's verified token, or `nothing`, for the handler to read -- on an unsafe
            # request too, which has just proved it holds one, so a handler re-rendering a form
            # after a POST hands back the same token.
            cookie_value = get_cookie(req, cookie_name, nothing; encrypted=false)
            req.context[:csrf_token] = (binding === nothing || cookie_value === nothing) ?
                nothing : _verify_signed_token(secret, cookie_value, binding)
            req.context[_ACTIVE_KEY] = true
            req.context[_BINDING_KEY] = binding
            binding_before = binding

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

            needs_token = cookie_value === nothing ||
                          _verify_signed_token(secret, cookie_value, binding) === nothing
            handler_minted = _response_sets_cookie(response, cookie_name)
            if handler_minted
                _keep_session!(req)
                return response
            end

            requested = Base.get(req.context, _REQUESTED_KEY, false) === true
            given = Base.get(req.context, :csrf_token, nothing)
            if requested && given isa String &&
               (!needs_token || Base.get(req.context, _MINTED_HERE_KEY, false) === true)
                # The handler holds `given` and may have put it in the body, so the cookie
                # carries THAT token. Either the client's own, still valid: re-sent so its
                # Max-Age starts again, as Django does whenever `get_token` runs. Or one
                # `csrf_token!` minted in this request: signed under the final binding, which
                # follows a rotation safely because nobody else has seen it.
                raw_token = given
            elseif needs_token &&
                   (requested || _session_persists(req, binding_before, binding))
                # Lazy (#431): a fresh token only when the handler asked, or the session is
                # saved anyway. A cookieless request nobody asked a token for creates nothing.
                # `requested` lands here only with the client's pre-rotation token, which a
                # rotation retires rather than re-binds.
                raw_token = _generate_raw_token()
            else
                return response
            end
            # Own the headers before issuing the cookie: `response` may be a shared/`const`
            # object, and setting a cookie mutates the headers in place.
            response = own_response_headers(response)
            _set_token_cookie!(response, secret, raw_token, binding, cookie_name, ttl, config)
            # One visitor's credential in a Set-Cookie (and, when the handler asked, often in the
            # body): never storable by a shared cache. A refresh sends it with no session write,
            # so `SessionMiddleware` would not mark it (#431 review).
            _mark_private!(response)
            req.context[:csrf_token] = raw_token
            # A refresh of a still-valid token needs nothing kept: its session already exists.
            needs_token && _keep_session!(req)
            return response
        end
    end
end

end
