module Constants
using HTTP


export PACKAGE_DIR,
    GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS, CONNECT, TRACE,
    HTTP_METHODS,
    WEBSOCKET, STREAM,
    SPECIAL_METHODS, METHOD_ALIASES, TYPE_ALIASES,
    SHUTDOWN_TIMEOUT_SECONDS

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
"""
const SHUTDOWN_TIMEOUT_SECONDS :: Float64 = 10.0

end