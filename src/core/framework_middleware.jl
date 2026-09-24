# ── Framework middleware ────────────────────────────────────────────────────────
# The Core-owned layers `setupmiddleware` installs around the router.
# Included into `module Core` by src/core.jl — not a submodule; see the hub for why.

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

"""
    AccessLogMiddleware(; log_query::Bool=false)

Logs one line per request once the response status is known, mirroring the old
HTTP.jl v1 `access_log` default (`\$time_iso8601 - \$remote_addr:\$remote_port - "\$request" \$status`).
HTTP.jl v2 removed the `logfmt`/`access_log` server kwargs, so request logging now
lives in the middleware chain.

Security: by default only the request **path** is logged, not the query string.
Query strings routinely carry secrets (password-reset tokens, API keys, OAuth
`code`/`state`, signed-URL signatures), and access logs are frequently shipped to
third-party aggregators. Pass `log_query=true` to log the full target including the
query when you are sure no sensitive data travels in URLs.

`log_query=true` logs the request-target **verbatim**, which is not only the query: a
client may send absolute-form (`GET http://user:pa55w0rd@host/x`), so credentials in the
authority are logged too. The default path is reduced by `_log_target_path`, which strips
both. Only opt in for a service whose clients you control.
"""
function AccessLogMiddleware(; log_query::Bool=false)
    return function(handle)
        return function(req::HTTP.Request)
            response = handle(req)
            ip = Base.get(req.context, :ip, nothing)
            target = log_query ? req.target : _log_target_path(req.target)
            @info "$(Dates.format(now(), "yyyy-mm-ddTHH:MM:SS")) - $ip - \"$(req.method) $target\" $(response.status)"
            return response
        end
    end
end

# One or more `/segment`s, each a run of RFC 3986 `pchar`s: unreserved, sub-delims, ':' and '@',
# or a `%XX` escape. That rules out '?', '#', whitespace, non-ASCII and empty segments in one test.
const _PREFIX_SHAPE = r"^(?:/(?:[A-Za-z0-9\-._~!$&'()*+,;=:@]|%[0-9A-Fa-f]{2})+)+$"

"""
    _normalize_prefix(prefix) -> Union{String, Nothing}

Validate `serve(prefix = …)` and return it in the one form `PrefixStripMiddleware` matches on:
a `String` with a leading `/` and no trailing one (#315). `nothing` means no prefix.

The prefix is compared against the raw request-target, which is what arrives on the wire, so it
has to be written the way a client sends it: ASCII, percent-encoded, no query or fragment. A
shape that could never match a well-formed target is an `ArgumentError` here rather than a
server that answers 404 to everything. Trailing slashes are dropped, the same tolerance
`urlpatterns` gives its prefixes. Any `AbstractString` is accepted; `serve` used to drop a
`SubString` silently, which left every route unprefixed.
"""
function _normalize_prefix(prefix)::Nullable{String}
    prefix === nothing && return nothing
    prefix isa AbstractString || throw(ArgumentError(
        "`prefix` must be a string such as \"/api\", or `nothing` for no prefix; got a $(typeof(prefix))."))
    p = String(rstrip(prefix, '/'))
    isempty(p) && throw(ArgumentError(
        "`prefix = $(repr(prefix))` strips nothing. Pass `prefix = nothing` to serve without a prefix."))
    isascii(p) || throw(ArgumentError(
        "`prefix = $(repr(prefix))` is not ASCII. It is matched against the raw request-target, so " *
        "write it percent-encoded, the way clients send it: e.g. \"/caf%C3%A9\" for \"/café\"."))
    startswith(p, '/') || throw(ArgumentError(
        "`prefix = $(repr(prefix))` must start with '/', e.g. \"/$(p)\"."))
    occursin(_PREFIX_SHAPE, p) || throw(ArgumentError(
        "`prefix = $(repr(prefix))` is not a URL path. Each segment may hold only letters, digits, " *
        "`-._~!\$&'()*+,;=:@` and `%XX` escapes: no '?', '#', whitespace, or empty segments (`//`)."))
    any(s -> s == "." || s == "..", eachsplit(p, '/')) && throw(ArgumentError(
        "`prefix = $(repr(prefix))` contains a '.' or '..' segment. Clients resolve those before " *
        "sending a request, so the prefix would never match."))
    return p
end

