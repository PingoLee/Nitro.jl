# Behind a Reverse Proxy

When Nitro runs behind nginx, Caddy, a Kubernetes ingress or a CDN, the TCP connection it sees
comes from the *proxy*, not from your user. Anything that keys on the client IP — rate limiting,
audit logging, allow/deny lists — needs to be told how to recover the real address, and told
*carefully*: the headers that carry it are written by whoever is on the other end of the socket.

## The default: no headers are trusted

Out of the box Nitro uses the socket peer address and ignores every forwarding header:

```julia
serve(middleware = [ExtractIP()])
```

This is always safe and sometimes wrong. Behind a proxy, every client shares the proxy's address,
so they all land in one rate-limit bucket and your access log records the proxy on every line.
That is a *degradation*, not a vulnerability — which is the trade-off Nitro picks by default.

## Enabling header parsing

To read a forwarding header you must declare two things together:

```julia
serve(middleware = [
    ExtractIP(forwarded_header = :x_forwarded_for,
              trusted_proxies  = [ip"127.0.0.1"]),
])
```

| Keyword | What it means |
|---|---|
| `trusted_proxies` | The peers whose forwarding header may be believed. `IPAddr` values or CIDR strings. |
| `forwarded_header` | The **one** header your proxy writes: `:x_forwarded_for`, `:x_real_ip`, `:cf_connecting_ip`, or `:true_client_ip`. |

Setting either one alone is an `ArgumentError` at startup. A trust boundary with no header named
reads nothing; a header with no trust boundary is honored from any client, which is the whole
problem. Nitro refuses both rather than starting in a configuration that looks active and isn't.

**Only the header you name is ever read.** If you declare `:x_forwarded_for`, a request carrying
`CF-Connecting-IP` is not consulted at all — so a proxy that forgets to strip a vendor header
cannot be used to bypass your configuration.

## Your proxy must *set* the header, not pass it through

`X-Real-IP`, `CF-Connecting-IP` and `True-Client-IP` carry a single address, and Nitro believes
whatever the trusted proxy wrote. If your proxy forwards a client-supplied value unchanged, the
client controls it. Configure the proxy to overwrite:

```nginx
location / {
    proxy_set_header X-Real-IP        $remote_addr;
    proxy_set_header X-Forwarded-For  $proxy_add_x_forwarded_for;
    proxy_pass       http://127.0.0.1:8080;
}
```

Strip the forwarding headers you do *not* use as well. Nitro no longer depends on that — it reads
one header and one only — but downstream tooling that parses your logs generally does.

## How `X-Forwarded-For` is resolved

`X-Forwarded-For` is a chain, appended to by each hop: `client, proxy1, proxy2`. The leftmost entry
is the one furthest from you, and it is the entry a client can write for itself. Nitro therefore
walks the chain **right to left**, discarding hops it recognizes as your own proxies, and takes the
first address that is not one of them.

```
X-Forwarded-For: 9.9.9.9, 203.0.113.7
                 ~~~~~~~  ~~~~~~~~~~~
                 client   appended by your proxy —
                 wrote    the address it really saw
                 this
```

With `trusted_proxies = [ip"127.0.0.1"]` and the socket peer being loopback, the resolved client is
`203.0.113.7`. The prepended `9.9.9.9` is never reached, so rotating it buys nothing.

Edge cases resolve conservatively — when in doubt, Nitro returns the socket peer, which degrades to
a shared bucket rather than letting a client choose its own:

| Situation | Result |
|---|---|
| An entry that does not parse | Socket peer. The chain cannot be trusted past a value we can't read. |
| Every entry is a trusted proxy | Socket peer. The request originated inside your own infrastructure. |
| Header absent or empty | Socket peer. |
| Blank entries (`,,`, trailing comma) | Skipped; the walk continues. |
| Entry carries a port (`203.0.113.7:1234`, `[2001:db8::1]:443`) | Port stripped, address used. |
| The header appears on several lines | Treated as one chain, joined in order (RFC 9110 §5.3). A client-sent line cannot shadow the one your proxy appended. |

