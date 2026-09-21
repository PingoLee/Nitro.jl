# Behind a Reverse Proxy

In production, Nitro expects to sit behind nginx, Caddy, a Kubernetes ingress or a CDN. That proxy
is not just a router — it owns TLS, your static assets, and the transport-level limits that protect
the Julia process. This page covers what to give it, the two configurations that work out of the
box, and how to recover the real client IP afterwards without letting anyone forge it.

## What the proxy owns, and what it cannot

| Concern | Owner |
|---|---|
| TLS termination and certificates | **Proxy** — Nitro speaks plain HTTP and has no TLS story |
| Static assets, SPA history fallback | **Proxy** in production (see below) |
| Request body caps, connection timeouts, compression | **Proxy first, app second** — Nitro has no body cap of its own yet, so a deployment without a proxy has none at all |
| Coarse per-IP rate limiting | **Proxy first, app second** — `RateLimiter` still matters in development and as a second layer |
| Per-user rate limiting, quotas | **App** — needs identity |
| **Authentication and authorization** | **App, always** |
| CSRF, sessions | **App, always** |

The last two rows are not a matter of preference. A proxy sees a URL, some headers and a peer
address; it cannot know whether the authenticated caller owns the record they asked for. Guards like
`login_required` and ownership checks inside your handlers are the only thing enforcing that. A
`location /admin/ { allow 10.0.0.0/8; }` block is a fine *second* layer and a dangerous *only* one.

Nitro's file mounts — `staticfiles`, `spafiles`, `dynamicfiles` — are a development convenience with
a safe floor, not a production asset pipeline. They read files into memory, do not compress, and
serve only the files that existed at startup. They *do* handle conditional GETs (`ETag`,
`Last-Modified`, `304`) and byte ranges, so a warm client costs a `304` rather than a body — but a
proxy still does all of it upstream, and with `sendfile`. The reasoning is recorded in
`docs/design/static-serving-boundary.md`.

Cache lifetime is yours to state, because only you know which assets are content-hashed:

```julia
staticfiles("dist/assets", "assets"; cache_control = "public, immutable, max-age=31536000")
spafiles("dist", "";        cache_control = "no-cache")   # the shell must revalidate
```

There is deliberately no default — a `max-age` guessed on your behalf is wrong more often than
right, and guessing high pins clients to a stale asset with no way to recover.

### Large files hold a descriptor, and `proxy_buffering` is why that is fine

A mounted file over `stream_threshold` (8 MiB by default), and any `Res.file(req, path;
stream = true)`, is sent in chunks from an open handle rather than buffered in memory. Peak memory
stops scaling with file size — but the handle stays open for as long as the transfer takes, so a
slow client now costs a **file descriptor** where it used to cost RAM.

Keep nginx's default `proxy_buffering on` for these routes. nginx drains Nitro at LAN speed, Nitro
closes the handle immediately, and nginx feeds the slow client from its own buffers. Without
buffering, Nitro holds one descriptor per in-flight download for the client's full transfer time,
and the default `ulimit -n` of 1024 becomes your real concurrency limit for downloads.

The two places you may have turned buffering **off** are SSE and WebSockets, and the worked config
above already scopes `proxy_buffering off` to those locations only. Do not widen it to a location
that serves files.

## Why this matters more than usual for Nitro

Nitro runs every request on its own thread — there is no event loop. A slow client therefore occupies
a **thread**, not a cheap continuation. nginx buffers request and response bodies by default, so
Nitro only ever sees complete requests; the proxy absorbs the slow-client cost that would otherwise
sit in your thread pool. Treat request timeouts and body caps at the proxy as capacity protection,
not just hygiene.

## nginx

