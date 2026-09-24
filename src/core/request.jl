# ── Request accessors ───────────────────────────────────────────────────────────
# Per-request caches and the exported `get*` accessor surface.
# Included into `module Core` by src/core.jl — not a submodule; see the hub for why.

const REQUEST_JSON_CACHE_KEY = :__nitro_request_json
const REQUEST_FORM_CACHE_KEY = :__nitro_request_form
const REQUEST_INPUT_CACHE_KEY = :__nitro_request_input
const REQUEST_FILES_CACHE_KEY = :__nitro_request_files
const REQUEST_POST_CACHE_KEY = :__nitro_request_post
const REQUEST_CONTEXT_KEY = :__nitro_app_context

# One implementation, in `Types` (#38): it probes the raw `HTTP.RequestContext` instead
# of `req.context`, so a cache miss no longer allocates the metadata `Dict` just to look
# for a key that is not there. The body-parser caches below (`getjson`, `getform`, …)
# get that saving for free by sharing it.
using .Types: request_cache!

function merge_request_input!(merged::Dict{String,Any}, source)
    if source isa AbstractDict
        for (key, value) in pairs(source)
            merged[string(key)] = value
        end
    end
    return merged
end

const REQUEST_MULTIPART_CACHE_KEY = :__nitro_request_multipart

"""
Parse the `multipart/form-data` body once per request and cache the raw result, so that
[`getfiles`](@ref) and [`getpost`](@ref) can both read it without re-parsing (and
re-reading) the body.
"""
function request_multipart(req::HTTP.Request)
    return request_cache!(req, REQUEST_MULTIPART_CACHE_KEY) do
        Types.multipartbody(req)
    end
end

# `getparams(req)` is `nothing` until the router populates it, and `merge_request_input!` above
# silently skips a non-`AbstractDict` source — so a merge performed before the router ran
# produces an input map with the path params missing, and caching that unconditionally hands
# every later reader the truncated version. A middleware calling the public `payload(req)`, or
# a guard reading `payload(req)["tenant"]`, was enough to do it.
#
# That fails *silently* with wrong data rather than loudly, which is the worse shape, so the
# cached merge is invalidated exactly once: if the value was built while path params were
# absent and they have since appeared, it is rebuilt and then pinned. `pathparams` solves the
# same transient-state problem by refusing to cache the `nothing` (see `src/types.jl`); this
# one cannot, because a route with *no* path parameters leaves `getparams(req) === nothing`
# permanently, and gating on that would disable this cache for every such route.
const REQUEST_INPUT_ROUTED_KEY = :__nitro_request_input_routed

function request_input(req::HTTP.Request) :: Dict{String,Any}
    ctx = getfield(req, :context)
    params = Types.pathparams(req)
    if haskey(ctx, REQUEST_INPUT_CACHE_KEY) &&
       (params === nothing || haskey(ctx, REQUEST_INPUT_ROUTED_KEY))
        return ctx[REQUEST_INPUT_CACHE_KEY] :: Dict{String,Any}
    end
    merged = Dict{String,Any}()
    merge_request_input!(merged, Types.queryvars(req))
    merge_request_input!(merged, getjson(req))
    merge_request_input!(merged, getform(req))
    merge_request_input!(merged, getpost(req))
    merge_request_input!(merged, params)
    ctx[REQUEST_INPUT_CACHE_KEY] = merged
    params === nothing || (ctx[REQUEST_INPUT_ROUTED_KEY] = true)
    return merged
end

