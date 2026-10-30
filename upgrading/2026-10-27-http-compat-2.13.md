## HTTP compat moves to `~2.13` — an app pinning `~2.11` must move too

- **Version**: 0.7.0
- **Nitro ref**: `Project.toml` `[compat]`; `src/utilities/bodyparsers.jl` (`multipart`,
  `_too_many_parts`); `src/core/transport.jl` (`_send_response!`); `test/http_internals_contract_tests.jl`,
  `test/max_fields_tests.jl`, `test/response_tests.jl`
- **Recorded**: 2026-10-27
- **Severity**: **breaking (dependency resolution)** — an app carrying its own `HTTP = "~2.11"`
  bound does not resolve against this release. Nothing in Nitro's own API changes; a few things
  HTTP.jl does differently are listed below, for an app that relied on the old behavior.

### What changed

Nitro's bound moved from `HTTP = "~2.11"` to `HTTP = "~2.13"` (resolving 2.13.1, with Reseau
1.6.3; HTTP 2.11.1 and later need Reseau 1.6.1, which Nitro's `Reseau = "~1.6"` already admits).
**The pin stays `~`** for the same reason as every earlier move: core reaches into HTTP internals
no SemVer covers. Every internal canaried in `test/http_internals_contract_tests.jl` keeps its
layout and behavior at 2.13.1.

**Two HTTP changes needed a Nitro change.** Unfixed, each would have changed what an app's
clients see; fixed, neither does.

**HTTP's multipart parser gained a part cap of its own, 1000 by default (HTTP.jl #1453)**, and
refuses a body past it with an error that read, to Nitro, as a malformed body. Unfixed, a multipart form with 1001 or more parts bound as **no fields at all**:
an app at the default cap got empty forms where it had got a `400`, and an app that raised
`serve(max_fields = …)` or set it to `0` silently lost every larger form. Nitro now passes its
`max_fields` cap to HTTP as that limit, so through Nitro multipart forms behave as before — at most
`max_fields` parts, a `400` past it, no limit at `0` — and the body is refused while it is still
being scanned, before any part is built. A form padded with parts that have no
`Content-Disposition` now counts those parts against the cap too.

**HTTP now sets a `HEAD` response's `Content-Length` itself (HTTP.jl #1454)**, from the body
length, whenever that length is known. Nitro already gives a `HEAD` the `Content-Length` its `GET`
would send (#146), and deliberately sends none when it cannot know that value. Unfixed, HTTP's
header undid that: `Content-Length: 0` on every `HEAD` handler returning an empty body such as
`Res.status(200)` (while its `GET` sends a body, so the header was wrong), and the same `0`
written over a length a `HEAD` handler set explicitly. Nitro now hands HTTP a `HEAD` response
whose length HTTP will not read, so the header is Nitro's alone, as through 2.11. One `HEAD` does
gain the header: a `413` or `503` that Nitro refuses before the pipeline runs now carries the
length of its message, the same value the `GET` refusal sends.

What an app or its clients can observe, none of which needs an app change unless it relied on the
old behavior:

- **A response body of unknown length to an HTTP/1.0 client is no longer chunked** (HTTP.jl #1463,
  #1485): it is sent as is and the connection closes after it. HTTP/1.0 clients could not read the
  chunked form.
- **After an error response, or a request body a handler left unread, the server reads what the
  client is still sending** (up to 500 ms and 1 MiB) before it closes the connection (HTTP.jl
  #1494), so the client reads the response instead of a connection reset.
- **A `Res.sse` stream whose client stops reading is closed** once its unsent events pass four
  times `max_len`, and at least 16 MiB (HTTP.jl #1478): the producer's next `write` throws
  `IOError`, as for a client that disconnected. Before, the server kept every event.
- **A WebSocket whose handler leaves received messages unread is closed with status 1008** once
  they pass four times `maxframesize` bytes, 64 MiB at the default (HTTP.jl #1474). A handler that
  never calls `receive` on an open socket now loses it.
- **The HTTP/1 request parser is stricter** (HTTP.jl #1468): a version other than `HTTP/`
  DIGIT `.` DIGIT, and a control byte other than HTAB in a chunk extension, are answered `400`.
- **An OS error from `accept`, such as running out of file descriptors, no longer stops the
  server for good** (HTTP.jl #1443): it is logged as `server accept error; retrying` and accept is
  retried.
- **HTTP.jl's own `server handler error` log record leaves out the query string** (HTTP.jl #1473).
  Nitro already kept that record from being written; it still does, because the record carries the
  live exception.
- **Client side** (an app using `HTTP.request`, `HTTP.WebSockets.open` or `HTTP.Form` itself):
  URLs are checked against RFC 3986 before a connection is made, so a userinfo or host with a
  backslash, space or control character, or a host with `%`, raises `ArgumentError` — percent-encode
  special characters in URL credentials, such as `DOMAIN\user` as `DOMAIN%5Cuser` (#1447); a URL
  whose path or query holds a control character fails before connecting and is not retried (#1459);
  a TLS handshake that runs into a deadline raises `TimeoutError`, not `TLSHandshakeError` (#1455);
  `WebSockets.open` raises `ConnectError` and the other `HTTP.request` error types instead of
  Reseau's (#1456); `HTTP.Form` escapes `"`, CR and LF in field and file names (#1444); cookie paths
  are matched without the query (#1448); and printing a `Client`, `Transport` or `ProxyConfig` no
  longer shows credentials (#1465).
- **An app that calls HTTP.jl's multipart parsers itself** (`HTTP.parse_multipart_form`,
  `parse_multipart`, `parse_multipart_body`) gets the 1000-part cap there too; pass `max_parts`.

**What did *not* change:** the router, the body types, the non-consuming write path, how Nitro logs
and answers a failed request (the 2.11 handling of `stream.io_error` is unchanged in 2.13), the
`Content-Length` of a `HEAD` that reaches a handler, and Nitro's public API. The HTTP/2 server
changes in 2.12 and 2.13 do not reach Nitro, whose listener is HTTP/1.x only.

### How to find the calls to migrate

```bash
# The app's own bound — this is what blocks resolution.
rg -n '^HTTP\s*=' <app>/Project.toml

# Direct calls to HTTP.jl's multipart parsers, which now stop at 1000 parts.
rg -n 'parse_multipart' <app>/src

# Client code that catches TLS handshake errors, or Reseau errors from WebSockets.open.
rg -n 'TLSHandshakeError|Reseau\.' <app>/src

# WebSocket handlers that may leave received messages unread.
rg -n 'WebSocket' <app>/src

# URLs with credentials, which must now be percent-encoded.
rg -n 'https?://[^/@[:space:]]+@' <app>/src <app>/config
```

### Migrate your app

```toml
# ✗ before — will not resolve against this release
HTTP = "~2.11"

# ✓ after
HTTP = "~2.13"
```

An app that parses multipart bodies with HTTP.jl directly and accepts more than 1000 parts:

```julia
# ✗ before — throws past 1000 parts on HTTP 2.13
parts = HTTP.parse_multipart_form(req)

# ✓ after — state the limit (0 removes it)
parts = HTTP.parse_multipart_form(req; max_parts = 5000)
```

An app that does not pin HTTP itself needs no `Project.toml` change: it inherits the bound from
Nitro.
