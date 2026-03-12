# Nitro.jl Refactor TODO

This file tracks what Nitro itself should do, and what should live in reusable apps/packages.

## External Reference App
- Reference migration target: BI server currently built with Genie.jl.
- Local path for context gathering in future chats: /home/pingo03/app/bi_server
- Start context gathering from these areas first:
  - `Project.toml` for dependencies and local package sources
  - `routes.jl` for endpoint surface area
  - `src/JwtAuth.jl`, `src/Security.jl`, and `src/WebServer.jl` for auth/cookie/security behavior
  - `src/Workers.jl` and `src/CtrlWorkerBi.jl` for job orchestration and queue semantics
  - `src/CtrlApiBpa.jl` for PormG/DataFrame-heavy API behavior
- When opening a new chat, mention that Nitro.jl is the framework repo and `bi_server` is the external Genie app being migrated to Nitro.

## Architecture Direction
- [ ] Keep Nitro core focused on HTTP, routing, middleware, request/response ergonomics, cookies, sessions, static files, SPA fallback, SSE, and websockets.
- [ ] Do not put JWT business logic, worker queues, cron schedulers, or ORM-specific code inside Nitro core.
- [ ] Treat authentication and background processing as reusable apps/packages that can be installed in multiple Nitro projects.
- [ ] Keep PormG integration outside Nitro core; Nitro should only provide clean extension points for apps that use PormG.
- [ ] Use this config philosophy consistently: Nitro should give a clean app-config pipeline, but the config object should live in the app layer, not inside Nitro core.

## Nitro Core

### Routing
- [x] Make `path()`, `urlpatterns()`, and `include_routes()` the only documented routing API.
- [x] Remove old routing macros and old route-registration style from the public API.
- [x] Remove or deprecate exported `route()` usage from docs/examples so the framework story is consistent.
- [x] Add missing path converters needed for real apps, especially `<uuid:key>`.
- [x] Verify nested route modules work cleanly for multi-file app structures.

### Request/Response Ergonomics
- [ ] Standardize on `req.params`, `req.query`, `req.session`, and `req.ip` for handler ergonomics.
- [x] Keep `Res.json()`, `Res.status()`, and `Res.send()` as the default response style in examples and docs.
- [ ] Decide whether Nitro should provide a small request helper for merged JSON/query/form access, or leave that to app-level helpers.
- [ ] Improve docs for request parsing so Genie users have a clear migration path.

### Security Foundation
- [ ] Keep Nitro security primitives generic: cookie helpers, session middleware, bearer middleware, guards, CORS, IP extraction, and rate limiting.
- [ ] Add a cookie-auth middleware hook so reusable auth apps can authenticate from signed/encrypted cookies without duplicating middleware wiring.
- [x] Fix `SessionMiddleware` cookie configuration so `secure` is configurable and works in local development over plain HTTP.
- [ ] Review default cookie settings for `HttpOnly`, `Secure`, `SameSite`, and expiration behavior.
- [x] Add docs for recommended middleware order: global prefix -> custom middleware -> defaults -> router.

### Sessions
- [ ] Keep session support in core, but make the storage contract reusable.
- [ ] Define and document a store interface for memory, Redis, database, or custom backends.
- [ ] Ensure session middleware can use external stores without depending on PormG directly.
- [ ] Add tests for persistent session stores via adapters, not core-specific database code.

### Extension Points
- [ ] Document how external apps/packages plug into Nitro via middleware, route modules, and package extensions.
- [ ] Provide one official example of a reusable Nitro app package.
- [ ] Verify weak-dependency patterns stay clean and do not leak app dependencies into `src/`.

### App Config Pipeline
- [ ] Do not add a Genie-style global mutable `Nitro.config` singleton.
- [x] Provide a clean way for apps to pass a typed config object into Nitro startup, preferably through app context.
- [ ] Keep environment loading, file merging, secrets resolution, and app-specific defaults in the app layer.
- [ ] Ensure handlers, middleware, auth modules, worker modules, and PormG integrations can read shared config from the app context.
- [x] Provide one documented bootstrap pattern for apps: load config -> run initializers -> build routes/middleware -> `serve(context=...)`.
- [ ] Keep Nitro limited to transport/runtime concerns; app config schema and environment conventions belong to the app.

## Auth App

> **Strategy**: Build as a well-structured module inside the BI server app first.
> Extract to a standalone `NitroAuth.jl` package only when a **second** Nitro project
> needs to reuse it. Generalizing before two real consumers exist produces the wrong API.

Folder layout inside the app:
```
src/Auth/
  jwt.jl        ← JWTs.jl wrapper, kid rotation, iat/exp validation
  middleware.jl ← bearer-token + cookie-token Nitro middleware
  guards.jl     ← login_required, role_required, claim-based guards
  cookies.jl    ← set_auth_cookie!, clear_auth_cookie!
```

- [ ] Build auth as a module inside the app, not as a standalone package yet.
- [ ] Implement JWT encode/decode with support for multiple keys and `kid` rotation.
- [ ] Validate `iat`, `exp`, `nbf`, issuer, and audience claims where configured.
- [ ] Add support for access-token and refresh-token flows.
- [ ] Support both bearer-token auth and cookie-based auth.
- [ ] Provide login/logout helpers that set and clear cookies safely.
- [ ] Expose reusable guards like `login_required`, `role_required`, and claim-based/permission-based guards.
- [ ] Provide a middleware that injects authenticated user/claims into the request context.
- [ ] Add CSRF strategy for cookie-based auth when needed.
- [ ] Add password-hash helpers or a pluggable password API, but keep user storage outside the auth package.
- [ ] Keep the package storage-agnostic so it can work with PormG apps, Redis-backed apps, or custom repositories.
- [ ] Add end-to-end tests for invalid signature, expired token, wrong `kid`, wrong audience, missing cookie, and logout behavior.

