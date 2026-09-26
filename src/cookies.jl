module Cookies

using HTTP
using Dates
using UUIDs
using ..Types
using ..Types: _normalize_domain
using ..Errors

using ..Crypto: encrypt_payload, decrypt_payload, secure_uuid4, SecretString, _cookie_secret

export parse_cookies, format_cookie, get_cookie, set_cookie!, load_cookie_settings!,
    storesession!, prunesessions!, regenerate_session!

# ============================================================================
# SECTION 1: Internal Normalization & Validation
# ============================================================================

"""
    _normalize_attribute_name(name::Union{String, Symbol})

Normalizes the attribute name to standard lowercase symbols.
"""
function _normalize_attribute_name(name::Union{String, Symbol}) :: Symbol
    n = replace(lowercase(string(name)), "_" => "")
    n == "path" && return :path
    n == "secure" && return :secure
    n == "httponly" && return :httponly
    n == "domain" && return :domain
    n == "expires" && return :expires
    n == "maxage" && return :maxage
    n == "samesite" && return :samesite
    n == "max-age" && return :maxage
    n == "http-only" && return :httponly
    n == "same-site" && return :samesite
    n == "secretkey" && return :secret_key
    n == "maxcookiesize" && return :max_cookie_size
    
    return n |> Symbol
end

"""
Helper to convert SameSite string to standard string
"""
function _samesite_to_mode(val::String) :: Union{String, Nothing}
    val_lower = lowercase(strip(val))
    val_lower == "lax" && return "Lax"
    val_lower == "strict" && return "Strict"
    val_lower == "none" && return "None"
    nothing
end