```nginx
upstream nitro {
    server 127.0.0.1:8080;
    keepalive 32;
}

server {
    listen 80;
    listen [::]:80;
    server_name app.example.com;

    # certbot writes the challenge here, over plain HTTP — it must be matched
    # before the redirect below.
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen      443 ssl;
    listen [::]:443 ssl;
    http2 on;                      # nginx < 1.25.1: use `listen 443 ssl http2;`
    server_name app.example.com;

    ssl_certificate     /etc/letsencrypt/live/app.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/app.example.com/privkey.pem;

    root /srv/app/dist;            # your built SPA

    client_max_body_size 10m;      # reject oversize uploads before Julia sees them

    # Protect against links out of the asset tree without breaking the usual
    # atomic-deploy layout, where `dist` is itself a symlink into `releases/N`.
    # Bare `disable_symlinks on` checks every component and 403s that setup.
    disable_symlinks if_not_owner from=$document_root;

    # ACME first, and with `^~` so it wins: a regex location beats a plain prefix
    # location, so the dotfile rule below would otherwise swallow /.well-known/.
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location ~ /\. {               # nginx does NOT deny dotfiles by default
        deny all;
    }

    # Hashed build output: safe to cache forever.
    location /assets/ {
        try_files $uri =404;
        add_header Cache-Control "public, immutable, max-age=31536000";
    }

    location /api/ {
        proxy_pass         http://nitro;
        proxy_http_version 1.1;
        proxy_set_header   Connection        "";    # required for upstream keepalive
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
    }

    # Server-sent events: buffering defeats the point.
    location /api/events {
        proxy_pass         http://nitro;
        proxy_http_version 1.1;
        proxy_set_header   Connection        "";
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_buffering    off;
        proxy_cache        off;
        proxy_read_timeout 1h;
    }

    # WebSockets need the upgrade dance and a long read timeout.
    location /ws {
        proxy_pass         http://nitro;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           $http_upgrade;
        proxy_set_header   Connection        "upgrade";
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 1h;
    }

    # SPA history mode — this is what `spafiles` does in development.
    location / {
        try_files $uri /index.html;
    }
}
```

Four things in that config are easy to get wrong, and three of them fail *quietly*:

- **`proxy_set_header` does not merge across levels.** A location that sets *any* header inherits
  *none* from above. That is why the forwarding headers are repeated verbatim in every proxying
  block — omit them from the SSE and WebSocket locations and `ExtractIP` silently falls back to the
  proxy's own address on exactly your longest-lived connections.
- **A regex location beats a plain prefix location.** `location ~ /\.` therefore captures
  `/.well-known/acme-challenge/…` unless an `^~` location claims it first. Without that, everything
  works until your first certificate renewal, roughly sixty days after deployment.
- **`keepalive` needs `proxy_set_header Connection "";`.** Without it nginx sends `Connection: close`
  upstream and the pool is never reused — the directive looks active and does nothing.
- **SSE needs `proxy_buffering off`.** nginx buffers proxied responses by default, which is right for
  JSON and wrong for an event stream: without it the endpoint simply appears to hang. A WebSocket
  route missing `Upgrade`/`Connection` fails the handshake with a confusing `400`.

## Caddy

Caddy obtains and renews certificates itself, which also solves the ACME problem Nitro's mounts
cannot: `.well-known/acme-challenge/<token>` is written at renewal time, long after startup, so no
Nitro mount could ever serve it.

```caddyfile
app.example.com {
    root * /srv/app/dist
    encode zstd gzip

    request_body {
        max_size 10MB
    }

    # Be explicit rather than relying on file_server's defaults.
    @dotfiles path */.*
    respond @dotfiles 404

    handle /api/events* {
        reverse_proxy 127.0.0.1:8080 {
            flush_interval -1        # stream SSE instead of buffering
        }
    }

    handle /api/* {
        reverse_proxy 127.0.0.1:8080
    }

    handle /ws* {
        reverse_proxy 127.0.0.1:8080
    }

    handle {
        try_files {path} /index.html
        file_server
    }
}
```

Two asymmetries with the nginx config above, both in Caddy's favour:

- **The dotfile matcher does not break ACME here.** Caddy serves the HTTP-01 challenge from a route
  injected ahead of your site routes, so it is never reached by `@dotfiles`. The `^~` exception nginx
  needs has no equivalent requirement.
- **`file_server` has no dotfile default to rely on** — its hide list is empty. The explicit matcher
  is doing real work; do not delete it on the assumption Caddy handles it.

`reverse_proxy` sets `X-Forwarded-For`, `X-Forwarded-Proto` and `X-Forwarded-Host` for you and
handles WebSocket upgrades with no extra configuration. It does **not** set `X-Real-IP` — so pair it
with the `:x_forwarded_for` variant of `ExtractIP` below, not the `:x_real_ip` one.

## Keep Nitro unreachable directly

Every protection above assumes traffic arrives *through* the proxy. If the application port is
reachable another way — a published container port, a sibling pod, another user on a shared host —
the body caps, the dotfile denial and the `location /admin/` rule all evaporate silently, and any
`trusted_proxies` entry becomes forgeable by whoever can open that socket.

Nitro already defaults to `host = "127.0.0.1"`. Keep it there when the proxy is on the same machine:

```julia
serve(host = "127.0.0.1", port = 8080)     # the default
```

Only widen it when the proxy genuinely lives elsewhere, and then constrain the listener at the
network layer too — a firewall rule, a Kubernetes `NetworkPolicy`, or a private-subnet bind:

