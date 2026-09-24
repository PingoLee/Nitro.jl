using HTTP 
using JSON
using Dates

using ..Errors: ValidationError, UnsupportedMediaTypeError, is_unrecoverable
using .BodyParsers: _parse_json_bounded

export recursive_merge, parseparam, parseparam_checked,
    handlerequest,
    format_response, header_name_isequal,
    join_url_path,
    own_response_headers, add_response_headers

### Request helper functions ###


function handle_error(::ValidationError)
    return Res.json(("message" => "400: Bad Request"), status = 400)
end

function handle_error(::UnsupportedMediaTypeError)
    return Res.json(("message" => "415: Unsupported Media Type"), status = 415)
end

function handle_error(::Any)
    return Res.json(("message" => "500: Internal Server Error"), status = 500)    
end

function handlerequest(getresponse::Function, catch_errors::Bool; show_errors::Bool = true)
    if !catch_errors
        return getresponse()
    else
        try
            return getresponse()
        catch error
            if error isa ValidationError
                # A rejected request is client input, not a server fault: never emit a
                # backtrace. The old `@error` wrote one stack trace per malformed request,
                # so a spray of bad URLs was a log-flood / disk-fill vector. `@debug` is
                # compiled out at the default log level, so this costs nothing in
                # production.
                #
                # `.msg` — and ONLY `.msg` — is safe to log as of #72: every
                # `ValidationError` Nitro raises names the parameter, its source, and the
                # expected type or the rejecting validator, never the submitted value.
                # `try_validate` used to interpolate up to 300 characters of the
                # deserialized payload, which put a submitted password on this line for a
                # `Json{Login}` rejection; it no longer does. Keep that invariant when
                # adding a `ValidationError` — `test/util_tests.jl` and
                # `test/extractor_tests.jl` pin it.
                #
                # `.cause` is still attached -- by `safe_extract` (src/extractors.jl),
                # `parseparam_checked` below, and both `Types.*` decode accessors -- and it
                # still carries client input verbatim: a JSON parse `ArgumentError` quotes
                # the offending bytes. As of #130 it no longer *renders* on any of Nitro's
                # three output paths: `showerror` prints `.msg` only unless a caller passes
                # `cause=true`, and `show` and `JSON.lower` mask the cause down to its type
                # name. So neither `exception=error` nor `sprint(showerror, error)` can leak
                # here any more, whatever the log sink does with the value.
                #
                # Keep the line as `message=error.msg` anyway. `exception=error` would carry
                # nothing this does not -- it renders the same `.msg` behind a prefix, as a
                # blob a log sink cannot index -- and it sits one careless edit away from
                # `exception=(error, catch_backtrace())`: the per-request stack trace #18
                # removed as a log-flood / disk-fill vector. `.msg` is also pinned value-free
                # by tests directly, where the renderer's safety is only transitive; two
                # independent guarantees cost nothing to keep separate.
                show_errors && @debug "Request rejected (400 Bad Request)" message=error.msg
            elseif error isa UnsupportedMediaTypeError
                # Client input too, so the same treatment: no backtrace. `.msg` names the
                # parameter and the type it needs, never the Content-Type the client sent (#327).
                show_errors && @debug "Request rejected (415 Unsupported Media Type)" message=error.msg
            elseif show_errors && !isa(error, InterruptException)
                @error "ERROR: " exception=(error, catch_backtrace())
            end
            return handle_error(error)
        end
    end
end


# https://discourse.julialang.org/t/multi-layer-dict-merge/27261/7
recursive_merge(x::AbstractDict...) = merge(recursive_merge, x...)
recursive_merge(x...) = x[end]

function recursive_merge(x::AbstractVector...)
    elements = Dict()
    parameters = []
    flattened = cat(x...; dims=1)

    for item in flattened
        if !(item isa Dict) || !haskey(item, "name")
            continue
        end
        if haskey(elements, item["name"])
            elements[item["name"]] = recursive_merge(elements[item["name"]], item)
        else 
            elements[item["name"]] = item
            if !(item["name"] in parameters)
                push!(parameters, item["name"])
            end
        end
    end
    
    if !isempty(parameters)
        return [ elements[name] for name in parameters ]
    # Fix: When returning a vector of primitive values simply prefer 
    # the final entry over the earlier (instead of combining) which makes 
    # no sense for items like `required`
    else
        return x[end]
    end
end 

