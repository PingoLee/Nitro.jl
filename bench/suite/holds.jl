# How long one call to a Nitro primitive holds its thread (#588). A request runs on a `:default`
# thread that Julia never preempts, so a primitive that computes for N ms without reaching a yield
# point holds that thread, and every request queued behind it, for N ms (#467). The number that
# matters here is the time per call at sizes an API actually sees; the issue's threshold for
# "nothing to do" is about 1 ms. Run these at one thread: they measure the hold, not throughput.
#
#   NITRO_BENCH_GROUPS=holds julia --project=bench --threads=1 bench/runbenchmarks.jl
#
# Every row builds its input in `setup` with `evals=1`, so a request's body cache or a consumed
# stream never carries over between samples.
#
# Each input is checked once at include time against the full result it must produce. A parser
# that rejects its input answers fast and quietly -- `json(req)` with `nothing`, `multipart(req)`
# with an empty `Dict` -- and a row timing that path would report a plausible, meaningless number.

SUITE["holds"] = BenchmarkGroup()

const _HOLDS_BP = Nitro.Core.Util.BodyParsers

# ── JSON: `Res.json`, `getjson`, `json(req, T)` ─────────────────────────────────────────────────
#
# `suite/json.jl`'s rows payload, scaled by row count. Each row serializes to ~40 bytes, so the
# names are nominal; `HOLDS_JSON_BYTES` holds the real sizes.
#
# The parse rows pass `max_fields = 0`. At the default cap (`DEFAULT_MAX_FIELDS`, 1000 keys) a
# body this shape is refused by `_check_json_depth` before it is parsed: 100 KB of three-key rows
# is about 7,500 keys. An app that accepts such bodies has raised the cap with
# `serve(max_fields = 0)`, which is what these rows measure. `BodyParsers.json(req)` is
# `getjson`'s parse without its per-request cache, depth and key scan (#540) included.
_holds_rows_json(n::Int) = JSON.json(Dict("rows" => [Dict("id" => i, "label" => "row-$i", "value" => i * 1.5)
                                                      for i in 1:n]))

const HOLDS_JSON = [(size, _holds_rows_json(n)) for (size, n) in (("100kb", 2_500),
                                                                   ("1mb", 25_000),
                                                                   ("10mb", 250_000))]
const HOLDS_JSON_BYTES = Dict(size => sizeof(body) for (size, body) in HOLDS_JSON)

for (size, body) in HOLDS_JSON
    bytes = Vector{UInt8}(body)
    rows = length(_HOLDS_BP._parse_json_bounded(bytes; max_fields = 0)["rows"])
    req = bench_request("POST", "/bench/json"; body = body)
    length(_HOLDS_BP.json(req; max_fields = 0)["rows"]) == rows ||
        error("holds: getjson_$size does not parse its body")
    req = bench_request("POST", "/bench/json"; body = body)
    length(_HOLDS_BP.json(req, BenchRows; max_fields = 0).rows) == rows ||
        error("holds: json_typed_$size does not bind its body")
    SUITE["holds"]["write_dict_$size"] = @benchmarkable Res.json(v) setup=(
        v = _HOLDS_BP._parse_json_bounded($bytes; max_fields = 0)) evals=1
    SUITE["holds"]["write_struct_$size"] = @benchmarkable Res.json(v) setup=(
        v = _HOLDS_BP._parse_json_bounded($bytes, BenchRows; max_fields = 0)) evals=1
    SUITE["holds"]["getjson_$size"] = @benchmarkable _HOLDS_BP.json(req; max_fields = 0) setup=(
        req = bench_request("POST", "/bench/json"; body = $body)) evals=1
    SUITE["holds"]["json_typed_$size"] = @benchmarkable _HOLDS_BP.json(req, BenchRows; max_fields = 0) setup=(
        req = bench_request("POST", "/bench/json"; body = $body)) evals=1
end

# ── Multipart: what `getfiles` / `getpost` parse ────────────────────────────────────────────────
#
# One text field and one file part of random bytes (an upload is usually compressed, so it looks
# random to the boundary scan). The 64 MiB body is sized so the WHOLE body fits the default
# `max_body_bytes` (`DEFAULT_MAX_BODY_BYTES`), the largest a default server accepts.
const HOLDS_BOUNDARY = "----NitroBenchBoundary7MA4YWxkTrZu0gW"

