## `instance()` is removed — construct a second `App` instead (#31)

- **Version**: Unreleased
- **Nitro ref**: #31; `src/instances.jl` (deleted), `src/Nitro.jl`,
  `test/instance_tests.jl` → `test/app_tests.jl`
- **Recorded**: 2026-09-13
- **Severity**: **breaking, and it fails LOUDLY.** `instance` is no longer exported or defined, so
  a call site raises `UndefVarError: instance not defined`.

### What changed

`instance()` was the only way to get two independent Nitro apps. It bought that by reading
`src/Nitro.jl` off disk, rewriting its `include` paths and `include_string`ing the **entire
package** into a fresh anonymous module — a full recompile per instance, a second copy of every
method table, and a hard failure on any deployment where the package source is not present or
readable at runtime (system images, relocated installs).

`App` gives you an independent router, middleware stack, cookie config and app context, with none
of that cost. Two differences are worth knowing before you port:

- **Types are shared.** There is no separate module namespace, so `app1`'s `Request` *is*
  `Nitro.Request`. That is what you want — objects could not cross `instance()` boundaries.
- **Worker stores are NOT isolated by default.** `_resolve_store` falls back to the process-wide
  default store when an app has none installed, so two `App`s that never install one share a
  queue — where two `instance()` modules got one each.

  To give an app its own store, put `worker_startup(app; ...)` in **that app's**
  `serve(middleware = [...])` list, or call `Nitro.Workers.start!(app; ...)` directly.
  `worker_startup` on its own installs nothing: it *returns* lifecycle middleware, and the store
  is installed when `serve` fires its `on_startup`.

  Once an app has its own store, use that app's worker API (`submit_task(app, ...)` and friends).
  The argument-less `submit_task(...)` helpers keep writing to the process-wide default store, so
  mixing the two silently splits submissions from the queue processors watching the app's store.

### How to find the calls to migrate

```bash
# 1. The call. Note the word boundary -- `internalrequest`, `instances` and any local
#    variable named `instance` are NOT matches.
rg -n '\binstance\(\)' --type julia

# 2. Module-qualified calls through the returned instance, which have no direct equivalent:
#    `app.urlpatterns(...)` becomes `urlpatterns(app, ...)`.
rg -n '\w+\.(urlpatterns|serve|terminate|internalrequest|path)\(' --type julia
```

### Migrate your app

```julia
# ✗ before
app1 = instance()
app1.urlpatterns("", app1.path("/", () -> "hello"))
app1.serve(port = 8080, async = true)

# ✓ after
app1 = App(mod = @__MODULE__)
urlpatterns(app1, "", path("/", () -> "hello"))
serve(app1; port = 8080, async = true)
```

The call shape changes from method-on-module to function-on-value: `app.f(x)` becomes `f(app, x)`.
`path` and `include_routes` take no app at all — they build route definitions, and
`urlpatterns(app, …)` is what binds them to one.
