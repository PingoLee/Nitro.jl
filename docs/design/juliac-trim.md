# juliac `--trim`: the walls, and the order to clear them in

Design record for compiling a Nitro app with `juliac --trim`: on Julia 1.13 through the
[JuliaC.jl](https://github.com/JuliaLang/JuliaC.jl) app, and up to #718 on Julia 1.12.7's bundled
driver (§1 says which count comes from which). It covers what the
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
>
> **Recounted on Julia 1.13 (§3.5)**, from the same commit as a 1.12.7 control: the minimal app
> goes from 40 errors to 96 and the probe from 36 to 70. No Nitro code changed between the two.
> 1.13's trim compiler also verifies every closure that verified code builds, as a root of its own.
> That reaches the per-request task behind `HTTP.listen!`, so `app.jl` now shows the request
> path while the listener's wall still stands. And the probe's path-parameter read gets through
> to `_pathparams_uncached`, where `HTTP.getparams` is `Any`.
>
> **The request path Nitro owns is typed (§3.6)**: path parameters, the serializer and the
> error response, and the app-context read. On 1.13 the probe goes from 70 errors to 20 and the
> app from 96 to 87, and the trimmed probe now serves `GET /plaintext` through the whole
> pipeline. What is left on the probe's request path is the security-header layer, Base's
> `ScopedValue` HAMT, and the probe's own `main`.
>
> **The start-up walls are cleared (§3, §3.3):** the banner, `CookieKey`, `HTTP.listen!`'s keyword
> call and the server field, 28 errors. On 1.13 the minimal app goes from 87 to 59, and what is
> left on it is the request path, the lifecycle hooks, the `revise = :eager` watcher and upstream
> code.

## 1. How to measure

```bash
julia +1.13 -e 'using Pkg; Pkg.Apps.add("JuliaC")'   # once: the `juliac` app, in ~/.julia/bin
bench/juliac/build.sh unsafe-warn        # julia +1.13 with JuliaC; log under bench/results/ (gitignored)
```

```bash
ENTRY=probe bench/juliac/build.sh unsafe-warn   # the request path, without the listener (#718)
julia bench/juliac/frames.jl bench/results/juliac-<stamp>-<entry>-<mode>.log
```

**The frontend.** Julia 1.12 ships a `juliac.jl` driver under `share/julia/juliac/`; Julia 1.13
ships none, and its frontend is the JuliaC.jl app. `build.sh` runs JuliaC under `julia +1.13` by
default. `JULIAC=bundled` (which defaults `JULIA` to `julia +1.12`) runs 1.12's driver instead,
so a 1.12 count can be reproduced until the floor moves to 1.13
([#526](https://github.com/PingoLee/Nitro.jl/issues/526)). Every count up to #718 below is
1.12.7's; §3.5 recounts on 1.13. Toolchain of that recount: Julia 1.13.2, JuliaC 0.3.12 (git
tree `49a147f5`, release commit `98e82861`), gcc 13.3.0, Linux x86-64. The 1.12.7 control used
the driver Julia 1.12.7 ships.

Three things about the JuliaC path that a count depends on:
- JuliaC passes `--trim=<mode>` to the process that loads the entry file, so
  `Base.JLOptions().trim` is set while routes register. `RouteEndpoint` (#718) exports its thunks
  then: the 1.13 probe exe carries all 14 `nitro_route_endpoint_*` symbols, without
  `--compile-ccallable`.
- The verifier's output must reach the log through a pipe. With stderr redirected straight to a
  file, a 1.13 build lost the last errors and the summary line (66 of 70 logged). `build.sh` pipes
  through `tee`, and `frames.jl` warns when the `Trim verify finished` line is missing or
  disagrees with its own total.
- JuliaC builds for every target in Julia's system image unless `JULIA_CPU_TARGET` is set. The
  1.12 driver built for `native`. `build.sh` defaults to `native`, so exe size and build time
  stay comparable; the count does not depend on it.

The verifier reports **the first dynamic call on each path** and does not look past it. A low
count therefore means "the first wall is close", not "nearly done". Each fix can expose code that
was never verified before. Count the errors by the first frame inside `src/` (`frames.jl` does),
not by the raw total: one line of Nitro can account for hundreds of Base frames (§2).

`app.jl` reaches the request path only through `serve` and `HTTP.listen!`. On 1.12, while any
wall stands in front of the listener, the route path is never verified at all. `probe.jl` builds
the pipeline with `setupmiddleware` and calls it on requests (an exact route, a converter route,
three middleware stacks), so the request path is measured whatever the listener does. On 1.13 the
verifier also reaches the per-request task behind the listener (§3.5), but `app.jl` has one exact
route and no middleware, so the probe stays the measure of the route path.

## 2. Cleared: the lifecycle wall (#571)

| Mechanism | Errors | Fix |
|---|---|---|
| `repr(revise)` in `serve`'s validation | 310 | `repr` of a `Symbol` goes through Base's `show_unquoted` on an `Any` and drags the `show` machinery in. Interpolating `:$revise` only `print`s the name |
| `Service` slots typed `Ref{T}` | 78, with the row below | `Ref{T}` is abstract, so `getindex` on it was a dynamic call returning `Any`. The slots are now `Base.RefValue{T}`. This also removes a per-request `Any` on the `Cookie{T}`/`Session{T}` binding path in the JIT build |
| `get(kwargs, :async)`, and `get(kwargs, :secret_key)` in the convenience `serve` | (above) | Named keywords instead of reads out of a `Base.Pairs` bag |

The lesson that generalizes: **`repr`/`string` of an un-inferred value is the most expensive single
trim mistake**, and that includes a `Symbol`. Type the value, then `print` it.

## 3. Remaining (40 errors on the minimal app on Julia 1.12.7; on 1.13, 96, then 87 after §3.6 and 59 after the start-up walls)

Measured 2026-10-22 on Julia 1.12.7, before and after #572. Each error is printed twice, so 20
sites. `main` before #572 had **22**: the 20 below plus `CookieKey`'s, which arrived with a later
merge. The `1.13` column is the recount (§3.5), 2026-10-23 at `dea736f0`, with JuliaC; a
1.12.7 control at the same commit gives the After #572 column again, total 40. The `1.13, §3.6`
column is the same build after the request-path change (§3.6), and the last count column after
the start-up walls (below).

| First frame in `src/` | Before #572 | After #572 | 1.13 | 1.13, §3.6 | start-up walls | What |
|---|---:|---:|---:|---:|---:|---|
| `src/core/pipeline.jl` `setupmiddleware` | 4 | 0 | 0 | 0 | 0 | the fold (§3.2), **cleared** |
| `src/core/lifecycle.jl` `serve` → `_serve_listener`, `startserver` | 4 | 0 | 0 | 0 | 0 | the pipeline's type through `serve`, **cleared** |
| `src/core/lifecycle.jl` `_serve_pipeline`, the `start` closure | | 4 | 4 | 4 | 0 | `HTTP.listen!(…; kwargs...)` over the `Dict{Symbol,Any}` `startserver` passes, **cleared** (below) |
| `src/core/lifecycle.jl` `serverwelcome`, `startserver` | | 16 | 14 | 14 | 0 | the banner and the blocking wait's `println`: `Dates.format(now(), "yyyy-mm-dd HH:MM:SS")` builds a `DateFormat` from a runtime string (4 of the 16 surface inside Dates' own `io.jl`), `IO`-typed `stdout`, `join` over `VersionNumber` fields. The control counts this row 18 (2 of them at `startserver`'s wait), which is where its 40 comes from |
| `src/context.jl` `close`, `isopen`, `wait` | 6 | 8 | 8 | 8 | 0 | **the server field (§3.3)**, cleared |
| `src/context.jl` `_try_cancel`; on 1.13 also `lifecycle.jl:118` | 2 | 2 | 3 | 3 | 3 | the `revise = :eager` watcher's `invokelatest`: dev-only and dynamic on purpose, so it stays |
| `src/types.jl` `startup`/`shutdown` | 2 | 4 | 4 | 4 | 4 | the lifecycle hooks (§3.4) |
| `src/crypto.jl` `CookieKey` | 2 | 2 | 2 | 2 | 0 | `NTuple{32,UInt8}` from a `Vector` |
| `src/core/transport.jl`: the stream handler's body read (`_http_stream_request`, `_swallow_request_body!`), the response write and release | | | 18 | 18 | 18 | **new on 1.13**: the per-request task, reached past the `HTTP.listen!` wall (§3.5) |
| `src/middleware/security_headers.jl` | | | 20 | 20 | 20 | **new on 1.13**: a response typed `Any`, the same rows as on the probe (§3.2) |
| `src/core/pipeline.jl` `_app_context_seed`; serializer `format_response`, `handle_error` | | | 11 | 2 | 2 | **new on 1.13**: the probe's rows of the same name (§3.2). §3.6 clears all but the seed's `@with`, which is inside Base |
| outside `src/` (OpenSSL.jl, a Base `string`, the libuv read callback; on 1.13 also Base's `errormonitor` task, `printstyled`'s closure, `showerror`, the TLS read) | 2 | 2 | 12 | 12 | 12 | upstream |

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
| `_serve_pipeline`'s `start` closure → `HTTP.listen!` | keyword call splatting a `Dict{Symbol,Any}` | **cleared**: a `NamedTuple` (below) |
| `compose` → the route's cached chain | a route table of differently typed chains | the route boundary (§3.2), **cleared** in [#718](https://github.com/PingoLee/Nitro.jl/issues/718) |
| `isopen(::Service)`, `close(::Service)`, `wait` | `Service.server` holds `HTTP.Server{F}`, a UnionAll | **cleared**: `ServerHandle` (§3.3) |
| `startup`/`shutdown` | `LifecycleMiddleware.on_startup`/`on_shutdown` are `Union{Function,Nothing}`-typed | lifecycle only (§3.4), [#719](https://github.com/PingoLee/Nitro.jl/issues/719) |
| the banner | `IO`-typed `stdout`, a runtime `DateFormat` | **cleared** (below) |
| the `revise = :eager` watcher's cancel | `Base.invokelatest` | dev-only and dynamic on purpose, so it stays |
| `OpenSSL.jl`, libuv read callback | outside Nitro | upstream |

**The start-up walls, cleared.** Four rows stood in front of the request path or on the way out of
`serve`: the banner, `CookieKey`, `HTTP.listen!`'s keyword call and the server field. Measured
2026-10-23 on `bench/juliac/app.jl`, `unsafe-warn`, Julia 1.13.2 with JuliaC 0.3.12, against
`main` at `b218d362` (§3.6 merged); counted by first frame in `src/`:

| First frame in `src/` | `main` | after | What changed |
|---|---:|---:|---|
| `src/core/lifecycle.jl` `serverwelcome`, `startserver` (the banner, the blocking wait's `println`) | 14 | 0 | the banner is built in one buffer and written once, through `_with_stdout`, which hands it `stdout` as one of the concrete types Base installs there; colours are `printstyled`'s bytes; the version is printed part by part; the date format is a `dateformat"…"` constant |
| `src/crypto.jl` `CookieKey` | 2 | 0 | `ntuple` over `Val(32)`, after checking the length |
| `src/core/lifecycle.jl` `_serve_pipeline`, the `start` closure → `HTTP.listen!` | 4 | 0 | `preprocesskwargs` returns a `NamedTuple`, not a `Dict{Symbol,Any}`, so the keyword call resolves |
| `src/context.jl` `close`, `isopen`, `wait` | 8 | 0 | `Service.server` holds a `ServerHandle` (§3.3) |
| `src/core/transport.jl`: the body reads, the response write and release | 18 | 18 | the request path (§4, step 4) |
| `src/middleware/security_headers.jl` | 20 | 20 | a route chain's `Any` result (§3.6) |
| `src/core/pipeline.jl` `_app_context_seed`'s `@with` | 2 | 2 | inside Base's `ScopedValue` HAMT (§3.5) |
| `src/types.jl` `startup`/`shutdown` | 4 | 4 | the lifecycle hooks (§3.4) |
| `src/context.jl` `_try_cancel`, `src/core/lifecycle.jl` the `ReviseHandler`'s `invokelatest` | 3 | 3 | dev-only and dynamic on purpose |
| outside `src/` | 12 | 12 | upstream |
| **total** | **87** | **59** | |

By step: 87, then 71 with the banner and `CookieKey`, 67 with the keywords, 59 with the server
field. No step added a row. The probe is unchanged at 20, row for row: none of the four is on its
path.

What a trimmed build does differently, all at start-up or shutdown: the banner has no colour, since
reading `:color` from a terminal loads terminfo through untyped code; and the banner and the
blocking wait's newline go to Julia's `Core.stdout`, because a trimmed executable's `stdout` is
the stream saved when the image was built, never initialized. A write to it throws "stream not
initialized" (found by running the trimmed app: a Ctrl-C to its blocking `serve` died there). With
that fixed, the same Ctrl-C unwinds through `terminate`, the handle's `ccall`s and a clean exit.
Under the JIT the banner's bytes are unchanged on a terminal, a file and a pipe, and with
`--color=yes|no`.

The keyword call keeps every key the caller passed, so a keyword `HTTP.listen!` does not take is
still refused by its own `MethodError` (#525), and every value still meets HTTP.jl's own checks.
A list of named, typed keywords would have made Nitro refuse unknown keys itself, with a different
error.

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

Verifier on `bench/juliac/probe.jl`, `unsafe-warn`, Julia 1.12.7, counted by first frame in `src/`.
The `#718, 1.13` column is #718 again, recounted on Julia 1.13 with JuliaC (§3.5), and the last one
is the request-path change on the same toolchain (§3.6):

| First frame in `src/` | `main` | #718 | #718, 1.13 | §3.6, 1.13 |
|---|---:|---:|---:|---:|
| `routerhof.jl` `foldlayers` (the fold on the request path) | 10 | 0 | 0 | 0 |
| `types.jl` `cache_chain!` | 2 | 0 | 0 | 0 |
| `routerhof.jl` `compose`: the cached and the fresh chain call | 4 | 0 | 0 | 0 |
| `pipeline.jl` the leaf call (`_dispatch_resolved`, `_route_unresolved`, `_route_rerouted`) | 6 | 0 | 0 | 0 |
| `framework_middleware.jl` / `misc.jl` serializer: `format_response(::Any)`, `handle_error` | 6 | 10 | 12 | 0 |
| `middleware/security_headers.jl` (a response typed `Any`) | 12 | 12 | 10 | 10 |
| `pipeline.jl` `_app_context_seed`: the `ScopedValue` HAMT, and on 1.13 the `Ref{Any}` read | 6 | 6 | 6 | 4 |
| `types.jl` `pathparams` on `LazyRequest` (newly reached, inside a handler) | – | 2 | 0 | 0 |
| `types.jl` `_pathparams_uncached`: `HTTP.getparams` returns `Any` | – | – | 36 | 0 |
| outside `src/`: `probe.jl`'s own `main`, Base's `string`, the libuv read callback | 6 | 6 | 6 | 6 |
| **total** | **52** | **36** | **70** | **20** |

The route path is clear: what remains starts after a handler returns, whose result is `Any` by
design, or in layers outside the route boundary. The trimmed probe binary shows the same: on
`main` it dies inside `foldlayers`; with #718 the request reaches the route's handler through the
endpoint, which builds its response, and the binary stops at `format_response`, the next wall.
`app.jl` stays at 40: its request path is still behind `HTTP.listen!`'s keyword call. The 1.13
binary, built with JuliaC, does the same: `GET /plaintext` goes through the `ccall` into its
handler, which builds `"Hello, World!"`, and the exe stops at `format_response` (§3.5).

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

### 3.3 The server field: cleared

`Service.server` held `HTTP.Server{F}`, where `F` is the listener and so the pipeline type. It is
read only at the start of `serve` (`isopen`) and at `terminate` (`close` → `_shutdown_server`),
never per request, but each of those calls was one `--trim=safe` rejects: 8 errors on 1.13. The
server's type first exists inside `serve`, which in an executable runs in `main`, so it cannot be
a type parameter of `App` (§3.1 kept `App` concrete) and cannot be exported at build time the way
§3.2's route thunks are.

**Done: `ServerHandle` (`src/context.jl`).** `Service.server` is a
`Base.RefValue{Nullable{ServerHandle}}`, a concrete Nitro struct that holds the `HTTP.Server` and,
in a trimmed build only, three static `@cfunction` pointers to typed shims for `isopen`, `wait`
and the bounded shutdown. `startserver`, where the server's type `S` is concrete, builds it:
- **Under the JIT** the pointers are `C_NULL` and every call is the direct call the bare field made
  before, behind the same `_trimmed()` switch as `RouteEndpoint`. Nothing runs per request.
- **In a trimmed build** each call is a `ccall` through its pointer, which the verifier accepts.
  The `@cfunction`'s signature (`Ref{S}`, and a `Float64` timeout) is static in a method specialized
  on `S`, so its code is compiled ahead of time. The pointer is made at run time and never stored in
  an image, which is what broke `FunctionWrapper` (§3.1). The shims catch what the call throws and
  hand it back, so no exception unwinds through the foreign frame, as `RouteEndpoint`'s thunk does.
  The new catch is in `src/errors.jl`'s list. A handle without pointers is refused, not called.
- **The blocking `serve` waits on its own server**, whose type is concrete there, not through the
  handle, so no foreign frame sits under Ctrl-C for the server's whole life.
- `serve(async = true)` still returns the `HTTP.Server`; `terminate`, `isopen`/`wait(::Service)`,
  the double-`serve` guard and the compare-and-clear in `close` (now on handles) are unchanged.

A scratch program first checked the mechanism under `juliac --trim=safe` on 1.13.2: 0 errors, and
the executable ran a `sleep` inside the foreign frame and handed an exception back.
`test/juliac_internals_contract_tests.jl` runs the trimmed branches in a child process, with
`_trimmed()` redefined to `true`, against a live server.

| Candidate | Verifier | Why it was not chosen |
|---|---|---|
| **`ServerHandle`: static `@cfunction`s made in `startserver`** | clears the 8 | chosen: no API change, nothing per request |
| a typed handle `serve` returns and `terminate` takes | at best the same | `terminate(app)`, `terminate()` and the double-`serve` guard still need an erased handle on `Service`, so it is this design plus an API change and an `upgrading/` entry |
| a thunk exported at build time, as `RouteEndpoint` | cannot clear | the thunks are made with `Core.eval` at registration, which runs while the image is built; the server's type first exists in `serve`, in `main`, where an executable has no `Core.eval`. It would need a new build-time API that declares the server type |
| one concrete listener type, erased per request | clears | adds a dynamic call to every request under the JIT, against §4's rule |
| a supervisor task that owns the typed server, driven over typed channels | clears | moves the blocking wait and `close` onto another task, which changes where Ctrl-C lands (#426, #677) |
| `isopen` re-derived from HTTP.jl's internal fields | clears | the wrong trade (nitro-core §4) |

### 3.4 Lifecycle hooks

`on_startup`/`on_shutdown` are `Union{Function,Nothing}`-typed (abstract), live in a `Vector{LifecycleMiddleware}`, and run
only at startup and shutdown. The typed option this section used to name,
`FunctionWrapper{Nothing, Tuple{}}`, is ruled out: FunctionWrappers.jl fails `--trim=safe`
wherever the wrapper is built (#625, §3.1). The hooks need a shape of their own. That is open,
and it comes fifth in §4's order.

### 3.5 The recount on Julia 1.13

Built 2026-10-23 at `dea736f0` (#718 merged) with JuliaC on Julia 1.13.2, against a control with
the driver Julia 1.12.7 ships, at the same commit (§1). The control reproduces §3's and §3.2's
1.12.7 totals, 40 and 36, so every difference below comes from the toolchain, not from Nitro.

| Build | 1.12.7 | 1.13 |
|---|---:|---:|
| `ENTRY=app`, `unsafe-warn` | 40 | 96 |
| `ENTRY=probe`, `unsafe-warn` | 36 | 70 |
| `ENTRY=probe`, `safe` | – | fails on the same 70 |

**Most of it is one change: 1.13 verifies the closures that verified code builds.** Its trim
compiler (`collectinvokes!` in `Compiler/src/typeinfer.jl`) gained a rule that 1.12.7's lacks.
When code it compiles builds a closure (a `:new` of a `Function` subtype), it also compiles that
closure and verifies it as a root of its own, whether or not the call that would run it resolves.
Those stacks end at the closure, with no caller. On `app.jl` that root is the per-request task
`parallel_stream_handler` spawns, so the request path behind the `HTTP.listen!` wall is now
verified. New rows on the app:
- `transport.jl`, 18: the body reads (`_http_stream_request`, `_swallow_request_body!`) and the
  response write and release, on the handler's `Any` result;
- `security_headers.jl`, 20, and `_app_context_seed` and the serializer, 11: the rows the probe
  already showed (§3.2);
- outside `src/`, +10: Base's `errormonitor` task, the closure `printstyled` hands to
  `with_output_color`, `showerror`, and the TLS read. The banner's `printstyled` line drops from 8
  errors to 4 in the same build, so the `serverwelcome` row reads 14 rather than 18;
- `lifecycle.jl:118`, 1: the `revise = :eager` watcher's `invokelatest`, dynamic on purpose.

Unchanged on the app: `HTTP.listen!`'s keyword call (4), the server field (8), the lifecycle hooks
(4) and `CookieKey` (2). So the walls §4 orders are the same; 1.13 shows more of what is behind
them.

**On the probe: path parameters reach `_pathparams_uncached`.** On 1.12.7 the converter route's
`pathparams(lr.req)` is unresolved: the field is the `HTTP.Request` UnionAll, so the verifier
stops there (2). On 1.13 the stack shows the call resolved to
`pathparams(::Request{HTTP.BytesBody{Vector{UInt8}}})`, and the verifier walks on into
`_pathparams_uncached`. There `HTTP.getparams(req)` is `get(req.context::Dict{Symbol,Any},
:params, nothing)::Any`, so every use of the raw map is dynamic: iterating it, `unescapeuri`,
`isvalid`, `setindex!` and the error-message `string`, 36 in all. **This is a new wall on the request
path of every route with a path parameter.** It is recorded here, not fixed: it is `src/` work
for the request-path step of §4.

**What §3.6 did with these.** The path-parameter wall is cleared: `HTTP.getparams` is tested against
the router's `Params` where it is read, and the decode runs on that type. The seed's 6 errors were two walls. 2 were Nitro's: the
`Ref{Any}` read of the app context, now through a concrete type. The other 4 are inside Base:
`@with` inserts into the `ScopedValue` HAMT, whose `insert!` builds a `HashState` from a
`Leaf{AbstractScopedValue,Any}` key and calls `next` on the resulting `HashState{K}` UnionAll
(`hamt.jl:204`, `:219`). That holds for any key, so it is an upstream candidate, beside the
`ScopedValue` row of the upstream list, and nothing in Nitro works around it.

Two smaller moves on the probe: the serializer and security-header rows trade 2 errors (16 in
both versions), and the OpenSSL site outside `src/` reports its first frame as Base's
`getproperty` rather than `string`.

**The endpoint path runs on 1.13.** The trimmed probe (`unsafe-warn`) exports all 14
`nitro_route_endpoint_*` symbols, so `JLOptions().trim` was set while routes registered. Run, it
sends `GET /plaintext` through the `ccall` into the route's handler, which builds
`"Hello, World!"`, and stops at `format_response`'s `MethodError`. That is the same place as on
1.12.7, and the same binary behaviour #718 reported.

**The untrimmed app serves, and its first request no longer compiles.** `ENTRY=app`, `--trim=no`,
`JULIA_CPU_TARGET=native`, then `smoke.sh`, three runs each, `THREADS=8,1`. The machine was busy
(load ≈ 4 on 12 cores), so these are indicative, not measurements:

| `app.jl`, untrimmed | exe size | time to listen | first request | warm | RSS |
|---|---:|---:|---:|---:|---:|
| 1.12.7 exe, bundled driver | 391 MB | 0.30 s | 1.44 s | 0.3 ms | 460 MB |
| 1.13 exe, JuliaC | 350 MB | 0.24 s | 0.024 s | 0.3 ms | 276 MB |
| 1.13 JIT (`smoke.sh jit`) | – | 2.3 s | 1.43 s | 0.3 ms | 437 MB |

On 1.12.7 the image kept the JIT, and the first request paid for compiling it (§4). On 1.13 it
does not: about 60 times faster and 40% less memory. The likely cause is the closure rule above.
The per-request task body is now compiled into the image, where 1.12.7 compiled it at the first
request. That has not been checked further. The build took 183 s (indicative); with
`FILLER_ROUTES=1000` it took 235 s and made a 402 MB exe, a reference point for #726.

### 3.6 The request path Nitro owns

Built 2026-10-23 on the toolchain of §3.5 (Julia 1.13.2, JuliaC 0.3.12, gcc 13.3.0, Linux
x86-64), from `main` at `96524d3c` and the change on top of it.

| Build | `main` | path params | + app context | + error response | + format at the leaf |
|---|---:|---:|---:|---:|---:|
| `ENTRY=probe`, `unsafe-warn` | 70 | 34 | 32 | 26 | 20 |
| `ENTRY=app`, `unsafe-warn` | 96 | 96 | 92 | – | 87 |

Each step cleared its own rows and exposed nothing new. Four changes, each an `Any` on the JIT's
request path too (nitro-core §7):

- **Path parameters.** `_pathparams_uncached` decodes on a concrete `HTTP.Handlers.Params`, the
  type every writer of `:params` Nitro knows stores; a row in
  `test/http_internals_contract_tests.jl` pins that. A map of another type, which only application
  code would put there, goes to an out-of-line fallback (`_pathparams_foreign`): decoded as before
  under the JIT, refused in a trimmed image.
- **The app-context read.** `App.app_context` is declared `Ref{Any}`, an abstract type, so its
  `getindex` was dynamic. Both reads (`_app_context_seed`, `internalrequest`) assert it to
  `Base.RefValue{Any}`. Declaring the field that way, as the `Service` slots were in #571, makes
  the assertion redundant.
- **The error response.** `handlerequest` called `handle_error` on the caught exception, an `Any`.
  `_error_response` chooses by a closed set of `isa` tests over the types that have a method.
- **The serializer boundary.** Below.

**The serializer boundary: format at the leaf.** A handler may return a `Response`, a `String`, a
`Dict`, a number, and `format_response` turns it into a response, so a call on a value of unknown
type cannot disappear. It can only move to where the type is known. That is the leaf: each handler's
endpoint (`leaf_endpoint`, src/routeendpoint.jl) also carries `FormattedLeaf(handler)`, behind a
`RouteEndpoint` of its own, so in a trimmed image it is one more exported thunk pair per handler
(the probe's 14 symbols become 24). The serializer passes `Val(true)` down the terminal, which calls
that half, so the terminal returns an `HTTP.Response` whatever the route. With `serialize = false`
it calls the handler itself, and the raw value comes back as before. Route and global middleware
sit outside the serializer (`compose` → chain → `RouteNext` → serializer → terminal), so what they
receive does not change.

| Candidate | Probe after it | Why not |
|---|---:|---|
| **Format at the leaf** | **20** | chosen |
| A closed `format_response`: `isa` tests over the documented shapes, one `JSON.json(::Any)` fallback | 22 | the fallback is still a dynamic call, exactly where a route returning a `Dict` goes; under the JIT it moves the dispatch, not removes it |
| Format at the leaf even under `serialize = false` | – | breaks that flag's contract, the handler's own value |

Under the JIT the leaf makes one dynamic call per request where the serializer made two (the
handler, then `format_response`). Allocations per request through `setupmiddleware` are unchanged
for a plain, a JSON, a path-parameter and a route-middleware route (1008, 2272, 1680 and 944 bytes
on both). Throughput is pending, to be measured as §4 asks.

**How far the trimmed probe gets.** `GET /plaintext` now goes through the whole pipeline: the
endpoint's `ccall`, the formatted half, the error boundary and the security-header layer. The
response, `200` with `"Hello, World!"`, gets back to `probe.jl`'s `main`, which dies at its own
`res.status`, an `Any` there. That is the `probe.jl main` row outside `src/`.

**The next walls on the request path:**
- `middleware/security_headers.jl`, 10 on the probe and 20 on the app: what it gets from the
  inner layers is still `Any`, because `compose` returns what a route **chain** returns, and route
  middleware may return anything;
- the transport's body reads and response write on the app (18, §3.5), behind the same `Any`;
- `pathparams(::LazyRequest)` makes one dynamic call under the JIT, because `LazyRequest.req` is
  declared as the `HTTP.Request` UnionAll. The trimmed build resolves it (§3.5).

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
  first request is no faster (1.33 s against 1.28 s), because the image keeps the JIT. That was
  1.12. On 1.13 the untrimmed exe's first request is ≈ 0.02 s against the JIT's 1.4 s
  (indicative, §3.5).

The order:

0. **The harness is on Julia 1.13. Done:** `bench/juliac/build.sh` builds with JuliaC.jl by
   default, keeps 1.12's driver behind `JULIAC=bundled` until the floor moves (#526), and §3.5
   gives the backlog its 1.13 counts.
1. **§3.1, the router's type. Done (#625):** one Nitro-owned router type, and the custom
   404/405 as fixed responses on `App`. It typed every pipeline closure, but cleared no verifier
   error on its own: the fold behind it is the next wall on that path (§3).
2. **§3.2's outer fold. Done (#572).** This record put it third, behind §3.3, and called it
   blocked on the server field. The dependency runs the other way: `Service.server` is
   `HTTP.Server{F}` with `F` the pipeline's type, so the field cannot be concrete until the
   pipeline is. The fold also cleared its own errors without §3.3.
3. **§3.3, the server field, and `HTTP.listen!`'s keyword call in front of the request path.
   Done**, with the banner and `CookieKey`: `ServerHandle` holds the server behind one concrete
   type, a direct call under the JIT and a `ccall` through a static `@cfunction` in a trimmed
   build, and `serve` hands `listen!` its keywords as a `NamedTuple` (§3). The minimal app went
   from 87 to 59 on 1.13. **§3.2's route boundary is done (#718)**: one `RouteEndpoint` per route
   chain and per handler.
4. **The request path.** The audit's four (#537, #538, #546, #566) are closed. The path
   parameters, the serializer, the error response and the app-context read are typed (§3.6). What
   the verifier shows there now: the security-header layer and the transport's response write,
   both on a route chain's `Any` result, and Base's `ScopedValue` HAMT behind `@with`. Like the
   four, these need not wait for 1–3.
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
