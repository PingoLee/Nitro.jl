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
| Request body caps, connection timeouts, compression | **Proxy first, app second** — Nitro caps request bodies at 64 MiB by default (`serve(max_body_bytes = …)`) and closes a connection that has not sent a complete request head within 15 seconds (`serve(read_header_timeout = …)`), but the proxy rejects an oversized or slow upload before it reaches Julia at all |
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
const app = App(mod = @__MODULE__)

staticfiles(app, "dist/assets", "assets"; cache_control = "public, immutable, max-age=31536000")
spafiles(app, "dist", "";        cache_control = "no-cache")   # the shell must revalidate
```

There is deliberately no default — a `max-age` guessed on your behalf is wrong more often than
right, and guessing high pins clients to a stale asset with no way to recover.

Whoever serves the SPA shell, the proxy in production or `spafiles` in development, no handler of
yours runs for it, so the shell cannot be relied on to carry a CSRF token. The app fetches one
from an endpoint that calls `csrf_token!` instead; see
[Single-page apps](sessions_and_auth.md#Single-page-apps).

### Large files hold a descriptor, and `proxy_buffering` is why that is fine

A mounted file over `stream_threshold` (8 MiB by default), a `Res.file(req, path)` of a file over
8 MiB, and any `Res.file(req, path; stream = true)`, is sent in chunks from an open handle rather than buffered in memory. Peak memory
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

Nitro runs every request on its own task — there is no event loop, and no fixed pool of workers
to exhaust. A slow client does not hold a *thread*: its task yields while it waits for bytes, and
the thread moves on. What it does hold, for as long as it is slow, is a **file descriptor**, a
task, and whatever part of its request body has arrived. nginx buffers request and response
bodies by default, so Nitro only ever sees complete requests arriving at LAN speed; the proxy
absorbs that cost. Treat request timeouts and body caps at the proxy as capacity protection, not
just hygiene.

Nitro's own limits are the floor underneath, for a process the proxy is not in front of:

| Limit | Default | What it bounds |
|---|---|---|
| `read_header_timeout` | 15 s | How long a connection may take to send a complete request head, counted on a keep-alive connection from the next request's first byte and on a new one from accept. A Slowloris client is answered `408` and dropped |
| `idle_timeout` | 120 s | How long a keep-alive connection may sit idle between requests before it is closed |
| `max_body_bytes` | 64 MiB | How much one request body may hold |
| `max_concurrent_requests` | off | How many requests are held at once, and so, with `max_body_bytes`, how much body memory. Over it, a request is answered `503` before its body is read. A WebSocket holds one of these slots for as long as it is open, unless `max_upgraded_connections` gives WebSockets their own budget (and its handshake carried no body); see [Bounding requests in flight](@ref) |
| `max_upgraded_connections` | off | How many WebSockets are open at once — how many, not how much memory each holds. A socket counts here from its handshake, and once its `101` is sent it no longer counts against `max_concurrent_requests` — unless the handshake carried a body; over it, an upgrade is answered `503` |
| `read_timeout` | off | How long the body may take once the head has arrived. Off because a legitimate large upload over a slow link can take minutes; turn it on when the proxy is not buffering bodies for you |

`read_header_timeout` deliberately does not cover the body, so a slow upload is only cut by
`read_timeout`. `idle_timeout` is the one to size against your proxy: an nginx `upstream` pool and
an AWS ALB both close idle connections at 60 seconds, and a backend that closes them first races
the proxy reusing them, which surfaces as sporadic `502`s. Keep it above your proxy's idle
timeout if you lower it.

The other half of capacity is the process itself: how many threads it starts with, and how much
memory its garbage collector aims for. Both are covered in
[Running in Production](deployment.md).

## nginx

```nginx
# A conf.d/ file is included inside nginx's `http {}` block, so the directives
# down to `upstream` are http-level: they apply to every server below.
server_tokens off;                 # proxy-built error pages stop naming the nginx version

limit_req_zone $binary_remote_addr zone=perip:10m rate=10r/s;
limit_req_status 429;              # the default, 503, reads as an outage

upstream nitro {
    server 127.0.0.1:8080;
    keepalive 32;
}

# Catch-alls. Scanners address the bare IP; without these, the first server
# block below would be the default and answer every unknown Host.
server {
    listen      80 default_server;
    listen [::]:80 default_server;
    return 444;                    # close the connection without a response
}

