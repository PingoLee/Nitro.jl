# Upgrading Nitro — consumer-app rollout log

Tracks **breaking / behavior changes in Nitro** that require source-code changes in the applications
that depend on it. Nitro is pre-publish (single maintainer, no external users), so breaking changes
are intentional and cheap on the *Nitro* side — but each one still has to be rolled out by hand in
every consuming app. This file is that rollout checklist.

> 🚀 **Upgrading an app? Don't read this file top to bottom.** Run
> `Nitro.upgrade_guide(from = v"<your pinned version>")` — it renders only the entries newer than
> your pin, newest-first. The full how-to (versioning model, the apply recipe, driving it with an AI
> agent) lives in the docs: **[Upgrading Nitro](https://pingolee.github.io/Nitro.jl/dev/upgrading/)**.
> This file is the change log those tools read; the sections below are the rules for *writing* an
> entry.

## Writing an entry

- One `##` entry per breaking change, **newest first**. New entries land in **`## Unreleased`** with
  `- **Version**: Unreleased` and **no `Project.toml` bump**; the maintainer stamps them with a
  release number when cutting a train (`nitro-cut-release`).
- Each entry records: the Nitro **version** it shipped in, what changed, why, a *"How to find the
  calls to migrate"* grep, and the concrete **before → after** code edit.
- **Not for additive features.** This log is only what **forces** an app edit. A new opt-in
  capability (middleware, extractor, kwarg, function) requires no change to keep an app working →
  document it in `docs/`, not here.
- **No per-entry rollout tables.** An app's own Nitro dependency pin *is* its rollout state, and
  `upgrade_guide(from = <that pin>)` derives what it still needs — so there is nothing to maintain
  per app.
- **Keep the prose version-neutral.** Write *"part of the `0.1.x` pre-publish wave"*, never *"part of
  the current `## Unreleased` wave"* — stamping rewrites the `- **Version**:` bullet, not the body,
  so self-referential prose ships stale.
- Entries are version-stamped from **`0.1.0`** onward. `0.1.0` is the baseline of the release-train
  policy: earlier `Project.toml` numbers (`0.2.0`–`0.4.0`) and their tags predate it and were
  reclaimed, so nothing below `0.1.0` exists to port from.

---

## Unreleased — next `0.3.0`

_Changes merged but not yet cut into a release. A consumer dev'ing Nitro at HEAD is running these,
and `Nitro.upgrade_guide` surfaces them by default. When the maintainer next rolls changes into a
consuming app, `nitro-cut-release` stamps every entry below with `0.3.0`, dates them, and tags it._

---

## The `PormG` pin moves to `^0.5`, which is a breaking PormG release (#PormG 0.5.0)

- **Version**: Unreleased
- **Nitro ref**: `Project.toml` (`[compat]`); `ext/NitroPormGExt.jl` (unchanged)
- **Recorded**: 2026-09-05
- **Severity**: **breaking for the app, not for Nitro** — Nitro's own PormG surface needs no edit,
  but a consuming app pinned to Nitro now resolves PormG `0.5.x`, and PormG 0.5.0 carries 22
  breaking entries of its own.

### What changed

`[compat]` moves from `PormG = "^0.4"` to `PormG = "^0.5"`. Nothing in `ext/NitroPormGExt.jl`
changed: every symbol it reaches — `PormG.Models.Model` and the `CharField`/`TextField`/
`DateTimeField`/`FloatField` constructors, `PormG.connection`, `PormG.Configuration.load`,
`PormG.Dialect.create_table`/`create_index`, `PormG.ConnectionPool.fetch` and
`PormG.register_ignore_tables!` — still resolves on 0.5.0, and the extension's two forward-compat
hooks are `isdefined`-guarded. The extension tests pass unchanged.

None of PormG 0.5.0's 22 breaking entries touches Nitro, because Nitro's ORM use is deliberately
narrow: two flat models with no relations, no CTEs, no `cjoin_on`, no `F(...)` expressions, no
`bulk_update`, no Django import, and no `AutoField`. The entries cluster on exactly those features.

**The break is transitive.** If your app uses PormG directly — and an app that gave Nitro a
`PormGSessionStore` or `PormGWorkerStore` almost certainly does — upgrading Nitro drags your PormG
with it, and *your* query code is what has to move.

### How to find the calls to migrate

Do not grep for this one. Run PormG's own guide, which renders only the slice newer than your pin,
and follow each entry's migration note:

```bash
# From PormG's environment, not Nitro's -- PormG is a weakdep here.
julia --project=../PormG.jl -e 'using PormG; PormG.upgrade_guide(from = v"0.4.0")'
```

The entries most likely to reach an ordinary app, in rough order of blast radius:

| PormG entry | What breaks |
|---|---|
| #481 | `F("alias.col")` is removed; use `Joined(alias, col)` |
| #444 | CTE columns are `CTE(name, path)`, not `"<cte>__col"` strings |
| #411 | A wrong-typed filter value raises `FilterError`, not `InvalidValueError` |
| #408/#409/#417 | `AutoField` is retired |
| #345/#346 | Django-import app prefix moves to `db_table`; `ignore_table` and `Model_to_str`'s `settings` are gone |
| #358 | Row-level writes no longer auto-resync PostgreSQL sequences — call `resync_sequences` yourself |

### Migrate your app

```julia
# Nitro side: nothing. Your Project.toml already tracks Nitro; the PormG bound follows.
# App side: work PormG's guide above, then re-run your suite.
```

If you do not use PormG at all, there is nothing to do — it is a weak dependency, and the extension
only loads when you load PormG yourself.
---

## `internalrequest`'s `catch_errors`/`serialize` are no longer ignored on a warm route (#79)

- **Version**: Unreleased
- **Nitro ref**: #79; `src/routerhof.jl`, `src/core.jl`, `src/types.jl`
- **Recorded**: 2026-09-01
- **Severity**: **behavior (a call that returned a `500` now throws)** — bug fix.

### What changed

`middleware_cache` lives on `ctx.service` and outlives any one pipeline, but the chain it stores
closes over the serializer — `DefaultSerializer(catch_errors; show_errors)`, present only when
`serialize` is true. Those three settings were baked into the cached value while the key named only
the route, so the **first** pipeline to warm a route won permanently and every later pipeline's
kwargs were silently ignored:

```julia
ctx = ServerContext()
urlpatterns(ctx, "", [path("/boom", req -> error("kaboom"), middleware = [mw])])

internalrequest(ctx, HTTP.Request("GET", "/boom"); catch_errors = true)   # 500, warms the cache
internalrequest(ctx, HTTP.Request("GET", "/boom"); catch_errors = false)  # ALSO 500 — ignored
```

The cache key now carries those settings (`"GET|/boom|cES"`), so each pipeline gets its own chain.
The second call above **throws**, as it always should have.

**This is not a `serve` change.** One pipeline lives for the server's lifetime there, so its baked
settings were always the correct ones. It reaches code that drives `internalrequest` with varying
kwargs against a shared context — in practice, test suites.

`serve`'s and `setupmiddleware`'s `show_errors` kwargs are now declared `::Bool` (they were
untyped), so that a truthy non-`Bool` cannot bake one behaviour into the chain while the key records
another. One previously-working combination now throws: `serve(…; serialize = false,
show_errors = <non-Bool>)` used to slip through — with `serialize = false` no serializer was built,
so the value was never converted — and is now a `MethodError` at the `serve` boundary.

### How to find the calls to migrate

```bash
# Two or more internalrequest calls against ONE context with differing kwargs — the shape whose
# outcome changes. Worth reading each hit rather than trusting the count.
rg -n -U 'internalrequest[\s\S]{0,200}?(catch_errors|serialize)' <app>/src <app>/test

# Assertions on cache key spelling, which gained a 4-character settings suffix.
rg -n 'middleware_cache' <app>/src <app>/test

# Non-Bool show_errors, which is now a MethodError rather than a silent conversion.
rg -n 'show_errors\s*=' <app>/src <app>/test
```

### Migrate your app

Only tests that leaned on the bug need an edit, and the edit is to assert the correct thing:

```julia
# ✗ before — the second call silently reused the first call's catch_errors = true
internalrequest(ctx, HTTP.Request("GET", "/boom"); catch_errors = true)
@test internalrequest(ctx, HTTP.Request("GET", "/boom"); catch_errors = false).status == 500

# ✓ after — catch_errors = false means the handler's error propagates
internalrequest(ctx, HTTP.Request("GET", "/boom"); catch_errors = true)
@test_throws Exception internalrequest(ctx, HTTP.Request("GET", "/boom"); catch_errors = false)
```

If a test asserted on cache keys directly, add the settings tag. Build it with `cachetag` rather
than hard-coding the four characters:

```julia
# ✗ before
@test haskey(snapshot(ctx.service.middleware_cache), "GET|/warm")

# ✓ after — catch_errors = false, show_errors and serialize defaulted
using Nitro.Core.RouterHOF: cachetag
@test haskey(snapshot(ctx.service.middleware_cache), "GET|/warm" * cachetag(false, true, true))
```

`custommiddleware` is **unchanged** — it still keys on the bare route. The two tables no longer
share a key space.

---

## Lifecycle hook order is now specified: registration order in, LIFO out (#74)

- **Version**: Unreleased
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

---

## `Service.lifecycle_middleware` splits by owner; route-level startup hooks survive a restart (#82)

- **Version**: Unreleased
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

---

## Percent-decoding now happens once, at the boundary — query, `Path{T}`, and cookie values change (#70)

- **Version**: Unreleased
- **Nitro ref**: #70; `src/types.jl`, `src/core.jl`, `src/utilities/misc.jl`, `src/extractors.jl`,
  `ext/TimeZonesExt.jl`
- **Recorded**: 2026-08-30
- **Severity**: **behavior (parameter values reaching handlers)** — bug fix. Three separate value
  changes; an app that compensated for any of them by hand will now double-correct.

### What changed

Percent-decoding is now performed **exactly once**, in the `Types.*` accessor that turns the raw
request into a map. `parseparam`, `parsetype`, and `struct_builder` are pure type conversion and
never unescape. Previously the `parseparam` family carried an `escape=true` keyword — the
*converter* decided — and that one default was correct for path params and wrong for query params.

Three defects followed from it, all fixed together:

- **Query values were decoded twice.** `HTTP.queryparams` decodes, then `parseparam` decoded again.
  `?q=100%25%20off` reached the handler mangled instead of as `100% off`; `%252B` collapsed to a
  literal `+`. Silent — no error, just a wrong string.
- **`Path{T}` was never decoded at all.** It binds through `struct_builder`/`parsetype`, which do
  not unescape, so `GET /files/a%2Fb` reached the struct field as the literal `a%2Fb` while the
  scalar form of the same parameter correctly yielded `a/b`. The two binding paths disagreed.
- **`Cookie{T}` values were decoded on read but never encoded on write.** `set_cookie!` validates
  octets (`_validate_cookie_value`) rather than percent-encoding, and `%` is a legal cookie octet,
  so a cookie written as `a%2Bb` was read back as `a+b`.

Scalar path parameters are **unchanged** — they were already decoded exactly once; the decode
simply moved from `parseparam` up to `Types.pathparams`.

Two further changes to **malformed** input, one a fix and one a genuinely new restriction:

- **A malformed escape is now a clean `400` (fix).** `HTTP.unescapeuri` throws on `%ZZ` or a
  trailing `%`, and `HTTP.queryparams` throws the same way. `?q=%ZZ` previously returned `500`
  with a logged backtrace — that path was unguarded before this change too — and moving the path
  decode to the accessor would have put it outside the guard as well. Both accessors now raise
  `ValidationError`, so both are a `400` and neither logs a stack trace per request.
- **A value decoding to invalid UTF-8 is now rejected with `400` (new restriction).**
  `unescapeuri("%80")` does not throw; it returns an invalid `String`. Nothing downstream
  rejected it either, so `GET /f/caf%E9` and `?q=%FF` **used to return `200`** — with the bad
  byte reaching your handler and, through `Res.json`, the response body. Nitro now refuses the
  request instead of emitting an invalid-UTF-8 body. If you accept Latin-1 or other non-UTF-8
  encoded parameters, percent-encode them as UTF-8 client-side, or read the raw value from
  `req.target` yourself.

Also: `HTTP.queryparams(::HTTP.Request)` — which Nitro re-exports — now raises `ValidationError`
for a malformed query string where it previously raised `ArgumentError`/`EOFError`. A `catch`
block matching on those specific types needs updating.

The `escape` keyword is **removed**, not re-defaulted, so no call site can opt back into a second
decode. `parseparam` is not part of Nitro's public export surface (it is exported from the internal
`Util` module only), so this signature change is source-visible only to code reaching into
`Nitro.Core.Util` — or defining its own `parseparam` method, as `ext/TimeZonesExt.jl` does.