"""
    Scalar Parameter Parsing functions

**These convert; they never percent-decode.** Decoding happens exactly once, upstream, in the
`Types.*` accessor that turns the raw request into a map (`Types.pathparams` unescapes, because
HTTP.jl hands over raw segments; `Types.queryvars` does not, because `HTTP.queryparams` already
did). Every value reaching `parseparam` is therefore already decoded.

This used to carry an `escape=true` keyword, which made the *converter* decide. That default was
correct for path params and wrong for query params — the same decode ran twice and any query
value containing `%` was silently mangled (#70). The knob is gone rather than re-defaulted: a
converter is the wrong place to know how its input was transported, which is why Django's path
converters, Spring's `ConversionService`, and axum's `serde` layer are all decode-free too.
"""

function parseparam(::Type{Any}, str::String)
    return str
end

function parseparam(::Type{String}, str::String)
    return str
end

function parseparam(::Type{Char}, str::String)
    return first(str)
end

# Upper bound on the length of a URL-supplied pattern compiled into a `Regex`
# path parameter. Compiling (and later matching) an attacker-controlled regex is
# a ReDoS vector; legitimate route patterns are short, so cap the input.
const MAX_REGEX_PARAM_LENGTH = 256

function parseparam(::Type{Regex}, str::String)
    if ncodeunits(str) > MAX_REGEX_PARAM_LENGTH
        throw(ValidationError("Regex path parameter exceeds maximum length of $MAX_REGEX_PARAM_LENGTH bytes"))
    end
    return Regex(str)
end


# There is deliberately no `parseparam(::Type{Symbol}, …)`. It was `Symbol(str)`, which interned
# every value a client sent, and Julia never frees an interned `Symbol` (#306). A `Symbol`
# parameter is refused at route registration; one reached any other way falls through to the
# JSON fallback below, whose read style refuses it too.

# An enum binds by its integer value or by its name. The name is matched against the members'
# own names (`BodyParsers.enum_from_string`), never looked up as `Symbol(str)`: that would intern
# every string a client sends, and Julia never frees an interned `Symbol` (#306).
function parseparam(::Type{T}, str::String) where {T <: Enum}
    n = tryparse(Int, str)
    return isnothing(n) ? BodyParsers.enum_from_string(T, str) : T(n)
end

"""
Parse `str` as the first member type of `type` that accepts it.

`Nothing` and `Missing` are never parse targets. `JSON.parse(str, Nothing)` succeeds for *any*
valid JSON document (likewise `Missing`), and `Base.uniontypes` places them first, so trying them
made every `Nullable{T}` parameter bind to `nothing` and silently discard the client's value —
`parseparam(Union{Nothing,Int}, "5")` returned `nothing`. An *absent* optional parameter is
handled one layer up by the parameter's declared default, not here.

Throws a `ValidationError` when no member type parses. The previous behavior returned the raw
unparsed `String`, producing a value outside the declared union type.
"""
function parseparam(type::Union, str::String)
    for current_type in Base.uniontypes(type)
        (current_type === Nothing || current_type === Missing) && continue
        try
            return parseparam(current_type, str)
        catch e
            # A member type failing is the normal case — but do not let the blanket catch
            # swallow a condition that is not a member type failing, which would defeat the
            # guard in `parseparam_checked`. Widened past `InterruptException` in #254.
            is_unrecoverable(e) && rethrow()
            continue
        end
    end
    # The submitted value is deliberately not interpolated. `.msg` is app-reachable — via
    # `showerror`, via an app-level `catch ValidationError`, and via anything that chooses to
    # log it — so it must stay value-free regardless of what Nitro itself logs today.
    throw(ValidationError("Could not parse value as $type"))
end

"""
The fallback case for parsing parameters.
Tries to parse the type as is, if this fails then we assume it's a json string
"""
function parseparam(::Type{T}, str::String) where {T}
    try
        return parse(T, str)
    catch e
        # This is the method every scalar type below the specialized ones lands in, so it is
        # where the swallow would actually happen — falling through to the JSON parse and, one
        # layer up, being reported as a client error. The matching guard in
        # `parseparam_checked` never sees it without this rethrow.
        #
        # The fall-through below is reachable from ANY scalar parameter: `parse(Int, str)`
        # fails first and lands here. Unbounded, `JSON.parse` overflowed the stack on ~3 KB of
        # `[[[[…` in a query string (#254). `_parse_json_bounded` rejects anything nested past
        # `MAX_JSON_DEPTH` as malformed before the parser recurses (#314), so that is now an
        # `ArgumentError` -> `ValidationError` -> 400 like any other bad value.
        is_unrecoverable(e) && rethrow()
        #
        # Nitro's read style too: `str` is client input, and JSON.jl's default style interns the
        # strings it lifts into a `Symbol` or an enum field (#306).
        return _parse_json_bounded(str, T; style = BodyParsers.NITRO_READ_STYLE)
    end
end

