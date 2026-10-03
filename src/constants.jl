module Constants
using HTTP
using Base.ScopedValues: ScopedValue


export PACKAGE_DIR,
    GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS, CONNECT, TRACE,
    HTTP_METHODS,
    WEBSOCKET, STREAM,
    SPECIAL_METHODS, METHOD_ALIASES, TYPE_ALIASES,
    SHUTDOWN_TIMEOUT_SECONDS,
    DEFAULT_READ_HEADER_TIMEOUT_SECONDS, DEFAULT_IDLE_TIMEOUT_SECONDS,
    DEFAULT_MAX_BODY_BYTES, DEFAULT_MAX_FIELDS

# Generate a reliable path to our package directory
const PACKAGE_DIR = @__DIR__


# HTTP Methods
const GET       :: String   = "GET"
const POST      :: String   = "POST"
const PUT       :: String   = "PUT"
const DELETE    :: String   = "DELETE"
const PATCH     :: String   = "PATCH"
const HEAD      :: String   = "HEAD"
const OPTIONS   :: String   = "OPTIONS"
const CONNECT   :: String   = "CONNECT"
const TRACE     :: String   = "TRACE"

const HTTP_METHODS :: Set{String} = Set([GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS, CONNECT, TRACE])

# Special Methods
const WEBSOCKET :: String = "WEBSOCKET"
const STREAM    :: String = "STREAM"

const SPECIAL_METHODS :: Set{String} = Set([WEBSOCKET, STREAM])

# Sepcial Method Aliases
const METHOD_ALIASES :: Dict{String,String} = Dict(
    WEBSOCKET   => GET,
    STREAM      => GET
)

const TYPE_ALIASES :: Dict{String, Type} = Dict(
    WEBSOCKET   => HTTP.WebSockets.WebSocket,
    STREAM      => HTTP.Stream
)

"""
Default ceiling, in seconds, on `terminate()`'s graceful drain before Nitro force-closes
whatever connections are left.

Ten seconds is far more than a healthy shutdown needs — the drain is normally milliseconds,
since it only has to reap idle keep-alive connections — while still bounding a pathological
shutdown to something a CI job survives. Override per server with `serve(shutdown_timeout = …)`
or per call with `terminate(timeout = …)`.

`terminate` runs the lifecycle shutdown hooks first, so a blocking hook adds to this. The one in
the box is the worker drain (`Nitro.Workers.WORKER_DRAIN_TIMEOUT_SECONDS`, 5 seconds), which is
sized at half this figure precisely because the two add up.
"""
const SHUTDOWN_TIMEOUT_SECONDS :: Float64 = 10.0

"""
Default for `serve(read_header_timeout = …)`: seconds a connection has to deliver a complete
request head before the server answers **408** and closes it (#316).

HTTP.jl disables every server timeout by default, so without this a client that opens a connection
and trickles header bytes (Slowloris), or simply goes silent, holds its socket and its task
forever. Go's `net/http` guidance is the same: always set `ReadHeaderTimeout`.

**Why 120 seconds rather than Go's usual 5–10.** On HTTP/1.1, HTTP.jl re-arms this deadline
before *every* request head, including the wait between two requests on a keep-alive
connection, so it is also the keep-alive idle limit (`idle_timeout` never gets a chance to apply
there). A backend that drops idle connections before its proxy does races the proxy's reuse of
them: nginx upstream pools and AWS ALB both idle out at 60 seconds, and a backend below that
produces sporadic `502`s. 120 seconds keeps the proxy the side that closes first, and still bounds
a stuck or hostile connection instead of keeping it forever. That coupling is an HTTP.jl behavior,
reported upstream as
[JuliaWeb/HTTP.jl#1381](https://github.com/JuliaWeb/HTTP.jl/issues/1381); once a release keeps
the idle and header deadlines apart the way Go does, this default can drop to Go's usual range.

It bounds the head only. Once the head is parsed Nitro clears the deadline, so a slow upload is
not cut by it — the Go semantics. Set `read_timeout` to bound the body too.
"""
const DEFAULT_READ_HEADER_TIMEOUT_SECONDS :: Float64 = 120.0

"""
Default for `serve(idle_timeout = …)`: seconds an idle connection is kept before it is closed
(#316).

Kept equal to [`DEFAULT_READ_HEADER_TIMEOUT_SECONDS`](@ref Nitro.Core.Constants.DEFAULT_READ_HEADER_TIMEOUT_SECONDS)
on purpose. HTTP.jl 2.7 overwrites this deadline with the header deadline before it can fire, so
the header timeout *is* the idle limit. This value applies only when both
`read_header_timeout` and `read_timeout` are `0`: then nothing overwrites it, and it bounds the
wait for the next request's head instead. Either way Nitro clears it once a head has arrived, so
it never reaches into a request body. (It was also HTTP/2's idle limit, until #375 took
cleartext HTTP/2 off Nitro's listeners.)
"""
const DEFAULT_IDLE_TIMEOUT_SECONDS :: Float64 = 120.0

