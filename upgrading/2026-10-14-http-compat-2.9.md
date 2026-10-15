## HTTP compat moves to `~2.9` — an app pinning `~2.8` must move too, and the keep-alive wait is now `idle_timeout`'s

- **Version**: 0.6.0
- **Nitro ref**: `Project.toml` `[compat]`; `src/core/lifecycle.jl` (`preprocesskwargs`,
  `_validate_allow_h2c`), `src/core/transport.jl` (`_clear_header_deadline!` removed);
  `test/http_internals_contract_tests.jl`
- **Recorded**: 2026-10-14
- **Severity**: **breaking (dependency resolution)** — an app carrying its own `HTTP = "~2.8"`
  bound does not resolve against this release. Plus a **behavior change in connection timing**:
  which timeout bounds the wait between two keep-alive requests, and what an idle close sends
  (below).

### What changed

Nitro's bound moved from `HTTP = "~2.8"` to `HTTP = "~2.9"` (resolving 2.9.0).

**The pin stays tight — `~`, not `^` — on purpose**, for the same reason as every earlier move:
core reaches into HTTP internals that no public API covers (`BytesBody.data` in the non-consuming
response write path, the `Stream` write-state fields behind the live fixed-length writer, the
router's node tree, the bounded shutdown). Verified against 2.9.0 before the bound moved: every
internal canaried in `test/http_internals_contract_tests.jl` still exists and behaves the same,
and Nitro's full suite passed against 2.9.0 before the two simplifications below, and again with
them.

**The keep-alive wait is `idle_timeout`'s (HTTP.jl #1382).** Through 2.8, HTTP.jl armed the
header deadline before the wait for the next request on a keep-alive connection, so
`read_header_timeout` was the idle limit in practice, and an idle connection that hit it was sent
an unsolicited `408` (reported upstream as JuliaWeb/HTTP.jl#1381). From 2.9 the wait is bounded by
`idle_timeout` (or `read_timeout` when `idle_timeout` is `0`), the header deadline starts with the
next request's first byte, and an idle close writes nothing.

| On a keep-alive connection | ≤ 2.8 | 2.9 |
|---|---|---|
| Wait for the next request is bounded by | `read_header_timeout` | `idle_timeout` (`read_timeout` if that is `0`) |
| Idle connection reaches its limit | `408 Request Timeout`, then close | close, no response |
| `read_header_timeout = 5`, `idle_timeout` at its default | idle connections closed after 5 s | idle connections closed after 120 s |
| `read_header_timeout` set, `idle_timeout = 0`, `read_timeout` unset | idle connections closed after `read_header_timeout` | idle connections kept until the client closes them |
| `read_header_timeout = 0`, `idle_timeout` set, `read_timeout` unset | the next request's head bounded by `idle_timeout`, counted from the previous response | the wait bounded by `idle_timeout`; once the first byte arrives, the head has no time bound |

With Nitro's defaults — both 120 seconds — the idle limit is the same 120 seconds it was; what
changes is that the close is silent. An app that lowered `read_header_timeout` to tighten
Slowloris protection and relied on it to reap idle connections must set `idle_timeout` too.

The same release clears the read deadline once a head is parsed when `read_timeout` is unset, so a
slow upload is not cut by `read_header_timeout` — the Go semantics Nitro already promised. Nitro
used to enforce that itself (`_clear_header_deadline!`, a stream wrapper installed by `serve`);
it is removed, since HTTP.jl now does exactly what it did.

**Cleartext HTTP/2 is refused through HTTP.jl's own switch (HTTP.jl #1388).** Nitro serves
HTTP/1.1 only on its plaintext listener (#375). It used to enforce that by overriding a private
HTTP.jl method; it now passes `allow_h2c = false` to `listen!`, which does the same thing. The
behavior is unchanged: an h2c preface is answered `400` and the connection closed. Because the
keyword now exists, `serve(...; allow_h2c = true)` is refused with an `ArgumentError`, before
`serve` changes anything, rather than silently overridden. (Against 2.8 it was a `MethodError` from
`listen!`.)

Also in 2.9.0, none of which needs an app change:

- **Repeated `Cookie` lines are joined with `"; "`** (HTTP.jl #1386), all onto the first, over
  HTTP/1 as over HTTP/2. Two adjacent `Cookie` lines used to be folded with `,`, which
  `get_cookie` and `parse_cookies` then read as one cookie whose value ran into the next pair.
  First-wins for a repeated name (#329) is unchanged.
- **An empty `write` to a response stream is a no-op** (HTTP.jl #1391). On a chunked response it
  used to send the last-chunk marker and end the body early.
- **A fixed-length response streams after an explicit `startwrite`** (HTTP.jl #1389, #1396). A
  handler that calls `startwrite(stream)` and writes more than 4 KiB with a `Content-Length` now
  sends it as written; before, the whole body was held until `closewrite`. A failure after the
  first 4 KiB then closes the connection rather than sending an error response.
- **Client side:** a redirect keeps the target's path and query as RFC 3986 resolves them
  (HTTP.jl #1383); a request with an empty streaming body can be retried and redirected (#1394);
  and an error response's body no longer overwrites a byte-buffer `response_stream` (#1387).

**What did *not* change:** the router, the body types and the pre-send check, the non-consuming
write path, header-name spelling (2.8), and Nitro's public API.

### How to find the calls to migrate

```bash
# The app's own bound — this is what blocks resolution.
rg -n '^HTTP\s*=' <app>/Project.toml

# serve() calls that set read_header_timeout without idle_timeout: their idle limit moves to
# idle_timeout's (120 s by default), or to none at all with idle_timeout = 0.
rg -n 'read_header_timeout' <app>/src
rg -n 'idle_timeout' <app>/src

# Clients, monitors or tests that expected a 408 from an idle keep-alive connection.
rg -n '408' <app>/test <app>/src

# Streaming handlers that call startwrite before a fixed-length body.
rg -n 'startwrite\(' <app>/src
```

### Migrate your app

```toml
# ✗ before — will not resolve against this release
HTTP = "~2.8"

# ✓ after
HTTP = "~2.9"
```

An app that lowered `read_header_timeout` and expected it to reap idle connections:

```julia
# ✗ before — the 5-second header timeout also closed idle keep-alive connections
serve(app; read_header_timeout = 5)

# ✓ after — name the idle limit; keep it above your proxy's (nginx and AWS ALB use 60 s)
serve(app; read_header_timeout = 5, idle_timeout = 75)
```

An app that does not pin HTTP itself needs no `Project.toml` change: it inherits the bound from
Nitro.
