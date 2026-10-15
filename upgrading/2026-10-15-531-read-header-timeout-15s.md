## `serve(read_header_timeout = …)` defaults to 15 seconds, not 120 (#531)

- **Version**: 0.6.0
- **Nitro ref**: [#531](https://github.com/PingoLee/Nitro.jl/issues/531) ; `src/constants.jl`
- **Recorded**: 2026-10-15
- **Severity**: **behavior change (security default).** An app that does not set
  `read_header_timeout` now gives a client 15 seconds, not 120, to finish a request head.

### What changed

`DEFAULT_READ_HEADER_TIMEOUT_SECONDS` is now `15.0`. It was 120 only because, through HTTP.jl
2.8, this deadline was also the keep-alive idle limit, and a backend must not close idle
connections before its proxy does. Since HTTP.jl 2.9 the idle wait has its own deadline,
`idle_timeout`, which stays at 120 seconds. So the header deadline now bounds only a client that
began a request and has not finished its head: the Slowloris window. A connection held that way
is now dropped 8× sooner.

It is the same bound as before, with a different number. Past it the server answers `408` and
closes the connection. It does not cover the request body; that is `read_timeout`'s job.

**A fresh connection's deadline runs from accept**, because there is no idle wait before a
connection's first request. A socket opened and left silent for 15 seconds, such as a browser
preconnect, is now answered `408` and closed. Browsers open a new connection when they need one.

**What did not change:** the keep-alive idle limit (`idle_timeout`, 120 s), so the reasoning for
sizing it against an nginx or ALB pool still holds. Behind nginx the change rarely matters: it
sends the backend each head in one go, and pools an upstream connection only after a response on
it. **The exception is a load balancer that opens backend connections ahead of requests and holds
them idle:** those connections now get a `408` and are closed after 15 seconds, which can surface
as sporadic `502`s. Set `read_header_timeout` at or above that balancer's idle timeout.

### How to find the calls to migrate

Only apps that relied on the default and either serve clients that take more than 15 seconds to
send a request head, or sit behind a balancer that pre-opens idle backend connections. These 408s
are written by HTTP.jl's connection loop before any Nitro middleware runs, so **Nitro's own access
log does not show them**: look in the proxy's upstream log (408s, or upstream connections closed
early) and for 408s or `502`s on the client side.

```bash
rg -n 'read_header_timeout' <app>/src <app>/bin   # an app that sets it explicitly is unaffected
```

### Migrate your app

```julia
# ✗ before — relied on the 120 s default
serve(app; host = "0.0.0.0", port = 8080)

# ✓ after — nothing to change for most apps; to keep the old bound explicitly:
serve(app; host = "0.0.0.0", port = 8080, read_header_timeout = 120)
```