"""
    parseparam_checked(::Type{T}, str, name, source)

Parse a scalar path or query parameter, converting **any** parse failure into a
`ValidationError` so a client input error becomes `400 Bad Request` rather than a
`500 Internal Server Error` with a logged backtrace.

This is the scalar counterpart of `Extractors.safe_extract`, which cannot be reused here: it is
typed `Param{U} where U <: Extractor{T}` and so cannot serve a bare `Param{Int}`. Without this
guard, `parseparam`'s bare `ArgumentError`/JSON errors — plus the `BoundsError` from
`parseparam(Char, "")` and the `ArgumentError` from an out-of-range `Enum` — reach
`handle_error(::Any)` and are reported as server faults.

`source` is `:path` or `:query`. It reaches neither the response body — which stays the generic
`400: Bad Request` — nor Nitro's own log, which reports only that a request was rejected; it is
there for an application that catches `ValidationError` and wants to say which parameter failed.
The submitted **value is deliberately never interpolated** into the message: `.msg` is
app-reachable and must stay value-free, because a parameter value can be a token or other secret.

The wrapped parse failure *is* attached as `.cause`, and that one is **not** value-free -- it is the
parser's own exception, which quotes its input. Since #130 none of `showerror`, `show` or
`JSON.lower` renders a cause by default (see `ValidationError` for the opt-in), so it is safe to
carry; reaching `.cause` directly and logging it is still on you.
"""
function parseparam_checked(::Type{T}, str::String, name::String, source::Symbol) where {T}
    try
        return parseparam(T, str)
    catch e
        # #254: not just an interrupt. Wrapping a `StackOverflowError` or `OutOfMemoryError`
        # in a `ValidationError` would call a corrupted worker a client mistake. A deeply
        # nested value no longer gets that far -- the JSON fall-through is depth-bounded
        # (#314) -- so this is the backstop, not the defence.
        is_unrecoverable(e) && rethrow()
        # Already well-formed (e.g. the `Regex` length cap above) — do not double-wrap.
        e isa ValidationError && rethrow()
        throw(ValidationError("Invalid $source parameter '$name': expected $T", e))
    end
end

"""
    Response Formatter functions
"""

# HTTP.jl v2's `Request` has no mutable `response` scratch field, and `Response{B}` is
# parametric on its body type (so the body cannot be reassigned in-place after
# construction). `format_response` therefore builds and returns a fresh `HTTP.Response`
# from whatever a handler returned.

format_response(resp::HTTP.Response) = resp

function format_response(content::AbstractString)
    # Security: serve raw string returns as text/plain. We must NOT content-sniff
    # here — `HTTP.sniff` would classify an attacker-influenced string that looks
    # like markup as text/html, turning a reflected value into stored/reflected
    # XSS. Handlers that intentionally return HTML/JS/etc. must opt in explicitly
    # via `Res.html(...)` or `Res.send(...; content_type=...)`, which set the type
    # themselves. Those two, plus template rendering through `response` below (which
    # DOES sniff), are the framework's markup sinks.
    body = string(content)
    return HTTP.Response(200, [
        "Content-Type" => "text/plain; charset=utf-8",
        "Content-Length" => string(sizeof(body)),
    ], body)
end

function format_response(content::Union{Number, Bool, Char, Symbol})
    # Convert all primitvies to a string and set the content type to text/plain
    body = string(content)
    return HTTP.Response(200, [
        "Content-Type" => "text/plain; charset=utf-8",
        "Content-Length" => string(sizeof(body)),
    ], body)
end

function format_response(content::Any)
    # Convert anthything else to a JSON string
    body = JSON.json(content)
    return HTTP.Response(200, [
        "Content-Type" => "application/json; charset=utf-8",
        "Content-Length" => string(sizeof(body)),
    ], body)
end

"""
    header_name_isequal(a, b) -> Bool

Case-insensitive comparison of two HTTP header field names. Replaces
`HTTP.Messages.field_name_isequal`, which was removed in HTTP.jl v2.
"""
header_name_isequal(a::AbstractString, b::AbstractString) = lowercase(a) == lowercase(b)

"""
    own_response_headers(resp::HTTP.Response) -> HTTP.Response

Return a copy of `resp` that owns its `headers` vector, so a caller can add response
headers without mutating `resp` in place.

Response objects are routinely shared across requests and threads — module-level `const`
error responses, cached responses — and Nitro's server is multithreaded
(`Threads.@spawn` per request). Appending to a *returned* response's `headers` therefore
mutates the shared object: it leaks/accumulates headers across requests (e.g. a session
`Set-Cookie` minted for one request served to the next) and is an unsynchronized data
race on the headers vector.

`status` and `body` are shared by reference. Sharing the body is safe because Nitro
writes bodies non-destructively (`Core._write_response_body!`); see
`docs/design/response-body-lifecycle.md`. Every other `HTTP.Response` field
(`reason`, `trailers`, HTTP version, `close`, and the client-side redirect fields) is
preserved — a handler returning `HTTP.Response(...; close=true)` keeps `close=true`
through the middleware chain. Used by header-adding middleware (CORS, session, CSRF,
rate limiter).
"""
own_response_headers(resp::HTTP.Response) = _rebuild_with_headers(resp, copy(resp.headers))