!!! warning "Never put a trusted-proxy address on an IP allow-list"

    The fallback above lands on the socket peer — which, in a proxied deployment, *is* one of
    your `trusted_proxies` addresses, very often `127.0.0.1`. A client who can force the fallback
    (by sending an unreadable boundary entry) therefore gets `getip(req) == 127.0.0.1`.

    That is harmless for a rate limit — they land in the shared bucket. It is **not** harmless if
    loopback is on an allow-list, as in "admin endpoints reachable only from localhost": the
    degradation becomes an escalation. Gate admin access on authentication, not on a client IP
    that a forwarding header can steer.

## Dynamic proxy addresses: use CIDR

Exact addresses work for a local nginx, but a Kubernetes ingress pod gets a new IP on every
rollout and a CDN publishes ranges. `trusted_proxies` accepts CIDR strings, and entries may be
mixed freely with `IPAddr` values:

```julia
# Kubernetes: trust the pod CIDR rather than any single pod.
# Scope this as tightly as your platform allows — a pod CIDR contains EVERY workload, not
# just the ingress, so any pod that can reach the Service directly is believed. Prefer the
# ingress controller's own subnet, and pair it with a NetworkPolicy that stops pods from
# bypassing the ingress.
ExtractIP(forwarded_header = :x_forwarded_for,
          trusted_proxies  = ["10.244.0.0/16"])

# Cloudflare in front of a local nginx that rewrites X-Real-IP from its own peer
ExtractIP(forwarded_header = :x_real_ip,
          trusted_proxies  = [ip"127.0.0.1"])

# Mixed literals
ExtractIP(forwarded_header = :x_forwarded_for,
          trusted_proxies  = [ip"127.0.0.1", "10.244.0.0/16", "2400:cb00::/32"])
```

A catch-all range (`"0.0.0.0/0"`, `"::/0"`) is rejected at construction — it would trust the
forwarding header from every peer on the internet, which is exactly what the gate exists to
prevent. IPv4 and IPv6 ranges never match across families, and an IPv4-mapped IPv6 peer
(`::ffff:127.0.0.1`, which some dual-stack listeners report) matches an IPv4 entry as you'd expect.

## Rate limiting

`RateLimiter` builds an `ExtractIP` internally, so it takes the same two keywords:

```julia
serve(middleware = [
    RateLimiter(rate_limit = 100, window = Minute(1),
                forwarded_header = :x_forwarded_for,
                trusted_proxies  = [ip"127.0.0.1"]),
])
```

If you would rather compose it yourself, set `auto_extract_ip = false` and put `ExtractIP` in the
chain ahead of the limiter. Middleware runs top-down, so anything that reads `getip(req)` must sit
*below* whatever resolved it. The two trust keywords then belong on your `ExtractIP` call — passing
them to the limiter as well is an `ArgumentError`, because with `auto_extract_ip = false` the
limiter builds no extractor and they would silently do nothing:

```julia
serve(middleware = [
    ExtractIP(forwarded_header = :x_forwarded_for, trusted_proxies = [ip"127.0.0.1"]),
    RateLimiter(rate_limit = 100, window = Minute(1), auto_extract_ip = false),
])
```

## Auditing: the socket peer is preserved

`ExtractIP` records the address that actually connected before it overwrites the client IP:

```julia
function handler(req)
    getip(req)      # the resolved client — may come from a forwarding header
    getpeerip(req)  # the socket peer — always the real TCP connection
end
```

A forged header can change `getip`, but nothing a client sends can change `getpeerip`. Logging both
is what lets you tell a proxied request from a direct one after an incident. Without `ExtractIP` in
the pipeline the two are the same value.

## Checklist

- [ ] Declare `forwarded_header` and `trusted_proxies` together, or neither.
- [ ] Make the proxy **set** (not forward) that header.
- [ ] Strip the forwarding headers you don't use at the proxy.
- [ ] Use CIDR ranges where proxy addresses are dynamic.
- [ ] Put `ExtractIP` above anything that reads the client IP.
- [ ] Confirm the resolved IP is what you expect before relying on it for a limit — log `getip`
      and `getpeerip` side by side once in staging.
