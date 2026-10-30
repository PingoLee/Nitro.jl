## HTTP compat moves to `~2.11` — an app pinning `~2.9` must move too, and a failure HTTP answered silently is now logged

- **Version**: 0.7.0
- **Nitro ref**: `Project.toml` `[compat]`; `src/core/transport.jl` (`parallel_stream_handler`,
  `_report_escaped!`, `_mark_reported!`, `_write_fixed_body!`); `test/http_internals_contract_tests.jl`,
  `test/streaming_write_tests.jl`, `test/middleware/middleware_error_boundary_tests.jl`
- **Recorded**: 2026-10-20
- **Severity**: **breaking (dependency resolution)** — an app carrying its own `HTTP = "~2.9"`
  bound does not resolve against this release. Plus **behavior changes** in what is logged, and in
  a few statuses and connection endings an app or its clients can observe (below).

### What changed

Nitro's bound moved from `HTTP = "~2.9"` to `HTTP = "~2.11"` (resolving 2.11.0; 2.10.0 and 2.11.0
were released the same day, so there is no stop at 2.10). **The pin stays `~`** for the same reason
as every earlier move: core reaches into HTTP internals no SemVer covers. Every internal canaried
in `test/http_internals_contract_tests.jl` has the same layout and behavior at 2.11.0, and Nitro's
full suite passed against it before any Nitro change.

**One HTTP change needed a Nitro change: HTTP now logs a stream handler's error itself
(HTTP.jl #1425), with the live exception and the whole request target — query string included.**
Nitro keeps both out of its logs (`access_log_query = false`, and every Nitro record carries a
`LoggedException`, never the exception). So Nitro now logs such an error first, once, without the
target, and tells HTTP it is reported, so HTTP does not log it again. Which errors that is:

| The error | ≤ 2.9 | 2.11 without Nitro's fix | Now |
|---|---|---|---|
| A streamed body with a `Content-Length` fails (producer throws, wrong length) | Nitro's `@warn` | Nitro's `@warn` **and** HTTP's `@error` with the value and query | Nitro's `@warn` only |
| A chunked body (no `Content-Length`) fails after its head | nothing logged | HTTP's `@error` with the value and query | Nitro's `@error "Request failed outside the error handler"` |
| A handler throws with no error boundary (`serve(catch_errors = false)` or `serialize = false`), or a layer outside the boundary throws | nothing logged | HTTP's `@error` with the value and query | Nitro's `@error "Request failed outside the error handler"` |
| A client disconnects, a read times out, a WebSocket closes | nothing logged | nothing logged | nothing logged |

An app that alerts on `@error` records sees the new line for the second and third rows. It names a
real server-side fault the client saw as a `500` or a cut connection. It is written whatever
`show_errors` says, as the streamed-body warning always was: `show_errors` governs the error
boundary's own line, and in the third row the boundary never saw the error.

**Statuses keep 2.9's mapping for these errors.** 2.11 answers any handler error with `500`; an
error Nitro has reported keeps the status HTTP derives from its type, as through 2.9 — so a handler
that throws `HTTP.ParseError` under `catch_errors = false` is still a `400`.

Also in 2.10 and 2.11, none of which needs an app change unless it relied on the old behavior:

- **A chunked body whose producer throws after the head ends without the last chunk** (HTTP.jl
  #1436). Through 2.9 the connection close wrote `0\r\n\r\n` first, so a client could not tell the
  truncated response from a complete one. Now it can. (A failing `Res.sse` producer is unaffected:
  Nitro catches it, logs it and ends the stream normally, as before.)
- **Static files: `Range` is ignored rather than refused** (HTTP.jl #1433) when it names several
  ranges or a unit other than `bytes` — the whole file with `200`, where 2.9 sent `416` — and on any
  method but `GET`/`HEAD`, which reaches `Res.file(req, …)` in a `POST` handler.
- **A busy port throws `HTTP.AddressInUseError`** from `serve` (HTTP.jl #1432). Through 2.9
  `listen!` bound inside its server task, so the bind failure surfaced as a `TaskFailedException`
  wrapping it.
- **A request line whose HTTP major version is not 1 is answered `505`** (HTTP.jl #1405). A
  cleartext HTTP/2 preface is still `400`, refused earlier (#375).
- **Over TLS, a request read timeout is answered `408`**, as over plain TCP (HTTP.jl #1403), and
  status lines always read `HTTP/1.0` or `HTTP/1.1` (HTTP.jl #1431).
- **Client side** (an app using `HTTP.request` itself): a byte-buffer `response_stream` receives
  only a `2xx` body (HTTP.jl #1407); loopback requests never go through an environment proxy
  (#1414); spaces in URLs are sent as `%20` (#1415); a read timeout over HTTPS throws
  `TimeoutError` (#1416); a URL with an invalid port is rejected when parsed (#1420); and
  `isrecoverable` is `true` for refused connections and connect or TLS handshake timeouts (#1412).

**What did *not* change:** the router, the body types, the non-consuming write path, the in-place
writes HTTP makes to the response it sends (Nitro's handoff copy, #628, still covers them), and
Nitro's public API.

### How to find the calls to migrate

```bash
# The app's own bound — this is what blocks resolution.
rg -n '^HTTP\s*=' <app>/Project.toml

# Code that catches a bind failure around serve() by its old shape.
rg -n 'TaskFailedException|IOError|EADDRINUSE' <app>/src

# Log alerts or tests keyed on HTTP.jl's own record, or on its absence.
rg -n 'server handler error|Request failed outside the error handler' <app>

# Tests or clients that expected 416 for a multi-range or non-bytes Range on a static file.
rg -n '416' <app>/test <app>/src

# HTTP client calls with a byte-buffer response_stream that read error bodies from it.
rg -n 'response_stream' <app>/src
```

### Migrate your app

```toml
# ✗ before — will not resolve against this release
HTTP = "~2.9"

# ✓ after
HTTP = "~2.11"
```

An app that caught a busy port around `serve`:

```julia
# ✗ before — the bind error arrived wrapped in the server task's failure
try
    serve(app; port = 8080)
catch e
    e isa TaskFailedException || rethrow()
    @warn "port 8080 is taken"
end

# ✓ after
try
    serve(app; port = 8080)
catch e
    e isa HTTP.AddressInUseError || rethrow()
    @warn "port 8080 is taken"
end
```

An app that does not pin HTTP itself needs no `Project.toml` change: it inherits the bound from
Nitro.