"""
    getparams(req::HTTP.Request) -> Dict{String, String}

Returns the path parameters for the request, **percent-decoded exactly once**.

HTTP.jl's router hands over raw, still-encoded segments; the single decode happens in
`Types.pathparams`, which every path-parameter consumer goes through — this accessor, scalar
handler parameters, and the `Path{T}` extractor. They therefore all observe the same value.
Query parameters ([`getquery`](@ref)) are decoded once by `HTTP.queryparams` for the same
reason. See #70.

Returns the **same `Dict` for the lifetime of the request** — it is decoded once and cached
(#38), so the result is a live handle, not a snapshot. Mutating it *does* change what a later
call returns, and is visible to [`payload`](@ref) and to every parameter binding that has not
run yet. Treat it as read-only; pass values down a request through `req.context` instead.

This matches [`getjson`](@ref) and [`getform`](@ref), which have always been memoized this
way. It used to return a fresh `Dict` per call, which meant a handler with N path parameters
re-decoded the whole table N times.

A malformed escape (`/x/%ZZ`, a trailing `%`) or a sequence decoding to invalid UTF-8 raises
`ValidationError`, which the error handler reports as `400 Bad Request` — not a `500`.
"""
getparams(req::HTTP.Request) = Types.pathparams(req)

"""
    getquery(req::HTTP.Request) -> Dict{String, String}

Returns the query parameters for the request.

Parsed once per request and cached (#38), so this returns the **same `Dict`** on every call —
a live handle, not a snapshot. Treat it as read-only: a mutation is visible to
[`payload`](@ref) and to any query-parameter binding that has not run yet.
"""
getquery(req::HTTP.Request) = Types.queryvars(req)

"""
    getjson(req::HTTP.Request) -> Any

Returns the parsed JSON request body, or `nothing` when the body is empty or malformed.

Parsed **once per request and cached**, so reading it twice is free and both reads return the
same object — a live handle, not a snapshot. This is the accessor handler code wants.

Contrast [`json(req)`](@ref), the body *parser*: it re-reads and re-parses the body on every
call, takes `kwargs`, has a typed `json(req, T)` form, and also works on an `HTTP.Response`.
The relationship mirrors `getparams(req)` (cached, decoded) versus `HTTP.getparams(req)` (raw).
"""
getjson(req::HTTP.Request) = request_cache!(req, REQUEST_JSON_CACHE_KEY) do
    Types.jsonbody(req)
end

"""
    getform(req::HTTP.Request) -> Dict{String, String}

Returns the parsed urlencoded form body, or an empty `Dict` when the body is empty or is not
form-encoded. A `multipart/form-data` body is **not** parsed here — use [`getpost`](@ref) and
[`getfiles`](@ref) for those.

Parsed **once per request and cached**, like [`getjson`](@ref). [`formdata(req)`](@ref) is the
uncached parser underneath it.
"""
getform(req::HTTP.Request) = request_cache!(req, REQUEST_FORM_CACHE_KEY) do
    Types.formbody(req)
end

"""
    getfiles(req::HTTP.Request) -> Dict{String, Union{FormFile, Vector{FormFile}}}

Returns the **file parts** of a `multipart/form-data` body — Django's `request.FILES`. Text
fields are excluded; read those with [`getpost`](@ref).

Returns an empty `Dict` for a non-multipart or unparseable body. The body is parsed once per
request and shared with `getpost`, so reading both costs one parse.

Note this is a *filtered view*: [`multipart(req)`](@ref) returns files and text fields
together, so it is not a drop-in substitute.
"""
getfiles(req::HTTP.Request) = request_cache!(req, REQUEST_FILES_CACHE_KEY) do
    parsed = request_multipart(req)
    Dict{String, Union{FormFile, Vector{FormFile}}}(
        k => v for (k, v) in parsed
        if v isa FormFile || v isa Vector{FormFile}
    )
end

"""
    getpost(req::HTTP.Request) -> Dict{String, Union{String, Vector{String}}}

Returns the **text fields** of a `multipart/form-data` body — Django's `request.POST`. File
parts are excluded; read those with [`getfiles`](@ref).

Returns an empty `Dict` for a non-multipart or unparseable body. The body is parsed once per
request and shared with `getfiles`, so reading both costs one parse.

Note this is a *filtered view*: [`multipart(req)`](@ref) returns files and text fields
together, so it is not a drop-in substitute.
"""
getpost(req::HTTP.Request) = request_cache!(req, REQUEST_POST_CACHE_KEY) do
    parsed = request_multipart(req)
    Dict{String, Union{String, Vector{String}}}(
        k => v for (k, v) in parsed
        if v isa String || v isa Vector{String}
    )
