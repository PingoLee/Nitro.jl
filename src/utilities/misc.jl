using HTTP 
using JSON
using Dates

using ..Errors: ValidationError, UnsupportedMediaTypeError, AuthorizationError, WorkerUnavailableError,
    WorkerCapacityError, is_unrecoverable
using .BodyParsers: _parse_json_bounded

export recursive_merge, parseparam, parsebody, parseparam_checked,
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

# A refusal, not a fault (#323). It used to fall to `handle_error(::Any)`: a 500 plus an `@error`
# with a full backtrace, so every probe of someone else's task wrote a stack trace (the #18
# log-flood class) while a missing task answered 404 -- the difference was the oracle.
function handle_error(::AuthorizationError)
    return Res.json(("message" => "403: Forbidden"), status = 403)
end

# The App a worker call named has no runtime installed (#322). It used to fall back to the
# process-wide runtime, which carries none of the app's policy; now it is refused, and "the
# service this route needs is not up" is a 503, not a 500.
function handle_error(::WorkerUnavailableError)
    return Res.json(("message" => "503: Service Unavailable"), status = 503)
end

# A worker limit (#324). The runtime's concurrency cap and a full queue are the SERVER's capacity,
# so 503; a per-owner quota is THIS caller's, so 429. A full queue used to block the handler in
# `put!` indefinitely instead.
function handle_error(e::WorkerCapacityError)
    e.kind === :owner && return Res.json(("message" => "429: Too Many Requests"), status = 429)
    return Res.json(("message" => "503: Service Unavailable"), status = 503)
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
            elseif error isa AuthorizationError
                # A refusal, so no backtrace -- and, unlike the two branches above, not even
                # `.msg`: an `AuthorizationError`'s message names the caller-chosen queue or task key
                # verbatim, and it is not pinned value-free the way `ValidationError.msg` is (#323).
                show_errors && @debug "Request refused (403 Forbidden)"
            elseif error isa WorkerUnavailableError
                # A misconfiguration or a restart gap, not a client fault -- so visible, at
                # `@warn`, but without a backtrace per request. `.msg` is fixed text naming the
                # extension key and the fix; it carries no request data (#322).
                show_errors && @warn "Request refused (503): no worker runtime installed" message=error.msg
            elseif error isa WorkerCapacityError
                # Back-pressure, not a fault: a burst would otherwise write one line per refused
                # request at exactly the moment the server is busiest. `kind` only -- no message.
                show_errors && @debug "Request refused: worker capacity" kind=error.kind
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
        # `ArgumentError` -> `ValidationError` -> 400 like any other bad value. It parses with
        # Nitro's read style too: `str` is client input, and JSON.jl's default style interns the
        # strings it lifts into a `Symbol` or an enum field (#306).
        is_unrecoverable(e) && rethrow()
        return _parse_json_bounded(str, T; style = BodyParsers.NITRO_READ_STYLE)
    end
end

"""
Floats are the fallback above plus one rule: the value must be finite (#327).

`parse(Float64, s)` accepts `"NaN"`, `"nan"`, `"inf"` and `"-Infinity"`, and turns `"1e999"`
into `Inf`. None is a number a client can mean, and `NaN` defeats comparisons silently:
`NaN > balance` and `NaN <= balance` are both `false`, so a check like "reject if amount >
balance" lets it through. This one method covers every scalar path: `<float:x>`, typed query
parameters, `Cookie{Float64}`, struct fields bound by `Query{T}`/`Form{T}`, and each member of a
`Union`. `Body{Float64}` goes through `parsebody`, which applies the same rule. The message is value-free, like every other parse failure here.
"""
function parseparam(::Type{T}, str::String) where {T <: AbstractFloat}
    # A union of float types (`Union{Float32, Float64}`) also lands here, because it is
    # `<: AbstractFloat` and this method is more specific than `parseparam(::Union, …)`. Hand it
    # back to that method, which tries each member in turn: the fallback's `parse(T, str)` on a
    # union recurses in Base's `tryparse` until the stack overflows (#327 review).
    T isa Union && return invoke(parseparam, Tuple{Union, String}, T, str)
    value = invoke(parseparam, Tuple{Type{T}, String} where {T}, T, str)
    isfinite(value) || throw(ArgumentError("not a finite number"))
    return value
end

