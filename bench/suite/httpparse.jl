# HTTP/1 request-head parse: what HTTP.jl's server pays per request on the connection task (#462).
#
# `_serve_h1_conn!` calls `read_request` on a `_ConnReader` BEFORE the stream handler runs, so
# the request line and every header are parsed on HTTP.jl's connection task -- which lives on
# the `:interactive` pool, one thread under `julia -t N`. Nitro's per-request `Threads.@spawn`
# moves the handler off that thread; it cannot move the parse. This group measures the parse in
# isolation, so its share of the interactive thread can be argued from a number.
#
# Two readers, deliberately:
#   connreader_*  the server's path. `_ConnReader` (src/http_transport.jl) scans its buffer for
#                 the line end and builds ONE String per line (`unsafe_string`); `Headers` is
#                 pre-sized from `_upcoming_header_keys`. Per header, what is left is the
#                 key/value `String(SubString(...))` copies in `_read_headers` (src/http1.jl) and
#                 `canonical_header_key`, which for a non-canonical name (`host`, `accept`)
#                 builds a `Vector{Char}`, a slice and a String before the common-header table
#                 is consulted.
#   iobuffer_*    the generic `IO` path (`read(io, UInt8)` per byte, a `push!` vector per line).
#                 The server never runs it. It is here because #462's Finding 2 was written
#                 against it; the pair shows how far the two are apart.
#
# The `_ConnReader` needs a real `TCP.Conn` (an immutable fd wrapper -- `nothing` does not
# type-check), so one loopback pair is opened at include time the way HTTP's own
# test/http1_wire_tests.jl does. The head is placed in the reader's buffer directly and the
# pointers are reset before every parse: the whole head ends in `\r\n\r\n`, there is no body, so
# `_fill_conn_reader!` is never reached and the socket is never read. `unsafe_string` copies, so
# reusing the buffer is safe.
#
# `HTTP._ConnReader(buf, next, stop, conn)` is internal and pinned to HTTP 2.8.0 (`~2.8` in
# Project.toml); `read_request` and `canonical_header_key` are public. If the struct changes
# shape, this file is what breaks, which is the intent.
SUITE["httpparse"] = BenchmarkGroup()

const _TCP = HTTP.TCP

function _httpparse_conn_pair()
    listener = _TCP.listen(_TCP.loopback_addr(0); backlog = 16)
    addr = _TCP.addr(listener)::_TCP.SocketAddrV4
    t = Task(() -> _TCP.accept(listener))
    schedule(t)
    client = _TCP.connect(_TCP.loopback_addr(Int(addr.port)))
    return fetch(t)::_TCP.Conn, client, listener
end

# Kept alive for the process: the server end is what every reader below points at.
const HTTPPARSE_SERVER_CONN, HTTPPARSE_CLIENT_CONN, HTTPPARSE_LISTENER = _httpparse_conn_pair()

head_bytes(lines::Vector{String}) = collect(codeunits(join(lines, "\r\n") * "\r\n\r\n"))
head_reader(bytes::Vector{UInt8}) = HTTP._ConnReader(copy(bytes), 1, length(bytes), HTTPPARSE_SERVER_CONN)

# Reset the buffered head and parse it. The two assignments are the whole per-iteration setup
# and allocate nothing, so they stay inside the measured body rather than forcing `evals=1`.
function parse_buffered_head!(r::HTTP._ConnReader, n::Int)
    r.next = 1
    r.stop = n
    return HTTP.read_request(r)
end

parse_iobuffer_head(bytes::Vector{UInt8}) = HTTP.read_request(IOBuffer(bytes))

# ── Request heads ───────────────────────────────────────────────────────────
#
# `oha`: what the load generator in bench/socket/run.sh sends -- hyper writes header names in
# lower case, and `--disable-compression` drops `accept-encoding`. Replace with a captured head
# if yours differs (`nc -l 127.0.0.1 8099 &` then `oha -n 1 http://127.0.0.1:8099/plaintext`).
const HEAD_MINIMAL = ["GET /plaintext HTTP/1.1", "Host: 127.0.0.1:8080"]
const HEAD_OHA = ["GET /plaintext HTTP/1.1", "accept: */*", "host: 127.0.0.1:8080", "user-agent: oha/1.4.6"]

