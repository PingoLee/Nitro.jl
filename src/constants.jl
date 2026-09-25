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
a stuck or hostile connection instead of keeping it forever.

It bounds the head only. Once the head is parsed Nitro clears the deadline, so a slow upload is
not cut by it — the Go semantics. Set `read_timeout` to bound the body too.
"""
const DEFAULT_READ_HEADER_TIMEOUT_SECONDS :: Float64 = 120.0

"""
Default for `serve(idle_timeout = …)`: seconds an HTTP/2 connection with no open stream is kept
before it is closed (#316).

Kept equal to [`DEFAULT_READ_HEADER_TIMEOUT_SECONDS`](@ref Nitro.Core.Constants.DEFAULT_READ_HEADER_TIMEOUT_SECONDS)
on purpose. On HTTP/1.1 HTTP.jl 2.7 overwrites this deadline with the header deadline before it
can fire, so on the connections a browser or a reverse proxy actually opens, the header timeout
*is* the idle limit. This value applies to cleartext HTTP/2, and would take over on HTTP/1.1 if
HTTP.jl stops overwriting it — equal values mean neither case changes behavior.
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
    REQUEST_MAX_FIELDS :: ScopedValue{Int64}

The field cap in force for the request being handled: `serve(max_fields = …)`, bound by the
pipeline's outermost layer for the request's whole dynamic extent (and by `internalrequest`, which
runs the same pipeline). Outside a request it is [`DEFAULT_MAX_FIELDS`](@ref), so a parser called
directly -- in a test, a script -- is still capped. `0` means unlimited.

A `ScopedValue` rather than a field on the request: the parsers that enforce it (`Util`'s body
parsers, `Types`' query accessor) load before `App` exists, and reading a typed scoped value keeps
`Any` out of the hot path. It is the same carrier as `SERVING_APP` (#308).
"""
const REQUEST_MAX_FIELDS = ScopedValue{Int64}(DEFAULT_MAX_FIELDS)

end
