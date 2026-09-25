# ── Framework middleware ────────────────────────────────────────────────────────
# The Core-owned layers `setupmiddleware` installs around the router.
# Included into `module Core` by src/core.jl — not a submodule; see the hub for why.

# The access-log target helpers live in `Util` (src/utilities/misc.jl) so the structured
# `AccessLog`, which is included before this file, can share them (#320). Imported by name so
# they stay reachable as `Nitro.Core._log_target_path`, which the security tests pin.
using .Util: _log_target_path, _log_escape

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
both. Only opt in for a service whose clients you control. Inside the pipeline `setupmiddleware`
builds, `OriginFormMiddleware` has already dropped an absolute-form authority by the time this
reads the target (#341); the caveat stands for this layer used on its own.

Either way the target is escaped before it reaches the line (#320): control characters,
invalid UTF-8 and Unicode line/bidi characters appear as `\\u…`/`\\x…` escapes, and `"` and
`\\` are backslash-escaped, so a request cannot forge a log line or drive the terminal that
displays it.
"""
function AccessLogMiddleware(; log_query::Bool=false)
    return function(handle)
        return function(req::HTTP.Request)
            response = handle(req)
            ip = Base.get(req.context, :ip, nothing)
            target = _log_escape(log_query ? req.target : _log_target_path(req.target))
            @info "$(Dates.format(now(), "yyyy-mm-ddTHH:MM:SS")) - $ip - \"$(req.method) $target\" $(response.status)"
            return response
        end
    end
end

# One or more `/segment`s, each a run of RFC 3986 `pchar`s: unreserved, sub-delims, ':' and '@',
# or a `%XX` escape. That rules out '?', '#', whitespace, non-ASCII and empty segments in one test.
# Anchored with `\z`, not `$`: PCRE's `$` also matches before a final "\n", so a prefix read from
# a file or an env var with its newline still attached would pass and then match nothing.
const _PREFIX_SHAPE = r"^(?:/(?:[A-Za-z0-9\-._~!$&'()*+,;=:@]|%[0-9A-Fa-f]{2})+)+\z"

"""
    _normalize_prefix(prefix) -> Union{String, Nothing}

Validate `serve(prefix = …)` and return it in the one form `PrefixStripMiddleware` matches on:
a `String` with a leading `/` and no trailing one (#315). `nothing` means no prefix.

The prefix is compared against the raw request-target, which is what arrives on the wire, so it
has to be written the way a client sends it: ASCII, percent-encoded, no query or fragment.
Escapes are compared byte for byte, so write them in the uppercase RFC 3986 recommends and clients
send (`%C3%A9`, not `%c3%a9`); a mismatch fails closed, as a 404. A
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
        "`prefix = $(repr(prefix))` must start with '/', like \"/api\"."))
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
function _strip_prefix(target::String, prefix::String, n::Int)::Nullable{String}
    startswith(target, prefix) || return nothing
    ncodeunits(target) == n && return "/"
    next = codeunit(target, n + 1)
    next == UInt8('/') && return String(SubString(target, n + 1))
    next == UInt8('?') && return string('/', SubString(target, n + 1))
    return nothing
end

"""
    _origin_form(target) -> Union{String, Nothing}

The request-target as the router will match it, in origin-form (`/path?query`), or `nothing`
when the path holds an empty segment (`//`) and the request must be refused (#341).

HTTP.jl's router does not match on `req.target` as written. It splits the path with
`keepempty = false`, so `//admin/users` and `/admin//users` both reach `/admin/users`, and it
routes an absolute-form target (`http://h/admin/users`) by the path after the authority. Global
middleware runs before the route is chosen (#291), so a gate testing
`startswith(req.target, "/admin")` saw none of those as `/admin`. This makes the two agree:

- `*` (`OPTIONS *`) is returned as is.
- Origin-form is returned as the **same object** when it is well-formed, the common case.
- Absolute-form loses its scheme and authority, as RFC 9112 §3.2.2 has an origin server do. The
  authority ends at the first `/`, `?` or `#` and is never parsed, so a malformed one
  (`http://h:abc/x`) cannot throw (#326). An empty path becomes `/`. The router finds the path
  by the first `/` after `://` instead, which put `http://h?x=/admin` and `http://h#/admin` on
  `/admin`. Now the first routes to `/`, and the second keeps its fragment in the path
  (`/#/admin`), which matches no route.
- Anything else, including `""`, gets the leading `/` the router assumes. Over the wire that is
  only `CONNECT`'s authority-form (`host:443`); `internalrequest` can deliver any string.

An empty segment is refused rather than collapsed. Collapsing would rewrite
`//user:pw@host/x`, which the access log reduces as an authority and redacts, into a path that
logs the credentials. The check covers the path up to the first `?`, the same cut the router
makes, so a `//` inside the query is fine and a single trailing `/` is kept.

The result always starts with `/` and has no empty segment before its last `/`, so the path
the router splits is the path global middleware reads, segment for segment.
"""
function _origin_form(target::String)::Nullable{String}
    target == "*" && return target
    t = target
    if !startswith(target, '/')
        scheme = findfirst("://", target)
        if scheme === nothing
            t = string('/', target)
        else
            i = findnext(c -> c === '/' || c === '?' || c === '#', target, last(scheme) + 1)
            t = i === nothing ? "/" :
                target[i] == '/' ? String(SubString(target, i)) :
                string('/', SubString(target, i))
        end
    end
    q = findfirst('?', t)
    path = q === nothing ? t : SubString(t, 1, prevind(t, q))
    occursin("//", path) && return nothing
    return t
end

"""
    OriginFormMiddleware()

The framework layer that puts `req.target` in the form the router matches, before any prefix
strip or user middleware sees it (#341). See `_origin_form`. A target with an empty path segment
is answered `400`.
"""
function OriginFormMiddleware()
    BAD_REQUEST = HTTP.Response(400, "Bad Request")
    return function(handler)
        return function(req::HTTP.Request)
            target = _origin_form(req.target)
            target === nothing && return BAD_REQUEST
            target === req.target || (req.target = target)
            return handler(req)
        end
    end
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
