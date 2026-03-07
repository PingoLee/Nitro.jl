# Nitro.jl Fork — Django-Style API/SPA Framework

## Step 1: Subtraction (Strip Down)
- [ ] Delete [src/cron.jl](file:///c:/Sistemas/Nitro.jl/src/cron.jl) and remove all cron references from [core.jl](file:///c:/Sistemas/Nitro.jl/src/core.jl), [context.jl](file:///c:/Sistemas/Nitro.jl/src/context.jl), [types.jl](file:///c:/Sistemas/Nitro.jl/src/types.jl), [methods.jl](file:///c:/Sistemas/Nitro.jl/src/methods.jl), [routerhof.jl](file:///c:/Sistemas/Nitro.jl/src/routerhof.jl)
- [ ] Delete [src/repeattasks.jl](file:///c:/Sistemas/Nitro.jl/src/repeattasks.jl) and remove all repeat-task references from [core.jl](file:///c:/Sistemas/Nitro.jl/src/core.jl), [context.jl](file:///c:/Sistemas/Nitro.jl/src/context.jl), [types.jl](file:///c:/Sistemas/Nitro.jl/src/types.jl), [methods.jl](file:///c:/Sistemas/Nitro.jl/src/methods.jl)
- [ ] Delete [src/metrics.jl](file:///c:/Sistemas/Nitro.jl/src/metrics.jl) and remove metrics references from [core.jl](file:///c:/Sistemas/Nitro.jl/src/core.jl) (middleware, setupmetrics, welcome banner, serve params)
- [ ] Delete [src/autodoc.jl](file:///c:/Sistemas/Nitro.jl/src/autodoc.jl) and remove autodoc/docs references from [core.jl](file:///c:/Sistemas/Nitro.jl/src/core.jl) (middleware, setupdocs, welcome banner, serve params)
- [ ] Clean [context.jl](file:///c:/Sistemas/Nitro.jl/src/context.jl): remove `CronContext`, `TasksContext` fields from `ServerContext`; remove docs router/schema logic
- [ ] Clean [types.jl](file:///c:/Sistemas/Nitro.jl/src/types.jl): remove `ActiveTask`, `RegisteredTask`, `TaskDefinition`, `ActiveCron`, `RegisteredCron`, `CronDefinition`, `HTTPTransaction`, `History`
- [ ] Clean [routerhof.jl](file:///c:/Sistemas/Nitro.jl/src/routerhof.jl): remove `interval`, `cron` fields from `OuterRouter`/`InnerRouter`
- [ ] Clean [methods.jl](file:///c:/Sistemas/Nitro.jl/src/methods.jl): remove `@cron`, `@repeat`, cron/task management functions, docs exports
- [ ] Clean [Nitro.jl](file:///c:/Sistemas/Nitro.jl/src/Nitro.jl): remove stripped exports (`@cron`, `@repeat`, `starttasks`, `stoptasks`, etc.)
- [ ] Update [Project.toml](file:///c:/Sistemas/Nitro.jl/Project.toml): remove `Statistics`, `RelocatableFolders` deps
- [ ] Remove test files for stripped features: [crontests.jl](file:///c:/Sistemas/Nitro.jl/test/crontests.jl), [metricstests.jl](file:///c:/Sistemas/Nitro.jl/test/metricstests.jl), [autodoctests.jl](file:///c:/Sistemas/Nitro.jl/test/autodoctests.jl), [reflectiontests.jl](file:///c:/Sistemas/Nitro.jl/test/reflectiontests.jl), [cronmanagement.jl](file:///c:/Sistemas/Nitro.jl/test/cronmanagement.jl), [taskmanagement.jl](file:///c:/Sistemas/Nitro.jl/test/taskmanagement.jl)
- [ ] Update [test/runtests.jl](file:///c:/Sistemas/Nitro.jl/test/runtests.jl) to exclude removed test files

## Step 2: Adaptation (Django Routing Layer)
- [ ] Create `src/routing.jl` with `route()` and `include_router()` wrapper functions
- [ ] Implement parameterized routes with built-in type coercion (e.g., `<int:user_id>`, `<uuid:token>`)
- [ ] Support modular app structures via route inclusion (e.g., `include("blog/urls.jl")`)
- [ ] Export new routing API from [Nitro.jl](file:///c:/Sistemas/Nitro.jl/src/Nitro.jl)

## Step 3: Session Management (Django-like)
- [ ] Create `src/sessions.jl` or a dedicated middleware module for session handling
- [ ] Implement secure cookie generation and parsing (`HttpOnly`, `Secure`, `SameSite` flags)
- [ ] Add an in-memory session store (and a skeleton interface for Redis/DB stores)
- [ ] Inject session data into the HTTP `Request` context (e.g., `req.session["key"]`)

## Step 4: SPA & API First Features (Node.js style)
- [ ] Create a built-in CORS middleware (`src/cors.jl`) that is easy to enable globally
- [ ] Add a JSON auto-serialization helper (automatically return JSON if a handler returns a `Dict` or `Struct`)
- [ ] Create a static file serving wrapper with fallback to `index.html` for client-side routing (Vue/React/Angular)

## Step 5: Developer Experience (Node.js inspired)
- [ ] Ensure the middleware registration pipeline is linear and predictable
- [ ] Provide clean, mutable `Request` and `Response` object abstractions
- [ ] Leverage Julia's `Task` system for async I/O performance

## Step 6: Tests & Documentation
- [ ] Write new test suites for routing, sessions, CORS, and SPA fallback
- [ ] Update `README.md` to reflect the new SPA/API-first methodology
- [ ] Document the new routing API with usage examples

## Step 7: Verification
- [ ] Package loads without errors (`using Nitro`)
- [ ] All tests pass (old retained + new)
- [ ] Verify a minimal route-and-serve integration works end-to-end