### How to find the calls to migrate

```bash
# 1. Any method or call passing the removed keyword — including in your own extensions.
grep -rn "parseparam" --include=*.jl . | grep "escape"

# 2. Hand-rolled workarounds for the old double decode: a re-encode before reading a query
#    value, or a decode/encode wrapped around a cookie read. These now over-correct.
grep -rnE "escapeuri|unescapeuri" --include=*.jl .

# 3. Handlers reading `Path{T}` fields that compensated for the missing decode.
grep -rn "Path{" --include=*.jl .
```

### Before → after

```julia
# 1. A custom `parseparam` method (e.g. in your own package extension)
# before
function parseparam(::Type{MyType}, str::String; escape=true)
    return parse(MyType, escape ? HTTP.unescapeuri(str) : str)
end
# after — the value arrives already decoded
function parseparam(::Type{MyType}, str::String)
    return parse(MyType, str)
end

# 2. A handler that re-encoded to undo the double decode
# before
handler(req, q::String) = search(HTTP.escapeuri(q))
# after — `q` is now exactly what the client sent
handler(req, q::String) = search(q)

# 3. A handler that decoded a `Path{T}` field by hand
# before
handler(req, p::Path{Ref}) = lookup(HTTP.unescapeuri(p.payload.name))
# after — already decoded
handler(req, p::Path{Ref}) = lookup(p.payload.name)
```

