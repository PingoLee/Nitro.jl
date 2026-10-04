module CrossOriginProtectionMiddleware

using HTTP

using ...Types: _parse_origin
using ...Res: json
using ...Core: header_name_isequal
using ...Util: _ows_strip
using ..CSRFMiddleware_: SAFE_METHODS
using ..RateLimiterMiddleware: _is_exempt

export CrossOriginProtection

"""
    CrossOriginProtection(; trusted_origins = String[], exempt_paths = String[])

Tokenless CSRF protection from the browser's own Fetch Metadata (#437): an unsafe request
(anything but `GET`, `HEAD`, `OPTIONS`, `TRACE`) that a browser sent from another origin is
refused with `403`. No token, no cookie and no session are involved, so nothing has to be minted,
stored, embedded in a form or fetched by a single-page app. This is Go 1.25's
`net/http.CrossOriginProtection`, check for check.

For each unsafe request, in order:

1. **`Sec-Fetch-Site`**, which every current browser sends on every request to an HTTPS (or
   localhost) URL, and which no page can set: `same-origin` or `none` (the user typed the URL, or
   used a bookmark) passes. Any other value, `cross-site` or `same-site`, is refused unless step 4
   exempts it.
2. **No `Sec-Fetch-Site`** (an older browser, or any browser over plain HTTP): the `Origin`
   header's host and port must equal the request's `Host`, or the request is refused unless step
   4 exempts it. The scheme is not compared, as in Go, so a proxy that terminates TLS needs no
   configuration.
3. **Neither header**: the request passes. It did not come from a browser, so it carries no
   cookie a browser attached on its own, which is the only thing CSRF borrows.
4. **Exemptions**: an `Origin` listed in `trusted_origins`, or a path in `exempt_paths`, passes.

```julia
serve(middleware = [
    CrossOriginProtection(trusted_origins = ["https://app.example.com"]),
    SessionMiddleware(store = store),
])
```

It composes with [`CSRFMiddleware`](@ref Nitro.Core.Middleware.CSRFMiddleware_.CSRFMiddleware):
keep both for defence in depth, or use this one alone and drop the tokens. It checks requests
only. It does not answer CORS preflights; that is [`Cors`](@ref Nitro.Core.Middleware.CORSMiddleware.Cors).

# Keywords

- `trusted_origins`: pages on other origins allowed to send unsafe requests, such as a
  single-page app on `https://app.example.com` calling an API on `https://api.example.com`.
  Each entry is an origin exactly as a browser sends it, with matching exact on scheme, host and
  port. A malformed entry is an `ArgumentError`, with the same rules as
  [`WebSocketOrigins`](@ref Nitro.Core.Middleware.WebSocketOriginsMiddleware.WebSocketOrigins).
- `exempt_paths`: paths never checked, such as a webhook that a third party POSTs to. Each entry
  covers whole path segments, as `exempt_paths` does for the rate limiters: `"/hooks"` exempts
  `/hooks` and `/hooks/github`, not `/hooksadmin`. Write entries in canonical percent-encoding,
  each starting with `/`.

# Behind a reverse proxy

The `Origin` fallback compares against the `Host` header, never `X-Forwarded-Host`, so the proxy
must pass the client's `Host` through (nginx: `proxy_set_header Host \$host;`). Over HTTPS a
current browser sends `Sec-Fetch-Site` and is not affected by `Host`. Browsers send it only to
HTTPS and localhost, though, so on a plain-HTTP site the `Host` rule applies to every browser.
"""
function CrossOriginProtection(; trusted_origins::AbstractVector{<:AbstractString} = String[],
                                 exempt_paths::AbstractVector{<:AbstractString} = String[])
    trusted = _trusted_origins(trusted_origins)
    exempt = _exempt_paths(exempt_paths)
    return function (handle::Function)
        return function (req::HTTP.Request)
            _allowed(req, trusted, exempt) && return handle(req)
            return json(Dict("error" => "Cross-origin request refused"); status = 403)
        end
    end
end

function _trusted_origins(origins::AbstractVector{<:AbstractString})::Set{String}
    canonical = Set{String}()
    for origin in origins
        parsed, problem = _parse_origin(origin)
        parsed === nothing && throw(ArgumentError(
            "CrossOriginProtection: $(repr(String(origin))) is not an origin: $problem. An origin is " *
            "exactly what a browser sends in `Origin`: `https://app.example.com`, or " *
            "`https://app.example.com:8443` on a non-default port."))
        push!(canonical, parsed)
    end
    return canonical
end

function _exempt_paths(paths::AbstractVector{<:AbstractString})::Vector{String}
    for p in paths
        startswith(p, '/') || throw(ArgumentError(
            "CrossOriginProtection: exempt path $(repr(String(p))) must start with `/`; it is matched " *
            "against the request path, which always does."))
    end
    return String[String(p) for p in paths]
end

# Go's `CrossOriginProtection.Check`, in the same order. Header values are bytes a client chose,
# possibly malformed UTF-8: they are compared byte-for-byte or through `_parse_origin`, which
# refuses non-ASCII before it case-folds anything, never through `lowercase`.
function _allowed(req::HTTP.Request, trusted::Set{String}, exempt::Vector{String})::Bool
    uppercase(String(req.method)) in SAFE_METHODS && return true
    fetch_site = _single_header(req, "Sec-Fetch-Site")
    if fetch_site !== nothing && !isempty(fetch_site)
        (fetch_site == "same-origin" || fetch_site == "none") && return true
    else
        origin = _single_header(req, "Origin")
        (origin === nothing || isempty(origin)) && return true
        _same_host(origin, _single_header(req, "Host")) && return true
    end
    return _exempt(req, trusted, exempt)
end

function _exempt(req::HTTP.Request, trusted::Set{String}, exempt::Vector{String})::Bool
    if !isempty(trusted)
        origin = _single_header(req, "Origin")
        if origin !== nothing
            canonical = first(_parse_origin(origin))
            canonical !== nothing && canonical in trusted && return true
        end
    end
    return !isempty(exempt) && _is_exempt(req.target, exempt)
end

# The `Origin` header's host and port against `Host`. `Host` is read under the Origin's own
# scheme, so a missing port means that scheme's default on both sides, and both go through the one
# strict parser: case-folded, IPv6-normalized, and a malformed or non-ASCII value is never equal
# to anything. The scheme itself cancels out -- Go compares hosts only.
function _same_host(origin::String, host::Union{Nothing, String})::Bool
    host === nothing && return false
    parsed = first(_parse_origin(origin))
    parsed === nothing && return false
    scheme = parsed[1:first(findfirst("://", parsed))-1]
    return first(_parse_origin(string(scheme, "://", host))) == parsed
end

# A header that appears more than once becomes one value joined with `,`: HTTP.jl folds ADJACENT
# duplicates that way itself, and this joins non-adjacent ones. No such value matches anything
# allowed, so a duplicated `Sec-Fetch-Site` or `Origin` fails closed. `nothing` when absent; OWS
# trimmed otherwise.
function _single_header(req::HTTP.Request, name::String)::Union{Nothing, String}
    value = nothing
    for (k, v) in req.headers
        # Safe to case-fold: HTTP.jl refuses a field name that is not a token on the wire.
        header_name_isequal(k, name) || continue
        value === nothing || return string(value, ",", _ows_strip(v))
        value = String(_ows_strip(v))
    end
    return value
end

end
