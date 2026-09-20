## Lifecycle hook order is now specified: registration order in, LIFO out (#74)

- **Version**: 0.3.0
- **Nitro ref**: #74; `src/context.jl`, `src/core.jl`, `src/routerhof.jl`
- **Recorded**: 2026-09-01
- **Severity**: **breaking (two `Service` fields change container type) plus behavior (a
  previously-unspecified execution order becomes a contract)** — bug fix.

### What changed

`startserver` ran `startup.(…)` and `terminate` ran `shutdown.(…)` over a `Set`. Broadcasting over
a `Set` collects it in **hash order**, and `LifecycleMiddleware` is an immutable struct whose fields
are closures — heap objects — so the order varied run to run and was not reproducible even for an
identical program.

Nothing depended on it yet, which is precisely why it had to be pinned before something did: the
first time two lifecycle middlewares share a resource — an `AccessLog` sink flushing into something
another lifecycle owns — teardown order decides whether the flush succeeds.

`route_lifecycle` and `serve_lifecycle` are now `Vector{LifecycleMiddleware}`, guarded by a new
`lifecycle_lock`, and the contract is:

- **Startup** — route-owned then serve-owned, each in **registration order**.
- **Shutdown** — the **exact reverse**: serve-owned reversed, then route-owned reversed.

LIFO teardown is what Spring's `SmartLifecycle` phases, ASP.NET Core's `IHostedService`, OTP
supervisors, ASGI lifespan, and `defer`/`atexit` all do. Nitro now matches them.

Two further changes fall out of the container swap:

- **Dedup moved from the `Set` to an explicit `∉` guard** and is unchanged in effect: one shared
  `RateLimiter()` passed to N routes is still one registration, so its cleanup task starts once.
- **Registration takes `lifecycle_lock`**, and `startup.`/`shutdown.` broadcast over a *copy* taken
  under it. "Registration time" was never a synonym for "single-threaded startup": under
  `revise=:lazy`, `Revise.revise()` runs on a request-handling task, and re-running user top-level
  code re-enters `urlpatterns` → `register_route` → the registration path. Two revisions, or one
  revision concurrent with a `startup.` broadcast, raced a bare collection. Same defect class as
  #68 item 1, and the same asymmetry gave it away: `named_routes` and `extensions` on this struct
  already carry locks.

`ctx.service.router` (the `HTTP.Router`) has the same unsynchronized exposure via `HTTP.register!`
and is **not** covered here — different container, different owner. Tracked separately.

### How to find the calls to migrate

```bash
# Reads of the lifecycle vectors. `in` still works; `length`/indexing/iteration now see order.
rg -n 'route_lifecycle|serve_lifecycle' <app>/src <app>/test

# Anything that assumed hooks were unordered, or ordered some other way.
rg -n 'on_startup|on_shutdown|LifecycleMiddleware' <app>/src
```

### Migrate your app

Reading the fields still works — `in`, `length` and `isempty` behave the same — so most apps need
no edit. Two cases do:

```julia
# ✗ before — Set semantics; push! deduped for you, and order was meaningless
push!(ctx.service.route_lifecycle, mw)

# ✓ after — a Vector: register through the API, which dedups and takes the lock
Nitro.Core.RouterHOF.register_route_lifecycle!(ctx, [mw])
```

```julia
# ✗ before — comparing against a Set, order-insensitively
@test ctx.service.serve_lifecycle == Set([a, b])

# ✓ after — a Vector in registration order
@test ctx.service.serve_lifecycle == [a, b]
```

If two of your lifecycle middlewares share a resource, register the **owner first**: it will then
be torn down last, after its dependents. That is the same rule as `defer`, and the reason the
order is LIFO rather than FIFO.

!!! note "The contract is per cycle"
    Teardown is the exact reverse of startup in any cycle where no *ownership promotion* happened.
    Handing one object to both a route and `serve(middleware = …)` makes it route-owned (#82), and
    if the route registration lands mid-cycle — a runtime `include_routes`, or Revise re-running
    `urlpatterns` — that object moves from the serve phase to the route phase for the remainder of
    that cycle, so it is torn down ahead of serve-owned entries it previously followed. It settles
    after one `terminate()`, because that clears `serve_lifecycle` and the next `serve()` starts
    from a stable split. If you depend on teardown order between two middlewares, keep them in the
    same half.