### ⚠️ Security: check anything that builds a filesystem path or URL from a path parameter

`Path{T}` fields and `req.params` values were previously **not** decoded, and are now. Encoded
traversal sequences that used to arrive inert now arrive live:

```
GET /files/..%2F..%2Fetc%2Fpasswd

  before →  p.payload.name == "..%2F..%2Fetc%2Fpasswd"   (usually a harmless ENOENT)
  after  →  p.payload.name == "../../etc/passwd"
```

An app that joined such a value straight into a path was already wrong — the scalar form of the
same parameter (`handler(req, name::String)`) has always been decoded and was always exploitable
— but this change makes the `Path{T}` and `req.params` spellings behave like the scalar one, so
code that looked safe by accident no longer is. **Audit every handler that reaches a filesystem,
an outbound URL, or a shell from a path parameter, and reduce the value to a bare basename or
validate it against an allowlist:**

```julia
# unsafe — traversal reachable
handler(req, p::Path{FileRef}) = readfile(joinpath(UPLOAD_DIR, p.payload.name))

# safe — strip any directory component before joining
handler(req, p::Path{FileRef}) = readfile(joinpath(UPLOAD_DIR, basename(p.payload.name)))
```

**Nitro's own static/SPA mounts are not affected.** `staticfiles`/`spafiles`/`dynamicfiles`
enumerate the tree at mount time and register one literal route per file, so no path parameter
ever reaches a path join inside the framework. This exposure is entirely in application code.

### `req.params` is now a snapshot, not a live handle

Decoding cannot be done in place, so `req.params` (and `getparams(req)`) builds a **fresh `Dict`
on every access**. It used to hand back the router's own dictionary. Mutating it is therefore now
a no-op:

```julia
# before — the write was visible to later reads
req.params["tenant"] = resolve_tenant(req)

# after — silently lost; use the request context instead
req.context[:tenant] = resolve_tenant(req)
```

Reading is unaffected. Only code that *wrote* to `req.params` to pass a value down a request
needs to change.

Apps that never put a `%` in a query value, never used `Path{T}` or `req.params`, never sent a
non-UTF-8 percent-encoded parameter, and never stored a `%` in a cookie are unaffected and need
no edit.

---

## 0.2.0 — 2026-08-10

## PormG compat moves to `^0.4` — apps on the PormG extension must upgrade PormG too

- **Version**: 0.2.0
- **Nitro ref**: `Project.toml` `[compat]`; `ext/NitroPormGExt.jl`
- **Recorded**: 2026-08-10
- **Severity**: **breaking (dependency resolution)** — an app still bounded to PormG `0.3` does not
  resolve against this release.

### What changed

Nitro's bound moved from `PormG = "^0.3"` to `PormG = "^0.4"`. PormG 0.4.0 is a breaking release
train of its own, carrying 17 entries.

**Nitro itself needed no source change.** Every one of those 17 entries was checked against
`ext/NitroPormGExt.jl` with its own *"How to find the calls to migrate"* grep, and all came back
empty — Nitro's PormG surface is two models with no foreign keys, no `ManyToManyField`, no bulk
writes, no introspection, and no `catch` that reads a PormG error type.