"""
    parsebody(::Type{T}, str) :: T

`Body{T}`'s conversion (#345): `parseparam` **without the JSON fall-through**. The types route
registration admits (`BodyParsers.binds_from_text`) are converted from the text alone -- through
their own `parseparam` method, or `Base.parse(T, str)` -- and a failure is a failure.

The fall-through is why this is not simply `parseparam`. It catches a failed `parse(T, str)` and
retries the text as JSON, so an app type admitted for its `Base.parse` method would still bind
field by field from a JSON body sent as `text/plain`, bypassing whatever that `parse` checks.
"""
function parsebody(::Type{T}, str::String) where {T}
    T isa Union && return parsebody_union(T, str)
    (T === Any || T === String || T <: Union{Char, Regex, Enum}) && return parseparam(T, str)
    value = parse(T, str)
    value isa AbstractFloat && !isfinite(value) && throw(ArgumentError("not a finite number"))
    return value
end

# `parseparam(::Union, …)`'s member loop, with `parsebody` per member: the first member the text
# converts to wins, `Nothing`/`Missing` are never targets, and the message stays value-free.
function parsebody_union(type::Union, str::String)
    for current_type in Base.uniontypes(type)
        (current_type === Nothing || current_type === Missing) && continue
        try
            return parsebody(current_type, str)
        catch e
            is_unrecoverable(e) && rethrow()
            continue
        end
    end
    throw(ValidationError("Could not parse value as $type"))
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
    # sniffs when no type was given), are the framework's markup sinks.
    return _formatted(string(content), "text/plain; charset=utf-8")
end

function format_response(content::Union{Number, Bool, Char, Symbol})
    # Convert all primitvies to a string and set the content type to text/plain
    return _formatted(string(content), "text/plain; charset=utf-8")
end

function format_response(content::Any)
    # Convert anthything else to a JSON string
    return _formatted(JSON.json(content), "application/json; charset=utf-8")
end

# The response every `format_response` method builds: a 200 with exactly these two headers, made
# through `Res._new_response` rather than HTTP's keyword constructor (#446).
function _formatted(body::String, content_type::String)
    h = HTTP.Headers(2)
    push!(h, "Content-Type" => content_type)
    push!(h, "Content-Length" => string(sizeof(body)))
    return Res._new_response(200, h, body)
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
add_response_headers(resp::HTTP.Response, extra::Pair{<:AbstractString,<:AbstractString}) =
    _rebuild_with_headers(resp, _appended(resp.headers, (extra,)))
add_response_headers(resp::HTTP.Response, extra::AbstractVector{<:Pair{<:AbstractString,<:AbstractString}}) =
    _rebuild_with_headers(resp, _appended(resp.headers, extra))
# Anything else -- tuples, vector-valued pairs, an untyped vector -- keeps HTTP's general
# normalization, which is what every call went through before #447.
add_response_headers(resp::HTTP.Response, extra) =
    _rebuild_with_headers(resp, HTTP.Headers(vcat(resp.headers, extra)))

# `resp.headers` then `extra`, through `appendheader`: adjacent duplicate names fold into `a,b`
# and `Set-Cookie` never does. That is exactly what `HTTP.Headers(vcat(resp.headers, extra))`
# produces, minus the intermediate vector and the keyword constructor's second copy (#447).
function _appended(headers::HTTP.Headers, extra)
    out = HTTP.Headers(length(headers) + length(extra))
    for header in headers
        HTTP.appendheader(out, header)
    end
    for header in extra
        HTTP.appendheader(out, header)
    end
    return out
end

# Rebuild `resp` around a `headers` collection the caller owns, carrying every other field over
# as-is. The keyword constructors reset `reason`, `trailers`, HTTP version, `close` and the
# client-side redirect fields unless each is passed back in; the server reads `close`/version to
# decide connection teardown, so they must survive header-adding middleware. `body` is shared by
# reference (see `own_response_headers`); `trailers` is copied, so the new response owns every
# mutable collection it holds. `content_length` is carried as stored too: the keyword form
# re-derived a negative one from the body, which no constructor produces for a sized body, so
# only a handler that wrote `-1` into a built response would see a difference.
#
# This is `Res._new_response`'s field constructor (#446), not the keyword form: that form ran
# `copy(mkheaders(...))` on both header collections, so each middleware layer built four of them
# per request (#447). The field order is pinned in `test/http_internals_contract_tests.jl`.
_rebuild_with_headers(resp::HTTP.Response{B}, headers::HTTP.Headers) where {B} = HTTP.Response{B}(
    resp.status, resp.reason, headers, copy(resp.trailers), resp.body, resp.content_length,
    resp.proto_major, resp.proto_minor, resp.close, resp.request, resp.request_url,
    resp.previous, resp.redirect_count,
)

