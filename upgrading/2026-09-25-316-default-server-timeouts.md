## `serve()` — a connection must finish its request head within 120 seconds, and idles out after 120 (#316)

- **Version**: Unreleased
- **Nitro ref**: [#316](https://github.com/PingoLee/Nitro.jl/issues/316) ; `src/core/lifecycle.jl`, `src/core/transport.jl`
- **Recorded**: 2026-09-25
- **Severity**: **behavior change.** It affects every app that calls `serve`, but only the
  connections that were already misbehaving or idle: one that takes longer than 120 seconds to
  send a complete request head, or that sits idle for 120 seconds between requests. A request body
  is **not** timed, however slowly it arrives.

### What changed

HTTP.jl disables every server timeout by default, and Nitro passed that through. A client could
open a connection and send one header byte a minute (Slowloris), or open one and send nothing, and
hold its socket and its task for the life of the process. `serve` now sets two of HTTP.jl's
timeouts by default:

| Keyword | Before | After |
|---|---|---|
| `read_header_timeout` | off | **120 s** — a request head must arrive within it, or the server answers `408` and closes the connection |
| `idle_timeout` | off | **120 s** — an idle HTTP/2 connection is closed |
| `read_timeout`, `write_timeout` | off | off (unchanged) |

Two consequences of how HTTP.jl 2.7 applies these on HTTP/1.1, the protocol browsers and reverse
proxies use to reach Nitro:

- **The header timeout is also the keep-alive idle limit.** HTTP.jl re-arms it before every
  request on a connection, so an HTTP/1.1 connection that sits idle for 120 seconds between two
  requests is closed, with an unsolicited `408`. Clients and proxies treat that as a closed
  keep-alive connection and open a new one. 120 seconds is above the 60-second idle timeout of
  nginx `upstream` pools and AWS ALB, so behind those the proxy still closes first.
- **The body is not timed.** HTTP.jl would otherwise leave the header deadline running while the
  body is read, making `read_header_timeout = 120` a limit on the head *and* the whole upload.
  Nitro clears it once the head is parsed, the way Go's `ReadHeaderTimeout` works. Set
  `read_timeout` if you want the body bounded too.

Separately, a request whose body read failed on an HTTP.jl error used to be answered `500`
whatever the cause, because Nitro's per-request task wrapped the error before HTTP.jl could
classify it. HTTP.jl's own status now reaches the client: `408` when an explicit `read_timeout`
fires mid-body, `400` for a malformed body. Nothing to migrate for that part; it is listed here
because a monitor that counted those `500`s will now see `408`s and `400`s instead.

### How to find the calls to migrate

Every server start, and any proxy that keeps idle connections to Nitro open longer than 120
seconds:

```bash
grep -rn "serve(" src/ --include=*.jl
grep -rn "keepalive_timeout\|idle_timeout\|idleTimeout" /etc/nginx/ deploy/ 2>/dev/null
```

Nothing needs to change unless one of these is true:

- a client deliberately holds a connection open **before** sending its request (a long-poll
  protocol that opens the socket early), or
- your proxy's idle timeout for connections *to Nitro* is **above** 120 seconds — then either lower
  the proxy's, or raise Nitro's above it.

### Migrate your app

```julia
# ✗ before — relied on HTTP.jl's "no timeouts" default
serve(app; host = "127.0.0.1", port = 8080)

# ✓ after — to keep a proxy with a 300-second upstream idle timeout closing first
serve(app; host = "127.0.0.1", port = 8080, read_header_timeout = 330, idle_timeout = 330)

# ✓ after — to restore the old behavior exactly (not recommended for a directly exposed server)
serve(app; host = "127.0.0.1", port = 8080, read_header_timeout = 0, idle_timeout = 0)
```
