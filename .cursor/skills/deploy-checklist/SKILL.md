---
name: deploy-checklist
description: >-
  Pre-production checklist for Nitro.jl apps: env/secrets, Project.toml deps,
  extensions, nginx SPA proxy, tests, and optional formatting. Use before deploy
  or when the user asks to prepare for production.
disable-model-invocation: true
---

# Production Deploy Checklist

Run this as a **read-only audit** first; implement fixes only when the user asks or blocking issues are found.

Applies to **applications built on Nitro.jl**. For changes to the Nitro package itself, focus on steps 2, 4, and 6 (deps, CI, tests).

Read `nitro-config.mdc` for config ownership rules before recommending structure changes.

## 1. Environment and secrets

- [ ] Production config does not rely on committed secrets.
- [ ] Session/crypto secrets (`SECRET_KEY`, cookie keys, JWT secrets) come from environment or a non-committed local file.
- [ ] Debug/dev-only flags are off in production (no verbose error leakage to clients).
- [ ] Worker and DB connection strings use the correct env for the target (`nitro-config.mdc`).

Report missing env vars by name; do not invent secret values.

## 2. Dependencies and extensions

- [ ] `Project.toml` `[deps]` has no test-only packages required at runtime.
- [ ] `[extensions]` and `[weakdeps]` correctly wire `NitroPormGExt` (or other weak deps) when the app uses them.
- [ ] `[compat]` bounds are sensible for production pins.

## 3. Nitro runtime pipeline

- [ ] `serve(urlpatterns; middleware=[...])` order: global middleware → defaults → router (`nitro-core.mdc`).
- [ ] `SessionMiddleware` / `CSRFMiddleware` present for stateful cookie apps.
- [ ] `spafiles` or static config matches how the frontend is served in production.
- [ ] Worker `startup(..., store=..., recover_zombies=...)` configured if background queues are used (`workers.mdc`).

## 4. Reverse proxy (when requested)

If the user uses nginx (or similar) in front of Nitro:

- [ ] `proxy_pass` to the Nitro listen address (e.g. `http://127.0.0.1:8080`).
- [ ] SPA history fallback: `try_files $uri $uri/ /index.html;` for the frontend root.
- [ ] WebSocket upgrade headers if the app uses Nitro websockets.
- [ ] **Client IP / rate limiting behind a proxy.** `ExtractIP` and `RateLimiter`
      ignore forwarding headers (`X-Forwarded-For`, `X-Real-IP`, `CF-Connecting-IP`,
      `True-Client-IP`) by **default** — they cannot be trusted from arbitrary
      clients. Behind a reverse proxy this means every client collapses onto the
      proxy's socket IP and shares one rate-limit bucket. Configure the trusted
      proxy so per-client limits work again:
      `RateLimiter(...; trusted_proxies=[ip"127.0.0.1"])` (honor headers only when
      the peer is a listed proxy — preferred), or `trust_forwarded=true` (trust any
      peer; only when clients cannot reach Nitro directly). Make the proxy set
      `X-Forwarded-For`/`X-Real-IP`.

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