"""
Default ceiling, in bytes, on a buffered request body before `serve()` answers **413** instead
of reading it.

64 MiB is not a number Nitro invented: it is `HTTP._SERVER_DEFAULT_MAX_BODY_BYTES`, the cap the
bundled fork already enforces on its ordinary `serve!` path. Nitro serves through `HTTP.listen!`
with a raw stream handler, which the fork documents as "application-managed large uploads" and
therefore leaves entirely uncapped — so this constant restores a guarantee that was already being
made one layer down, rather than inventing a new policy. Peer defaults sit lower (Plug 8 MB,
ASP.NET Core 30 MB, Express 100 KB), but matching the fork keeps the migration story to "the
ceiling you already had", which is the smallest possible break.

Override per server with `serve(max_body_bytes = …)`, or pass `nothing` to buffer without a
ceiling. A reverse proxy should still cap bodies upstream — rejecting before the request reaches
Julia is strictly better, and this is the floor for deployments that have no proxy.

Internally the limit travels as an `Int64` with **`0` meaning unlimited** — again the fork's own
convention — so the per-request check stays a plain integer comparison on the hot path instead of
branching on a `Union{Nothing, Int64}` (nitro-core §7). `serve` does that normalization once.
"""
const DEFAULT_MAX_BODY_BYTES :: Int64 = 64 * 1024 * 1024

"""
Default ceiling on the number of fields one request may carry, per source, before Nitro answers
**400**: query parameters, urlencoded form fields, multipart parts, and the keys of a JSON body
(counted across the whole document, every object included).

Byte caps bound how much a request can send, not how many keys it packs into it, and every one
of those sources becomes a hash table keyed by strings the client chose. Julia's `hash(::String)`
uses a fixed seed, so a client that can pick its keys can pick colliding ones. 1000 is Django's
`DATA_UPLOAD_MAX_NUMBER_FIELDS`, and Express's `urlencoded` `parameterLimit`; a form or JSON body
with more fields than that is almost always a bug or an attack.

Override per server with `serve(max_fields = …)`; `0` means unlimited (#327).
"""
const DEFAULT_MAX_FIELDS :: Int64 = 1000

"""
    AbstractApp

The supertype of [`App`](@ref), declared here so [`RequestScope`](@ref) can name the serving app
without `Any`. `Constants` loads before `App` exists (src/core.jl).
"""
abstract type AbstractApp end

"""
    RequestScope(app, max_fields)

What the pipeline binds for one request's dynamic extent, as the single value of
[`REQUEST_SCOPE`](@ref):

- `app` -- the `App` whose pipeline is running the request, `nothing` outside one. Read it through
  `Nitro.Core.serving_app()`, which narrows it back to `App`.
- `max_fields` -- that app's own `service.max_fields` cell, shared rather than copied, so
  `serve(max_fields = …)` is seen by every pipeline already built. Read it through
  [`request_max_fields`](@ref).

**Mutable only so that it is a heap object**, both fields `const`. A scope stores its values in a
`PersistentDict{ScopedValue, Any}`, so an immutable value is boxed on every insert. One instance is
built per pipeline (`_app_context_seed`) and every request binds that same object, which costs one
insert and no box (#444). It used to be two `ScopedValue`s (`SERVING_APP`, `REQUEST_MAX_FIELDS`),
an `App` and an `Int64`: two inserts and two boxes per request.
"""
mutable struct RequestScope
    # `Union{…, Nothing}` spelled out: `Nullable` lives in `Types`, which loads after this.
    const app        :: Union{AbstractApp, Nothing}
    const max_fields :: Base.RefValue{Int64}
end

"""
    REQUEST_SCOPE :: ScopedValue{RequestScope}

The request being handled, bound by the pipeline's outermost layer (`_app_context_seed`) for the
request's whole dynamic extent: every middleware, the handler, and any task the handler spawns.
`internalrequest` runs the same pipeline, so it binds it too.

Outside a request it holds no app and [`DEFAULT_MAX_FIELDS`](@ref), so a parser called directly --
in a test, a script -- is still capped.

It carries two things that cannot reach their readers through arguments:

- **The serving app**, for the argument-less `get_cookie(req, …)`/`set_cookie!(res, …)` (#308). They
  used to read the process-wide `CONTEXT[]`, so an app built with an explicit `App` -- the
  recommended handle since #31 -- silently wrote plaintext cookies and trusted raw client values,
  because the key lived on the serving app and the helpers looked somewhere else. A `Response`
  carries no request, so `set_cookie!(res, …)` cannot find the serving app from its arguments; a
  task-scoped binding is the one carrier both helpers can read. This is Spring's
  `RequestContextHolder`, with Julia's `ScopedValue` in place of a thread-local, which is what keeps
  it correct across `Threads.@spawn`.
- **The field cap** (#327). The parsers that enforce it (`Util`'s body parsers) load before `App`
  exists, so they read the cap from here rather than from the app.

A background worker run deliberately does not inherit it: `_spawn_detached` clears the dynamic
scope (#209).
"""
const REQUEST_SCOPE = ScopedValue{RequestScope}(RequestScope(nothing, Ref{Int64}(DEFAULT_MAX_FIELDS)))

"""
    request_max_fields() -> Int64

The field cap in force for the request being handled: `serve(max_fields = …)` inside a request,
[`DEFAULT_MAX_FIELDS`](@ref) outside one. `0` means unlimited (#327).
"""
request_max_fields()::Int64 = REQUEST_SCOPE[].max_fields[]

end
