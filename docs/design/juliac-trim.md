# juliac `--trim`: the walls, and the order to clear them in

Design record for compiling a Nitro app with Julia 1.12's `juliac --trim`. It covers what the
verifier reports, which walls are cleared, which remain, why each remaining one is a design
question rather than a patch, and the decision (§4) that makes clearing them the goal. The measuring
harness is `bench/juliac/` ([#570](https://github.com/PingoLee/Nitro.jl/issues/570)). The first
wall was cleared in [#571](https://github.com/PingoLee/Nitro.jl/issues/571), and
[#572](https://github.com/PingoLee/Nitro.jl/issues/572) is where this record was written.

> **TL;DR.** The lifecycle wall is gone: on the minimal app the verifier drops from **408**
> errors to **20**. What is left is not a list of untyped values. Two `Service` fields hold
> values whose type depends on the *app*: the router and the running server. Every closure the
> pipeline builds captures the router, so the request pipeline is abstract to a static compiler
> however the layers are folded. Clearing that means `Service`'s type has to carry the router's
> type, or Nitro has to own one router type. Both are API-shaped choices. **§4 is decided:
> `--trim=safe` is a product target**, and §3.1 is decided: one Nitro-owned router type. That is
> the first change.

## 1. How to measure

```bash
bench/juliac/build.sh unsafe-warn        # julia +1.12; log under bench/results/ (gitignored)
```

The verifier reports **the first dynamic call on each path** and does not look past it. A low
count therefore means "the first wall is close", not "nearly done". Each fix can expose code that
was never verified before. Count the errors by the first frame inside `src/`, not by the raw
total: one line of Nitro can account for hundreds of Base frames (§2).

## 2. Cleared: the lifecycle wall (#571)

| Mechanism | Errors | Fix |
|---|---|---|
| `repr(revise)` in `serve`'s validation | 310 | `repr` of a `Symbol` goes through Base's `show_unquoted` on an `Any` and drags the `show` machinery in. Interpolating `:$revise` only `print`s the name |
| `Service` slots typed `Ref{T}` | 78, with the row below | `Ref{T}` is abstract, so `getindex` on it was a dynamic call returning `Any`. The slots are now `Base.RefValue{T}`. This also removes a per-request `Any` on the `Cookie{T}`/`Session{T}` binding path in the JIT build |
| `get(kwargs, :async)`, and `get(kwargs, :secret_key)` in the convenience `serve` | (above) | Named keywords instead of reads out of a `Base.Pairs` bag |

The lesson that generalizes: **`repr`/`string` of an un-inferred value is the most expensive single
trim mistake**, and that includes a `Symbol`. Type the value, then `print` it.

## 3. Remaining (20 errors on the minimal app)

| Where | What | Kind |
|---|---|---|
| `setupmiddleware` → `_serve_listener` | the pipeline's type is not inferable | **the router field (§3.1)**, then the fold (§3.2) |
| `startserver`'s `start` closure | captures the listener, whose type is the pipeline's | follows from §3.1 |
| `isopen(::Service)`, `close(::Service)` → `_shutdown_server` | `Service.server` holds `HTTP.Server{F}`, a UnionAll | **the server field (§3.3)** |
| `startup`/`shutdown` | `LifecycleMiddleware.on_startup`/`on_shutdown` are `Union{Function,Nothing}`-typed | lifecycle only (§3.4) |
| the `revise = :eager` watcher's cancel | `Base.invokelatest` | dev-only and dynamic on purpose, so it stays |
| `OpenSSL.jl`, libuv read callback | outside Nitro | upstream |

### 3.1 The router field: the actual blocker for the request path

`Service.router` is declared as `HTTP.Router`, which is `Router{T,S,F}` with all three parameters
free. A default `Router()` is concretely
`Router{typeof(default404), typeof(default405), Nothing}`, but a custom 404/405
(`Service(router = HTTP.Router(my404))`) is a different type. So the field is abstract by design.

That matters because **a closure takes the type of what it captures as a type parameter**. The
innermost layer `router_entry` captures the router, so its type is `var"#…"{<:Router}`, which is
abstract. Every layer folded around it captures it in turn, so the whole pipeline is abstract.
The verifier prints exactly that type at the composition site. **Folding the layers over a tuple
instead of `reduce(|>, [ … ])` types every layer except the innermost one, and the result is still
abstract.**

The JIT build does not have this problem: closure types are fixed when the closure is built at
runtime, and the call out of `_serve_listener` into `stream_handler` is a dynamic dispatch, so
the stream handler and the closures it builds specialize on the runtime pipeline type.
#572's tuple fold would therefore buy nothing in the JIT build. Under trim it buys nothing until
this field is concrete. That is why it was not landed.

The two shapes that would make it concrete:

| Shape | What it costs |
|---|---|
| **`Service{R}` / `App{S}`**: the router's type becomes a type parameter (axum's `Router<S>`) | `App` becomes a UnionAll, so `CONTEXT::Ref{App}` and every `::App` signature turn abstract unless a concrete default alias is pinned. A custom router stays supported |
| **One Nitro-owned router type**: custom 404/405 move from the router's type into a typed field or a fixed callable | Keeps `App` concrete. It is a breaking change to `Service(router = HTTP.Router(my404, …))` and needs a new customization surface and an `upgrading/` entry |

**Decided by the maintainer (2026-10-18): one Nitro-owned router type.** `App` stays concrete, so
`CONTEXT::Ref{App}` and every `::App` signature are unchanged. What the choice leaves to design:

- **Where the custom 404/405 go.** Nitro already calls them itself: `r._404`/`r._405` in
  `_route_miss` and `_method_not_allowed` (`src/core/pipeline.jl`), and `router._404` captured by
  the static mounts (`src/core/staticfiles.jl`). Nitro dispatches with its own `_gethandler`, so
  nothing relies on HTTP.jl calling them. They can therefore leave the router for a field Nitro
  owns, set through `App`.
- **The field's type is the open part.** A `Function` field is abstract, and `--trim=safe` rejects
  the call. That leaves two candidates: a fixed response value, which loses per-request logic, or
  a `FunctionWrapper{HTTP.Response, Tuple{HTTP.Request}}`, which brings in a new dependency whose
  verifier behaviour is unconfirmed (§3.2, §3.4). A spike under `juliac --trim=safe` decides it,
  and the same answer serves §3.2 and §3.4.
- **HTTP.jl's router-level middleware** (the router's third type parameter) goes. Nitro has its
  own chain, and it already refuses that middleware on some routes (#282).

### 3.2 The fold and the route boundary (#572, after §3.1)

Once the router is concrete, the outer fold needs three things:

- **a tuple** rather than `reduce(|>, [ … ])`;
- **one type per layer whatever the flags.** The conditional layers (`serialize`, `catch_errors`,
  `prefix`, `access_log`, `security_headers`) are runtime `Bool`s, and `cond ? (x,) : ()` over
  five flags is a union of up to 32 shapes, which inference widens away. A built-or-pass-through
  layer with one predictable branch per request keeps one type;
- **user middleware passed as a `Tuple`** for the typed path. `serve(middleware = [ … ])` stays
  valid, but a `Vector` of mixed closures is folded dynamically. A `LifecycleMiddleware` member is
  abstract either way, because its `middleware` field is typed `Function`.

Behind that sits **the route boundary**. Per-route and group middleware chains are composed and
cached per route (`compose`, `ChainCache` in `src/routerhof.jl`), and a route table holding
different chain types hands back an abstract value. Typing the outer fold moves the wall to that
line. It does not remove it:

| Goal | Boundary shape | Cost |
|---|---|---|
| JIT performance only | **one function barrier per request** into a concretely typed per-route chain (the trade #516 made for `json_bind`) | about one dynamic call per request. `--trim=safe` rejects it |
| `--trim=safe` | **no unresolved call**: a fixed-signature callable (`FunctionWrapper{HTTP.Response, Tuple{HTTP.Request}}`) or dispatch unrolled over a tuple of routes | a trampoline per call, measure it; unconfirmed that `FunctionWrapper` passes the verifier at all; unrolled dispatch makes compile time grow with the route count |

Prior art: Tower/axum type each layered stack fully and erase it at the router with
`BoxCloneService`. That is one deliberate dynamic boundary per route. Even a fully static stack
accepts one erasure point, so the question is where it goes, not whether there is one.

Still to measure: build time and first-request time at 10, 100 and 1000 routes with mixed group
middleware, since a concrete chain type is one compiled type per distinct stack.

### 3.3 The server field

`Service.server` holds `HTTP.Server{F}`, where `F` is the listener and so the pipeline type. It is
read only at the start of `serve` (`isopen`) and at `terminate` (`close` → `_shutdown_server`),
never per request. A concrete field needs the same type-parameter decision as §3.1. Re-deriving
`isopen` from HTTP.jl's internal fields would work, and it is the wrong trade (nitro-core §4).

### 3.4 Lifecycle hooks

`on_startup`/`on_shutdown` are `Union{Function,Nothing}`-typed (abstract), live in a `Vector{LifecycleMiddleware}`, and run
only at startup and shutdown. The typed option is `FunctionWrapper{Nothing, Tuple{}}`, a new
dependency whose trim behaviour is unverified. This is deliberately left until §4 is decided.

## 4. The decision: `--trim=safe` is a target

**The question was:** is `--trim=safe` a product target for Nitro, or a ratchet that only keeps
new dynamic seams out?

- As a **ratchet**, §2's fixes are the whole value (they also helped the JIT build). New code keeps
  the slots concrete and avoids `repr` of an un-inferred value. §3 stays as it is.
- As a **target**, §3.1 is the first change, and it is an API one. Then come §3.2's route boundary
  and the request path the audit predicted (#537, #538, #546, #566). It is worth deciding before
  publication, while a breaking change to `App`/`Service` is still cheap.

**Decided by the maintainer (2026-10-18): a target.** It is chosen over further work on the
runtime limits the performance passes measured: no preemption (#469), the order spawned tasks
run in (#618), GC safepoints (#588). Nitro cannot change those, and a compiled binary inherits
them unchanged, so a compiled binary is not expected to fix any of them. What it is expected to
buy is a startup and deployment win:
- time to listen, already measured untrimmed: 0.53 s against 2.48 s under the JIT;
- binary size: 3.8 MB trimmed;
- resident memory and time to first request: **neither measured trimmed yet.** Untrimmed, the
  first request is no faster (1.33 s against 1.28 s), because the image keeps the JIT.

The order:

1. **§3.1, the router's type.** One Nitro-owned router type (decided 2026-10-18; see §3.1). Its
   custom 404/405 surface waits on the `FunctionWrapper` spike.
2. **§3.3, the server field.** Its type parameter is the pipeline's, which is fixed at `serve`
   time, not at `App` construction, so it needs its own shape. One candidate, not designed yet: a
   typed handle that `serve` returns and `terminate` takes.
3. **§3.2, the fold and the route boundary (#572).** It does nothing until 1 and 2 land, and it
   is where the per-route erasure point is chosen.
4. **The request path:** #537, #538, #546, #566. Those four also help the JIT build, so they need
   not wait for 1–3.
5. **§3.4, the lifecycle hooks.**
6. **Outside Nitro:** OpenSSL.jl and the libuv read callback, reported upstream.

Two rules come with the target:

- **The JIT build is the one users run today, so it must not pay for the target.** A change made
  for `--trim` that costs the JIT request path more than the noise, such as a `FunctionWrapper`
  trampoline per request where a function barrier would do (§3.2), has to justify that cost with
  a measurement (`bench/socket/run.sh`, interleaved with `main`).
- **Every wall cleared is re-measured with `bench/juliac/build.sh unsafe-warn`, counted by first
  frame in `src/`**, so this record's §3 stays the live backlog. Once the minimal app passes
  `--trim=safe`, the trimmed exe's first request, resident memory and throughput against the JIT
  are the numbers that say whether the target paid off.
