## WebSocket routes — a request that is not an upgrade now gets `426`, not `200 "false"`

- **Version**: 0.5.0
- **Nitro ref**: [#384](https://github.com/PingoLee/Nitro.jl/issues/384) ; `src/core/transport.jl`
- **Recorded**: 2026-09-27
- **Severity**: behavior change. A request to a WebSocket route that is not a valid upgrade used to
  be answered `200` with the body `false`. It now gets `426 Upgrade Required` or `400 Bad Request`.
  A valid handshake is unchanged.

### What changed

A route registered with `method = "WEBSOCKET"`, or with a handler whose first argument is a
`WebSocket`, returned `HTTP.WebSockets.isupgrade(req)`'s `false` for anything that was not a valid
handshake, and the serializer answered it as a successful `200`. That covered a browser tab opening
the URL, a malformed handshake, and — most often — a reverse proxy that does not forward
`Upgrade`/`Connection`. Every layer in between, the access log included, recorded success.

| Request to a WebSocket route | Before | After |
|---|---|---|
| No `Upgrade: websocket`, or no `Connection: upgrade` (a plain `GET`, a browser tab, a proxy that dropped either header) | `200`, body `false` | `426`, `Upgrade: websocket`, `Connection: Upgrade` |
| Both headers, `Sec-WebSocket-Version` other than `13` | `200`, body `false` | `426`, plus `Sec-WebSocket-Version: 13` |
| Both headers, but no version, no or an invalid `Sec-WebSocket-Key`, or a method other than `GET` | `200`, body `false` | `400` |
| A valid handshake | `101` | unchanged |

Each case logs one warning the first time it happens, with the per-request detail at debug level.

**What can need an edit:** anything that probed a WebSocket path with an ordinary request and
expected a `2xx` — an uptime or health check, a load-balancer probe, a smoke test, a test suite
asserting on the `false` body.

### How to find the calls to migrate

```bash
# The WebSocket routes themselves:
grep -rnE 'method *= *"WEBSOCKET"|::(HTTP\.WebSockets\.)?WebSocket\b' --include=*.jl .
# Then, for each path the first command found, look for health checks, load-balancer probes
# and tests that request it without upgrading. With a WebSocket route at "/ws/chat":
grep -rn '/ws/chat' --include=*.jl --include=*.yml --include=*.yaml --include=*.conf .
```

### Migrate your app

```julia
# ✗ before — a health check that GETs the WebSocket path and expects success
@test HTTP.get("http://127.0.0.1:8080/ws"; status_exception = false).status == 200

# ✓ after — either expect the 426, or open a real WebSocket
@test HTTP.get("http://127.0.0.1:8080/ws"; status_exception = false).status == 426
HTTP.WebSockets.open("ws://127.0.0.1:8080/ws") do ws
    # ...
end
```

For a load balancer, point the health check at an ordinary `GET` route rather than at the
WebSocket path.