end

# HTTP.jl v1 shipped `queryparams(::Request)` / `queryparams(::Response)`; v2 only provides
# the URIs `queryparams(::AbstractString)` / `(::URI)`. Re-add the message overloads (which
# Nitro re-exports) so existing call sites keep working. A `Response` resolves its query
# from the linked request, returning `nothing` when there is none.
HTTP.queryparams(req::HTTP.Request) = Types.queryvars(req)
function HTTP.queryparams(res::HTTP.Response)
    linked = res.request
    return linked === nothing ? nothing : Types.queryvars(linked)
end

"""
    getsession(req::HTTP.Request) -> Union{Dict{String,Any}, Nothing}

Returns the session dictionary from the request context, if present.
"""
getsession(req::HTTP.Request) = Base.get(req.context, :session, nothing)

"""
    setsession!(req::HTTP.Request, val::Dict{String,Any})

Assigns the session dictionary to the request context.
"""
setsession!(req::HTTP.Request, val) = (req.context[:session] = val)

"""
    getuser(req::HTTP.Request) -> Any

Returns the authenticated user attached to the request context by an auth middleware, or
`nothing` when the request is unauthenticated.

**The type is deliberately open.** `BearerAuth`/`CookieAuthMiddleware` store whatever their
validator returned: `jwt_validator` without a `user_validator` stores the [`Principal`](@ref),
but with one it stores the *application's* user object and the `Principal` moves to
`req.context[:auth_claims]`. A custom validator may return any identity at all, with one
restriction: `nothing`, `missing`, a `Bool`, `""` and an empty dict are *not* identities. The
auth middleware answers those with a `401` and never stores them here. Guards
(`login_required`, `role_required`, …) do their own normalization; this accessor does not —
in particular the claim guards fall through to `req.context[:auth_claims]` when what is
stored here is not dict-like, so a struct user still authorizes on its verified claims.

`SessionMiddleware` populates the session, not the user — see [`getsession`](@ref).
"""
getuser(req::HTTP.Request) = Base.get(req.context, :user, nothing)

"""
    getip(req::HTTP.Request) -> Union{Sockets.IPAddr, Nothing}

Returns the caller's IP address from the request context, if present.

The address is **canonical**: a dual-stack listener that reports an IPv4 client as
`::ffff:203.0.113.7` is seeded as `203.0.113.7`, so one host has one spelling whether it arrived
directly or through a proxy (#66). Canonicalization happens where `serve` reads the socket, not in
middleware, so it applies with or without `ExtractIP` in the pipeline — and, for the same reason,
it is a guarantee about what *Nitro* seeds. A custom middleware calling `setip!` can write
any address it likes, including a non-canonical one.
"""
getip(req::HTTP.Request) = Base.get(req.context, :ip, nothing)

"""
    setip!(req::HTTP.Request, val::Sockets.IPAddr)

Assigns the caller's IP address to the request context.
"""
setip!(req::HTTP.Request, val) = (req.context[:ip] = val)

"""
    getpeerip(req::HTTP.Request) -> Union{Sockets.IPAddr, Nothing}

Returns the address of the socket that actually connected, as opposed to the client address
`getip` reports.

The two differ only when `ExtractIP` resolved the client from a forwarding header: it records the
socket peer here before overwriting `getip(req)`. Without `ExtractIP` in the pipeline the two are
the same value, because `serve` seeds the request context from the real TCP connection — in the
same canonical form `getip` documents, since the seed is where that form is decided.

Use it to tell a proxied request from a direct one when auditing — that distinction is what makes
an access log usable after an incident, since a forged forwarding header changes `getip` but can
never change the socket peer. Note that a custom middleware calling `setip!` directly, rather
than through `ExtractIP`, overwrites `getip` without recording a peer here.
"""
getpeerip(req::HTTP.Request) = Base.get(req.context, :peer_ip, getip(req))

