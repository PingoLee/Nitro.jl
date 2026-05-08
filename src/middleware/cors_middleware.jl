module CORSMiddleware

using HTTP
using ...Types

export Cors

"""
    Cors(; allowed_origins=["*"], allowed_headers=["*"], allowed_methods=["GET","POST","OPTIONS"], allow_credentials=false, max_age=nothing, extra_headers=Pair[])

Creates a middleware function that adds CORS headers to responses and handles preflight OPTIONS requests.

Per the CORS specification, `Access-Control-Allow-Origin` must be either the
literal `*` or a **single origin** that matches the request's `Origin` header.
When multiple origins are configured, this middleware checks the incoming
`Origin` against the allowed set and echoes it back if it matches.  A `Vary:
Origin` header is added so that caches do not serve a response keyed to one
origin for a different one.

When `allow_credentials=true`, the wildcard `*` is not permitted by browsers,
so the middleware always falls back to per-request origin matching in that case.

# Keyword Arguments

    - `allowed_origins`: Vector of allowed origins (default: ["*"]).
    - `allowed_headers`: Vector of allowed headers (default: ["*"]).
    - `allowed_methods`: Vector of allowed methods (default: ["GET","POST","OPTIONS"]).
    - `allow_credentials`: If true, adds `Access-Control-Allow-Credentials: true`.
    - `max_age`: If set, adds `Access-Control-Max-Age` header.
    - `extra_headers`: Vector of additional key-value pairs.

# Returns
A middleware closure compatible with the Nitro middleware pipeline.
"""
function Cors(;
    allowed_origins     :: Vector{String} = ["*"],
    allowed_headers     :: Vector{String} = ["*"],
    allowed_methods     :: Vector{String} = ["GET","POST","OPTIONS"],
    allow_credentials   :: Bool = false,
    max_age             :: Union{Int,Nothing} = nothing,
    extra_headers       :: Vector{Pair{String, String}} = Pair{String,String}[])

    format_header(xs::Vector{String}) = ("*" in xs) ? "*" : join(xs, ", ")

    # Determine whether the origin header can be a static value or must be
    # resolved per-request.  The spec only allows a single origin (or "*")
    # in the header value, and "*" is forbidden when credentials are enabled.
    is_wildcard    = "*" in allowed_origins
    is_single      = !is_wildcard && length(allowed_origins) == 1
    needs_dynamic  = !is_wildcard && !is_single
    origin_set     = Set(allowed_origins)

    # When credentials are enabled the browser rejects "*", so we must
    # always resolve against the request even for a single-origin list.
    force_dynamic  = allow_credentials && is_wildcard

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
    if !needs_dynamic && !force_dynamic
        origin_value = is_wildcard ? "*" : allowed_origins[1]
        frozen_headers = vcat(["Access-Control-Allow-Origin" => origin_value], static_headers)

        # Add Vary: Origin when the response is origin-specific (not "*").
        if !is_wildcard
            push!(frozen_headers, "Vary" => "Origin")
        end

        return function(handle::Function)
            return function(req::HTTP.Request)
                if HTTP.method(req) == "OPTIONS"
                    return HTTP.Response(200, frozen_headers)
                end
                response = handle(req)
                append!(response.headers, frozen_headers)
                return response
            end
        end
    end

    # Dynamic path: multiple origins, or wildcard + credentials.
    # Resolve the correct origin on every request.
    return function(handle::Function)
        return function(req::HTTP.Request)
            request_origin = HTTP.header(req, "Origin", "")
            headers = copy(static_headers)

            if force_dynamic
                # Credentials + wildcard: echo any origin back.
                if !isempty(request_origin)
                    push!(headers, "Access-Control-Allow-Origin" => request_origin)
                else
                    push!(headers, "Access-Control-Allow-Origin" => "*")
                end
            elseif request_origin in origin_set
                push!(headers, "Access-Control-Allow-Origin" => request_origin)
            else
                # Origin not in allowed list — still attach headers without
                # Allow-Origin so the browser blocks the response cleanly.
            end

            push!(headers, "Vary" => "Origin")

            if HTTP.method(req) == "OPTIONS"
                return HTTP.Response(200, headers)
            end
            response = handle(req)
            append!(response.headers, headers)
            return response
        end
    end
end

end