"""
    _strip_prefix(target, prefix, n) -> Union{String, Nothing}

`target` with `prefix` removed, or `nothing` when the request is not under it. `n` is
`ncodeunits(prefix)` and `prefix` comes from `_normalize_prefix`.

The prefix is a whole number of path segments (#315). `/api` covers `/api`, `/api/…` and
`/api?…`. It does not cover `/apiadmin/…`: a bare `startswith` turned that into `admin/…`, which
HTTP.jl's router resolves to `/admin/…`, so any control keyed on the URL (a global
`startswith(req.target, "/admin")` gate, a proxy `location /api/admin/` rule) was bypassed. The
result always keeps its leading `/`. `n` is a byte count and the byte after the prefix is ASCII
whenever it is accepted, so slicing at `n + 1` is always on a character boundary.
"""
function _strip_prefix(target::AbstractString, prefix::String, n::Int)::Nullable{String}
    startswith(target, prefix) || return nothing
    ncodeunits(target) == n && return "/"
    next = codeunit(target, n + 1)
    next == UInt8('/') && return String(SubString(target, n + 1))
    next == UInt8('?') && return string('/', SubString(target, n + 1))
    return nothing
end

function PrefixStripMiddleware(prefix::AbstractString)
    # Normalized here as well as in `serve`: `internalrequest` builds this layer straight from
    # `service.prefix[]`, so this is the one point every path to it shares.
    p = _normalize_prefix(prefix)::String
    n = ncodeunits(p)
    NOT_FOUND = HTTP.Response(404, "Not Found")
    return function(handler)
        return function(req::HTTP.Request)
            stripped = _strip_prefix(req.target, p, n)
            stripped === nothing && return NOT_FOUND
            req.target = stripped
            return handler(req)
        end
    end
end

function DefaultSerializer(catch_errors::Bool; show_errors::Bool)
    return function(handle)
        return function(req::HTTP.Request)
            return handlerequest(catch_errors; show_errors) do
                format_response(handle(req))
            end
        end
    end
end

# The pipeline's error boundary (#256): `handlerequest` around the WHOLE middleware chain, so an
# exception escaping middleware gets the same treatment one escaping a handler does -- an `@error`
# with a backtrace, the generic JSON 500 (or a 400 for a `ValidationError`), and an access-log line.
#
# `DefaultSerializer` cannot simply move out here, because it does two jobs and only one of them
# belongs at the top. `format_response` must stay innermost: every middleware is written against an
# `HTTP.Response` coming back from `handle(req)`, not a handler's raw `Dict` or `String`. The catch
# stays there too, so a handler's 500 still passes back through `Cors`, the session layer and the
# rest on its way out. This layer therefore only ever sees what escapes middleware; a handler's
# exception has already become a response, which is also why nothing is logged twice.
#
# Before this, such an exception left `stream_handler` unhandled and HTTP.jl answered with a
# bodyless 500 and no Nitro log line at all -- the path #254 made reachable from `BearerAuth` and
# `CookieAuthMiddleware` by letting `StackOverflowError`/`OutOfMemoryError` through them. This is
# Plug's `Plug.ErrorHandler` shape: the boundary sits at the top of the pipeline, not next to the
# router.
#
# `setupmiddleware` places it INSIDE `AccessLogMiddleware`, which reads `response.status` and so
# needs a response to exist, and outside everything that can throw. A 500 raised here carries no
# CORS or session headers: those layers were inside the throw and never produced a response.
#
# `InterruptException` is rethrown BEFORE `handlerequest` sees it. `handlerequest` turns every
# exception into a response, interrupts included (it only skips logging them), so without this the
# boundary would absorb a Ctrl-C landing in middleware as a silent 500. That is the exact "no-op
# Ctrl-C" #254 removed from `BearerAuth` and `CookieAuthMiddleware`. Before this layer existed an
# interrupt out of middleware propagated, and it still does. `StackOverflowError` and
# `OutOfMemoryError` are deliberately NOT rethrown: they are failures of the request, and
# recording them is what this layer is for.
#
# `handlerequest(rethrow, ...)` reuses its policy (log level, 400 vs 500, body) instead of
# restating it. The no-argument `rethrow()` re-raises the exception being handled here with its
# ORIGINAL backtrace, so the `catch_backtrace()` that `handlerequest` logs still points into the
# middleware that threw, not at this layer.
function ErrorBoundary(catch_errors::Bool; show_errors::Bool)
    return function(handle)
        return function(req::HTTP.Request)
            try
                return handle(req)
            catch e
                e isa InterruptException && rethrow()
                return handlerequest(rethrow, catch_errors; show_errors)
            end
        end
    end
end
