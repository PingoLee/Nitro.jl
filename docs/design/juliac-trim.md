# juliac `--trim`: the walls, and the order to clear them in

Design record for compiling a Nitro app with Julia 1.12's `juliac --trim`. It covers what the
verifier reports, which walls are cleared, which remain, why each remaining one is a design
question rather than a patch, and the decision (§4) that makes clearing them the goal. The measuring
harness is `bench/juliac/` ([#570](https://github.com/PingoLee/Nitro.jl/issues/570)). The first
wall was cleared in [#571](https://github.com/PingoLee/Nitro.jl/issues/571), and
[#572](https://github.com/PingoLee/Nitro.jl/issues/572) is where this record was written.

> **TL;DR.** The lifecycle wall is gone: on the minimal app the verifier dropped from **408**
> errors to **20**. What was left was not a list of untyped values. Two `Service` fields hold
> values whose type depends on the *app*: the router and the running server. Every closure the
> pipeline builds captures the router, so the request pipeline was abstract to a static compiler
> however the layers were folded. **§4 is decided: `--trim=safe` is a product target.** §3.1 is
> done ([#625](https://github.com/PingoLee/Nitro.jl/issues/625)): one Nitro-owned router type,
> with the custom 404/405 as fixed responses on `App`. The app-wide half of §3.2 is done
> ([#572](https://github.com/PingoLee/Nitro.jl/issues/572)): `setupmiddleware` builds one type
> whatever the `serve` flags, and `serve` builds its listener from it without a dynamic call. The
> count went *up*, 22 to 40, because the verifier now reaches `startserver` and the banner, code
> it never looked at before (§3). The route boundary of §3.2 is done
> ([#718](https://github.com/PingoLee/Nitro.jl/issues/718)): one `RouteEndpoint` per route chain and
> per handler, a direct call under the JIT and a `ccall` to an exported thunk in a trimmed image.
> Measured on the request-path probe (§1), it clears every error on the route path, 22 of them. The
> next walls are `HTTP.listen!`'s keyword call in front of the request path, and, on it, what
> follows a handler's `Any` result (`format_response`, the security-header layer).

## 1. How to measure

```bash
bench/juliac/build.sh unsafe-warn        # julia +1.12; log under bench/results/ (gitignored)
```

```bash
ENTRY=probe bench/juliac/build.sh unsafe-warn   # the request path, without the listener (#718)
julia bench/juliac/frames.jl bench/results/juliac-<stamp>-<entry>-<mode>.log
```

The verifier reports **the first dynamic call on each path** and does not look past it. A low
count therefore means "the first wall is close", not "nearly done". Each fix can expose code that
was never verified before. Count the errors by the first frame inside `src/` (`frames.jl` does),
not by the raw total: one line of Nitro can account for hundreds of Base frames (§2).

`app.jl` reaches the request path only through `serve` and `HTTP.listen!`, so while any wall stands
in front of the listener the route path is never verified at all. `probe.jl` builds the pipeline
with `setupmiddleware` and calls it on requests (an exact route, a converter route, three
middleware stacks), so the request path is measured whatever the listener does.

## 2. Cleared: the lifecycle wall (#571)

| Mechanism | Errors | Fix |
|---|---|---|
| `repr(revise)` in `serve`'s validation | 310 | `repr` of a `Symbol` goes through Base's `show_unquoted` on an `Any` and drags the `show` machinery in. Interpolating `:$revise` only `print`s the name |
| `Service` slots typed `Ref{T}` | 78, with the row below | `Ref{T}` is abstract, so `getindex` on it was a dynamic call returning `Any`. The slots are now `Base.RefValue{T}`. This also removes a per-request `Any` on the `Cookie{T}`/`Session{T}` binding path in the JIT build |
| `get(kwargs, :async)`, and `get(kwargs, :secret_key)` in the convenience `serve` | (above) | Named keywords instead of reads out of a `Base.Pairs` bag |

The lesson that generalizes: **`repr`/`string` of an un-inferred value is the most expensive single
trim mistake**, and that includes a `Symbol`. Type the value, then `print` it.

## 3. Remaining (40 errors on the minimal app)

Measured 2026-10-22 on Julia 1.12.7, before and after #572. Each error is printed twice, so 20
sites. `main` before #572 had **22**: the 20 below plus `CookieKey`'s, which arrived with a later
merge.

| First frame in `src/` | Before #572 | After #572 | What |
|---|---:|---:|---|
| `src/core/pipeline.jl` `setupmiddleware` | 4 | 0 | the fold (§3.2), **cleared** |
| `src/core/lifecycle.jl` `serve` → `_serve_listener`, `startserver` | 4 | 0 | the pipeline's type through `serve`, **cleared** |
| `src/core/lifecycle.jl` `_serve_pipeline`, the `start` closure | | 4 | `HTTP.listen!(…; kwargs...)` over the `Dict{Symbol,Any}` `startserver` passes: **the next wall in front of the request path** |
| `src/core/lifecycle.jl` `serverwelcome`, `startserver` | | 16 | the banner and the blocking wait's `println`: `Dates.format(now(), "yyyy-mm-dd HH:MM:SS")` builds a `DateFormat` from a runtime string (4 of the 16 surface inside Dates' own `io.jl`), `IO`-typed `stdout`, `join` over `VersionNumber` fields |
| `src/context.jl` `close`, `isopen`, `wait` | 6 | 8 | **the server field (§3.3)** |
| `src/context.jl` `_try_cancel` | 2 | 2 | the `revise = :eager` watcher's `invokelatest`: dev-only and dynamic on purpose, so it stays |
| `src/types.jl` `startup`/`shutdown` | 2 | 4 | the lifecycle hooks (§3.4) |
| `src/crypto.jl` `CookieKey` | 2 | 2 | `NTuple{32,UInt8}` from a `Vector` |
| outside `src/` (OpenSSL.jl, a Base `string`, the libuv read callback) | 2 | 2 | upstream |

The verifier reports **the first dynamic call on each path**, so a cleared wall raises the count
when it exposes code that was never verified. Every row #572 added is code that ran before #572
too, unverified.

What #572 changed:
- **`setupmiddleware`** nests its layers with direct calls instead of `reduce(|>, [ … ])`, and
  installs every framework layer whatever the flags. A disabled one (`serialize`,
  `catch_errors`, `access_log`, `security_headers`, the prefix strip) is a pass-through with one
  branch per request. Its type is a function of the argument types, which
  `test/precompilation_test.jl` pins across every flag combination.
- **User middleware** folds through a `Tuple` in `compose` (`_foldtuple`). A `Vector` is still
  accepted and converted once, which is dynamic. `serve(middleware = (…))` is the typed form.
- **`serve`** builds the pipeline once per `revise` branch and hands it to a function barrier,
  `_serve_pipeline`. A `revise` prepend had made the list a `Union`, and a keyword call over a
  `Union` does not resolve. `serve`, `_serve_pipeline` and `_serve_listener` take the pipeline
  and the handler as type parameters, because Julia does not specialize on a `Function` argument
  a method only passes on: each was compiled for `::Function`, and its next call was dynamic.

| Where | What | Kind |
|---|---|---|
| `_serve_pipeline`'s `start` closure → `HTTP.listen!` | keyword call splatting a `Dict{Symbol,Any}` | next; small |
| `compose` → the route's cached chain | a route table of differently typed chains | the route boundary (§3.2), **cleared** in [#718](https://github.com/PingoLee/Nitro.jl/issues/718) |
| `isopen(::Service)`, `close(::Service)`, `wait` | `Service.server` holds `HTTP.Server{F}`, a UnionAll | **the server field (§3.3)** |
| `startup`/`shutdown` | `LifecycleMiddleware.on_startup`/`on_shutdown` are `Union{Function,Nothing}`-typed | lifecycle only (§3.4), [#719](https://github.com/PingoLee/Nitro.jl/issues/719) |
| the banner | `IO`-typed `stdout`, a runtime `DateFormat` | startup only; not designed yet |
| the `revise = :eager` watcher's cancel | `Base.invokelatest` | dev-only and dynamic on purpose, so it stays |
| `OpenSSL.jl`, libuv read callback | outside Nitro | upstream |

### 3.1 The router field: cleared in #625

*Kept as written when it was the blocker; the outcome is at the end of this section.*

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

**The spike decided the field type: a fixed `HTTP.Response`**
([#625, Phase 1](https://github.com/PingoLee/Nitro.jl/issues/625#issuecomment-6244200220)).
A `FunctionWrapper` fails `--trim=safe` wherever it is built, and the trimmed binary crashes at
its first call. Its `@cfunction` pointer is nulled when the image is serialized, so the first
call re-initializes it, and that dispatches `gen_fptr` on a field typed `Any`. A wrapper built
at runtime also needs a `@cfunction` that the trimmer does not keep. Under the JIT it is also
slower than a plain `Function` field: 15.9 ns against 12.1 ns per call. A fixed response passes
and costs 2.4 ns. The same finding rules FunctionWrappers.jl out for §3.2 and §3.4.

**What landed (#625):**
- `Service.router` is `NitroRouter`, which is
  `HTTP.Router{typeof(_nitro_404), typeof(_nitro_405), Nothing}` (`src/types.jl`). `Service`
  accepts no other router, so HTTP.jl-level router middleware is gone, and with it #282's
  registration refusal.
- The custom 404/405 are `App(not_found = …, method_not_allowed = …)`. They are fixed
  `HTTP.Response` values, carried as `MissResponses` to the pipeline's miss path, the static
  mounts and `RetiredHeadHandler`. A custom 405 still gets `Allow` on a copy. Both are typed
  `MissResponse` (`src/types.jl`), the three body types HTTP.jl keeps as given and can resend,
  not the `HTTP.Response` UnionAll; `App` refuses any other body at construction.
- `RouteResolution.router` is concrete as well.

### 3.2 The fold and the route boundary

**The outer fold is done (#572); the route boundary is open (#718).** Once the router was
concrete, the outer fold needed three things, and each landed as written:

- **a tuple** rather than `reduce(|>, [ … ])`;
- **one type per layer whatever the flags.** The conditional layers (`serialize`, `catch_errors`,
  `prefix`, `access_log`, `security_headers`) are runtime `Bool`s, and `cond ? (x,) : ()` over
  five flags is a union of up to 32 shapes, which inference widens away. A built-or-pass-through
  layer with one predictable branch per request keeps one type;
- **user middleware passed as a `Tuple`** for the typed path. `serve(middleware = [ … ])` stays
  valid, but a `Vector` of mixed closures is folded dynamically. A `LifecycleMiddleware` member is
  abstract either way, because its `middleware` field is typed `Function`.

Behind that sat **the route boundary**, [#718](https://github.com/PingoLee/Nitro.jl/issues/718).
Per-route and group middleware chains were composed and cached per route (`compose`, `ChainCache`
in `src/routerhof.jl`), and a route table holding different chain types hands back an abstract
value. The leaf the router terminal calls has the same problem: HTTP.jl types `Leaf.handler` as
`Any`, and every route's handler is a closure of its own type. The chain was also *folded* on the
request path, from a `Vector{Function}`, which no compiler can type.

**Done in #718: one erasure point per route, Nitro-built.** Prior art: Tower/axum type each layered
stack fully and erase it at the router with `BoxCloneService`. So every route has a
`RouteEndpoint` (`src/routeendpoint.jl`) for its chain and one for its handler:

- **The chain is folded once, at registration** (`publish_route_middleware!`), around `RouteNext`,
  which continues into the pipeline running it through the request's `RouteResolution`. That
  handler has one concrete type, `PipelineHandler`, since the serializer and the router entry
  became named structs. Registration is top-level code, which under `juliac` runs at build time,
  so the untyped fold is never verified; only the call through the endpoint is. Chains are recorded
  beside the entry they were folded from and published under one lock, so a request never runs a
  chain under an entry it was not folded from.
- **Under the JIT the endpoint is a direct call**, `obj(req)`: the one dynamic call per route the
  untyped table made.
- **In a `--trim` build it is a `ccall`.** The verifier rejects a call it cannot resolve; a
  `foreigncall` is not one. Registration `Core.eval`s a concrete thunk method per chain type and
  request shape, roots it with `Base.Experimental.entrypoint`, exports it with `Base._ccallable`,
  and redefines `_trimmed()` to `true`, so inference folds the endpoint to one branch per build.
  A pointer does not survive an image, so the first call looks the symbol up through `jl_dlsym`
  on the executable's handle. The thunk catches what the handler throws and hands it back, so no
  exception unwinds through the C frame. `test/juliac_internals_contract_tests.jl` pins the Base
  calls on 1.12 and 1.13.
- **A leaf not registered through Nitro is refused** (`serve` will not start; a request reaching
  one gets a `500`): a call to an arbitrary leaf is exactly the dynamic call this removes.

The candidates, measured on the probe and in a scratch spike (Julia 1.12.7):

| Candidate | `--trim=safe` | Why |
|---|---|---|
| `FunctionWrapper{HTTP.Response, Tuple{HTTP.Request}}` | fails | #625 Phase 1: its pointer is nulled in the image and re-derived through a dynamic `gen_fptr` |
| dispatch unrolled over a tuple of routes, typed at `serve` | not prototyped: cannot pass | `main` knows the tuple's type only if it is part of `App`'s, which §3.1 decided against; built at `serve` from the `Vector{Function}` table it is itself a dynamic fold; a route registered after `serve` (#71) needs a dynamic fallback |
| `Core.OpaqueClosure{Tuple{Req},Resp}` | fails | the call is an "unresolved call" (`verifytrim.jl` resolves only builtins and `invoke`s), and building one is flagged too |
| a closed set of Nitro's own layer types (union-splitting) | does not help | route middleware is user code, union-splitting stops at four types, and the leaf is always a user closure |
| **`RouteEndpoint`: an exported thunk per type, called with `ccall`** | **passes** | a scratch program with three differently typed chains builds under `--trim=safe` with 0 errors and serves all three; on the Nitro probe the route path clears (below) |

Verifier on `bench/juliac/probe.jl`, `unsafe-warn`, Julia 1.12.7, counted by first frame in `src/`:

| First frame in `src/` | `main` | #718 |
|---|---:|---:|
| `routerhof.jl` `foldlayers` (the fold on the request path) | 10 | 0 |
| `types.jl` `cache_chain!` | 2 | 0 |
| `routerhof.jl` `compose`: the cached and the fresh chain call | 4 | 0 |
| `pipeline.jl` the leaf call (`_dispatch_resolved`, `_route_unresolved`, `_route_rerouted`) | 6 | 0 |
| `framework_middleware.jl` / `misc.jl` serializer: `format_response(::Any)`, `handle_error` | 6 | 10 |
| `middleware/security_headers.jl` (a response typed `Any`) | 12 | 12 |
| `pipeline.jl` `_app_context_seed` (`ScopedValue` HAMT) | 6 | 6 |
| `types.jl` `pathparams` on `LazyRequest` (newly reached, inside a handler) | – | 2 |
| outside `src/`: `probe.jl`'s own `main`, Base's `string`, the libuv read callback | 6 | 6 |
| **total** | **52** | **36** |

The route path is clear: what remains starts after a handler returns, whose result is `Any` by
design, or in layers outside the route boundary. The trimmed probe binary shows the same: on
`main` it dies inside `foldlayers`; with #718 the request reaches the route's handler through the
endpoint, which builds its response, and the binary stops at `format_response`, the next wall.
`app.jl` stays at 40: its request path is still behind `HTTP.listen!`'s keyword call.

What it asks of an application: nothing in code, but a route middleware factory now runs once per
route at registration, so what it creates is shared by `serve` and every `internalrequest`; a
direct `HTTP.register!` is refused. The `upgrading/` entry carries both.

**The JIT build does not pay for it** (§4's rule), measured behind `bench/socket/quiet.sh` on
Julia 1.13.2 against `main`:

- `bench/socket/run.sh`, 5 × 6 s interleaved, c=50, `--threads=8`, over `/plaintext`, `/json` and
  `/mw` (group plus route middleware), in both mode orders. Every route's sign follows the order,
  the known order effect: +0.61 / −0.02 / +0.08% with `main` first, −0.99 / −1.30 / −0.91% with
  the branch first. Nothing loses ≥ 2% in both orders.
- Start-up is faster, not slower: with `FILLER_ROUTES` routes over three middleware stacks, time to
  listen is 4.2 / 7.8 / 45 s at 10 / 100 / 1000 routes against `main`'s 6.4 / 19 / 146 s, and the
  trimmed build 14 / 18 / 56 s against 14 / 21 / 101 s. Both grow linearly. The first request is
  unchanged (≈ 1.4 s). Every leaf now has the one type `RouteEndpoint`, so `HTTP.register!` no
  longer compiles a specialization per handler type, which is the likely source; #726 measures
  registration on its own.

### 3.3 The server field

`Service.server` holds `HTTP.Server{F}`, where `F` is the listener and so the pipeline type. It is
read only at the start of `serve` (`isopen`) and at `terminate` (`close` → `_shutdown_server`),
never per request. A concrete field needs the same type-parameter decision as §3.1. Re-deriving
`isopen` from HTTP.jl's internal fields would work, and it is the wrong trade (nitro-core §4).

### 3.4 Lifecycle hooks

`on_startup`/`on_shutdown` are `Union{Function,Nothing}`-typed (abstract), live in a `Vector{LifecycleMiddleware}`, and run
only at startup and shutdown. The typed option this section used to name,
`FunctionWrapper{Nothing, Tuple{}}`, is ruled out: FunctionWrappers.jl fails `--trim=safe`
wherever the wrapper is built (#625, §3.1). The hooks need a shape of their own. That is open,
and it comes fifth in §4's order.

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

1. **§3.1, the router's type. Done (#625):** one Nitro-owned router type, and the custom
   404/405 as fixed responses on `App`. It typed every pipeline closure, but cleared no verifier
   error on its own: the fold behind it is the next wall on that path (§3).
2. **§3.2's outer fold. Done (#572).** This record put it third, behind §3.3, and called it
   blocked on the server field. The dependency runs the other way: `Service.server` is
   `HTTP.Server{F}` with `F` the pipeline's type, so the field cannot be concrete until the
   pipeline is. The fold also cleared its own errors without §3.3.
3. **§3.3, the server field**, and `HTTP.listen!`'s keyword call in front of the request path.
   The field's type parameter is the pipeline's, fixed at `serve` time, not at `App`
   construction, so it needs its own shape. One candidate, not designed yet: a typed handle that
   `serve` returns and `terminate` takes. **§3.2's route boundary is done (#718)**: one
   `RouteEndpoint` per route chain and per handler.
4. **The request path:** #537, #538, #546, #566. Those four also help the JIT build, so they need
   not wait for 1–3.
5. **§3.4, the lifecycle hooks ([#719](https://github.com/PingoLee/Nitro.jl/issues/719)).**
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