"""
    add_response_headers(resp::HTTP.Response, extra) -> HTTP.Response

Return a new response carrying `resp`'s status and body plus the `extra` header pairs,
without mutating `resp`. See [`own_response_headers`](@ref) for why in-place header
mutation of a returned response is unsafe, and for the full set of fields preserved.
"""
add_response_headers(resp::HTTP.Response, extra) = _rebuild_with_headers(resp, vcat(resp.headers, extra))

# Rebuild `resp` with a fresh `headers` vector while preserving every other field.
# The two-argument `HTTP.Response(status, headers, body)` constructor resets `reason`,
# `trailers`, HTTP version, `close`, and the client-side redirect fields to their
# defaults; the server reads `close`/version to decide connection teardown, so they
# must survive header-adding middleware. `body` (an `AbstractBody`) is shared by
# reference. See `own_response_headers`.
_rebuild_with_headers(resp::HTTP.Response, headers) = HTTP.Response(
    resp.status, resp.body;
    reason          = resp.reason,
    headers         = headers,
    trailers        = resp.trailers,
    content_length  = resp.content_length,
    proto_major     = resp.proto_major,
    proto_minor     = resp.proto_minor,
    close           = resp.close,
    request         = resp.request,
    request_url     = resp.request_url,
    previous        = resp.previous,
    redirect_count  = resp.redirect_count,
)


"""
    response(content::String, status=200, headers=[]) :: HTTP.Response

Convert a template string `content` into a valid HTTP Response object.
The content type header is automatically generated based on the content's mimetype
- `content`: The string content to be included in the HTTP response body.
- `status`: The HTTP status code (default is 200).
- `headers`: Additional HTTP headers to include (default is an empty array).

Returns an `HTTP.Response` object with the specified content, status, and headers.
"""
function response(content::String, status=200, headers=[]; detect=true) :: HTTP.Response
    response = HTTP.Response(status, headers, content)
    detect && HTTP.setheader(response, "Content-Type" => HTTP.sniff(content))
    HTTP.setheader(response, "Content-Length" => string(sizeof(content)))
    return response
end


"""
    join_url_path(prefix::Union{String,Nothing}, route::String)::String

- prefix may be nothing or a string (e.g. "api" or "/api/v1")
- route may be "/users/{id}" or "users/{id}" or "/"
Result always uses "/" and contains no duplicate slashes.
"""
function join_url_path(prefix::String, route::String) :: String
    if isempty(strip(route))
        return prefix
    else
        p = endswith(prefix, "/") ? prefix : prefix * "/"  # Ensure the prefix always ends with a slash
        r = startswith(route, "/") ? lstrip(route, '/') : route # Ensure the route doesn't start with a slash
        return p * r # when combined, it should create a valid url route
    end
end

join_url_path(::Nothing, route::String) :: String = route
join_url_path(prefix::String, ::Nothing) :: String = prefix

# """
#     generate_parser(func::Function, pathparams::Vector{Tuple{String,Type}})

# This function generates a parsing function specifically tailored to a given path.
# It generates parsing expressions for each parameter and then passes them to the given function. 

# ```julia

# # Here's an exmaple endpoint
# @get "/" function(req::HTTP.Request, a::Float64, b::Float64)
#     return a + b
# end

# # Here's the function that's generated by the macro
# function(func::Function, req::HTTP.Request)
#     # Extract the path parameters 
#     params = HTTP.getparams(req)
#     # Generate the parsing expressions
#     a = parseparam(Float64, params["a"])
#     b = parseparam(Float64, params["b"])
#     # Call the original function with the parsed parameters in the order they appear
#     func(req, a, b)
# end
# ```
# """
# function generate_parser(pathparams)    
#     # Extract the parameter names
#     func_args = [Symbol(param[1]) for param in pathparams]

#     # Create the parsing expressions for each path parameter
#     parsing_exprs = [
#         :( $(Symbol(param_name)) = parseparam($(param_type), params[$("$param_name")]) ) 
#         for (param_name, param_type) in pathparams
#     ]
#     quote 
#         function(func::Function, req::HTTP.Request)
#             # Extract the path parameters 
#             params = HTTP.getparams(req)
#             # Generate the parsing expressions
#             $(parsing_exprs...)
#             # Pass the func at runtime, so that revise can work with this
#             func(req, $(func_args...))
#         end
#     end |> eval
# end
