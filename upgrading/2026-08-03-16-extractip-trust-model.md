## `ExtractIP` trust model rebuilt; `trust_forwarded` removed (#16)

- **Version**: 0.2.0
- **Nitro ref**: #16; `src/middleware/extract_ip.jl`, `src/middleware/rate_limiter.jl`, `src/core.jl`
- **Recorded**: 2026-08-03
- **Severity**: **breaking (removed kwarg + changed resolution)** — security fix.

### What changed

Under `trusted_proxies`, the configuration the old docstring called "the recommended, safe option",
the resolved client IP was attacker-controllable. Two defects: `X-Forwarded-For` was read
**leftmost-first** — the client-controlled end of the chain, so a client that prepended
`X-Forwarded-For: 9.9.9.9` before nginx appended the real address won outright — and
`CF-Connecting-IP`/`True-Client-IP` were honored *above* `X-Forwarded-For` unconditionally, which
no ordinary nginx config strips. Either header could be rotated to mint an unlimited number of
rate-limit buckets, forge access-log entries, and slip past IP allow/deny lists.

The trust model is now declarative. `ExtractIP` reads **exactly one** header, named by the
operator, and only when the socket peer is a listed proxy:

- `forwarded_header::Symbol` — `:none` (default), `:x_forwarded_for`, `:x_real_ip`,
  `:cf_connecting_ip`, `:true_client_ip`. It and `trusted_proxies` are strictly
  mutually-required; setting either alone is an `ArgumentError` at construction.
- `trusted_proxies` now accepts **CIDR strings** (`"10.244.0.0/16"`, `"2400:cb00::/32"`) mixed
  with `IPAddr` values, so k8s ingress pods and published CDN ranges are expressible. A catch-all
  range is rejected.
- `X-Forwarded-For` is walked **right-to-left**, peeling hops that match `trusted_proxies`; the
  first address that is not one of yours is the client. Unreadable chains, all-proxy chains and
  absent headers fall back to the socket peer.
- A header sent on **several lines** is treated as one value, joined in order per RFC 9110 §5.3,
  so a client-supplied line cannot shadow the one a proxy appended. This matters for proxies that
  append a new header line rather than rewriting (HAProxy's `option forwardfor`).
- Addresses resolved out of a header are returned in canonical form, so `::ffff:203.0.113.7` and
  `203.0.113.7` no longer key two different rate-limit buckets.
- `trust_forwarded` is **removed**. It trusted headers from any peer and guessed which header to
  read; passing it now throws with a message naming the replacement — on `RateLimiter` as well as
  on `ExtractIP`.
- On `RateLimiter`, `auto_extract_ip = false` is now **incompatible** with `forwarded_header` /
  `trusted_proxies` and throws. That combination built no `ExtractIP` at all, so both keywords
  were accepted, never validated, and had no effect: every client stayed in the proxy's single
  bucket while the configuration read as active. Set the IP yourself in your own middleware, or
  keep `auto_extract_ip = true` and let the limiter apply them.
- `RateLimiter` also validates the pair **itself** now, rather than deferring to the `ExtractIP`
  it composes — a bad trust configuration fails at `RateLimiter(...)`, not later at `serve()`.
- `extract_ip` returns `Union{IPAddr, Nothing}` — it previously declared `::IPAddr` while being
  able to return `nothing` for a request that never went through the server.
- New: `getpeerip(req)` returns the socket peer, preserved by `ExtractIP` before it overwrites
  `getip(req)`. No forwarding header can change it.

`ExtractIP()` with no arguments is unchanged and still the safe default: the socket peer is used
and no forwarding header is read.

### How to find the calls to migrate

```bash
rg -n 'trust_forwarded|trusted_proxies|extract_ip' <app>     # not just <app>/src — proxy trust
                                                             # is often set in config/ or env wiring
```

Every `ExtractIP`/`RateLimiter` hit needs a `forwarded_header` alongside it, and a configuration
missing one will not start — the `ArgumentError` names the absent keyword — so those call sites
cannot fail silently.

**`extract_ip` is the exception, and it is why the grep includes it.** It is now a public export
and its return type widened from `IPAddr` to `Union{IPAddr, Nothing}`. A direct call such as
`ip::IPAddr = extract_ip(req)` or `string(extract_ip(req))` breaks at runtime, and a bare
`extract_ip(req)` with no trust configured keeps returning the peer exactly as before — so this
one *does* have a silent path. Check every direct call for a `nothing` it did not previously have
to handle.

### Migrate your app

```julia
# ✗ before — the header was guessed from a fixed priority list
ExtractIP(trusted_proxies = [ip"127.0.0.1"])

# ✓ after — declare the one header your proxy writes
ExtractIP(forwarded_header = :x_forwarded_for, trusted_proxies = [ip"127.0.0.1"])

# ✗ before — trusted forwarding headers from ANY peer
ExtractIP(trust_forwarded = true)

# ✓ after — name the proxies instead; CIDR covers dynamic addresses
ExtractIP(forwarded_header = :x_forwarded_for, trusted_proxies = ["10.244.0.0/16"])

# ✗ before — same two kwargs on the rate limiter
RateLimiter(rate_limit = 100, trusted_proxies = [ip"127.0.0.1"])

# ✓ after
RateLimiter(rate_limit = 100,
            forwarded_header = :x_forwarded_for,
            trusted_proxies  = [ip"127.0.0.1"])
```

Two operational notes. Your proxy must **set** the header it writes, not forward a client-supplied
value — `proxy_set_header X-Real-IP $remote_addr`, not a pass-through — because single-valued
headers are believed as written. And if you were relying on a vendor header while declaring
`X-Forwarded-For`, that now resolves differently: only the declared header is read, which is the
point of the fix.
