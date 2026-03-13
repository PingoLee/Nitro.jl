module CSRFMiddleware_

using HTTP
using SHA
using Random
using Base64

using ...Types: CookieConfig, Nullable
using ...Cookies: get_cookie, set_cookie!

export CSRFMiddleware, issue_csrf_token!, validate_csrf_token

const SAFE_METHODS = Set(("GET", "HEAD", "OPTIONS", "TRACE"))

function _base64url_encode(data::Vector{UInt8})
    encoded = Base64.base64encode(data)
    encoded = replace(encoded, '+' => '-', '/' => '_')
    return replace(encoded, '=' => "")
end

function _csrf_signature(secret::String, token::AbstractString)
    signature = SHA.hmac_sha256(Vector{UInt8}(codeunits(secret)), Vector{UInt8}(codeunits(String(token))))
    return _base64url_encode(signature)
end

function _generate_raw_token()
    return _base64url_encode(rand(UInt8, 32))
end

function _signed_token(secret::String, raw_token::String)
    return string(raw_token, ".", _csrf_signature(secret, raw_token))
end

function _parse_signed_token(value::AbstractString)
    parts = split(String(value), '.', limit=2)
    length(parts) == 2 || return nothing, nothing
    return parts[1], parts[2]
end

function issue_csrf_token!(res::HTTP.Response, secret::String; cookie_name::String="csrf_token", ttl::Int=3600, config::CookieConfig=CookieConfig(httponly=false, secure=true, samesite="Lax", path="/", maxage=ttl))
    raw_token = _generate_raw_token()
    set_cookie!(res, cookie_name, _signed_token(secret, raw_token); config=config, encrypted=false, maxage=ttl)
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

function validate_csrf_token(req::HTTP.Request, secret::String; cookie_name::String="csrf_token", header_name::String="X-CSRF-Token", form_field::String="_csrf")
    cookie_value = get_cookie(req, cookie_name, nothing; encrypted=false)
    cookie_value === nothing && return false

    raw_token, signature = _parse_signed_token(cookie_value)
    raw_token === nothing && return false
    signature == _csrf_signature(secret, raw_token) || return false

    presented = _presented_token(req, header_name, form_field)
    presented === nothing && return false
    return presented == raw_token || presented == cookie_value
end

function CSRFMiddleware(secret::String; cookie_name::String="csrf_token", header_name::String="X-CSRF-Token", form_field::String="_csrf", ttl::Int=3600, config::CookieConfig=CookieConfig(httponly=false, secure=true, samesite="Lax", path="/", maxage=ttl))
    return function(handle::Function)
        return function(req::HTTP.Request)
            method = uppercase(String(req.method))
            existing_cookie = get_cookie(req, cookie_name, nothing; encrypted=false)

            if !(method in SAFE_METHODS)
                validate_csrf_token(req, secret; cookie_name, header_name, form_field) || return HTTP.Response(403, ["Content-Type" => "application/json"], codeunits("{\"error\":\"Invalid CSRF token\"}"))
            else
                raw_token, _ = existing_cookie === nothing ? (nothing, nothing) : _parse_signed_token(existing_cookie)
                req.context[:csrf_token] = raw_token
            end

            response = handle(req)
            if method in SAFE_METHODS && existing_cookie === nothing
                raw_token = issue_csrf_token!(response, secret; cookie_name, ttl, config)
                req.context[:csrf_token] = raw_token
            end
            return response
        end
    end
end

end