"""
Helper to normalize expires value from various sources
"""
function _normalize_expires(val::Any) :: Union{Dates.DateTime, Nothing}
    if isnothing(val) || val isa Dates.DateTime
        return val
    end

    if !isa(val, AbstractString)
        throw(ArgumentError("expires: expected String or DateTime, got $(typeof(val))"))
    end
  
    # Try RFC 2822: "Wed, 09 Jun 2025 10:18:14 GMT"
    if occursin(r"^[A-Za-z]{3},\s+\d{2}\s+[A-Za-z]{3}\s+\d{4}\s+\d{2}:\d{2}:\d{2}\s+[A-Z]{3}$", val)
        try return Dates.DateTime(val, dateformat"e, dd u yyyy HH:MM:SS \G\M\T") catch; end
    end
  
    # Try ISO 8601: "2025-06-09T10:18:14Z"
    if occursin(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$", val)
        try return Dates.DateTime(val, dateformat"yyyy-mm-ddTHH:MM:SS\Z") catch; end
    end
  
    # Try Unix timestamp
    if occursin(r"^\d+$", val)
        try return Dates.unix2datetime(parse(Int64, val)) catch; end
    end
  
    throw(ArgumentError("expires: cannot parse '$val' as DateTime"))
end

function _normalize_bool(val::Any, name::String) :: Bool
    if val isa Bool
        return val
    elseif val isa AbstractString
        v = lowercase(strip(val))
        if v in ("true", "1", "yes", "on")
            return true
        elseif v in ("false", "0", "no", "off")
            return false
        end
    elseif val isa Number
        return val != 0
    end
    throw(ArgumentError("$name: cannot parse '$val' as Bool"))
end

function _has_ctl_chars(val::AbstractString) :: Bool
    return any(ch -> ch <= '\x1f' || ch == '\x7f', val)
end

function _validate_cookie_name(name::String) :: String
    isempty(name) && throw(ArgumentError("cookie name cannot be empty"))
    _has_ctl_chars(name) && throw(ArgumentError("cookie name contains control characters"))

    for ch in name
        if isletter(ch) || isdigit(ch) || ch in ('!', '#', '\$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~')
            continue
        end
        throw(ArgumentError("cookie name contains invalid character: '$ch'"))
    end

    return name
end

function _validate_cookie_value(value::String) :: String
    _has_ctl_chars(value) && throw(ArgumentError("cookie value contains control characters"))

    for ch in value
        if ch == '!' || ('#' <= ch <= '+') || ('-' <= ch <= ':') || ('<' <= ch <= '[') || (']' <= ch <= '~')
            continue
        end
        throw(ArgumentError("cookie value contains invalid character: '$ch'"))
    end

    return value
end

function _normalize_path(val::Any) :: String
    if !isa(val, AbstractString)
        throw(ArgumentError("path: expected String, got $(typeof(val))"))
    end

    path = String(val)
    isempty(path) && throw(ArgumentError("path: cannot be empty"))
    startswith(path, "/") || throw(ArgumentError("path: must start with '/': $path"))
    _has_ctl_chars(path) && throw(ArgumentError("path: contains control characters"))
    occursin(';', path) && throw(ArgumentError("path: contains invalid character: ';'"))

    return path
end

function _normalize_runtime_path(val::Any) :: String
    if !isa(val, AbstractString)
        throw(ArgumentError("path: expected String, got $(typeof(val))"))
    end

    path = String(val)
    _has_ctl_chars(path) && throw(ArgumentError("path: contains control characters"))
    occursin(';', path) && throw(ArgumentError("path: contains invalid character: ';'"))

    if isempty(path) || !startswith(path, "/")
        return "/"
    end

    return path
end

function _normalize_maxage(val::Any) :: Tuple{Union{Int, Nothing}, Bool, Union{Dates.DateTime, Nothing}}
    mv = if val isa AbstractString
        tryparse(Int, val)
    elseif val isa Number
        Int(val)
    else
        nothing
    end

    if isnothing(mv) && val isa AbstractString
        throw(ArgumentError("max_age: cannot parse '$val' as integer"))
    end

    if mv == 0
        return (0, true, Dates.DateTime(1970, 1, 1))
    else
        return (mv, false, nothing)
    end
end

# ============================================================================
# SECTION 2: Parsing & Formatting (The Engine)
# ============================================================================

"""
Internal helper to extract a single cookie value from a header string lazily.
Works with SubString views to minimize allocations.

Cookie names match **exactly** and the **first** occurrence wins (#329). Names are
case-sensitive (RFC 6265 §4.1.1), and matching them case-insensitively let
`__HOST-csrf_token=attacker` -- a name no prefix-checking browser protects -- shadow the real
`__Host-csrf_token` sent after it (the "Cookie Crumbles" prefix bypass). First-wins follows
RFC 6265 §5.4, which sends the most specific path first, and matches Go's `Request.Cookie` and
npm `cookie`; `parse_cookies` agrees.
"""
function _extract_value_from_header(header_value::AbstractString, target_key::String) :: Union{SubString{String}, Nothing}
    for pair in eachsplit(header_value, ';')
        trimmed = strip(pair)
        idx = findfirst('=', trimmed)

        name_view = isnothing(idx) ? trimmed : strip(@view trimmed[begin:prevind(trimmed, idx)])

        if name_view == target_key
            if isnothing(idx)
                return SubString("")
            end
            # Extract, strip whitespace, then strip surrounding quotes if balanced
            val_view = strip(@view trimmed[nextind(trimmed, idx):end])
            if length(val_view) >= 2 && val_view[begin] == '"' && val_view[end] == '"'
                return @view val_view[nextind(val_view, begin):prevind(val_view, end)]
            end
            return val_view
        end
    end
    return nothing
end

"""
Optimized cookie parser that uses SubStrings to minimize allocations.
Strips surrounding quotes from values according to RFC 6265.

Reads the request `Cookie` header(s) only -- every one of them, since HTTP/2 may split the
cookie list across several. A name sent twice keeps its **first** value, as `get_cookie` does
(#329): this used to keep the last, so the two helpers disagreed on the same request.
"""
function parse_cookies(headers::Union{Dict, Vector{Pair{String, String}}, HTTP.Headers})
    cookies = Dict{SubString{String}, SubString{String}}()

    if headers isa Dict
        cookie_header = Base.get(headers, "cookie", Base.get(headers, "Cookie", ""))
        _parse_cookie_header!(cookies, cookie_header)
    else
        for (k, v) in headers
            lowercase(k) == "cookie" && _parse_cookie_header!(cookies, v)
        end
    end

    return cookies
end

function _parse_cookie_header!(cookies::Dict{SubString{String}, SubString{String}}, cookie_header::AbstractString)
    for pair in eachsplit(String(cookie_header), ';')
        trimmed = strip(pair)
        if isempty(trimmed)
            continue
        end

        # find the first '=' to split name and value
        idx = findfirst('=', trimmed)
        if isnothing(idx)
            # RFC 6265: Cookie without '=' is treated as name with empty value
            haskey(cookies, trimmed) || (cookies[trimmed] = "")
            continue
        end

        name = strip(@view trimmed[begin:prevind(trimmed, idx)])
        value = strip(@view trimmed[nextind(trimmed, idx):end])

        # Strip surrounding quotes if balanced (RFC 6265)
        if length(value) >= 2 && value[begin] == '"' && value[end] == '"'
            value = @view value[nextind(value, begin):prevind(value, end)]
        end

        haskey(cookies, name) || (cookies[name] = value)
    end
    return cookies
end

function parse_cookies(req::HTTP.Request)
    return parse_cookies(req.headers)
end

function parse_cookies(res::HTTP.Response)
    # Set-Cookie is different as it can have name=value; attr1=val1; ...
    cookies = Dict{SubString{String}, SubString{String}}()
    for (k, v) in res.headers
        if lowercase(k) == "set-cookie"
            # find the first ';' which separates the cookie-pair from attributes
            semi_idx = findfirst(';', v)
            pair_view = isnothing(semi_idx) ? SubString(v) : @view v[begin:prevind(v, semi_idx)]
            
            eq_idx = findfirst('=', pair_view)
            if !isnothing(eq_idx)
                name = strip(@view pair_view[begin:prevind(pair_view, eq_idx)])
                val = strip(@view pair_view[nextind(pair_view, eq_idx):end])
                
                # Strip internal quotes if balanced (RFC 6265)
                if length(val) >= 2 && val[begin] == '"' && val[end] == '"'
                    val = @view val[nextind(val, begin):prevind(val, end)]
                end
                
                cookies[name] = val
            end
        end
    end
    return cookies
end

"""
Strictly format a cookie header string according to RFC 6265bis
"""
function format_cookie(
    name::String, 
    value::String; 
    path::String = "/", 
    domain::Nullable{String} = nothing, 
    expires::Nullable{Dates.DateTime} = nothing, 
    maxage::Nullable{Int} = nothing, 
    httponly::Bool = true, 
    secure::Bool = true, 
    samesite::String = "Lax"
)
    _validate_cookie_name(name)
    _validate_cookie_value(value)
    path = _normalize_path(path)

    parts = ["$name=$value", "Path=$path"]
    
    if !isnothing(domain)
        # The strict validator every other path uses (#329). This one used to reject only a
        # space and `:`, so `domain = "evil.com; Secure"` injected attributes into the header.
        push!(parts, "Domain=$(_normalize_domain(domain))")
    end
    
    # Handle Max-Age=0 and convert to past Expires for better reliability
    if !isnothing(maxage)
        push!(parts, "Max-Age=$maxage")
        if maxage == 0
            # Set expires to epoch
            push!(parts, "Expires=Thu, 01 Jan 1970 00:00:00 GMT")
        end
    end

    if isnothing(maxage) && !isnothing(expires)
        push!(parts, "Expires=$(Dates.format(expires, Dates.RFC1123Format)) GMT")
    end
    
    if httponly
        push!(parts, "HttpOnly")
    end
    
    # SameSite validation
    ss = uppercasefirst(lowercase(strip(samesite)))
    if ss == "None" 
        # SameSite=None cookies must be Secure
        if !secure
            @warn "SameSite=None cookies must also be Secure. Setting Secure=true."
            secure = true
        end
        push!(parts, "SameSite=None")
    elseif ss in ("Lax", "Strict")
        push!(parts, "SameSite=$ss")
    end

    if secure
        push!(parts, "Secure")
    end
    
    return join(parts, "; ")
end

const HOST_COOKIE_PREFIX = "__Host-"
const SECURE_COOKIE_PREFIX = "__Secure-"

"""
Reject a cookie-name prefix the surrounding config would make undeliverable.

Browsers match `__Host-`/`__Secure-` case-insensitively and *silently discard* a cookie that
violates the prefix rules, so a misconfigured pipeline looks healthy and then never sets its
cookie. Failing at construction turns that into an error the developer sees once. Shared by
`CSRFMiddleware` and `SessionMiddleware` (#329); `label` and `plain_name` only shape the message.
"""
function _validate_cookie_prefix(cookie_name::AbstractString, config::CookieConfig;
                                 label::AbstractString = "Cookie",
                                 plain_name::Union{AbstractString, Nothing} = nothing)
    lowered = lowercase(String(cookie_name))
    is_host = startswith(lowered, lowercase(HOST_COOKIE_PREFIX))
    (is_host || startswith(lowered, lowercase(SECURE_COOKIE_PREFIX))) || return nothing
    prefix = is_host ? HOST_COOKIE_PREFIX : SECURE_COOKIE_PREFIX
    unprefixed = isnothing(plain_name) ? "a cookie_name without the prefix" :
                 "a cookie_name without the prefix (e.g. `cookie_name=\"$plain_name\"`)"

    config.secure || throw(ArgumentError(
        "$label \"$cookie_name\" carries the $prefix prefix, which browsers accept only on a " *
        "Secure cookie. Pass `secure=true`, or use $unprefixed when serving over plain HTTP."))

    if is_host
        config.domain === nothing || throw(ArgumentError(
            "$label \"$cookie_name\" carries the $prefix prefix, which browsers accept only " *
            "when no Domain attribute is set (got domain=\"$(config.domain)\")."))
        config.path == "/" || throw(ArgumentError(
            "$label \"$cookie_name\" carries the $prefix prefix, which browsers accept only " *
            "with Path=/ (got path=\"$(config.path)\")."))
    end
    return nothing
end

function format_cookie(name::String, value::String, config::CookieConfig)
    return format_cookie(
        name,
        value;
        path=config.path,
        domain=config.domain,
        expires=config.expires,
        maxage=config.maxage,
        httponly=config.httponly,
        secure=config.secure,
        samesite=config.samesite,
    )
end

# ============================================================================
# SECTION 3: Public API (Get/Set)
# ============================================================================

"""
Internal lazy lookup for a cookie value across all headers.

`set_cookie = false` -- a Request, or a bare header collection -- reads the `Cookie` header(s)
only; `set_cookie = true` -- a Response -- reads `Set-Cookie` only (#329). A `Set-Cookie` on a
REQUEST is not a cookie the client holds, but it used to be read as one, so any client could
supply a "cookie" by sending the wrong header. Names match exactly, as in
`_extract_value_from_header`.
"""
function _get_cookie_lazy(headers::Any, target_name::String; set_cookie::Bool = false) :: Union{SubString{String}, Nothing}
    # A Dict is never a Response's headers, so it is only ever read as a request's.
    if headers isa Dict
        cookie_val = Base.get(headers, "cookie", Base.get(headers, "Cookie", nothing))
        return isnothing(cookie_val) ? nothing : _extract_value_from_header(cookie_val, target_name)
    end

    # Iterate through headers (Vector{Pair} or HTTP.Headers)
    for (k, v) in headers
        kl = lowercase(k)
        res = if !set_cookie && kl == "cookie"
            _extract_value_from_header(v, target_name)
        elseif set_cookie && kl == "set-cookie"
            _set_cookie_value(v, target_name)
        else
            nothing
        end
        !isnothing(res) && return res
    end
    return nothing
end

# The value of one `Set-Cookie` line if it sets `target_name`, else `nothing`.
function _set_cookie_value(line::AbstractString, target_name::String) :: Union{SubString{String}, Nothing}
    semi_idx = findfirst(';', line)
    pair_view = isnothing(semi_idx) ? SubString(line) : @view line[begin:prevind(line, semi_idx)]
    eq_idx = findfirst('=', pair_view)
    isnothing(eq_idx) && return nothing
    name = strip(@view pair_view[begin:prevind(pair_view, eq_idx)])
    name == target_name || return nothing
    val_view = strip(@view(pair_view[nextind(pair_view, eq_idx):end]))
    if length(val_view) >= 2 && val_view[begin] == '"' && val_view[end] == '"'
        return @view val_view[nextind(val_view, begin):prevind(val_view, end)]
    end
    return val_view
end

"""
Get a cookie value by name from a Request or Response.
Supports default values, type parsing, and decryption.

With `encrypted = true` the value must be a token `set_cookie!` sealed under this key **for this
cookie name**. One that does not open — tampered, sealed under another key, copied from another
cookie, expired, or written before the current token format — reads as **absent**: the default
is returned and the rejection is logged at `@debug`, never with the value (#309). Encrypting
with no key at all is still a `CookieError`, since that is configuration rather than a bad cookie.
"""
function get_cookie(
    source::Any, 
    name::Union{String, Symbol},
    default::Any = nothing; 
    encrypted::Bool = false,
    config::CookieConfig = CookieConfig(),
    secret_key::Union{AbstractString, SecretString, Nothing} = nothing,
    max_cookie_size::Union{Int, Nothing} = nothing,
    kwargs...
)
    # Use the positional default unless it's nothing and we have a keyword default
    final_default = haskey(kwargs, :default) ? kwargs[:default] : default

    if isnothing(source)
        return final_default
    end

    # Validated BEFORE the lookup: a bad per-call key is configuration, and must fail on every
    # call rather than only on the ones that happen to carry the cookie.
    final_secret = isnothing(secret_key) ? config.secret_key : _cookie_secret(secret_key)

    target_name = string(name)
    headers = if source isa HTTP.Request || source isa HTTP.Response
        source.headers
    else
        source
    end

    found_value = _get_cookie_lazy(headers, target_name; set_cookie = source isa HTTP.Response)

    if isnothing(found_value)
        return final_default
    end

    raw_value = String(found_value)

    final_max_cookie_size = isnothing(max_cookie_size) ? config.max_cookie_size : max_cookie_size

    # Check size limit
    if !isnothing(final_max_cookie_size) && length(raw_value) > final_max_cookie_size
        return final_default
    end

    # Decrypt if requested
    final_value = if encrypted
        if isnothing(final_secret)
            throw(CookieError("Encrypted cookie access requires a non-empty secret_key"))
        end
        # A token that does not open is a cookie the client should not have -- the same as no
        # cookie, which is what Rails and Plug answer too. It used to throw, so every client
        # carrying a stale or junk cookie turned each request into a 500, and a format change
        # would have done that to every client at once. `purpose` is the NAME: a token sealed
        # for `language` does not open as `session_user`.
        try
            decrypt_payload(final_secret, raw_value; purpose = target_name)
        catch e
            e isa CookieError || rethrow()
            @debug "Nitro: an encrypted cookie did not open; reading it as absent" cookie = target_name reason = e.msg
            return final_default
        end
    else
        raw_value
    end
    
    if isnothing(final_default) || final_default isa String
        return final_value
    end
    
    # Try to parse as the same type as default
    try
        T = typeof(final_default)
        if T == Bool
            lv = lowercase(final_value)
            if lv in ("true", "1", "yes", "on")
                return true
            elseif lv in ("false", "0", "no", "off")
                return false
            else
                return final_default
            end
        elseif T <: Number
            parsed = parse(T, final_value)
            # `parse(Float64, "nan")` succeeds, and `NaN > limit` and `NaN <= limit` are both
            # false; a client-set cookie must not bring one in (#327). Same rule as the default
            # for a value that does not parse.
            parsed isa AbstractFloat && !isfinite(parsed) && return final_default
            return parsed
        else
            return final_value
        end
    catch
        return final_default
    end
end

"""
Set a cookie on an HTTP response.
If secret_key is provided in the config, the value will be encrypted.
"""
function set_cookie!(
    res::HTTP.Response, 
    name::Union{String, Symbol}, 
    value::Any; 
    config::CookieConfig = CookieConfig(),
    attrs::Dict = Dict(),
    path::Nullable{String} = nothing, 
    domain::Nullable{String} = nothing, 
    expires::Union{Nullable{DateTime}, String} = nothing, 
    maxage::Union{Nullable{Int}, String} = nothing, 
    httponly::Nullable{Bool} = nothing, 
    secure::Nullable{Bool} = nothing, 
    samesite::Nullable{String} = nothing,
    encrypted::Nullable{Bool} = nothing,
    secret_key::Union{AbstractString, SecretString, Nothing} = nothing
)
    # `string(value)` below would write a masked secret's DISPLAY form -- `SecretString("****")`
    # -- as the cookie value, the same failure #307 fixed for the key. Refuse rather than guess:
    # a secret in a cookie is a decision the caller should spell with `reveal`.
    value isa Union{SecretString, Base.SecretBuffer} && throw(ArgumentError(
        "set_cookie!: the value for cookie $(repr(string(name))) is a $(typeof(value)), which " *
        "would be written as its masked display form. Pass `reveal(value)` if the secret " *
        "really belongs in a cookie."))

    # 1. Resolve values (Explicit param > Dict > Config Default)
    merged_attrs = Dict{Symbol, Any}()
    
    # helper to set if not nothing
    function set_if_not_nothing(key::Symbol, val)
        if !isnothing(val)
            merged_attrs[key] = val
        end
    end

    # First load from attrs dict
    for (k, v) in attrs
        merged_attrs[_normalize_attribute_name(k)] = v
    end

    # Explicit params override dict
    set_if_not_nothing(:path, path)
    set_if_not_nothing(:domain, domain)
    set_if_not_nothing(:expires, expires)
    set_if_not_nothing(:maxage, maxage)
    set_if_not_nothing(:httponly, httponly)
    set_if_not_nothing(:secure, secure)
    set_if_not_nothing(:samesite, samesite)

    # 2. Normalize and apply defaults from config
    final_path = _normalize_runtime_path(Base.get(merged_attrs, :path, isnothing(config.path) ? "/" : config.path))

    final_domain = nothing
    if haskey(merged_attrs, :domain)
        final_domain = _normalize_domain(merged_attrs[:domain])
    elseif !isnothing(config.domain)
        final_domain = config.domain
    end

    final_maxage = nothing
    final_expires = nothing
    
    # Handle Max-Age and Expires
    ma_input = Base.get(merged_attrs, :maxage, config.maxage)
    if !isnothing(ma_input)
        mv, is_logout, logout_expires = _normalize_maxage(ma_input)
        if is_logout
            final_expires = logout_expires
        end
        final_maxage = mv
    end

    if isnothing(final_expires)
        ex_input = Base.get(merged_attrs, :expires, config.expires)
        if !isnothing(ex_input)
            final_expires = _normalize_expires(ex_input)
        end
    end

    final_httponly = _normalize_bool(Base.get(merged_attrs, :httponly, config.httponly), "httponly")
    final_secure = _normalize_bool(Base.get(merged_attrs, :secure, config.secure), "secure")
    
    ss_input = Base.get(merged_attrs, :samesite, config.samesite)
    final_samesite = isnothing(ss_input) ? "Lax" : _samesite_to_mode(string(ss_input))
    if isnothing(final_samesite)
        final_samesite = "Lax" # fallback
    end
    
    # 3. Handle Encryption
    final_secret = isnothing(secret_key) ? config.secret_key : _cookie_secret(secret_key)
    is_encrypted = isnothing(encrypted) ? !isnothing(final_secret) : encrypted
    str_value = string(value)

    final_value = if is_encrypted
        if isnothing(final_secret)
            throw(CookieError("Encrypted cookie writes require a non-empty secret_key"))
        end
        # The token carries the lifetime the browser is told, so the server enforces it too
        # (#309): `Max-Age` alone is a hint, and a captured cookie used to decrypt forever.
        # Max-Age wins over Expires, as it does in the browser. A cookie with neither has no
        # server-side expiry -- set `maxage` (per cookie, or in `configcookies`) to bound it.
        issued = Dates.now(Dates.UTC)
        sealed_until = if !isnothing(final_maxage)
            issued + Dates.Second(final_maxage)
        elseif final_expires isa DateTime
            final_expires
        else
            nothing
        end
        encrypt_payload(final_secret, str_value; purpose = string(name), expires = sealed_until,
                        now = issued)
    else
        str_value
    end
    
    cookie_str = format_cookie(
        string(name), 
        final_value; 
        path=final_path, 
        domain=final_domain, 
        expires=final_expires isa DateTime ? final_expires : nothing, 
        maxage=final_maxage, 
        httponly=final_httponly, 
        secure=final_secure, 
        samesite=final_samesite
    )
    
    if length(cookie_str) > 4096
        @warn "Set-Cookie header for '$name' exceeds 4096 bytes. Some browsers may reject it."
    end
    
    # CORRECT WAY: Appending to the headers vector directly
    # HTTP.setheader would replace all existing Set-Cookie headers, which is wrong for multiple cookies.
    push!(res.headers, "Set-Cookie" => cookie_str)
    return res
end

"""
Load cookie settings from a dictionary into a CookieConfig object.
Performs normalization and validation.
"""
function load_cookie_settings!(defaults::Nullable{Dict} = nothing)
    if isnothing(defaults)
        return CookieConfig()
    end
    
    optimized_defaults = Dict{Symbol, Any}()
    errors = String[]

    for (k, v) in defaults
        attr_key = _normalize_attribute_name(k)
        
        try
            if attr_key == :maxage
                mv, is_logout, logout_expires = _normalize_maxage(v)
                if !is_logout
                    optimized_defaults[attr_key] = mv
                end
            elseif attr_key in (:httponly, :secure)
                optimized_defaults[attr_key] = _normalize_bool(v, string(attr_key))
            elseif attr_key == :samesite
                if v isa String
                    mode = _samesite_to_mode(v)
                    if isnothing(mode)
                        push!(errors, "Invalid SameSite mode: $v")
                    else
                        optimized_defaults[attr_key] = mode
                    end
                else
                    optimized_defaults[attr_key] = v
                end
            elseif attr_key == :path
                optimized_defaults[attr_key] = _normalize_path(v)
            elseif attr_key == :domain
                optimized_defaults[attr_key] = _normalize_domain(v)
            elseif attr_key == :expires
                optimized_defaults[attr_key] = _normalize_expires(v)
            elseif attr_key == :secret_key
                # Never `string(v)`: on a `SecretString` that is its masked `show` (#307).
                optimized_defaults[attr_key] = _cookie_secret(v)
            elseif attr_key == :max_cookie_size
                optimized_defaults[attr_key] = v isa String ? parse(Int, v) : Int(v)
            else
                push!(errors, "Unknown attribute: $k")
            end
        catch e
            push!(errors, e isa ArgumentError ? e.msg : string(e))
        end
    end
    
    if !isempty(errors)
        throw(ArgumentError(join(errors, "\n")))
    end
    
    return CookieConfig(; optimized_defaults...)
end

"""
Add a session to a store with a time-to-live (TTL).

Custom stores can satisfy this by implementing `set_session!`.
"""
function storesession!(store::AbstractSessionStore, key, value; ttl::Int = 3600)
    return set_session!(store, key, value; ttl)
end

"""
Add a session to a MemoryStore with a time-to-live (TTL).
"""
function storesession!(store::MemoryStore{K, V}, key::K, value::V; ttl::Int = 3600) where {K, V}
    return set_session!(store, key, value; ttl)
end

"""
Remove expired sessions from a store.

Delegates to `cleanup_expired_sessions!`, which is an optional part of the
`AbstractSessionStore` contract and defaults to a no-op — so a store that does not
support background cleanup needs nothing here.

This runs **off** the request path (#36). `SessionMiddleware` and `SessionPruner` call it
from a background janitor tied to server startup/shutdown; it used to run inline on a
`prune_probability` fraction of requests, which made ~1 request in 100 pay a full O(N)
store scan — under `MemoryStore`'s single lock, blocking every concurrent session read
and write for the duration.

This used to wrap the call in a `try`/`catch` that swallowed any `MethodError` whose
`.f` was `cleanup_expired_sessions!`, which is how the optionality was expressed before
the default existed. That rescue also swallowed a *genuine* `MethodError` raised inside a
conforming store's own cleanup body, turning a real bug into a silent no-op. Errors from a
store that does implement cleanup now propagate.
"""
function prunesessions!(store::AbstractSessionStore)
    return cleanup_expired_sessions!(store)
end

"""
    regenerate_session!(req::HTTP.Request, store::AbstractSessionStore{String, Dict{String,Any}}; ttl::Int=3600) -> Union{String, Nothing}

Regenerate the session ID to prevent session-fixation attacks.

Moves the current session data to a new session ID with the store's atomic
[`rotate_session!`](@ref), which also removes the old one, and updates
`req.context[:session_id]` so that `SessionMiddleware` writes the new cookie on the response.
Works with any `AbstractSessionStore` backend.

Returns the new session ID, or **`nothing` when the session was logged out while this request
was running** (#361). A concurrent request deleted it, so there is nothing to rotate: the context
keeps the old id, `SessionMiddleware` drops this request's write, and no cookie is set. Rotating
anyway used to copy the logged-out session, identity included, into a fresh id.

A session `SessionMiddleware` created during this request has never been stored or sent to the
client, so it gets a new ID with no store operation; the middleware saves it on the way out.
"""
function regenerate_session!(req::HTTP.Request, store::AbstractSessionStore{String, Dict{String,Any}}; ttl::Int=3600)
    old_id = get(req.context, :session_id, nothing)
    session_data = get(req.context, :session, Dict{String,Any}())

    new_id = string(secure_uuid4())

    if isnothing(old_id)
        # No session at all, so none that a logout could have deleted: create one.
        set_session!(store, new_id, session_data; ttl=ttl)
    elseif get(req.context, :session_new, false) !== true
        # A session this request LOADED. Move it only if it is still there (#361).
        rotate_session!(store, old_id, new_id, session_data; ttl=ttl) || return nothing
    end
    # Otherwise the id was minted by `SessionMiddleware` in this request: never stored, never
    # sent, so no other request can hold it. Asking the store to move it would find nothing and
    # read as a logout, so a first-time visitor's login would never rotate.

    # Update the request context so middleware writes the new cookie
    req.context[:session_id] = new_id

    return new_id
end

end