function _holds_multipart_body(total::Int)
    head = string("--", HOLDS_BOUNDARY, "\r\n",
                  "Content-Disposition: form-data; name=\"note\"\r\n\r\nhello\r\n",
                  "--", HOLDS_BOUNDARY, "\r\n",
                  "Content-Disposition: form-data; name=\"upload\"; filename=\"data.bin\"\r\n",
                  "Content-Type: application/octet-stream\r\n\r\n")
    tail = string("\r\n--", HOLDS_BOUNDARY, "--\r\n")
    payload = rand(UInt8, total - sizeof(head) - sizeof(tail))
    return vcat(Vector{UInt8}(head), payload, Vector{UInt8}(tail)), length(payload)
end

const HOLDS_MULTIPART_HEADERS = ["Content-Type" => "multipart/form-data; boundary=$HOLDS_BOUNDARY"]

for (size, total) in (("1mb", 1_000_000), ("10mb", 10_000_000),
                      ("64mib", Int(Nitro.Core.Constants.DEFAULT_MAX_BODY_BYTES)))
    body, file_bytes = _holds_multipart_body(total)
    parsed = _HOLDS_BP.multipart(HTTP.Request("POST", "/bench/upload", HOLDS_MULTIPART_HEADERS, copy(body)))
    (get(parsed, "note", nothing) == "hello" && haskey(parsed, "upload") &&
     length(parsed["upload"].data) == file_bytes) ||
        error("holds: multipart_$size does not parse its body")
    SUITE["holds"]["multipart_$size"] = @benchmarkable _HOLDS_BP.multipart(req) setup=(
        req = HTTP.Request("POST", "/bench/upload", HOLDS_MULTIPART_HEADERS, copy($body))) evals=1
end

# ── `Res.file` of a file already in page cache ──────────────────────────────────────────────────
#
# `file_100mib` is the non-streamed path, `stream = false`: `read(path)` of the whole file, then
# `servecontent`. It was the default until #588 made a file over 8 MiB stream. An `IOStream` read
# does not yield, so all of it is one hold.
#
# `file_100mib_stream_read` is `stream = true` plus the READ side of the write loop
# (`_write_fixed_body!`): one `body_read!` per 64 KiB chunk. On a socket each chunk's `write` sits
# between two reads and is where the task can give its thread up, so the hold that matters is one
# chunk, the total divided by the chunk count (1,600); in-process there is no socket, so this row
# reports the sum of the reads.
const HOLDS_FILE_BYTES = 100 * 1024 * 1024
const HOLDS_FILE = let dir = mktempdir()   # removed at exit
    path = joinpath(dir, "holds-100mib.bin")
    write(path, rand(UInt8, HOLDS_FILE_BYTES))
    read(path)   # into page cache
    path
end
const HOLDS_CHUNK_BYTES = Nitro.Core._STREAM_CHUNK_BYTES

function _holds_drain(resp::HTTP.Response)
    body = resp.body
    buffer = Vector{UInt8}(undef, HOLDS_CHUNK_BYTES)
    total = 0
    try
        while (n = HTTP.body_read!(body, buffer)::Int) > 0
            total += n
        end
    finally
        HTTP.body_close!(body)
    end
    total == HOLDS_FILE_BYTES || error("drained $total bytes, expected $HOLDS_FILE_BYTES")
    return total
end

let resp = Res.file(HTTP.Request("GET", "/bench/file"), HOLDS_FILE; stream = false)
    resp.status == 200 && HTTP.header(resp, "Content-Length") == string(HOLDS_FILE_BYTES) ||
        error("holds: file_100mib does not serve the whole file")
end
_holds_drain(Res.file(HTTP.Request("GET", "/bench/file"), HOLDS_FILE; stream = true))   # checks the length

SUITE["holds"]["file_100mib"] = @benchmarkable Res.file(req, HOLDS_FILE; stream = false) setup=(
    req = HTTP.Request("GET", "/bench/file")) evals=1
SUITE["holds"]["file_100mib_stream_read"] = @benchmarkable _holds_drain(Res.file(req, HOLDS_FILE; stream = true)) setup=(
    req = HTTP.Request("GET", "/bench/file")) evals=1