# A response carrying one visitor's credential cookie must never be stored by a SHARED cache
# (#317). A static file served `public, max-age=31536000, immutable` under a global
# `SessionMiddleware` used to carry `Set-Cookie: <session>=<fresh id>` with no `private` and no
# `Vary: Cookie`, so a CDN that stored it handed one session -- and the CSRF token bound to it --
# to every visitor. `SessionMiddleware` calls this on every response that sets its cookie, and
# `CSRFMiddleware` on every response that sets its token cookie (#431): the token alone, sent
# without a session write, is still one visitor's credential.
#
# Internal, not exported: import it as `using ...Util: _mark_private!`. It lives in `Util`, next to
# `own_response_headers`, because both middleware modules use it and `csrf_middleware.jl` is
# included before `session_middleware.jl`. Only ever call it on headers the caller already owns
# (`own_response_headers`).
function _mark_private!(response::HTTP.Response)
    vary = String[]
    cache_control = String[]
    for (name, value) in response.headers
        field = lowercase(name)
        if field == "vary"
            append!(vary, _header_list(value))
        elseif field == "cache-control"
            append!(cache_control, _header_list(value))
        end
    end

    # `Vary` may already span several field lines -- `Cors` pushes its own `Vary: Origin` -- and
    # another line is additive by definition, so nothing already there is rewritten.
    if !any(t -> t == "*" || lowercase(t) == "cookie", vary)
        push!(response.headers, "Vary" => "Cookie")
    end

    # `private` wins over `public`; every other directive (`max-age`, `immutable`, …) is kept, so
    # the visitor's own browser still caches exactly as the handler asked. A response already
    # `private` or `no-store` is left alone.
    names = String[lowercase(strip(first(split(d, '='; limit = 2)))) for d in cache_control]
    if !("private" in names || "no-store" in names)
        kept = String[d for (d, n) in zip(cache_control, names) if n != "public"]
        # `setheader` replaces EVERY existing `Cache-Control` line with this one.
        HTTP.setheader(response, "Cache-Control" => join(pushfirst!(kept, "private"), ", "))
    end
    return response
end

# The comma-separated elements of a list-valued header, trimmed. A quoted element holding a comma
# (`no-cache="a, b"`) splits in two, but the pieces are re-joined in order with ", ", so it is
# written back as it came -- and no directive name this function tests can be inside quotes.
_header_list(value::AbstractString) =
    String[strip(element) for element in split(value, ',') if !isempty(strip(element))]


"""
    response(content::String, status=200, headers=[]; content_type=nothing, detect=true) :: HTTP.Response

Convert a rendered template string `content` into an HTTP Response. This is what the Mustache and
OteraEngine extensions render through, and it is a markup sink.

The `Content-Type` is the first of these that applies, and there is only ever one:
1. a `Content-Type` already in `headers` — the caller's per-call choice;
2. `content_type` — the template's `mime_type`;
3. `HTTP.sniff(content)`, only when `detect` is true.

**An explicit type is never overridden by sniffing** (#328). It used to be: sniffing replaced the
caller's header, so a template served as `text/plain` precisely so that unescaped output was safe
went out as `text/html` whenever the rendered value looked like markup.
"""
function response(content::String, status=200, headers=[]; content_type=nothing, detect=true) :: HTTP.Response
    response = HTTP.Response(status, headers, content)
    if !HTTP.hasheader(response, "Content-Type")
        if !isnothing(content_type)
            HTTP.setheader(response, "Content-Type" => content_type)
        elseif detect
            HTTP.setheader(response, "Content-Type" => HTTP.sniff(content))
        end
    end
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

### Access-log helpers ###
#
# Shared by BOTH access loggers: the console line `AccessLogMiddleware` writes
# (src/core/framework_middleware.jl) and the structured `AccessLog` records
# (src/middleware/access_log.jl). They live here, in `Util`, because `Util` is included before
# `middleware.jl` and `core/framework_middleware.jl` is included after it -- a helper defined
# there is not yet a binding when `access_log.jl` imports it (#320).

