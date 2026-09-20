## `serve()` now caps request bodies at 64 MiB and answers 413 (#17)

- **Version**: Unreleased
- **Nitro ref**: #17; `src/core/transport.jl`, `src/core/lifecycle.jl`, `src/constants.jl`
- **Recorded**: 2026-09-20
- **Severity**: **behavior (new default ceiling)** — a request whose body exceeds 64 MiB is now
  refused instead of buffered. Apps that accept larger uploads must raise the limit explicitly.

### What changed

Nitro serves through `HTTP.listen!` with a raw stream handler, and until now it read every request
body with an unbounded `read(stream)`. The bundled HTTP fork ships a 64 MiB default cap
(`_SERVER_DEFAULT_MAX_BODY_BYTES`), but that guard runs only on the ordinary `serve!`
Request-handler path — the fork's own docs describe stream handlers as "application-managed large
uploads". Nitro never re-implemented the ceiling, so **every deployment without a reverse-proxy
body cap had none at all**: a single unauthenticated POST with a multi-gigabyte body was buffered
whole into RAM before any middleware or handler ran.

`serve()` now takes `max_body_bytes`, defaulting to the same 64 MiB the fork already promised one
layer down. A request that declares or sends more gets **413 Content Too Large** before the
middleware chain runs, and its connection is closed. Both halves of the check matter: the declared
`Content-Length` is refused up front (so an `Expect: 100-continue` client is never told to send),
and the byte count is enforced again while reading, because a chunked body declares no length at
all.

Two limits are worth knowing. The cap does **not** cover WebSocket frames, which leave the HTTP
stream at upgrade and are bounded by HTTP's own `maxframesize`. And asking for a ceiling alongside
a custom `serve(handler = …)` throws an `ArgumentError` rather than silently ignoring it — the
handler reads the body itself, so Nitro cannot enforce one there. Passing
`max_body_bytes = nothing` alongside a custom handler is accepted, since that asks for exactly the
semantics such a handler already has.

If you upload files, read the `max_body_bytes` warning in
[`docs/src/tutorial/file_uploads.md`](../docs/src/tutorial/file_uploads.md) — the "Stage & Work"
pattern for 100 MB+ files needs the ceiling raised before it works at all.

### How to find the calls to migrate

Only apps that accept bodies larger than 64 MiB need a change. Find the upload routes and the
`serve` call that must admit them:

```bash
rg -n 'serve\(' <app>/src
rg -n 'multipart|MultipartForm|Files\{|getfiles' <app>/src
```

If the app is already behind a proxy, compare against what the proxy allows — an nginx
`client_max_body_size` above 64 MiB is the signal that this change will start rejecting traffic the
proxy was letting through:

```bash
rg -n 'client_max_body_size|request_body\s+max_size' <deploy>/
```

### Migrate your app

```julia
# ✗ before — no ceiling; a large upload route worked by accident
serve(app; host = "0.0.0.0", port = 8080)

# ✓ after — state the ceiling your uploads actually need
serve(app; host = "0.0.0.0", port = 8080, max_body_bytes = 500 * 1024 * 1024)

# ✓ or opt out entirely, when a proxy already caps bodies upstream
serve(app; host = "0.0.0.0", port = 8080, max_body_bytes = nothing)
```

Nothing changes for an app that stays under 64 MiB — that is the whole reason the default matches
the fork's number rather than the lower figure most frameworks pick (Plug 8 MB, ASP.NET Core
30 MB, Express 100 KB). Setting the limit to the smallest value your routes actually need is still
the better posture; the default is a floor, not a recommendation.
