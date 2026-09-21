module SecurityHeadersMiddleware

using Dates
using HTTP
using ...Types
using ...Core: add_response_headers

export SecurityHeaders

# Seconds for a `Strict-Transport-Security` max-age. `Dates.Second` converts the fixed-length
# periods (Week, Day, Hour, Minute, Second) and deliberately throws for Month and Year, which have
# no fixed length -- `Year(1)` as an HSTS max-age would be ambiguous by exactly the amount that
# matters when the value is cached by the browser for that long. Pass `Day(365)` instead.
_hsts_seconds(value::Dates.Period) = Int(Dates.value(Dates.Second(value)))
_hsts_seconds(value::Integer) = Int(value)

"""
    SecurityHeaders(; content_type_options="nosniff", frame_options="DENY", referrer_policy="strict-origin-when-cross-origin", hsts=nothing, hsts_include_subdomains=true, hsts_preload=false, csp=nothing, extra_headers=Pair[])

Creates a middleware function that adds baseline security headers to every response.

Add it to a middleware list like any other middleware; it is **not** installed by default:

```julia
serve(middleware = [SecurityHeaders(), Cors(), SessionMiddleware(store = MemoryStore())])
```

Nitro follows Phoenix here rather than Helmet. Phoenix's `put_secure_browser_headers` is generated
into the `:browser` pipeline and deliberately **never** into `:api`, because `X-Frame-Options` and
a referrer policy do nothing for a JSON response — and Nitro is SPA/API-first, so the same split
says opt-in. Django reaches the same place from the other direction: `SecurityMiddleware` ships in
the default list, but every setting that can break an app defaults to off.

# What is on by default

`X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY` and
`Referrer-Policy: strict-origin-when-cross-origin`. These three are safe to send on any response:
`nosniff` is default-on in Django, Phoenix, Spring Security and Helmet alike, and the other two
only constrain how a *browser* frames or attributes a page. Set any of them to `nothing` to omit
the header.

# What is off by default, and why

- **`hsts`** — sticky. A browser honours `max-age` even after you stop sending the header, so a
  value sent by mistake keeps a hostname HTTPS-only for that long with no way to recall it. It is
  off by default in Django (`SECURE_HSTS_SECONDS = 0`) and only sent over HTTPS by Spring
  Security. Nitro speaks plain HTTP behind a proxy and **cannot detect whether TLS terminated
  upstream**, so enable it only when you know it did.
- **`csp`** — a wrong policy breaks an SPA outright, which is why Helmet's default CSP is its
  single largest source of "it broke my app". There is no safe default to guess, so there is none.

# Keyword Arguments

    - `content_type_options`: `X-Content-Type-Options` (default: `"nosniff"`); `nothing` omits it.
    - `frame_options`: `X-Frame-Options` (default: `"DENY"`); `nothing` omits it. Use
      `"SAMEORIGIN"` if your own pages frame each other. For finer control prefer CSP's
      `frame-ancestors`, which supersedes this header in modern browsers.
    - `referrer_policy`: `Referrer-Policy` (default: `"strict-origin-when-cross-origin"`).
    - `hsts`: `Strict-Transport-Security` max-age, as a `Dates.Period` (`Day(365)`) or seconds.
      `nothing` (default) omits the header entirely.
    - `hsts_include_subdomains`: append `; includeSubDomains` (default: `true`).
    - `hsts_preload`: append `; preload` (default: `false`). Requires `hsts_include_subdomains`
      and a max-age of at least one year, per the browser preload list's own rules; a combination
      that could never be accepted is rejected at construction time rather than sent.
    - `csp`: `Content-Security-Policy` value. `nothing` (default) omits it.
    - `extra_headers`: additional pairs appended verbatim — `Cross-Origin-Opener-Policy`,
      `Permissions-Policy`, or anything else you want on every response.

Every header here is a **default, not an override**: if a handler or an inner middleware already
set one, that value is left alone and no second copy is added. This matters because duplicate
security headers are not additive — a browser seeing two conflicting `X-Frame-Options` must treat
the directive as invalid (RFC 7034 §2.1), which drops the protection rather than tightening it. So
a route that deliberately answers `X-Frame-Options: SAMEORIGIN` keeps it, even under an app-wide
`SecurityHeaders()` defaulting to `DENY`.

# Returns
A middleware closure compatible with the Nitro middleware pipeline. It owns no background
resource, so it is a plain `handle -> req -> resp` closure rather than a `LifecycleMiddleware`.

# Examples

```julia
# Defaults only -- the three headers that cannot break anything
SecurityHeaders()

# A browser-facing deployment with TLS terminated at the proxy
SecurityHeaders(hsts = Day(365), csp = "default-src 'self'")

# A JSON API that is framed by a partner's dashboard
SecurityHeaders(frame_options = "SAMEORIGIN", referrer_policy = "no-referrer")

# Nothing but your own additions
SecurityHeaders(content_type_options = nothing, frame_options = nothing,
                referrer_policy = nothing,
                extra_headers = ["Cross-Origin-Opener-Policy" => "same-origin"])
```
"""
function SecurityHeaders(;
    content_type_options    :: Nullable{String} = "nosniff",
    frame_options           :: Nullable{String} = "DENY",
    referrer_policy         :: Nullable{String} = "strict-origin-when-cross-origin",
    hsts                    :: Union{Nothing, Integer, Dates.Period} = nothing,
    hsts_include_subdomains :: Bool = true,
    hsts_preload            :: Bool = false,
    csp                     :: Nullable{String} = nothing,
    extra_headers           :: Vector{Pair{String, String}} = Pair{String,String}[])

    if hsts_preload && hsts === nothing
        throw(ArgumentError(
            "`hsts_preload=true` needs an `hsts` max-age: `preload` is a modifier on " *
            "Strict-Transport-Security, and without `hsts` no such header is sent at all."
        ))
    end

    headers = Pair{String, String}[]

    content_type_options === nothing || push!(headers, "X-Content-Type-Options" => content_type_options)
    frame_options        === nothing || push!(headers, "X-Frame-Options"        => frame_options)
    referrer_policy      === nothing || push!(headers, "Referrer-Policy"        => referrer_policy)

    if hsts !== nothing
        seconds = _hsts_seconds(hsts)
        seconds >= 0 || throw(ArgumentError("`hsts` max-age must be >= 0 seconds, got $seconds"))

        # Rejected at construction rather than sent, the same way `Cors` refuses
        # `allow_credentials` with a wildcard origin. A header the preload list would never accept
        # is not a weaker header -- it is a deployment that believes it is preloaded and is not.
        if hsts_preload
            hsts_include_subdomains || throw(ArgumentError(
                "`hsts_preload=true` requires `hsts_include_subdomains=true`: the browser preload " *
                "list rejects any entry without includeSubDomains."
            ))
            seconds >= 31_536_000 || throw(ArgumentError(
                "`hsts_preload=true` requires an `hsts` max-age of at least one year " *
                "(31536000 seconds), got $seconds. The preload list rejects anything shorter."
            ))
        end

        value = "max-age=$seconds"
        hsts_include_subdomains && (value *= "; includeSubDomains")
        hsts_preload            && (value *= "; preload")
        push!(headers, "Strict-Transport-Security" => value)
    end

    csp === nothing || push!(headers, "Content-Security-Policy" => csp)
    append!(headers, extra_headers)

    # Every header is known at construction time -- none of them depends on the request -- so the
    # vector is built once here and only read per request. Nothing is assigned inside the innermost
    # closure, which is what keeps it safe to share across threads.
    frozen = headers

    # Everything was disabled. Hand back a pass-through rather than rebuilding each response to
    # add nothing: `add_response_headers` allocates a new `HTTP.Response` on every call, and doing
    # that for an empty header list is pure cost on the request hot path.
    isempty(frozen) && return handle::Function -> handle

    return function(handle::Function)
        return function(req::HTTP.Request)
            resp = handle(req)

            # A NEW response, never a mutation of the one the inner layer returned. That response
            # may be a shared module-level `const` (an auth rejection, a cached error), and Nitro
            # serves every request on its own thread -- so `setheader` here would both leak these
            # headers across requests and race. See nitro-core §4.
            #
            # Fast path: the inner layer set none of these, which is almost every response. The
            # `any` scan itself allocates nothing and the shared `frozen` vector is appended as-is,
            # so this path costs exactly what the middleware cost before the conflict check existed
            # -- it is not allocation-free, because `add_response_headers` builds a new `Response`
            # by design, and nothing here should be "optimized" on the belief that it was.
            any(p -> HTTP.hasheader(resp, p.first), frozen) || return add_response_headers(resp, frozen)

            # A handler or an inner middleware already chose a value for at least one of these, so
            # DO NOT add a second copy. Two conflicting `X-Frame-Options` on the wire is not "more
            # secure": RFC 7034 §2.1 says the browser must treat the directive as invalid, so the
            # likely outcome is the protection being dropped entirely -- worse than either value
            # alone. The explicit choice wins, which is also what Django's `SecurityMiddleware`
            # (`setdefault`) and Phoenix's `put_secure_browser_headers` both do.
            return add_response_headers(resp, [p for p in frozen if !HTTP.hasheader(resp, p.first)])
        end
    end
end

end