# Chrome 131 over HTTP/1.1 to a loopback origin, as sent: 13 names in canonical case, the three
# client-hint names in lower case. `_canonical` writes all 16 canonically; `_lower` writes all 16
# in lower case, the shape an HTTP/2-habituated proxy or any hyper/Go client produces.
const HEAD_CHROME = [
    "GET /plaintext HTTP/1.1",
    "Host: 127.0.0.1:8080",
    "Connection: keep-alive",
    "Cache-Control: max-age=0",
    "sec-ch-ua: \"Chromium\";v=\"131\", \"Not_A Brand\";v=\"24\"",
    "sec-ch-ua-mobile: ?0",
    "sec-ch-ua-platform: \"Windows\"",
    "Upgrade-Insecure-Requests: 1",
    "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
    "Sec-Fetch-Site: none",
    "Sec-Fetch-Mode: navigate",
    "Sec-Fetch-User: ?1",
    "Sec-Fetch-Dest: document",
    "Accept-Encoding: gzip, deflate, br, zstd",
    "Accept-Language: en-US,en;q=0.9,pt-BR;q=0.8",
]

function _recase_names(lines::Vector{String}, f)
    out = copy(lines)
    for i in Iterators.drop(eachindex(out), 1)   # skip the request line
        line = out[i]
        sep = findfirst(':', line)
        out[i] = f(line[1:prevind(line, sep)]) * line[sep:end]
    end
    return out
end
_canonical_name(name::AbstractString) = HTTP.canonical_header_key(name)
const HEAD_CHROME_CANONICAL = _recase_names(HEAD_CHROME, _canonical_name)
const HEAD_CHROME_LOWER = _recase_names(HEAD_CHROME, lowercase)

# Per-header slope: N identical-shape headers whose names are canonical but not in the common
# table (`X-Bench-Nn`, scan + table miss) or lower-case (`x-bench-nn`, the allocating path).
headers_n(n::Int, name::String) =
    vcat(["GET /plaintext HTTP/1.1", "Host: 127.0.0.1:8080"], ["$name-$i: value-$i" for i in 1:n])

const HEADS = Pair{String,Vector{String}}[
    "minimal" => HEAD_MINIMAL,
    "oha" => HEAD_OHA,
    "chrome" => HEAD_CHROME,
    "chrome_canonical" => HEAD_CHROME_CANONICAL,
    "chrome_lower" => HEAD_CHROME_LOWER,
    "headers_canon_1" => headers_n(1, "X-Bench"),
    "headers_canon_6" => headers_n(6, "X-Bench"),
    "headers_canon_12" => headers_n(12, "X-Bench"),
    "headers_lower_1" => headers_n(1, "x-bench"),
    "headers_lower_6" => headers_n(6, "x-bench"),
    "headers_lower_12" => headers_n(12, "x-bench"),
]

for (name, lines) in HEADS
    bytes = head_bytes(lines)
    reader = head_reader(bytes)
    n = length(bytes)
    # Guard the premise once, at include time: the buffered parse must succeed without ever
    # reaching the socket, and both readers must agree on what they parsed.
    buffered = parse_buffered_head!(reader, n)
    generic = parse_iobuffer_head(bytes)
    buffered.target == generic.target == "/plaintext" || error("httpparse: $name parsed wrong target")
    length(buffered.headers) == length(generic.headers) == length(lines) - 1 ||
        error("httpparse: $name header count mismatch")
    SUITE["httpparse"]["connreader_$name"] = @benchmarkable parse_buffered_head!($reader, $n)
    SUITE["httpparse"]["iobuffer_$name"] = @benchmarkable parse_iobuffer_head($bytes)
end

# ── canonical_header_key alone ──────────────────────────────────────────────
#
# Four shapes: common + canonical (scan, table hit, returns the cached string), common + lower
# (`Vector{Char}` + slice + String, then table hit), uncommon + canonical (scan, table miss,
# returns the input), uncommon + lower (the allocating path, table miss).
for (label, key) in ("common_canonical" => "Host", "common_lower" => "host",
                     "uncommon_canonical" => "X-Request-Id", "uncommon_lower" => "x-request-id")
    SUITE["httpparse"]["canonical_key_$label"] = @benchmarkable HTTP.canonical_header_key($key)
end