server {
    listen      443 ssl default_server;
    listen [::]:443 ssl default_server;
    ssl_reject_handshake on;       # nginx >= 1.19.4; needs no certificate
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

    # One limit for every location below. A location that declares its own
    # `limit_req` drops this one rather than adding to it.
    limit_req zone=perip burst=50 nodelay;

    # HSTS, set here and not by Nitro as well. `always` reaches error responses.
    # A location with its own `add_header` drops this one: repeat it there.
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

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
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
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

    # SPA history mode — what `spafiles` does in development, minus one thing:
    # a miss that looks like a file (`/wp-login.php`) is a 404, not the shell.
    location / {
        try_files $uri @spa;
    }

    location @spa {
        if ($uri ~ \.[^/]+$) {     # looks like a file, and no file matched
            return 404;
        }
        rewrite ^ /index.html break;
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
  location missing `proxy_set_header Upgrade $http_upgrade` or `Connection "upgrade"` reaches Nitro
  as an ordinary request, and the route answers `426 Upgrade Required` — the same answer a browser
  tab opening the URL gets. Behind TLS
  termination a WebSocket route also needs `ExtractIP(forwarded_proto = …)`, or every browser
  upgrade is a `403` — see [WebSocket upgrades and the Origin check](@ref).

The rest of the config — the rate limit, the two catch-all servers, `server_tokens`, HSTS and the
`@spa` fallback — is for the traffic no user sends, and is explained in
[Hostile and scanner traffic](@ref).

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
with the `:x_forwarded_for` variant of `ExtractIP` below, not the `:x_real_ip` one. Because it
terminates TLS, WebSocket routes also need `forwarded_proto` — see
[WebSocket upgrades and the Origin check](@ref).

## Hostile and scanner traffic

Everything above assumes the clients you meant to serve. From its first hour online, an
internet-facing host also receives requests from nobody in particular: scanners probing `/.env`,
`/.git/config`, `/wp-login.php`, `/cgi-bin/` and the bare IP address. On a small app they can be
most of the traffic. None of it is dangerous to a correctly built Nitro app, but each gap below
turns it into cost: requests reaching Julia that the proxy could have refused, log volume that
buries the real records, and answers that tell a scanner to come back.

### Rate-limit at the server level, not per location

```nginx
limit_req_zone $binary_remote_addr zone=perip:10m rate=10r/s;   # http level
limit_req zone=perip burst=50 nodelay;                           # server level
```

The table at the top of this page makes coarse per-IP limiting the proxy's job; this is that job.
Put `limit_req` at the **server** level, as the worked config does, so every location inherits it,
including locations added later. `limit_req` follows the same rule as `proxy_set_header`: a
location that declares its own — a stricter zone on a login route, say — inherits **none** from
the server, so repeat the server-level line beside the stricter one. The opposite mistake is the
common one: a limit placed only on a login or fallback location leaves `location /` and `/api/`
unthrottled, and nothing reports it.

Size `burst` from your own app. An SPA's first load fetches the shell and every asset at once, so
count the requests in one cold page load and leave room above it. `limit_req_status 429` makes a
refusal say what it is; nginx's default `503` reads as an outage in monitoring.

The key has two blind spots:

- `$binary_remote_addr` is one key per address, so an IPv6 client gets a fresh bucket from every
  address in its /64 (see [Which addresses share a bucket](@ref)). `limit_req_zone` has no prefix
  option. `RateLimiter`, which groups IPv6 by /64 by default, closes that gap, so keep it as the
  second layer, configured with `forwarded_header` and `trusted_proxies` as in
  [Rate limiting](@ref). Without them it sees only the proxy's address, and every client shares one
  bucket.
- Behind a CDN, `$remote_addr` is the CDN's edge, and every user behind that edge shares one bucket.
  Restore the client address first with nginx's `realip` module (`set_real_ip_from` for the CDN's
  ranges, `real_ip_header`). It rewrites `$remote_addr` and `$binary_remote_addr`, so the limit and
  the `X-Real-IP` and `X-Forwarded-For` headers the worked config sends all carry the restored
  client. That is the setup the Cloudflare `ExtractIP` example below assumes. Distribution and
  nginx.org packages include the module; a build from source needs `--with-http_realip_module`.

Caddy has no built-in rate limiter. It needs a plugin, such as `caddy-ratelimit` built in with
`xcaddy`; without one, `RateLimiter` is the only limit you have.

### Drop requests for hosts you do not serve

Much scanner traffic addresses the machine by IP (`Host: 203.0.113.7`), or by some other name that
happens to resolve to it. nginx hands a request that no `server_name` matches to the port's
**default server**, and when none is declared that is the first `server` block listening on the
port: your app. The two catch-all blocks in the worked config take that role instead.

- On port 443, `ssl_reject_handshake on` (nginx 1.19.4 and later) refuses the TLS handshake for any
  name without a server block of its own. It needs no certificate, and the client never gets as
  far as an HTTP request.
- On port 80, `return 444` closes the connection without writing a response. The app's own port-80
  block keeps redirecting and serving the ACME challenge, because it names its `server_name`.

A port has only one default server. Debian and Ubuntu packages ship `sites-enabled/default` with
`listen 80 default_server`, so `nginx -t` refuses the config with *a duplicate default server for
0.0.0.0:80* until you disable that site or remove its `default_server`. Health checks and uptime
monitors that probe `http://<ip>/` or `https://<ip>/` fail after this change too; point them at
the hostname.

### Do not announce the version

`server_tokens off` takes the version out of the `Server` header and out of the error pages nginx
writes itself: the `404` for a missing asset, the `413` from `client_max_body_size`, the
`502`–`504` while Nitro restarts. Left on, every response tells a scanner the exact build
(`Server: nginx/1.24.0 (Ubuntu)`) to match against a CVE list. It sits at the http level so every
server block gets it.

### Never send one request to Nitro twice

nginx's `error_page` can hand a failed response on to a named location. Do not point it back at
Nitro:

```nginx
location /api/ {
    proxy_pass             http://nitro;
    proxy_intercept_errors on;
    error_page 404 = @app;          # wrong: @app proxies the same request again
}

location @app {
    proxy_pass http://nitro;
}
```

Every `404` then reaches the app **twice**: two access-log records, two hits against `RateLimiter`,
two runs of every middleware — for exactly the requests scanners send most. If `@app` looks on disk
first instead, it is worse: a file that happens to exist there turns Nitro's `404` into a `200`,
serving something the route refused.

If you want a fallback to files on disk, decide it **before** the request is proxied, and leave
`proxy_intercept_errors` off:

```nginx
location /api/ {
    try_files $uri @nitro;          # a file on disk, else Nitro — once
}

location @nitro {
    proxy_pass http://nitro;        # plus the proxy_set_header lines above
}
```

Nitro's `404` is an answer, not an error to recover from.

### Keep file-shaped misses out of the SPA fallback

A bare `try_files $uri /index.html` answers every miss with the app shell and a `200`,
`/wp-login.php` and `/phpmyadmin/index.php` included. A scanner records that as a hit and comes
back with the follow-up probes. The worked config sends misses to `location @spa` instead, which
answers `404` when the last path segment has an extension; only extension-free paths, which is what
client routes look like, get the shell. The cost is a client route whose last segment contains a
dot (`/users/jane.doe`): give it another shape, or a `location` of its own.

Two shorter ways to write the same rule look equivalent and are not:

- **A top-level `location ~ \.[^/]+$`** outranks the plain-prefix `/api/` and `/assets/`
  locations, because a regex location beats a prefix one. `/api/report.csv` stops reaching Nitro
  and is answered `404`, and `/assets/*` loses its `Cache-Control`.
- **The same regex nested inside `location /`** is checked *before* the server-level regexes, so it
  wins over `location ~ /\.` and serves `/.env`.

A named location is reached only after `try_files` has missed, so it can do neither.

`spafiles` still answers every miss with the shell, as a bare `try_files $uri /index.html` does. It
is the development server; in production the SPA fallback is the proxy's, as recorded in
`docs/design/static-serving-boundary.md`.

### Ban at the proxy, from its access log

An address that probes path after path is worth banning, and the tools for that read the proxy's
log: fail2ban, or CrowdSec with its nginx collection. Do not build banning into the app.
`RateLimiter` slows a client within a window and then forgets it, and `AccessLog` records requests;
neither is a ban layer, and a ban decided in Julia still costs a request that reached Julia.

Point the ban at the **access log**. In the worked config, scanner misses are answered by
`try_files … =404` and `return 404`, which write nothing to nginx's error log. fail2ban's stock
`nginx-botsearch` jail — the scanner jail — reads the error log by default, so on this config it
sees nothing until you point its `logpath` at the access log. Rejections by `limit_req` *are*
written to the error log, so the stock `nginx-limit-req` jail works as shipped.

### Set HSTS in one place

`Strict-Transport-Security` can come from the proxy (`add_header … always`, as in the worked
config) or from Nitro (`serve(app; security_headers = SecurityHeaders(hsts = Day(365)))`). Choose
**one**. Two copies do not add up: a browser that receives two obeys only the first (RFC 6797
§8.1), so the other is silently ignored, and the two drift apart the first time one is edited. The
proxy is usually the better home. It is where TLS terminates — Nitro speaks plain HTTP and cannot
tell whether TLS terminated upstream — and only the proxy reaches the responses it writes itself.

The worked config handles two nginx details:

- **`always`.** Without it, nginx adds the header only to a fixed list of success and redirect
  codes, so every `4xx` and `5xx` goes out without it.
- **`add_header` does not merge across levels either.** `location /assets/` has an `add_header
  Cache-Control` of its own, so it inherits none of the server's `add_header` lines and repeats the
  HSTS one. Remove that repeat and every asset response loses HSTS while every page keeps it.
  nginx 1.29.3 and later can change the rule with `add_header_inherit merge`; the repeated line
  works on every version.

If Nitro sets it instead, delete the proxy's lines, and pass `SecurityHeaders` as
`security_headers =` rather than in `middleware`, so it reaches the responses Nitro builds outside
the router as well (see [`SecurityHeaders`](@ref)).

## Keep Nitro unreachable directly

Every protection above assumes traffic arrives *through* the proxy. If the application port is
reachable another way — a published container port, a sibling pod, another user on a shared host —
the body caps, the dotfile denial and the `location /admin/` rule all evaporate silently, and any
`trusted_proxies` entry becomes forgeable by whoever can open that socket.

Nitro already defaults to `host = "127.0.0.1"`. Keep it there when the proxy is on the same machine:

```julia
serve(app; host = "127.0.0.1", port = 8080)     # the default
```

Only widen it when the proxy genuinely lives elsewhere, and then constrain the listener at the
network layer too — a firewall rule, a Kubernetes `NetworkPolicy`, or a private-subnet bind:

```julia
serve(app; host = "10.0.1.14", port = 8080)     # a specific private interface, not "0.0.0.0"
```

## Recovering the client IP

The TCP connection Nitro sees now comes from the *proxy*, not from your user. Anything that keys on
the client IP — rate limiting, audit logging, allow/deny lists — needs to be told how to recover the
real address, and told *carefully*: the headers that carry it are written by whoever is on the other
end of the socket.

### The default: no headers are trusted

Out of the box Nitro uses the socket peer address and ignores every forwarding header:

```julia
serve(app; middleware = [ExtractIP()])
```

This is always safe and sometimes wrong. Behind a proxy, every client shares the proxy's address,
so they all land in one rate-limit bucket and your access log records the proxy on every line.
That is a *degradation*, not a vulnerability — which is the trade-off Nitro picks by default.

### Enabling header parsing

To read a forwarding header you must declare two things together:

```julia
serve(app; middleware = [
    ExtractIP(forwarded_header = :x_forwarded_for,
              trusted_proxies  = [ip"127.0.0.1"]),
])
```

| Keyword | What it means |
|---|---|
| `trusted_proxies` | The peers whose forwarding header may be believed. `IPAddr` values or CIDR strings. |
| `forwarded_header` | The **one** header your proxy writes: `:x_forwarded_for`, `:x_real_ip`, `:cf_connecting_ip`, `:true_client_ip`, or `:forwarded` (RFC 7239). |
| `forwarded_proto` | The header your proxy writes the client's scheme into: `:x_forwarded_proto` or `:forwarded` (RFC 7239). Only needed for WebSocket routes behind TLS termination — see [WebSocket upgrades and the Origin check](@ref). |

A trust boundary with no header named, and a header with no trust boundary, are each an
`ArgumentError` at startup. The first reads nothing; the second is honored from any client, which
is the whole problem. Nitro refuses both rather than starting in a configuration that looks active
and isn't.

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

### How `Forwarded` is resolved

RFC 7239 standardizes the same information in one header,
`Forwarded: for=203.0.113.7;proto=https`. It is a chain of *elements*, one per proxy, each
describing the connection that proxy received. With `forwarded_header = :forwarded`, Nitro walks
the elements **right to left** by their `for=` parameter, under exactly the rules in the table
above. Parameter names are case-insensitive, values may be quoted, and IPv6 arrives quoted and
bracketed (`for="[2001:db8::1]:4711"`). A `for=` of `unknown` or an obfuscated identifier
(`_hidden`) names no address, so it stops the walk at the socket peer, like an entry that does not
parse.

```
Forwarded: for=9.9.9.9;proto=https, for=203.0.113.7;proto=http
           ~~~~~~~~~~~~~~~~~~~~~~~  ~~~~~~~~~~~~~~~~~~~~~~~~~~
           client wrote this        your proxy appended this:
                                    who connected, and over what
```

The resolved client is `203.0.113.7`. **The scheme is `http`, not `https`.** With
`forwarded_proto = :forwarded`, the `proto=` that counts is the one in the element that names the
client. Your own proxy wrote that element about the connection the client opened, so it is the only
`proto=` in the header the client cannot choose. That is why it differs from `X-Forwarded-Proto`,
where the leftmost value counts: that header carries no address to bind the scheme to. An element
from your proxy with no usable `for=` still supplies its `proto=`, so a proxy that sends only
`Forwarded: proto=https` works for a scheme-only configuration.

Nitro reads the header from the right, and only as far as the walk goes, so whatever a client
writes in front of your proxy's element cannot change how that element is parsed — not an
unterminated `"`, not malformed bytes. Even so, have the **edge** proxy *set* the header rather
than append to what the client sent (inner proxies append their own element after it), and write
**only values the proxy derives itself**:

```nginx
proxy_set_header Forwarded "for=\"$remote_addr\";proto=$scheme";
```

Never interpolate a client-controlled variable into it — `host=$host`, `$http_*`. A `Host` of
`x,for=9.9.9.9;proto=https` would then *inject an element to the right of yours*, which no parser
can tell apart from one your proxy wrote. `$remote_addr` goes in quotes because an IPv6 address
must be quoted, and that form is written without the brackets RFC 7239 asks for; Nitro reads it
either way.

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
serve(app; middleware = [
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
serve(app; middleware = [
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

## WebSocket upgrades and the Origin check

Every WebSocket upgrade passes a same-origin check: a browser's `Origin` must name this server's own
scheme, host and port, or be listed with `WebSocketOrigins` (see
[Allowing a page from another origin](@ref) below). That check is what stops a page on another
site from opening a socket that rides your users' cookies — cross-site WebSocket hijacking — and it
is the only thing that does.

Behind a proxy that terminates TLS, the *scheme* half is wrong unless Nitro is told. The page is
`https://app.example.com`, so the browser sends `Origin: https://app.example.com`, but the proxy
reaches Nitro over plain TCP — and a secure origin on an insecure connection is refused with `403`,
for every browser. Tell `ExtractIP` which header the proxy writes the client's scheme into. Both
configs above already send it (`X-Forwarded-Proto $scheme`; Caddy does it by default):

```julia
serve(app; middleware = [
    ExtractIP(forwarded_header = :x_forwarded_for,
              forwarded_proto  = :x_forwarded_proto,
              trusted_proxies  = [ip"127.0.0.1"]),
])
```

`forwarded_proto` can also be set without `forwarded_header` if the scheme is all you need. The
value is read only from a peer in `trusted_proxies`, the leftmost entry of an `X-Forwarded-Proto`
list counts, and Traefik's `wss`/`ws` are read as `https`/`http`. A proxy that sends RFC 7239
`Forwarded` instead is configured with `forwarded_proto = :forwarded`; see
[How `Forwarded` is resolved](@ref) for which `proto=` counts.

- **Keep `Host` the public host.** The Origin is compared with the `Host` Nitro receives.
  `proxy_set_header Host $host` does that; nginx's default, the upstream's own name, turns every
  upgrade back into a `403`. Behind a non-default public port use `$http_host`, which keeps the port.
- **Never strip or rewrite `Origin` to make the 403 go away.** A handshake with no `Origin` is let
  through — that is how a non-browser client is recognized — so stripping it switches the check off
  for everyone, including the cross-site page it exists to stop.
- **The scheme cannot admit another site.** It only decides whether `https://<Host>` or
  `http://<Host>` is same-origin: `Origin: https://evil.example` is refused whatever the proxy
  reports, and a scheme sent by a peer outside `trusted_proxies` is ignored.
- A refused upgrade logs **one** warning the first time it happens, with each refusal's `Origin` and
  status at debug level. It is not an application error, and it records the `403` the client got.

### Allowing a page from another origin

An SPA served from a different origin than its API — `https://app.example.com` opening a socket to
`https://api.example.com`, or a page on a CDN host — is not same-origin, so its upgrade is refused
whatever the proxy reports. List the page's origin with `WebSocketOrigins` instead of loosening the
check:

```julia
serve(app; middleware = [WebSocketOrigins(["https://app.example.com"])])

# or only on the routes that need it:
urlpatterns(app, "",
    path("/ws/chat", chat; method = "WEBSOCKET",
         middleware = [WebSocketOrigins(["https://app.example.com"])]),
)
```

- **Matching is exact** on scheme, host and port — never a prefix, suffix or pattern.
  `https://app.example.com` admits neither `http://app.example.com` nor
  `https://evil-app.example.com`. `:443` on `https` (and `:80` on `http`) may be written or left
  out.
- **Same-origin stays allowed**, and so does a handshake with no `Origin`.
- **The layer closest to the route wins.** A route-level list replaces a global one rather than
  adding to it, and `WebSocketOrigins(String[])` narrows a route back to same-origin only.
- **`Cors` does not govern handshakes.** Its `allowed_origins` controls which pages may *read*
  ordinary responses; it admits no WebSocket. Give each its own list, even when the two match.
- Entries are validated when the middleware is built: `*`, `null`, `wss://…`, a trailing `/` and a
  non-ASCII host are each an `ArgumentError` naming the fix.

### `CrossOriginProtection` and `Host`

[`CrossOriginProtection`](@ref) needs nothing from the proxy for a current browser on an HTTPS
site: `Sec-Fetch-Site` travels end to end and decides on its own. Browsers send that header only to
HTTPS and localhost, though, so on a plain-HTTP public side every browser takes the fallback. The
fallback compares the
`Origin` host with the **`Host` header** Nitro receives, never `X-Forwarded-Host`, so the same rule
applies as for WebSocket upgrades above: forward the public `Host` (`proxy_set_header Host $host`,
or `$http_host` behind a non-default port). The scheme is not compared, so TLS termination needs no
`forwarded_proto` for it. Never strip `Sec-Fetch-Site` or `Origin` at the proxy: a request with
neither is treated as a non-browser client and let through.

## Checklist

**The proxy layer**

- [ ] TLS terminates at the proxy; Nitro listens on plain HTTP behind it.
- [ ] Static assets and the SPA fallback are served by the proxy, not by `staticfiles`/`spafiles`.
- [ ] Dotfiles are denied explicitly — nginx does not do it for you.
- [ ] A request body cap is set at the proxy (`client_max_body_size` / `request_body max_size`),
      and it is **not larger** than Nitro's own `serve(max_body_bytes = …)` — otherwise the proxy
      forwards uploads that Nitro will only reject after buffering them.
- [ ] SSE routes disable response buffering; WebSocket routes pass `Upgrade`/`Connection`.
- [ ] Behind TLS termination, WebSocket routes have `ExtractIP(forwarded_proto = …)` configured,
      the proxy forwards the public `Host`, and nothing strips `Origin`.
- [ ] A page served from another origin is listed with `WebSocketOrigins([...])` — exact origins,
      never `*` — rather than admitted by stripping `Origin` or by `Cors`.
- [ ] With `CrossOriginProtection`, the proxy forwards the public `Host` and strips neither
      `Sec-Fetch-Site` nor `Origin`.
- [ ] The Nitro port is not reachable except through the proxy — check the container's published
      ports and any network policy, not just `host`.
- [ ] Authorization is enforced in handlers. No `location` block is the only thing guarding a route.

**Hostile traffic**

- [ ] `limit_req` is set at the server level, and any location with a `limit_req` of its own repeats
      the server-level one.
- [ ] Catch-all `default_server` blocks on 80 and 443 drop requests for hosts you do not serve.
- [ ] `server_tokens off`.
- [ ] No `error_page` hands a Nitro response to a location that proxies it to Nitro again.
- [ ] File-shaped misses get a `404`, not the SPA shell, and `/.env` is still refused after that
      change.
- [ ] Banning is done by fail2ban or CrowdSec reading the proxy's access log, not by the app.
- [ ] HSTS is sent by the proxy **or** by `SecurityHeaders`, never both, and reaches every
      location.

**Client IP**

- [ ] Declare `forwarded_header` and `trusted_proxies` together, or neither.
- [ ] Make the proxy **set** (not forward) that header.
- [ ] Strip the forwarding headers you don't use at the proxy.
- [ ] Use CIDR ranges where proxy addresses are dynamic.
- [ ] Put `ExtractIP` above anything that reads the client IP.
- [ ] Confirm the resolved IP is what you expect before relying on it for a limit — log `getip`
      and `getpeerip` side by side once in staging.