## Workers App

> **Strategy**: Same as auth — module-first inside the app, extract to `NitroWorkers.jl`
> only when a second app needs it, or when independent horizontal scaling becomes necessary.
>
> **Do NOT design as a separate process yet.** Workers hold live Julia `Task` references,
> process-local database connections, and `Channel`-backed queues. A separate worker process
> means another Julia cold start, re-established DB connections, and IPC overhead — not worth
> it for a single-machine server. Keep everything in-process with `Threads.@spawn`.

Folder layout inside the app:
```
src/Workers/
  registry.jl    ← TASK_REGISTRY, TASK_LOCK, TaskInfo, TaskStatus enum
  queue.jl       ← SequentialQueue, queue processor (Threads.@spawn only — no @async)
  execution.jl   ← _execute_queued_task, retry logic, timeout_call
  api.jl         ← submit_task, submit_sequential_task, get_task_status,
                    cancel_task, get_all_tasks, get_queue_status
```

- [ ] Refactor Workers into the folder layout above, replacing the flat single-file module.
- [ ] **Fix threading bug**: replace `@async` in `_execute_task_async` with `Threads.@spawn`; `@async` runs on thread 1 alongside HTTP coordination and can stall the web server under load.
- [ ] Keep sequential queue processor strictly on `Threads.@spawn` (already correct).
- [ ] Make cancellation semantics explicit: document that `schedule(task, InterruptException())` is best-effort and not guaranteed to interrupt blocking I/O.
- [ ] Add structured logging and error formatting for long-running jobs.
- [ ] Add tests for queue order, retry behavior, cancellation, timeout, and duplicate submission.
- [ ] Extract to `NitroWorkers.jl` when: (a) a second Nitro project needs the same machinery, or (b) workers need to scale independently of the web server.

## PormG Integration

> PormG is not published to the Julia general registry. **Do not use path dependencies
> for anything beyond local solo development** — path deps break silently on any machine
> where the relative directory layout differs.

**Recommended dependency strategy by stage:**

| Stage | How to add PormG |
|---|---|
| Local dev now | `{url = "https://github.com/PingoLee/PormG.jl", rev = "main"}` in `[sources]` |
| Production deploy | Same git URL, pin `rev` to a specific commit hash for reproducibility |
| When PormG stabilizes | Publish to a private registry via `LocalRegistry.jl`; then `add PormG` works normally |

- [ ] Replace `path = "../PormG.jl"` in bi_server `Project.toml` with a git URL source.
- [ ] Pin `rev` to a specific commit hash before any production deployment.
- [ ] Keep PormG outside Nitro core; never import it from `src/`.
- [ ] If any Nitro package extension for PormG is needed, keep it under `ext/` only as a weak dependency.
- [ ] When PormG's API stabilizes, set up a private registry with `LocalRegistry.jl`.

## BI Server Migration Plan

- [ ] Audit every route in the Genie server and classify it as auth, BI API, BPA API, worker control, or infrastructure.
- [ ] Create a typed `AppConfig` in the BI server app with sections for server, auth, workers, and PormG/database settings.
- [ ] Load BI server config in the app layer from env-specific files plus environment variables, then inject it into Nitro via app context.
- [ ] Move auth behavior into the reusable auth app instead of rebuilding it per project.
- [ ] Move task queue behavior into the reusable worker app instead of putting it in Nitro core.
- [ ] Port Genie routes to Nitro route modules using `path()` and `urlpatterns()`.
- [ ] Replace Genie payload helpers with Nitro request accessors and extractor-based parsing.
- [ ] Replace Genie cookie helpers with Nitro cookie/session helpers or the reusable auth app.
- [ ] Keep BPA query/dataframe logic in the BI app, not in Nitro core.
- [ ] Keep sync endpoints as web triggers that enqueue worker jobs, rather than doing job orchestration in the HTTP framework.
- [ ] Replace checked-in sensitive config values with environment variables or non-committed local config.
- [ ] Add migration examples from Genie handlers to Nitro handlers for login, protected JSON, BPA read endpoints, and worker status endpoints.

## Tests And Docs
- [x] Add tests that reflect the new direction: routing, security primitives, session configuration, CORS, and extension points.
- [x] Add tests for local-development cookie behavior and production-secure cookie behavior.
- [ ] Write one full example app using Nitro + reusable auth app.
- [ ] Write one full example app using Nitro + reusable worker app.
- [ ] Write one full example app using Nitro + external PormG app.
- [x] Update README and docs so Genie users understand what belongs in Nitro core vs app packages.
- [ ] Keep test style consistent and easy to extend for app packages.

## Success Criteria
- [ ] Nitro core stays small, reusable, and framework-focused.
- [ ] JWT/auth can be reused across multiple Nitro projects without copying code.
- [ ] Worker queues can be reused across multiple Nitro projects without re-embedding background logic in the server.
- [ ] PormG remains optional and external.
- [ ] A BI server can be rebuilt on Nitro by composing Nitro + auth app + worker app + PormG app.