"""
    getcontext(req::HTTP.Request) -> Union{Any, Nothing}

Returns the application context payload for the request — the object passed to
`serve(context = ...)` — or `nothing` when no context was configured.

This is the request-side counterpart to declaring a `Context{T}` handler parameter:
it lets handlers and the business logic they call reach the typed application config
from `req` alone, without threading a `Context` argument through every signature.

```julia
serve(context = AppConfig(...))

function handler(req)
    cfg = getcontext(req)        # ::AppConfig (untyped at the call site)
    cfg.host
end
```

Use [`getcontext(req, T)`](@ref) when you want the value statically typed as `T`.

!!! warning "Prefer the typed form on the request path"
    The server's app context is stored as `Ref{Any}` and can be reassigned after route
    registration by `serve(context = ...)`, so its payload type is genuinely unknown
    when a route is registered and this accessor can only return `Any`. Every field
    access on the result is therefore a dynamic `getfield`, once per request — the one
    remaining `Any` on the parameter-binding path after #37.

    `internalrequest(context = ...)` no longer reassigns that `Ref` — it stamps the
    override onto the request instead, because writing the process-shared cell raced
    the multithreaded `serve` pipeline (#31). It is not a source of type instability
    here either way: the carrier is `Ref{Any}` regardless of who set it.

    In a handler or middleware that runs per request, reach for
    `getcontext(req, AppConfig)` instead: the `::T` assertion is a function barrier,
    so everything downstream of it infers concretely (nitro-core §7). Keep this
    untyped form for scripts, tests, and one-off inspection. Making the type static
    rather than asserted means parameterizing the context carrier itself, which is
    [#31](https://github.com/PingoLee/Nitro.jl/issues/31).
"""
function getcontext(req::HTTP.Request)
    ctx = request_app_context(req)
    return ctx isa Context ? ctx.payload : nothing
end

# The app-context CARRIER for this request — the `Context{T}` wrapper itself, not its
# payload — or `missing` when none was configured.
#
# `missing` rather than `nothing` on purpose: this is the request-side replacement for
# reading `App.app_context[]`, whose empty value is `Ref{Any}(missing)`
# (src/context.jl). Keeping the sentinel identical is what lets the parameter-binding
# strategies and `extract` switch over without touching their own emptiness tests.
#
# THIS IS THE SINGLE SOURCE OF TRUTH for which app context a request sees (#31). Nothing
# downstream of the pipeline's outermost layer may read `ctx.app_context[]` again: that cell
# is process-shared, `serve()` dispatches on `Threads.@spawn` (nitro-core §2), and
# `internalrequest(context = ...)` used to swap it mid-flight — so a concurrent request got
# stamped with another caller's tenant config. Read the request instead; it cannot race.
request_app_context(req::HTTP.Request) = Base.get(req.context, REQUEST_CONTEXT_KEY, missing)

"""
    getcontext(req::HTTP.Request, ::Type{T}) -> T

Returns the application context payload typed as `T`, so field access is statically
typed (`getcontext(req, AppConfig).host`). Throws an `ArgumentError` when no context
was configured, and a `TypeError` when the payload is not a `T`.

**This is the form to use on the request path.** The `::T` assertion is a function
barrier: it converts the single `Any` the context carrier forces (see
[`getcontext(req)`](@ref)) into a concrete type, so the handler body and everything it
calls infer normally instead of dispatching dynamically on every field access.

```julia
function handler(req)
    cfg = getcontext(req, AppConfig)   # ::AppConfig, statically
    cfg.host                           # concrete getfield, not a dynamic lookup
end
```
"""
function getcontext(req::HTTP.Request, ::Type{T}) where {T}
    ctx = request_app_context(req)
    ctx isa Context || throw(ArgumentError(
        "No application context on request; pass `context = ...` to `serve()`."))
    return ctx.payload::T
end

"""
    payload(req::HTTP.Request) -> Dict{String, Any}

Returns a merged dictionary containing the JSON body, form data, multipart text
fields, and query parameters from the incoming request.
"""
function payload(req::HTTP.Request)::Dict{String, Any}
    return request_input(req)
end