# Strip everything after the path from a request-target, for the access log (#39).
#
# The hot path is a slice, not a full `HTTP.URI` parse: parsing per request purely to discard
# the query is waste, and for the origin-form target that ~every request carries
# (`/v1/x?k=1`) the prefix before the first '?' *is* the path.
#
# Two cases stop that from being the whole story, and both are security-relevant, because
# this feeds a log that is routinely shipped to third-party aggregators:
#
#   * **Absolute-form** (RFC 9112 §3.2.2) -- a server MUST accept `GET http://h/x?k=1`, and
#     HTTP.jl passes the target through verbatim. A prefix slice keeps
#     `scheme://userinfo@host`, so `http://user:pa55w0rd@h/x` would put credentials straight
#     into the log.
#   * **A leading `//` is an authority, not a path.** `//user:pa55w0rd@evil.example/x` *does*
#     start with '/', so a naive "starts with '/' means origin-form" test sends it down the
#     slice branch and logs the credentials anyway. This is the case that makes the guard
#     `startswith(target, '/') && !startswith(target, "//")` rather than the obvious one.
#   * **Fragments** are not legal in a request-target and browsers never send one, but a
#     hand-rolled client can, and '#' binds tighter than '?'. Cutting at whichever comes
#     first keeps this agreeing with `HTTP.URI(...).path`, which drops the fragment.
#
# Everything that is not origin-form is parsed, and the parse result is logged only if it is
# a real absolute path. That last test is what makes the fallback safe by construction rather
# than by enumerating forms: authority-form (`CONNECT h.example:443`) parses to the nonsense
# path "443", and any future shape that resolves to something authority-like fails it too, so
# the log gets "-" instead of attacker-influenced text. Asterisk-form is a fixed literal with
# no user content, so it is passed through as itself.
function _log_target_path(target::AbstractString)
    target == "*" && return SubString("*")
    if startswith(target, '/') && !startswith(target, "//")
        q = findfirst('?', target)
        h = findfirst('#', target)
        cut = q === nothing ? h : (h === nothing ? q : min(q, h))
        return cut === nothing ? SubString(target) : SubString(target, 1, prevind(target, cut))
    end
    parsed = try
        String(HTTP.URI(target).path)
    catch e
        e isa InterruptException && rethrow()
        ""
    end
    return SubString(startswith(parsed, '/') ? parsed : "-")
end

# Escape a request-target for a rendered log LINE (#320). HTTP.jl rejects C0 bytes in the
# request line, but not C1 controls (`\u9b` is a terminal CSI), raw non-UTF-8 bytes, or the
# Unicode line/bidi characters (U+2028, U+202E) -- a terminal may act on the first, and log UIs
# render the last as forged line breaks or reversed text. `escape_string` turns every one of
# those into a visible `\u…`/`\x…` escape, and escapes `"` too, which matters because the line
# wraps the target in quotes: a raw `"` could close that field and forge the next. Printable
# non-ASCII (`/café`) and percent-escapes pass through unchanged.
#
# For LINES only. A structured `AccessRecord` is data handed to a sink, not a rendering, so it
# is never escaped -- escaping is the renderer's job, as it is here for the console line.
_log_escape(s::AbstractString) = escape_string(s)

# Both access logs take a post-response `skip(req, resp) -> Bool` (#401). Until then the
# structured `AccessLog`'s `skip` was `req -> Bool`, called before the handler. An old one-argument
# hook would now throw a `MethodError` on every request -- caught, warned, and the request logged
# anyway -- so the migration would surface as a warning flood instead of an error. Refuse that
# shape at construction, where the call that contains it is on the stack. Only the clearly-old
# shape is refused: a hook with no method we can see is left to fail per request as any other.
function _check_access_log_skip(skip, owner::AbstractString)
    skip === nothing && return nothing
    if !hasmethod(skip, Tuple{HTTP.Request, Any}) && hasmethod(skip, Tuple{HTTP.Request})
        throw(ArgumentError(
            "$owner: `skip` is now called AFTER the handler as `skip(req, resp)` -- `resp` is the " *
            "response, or `nothing` when the handler threw -- but this hook only takes `req`. " *
            "Rewrite `req -> …` as `(req, resp) -> …` (#401; see `upgrade_guide`)."))
    end
    return nothing
end

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