```julia
serve(host = "10.0.1.14", port = 8080)     # a specific private interface, not "0.0.0.0"
```

## Recovering the client IP

The TCP connection Nitro sees now comes from the *proxy*, not from your user. Anything that keys on
the client IP — rate limiting, audit logging, allow/deny lists — needs to be told how to recover the
real address, and told *carefully*: the headers that carry it are written by whoever is on the other
end of the socket.

### The default: no headers are trusted

Out of the box Nitro uses the socket peer address and ignores every forwarding header:

```julia
serve(middleware = [ExtractIP()])
```

This is always safe and sometimes wrong. Behind a proxy, every client shares the proxy's address,
so they all land in one rate-limit bucket and your access log records the proxy on every line.
That is a *degradation*, not a vulnerability — which is the trade-off Nitro picks by default.

### Enabling header parsing

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

### Your proxy must *set* the header, not pass it through

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

### How `X-Forwarded-For` is resolved

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

### Dynamic proxy addresses: use CIDR

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
(`::ffff:127.0.0.1`) matches an IPv4 entry as you'd expect. Nitro already demotes that form when it
reads the socket, so a *peer* reaches this matching in its IPv4 spelling — but the fold still does
real work on the other two inputs: a hop your proxy wrote into `X-Forwarded-For` as
`::ffff:10.0.0.8`, and a mapped literal or CIDR you put in `trusted_proxies` yourself.

### Rate limiting

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

#### Which addresses share a bucket

The limiter keys its buckets on a **network prefix** of the client address, not on the address
itself. The defaults are `/32` for IPv4 — one bucket per host, i.e. no grouping — and **`/64` for
IPv6**:

```julia
RateLimiter(rate_limit = 100, window = Minute(1),
            ipv4_prefix = 32,   # default
            ipv6_prefix = 64)   # default
```

IPv6 is grouped because a single host is normally handed an entire `/64` — 2^64 addresses it can
pick from freely. Keying on the full `/128` means a client sends every request from a different
source address inside *its own* allocation, lands in a brand-new bucket each time, and is never
limited, while the `X-RateLimit-*` headers keep reporting that limiting is in effect. Grouping the
allocation into one bucket is what makes the limit apply at all. `django-ratelimit` and HAProxy
default to this same `32`/`64` pair.

Widen `ipv6_prefix` if your clients are larger than a `/64` — a hosting customer may hold a whole
`/48`, which is why Let's Encrypt rate-limits at that size — and narrow it only if you know your
addressing. `/0` is rejected for either family: it puts every client on the internet into one
shared bucket while still looking per-client.

An IPv4-mapped IPv6 peer (`::ffff:203.0.113.7`) is folded onto its IPv4 form first, so it shares a
bucket with the plain spelling rather than opening a second one. This is not made redundant by the
socket peer already arriving demoted: the bucket key is built from `getip(req)`, which behind a
trusted proxy is the address resolved out of the header, not the peer.

### Auditing: the socket peer is preserved

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

"Preserved" is about *which* address, not which spelling of it. Both accessors report one canonical
form per host: a dual-stack listener that reports an IPv4 client as `::ffff:203.0.113.7` is seeded
as `203.0.113.7`, so the same host logs identically whether it connected directly or came through
your proxy. That demotion happens where `serve` reads the socket, so it applies even with no
`ExtractIP` in the pipeline.

## Checklist

**The proxy layer**

- [ ] TLS terminates at the proxy; Nitro listens on plain HTTP behind it.
- [ ] Static assets and the SPA fallback are served by the proxy, not by `staticfiles`/`spafiles`.
- [ ] Dotfiles are denied explicitly — nginx does not do it for you.
- [ ] A request body cap is set at the proxy (`client_max_body_size` / `request_body max_size`).
- [ ] SSE routes disable response buffering; WebSocket routes pass `Upgrade`/`Connection`.
- [ ] The Nitro port is not reachable except through the proxy — check the container's published
      ports and any network policy, not just `host`.
- [ ] Authorization is enforced in handlers. No `location` block is the only thing guarding a route.

**Client IP**

- [ ] Declare `forwarded_header` and `trusted_proxies` together, or neither.
- [ ] Make the proxy **set** (not forward) that header.
- [ ] Strip the forwarding headers you don't use at the proxy.
- [ ] Use CIDR ranges where proxy addresses are dynamic.
- [ ] Put `ExtractIP` above anything that reads the client IP.
- [ ] Confirm the resolved IP is what you expect before relying on it for a limit — log `getip`
      and `getpeerip` side by side once in staging.