**Your app's surface is not that narrow.** Its own models, queries, and migrations are exactly what
PormG 0.4.0 changes, so the work is in PormG's guide, not this one. The runtime change most likely
to reach an app silently is **SQLite now enforcing foreign keys** (PormG #276): writes that
succeeded on SQLite and only failed in PostgreSQL now raise `IntegrityError` on both. Nitro's own
`nitro_session` and `nitro_task` tables declare no foreign keys, so that enforcement does not touch
them.

### How to find the calls to migrate

```bash
# Does this app use the PormG extension at all? If not, only the dependency bound matters.
rg -n 'pormg_nitro_session|pormg_nitro_worker|PormGSessionStore|PormGWorkerStore' <app>/src

# The app's own PormG bound — this is what must move.
rg -n 'PormG' <app>/Project.toml
```

### Migrate your app

```julia
# 1. Raise the app's own bound in Project.toml [compat]:
#      PormG = "^0.4"
#
# 2. Run PormG's guide from PormG's OWN environment — it is a weak dependency here, so it does not
#    load from the app's env — and apply every entry it lists before bumping the bound:
#      julia --project=/path/to/PormG.jl -e 'using PormG; PormG.upgrade_guide(from = v"0.3.0")'
#
# 3. Re-run the app's suite against SQLite specifically. Foreign-key enforcement is the change that
#    passes a code review and fails at runtime.
```

---

## `terminate()` force-closes after a bounded drain; `serve()` refuses to start over a live server (#73)

- **Version**: 0.2.0
- **Nitro ref**: #73; `src/core.jl`, `src/context.jl`, `src/methods.jl`, `src/constants.jl`
- **Recorded**: 2026-08-08
- **Severity**: **behavior (shutdown semantics, a new error on a previously-silent call, and a
  Windows socket-option default)** — bug fix.

### What changed

Three defects let a Nitro process outlive `terminate()` still holding its port.

- **`terminate()` is now bounded.** It was `HTTP.close(::Server)`, which releases the listener and
  then loops until every tracked connection is gone — force-closing only *idle* ones. HTTP 2.4
  declares a `HIJACKED` connection state and never assigns it, so a WebSocket, SSE, or STREAM
  handler pins its connection for its whole lifetime and that loop **never ends**; `terminate()`
  called from inside a request handler deadlocks against its own connection. `terminate()` now waits
  `timeout` seconds for in-flight work and then calls `HTTP.forceclose`, modeled on Go's
  `http.Server.Shutdown(ctx)`. The default is **10 s** (`Nitro.Core.SHUTDOWN_TIMEOUT_SECONDS`),
  settable per server with `serve(shutdown_timeout = …)` and per call with `terminate(timeout = …)`;
  `timeout = 0` skips the graceful phase. **Long-lived connections are now cut at the timeout** — if
  a streaming handler must finish cleanly, signal it from a `LifecycleMiddleware`'s `on_shutdown`,
  which runs before the drain.
- **`serve()` on a context that is already serving now throws.** It used to overwrite
  `ctx.service.server[]`, leaving the previous `HTTP.Server` unreachable and its port bound until the
  process exited — with nothing left that could close it. Call `terminate()` first, or give the
  second listener its own context (`instance()` / `ServerContext()`). Relatedly, `terminate()` now
  resets `ctx.service.server[]` to `nothing`; code reading that field after shutdown gets `nothing`
  instead of a dead handle.
- **`reuseaddr` now defaults to `false` on Windows** (`true` on Linux/macOS, unchanged). On Windows
  `SO_REUSEADDR` lets a second process bind a port another process is *actively listening on*, with
  indeterminate delivery — so an orphaned server silently answered some requests from its own router
  instead of the bind failing. An explicit `serve(reuseaddr = …)` still wins.

### How to find the calls to migrate

```bash
# Shutdown sites that may now cut a long-lived connection, and any terminate() reachable from a
# handler (that one used to hang, and is now a guaranteed forced shutdown).
rg -n 'terminate\(' <app>/src <app>/test

# A second serve() on the same context — now an error instead of a silent leak.
rg -n 'serve\(' <app>/src

# Streaming handlers that will be force-closed at the timeout.
rg -n 'method\s*=\s*"(STREAM|WEBSOCKET)"|::HTTP\.Stream|::WebSocket' <app>/src

# Reads of the server handle after shutdown — now `nothing`.
rg -n 'service\.server\[\]' <app>/src

# Windows deployments that relied on the old reuseaddr default.
rg -n 'reuseaddr' <app>/src
```

### Migrate your app

```julia
# ✗ before — unbounded: hung forever if any streaming connection was open
serve(port = 8080, async = true)
terminate()

# ✓ after — bounded; give slow requests room, or cut immediately
serve(port = 8080, async = true, shutdown_timeout = 30)
terminate()              # waits up to 30 s, then force-closes
terminate(timeout = 0)   # no graceful phase at all
```

```julia
# ✗ before — silently orphaned the first listener; its port stayed bound for the process's life
serve(port = 8080, async = true)
serve(port = 9090, async = true)

# ✓ after — the second call throws ArgumentError. Terminate first …
serve(port = 8080, async = true)
terminate()
serve(port = 9090, async = true)

# … or run the second listener on its own context
app2 = instance()
app2.serve(port = 9090, async = true)
```

```julia
# ✓ after — a streaming handler that must finish cleanly needs its own shutdown signal, because
# the drain cannot wait out a connection that never closes itself
# `Nitro.LifecycleMiddleware`, qualified: the type is not in Nitro's export list, so a bare
# name fails with UndefVarError under `using Nitro`.
const STOPPING = Base.Event()
serve(middleware = [Nitro.LifecycleMiddleware(middleware = identity,
                                              on_shutdown = () -> notify(STOPPING))],
      shutdown_timeout = 15)
```

---

## Static mounts no longer serve dotfiles, escaping symlinks, or route-pattern filenames (#20)

- **Version**: 0.2.0
- **Nitro ref**: #20; `src/utilities/fileutil.jl`, `src/core.jl`, `src/methods.jl`
- **Recorded**: 2026-08-09
- **Severity**: **behavior (files that were served now 404)** — security fix.

### What changed

`staticfiles`, `spafiles` and `dynamicfiles` used to register a route for **every** regular file
under the mounted folder. Pointing a mount at a directory that also held `.git/`, `.env`, or a
symlink to a file outside it served those to any unauthenticated client — something nginx, Express
and Caddy all deny by default.

Four classes of entry are now refused at mount time:

- **Hidden entries** — any path component starting with `.`, *relative to the mounted folder*. That
  covers `.env` and everything under `.git/`. The folder's own name is never tested, so mounting a
  dotted directory directly still works. Interior dots (`file.min.js`) are unaffected. The rule
  applies to what a symlink **resolves to** as well as to its own name, so an innocuously-named link
  pointing at an in-mount dotfile is refused too.
- **Symlinks resolving outside the mount** — resolved with `realpath` and required to stay under the
  resolved root, so a link *inside* the mount still works while `data.csv -> /etc/passwd` does not.
  Windows directory junctions count as symlinks here.
- **Filenames the router reads as patterns.** Two different failures. A file named `*` or `**` is an
  HTTP.jl wildcard and shadows its siblings — a request for any unmatched path under the mount was
  answered with that file's body. A file whose name contains `{` or `}` is read as a path parameter
  by Nitro's own route parser, which then threw `ArgumentError` because a mount's handler takes no
  such parameter, so **a single such file made `serve()` fail to boot** — an unauthenticated
  startup denial of service against exactly the user-writable directory `dynamicfiles` is meant for.
  Both are always refused; there is no opt-out. No working app can have been serving one, so this
  half needs no migration.
- **Anything that is not a regular file** — symlinked directories, FIFOs, sockets, devices.

Two related fixes ride along. `spafiles`' history-mode fallback used to locate `index.html` by
probing the filesystem, which reached straight past the mount rules: a refused `index.html` was
still served on *every* unmatched path under the mount. It now registers only if `index.html` is
actually servable, and logs a warning otherwise.

**These checks run at mount time only.** Which files exist is decided once, when the mount runs;
`dynamicfiles` still re-reads *content* per request, but it does not re-evaluate the rules. Serving a
directory whose contents an attacker can change between startup and a request is explicitly out of
scope for this layer — put a reverse proxy in front of it, or do not serve that directory. The
reasoning is in [`docs/design/static-serving-boundary.md`](docs/design/static-serving-boundary.md).

`include_hidden=true` and `allow_symlink_escape=true` restore the old behavior per mount. The
enumerator `Nitro.Core.Util.getfiles` has been replaced by `Nitro.Core.Util.mountable_files`, and
`mountfolder` now returns the `Vector{String}` of routes it registered.

### How to find the calls to migrate

```bash
# Every mount — check each one against the folder it actually points at
rg -n 'staticfiles|spafiles|dynamicfiles' <app>/src

# Mounts pointed at a project or build root are the ones most likely to lose files
rg -n '(static|spa|dynamic)files\(\s*"\.?/?"' <app>/src

# Direct users of the removed enumerator
rg -n 'getfiles' <app>/src <app>/test
```

Then list what a mount now refuses, without starting a server. Walk the tree yourself for the
left-hand side — `readdir` would compare only the top level, and against directories rather than
files, so it reports every ordinary subdirectory as "refused" while hiding every nested refusal:

```julia
julia> all_files = [joinpath(d, f) for (d, _, fs) in walkdir("public") for f in fs];

julia> setdiff(all_files, Nitro.Core.Util.mountable_files("public"))
```

### Migrate your app

```julia
# ✗ before — served .env, .git/config and any escaping symlink under "public"
staticfiles("public", "static")

# ✓ after — same call, but those entries are now refused. Nothing to change unless you
#   were relying on one of them; the mount logs what it skipped at startup.
staticfiles("public", "static")

# ✗ before — a dotted directory was served because nothing was filtered
staticfiles("public", "static")     # relied on public/.well-known/* being reachable

# ✓ after — mount it as its own root; the rule tests components *below* the folder,
#   never the folder's own name
staticfiles("public", "static")
staticfiles("public/.well-known", ".well-known")

# ✓ last resort — reinstate the old behavior for one mount, deliberately
staticfiles("public", "static"; include_hidden=true, allow_symlink_escape=true)
```

**`.well-known` will not make ACME work**, and it did not before either: every Nitro mount registers
only the files that exist when it runs, and `http-01` writes `acme-challenge/<token>` at renewal
time, long after boot. Serve that with a handler, not a mount.

One `spafiles`-specific wrinkle: because the history-mode fallback answers any unmatched path under
the mount, a refused file reads as `index.html` with a `200` rather than a `404`. Nothing leaks, but
it is confusing in logs — check the startup message for what was skipped rather than probing URLs.

---

## Worker task ids are namespaced by owner, and `submit_task` is authorized (#19)

- **Version**: 0.2.0
- **Nitro ref**: #19; `src/Workers/`, `ext/NitroPormGExt.jl`
- **Recorded**: 2026-08-09
- **Severity**: **breaking (return value + submit authorization)** — security fix.

### What changed

A task key used to be both the deduplication identity **and** the access capability. Resubmitting a
key that was already `RUNNING` or `PENDING` added the caller to the task's watcher list, and watcher
membership is the only gate on `get_task_status` (which returns `:result`) and `cancel_task`. Any
authenticated user who could guess a key derived from a non-secret resource id — `export_$report_id`
— read another user's task result and cancelled their job. Resubmitting a *finished* foreign key was
worse still: it replaced the record, destroying the owner's result and dropping them from the
watcher list. `submit_task` also ran no authorizer at all, unlike `submit_sequential_task`.

Three changes:

1. **`submit_task` and `submit_sequential_task` take `scope::Symbol = :user` and return the id the
   task is stored under.** Under `:user` that id is `"<user_id>::<task_key>"`, so two users
   submitting the same key get two independent tasks and neither can name the other's.
   `scope=:global` keeps the old verbatim key for genuinely shared work.
2. **A caller who is not already a watcher of an existing key is refused** with `AuthorizationError`,
   whether the task is live or finished. Opt back in with the new
   `set_watch_authorizer!(store, (task_key, watchers, user_id) -> Bool)`. Under `:user` scope this
   cannot fire between two ordinary callers.
3. **`submit_task` now runs the store's queue authorizer** under `DEFAULT_QUEUE_NAME` (`"default"`),
   following the default-queue convention. An allowlist authorizer must permit that name.

Two supporting changes fall out of those:

- **`submit_task` can now throw `AuthorizationError`**, which it never could before — from the
  queue authorizer and from the cross-user gate. Nitro does not map that exception to a status
  code, so a handler that submits without a `try`/`catch` turns a denial into a 500.
- **`PormGWorkerStore.get_task_info` rethrows read failures** instead of logging and returning
  `nothing`, matching `set_task!`. It had to: `nothing` meant "no such task", so one swallowed
  connection error would have skipped the gate above and let a caller take over an existing task.
  A failing read now surfaces instead of masquerading as an absent row.

  This reaches the read APIs too. Where a database failure used to be reported as
  `get_task_status → Dict(:status => "NOT_FOUND")`, `cancel_task → Dict(:error => "Task not
  found")`, and `is_task_running → false`, the exception now propagates. The old answers were
  wrong — a client could not tell "your task was cleaned up" from "the database is down" — but a
  polling route that silently degraded will now return 500 during an outage. Handle it if that
  matters to you. The sequential-queue processor is unaffected: it drops the failing item, logs,
  and keeps draining.

### How to find the calls to migrate

```bash
# 1. Every submission: the return value is now the id to keep.
rg -n 'submit_task|submit_sequential_task' --type julia

# 2. Reads and cancels given a literal or reconstructed key rather than the returned id.
rg -n 'get_task_status|cancel_task|is_task_running' --type julia

# 3. Queue authorizers that allowlist rather than denylist — these now close submit_task.
rg -n 'set_queue_authorizer!' --type julia
```

### Migrate your app

```julia
# ✗ before — the key you passed was the key you polled
submit_task("export_$(report_id)", cb, user_id)
status = get_task_status("export_$(report_id)", user_id)
cancel_task("export_$(report_id)", user_id)

# ✓ after — keep what the submit returned
task_id = submit_task("export_$(report_id)", cb, user_id)
status  = get_task_status(task_id, user_id)
cancel_task(task_id, user_id)

# ✓ after — or rebuild it, when the value was not kept (e.g. a separate status route)
task_id = scoped_task_key("export_$(report_id)", user_id)

# ✗ before — an allowlist authorizer that never saw submit_task
set_queue_authorizer!(store, (q, uid) -> q in queues_for(uid))

# ✓ after — it does now, under DEFAULT_QUEUE_NAME
set_queue_authorizer!(store, (q, uid) -> q == DEFAULT_QUEUE_NAME || q in queues_for(uid))

# ✓ after — deliberately shared work, gated explicitly. Keep the hook a pure in-memory
# predicate: it runs under the store's task lock.
set_watch_authorizer!(store, (task_key, watchers, uid) -> ORG_OF[first(watchers)] == ORG_OF[uid])
submit_task("warm-price-cache", cb, user_id; scope=:global)

# ✓ after — a denial is an exception, not a return value
try
    task_id = submit_task(key, cb, user_id)
catch err
    err isa AuthorizationError || rethrow()
    return Res.status(403, Res.json(Dict("error" => "forbidden")))
end
```

Operational notes:

- **In-flight rows are not migrated.** Tasks already persisted under the old unscoped ids stay
  readable only by their old id, and a resubmission now writes a new namespaced row. Drain the queue
  before upgrading, or delete the stale `nitro_task` rows.
- **`nitro_task.id` widened from `VARCHAR(100)` to `VARCHAR(255)`** to fit both halves.
  `_ensure_task_table!` only issues `CREATE TABLE IF NOT EXISTS`, so an existing Postgres or MySQL
  database keeps its old width and needs a one-time
  `ALTER TABLE nitro_task ALTER COLUMN id TYPE VARCHAR(255);`. SQLite ignores `VARCHAR` lengths and
  needs nothing.
- **`user_id` values are now constrained under `:user` scope**: they may not contain `::` and may
  not end in `:`, or `scoped_task_key` raises `ArgumentError`. Both rules keep the owner half of an
  id unambiguous. A colon elsewhere (`"google:12345"`) is still fine. Likewise a `:global`
  `task_key` may not contain `::`.
- **A scoped id contains `::`, which is not a legal Windows filename character.** If you used the
  value returned by `submit_task` as a path component — a staged upload, a cache file — derive that
  path from the `task_key` you passed in instead, or sanitize the id.

---

## Global middleware now runs on unmatched (404) and method-mismatched (405) requests (#71)

- **Version**: 0.2.0
- **Nitro ref**: #71; `src/routerhof.jl`, `src/core.jl`
- **Recorded**: 2026-08-08
- **Severity**: **behavior (middleware now runs on 404/405)** — bug fix.

Global middleware — the `middleware=[...]` vector passed to `serve` — now runs on **every**
request, including ones that match no route (404) and ones whose path matches but whose method
does not (405).

Previously this depended on something unrelated: `compose` was only installed when the app had
registered at least one route with per-route `middleware=`, and `compose`'s unmatched branch
called the inner handler directly, skipping the global chain. So an app **with** per-route
middleware silently exempted 404s and 405s from all global middleware, while an app **without**
any ran it on them. The two are now consistent, matching what the routing docs already described.

**Who this affects.** Only apps that use per-route middleware *and* global middleware. If your
global middleware assumed it only ever saw matched routes, it now also sees unmatched ones:

- an auth middleware that rejects unauthenticated requests will return **401 instead of 404** for
  unknown paths;
- a session middleware will create a session and emit `Set-Cookie` on 404 responses;
- a rate limiter will now count unmatched requests — this is usually the point, since it closes a
  bypass where 404 probes were never limited.

**How to find the calls to migrate**

```bash
rg -n 'serve\(' --glob '*.jl' -A5 | rg 'middleware\s*='
```

For each global middleware in those vectors, ask whether it is correct for a request that matches
no route. Nitro's own middleware needs no change.

**Before → after** — a global auth middleware that should not turn unknown paths into 401s.
Scope it to the subtree it actually guards:

```julia
# before — fine only while unmatched requests never reached it
auth = handler -> function (req)
    isauthenticated(req) || return json(Dict("error" => "unauthorized"); status = 401)
    return handler(req)
end

# after — guard the paths it owns; everything else falls through to the router
auth = handler -> function (req)
    if startswith(req.target, "/api/") && !isauthenticated(req)
        return json(Dict("error" => "unauthorized"); status = 401)
    end
    return handler(req)
end
```

Alternatively, move it off the global list and attach it per route with
`path(...; middleware = [GuardMiddleware(login_required())])`, which never sees unmatched
requests at all.

---

## Scalar path & query params reject bad input with 400; `Nullable{T}` params bind their value (#18)

- **Version**: 0.2.0
- **Nitro ref**: #18; `src/utilities/misc.jl`, `src/core.jl`, `src/extractors.jl`
- **Recorded**: 2026-08-08
- **Severity**: **behavior (status codes + optional-param binding)** — bug fix.

### What changed

Nitro had two binding paths that disagreed about whose fault a bad request is. Extractors
(`Json{T}`, `Query{T}`, `Path{T}`, …) routed every failure through a guard that produced a clean
`400`. Plain scalar parameters — `function get_user(req, id::Int)` — called `parseparam` unguarded,
so client input errors escaped as **`500 Internal Server Error`** with a full stack trace logged per
request. Both halves are fixed:

- **Malformed scalar path or query values are now `400`.** `/users/abc` against `<int:id>`, an
  out-of-range `@enum`, an empty `Char` segment, an `Int` that overflows — all `400`, not `500`. The
  converter remains a *binding* declaration rather than a routing filter, so this is a `400` and not
  a `404`; a route-level pattern could not reject the overflow case anyway.
- **A required query parameter that was not sent is now `400`.** It was a `KeyError` → `500`. A
  parameter *with* a declared default is unaffected: absence still falls back to the default.
- **`parseparam(::Union, …)` throws instead of returning the raw string.** When no member type
  parsed, it returned the unparsed `String` — a value outside the declared type, which reached the
  handler and typically became a `MethodError` → `500`. It is now a `400`.
- **`Nullable{T}` scalar params bind the client's value.** `Base.uniontypes` puts `Nothing` first and
  `JSON.parse(str, Nothing)` succeeds for *any* valid JSON, so `Union{Nothing, Int}` matched
  `Nothing` before it ever tried `Int`: **`?cursor=5` bound `nothing`.** `Nothing` is no longer a
  parse target, and neither is `Missing`, which had the identical defect.
- **`JsonFragment{T}` returns `400` for a body it cannot read.** The fragment key lookup sat outside
  the extractor guard, so a body missing the key (`KeyError`) or one that is not a JSON object at
  all (`MethodError`) escaped as a `500` while every sibling extractor returned a `400`.
- **Rejected requests are no longer logged with a backtrace.** `handlerequest` logs a
  `ValidationError` at `@debug` and genuine faults still log at `@error` with the full trace. This
  also removes the per-request stack trace that extractor `400`s were emitting, which made a spray
  of malformed URLs a log-flood vector. The `@debug` line deliberately does **not** include the
  `ValidationError` message: `try_validate` embeds a preview of the deserialized payload in it, so
  logging it would put a submitted password in the log.

The `400` response body is unchanged: the generic `{"message": "400: Bad Request"}`.

### How to find the calls to migrate

```bash
# Handlers with optional scalar path/query params — the silent half
rg -n 'Nullable\{|Union\{[^}]*Nothing' <app>/src

# Your own tests, and any client retry policy, asserting 5xx on bad input
rg -n '== 500|status.*500' <app>/test
```

The `Nullable{T}` change is the one that needs eyes. Nothing breaks at load time and nothing throws:
a handler that branched on `isnothing(cursor)` simply starts taking the other branch, because it now
receives the value the client actually sent. Read each hit and confirm the "absent" branch is still
what you want for a *present* value.

**One `Nullable{T}` case flips from `200` to `400`: a literal `?cursor=null`.** It used to be
absorbed by the `Nothing` member and bound `nothing`; now no member type accepts it. A JavaScript
client building `` `?cursor=${cursor}` `` with a null value emits exactly that string — omit the
parameter instead of sending `null`. (`?cursor=` with an empty value was already broken: it bound
the raw `""` and then `MethodError`'d into a `500`. It is now a clean `400`.)

### Migrate your app

```julia
# ✗ before — `?cursor=5` bound `nothing`, so this always took the first-page branch
function list_items(req, cursor::Nullable{Int} = nothing)
    return isnothing(cursor) ? first_page() : after(cursor)   # `after` was unreachable
end

# ✓ after — `?cursor=5` binds 5; absent still binds nothing; `?cursor=abc` is a 400
#   No source change is required, but verify the branch is correct now that both are reachable.

# ✗ before — a required query param that was not sent produced a 500
function search(req, q::String, limit::Int) ... end
# GET /search?q=chair   ->  500

# ✓ after
# GET /search?q=chair   ->  400   ... or give `limit` a default to make it genuinely optional:
function search(req, q::String, limit::Int = 20) ... end
```

If an app depends on the old status codes — an integration test asserting `500`, or an HTTP client
whose retry policy fires on 5xx and not 4xx — update it. Bad input now reports as bad input.

---

## `ExtractIP` trust model rebuilt; `trust_forwarded` removed (#16)

- **Version**: 0.2.0
- **Nitro ref**: #16; `src/middleware/extract_ip.jl`, `src/middleware/rate_limiter.jl`, `src/core.jl`
- **Recorded**: 2026-08-03
- **Severity**: **breaking (removed kwarg + changed resolution)** — security fix.

### What changed

Under `trusted_proxies`, the configuration the old docstring called "the recommended, safe option",
the resolved client IP was attacker-controllable. Two defects: `X-Forwarded-For` was read
**leftmost-first** — the client-controlled end of the chain, so a client that prepended
`X-Forwarded-For: 9.9.9.9` before nginx appended the real address won outright — and
`CF-Connecting-IP`/`True-Client-IP` were honored *above* `X-Forwarded-For` unconditionally, which
no ordinary nginx config strips. Either header could be rotated to mint an unlimited number of
rate-limit buckets, forge access-log entries, and slip past IP allow/deny lists.

The trust model is now declarative. `ExtractIP` reads **exactly one** header, named by the
operator, and only when the socket peer is a listed proxy:

- `forwarded_header::Symbol` — `:none` (default), `:x_forwarded_for`, `:x_real_ip`,
  `:cf_connecting_ip`, `:true_client_ip`. It and `trusted_proxies` are strictly
  mutually-required; setting either alone is an `ArgumentError` at construction.
- `trusted_proxies` now accepts **CIDR strings** (`"10.244.0.0/16"`, `"2400:cb00::/32"`) mixed
  with `IPAddr` values, so k8s ingress pods and published CDN ranges are expressible. A catch-all
  range is rejected.
- `X-Forwarded-For` is walked **right-to-left**, peeling hops that match `trusted_proxies`; the
  first address that is not one of yours is the client. Unreadable chains, all-proxy chains and
  absent headers fall back to the socket peer.
- A header sent on **several lines** is treated as one value, joined in order per RFC 9110 §5.3,
  so a client-supplied line cannot shadow the one a proxy appended. This matters for proxies that
  append a new header line rather than rewriting (HAProxy's `option forwardfor`).
- Addresses resolved out of a header are returned in canonical form, so `::ffff:203.0.113.7` and
  `203.0.113.7` no longer key two different rate-limit buckets.
- `trust_forwarded` is **removed**. It trusted headers from any peer and guessed which header to
  read; passing it now throws with a message naming the replacement — on `RateLimiter` as well as
  on `ExtractIP`.
- On `RateLimiter`, `auto_extract_ip = false` is now **incompatible** with `forwarded_header` /
  `trusted_proxies` and throws. That combination built no `ExtractIP` at all, so both keywords
  were accepted, never validated, and had no effect: every client stayed in the proxy's single
  bucket while the configuration read as active. Set the IP yourself in your own middleware, or
  keep `auto_extract_ip = true` and let the limiter apply them.
- `RateLimiter` also validates the pair **itself** now, rather than deferring to the `ExtractIP`
  it composes — a bad trust configuration fails at `RateLimiter(...)`, not later at `serve()`.
- `extract_ip` returns `Union{IPAddr, Nothing}` — it previously declared `::IPAddr` while being
  able to return `nothing` for a request that never went through the server.
- New: `getpeerip(req)` returns the socket peer, preserved by `ExtractIP` before it overwrites
  `getip(req)`. No forwarding header can change it.

`ExtractIP()` with no arguments is unchanged and still the safe default: the socket peer is used
and no forwarding header is read.

### How to find the calls to migrate

```bash
rg -n 'trust_forwarded|trusted_proxies|extract_ip' <app>     # not just <app>/src — proxy trust
                                                             # is often set in config/ or env wiring
```

Every `ExtractIP`/`RateLimiter` hit needs a `forwarded_header` alongside it, and a configuration
missing one will not start — the `ArgumentError` names the absent keyword — so those call sites
cannot fail silently.

**`extract_ip` is the exception, and it is why the grep includes it.** It is now a public export
and its return type widened from `IPAddr` to `Union{IPAddr, Nothing}`. A direct call such as
`ip::IPAddr = extract_ip(req)` or `string(extract_ip(req))` breaks at runtime, and a bare
`extract_ip(req)` with no trust configured keeps returning the peer exactly as before — so this
one *does* have a silent path. Check every direct call for a `nothing` it did not previously have
to handle.

### Migrate your app

```julia
# ✗ before — the header was guessed from a fixed priority list
ExtractIP(trusted_proxies = [ip"127.0.0.1"])

# ✓ after — declare the one header your proxy writes
ExtractIP(forwarded_header = :x_forwarded_for, trusted_proxies = [ip"127.0.0.1"])

# ✗ before — trusted forwarding headers from ANY peer
ExtractIP(trust_forwarded = true)

# ✓ after — name the proxies instead; CIDR covers dynamic addresses
ExtractIP(forwarded_header = :x_forwarded_for, trusted_proxies = ["10.244.0.0/16"])

# ✗ before — same two kwargs on the rate limiter
RateLimiter(rate_limit = 100, trusted_proxies = [ip"127.0.0.1"])

# ✓ after
RateLimiter(rate_limit = 100,
            forwarded_header = :x_forwarded_for,
            trusted_proxies  = [ip"127.0.0.1"])
```

Two operational notes. Your proxy must **set** the header it writes, not forward a client-supplied
value — `proxy_set_header X-Real-IP $remote_addr`, not a pass-through — because single-valued
headers are believed as written. And if you were relying on a vendor header while declaring
`X-Forwarded-For`, that now resolves differently: only the declared header is read, which is the
point of the fix.

---

## 0.1.0 — 2026-07-31

## `jwt_validator` returns a `Principal`, not the raw claims object (#46)

- **Version**: 0.1.0
- **Nitro ref**: #46, #4; `src/Auth/`, `src/middleware/`, `docs/src/tutorial/authentication.md`
- **Recorded**: 2026-07-31
- **Severity**: **breaking (return type)** — part of the `0.1.x` claim-based identity wave.

### What changed

`jwt_validator` used without a `user_validator` set `req.user` to the decoded claims object, so apps
reached into it with property sugar (`req.user.sub`) and sometimes mutated it. It now yields a
`Principal`: an immutable, dict-like wrapper over the *verified* claims with typed fields `id`
(normalized identity), `kid` (keyset-verified key id) and `source` (`:claim` / `:kid`).

Dict-style **reads** are unchanged — `user["sub"]`, `get`, `haskey`, iteration, `==`, and the JSON
serialization (which is exactly the claims object) all behave as before. Only property access and
mutation break.

### How to find the calls to migrate

```bash
rg -n 'user\.[a-z_]+' <app>/src        # property sugar on req.user
rg -n 'req\.user\[[^]]+\]\s*='  <app>/src   # mutation of req.user
```

`.id`, `.claims`, `.kid` and `.source` are the only valid properties; every other `req.user.<name>`
is a claim read that must become an index.

### Migrate your app

```julia
# ✗ before — property sugar over the claims object
subject = req.user.sub
email   = req.user.email

# ✓ after — index the Principal
subject = req.user["sub"]
email   = req.user["email"]
# or use the normalized identity field
subject = req.user.id

# ✗ before — mutating the claims in place
req.user["tenant"] = tenant_id

# ✓ after — the Principal is immutable; build your own user object in a
# user_validator, or copy out of it
u = Dict(req.user)
u["tenant"] = tenant_id
```

---

## `user_validator` receives the `Principal`; the tuple contract is `(user, principal)` (#46)

- **Version**: 0.1.0
- **Nitro ref**: #46; `src/Auth/`, `src/middleware/`
- **Recorded**: 2026-07-31
- **Severity**: **breaking (callback argument + context key)** — part of the `0.1.x` claim-based
  identity wave.

### What changed

A `user_validator` used to be handed the raw claims dict, and a validator returning a tuple returned
`(user, claims)`. It now receives the `Principal` — a dict-compatible superset of the old argument —
and the tuple contract is `(user, principal)`. Consequently `req.context[:auth_claims]` now holds
the `Principal` rather than a raw claims dict.

Because `Principal` supports the same dict reads, a validator that only *indexes* its argument keeps
working untouched. What breaks is a validator that treats the argument as a mutable `Dict`, calls
`Dict`-only methods on it, or annotates the parameter with `::Dict`.

### How to find the calls to migrate

```bash
rg -n 'user_validator' <app>/src
rg -n 'auth_claims' <app>/src
```

Then check each validator body for `::Dict` annotations, `setindex!`/`push!`/`delete!` on the
argument, and any downstream code that reads `req.context[:auth_claims]` expecting a plain dict.

### Migrate your app

```julia
# ✗ before — annotated and mutated as a Dict
function load_user(claims::Dict)
    claims["seen_at"] = now()
    return (fetch_user(claims["sub"]), claims)
end

# ✓ after — accept the Principal, copy before mutating, return (user, principal)
function load_user(principal)
    user = fetch_user(principal["sub"])   # or principal.id
    return (user, principal)
end

# ✗ before — downstream consumer assumed a dict
claims = req.context[:auth_claims]
claims["extra"] = 1

# ✓ after — it is a Principal; copy out if you need a mutable dict
principal = req.context[:auth_claims]
claims = Dict(principal)
claims["extra"] = 1
```

---

## `jwt_validator(...; with_kid=...)` is now a construction-time `ArgumentError` (#46)

- **Version**: 0.1.0
- **Nitro ref**: #46; `src/Auth/`
- **Recorded**: 2026-07-31
- **Severity**: **breaking (removed kwarg)** — part of the `0.1.x` claim-based identity wave.

### What changed

`with_kid` existed to opt into surfacing the token's key id. The kid now always flows through the
`Principal` (`req.user.kid`, populated only when the key id was *verified* against a keyset), so the
kwarg is redundant and is rejected at construction time rather than silently ignored. Passing it
throws an `ArgumentError` when the validator is built — at bootstrap, not per-request.

Note the tightened trust rule that comes with it: only a keyset-verified kid is exposed. A `kid`
header on a single-secret token is never trusted and leaves `req.user.kid` unset.

### How to find the calls to migrate

```bash
rg -n 'with_kid' <app>/src
```

### Migrate your app

```julia
# ✗ before
validator = jwt_validator(keyset = ks, with_kid = true)

# ✓ after — drop the kwarg; read the verified kid off the Principal
validator = jwt_validator(keyset = ks)

# in a handler or guard:
signing_key = req.user.kid          # nothing unless keyset-verified

# to authorize on it, prefer the declarative guard over a manual check
path("/admin", admin_handler, middleware = [kid_required(["ops-2026"])])
```

---

## Template for new entries

<!--
Copy the block below into the `## Unreleased` section at the top of the log for each new
breaking/behavior change. Do NOT bump `Project.toml` — the version moves once, at cut time
(the `nitro-cut-release` skill rewrites `Version: Unreleased` → the release number).

## `<api>` — <one-line summary of the change>

- **Version**: Unreleased
- **Nitro ref**: <issue / PR / commit> ; <src file>
- **Recorded**: <YYYY-MM-DD>
- **Severity**: breaking | behavior change | deprecation

### What changed
<what the old API did vs. the new contract>

### How to find the calls to migrate
<error message to grep for, or the call pattern>

### Migrate your app
```julia
# ✗ before
...
# ✓ after
...
```

-->
