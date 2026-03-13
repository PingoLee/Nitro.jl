const DEFAULT_AUTH_COOKIE_NAME = "auth_token"
const DEFAULT_AUTH_COOKIE_TTL = 24 * 60 * 60

function extract_auth_token(req::HTTP.Request; header::String="Authorization", scheme::String="Bearer", cookie_name::Union{String, Nothing}=DEFAULT_AUTH_COOKIE_NAME)
    auth_header = HTTP.header(req, header, "")
    full_scheme = string(scheme, " ")
    if startswith(auth_header, full_scheme)
        token = strip(SubString(auth_header, length(full_scheme) + 1:lastindex(auth_header)))
        isempty(token) || return String(token)
    end

    if cookie_name !== nothing
        token = get_cookie(req, cookie_name, nothing; encrypted=false)
        if !(token === nothing || token === missing || isempty(token))
            return String(token)
        end
    end

    return nothing
end

function set_auth_cookie!(res::HTTP.Response, token::AbstractString; cookie_name::String=DEFAULT_AUTH_COOKIE_NAME, ttl::Int=DEFAULT_AUTH_COOKIE_TTL, secure::Bool=true, httponly::Bool=true, samesite::String="Lax", path::String="/", domain=nothing)
    config = CookieConfig(secure=secure, httponly=httponly, samesite=samesite, path=path, domain=domain, maxage=ttl)
    set_cookie!(res, cookie_name, token; config=config, encrypted=false, maxage=ttl)
    return res
end

function clear_auth_cookie!(res::HTTP.Response; cookie_name::String=DEFAULT_AUTH_COOKIE_NAME, secure::Bool=true, httponly::Bool=true, samesite::String="Lax", path::String="/", domain=nothing)
    config = CookieConfig(secure=secure, httponly=httponly, samesite=samesite, path=path, domain=domain)
    set_cookie!(res, cookie_name, ""; config=config, encrypted=false, maxage=0)
    return res
end