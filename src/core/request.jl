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

Returns the parsed JSON request body, or `nothing` when the body is empty or malformed —
including a body nested deeper than 512 arrays/objects, which is rejected before it is parsed
(#314) — or when the request's `Content-Type` is not JSON (`application/json` or
`application/*+json`; a missing header counts as not JSON). A cross-site page can send
`text/plain` or no type without a CORS preflight, so a body that does not declare itself JSON is
not read as JSON (#327) -- and so [`payload`](@ref) and `CSRFMiddleware`'s JSON token lookup,
which read through this accessor, do not see it either.

Parsed **once per request and cached**, so reading it twice is free and both reads return the
same object — a live handle, not a snapshot. This is the accessor handler code wants.

Contrast [`json(req)`](@ref), the body *parser*: it re-reads and re-parses the body on every
call, takes `kwargs`, has a typed `json(req, T)` form, and also works on an `HTTP.Response`.
The relationship mirrors `getparams(req)` (cached, decoded) versus `HTTP.getparams(req)` (raw).
"""
getjson(req::HTTP.Request) = request_cache!(req, REQUEST_JSON_CACHE_KEY) do
    Util.BodyParsers.is_json_media_type(HTTP.header(req, "Content-Type", "")) || return nothing
    Types.jsonbody(req)
end

"""
    getform(req::HTTP.Request) -> Dict{String, String}

Returns the parsed urlencoded form body, or an empty `Dict` when the body is empty, is not
form-encoded, or declares a `Content-Type` other than `application/x-www-form-urlencoded` (#345).
An untyped body is still read. A `multipart/form-data` body is **not** parsed here — use [`getpost`](@ref) and
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
    getprincipal(req::HTTP.Request) -> Union{Principal, Nothing}

Returns the verified token [`Principal`](@ref) that authenticated the request, or `nothing`.

Where [`getuser`](@ref) returns whatever the validator returned, this returns the token's own
`Principal`, in both flows. When a `user_validator` put the application's user object at
`req.context[:user]`, the token's `Principal` rides at `req.context[:auth_claims]` — and that slot
is read **first**, because the app's object may itself be a `Principal` (an enriched copy, say)
that was never verified against anything. Otherwise it is `req.context[:user]`, where
`jwt_validator` stores it when there is no `user_validator`. The auth middleware keeps the two
slots describing one authentication, so neither can be left over from another layer.

```julia
function import_batch(req)
    kid = getprincipal(req).kid   # the keyset-verified key id
    ...
end
```

`principal.kid` is set only when the token was verified against a [`JWTKeyset`](@ref Nitro.Auth.JWTKeyset)
— a `kid` header on a single-secret token is an unverified label and is never exposed — and
`principal.id` is the resolved identity. `nothing` means no token principal: an unauthenticated
request, a session-only one, or a custom validator that returned some other identity. Behind
[`kid_required`](@ref) the result is never `nothing`.
"""
function getprincipal(req::HTTP.Request)::Nullable{Principal}
    claims = Base.get(req.context, :auth_claims, nothing)
    claims isa Principal && return claims
    user = Base.get(req.context, :user, nothing)
    return user isa Principal ? user : nothing
end

"""
    getip(req::HTTP.Request) -> Union{Sockets.IPAddr, Nothing}

Returns the caller's IP address from the request context, if present.

The address is **canonical**: a dual-stack listener that reports an IPv4 client as
`::ffff:203.0.113.7` is seeded as `203.0.113.7`, so one host has one spelling whether it arrived
directly or through a proxy (#66). Canonicalization happens where `serve` reads the socket, not in
middleware, so it applies with or without `ExtractIP` in the pipeline — and, for the same reason,
it is a guarantee about what *Nitro* seeds. A custom middleware calling `setip!` can write
any address it likes, including a non-canonical one.

If `serve` cannot read the socket peer at all, it seeds the unspecified address `0.0.0.0`
and logs once. That address is never a trusted proxy, so no forwarding header is believed for
such a request (#404).
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

The two differ only when `ExtractIP` resolved the client from a forwarding header: the first
`ExtractIP` in the chain records the socket peer here before overwriting `getip(req)`, and a later
one never overwrites it (#330). Without `ExtractIP` in the pipeline the two are the same value,
because `serve` seeds the request context from the real TCP connection — in the same canonical
form `getip` documents, since the seed is where that form is decided.

Use it to tell a proxied request from a direct one when auditing — that distinction is what makes
an access log usable after an incident, since a forged forwarding header changes `getip` but can
never change the socket peer. Note that a custom middleware calling `setip!` directly, rather
than through `ExtractIP`, overwrites `getip` without recording a peer here.
"""
getpeerip(req::HTTP.Request) = Base.get(req.context, :peer_ip, getip(req))

"""
    route_missed(req::HTTP.Request) -> Bool

`true` when Nitro answered the request with "no route here": the router's 404 or 405, a static
mount's miss, the `404` for a path outside `serve(prefix = …)`, or the `400` for a request-target
no route could ever match (`//x`, dot segments). Meaningful once the response is known, so read it
in a post-response hook, such as `AccessLog`'s or `access_log_skip`'s `skip`:

```julia
AccessLog(sink; skip = (req, resp) -> route_missed(req))   # keep scanner probes out
```

It is `false` for everything else, **including** a request a guard or middleware refused on a
real route, and one refused before the router ran. Only a request the router looked up and found
nothing for is a miss, so an access log filtered on it never drops a denied login (#401). A route
that returns 404 itself is not a miss either.

The miss belongs to the method and target that missed. A middleware that gets a 404, rewrites
`req.target` (a trailing-slash or locale fallback) and is then served by a route reads as
**not** missed.
"""
route_missed(req::HTTP.Request)::Bool =
    Base.get(req.context, Types.ROUTE_MISS_KEY, nothing) == (req.method, req.target)

# Set at each place Nitro answers "no route" (see `Types.ROUTE_MISS_KEY`). It records WHICH request
# shape missed rather than a bare `true`, so a re-dispatch to a target a route then serves is not
# left reading as a miss -- without clearing anything on the matched path, which every request
# takes. Only a miss allocates the tuple.
_mark_route_miss!(req::HTTP.Request) =
    (req.context[Types.ROUTE_MISS_KEY] = (req.method, req.target); nothing)

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

# ── Cooperative cancellation (#466) ─────────────────────────────────────────────────────────────

const REQUEST_CANCEL_STATE_KEY = :__nitro_request_cancel_state

# How often `cancel_reason(req)` may ask the kernel whether the client is still there. Between two
# probes a check is a lookup in `req.context`, a clock read and two atomic loads, so a handler can
# poll it in a hot loop.
# 10 ms is well under any client's patience and well over a `recv` syscall's cost.
const CANCEL_PROBE_INTERVAL_NS = UInt64(10_000_000)

# Per request, created on the first `cancel_reason`/`cancel_requested` call and never before, so a
# handler that never asks pays nothing. Every field is atomic or `const`, but reaching it means a
# lookup in `req.context`, an unsynchronized `Dict`: hence "call it from the handler's task".
mutable struct _CancelState
    @atomic reason        :: Symbol
    @atomic next_probe_ns :: UInt64
    # The flag of the server run that is handling this request (`RequestScope`), captured on the
    # first call: the run's flag, not whatever scope a later call happens to run in.
    const shutting_down   :: Threads.Atomic{Bool}
    # `nothing` for a request with no socket of its own (`internalrequest`).
    const stream          :: Union{Nothing, HTTP.Stream}
end

function _cancel_state(req::HTTP.Request)::_CancelState
    return request_cache!(req, REQUEST_CANCEL_STATE_KEY) do
        stream = Base.get(req.context, :stream, nothing)
        _CancelState(:none, zero(UInt64), Constants.REQUEST_SCOPE[].shutting_down,
                     stream isa HTTP.Stream ? stream : nothing)
    end::_CancelState
end

# First cause wins, as for a worker run: a client that left before the deploy stays
# `:client_disconnected`.
function _settle_cancel!(state::_CancelState, reason::Symbol)::Symbol
    @atomicreplace state.reason :none => reason
    return @atomic state.reason
end

"""
    cancel_reason(req::HTTP.Request) -> Symbol

Why the server would like this request's handler to stop, or `:none`:

| Reason | What happened |
|---|---|
| `:client_disconnected` | The client closed or reset the connection; nobody will read the response |
| `:shutdown` | `terminate` has begun: the server is draining, and will force-close what is left after `shutdown_timeout` |

Nitro cannot stop a handler: Julia tasks cannot be killed, and throwing into a running one is
unsafe (#127). This is the cooperative alternative. A handler that runs long checks it, and
stops on its own:

```julia
function export_report(req)
    rows = Row[]
    for page in 1:npages
        if cancel_requested(req)
            # A deploy: the client is still there, so tell it to retry.
            cancel_reason(req) === :shutdown && return Res.status(503)
            # The client left: nobody reads this status, but the access log records it.
            return Res.status(499)
        end
        append!(rows, fetch_page(page))
    end
    return Res.json(rows)
end
```

**The first cause wins**, and a reason never resets.

**Cheap enough to poll in a loop.** Whether the client is still there is asked of the kernel
(a non-blocking peek at the socket) at most once every 10 ms. Between probes, a check is a lookup
in `req.context`, a clock read and two atomic loads, and allocates nothing. Nothing runs for a
handler that never asks.

**What it cannot see:**
- A client that half-closes its side (`shutdown(SHUT_WR)`) after sending reads as disconnected.
  Go's `net/http` treats it the same way.
- A pipelined next request on the same connection, already sent, hides a later disconnect.
- A connection that died without a FIN or a reset (a cable pulled) looks alive until the kernel
  gives up on it.
- `internalrequest` has no connection, so only `:shutdown` can fire.

Once the response is written, the client is no longer probed: the connection may already be
carrying the next request.

**Call it from the handler's own task.** Every check reads `req.context`, as the other
per-request accessors do, and `req.context` is not safe to read while another task writes to it:
another accessor's first call, or `setsession!`, does. Do not poll `req` from a task you spawn
while the handler goes on using it.

The same function answers for a background job: `cancel_reason(task_info::TaskInfo)` reports
why a worker run was asked to stop. See `Nitro.Workers.cancel_reason`.
"""
function cancel_reason(req::HTTP.Request)::Symbol
    state = _cancel_state(req)
    reason = @atomic state.reason
    reason === :none || return reason
    state.shutting_down[] && return _settle_cancel!(state, :shutdown)
    stream = state.stream
    stream === nothing && return :none
    now = time_ns()
    now < (@atomic state.next_probe_ns) && return :none
    @atomic state.next_probe_ns = now + CANCEL_PROBE_INTERVAL_NS
    _peer_gone(stream) && return _settle_cancel!(state, :client_disconnected)
    return :none
end

"""
    cancel_requested(req::HTTP.Request) -> Bool

`true` once the client has disconnected or the server has begun shutting down: exactly
`cancel_reason(req) !== :none`. See `cancel_reason(req)` for what each cause means, what the
check costs, and what it cannot see.
"""
cancel_requested(req::HTTP.Request)::Bool = cancel_reason(req) !== :none
