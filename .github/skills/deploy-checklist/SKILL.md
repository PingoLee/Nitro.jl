---
name: deploy-checklist
description: >-
  Pre-production checklist for Nitro.jl apps: env/secrets, Project.toml deps,
  extensions, nginx SPA proxy, tests, and optional formatting. Use before deploy
  or when the user asks to prepare for production.
---

# Production Deploy Checklist

Run this as a **read-only audit** first; implement fixes only when the user asks or blocking issues are found.

Applies to **applications built on Nitro.jl**. For changes to the Nitro package itself, focus on steps 2, 4, and 6 (deps, CI, tests).

Read `nitro-config.instructions.md` for config ownership rules before recommending structure changes.

## 1. Environment and secrets

- [ ] Production config does not rely on committed secrets.
- [ ] Session/crypto secrets (`SECRET_KEY`, cookie keys, JWT secrets) come from environment or a non-committed local file.
- [ ] Error handling is production-safe. Nitro **never** sends stack traces to clients:
      a handler that throws returns a generic `{"message": "500: Internal Server Error"}`
      (via `catch_errors=true`, the default). The `serve(...; show_errors=true)` kwarg
      (default `true`) gates only **server-side** error logging, *not* the client response.
      Keep it `true` in production so failures are recorded in your logs — setting
      `show_errors=false` does not harden the response (it is already generic); it only
      silences your own error logs.
- [ ] Worker and DB connection strings use the correct env for the target (`nitro-config.instructions.md`).

Report missing env vars by name; do not invent secret values.

## 2. Dependencies and extensions

- [ ] `Project.toml` `[deps]` has no test-only packages required at runtime.
- [ ] `[extensions]` and `[weakdeps]` correctly wire `NitroPormGExt` (or other weak deps) when the app uses them.
- [ ] `[compat]` bounds are sensible for production pins.

## 3. Nitro runtime pipeline

- [ ] Routes registered with `urlpatterns(prefix, routes)` **before** `serve()`; `serve(middleware=[...])`
      is keyword-only. Pipeline order: global middleware → defaults → router (`nitro-core.instructions.md`).
- [ ] `SessionMiddleware` / `CSRFMiddleware` present for stateful cookie apps.
- [ ] `spafiles` or static config matches how the frontend is served in production.
- [ ] Access logging is privacy-safe. `serve(...; access_log=true)` (default on) logs the
      request **path only** — query strings are redacted so reset tokens, API keys, and
      OAuth `code`/`state` carried in URLs never reach the logs. Enable
      `serve(...; access_log_query=true)` only when you are certain no secrets travel in
      query strings.
- [ ] Worker `worker_startup(..., store=..., recover_zombies=...)` configured if background queues are used (`workers.instructions.md`).

## 4. Reverse proxy (when requested)

If the user uses nginx (or similar) in front of Nitro:

- [ ] `proxy_pass` to the Nitro listen address (e.g. `http://127.0.0.1:8080`).
- [ ] SPA history fallback: `try_files $uri $uri/ /index.html;` for the frontend root.
- [ ] WebSocket upgrade headers if the app uses Nitro websockets.
- [ ] **Client IP / rate limiting behind a proxy.** `ExtractIP` and `RateLimiter`
      ignore every forwarding header by **default** — they cannot be trusted from
      arbitrary clients. Behind a reverse proxy this means every client collapses onto
      the proxy's socket IP and shares one rate-limit bucket. Restore per-client limits
      by declaring **both** the trust boundary and the one header your proxy writes:
      `RateLimiter(...; forwarded_header=:x_forwarded_for, trusted_proxies=[ip"127.0.0.1"])`.
      Setting either alone is an `ArgumentError` at startup, by design. Only the header
      you name is read, so a proxy that forgets to strip `CF-Connecting-IP` cannot be
      used to bypass an `X-Forwarded-For` setup.
- [ ] **The proxy must _set_ that header, not pass it through.** `X-Real-IP`,
      `CF-Connecting-IP` and `True-Client-IP` are single-valued and believed as written
      (nginx: `proxy_set_header X-Real-IP $remote_addr`). `X-Forwarded-For` is a chain
      and is walked right-to-left with trusted hops peeled, so client-prepended entries
      are never reached. Strip the headers you don't use anyway — Nitro no longer needs
      it, but log tooling generally does.
- [ ] **Dynamic proxy addresses → CIDR.** `trusted_proxies` accepts ranges
      (`"10.244.0.0/16"`, `"2400:cb00::/32"`) mixed freely with `IPAddr` values, for k8s
      ingress pods or published CDN prefixes. A catch-all (`"0.0.0.0/0"`) is rejected.
- [ ] **Audit both addresses.** `getip(req)` is the resolved client; `getpeerip(req)` is
      the socket peer, which no header can forge. Log both to tell a proxied request
      from a direct one after an incident.
- [ ] The socket peer IP is resolved for **both** plain HTTP and direct-TLS listeners;
      if a Nitro/HTTP upgrade ever breaks that resolution it logs a loud, rate-limited
      error (and the request falls back to loopback) rather than silently degrading
      IP-based limits and audit logs — watch for it, because a loopback fallback
      combined with `trusted_proxies=[ip"127.0.0.1"]` would trust every client.

Provide a minimal config snippet only when asked; do not overwrite existing infra files without confirmation.

## 5. Tests

```bash
julia --project -e 'using Pkg; Pkg.test()'
```

- [ ] Full suite passes on the branch intended for deploy.
- [ ] Worker/auth tests run if those subsystems are enabled in production.

## 6. Code quality (optional)

If `JuliaFormatter` is in the project environment:

```bash
julia --project -e 'using JuliaFormatter; format("src"); format("test")'
```

Skip if the formatter is not a dependency — do not add it solely for deploy.

## Output format

1. **Blocking** — must fix before deploy (secrets in repo, failing tests, missing CSRF for cookie mutations).
2. **Advisory** — should fix soon (compat gaps, missing health checks).
3. **OK** — items verified.

Offer to apply fixes inline when blocking items exist.
