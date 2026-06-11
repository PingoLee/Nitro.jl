# HTTP.jl v2 bugs found during the Nitro.jl migration

These were discovered while migrating Nitro.jl from HTTP.jl v1 to v2 (`HTTP = "^2"`,
resolves to **v2.1.1**, depot path `~/.julia/packages/HTTP/54djb`). Platform:
**Windows 11, Julia 1.12.6**. Each item below reproduces with **raw HTTP.jl and no Nitro
code**, so they are upstream issues, not migration mistakes. They block the last ~6 Nitro
network tests; everything else passes.

Ordered by severity. The first is a correctness bug (data corruption); the other two are
the Windows/Reseau same-process loopback problems already partly tracked in JuliaWeb/HTTP.jl#1252.

---

## 1. CRITICAL — `listen!` empty-body response corrupts the keep-alive connection

After a `listen!` stream handler emits an **empty-body** response, the **next** request on
the same keep-alive connection fails with:

```
HTTP.ParseError: unexpected EOF while reading HTTP/1 data
```

The empty response itself is read correctly by the client (status + headers arrive); the
connection is left in a desynchronized state and every subsequent request on it dies.

This affects any response with no body: **CORS preflight (`OPTIONS`), `204`, `304`,
`HEAD`** — i.e. extremely common traffic. `HTTP.serve!` (the `Request->Response`,
`stream=false` path) is **not** affected; only `listen!` (`stream=true`) is.

### Minimal reproduction (no Nitro)

```julia
using HTTP
server = HTTP.listen!("127.0.0.1", 9074) do stream
    req  = HTTP._buffered_stream_request(stream)
    resp = req.target == "/empty" ? HTTP.Response(200, ["X-C" => "*"]) :
                                     HTTP.Response(200; body = "ok")
    resp.request   = req
    stream.response = resp
    b = resp.body
    (b isa HTTP.BytesBody && !isempty(b.data)) && write(stream, b.data)
    return nothing
end
sleep(2)
client = HTTP.Client()
for p in ["/empty", "/body", "/body", "/empty", "/body"]
    try
        r = HTTP.request("GET", "http://127.0.0.1:9074$p"; client=client, status_exception=false, retry=false)
        println("$p -> $(r.status) ", repr(String(r.body)))
    catch e
        println("$p -> THREW ", typeof(e))
    end
end
close(client); close(server)
```

Observed:

```
/empty -> 200 ""
/body  -> THREW HTTP.ParseError
/body  -> THREW HTTP.ParseError
/empty -> 200 ""
/body  -> THREW HTTP.ParseError
```

### Notes
- Reproduces equally with the **documented `listen!` pattern** from the v2 migration
  guide (`setstatus` / `setheader` / `startwrite`), and with an explicit
  `Content-Length: 0` header — so it is not a body-write API misuse.
- The same OPTIONS/GET sequence over `HTTP.serve!` works perfectly, which isolates the
  fault to the `listen!` server path's framing/connection-reuse for empty bodies.

---

## 2. HIGH — Reseau same-process Windows loopback latency (~1–1.6 s per request)

On Windows, same-process loopback requests take roughly **1 second each**, deterministically.

### Minimal reproduction (no Nitro)

```julia
using HTTP
server = HTTP.serve!("127.0.0.1", 9081) do req
    HTTP.Response(200; body = "ok")
end
sleep(2)
t = @elapsed for _ in 1:25
    HTTP.request("GET", "http://127.0.0.1:9081/x"; status_exception=false)
end
@info "25 requests" seconds = round(t, digits=2)   # ~41s observed (raw serve!)
close(server)
```

Observed: **41 s for 25 requests** with raw `serve!`; ~24 s through Nitro's `listen!`.
A shared `HTTP.Client` (connection reuse) does not help (~26 s), so the cost is per-request,
not per-connection-setup — consistent with the WSARecv completion lag described in
JuliaWeb/HTTP.jl#1252. This makes any test that fires many same-process requests inside a
short time window (e.g. rate limiting with a 3 s window and 25–100 requests) impossible to
pass on Windows.

---

## 3. HIGH — Reseau same-process loopback deadlock / precompile hang on Windows

`_precompile_workload_enabled()` returns `true` by default in v2.1.1, so the in-process
precompile workload (which stands up several servers and hits them on loopback) can
**hang precompilation** on Windows due to the same Reseau same-process deadlock
(client `WSARecv` completion is lost; server handler runs but the client never returns).

### Local mitigation currently required

Patch `~/.julia/packages/HTTP/54djb/src/precompile.jl`:

```julia
# was: if _precompile_workload_enabled()
if false  # disable in-process precompile workload (Reseau Windows loopback deadlock)
```

This is depot-local and wiped on reinstall. (Originally observed on v2.0.0 / `2cpJl`; the
same patch is needed on v2.1.1 / `54djb`.)

---

## Items that were NOT HTTP.jl bugs (handled inside Nitro during migration)

For completeness, these v1→v2 API changes were absorbed in Nitro and are working as
intended in v2 (listed so reviewers don't re-file them):

- `HTTP.method(req)` removed → use `req.method`.
- `HTTP.payload(req)` / raw `Vector{UInt8}` body → `req.body::AbstractBody`
  (`EmptyBody`/`BytesBody`).
- `HTTP.queryparams(::Request)` removed → only `queryparams(::AbstractString)`/`(::URI)`.
- `HTTP.Messages` / `HTTP.Streams` submodules removed → `HTTP.Request`, `HTTP.Stream`.
- `HTTP.WebSocket` → `HTTP.WebSockets.WebSocket`; `send`/`receive`/`startwrite`/`closewrite`
  no longer exported at top level.
- `HTTP.Headers` canonicalizes header field names to Title-Case on insertion.
- `HTTP.serve!` is strictly `Request->Response`; stream handlers must use `HTTP.listen!`.
- `logfmt"..."` / `access_log` server kwargs removed.
- `Base.getproperty(::Request, ::Symbol)` is now defined by HTTP.jl (handles
  `:context`/`:version`), so downstream `getproperty` extensions must be a superset and be
  installed at load time, not precompile time.
- `_write_response_body_to_stream!` advances the `BytesBody` read cursor, so a `Response`
  object reused across requests (e.g. a module-level `const`) writes an empty body on the
  second use. (Borderline — arguably a footgun worth a docs note upstream: reading
  `BytesBody.data` is cursor-independent and safe for reuse.)
