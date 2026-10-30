## The lifecycle registry holds `LifecycleEntry` values, and `LifecycleMiddleware` is parameterized (#719)

- **Version**: Unreleased
- **Nitro ref**: #719; `src/types.jl`, `src/routeendpoint.jl`, `src/context.jl`, `src/routerhof.jl`
- **Recorded**: 2026-10-24
- **Severity**: breaking (two `Service` fields change element type; `LifecycleMiddleware` gains type parameters) — only for code that reads the registry or compares `LifecycleMiddleware` types

### What changed

`startserver` and `terminate` called each lifecycle hook on an element of a
`Vector{LifecycleMiddleware}` whose hook fields were typed `Union{Function,Nothing}`: one dynamic
call per hook, and one `juliac --trim=safe` rejects. To give each hook a concrete call
(docs/design/juliac-trim.md §3.4):

- **`LifecycleMiddleware` is `LifecycleMiddleware{M,S,D,P}`**, parameterized on its `middleware`,
  `on_startup`, `on_shutdown` and `on_stopped` functions (`on_stopped`, the post-drain hook, is
  #161's, before this entry was released). The keyword constructor is unchanged, and the bare name
  still serves for `x isa LifecycleMiddleware` and `LifecycleMiddleware[]`. What changes: two of
  them no longer share one concrete type (`typeof(a) === typeof(b)` is `false` when their functions
  differ), and a struct field declared `::LifecycleMiddleware` is now an abstract type.
- **`Service.route_lifecycle` and `Service.serve_lifecycle` hold `LifecycleEntry` values**, one per
  registered object, not the objects themselves. The object is the entry's `mw` field. Order, dedup
  (by `===`), promotion and `lifecycle_lock` are unchanged. The #74 and #82 entries showed checks
  such as `lf in ctx.service.route_lifecycle`: written against the new fields, that is `false`
  whatever is registered.

Under the JIT every hook still runs exactly as before. In an application compiled with
`juliac --trim`, a `Vector`-form `serve(middleware = [...])` that holds a `LifecycleMiddleware`
is refused when `serve` starts (pass the `Tuple` form), and so is route middleware with lifecycle
hooks registered at run time rather than at top level.

### How to find the calls to migrate

```bash
# Code that reads the lifecycle registry (tests, mostly):
grep -rn -E 'route_lifecycle|serve_lifecycle|lifecycle_snapshot' --include=*.jl .
# Code that compares LifecycleMiddleware types, or declares a field of that type:
grep -rn -E 'typeof\(.*\) *===? *typeof|:: *(Nitro\.)?LifecycleMiddleware\b' --include=*.jl .
```

### Before → after

```julia
# before: the registry held the middleware objects
@test lf in ctx.service.route_lifecycle
@test route_lf == [a, b, c]

# after: it holds one entry per object; compare the objects
objects(entries) = [e.mw for e in entries]
@test lf in objects(ctx.service.route_lifecycle)
@test objects(route_lf) == [a, b, c]
```

```julia
# before: one concrete type for every LifecycleMiddleware
@test typeof(RateLimiter(strategy = :sliding_window)) === typeof(RateLimiter(strategy = :fixed_window))

# after: test against the public type
@test RateLimiter(strategy = :sliding_window) isa Nitro.LifecycleMiddleware
```

```julia
# before: a field of the bare type (now abstract)
struct Stack; limiter::Nitro.LifecycleMiddleware; end

# after: a type parameter keeps the field concrete
struct Stack{L<:Nitro.LifecycleMiddleware}; limiter::L; end
```
