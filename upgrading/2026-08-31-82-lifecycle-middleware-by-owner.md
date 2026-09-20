## `Service.lifecycle_middleware` splits by owner; route-level startup hooks survive a restart (#82)

- **Version**: 0.3.0
- **Nitro ref**: #82; `src/context.jl`, `src/core.jl`, `src/routerhof.jl`,
  `src/middleware/rate_limiter.jl`
- **Recorded**: 2026-08-31
- **Severity**: **breaking (a `Service` field is replaced by two) plus behavior (route-level
  lifecycle hooks now re-run across a `serve()` restart)** — bug fix.

### What changed

`terminate()` ran `empty!(context.service.lifecycle_middleware)`, but that one `Set` held two kinds
of member with different lifetimes:

- **serve-owned** — added from the `serve(middleware = …)` list on every `serve()`. Clearing these is
  correct; otherwise `serve(middleware=[A]); terminate(); serve(middleware=[B])` would start `A`'s
  lifecycle as well.
- **route-owned** — added at `urlpatterns()` time, once. Clearing these is wrong: nothing ever
  re-adds them, because routes are not re-registered on a second `serve()`.

So after `serve(); terminate(); serve()`, **every route-level `LifecycleMiddleware`'s `on_startup`
was silently skipped for the rest of the process's life.** For a route-level `RateLimiter` that meant
its bucket-pruning task never restarted while the limiter kept recording every request — an unbounded
leak in the component whose entire job is to bound resource use.

The single field is replaced by two, each cleared by whoever owns it:

| Field | Written by | Cleared by |
|---|---|---|
| `route_lifecycle` | `urlpatterns()` / `router()` / `register_route` | `resetstate()` only |
| `serve_lifecycle` | `serve(middleware = …)` | `terminate()` |

Startup runs route-owned then serve-owned; `terminate` unwinds the exact reverse. An object handed
to *both* a route and `serve(middleware = …)` is recorded once, as route-owned.

`RateLimiter`'s hooks were fixed in the same change. `on_shutdown` cleared a single shared `running`
flag without waiting for the cleanup task — parked in `sleep(cleanup_period)`, up to 10 minutes from
its next check — so the next `on_startup` set the flag back to `true` and the stale task kept looping
alongside the new one: **one leaked task per restart**. Each activation now owns its own stop token.
`on_startup` and `on_shutdown` additionally return the cleanup `Task` (or `nothing`), which
`startup`/`shutdown` discard.

### How to find the calls to migrate

```bash
# The removed field. Anything reading it must pick a half — or read both.
rg -n 'lifecycle_middleware' <app>/src <app>/test

# Route-level lifecycle middleware whose on_startup now fires again after a restart.
rg -n 'RateLimiter|AccessLog|LifecycleMiddleware' <app>/src

# Restart sequences, where the behaviour change is observable.
rg -n -A5 'terminate\(' <app>/src <app>/test | rg -n 'serve\('
```

### Migrate your app

```julia
# ✗ before — one Set, both scopes
@test lf in ctx.service.lifecycle_middleware
@test isempty(ctx.service.lifecycle_middleware)

# ✓ after — name the scope you mean
@test lf in ctx.service.route_lifecycle          # declared by urlpatterns()/router()
@test lf in ctx.service.serve_lifecycle          # declared by serve(middleware = ...)
@test isempty(ctx.service.serve_lifecycle)       # what terminate() clears
```

A `LifecycleMiddleware` attached to a route now has its `on_startup` called on **every** `serve()`,
not only the first. Hooks must therefore be idempotent across cycles — spawning a task, opening a
file, or connecting a client in `on_startup` needs a matching teardown in `on_shutdown` that the next
`on_startup` cannot be confused by. Bind the resource to a per-activation token rather than to a flag
shared across activations:

```julia
# ✗ before — one shared flag; a stale task observes the NEW activation's value and keeps running
running = Ref(false)
on_startup  = () -> (running[] = true;  isnothing(task[]) && (task[] = @async while running[] … end))
on_shutdown = () -> (running[] = false; task[] = nothing)

# ✓ after — per activation; a stale task can only ever see its own token
on_startup = function ()
    isnothing(active[]) || return nothing         # idempotent
    token = Ref(true); active[] = token
    task[] = @async while token[] … end
end
on_shutdown = function ()
    t = active[]; isnothing(t) || (t[] = false)
    active[] = nothing; task[] = nothing
end
```
