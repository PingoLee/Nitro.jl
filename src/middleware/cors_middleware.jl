module CORSMiddleware

using HTTP
using ...Types

export Cors

# Returns the request path with any query string stripped, e.g.
# "/api/import?x=1" -> "/api/import".
function _request_path(req::HTTP.Request)
    target = req.target
    q = findfirst('?', target)
    return isnothing(q) ? target : target[1:prevind(target, q)]
end

# Builds the predicate that decides whether CORS applies to a given request path.
#   nothing          -> every path (default, backwards compatible)
#   Vector{String}   -> exact-match allow-list
#   Function         -> custom predicate (path::AbstractString) -> Bool
_cors_path_predicate(::Nothing) = Returns(true)
_cors_path_predicate(pred::Function) = pred
function _cors_path_predicate(allowed::Vector{String})
    allowset = Set(allowed)
    return path -> path in allowset
end

"""
    Cors(; allowed_origins=["*"], allowed_headers=["*"], allowed_methods=["GET","POST","OPTIONS"], allow_credentials=false, max_age=nothing, extra_headers=Pair[], paths=nothing)

Creates a middleware function that adds CORS headers to responses and handles preflight OPTIONS requests.

Per the CORS specification, `Access-Control-Allow-Origin` must be either the
literal `*` or a **single origin** that matches the request's `Origin` header.
When multiple origins are configured, this middleware checks the incoming
`Origin` against the allowed set and echoes it back if it matches.  A `Vary:
Origin` header is added so that caches do not serve a response keyed to one
origin for a different one.

When `allow_credentials=true`, a wildcard origin (`*`) is rejected at
construction time with an `ArgumentError`: browsers forbid credentialed
requests against `Access-Control-Allow-Origin: *`, and reflecting an arbitrary
Origin alongside credentials would expose responses to any website. Specify the
explicit origins you trust in `allowed_origins` instead.

# Keyword Arguments

    - `allowed_origins`: Vector of allowed origins (default: ["*"]).
    - `allowed_headers`: Vector of allowed headers (default: ["*"]).
    - `allowed_methods`: Vector of allowed methods (default: ["GET","POST","OPTIONS"]).
    - `allow_credentials`: If true, adds `Access-Control-Allow-Credentials: true`.
    - `max_age`: If set, adds `Access-Control-Max-Age` header.
    - `extra_headers`: Vector of additional key-value pairs.
    - `paths`: Restrict CORS to a subset of request paths. Defaults to `nothing`
      (apply to every request). Pass a `Vector{String}` for an exact-match
      allow-list, or a predicate `(path::AbstractString) -> Bool` for custom
      matching (e.g. prefix matching). Requests whose path is not in scope pass
      straight through with no CORS headers and no preflight short-circuit. This
      is useful when `Cors` is installed as a global server middleware but only
      a handful of endpoints are meant to be cross-origin.

      Paths are matched against the **route path** — the same string you pass to
      `path()` — *after* any global `prefix` (from `serve(prefix=...)`) has been
      stripped. So when serving under `prefix="/v1"`, a client request to
      `/v1/api/import` is matched here as `/api/import`. List your route paths,
      not the full client URL.

# Returns
A middleware closure compatible with the Nitro middleware pipeline.

# Examples

```julia
# Only these two endpoints get CORS, even when installed globally
Cors(allowed_origins=["https://app.example.com"], allow_credentials=true,
     paths=["/api/import/data", "/api/apsaude/fix"])

# Prefix matching via a predicate
Cors(paths = path -> startswith(path, "/api/"))

# Under a global prefix, list the ROUTE path (the prefix is already stripped):
#   serve(prefix="/v1", middleware=[Cors(paths=["/api/import"])])
# matches client requests to /v1/api/import
```
"""
function Cors(;
    allowed_origins     :: Vector{String} = ["*"],
    allowed_headers     :: Vector{String} = ["*"],
    allowed_methods     :: Vector{String} = ["GET","POST","OPTIONS"],
    allow_credentials   :: Bool = false,
    max_age             :: Union{Int,Nothing} = nothing,
    extra_headers       :: Vector{Pair{String, String}} = Pair{String,String}[],
    paths               :: Union{Nothing, Vector{String}, Function} = nothing)

    applies = _cors_path_predicate(paths)

    format_header(xs::Vector{String}) = ("*" in xs) ? "*" : join(xs, ", ")

    # Determine whether the origin header can be a static value or must be
    # resolved per-request.  The spec only allows a single origin (or "*")
    # in the header value, and "*" is forbidden when credentials are enabled.
    is_wildcard    = "*" in allowed_origins
    is_single      = !is_wildcard && length(allowed_origins) == 1
    needs_dynamic  = !is_wildcard && !is_single
    origin_set     = Set(allowed_origins)

    # Security: a wildcard origin combined with credentials is forbidden. The
    # only way to satisfy it is to reflect the request's Origin back together
    # with `Access-Control-Allow-Credentials: true`, which lets ANY site make
    # credentialed cross-origin requests and read the responses. Reject it at
    # construction time so the misconfiguration can't ship.
    if allow_credentials && is_wildcard
        throw(ArgumentError(
            "CORS misconfiguration: allow_credentials=true cannot be combined with a " *
            "wildcard origin (\"*\"). Browsers forbid credentialed requests against " *
            "`Access-Control-Allow-Origin: *`, and reflecting an arbitrary Origin with " *
            "credentials exposes responses to any website. List the explicit origins you " *
            "trust in `allowed_origins` instead."
        ))
    end

    # Pre-build the headers that are the same for every response.
    static_headers :: Vector{Pair{String, String}} = [
        "Access-Control-Allow-Headers" => format_header(allowed_headers),
        "Access-Control-Allow-Methods" => format_header(allowed_methods),
    ]

    append!(static_headers, extra_headers)

    if allow_credentials
        push!(static_headers, "Access-Control-Allow-Credentials" => "true")
    end

    if max_age !== nothing
        push!(static_headers, "Access-Control-Max-Age" => string(max_age))
    end

    # Fast path: single allowed origin OR wildcard without credentials.
    # The origin header value never changes, so we can freeze it once.
    if !needs_dynamic
        origin_value = is_wildcard ? "*" : allowed_origins[1]
        frozen_headers = vcat(["Access-Control-Allow-Origin" => origin_value], static_headers)

        # Add Vary: Origin when the response is origin-specific (not "*").
        if !is_wildcard
            push!(frozen_headers, "Vary" => "Origin")
        end

        return function(handle::Function)
            return function(req::HTTP.Request)
                applies(_request_path(req)) || return handle(req)
                if req.method == "OPTIONS"
                    return HTTP.Response(200, frozen_headers)
                end
                response = handle(req)
                append!(response.headers, frozen_headers)
                return response
            end
        end
    end

    # Dynamic path: multiple explicit origins. Echo the request's Origin back
    # only when it is in the allow-list; otherwise omit Allow-Origin so the
    # browser blocks the response cleanly.
    return function(handle::Function)
        return function(req::HTTP.Request)
            applies(_request_path(req)) || return handle(req)
            request_origin = HTTP.header(req, "Origin", "")
            headers = copy(static_headers)

            if request_origin in origin_set
                push!(headers, "Access-Control-Allow-Origin" => request_origin)
            end

            push!(headers, "Vary" => "Origin")

            if req.method == "OPTIONS"
                return HTTP.Response(200, headers)
            end
            response = handle(req)
            append!(response.headers, headers)
            return response
        end
    end
end

end
