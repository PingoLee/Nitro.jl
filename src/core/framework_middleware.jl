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

function PrefixStripMiddleware(prefix::String)
    plen = length(prefix)
    NOT_FOUND = HTTP.Response(404, "Not Found")
    return function(handler)
        return function(req::HTTP.Request)
            if startswith(req.target, prefix)
                newtarget = req.target[plen+1:end]
                req.target = isempty(newtarget) ? "/" : newtarget
                return handler(req)
            else
                return NOT_FOUND
            end
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
