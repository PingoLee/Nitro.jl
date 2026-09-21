module Constants
using HTTP


export PACKAGE_DIR,
    GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS, CONNECT, TRACE,
    HTTP_METHODS,
    WEBSOCKET, STREAM,
    SPECIAL_METHODS, METHOD_ALIASES, TYPE_ALIASES,
    SHUTDOWN_TIMEOUT_SECONDS,
    DEFAULT_MAX_BODY_BYTES

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

end
