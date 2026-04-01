# Nitro.jl Refactor TODO

This file tracks what Nitro itself should do, and what should live in reusable apps/packages.

## External Reference App
- Reference migration target: BI server currently built with Genie.jl.
- Local path for context gathering in future chats: /home/pingo03/app/bi_server
- Reference ORM/Persistence: /home/pingo03/app/PormG.jl
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
- [x] Standardize on `req.params`, `req.query`, `req.session`, and `req.ip` for handler ergonomics.
- [x] Standardize on `req.user` for authenticated handler ergonomics.
- [x] Keep `Res.json()`, `Res.status()`, and `Res.send()` as the default response style in examples and docs.
- [x] Provide lazy request accessors via `LazyRequest` (JSON, form, text, headers).
- [x] Implement `req.input` (or `req.data`) as a unified accessor that merges path parameters, query string, and body (JSON or Form).
    - *Decision*: Nitro provides this "merged" view to simplify simple handlers, but keep typed `Extractors` as the recommended way for complex validation.
- [x] Improve docs for request parsing so Genie users have a clear migration path.
- [x] Add `req.form` and `req.json` shorthands to `HTTP.Request` extension in `src/core.jl`.
- [x] Ensure `Res` module includes common helper for file downloads and custom redirects.
- [x] Re-verify ergonomics/body parser behavior after rebase via focused tests and full `Pkg.test()`.

### Security Foundation
- [x] Keep Nitro security primitives generic: cookie helpers, session middleware, bearer middleware, guards, CORS, IP extraction, and rate limiting.
- [x] Create a unified `Nitro.Auth` module for authentication (JWT, Cookies, Passwords, CSRF).
- [x] Refactor `CSRFMiddleware` to return errors using `Res.json()` instead of raw `HTTP.Response` objects.
- [x] Implement a cookie-auth middleware hook so reusable auth apps can authenticate from signed/encrypted cookies without duplicating middleware wiring.
- [x] Fix `SessionMiddleware` cookie configuration so `secure` is configurable and works in local development over plain HTTP.
- [x] Review default cookie settings for `HttpOnly`, `Secure`, `SameSite`, and expiration behavior.
- [x] Add docs for recommended middleware order: global prefix -> custom middleware -> defaults -> router.

### Sessions
- [x] Keep session support in core, but make the storage contract reusable via `AbstractSessionStore`.
- [x] Remove `req.context[:user] = session_data` from `SessionMiddleware` to prevent overwriting auth context.
- [x] Define and document a store interface for memory, Redis, database, or custom backends.
- [x] Implement `MemoryStore` as a default provider.
- [x] Ensure session middleware can use external stores without depending on PormG directly.
- [x] Add tests for persistent session stores via adapters, not core-specific database code.
- [ ] Decide the `SessionMiddleware` auth contract: either remove the unused `validator` keyword or wire it explicitly without repopulating `req.user` from raw session state.

### Extension Points
- [ ] Document how external apps/packages plug into Nitro via middleware, route modules, and package extensions.
- [ ] Provide one official example of a reusable Nitro app package.
- [x] Verify weak-dependency patterns stay clean and do not leak app dependencies into `src/`.
- [x] Integrated `Bcrypt.jl` as a standard dependency for secure auth.

## Auth Module (Nitro.Auth)

> **Status**: Core implementation is integrated into Nitro.jl, but contract cleanup and token-scope follow-up still remain.

- [x] Implement JWT encode/decode with support for multiple keys and `kid` rotation.
- [x] Validate `iat`, `exp`, `nbf`, issuer, and audience claims where configured.
- [x] Add support for access-token flows.
- [ ] Add refresh-token helpers and lifecycle support, or narrow the documented auth scope to access tokens only.
- [x] Support both bearer-token auth and cookie-based auth in a unified `req.user` context.
- [x] Provide login/logout helpers (`set_auth_cookie!`, `clear_auth_cookie!`) that handle cookies safely.
- [x] Expose reusable guards like `login_required`, `role_required`, and claim-based/permission-based guards.
- [x] Provide middleware that injects authenticated user/claims into the request context (`req.user`).
- [x] Add CSRF protection strategy for cookie-based auth.
- [x] Ported and expanded `PormG` Passwords module:
    - [x] `PasswordEncoder` abstract interface.
    - [x] `PBKDF2PasswordEncoder`, `BCryptPasswordEncoder`.
    - [x] `SpringSecurityPBKDF2PasswordEncoder` for legacy compatibility.
    - [x] `DelegatingPasswordEncoder` for multi-algorithm support.
    - [x] `PasswordValidator` with i18n support (`Printf`-based).
- [x] Keep the module storage-agnostic via `AbstractSessionStore`.
- [x] Add comprehensive tests for invalid signature, expired tokens, i18n passwords, and cross-encoder matching.
  - [ ] Finish auth-context unification so guards rely on `req.user` consistently instead of falling back to the raw session dictionary.

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

- [x] Ported orignal `bi_server` background task logic to Nitro.jl infrastructure.
- [x] Refactor Workers into the folder layout above, replacing the flat single-file module.
- [x] **Fix threading bug**: replace `@async` in `_execute_task_async` with `Threads.@spawn`; `@async` runs on thread 1 alongside HTTP coordination and can stall the web server under load.
- [x] Keep sequential queue processor strictly on `Threads.@spawn` (already correct).
- [x] Make cancellation semantics explicit: document that `schedule(task, InterruptException())` is best-effort and not guaranteed to interrupt blocking I/O.
- [x] Add structured logging and error formatting for long-running jobs. (Added `TaskStatus` and detailed `TaskInfo` tracking)
- [x] Add tests for queue order, retry behavior, cancellation, timeout, and duplicate submission. (Verified in [test/workerstests.jl](test/workerstests.jl))
- [ ] Extract to `NitroWorkers.jl` when: (a) a second Nitro project needs the same machinery, or (b) workers need to scale independently of the web server.

### Future Work
- [ ] Extract store logic to `AbstractWorkerStore` for pluggable backends.
- [ ] Create `NitroWorkersRedisExt` for Redis-backed task registry.
- [ ] Add structured logging and metrics for queue depth and execution times.
- [ ] Support task progress updates during long-running callbacks.
- [ ] Add WebSocket support for real-time task status updates.

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
- [x] Create a typed `AppConfig` in the BI server app with sections for server, auth, workers, and PormG/database settings. (Documented example in [docs/src/tutorial/bi_app_config.md](/home/pingo03/app/Nitro.jl/docs/src/tutorial/bi_app_config.md))
- [x] Create a migration instruction file for the new workspace. (Created [.github/instructions/nitro-migration.instructions.md](.github/instructions/nitro-migration.instructions.md))
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
- [x] Run full `Pkg.test()` successfully after the request/response and auth refactors were rebased.
- [ ] Add focused tests for the finalized `SessionMiddleware` validator behavior and the `req.user` guard contract.
- [ ] Write one full example app using Nitro + reusable auth app.
- [ ] Write one full example app using Nitro + reusable worker app.
- [ ] Write one full example app using Nitro + external PormG app.
- [x] Update README and docs so Genie users understand what belongs in Nitro core vs app packages.
- [ ] Keep test style consistent and easy to extend for app packages.

## Success Criteria
- [ ] Nitro core stays small, reusable, and framework-focused.
- [x] JWT/auth can be reused across multiple Nitro projects without copying code.
- [ ] Worker queues can be reused across multiple Nitro projects without re-embedding background logic in the server.
- [ ] PormG remains optional and external.
- [ ] A BI server can be rebuilt on Nitro by composing Nitro + auth app + worker app + PormG app.