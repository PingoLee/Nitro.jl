## HTTP compat moves to `~2.8` — an app pinning `~2.7` must move too, and header names now go out as spelled

- **Version**: Unreleased
- **Nitro ref**: `Project.toml` `[compat]`; `test/http_internals_contract_tests.jl`
- **Recorded**: 2026-09-29
- **Severity**: **breaking (dependency resolution)** — an app carrying its own `HTTP = "~2.7"`
  bound does not resolve against this release. Plus one **behavior change on the wire**: the
  spelling of response header names (below).

### What changed

Nitro's bound moved from `HTTP = "~2.7"` to `HTTP = "~2.8"` (resolving 2.8.0).

**The pin stays tight — `~`, not `^` — on purpose**, for the same reason as every earlier move:
core reaches into HTTP internals that no public API covers (`BytesBody.data` in the non-consuming
response write path, the transport fields behind the peer-IP lookup, the h2c probe, the bounded
shutdown). Verified against 2.8.0 before the bound moved: every internal canaried in
`test/http_internals_contract_tests.jl` still exists and behaves the same, and Nitro's full suite
passes unchanged.

**Header names are no longer rewritten.** HTTP.jl 2.0 through 2.7 stored every header name in
`Content-Type` form on insertion. From 2.8.0 (HTTP.jl #1377) a name is stored **as it was given**,
HTTP/1 sends it in that spelling, and HTTP/2 sends every name lowercase. Lookups (`HTTP.header`,
`setheader`, `hasheader`, …) match any case. Headers **read from the network** are still stored in
`Content-Type` form, so request handling is unchanged.

What that changes in responses Nitro sends — headers Nitro writes itself, and headers HTTP.jl
writes on its behalf:

| Header | Where | ≤ 2.7 sent | 2.8 sends |
|---|---|---|---|
| `ETag` | every `staticfiles` / `spafiles` / `dynamicfiles` / `Res.file` response that carries one — the default `:weak_stat` policy does (written by `HTTP.servecontent`) | `Etag` | `ETag` |
| `X-RateLimit-Limit` / `-Remaining` / `-Reset` | every response through `RateLimiter` | `X-Ratelimit-*` | `X-RateLimit-*` |
| `Sec-WebSocket-Accept` (+ `-Protocol` / `-Extensions` when negotiated) | the accepted WebSocket handshake (101) | `Sec-Websocket-*` | `Sec-WebSocket-*` |
| `Sec-WebSocket-Version` | the 426 answering an unsupported WebSocket version | `Sec-Websocket-Version` | `Sec-WebSocket-Version` |

Every other header Nitro sets is written in `Content-Type` form, so it goes out unchanged.

**The same applies to headers your app sets:** `"x-request-id" => id` used to go out as
`X-Request-Id` and now goes out as `x-request-id`. Header names are case-insensitive (RFC 9110
§5.1) and browsers' `fetch` lowercases them anyway, so this only reaches a client that matches a
name **case-sensitively** — a CDN or proxy rule, a client outside HTTP.jl, or an app test that
inspects a response **in process** (a handler or middleware called directly). An HTTP.jl client
reading a Nitro server *over the network* still sees `Content-Type`-form names, because names read
from the network are canonicalized on arrival.

Nitro itself never depended on either spelling: every place `src/` walks a header list compares
names case-insensitively. The new spelling is pinned in `test/http_internals_contract_tests.jl`, so
a later release that re-canonicalized would be visible there.

Also in 2.8.0: HTTP/2 trailer handling fixes, and `show(::Request)` printing the `Host` line the
HTTP/1 writer actually sends. Neither reaches Nitro.

**What did *not* change:** the router (still-encoded path segments, match precedence), the body
types and the pre-send check `_check_response_body_unsent`, and Nitro's public API.

### How to find the calls to migrate

```bash
# The app's own bound — this is what blocks resolution.
rg -n '^HTTP\s*=' <app>/Project.toml

# Response header names the app writes lowercase or with a run of capitals ("x-request-id",
# "ETag", "X-CSRF-Token"): these now reach the wire as written. Noisy on JSON keys; skim it.
rg -n '"([a-z][a-z0-9-]*|[A-Za-z0-9-]*[A-Z]{2}[A-Za-z0-9-]*)"\s*=>' <app>/src
rg -n 'setheader!?\([^,]+,\s*"([a-z]|[A-Za-z0-9-]*[A-Z]{2})' <app>/src

# Tests, clients or proxy rules that match the old canonical spellings exactly.
rg -n 'X-Ratelimit-|"Etag"|Sec-Websocket-' <app>
```

### Migrate your app

```toml
# ✗ before — will not resolve against this release
HTTP = "~2.7"

# ✓ after
HTTP = "~2.8"
```

An app test that inspects an in-process response by exact name must match case-insensitively:

```julia
# ✗ before — worked only while HTTP canonicalized the name on insertion
etag = Dict(resp.headers)["Etag"]

# ✓ after — case-insensitive, and correct under any HTTP version
etag = HTTP.header(resp, "ETag")
```

An app that does not pin HTTP itself needs no `Project.toml` change: it inherits the bound from
Nitro.
