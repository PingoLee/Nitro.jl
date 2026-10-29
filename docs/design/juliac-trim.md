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
>
> **The response is typed through the outer layers (§3.7):** `compose` holds what the global
> middleware chain returns to the contract, an `HTTP.Response`, and `SecurityHeaders` and the
> transport reach the body type through one closed dispatch. On 1.13 the probe goes from 20 to 6
> and the app from 59 to 27. The trimmed probe serves all six of its requests and exits, and the
> trimmed app answers `GET /plaintext` with `200 "Hello, World!"`; before, it answered every
> request with a `500`. The request body read is next, and it is inside HTTP.jl.
>
> **The lifecycle hooks, Revise and Nitro's own middleware (§3.4, §3.8):** each hook is a concrete
> call behind a `LifecycleEntry` ([#719](https://github.com/PingoLee/Nitro.jl/issues/719)), and a
> trimmed build refuses Revise and compiles none of it. On 1.13 the minimal app goes from 27 to 11,
> and every error left on it is in HTTP.jl or Base. The probe now also runs eight of Nitro's
> request-time middlewares, which took it from 6 to 300 on `main`; this branch brings that to 115.
> The trimmed probe serves CORS, the CSRF and cross-origin refusals, the rate limiter and the
> global middleware pipeline. What is left there is the session store's internals and the JWT
> claims.
>
> **HTTP 2.13 clears the request body read (§3.9).** The fix is upstream
> ([JuliaWeb/HTTP.jl#1512](https://github.com/JuliaWeb/HTTP.jl/issues/1512)); no Nitro code
> changed. The minimal app goes from 10 to 4, and all 6 body-read rows are gone. The trimmed app
> now answers a request with a body as the JIT does (`405`, `404`), where it answered `500`. The 4
> left are Base's `ScopedValue` HAMT and two upstream sites. The probe does not move on HTTP: it
> calls the pipeline directly. It reads 231 on a fresh resolve, but 110 of those come from
> JSON.jl 1.13.0, whose `parse` with a `dicttype` keyword no longer resolves statically; on
> JSON 1.12.2 the probe reads 121.

## 1. How to measure

```bash
julia +1.13 -e 'using Pkg; Pkg.Apps.add("JuliaC")'   # once: the `juliac` app, in ~/.julia/bin
bench/juliac/build.sh unsafe-warn        # julia +1.13 with JuliaC; log under bench/results/ (gitignored)
```

```bash
ENTRY=probe bench/juliac/build.sh unsafe-warn   # the request path, without the listener (#718)
julia bench/juliac/frames.jl bench/results/juliac-<stamp>-<entry>-<mode>.log
```

**The frontend.** Julia 1.13 ships no `juliac` driver; its frontend is the JuliaC.jl app, and
`build.sh` runs it under `julia +1.13`. Julia 1.12 shipped a `juliac.jl` driver under
`share/julia/juliac/`, which `build.sh` ran as `JULIAC=bundled` until the floor moved to 1.13
([#526](https://github.com/PingoLee/Nitro.jl/issues/526)); that switch is gone, so the 1.12.7
counts below are records, no longer reproducible with `build.sh`. Every count up to #718 below is
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
  stay comparable with those records; the count does not depend on it.

The verifier reports **the first dynamic call on each path** and does not look past it. A low
count therefore means "the first wall is close", not "nearly done". Each fix can expose code that
was never verified before. Count the errors by the first frame inside `src/` (`frames.jl` does),
not by the raw total: one line of Nitro can account for hundreds of Base frames (§2).

`app.jl` reaches the request path only through `serve` and `HTTP.listen!`. On 1.12, while any
wall stands in front of the listener, the route path is never verified at all. `probe.jl` builds
the pipeline with `setupmiddleware` and calls it on requests (an exact route, a converter route,
three middleware stacks), so the request path is measured whatever the listener does. Since §3.8
it also runs Nitro's own request-time middleware (`Cors`, `SessionMiddleware`, `CSRFMiddleware`,
`CrossOriginProtection`, `RateLimiter`, `BearerAuth`, `GuardMiddleware`, `AccessLog`) as route
middleware and, in a second pipeline, as a global `Tuple`, each request with the answer it should
get. `LIFECYCLE=1` gives `app.jl` a route-owned and a serve-owned lifecycle hook. On 1.13 the
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

## 3. Remaining (40 errors on the minimal app on Julia 1.12.7; on 1.13, 96, then 87 after §3.6, 59 after the start-up walls, 27 after §3.7, 11 after §3.8 and 4 on HTTP 2.13, §3.9)

Measured 2026-10-22 on Julia 1.12.7, before and after #572. Each error is printed twice, so 20
sites. `main` before #572 had **22**: the 20 below plus `CookieKey`'s, which arrived with a later
merge. The `1.13` column is the recount (§3.5), 2026-10-23 at `dea736f0`, with JuliaC; a
1.12.7 control at the same commit gives the After #572 column again, total 40. The `1.13, §3.6`
column is the same build after the request-path change (§3.6), the next one after the start-up
walls (below), then the response type (§3.7), and the last count column after the lifecycle
hooks and Revise (§3.4, §3.8).

| First frame in `src/` | Before #572 | After #572 | 1.13 | 1.13, §3.6 | start-up walls | §3.7 | §3.8 | What |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| `src/core/pipeline.jl` `setupmiddleware` | 4 | 0 | 0 | 0 | 0 | 0 | 0 | the fold (§3.2), **cleared** |
| `src/core/lifecycle.jl` `serve` → `_serve_listener`, `startserver` | 4 | 0 | 0 | 0 | 0 | 0 | 0 | the pipeline's type through `serve`, **cleared** |
| `src/core/lifecycle.jl` `_serve_pipeline`, the `start` closure | | 4 | 4 | 4 | 0 | 0 | 0 | `HTTP.listen!(…; kwargs...)` over the `Dict{Symbol,Any}` `startserver` passes, **cleared** (below) |
| `src/core/lifecycle.jl` `serverwelcome`, `startserver` | | 16 | 14 | 14 | 0 | 0 | 0 | the banner and the blocking wait's `println`: `Dates.format(now(), "yyyy-mm-dd HH:MM:SS")` builds a `DateFormat` from a runtime string (4 of the 16 surface inside Dates' own `io.jl`), `IO`-typed `stdout`, `join` over `VersionNumber` fields. The control counts this row 18 (2 of them at `startserver`'s wait), which is where its 40 comes from |
| `src/context.jl` `close`, `isopen`, `wait` | 6 | 8 | 8 | 8 | 0 | 0 | 0 | **the server field (§3.3)**, cleared |
| `src/context.jl` `_try_cancel`; on 1.13 also `lifecycle.jl:118` | 2 | 2 | 3 | 3 | 3 | 3 | 0 | the `revise = :eager` watcher's `invokelatest`: dev-only and dynamic on purpose, so a trimmed build refuses Revise and compiles none of it (§3.8), **cleared** |
| `src/types.jl` `startup`/`shutdown` | 2 | 4 | 4 | 4 | 4 | 4 | 0 | the lifecycle hooks (§3.4), **cleared** |
| `src/crypto.jl` `CookieKey` | 2 | 2 | 2 | 2 | 0 | 0 | 0 | `NTuple{32,UInt8}` from a `Vector` |
| `src/core/transport.jl`: the stream handler's body read (`_http_stream_request`, `_swallow_request_body!`), the response write and release | | | 18 | 18 | 18 | 6 | 6 | **new on 1.13**: the per-request task, reached past the `HTTP.listen!` wall (§3.5). §3.7 clears the response write and release; the 6 left are the body read, inside HTTP.jl |
| `src/middleware/security_headers.jl` | | | 20 | 20 | 20 | 0 | 0 | **new on 1.13**: a response typed `Any`, the same rows as on the probe (§3.2); **cleared** (§3.7) |
| `src/core/pipeline.jl` `_app_context_seed`; serializer `format_response`, `handle_error` | | | 11 | 2 | 2 | 2 | 2 | **new on 1.13**: the probe's rows of the same name (§3.2). §3.6 clears all but the seed's `@with`, which is inside Base |
| outside `src/` (OpenSSL.jl, a Base `string`, the libuv read callback; on 1.13 also Base's `errormonitor` task, `printstyled`'s closure, `showerror`, the TLS read) | 2 | 2 | 12 | 12 | 12 | 12 | 3 | upstream; the 9 §3.8 removes were reached only through the Revise watcher |

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
| `startup`/`shutdown` | `LifecycleMiddleware.on_startup`/`on_shutdown` are `Union{Function,Nothing}`-typed | **cleared**: `LifecycleEntry` (§3.4), [#719](https://github.com/PingoLee/Nitro.jl/issues/719) |
| the banner | `IO`-typed `stdout`, a runtime `DateFormat` | **cleared** (below) |
| the `revise = :eager` watcher's cancel | `Base.invokelatest` | dev-only and dynamic on purpose: **refused** in a trimmed build and compiled out of it (§3.8) |
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

### 3.4 Lifecycle hooks: cleared

`on_startup`/`on_shutdown` were `Union{Function,Nothing}`-typed (abstract), lived in a
`Vector{LifecycleMiddleware}`, and ran only at startup and shutdown: 4 errors on the minimal app,
`startup(lf)` and `shutdown(lf)` on an element of that vector. `FunctionWrapper{Nothing, Tuple{}}`,
the option this section used to name, is ruled out: FunctionWrappers.jl fails `--trim=safe`
wherever the wrapper is built (#625, §3.1).

**The constraint that shaped the design: the two halves of the registry are registered at
different times.** Route-owned entries (#82) register with their routes, at top level, which under
`juliac` is build time. Serve-owned ones register in `serve`, which in an executable runs in
`main`, at run time, where there is no `Core.eval`. Neither of the two erasure patterns already in
the tree covers both:

- `RouteEndpoint`'s exported thunk (§3.2) needs `Core.eval` at build time. It fits the route-owned
  half and cannot serve the other.
- `ServerHandle`'s static `@cfunction` (§3.3) is taken at run time, in a method specialized on the
  concrete type. It fits the serve-owned half, as long as the hook types are concrete there, and
  cannot serve an object built at build time, whose pointer an image does not keep.

**Done in [#719](https://github.com/PingoLee/Nitro.jl/issues/719): both, one per half, behind one
concrete entry.**

- `LifecycleMiddleware{M,S,D}` is parameterized on its three functions. The keyword constructor
  is unchanged, and the bare name still serves for `isa` and `LifecycleMiddleware[]`. A
  `serve(middleware = (…))` tuple holding one is concrete, which also types the global fold
  through `.middleware` (§3.8). Code that compares two of their types, or reads the registry,
  changes; `upgrading/2026-10-24-719-lifecycle-registry-entries.md` has the edits.
- The registry holds a `LifecycleEntry` per object (`src/routeendpoint.jl`): `mw`, which dedup and
  promotion compare by `===` (what `∈` on the bare middleware meant, since it defines no `==`), and
  the pointer a trimmed image calls the hooks through. `startup(e)`/`shutdown(e)` on the entry are
  a direct call under the JIT, as before, and a `ccall` in a trimmed image.
- A route-owned entry gets a thunk exported at registration for its middleware's type
  (`route_lifecycle_entry`), found with `dlsym` on first use. A serve-owned entry gets a static
  `@cfunction` taken in `register_serve_lifecycle!(ctx, ::Tuple)`, which walks the tuple member by
  member so each member's type is concrete (`serve_lifecycle_entry`).
- An exception never unwinds through the foreign frame: `_lifecycle_call` hands it back and the
  caller throws it again, so the interrupt deferral of #185 holds. Promotion (#82), the LIFO
  unwind (#74) and the lock are unchanged.
- A trimmed image refuses what it has no code for, with an error that says so: a `Vector`-form
  `serve(middleware = [...])` holding a lifecycle middleware, and route lifecycle registered after
  the image was built (#71), refused when it is registered rather than when `startserver` finds
  no code for it. A trimmed executable reports `Base.JLOptions().trim == 0` at run time with
  `_trimmed()` true (checked with a throwaway build), which is what that refusal and
  `route_lifecycle_entry` both rely on to tell building from running. Under the JIT both work as
  before.

`test/juliac_internals_contract_tests.jl` runs the trimmed branches in a child with `_trimmed()`
redefined to `true`: startup, a throwing hook, an interrupting hook, shutdown, the two refusals,
and `serve`/`terminate` end to end.

| Candidate | Why not |
|---|---|
| **A `LifecycleEntry` per object: an exported thunk for route-owned, a `@cfunction` for serve-owned** | chosen |
| `FunctionWrapper{Nothing, Tuple{}}` | fails `--trim=safe` wherever it is built (#625) |
| an exported thunk only | needs `Core.eval`, which `main` does not have, so it cannot serve `serve(middleware = …)` |
| a `@cfunction` only | its pointer is not kept in an image, so it cannot serve a route-owned object built at build time |
| a `Tuple` of hooks typed at `serve` | cannot hold route-owned entries, promotion, or registration after `serve` |
| `Core.OpaqueClosure` | the verifier rejects the call and the construction (§3.2) |

### 3.5 The recount on Julia 1.13

Built 2026-10-23 at `dea736f0` (#718 merged) with JuliaC on Julia 1.13.2, against a control with
the driver Julia 1.12.7 ships, at the same commit (§1). The control reproduces §3's and §3.2's
1.12.7 totals, 40 and 36, so every difference below comes from the toolchain, not from Nitro.

| Build | 1.12.7 | 1.13 |
|---|---:|---:|
| `ENTRY=app`, `unsafe-warn` | 40 | 96 |
| `ENTRY=probe`, `unsafe-warn` | 36 | 70 |
| `ENTRY=probe`, `safe` | – | fails on the same 70 |

Later builds on the same 1.13 toolchain: the app goes 96 → 87 (§3.6) → 59 (the start-up walls, §3)
→ 27 (§3.7) → 11 (§3.4, §3.8), and the probe 70 → 20 (§3.6) → 6 (§3.7). §3.8 extends the probe
with Nitro's own middleware, which on `main` makes it 300; after §3.8 it is 115.

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
  the assertion redundant; §3.7 does, and the assertion is gone.
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

**The next walls on the request path** (the first two are cleared in §3.7):
- `middleware/security_headers.jl`, 10 on the probe and 20 on the app: what it gets from the
  inner layers is still `Any`, because `compose` returns what a route **chain** returns, and route
  middleware may return anything;
- the transport's body reads and response write on the app (18, §3.5), behind the same `Any`;
- `pathparams(::LazyRequest)` makes one dynamic call under the JIT, because `LazyRequest.req` is
  declared as the `HTTP.Request` UnionAll. The trimmed build resolves it (§3.5).

### 3.7 The response type through the outer layers

Built 2026-10-24 on the toolchain of §3.5 (Julia 1.13.2, JuliaC 0.3.12, HTTP.jl 2.11.2, Linux
x86-64), from `main` at `71eebc5b` (the start-up walls merged) and the change on top of it.
`unsafe-warn`, counted by first frame.

| `ENTRY=probe` | `main` | after |
|---|---:|---:|
| `src/middleware/security_headers.jl` | 10 | 0 |
| `probe.jl` `main` (outside `src/`) | 4 | 0 |
| `src/core/pipeline.jl` `_app_context_seed`'s `@with` | 4 | 4 |
| outside `src/` (the libuv read callback, OpenSSL's `getproperty`) | 2 | 2 |
| **total** | **20** | **6** |

| `ENTRY=app` | `main` | after |
|---|---:|---:|
| `src/middleware/security_headers.jl` | 20 | 0 |
| `src/core/transport.jl`, the response write and release (`_with_head_content_length`, `_handoff_copy`, `_releases_slot_early`, `_write_response_body!`, `_release_response_body!`) | 12 | 0 |
| `src/core/transport.jl`, the request body read (`_http_stream_request`, `_swallow_request_body!`) | 6 | 6 |
| `src/core/pipeline.jl` `_app_context_seed`'s `@with` | 2 | 2 |
| `src/types.jl` `startup`/`shutdown` | 4 | 4 |
| `src/context.jl` `_try_cancel`, `src/core/lifecycle.jl` the `ReviseHandler`'s `invokelatest` | 3 | 3 |
| outside `src/` | 12 | 12 |
| **total** | **59** | **27** |

**Why these rows were one wall.** After §3.6 the serializer returns an `HTTP.Response`, but
everything outside it still got `Any`. `compose` returned whatever the global middleware chain
returned, and a middleware may return anything. And a known `HTTP.Response` is still not enough:
`HTTP.Response{B}` is a UnionAll over its body, and `B` varies by route (a builder's `String` or
`Vector{UInt8}`, `servecontent`'s `BytesBody`, a streamed file, an SSE stream). So every call
that reads the body or rebuilds the response, `add_response_headers` included since it keeps
`B`, dispatched on `B` at run time. Each of those is also an `Any` on the JIT's request path
(nitro-core §7).

Three changes, plus the app-context field §3.6 left:

- **The contract boundary.** `compose` returns `ResponseBoundary(chain)` (src/routerhof.jl). Its
  call returns `chain(req)` if that is an `HTTP.Response`. Otherwise it answers: whatever a
  handler returns once it has written on the stream (a `STREAM` or WebSocket route under
  `serialize = false`) becomes a placeholder `200`, which the transport never writes. Anything else
  is a `500`, logged with the value's type and the route pattern, never the value (#613). The whole
  pipeline `setupmiddleware` builds now infers `HTTP.Response`, for both values of `serialize`.
- **The body dispatch.** `Types.with_response(f, resp, args...)` (src/routeendpoint.jl) is a
  closed set of `isa` tests over the bodies Nitro's builders produce. Each branch calls `f` on a
  concrete `HTTP.Response{B}`. The fallback, `_with_unlisted_body`, is an out-of-line dynamic call
  under the JIT, which is what every response cost before, and a refusal in a trimmed image.
  `args` is `Vararg{Any,N}`, not a bare `args...`: Julia does not specialize a vararg tail it only
  passes on, and the splat into `f` was then 7 `_apply_iterate` rows.
- **`SecurityHeaders`** returns a value that is not a response untouched (a router's own
  `SecurityHeaders()` can see a raw value under `serialize = false`, inside the boundary). It runs
  its header scan and rebuild in `_with_security_headers`, reached through `with_response`. It
  still builds a new response and never mutates the inner one (nitro-core §4).
- **The transport.** The write half of `stream_handler` moved verbatim into `_send_response!`,
  reached through `with_response`, or with `nothing` when the pipeline's value is not a
  response. Everything nitro-core §4 and #453/#298 rely on is unchanged and stays on the
  request's task: the `HEAD` length, the hand-off copy (#654), the no-drain guard (`_allows_body`),
  the slot release before a long write, the non-consuming write, `closewrite`, and the release in
  `finally`.
- **`App.app_context`** is declared `Base.RefValue{Any}`, so §3.6's assertion is gone.

**The body types.** All 16 builder shapes (`Res.send`, `json` over a value and over bytes, `html`,
`status`, `redirect`, `file` with and without a request, ranged and streamed, `sse`,
`format_response`, `HTTP.Response(404)`) land in 7 listed types. A test in
`test/response_type_tests.jl` checks that, plus the method counts of `_write_response_body!` and
`_release_response_body!`, so a new body type fails there first:

| Body `B` | Built by |
|---|---|
| `String` | `Res.send`, `Res.html`, `Res.json`, `Res.status`, `Res.redirect`, `format_response` |
| `Vector{UInt8}` | `Res.send`/`Res.json` over bytes, `Res.file(path)` |
| `HTTP.EmptyBody` | `HTTP.Response(status)`, the default `404`/`405` |
| `HTTP.BytesBody{Vector{UInt8}}` | `Res.file(req, path)` |
| `HTTP.BytesBody{SubArray{…}}` | `Res.file(req, path)` answering a `Range` request (`206`) |
| `HTTP._SeekableResponseBody{IOStream}` | `Res.file(req, path; stream = true)`, a file over 8 MiB, a mount's file over its threshold. A private HTTP.jl type, canaried in `test/http_internals_contract_tests.jl` |
| `HTTP.SSEStream` | `Res.sse` |

**Where the boundary sits, and the candidates measured.**

| Candidate | Probe | App | Why |
|---|---:|---:|---|
| (b) the body dispatch only, no contract | 10 | 27 | clears every row above but `probe.jl main`'s 4. It changes no behaviour, so the silent empty `200` and the crashes below stay |
| **(a′) the dispatch, and the boundary at the global chain's output** | **6** | **27** | **chosen** |
| (a) a boundary on the route chain's call too | – | – | not built. It breaks `serialize = false` with a global middleware that formats raw values (`test/original_tests.jl`), and a `STREAM` handler's `nothing` |

What a non-response did before the boundary, measured through `serve` and `internalrequest` on
`main`: under the access log or `SecurityHeaders`, a `500` with an empty body ("Request failed
outside the error handler"); with neither, an empty `200`; through `internalrequest`, a
`MethodError`. A `serialize = false` `STREAM` route under the access log (on by default) made the
client lose the connection mid-response. So no configuration delivered the value. The empty `200`
is the one answer an app could rely on (a status-only health check, a `HEAD` route), and it
becomes a `500`. That is the behaviour change, with its entry under `upgrading/`.

**Allocations per request**, in bytes, through `setupmiddleware` and through `internalrequest`, at
`-O2` (the `-O0` figures, which CI runs, are equal between the two trees too):

| Route | `main` | after |
|---|---:|---:|
| plaintext | 944 / 2720 | 944 / 2720 |
| JSON | 1792 / 3568 | 1792 / 3568 |
| path parameter | 1616 / 3392 | 1616 / 3392 |
| route middleware | 944 / 2768 | 944 / 2768 |
| `security_headers` on | 1248 / 3168 | 1232 / 3152 |
| streamed `Res.file` | 4624 / 6400 | 4624 / 6400 |
| SSE | 1744 / 3520 | 1744 / 3520 |

Throughput is pending, to be measured as §4 asks.

**How far the trimmed builds get.** The trimmed probe now serves all six of its requests
(`/plaintext`, a path parameter, a route with two middleware, two routes of an `include_routes` group, a miss) and exits `0`.
The trimmed app answers `GET /plaintext` with `200 "Hello, World!"`, as many times as asked, and a
miss with `404`. On `main` the same build answered every request with a `500`. A request with a
body still gets a `500`: that is the next wall. (On HTTP 2.13 it answers as the JIT does, §3.9.)

**The next walls:**
- **The request body read**, 6 on the app. **Cleared upstream** on HTTP 2.13 (§3.9). Every server stream is already concrete,
  `Stream{false, Request{EmptyBody}}`. The rows are inside HTTP.jl: `_stream_request_body_read!`
  calls `body_read!` on `Stream.request_body::AbstractBody`, which it narrows only to the UnionAlls
  `FixedLengthBody{I}`, `ChunkedBody{I}` and `EOFBody{I}`. Nitro could only work around it by
  reimplementing `readbytes!`, including `_maybe_write_continue!` (#17). Reported upstream as
  [JuliaWeb/HTTP.jl#1512](https://github.com/JuliaWeb/HTTP.jl/issues/1512).
- `_app_context_seed`'s `@with`, inside Base's `ScopedValue` HAMT (§3.5).
- The lifecycle hooks (§3.4, [#719](https://github.com/PingoLee/Nitro.jl/issues/719)), and the
  `revise = :eager` watcher, dynamic on purpose. **Both cleared** (§3.4, §3.8).
- Header-adding middleware a user places inside the chain (`Cors`, the session and CSRF layers,
  the rate limiter) still receives `Any` from the layer below it. The minimal app installs none
  of them. **Cleared**, with the walls behind it the extended probe found (§3.8).

### 3.8 Revise, and Nitro's own middleware

Built 2026-10-24 on the toolchain of §3.7 (Julia 1.13.2, JuliaC 0.3.12, HTTP.jl 2.11.2, Linux
x86-64), from `main` at `644c7f59` (§3.7 merged) and the change on top of it. `unsafe-warn`,
counted by first frame.

**Revise in a trimmed build.** `revise = :lazy` and `:eager` reach the revised world through
`invokelatest`, dynamic on purpose, and their branches were compiled into every build. `serve` now
refuses `revise != :none` when `_trimmed()`, before anything starts, and every Revise branch (the
`ReviseHandler` layer, starting and closing the eager watcher, `_try_cancel`) sits behind the same
switch, so a trimmed image compiles none of it. That cleared the watcher's 3 errors and 9 of the 12
outside `src/` on the app (Base's `errormonitor` task, `printstyled`'s closure, `showerror`),
which only the watcher reached. Under the JIT nothing changes.

| `ENTRY=app` | `main` | after |
|---|---:|---:|
| `src/types.jl` `startup`/`shutdown` (the lifecycle hooks, §3.4) | 4 | 0 |
| `src/context.jl` `_try_cancel`, `src/core/lifecycle.jl` the `ReviseHandler`'s `invokelatest` | 3 | 0 |
| `src/core/transport.jl`, the request body read | 6 | 6 |
| `src/core/pipeline.jl` `_app_context_seed`'s `@with` | 2 | 2 |
| outside `src/` | 12 | 3 |
| **total** | **27** | **11** |

The 11 left are the request body read inside HTTP.jl
([JuliaWeb/HTTP.jl#1512](https://github.com/JuliaWeb/HTTP.jl/issues/1512), §3.7), Base's
`ScopedValue` HAMT (§3.5), and three upstream sites: OpenSSL's `getproperty`, the libuv read
callback, the TLS read. `LIFECYCLE=1` (one route-owned and one serve-owned hook) counts the same
11, and the trimmed app runs both hooks through their pointers.

**The probe, extended.** `probe.jl` now also runs `Cors`, `SessionMiddleware` on a `MemoryStore`,
`CSRFMiddleware`, `CrossOriginProtection`, a fixed-window `RateLimiter`, `BearerAuth` over
`jwt_validator`, a `GuardMiddleware` and `AccessLog`. Each runs as route middleware and, in a
second pipeline, as a global `Tuple`, and every one of its 22 new requests has the answer it
should get. On `main` that took the probe from 6 errors to 300. The walls, and what cleared each:

| First frame in `src/` | `main` | after | What it was, and the change |
|---|---:|---:|---|
| `middleware/csrf_middleware.jl` | 96 | 0 | the inner layer's `Any` result (16), the parsed body read for the token through `AbstractDict` tests (62), the session and its id read from `req.context` (18). The response is checked, the cookie goes on the owned headers and the rebuild alone goes through `with_response`; the token is read from the parsers' concrete `Dict{String,String}` and `JSON.Object{String,Any}`; the session through `with_session` |
| `middleware/session_middleware.jl` | 46 | 12 | the inner layer's result (12) and the session read back from `req.context` (22), as for CSRF. Left: the auth-marker compare and the dirty check over `Dict{String,Any}` values, and `deepcopy` (follow-up) |
| `middleware/rate_limiter.jl` | 40 | 0 | the inner layer's result (8), and `b[2] + window + Millisecond(1)`, which Dates evaluates through a `CompoundPeriod` (32): two additions now |
| `middleware/extract_ip.jl` | 8 | 0 | `getip(req)` is `Any`; tested against IPv4 and IPv6 first |
| `middleware/cors_middleware.jl` | 4 | 0 | the inner layer's result |
| `core/pipeline.jl` | 8 | 4 | the global fold over a `LifecycleMiddleware` (`.middleware::Function`, §3.4) and the rate limiter's `reduce(|>, [ … ])` composition; left: the `@with` HAMT |
| `middleware/guards.jl` | 16 | 10 | the session read (6 cleared); left: JWT claim values compared as `Any` (follow-up) |
| `cookies.jl` | 16 | 16 | `set_cookie!`'s `Dict{Symbol,Any}` attributes (follow-up). Once, not once per body type: the cookie is written on `HTTP.Headers` |
| `Auth/` (`validators.jl`, `jwt.jl`, `claims.jl`), `middleware/auth_middleware.jl`, `utilities/misc.jl` | 50 | 50 | JWT claims as `Dict{String,Any}` values, `unauthorized::Function`, the validator's arity check by reflection (follow-up) |
| `types.jl` | 9 | 9 | LRUCache.jl's untyped `by` and `finalizer` fields, under `MemoryStore` (upstream) |
| `utilities/bodyparsers.jl` | 2 | 2 | `JSON.parse` of an `Any` target, inside JSON.jl |
| outside `src/` | 5 | 12 | Base's logging and `showerror` writing to `stderr`, newly reached through the typed global pipeline; the libuv read callback; OpenSSL |
| **total** | **300** | **115** | |

Three things the extended probe taught that hold beyond it:

- **An abstract `HTTP.Response` argument is a wall, even with one matching method.** The verifier
  rejects `f(resp::HTTP.Response)` when `resp`'s type is the UnionAll. So after the response is
  checked, everything that touches only headers works on `HTTP.Headers` (one concrete type
  whatever the body), and the rebuild, the one step that needs the body's type, is the only call
  through `with_response`. Taking the whole tail through `with_response` instead compiles it
  once per listed body: seven copies of `set_cookie!` per site, and its own walls seven times.
- **`req.context` is a `Dict{Symbol,Any}`, so every value read from it needs a closed dispatch**:
  `with_session` for the session (a supported Symbol-keyed session keeps the JIT's dynamic call
  and is refused in a trimmed image), concrete types for the session id and the client address.
  Asserting them instead puts the value in a `TypeError`, which for a session is #612's leak;
  `_stored_session` and `_stored_session_id` raise a value-free `SessionStoreFault`.
- **A `::Function` return annotation, or a `reduce` over a `Vector{Function}`, erases a chain's
  type for every layer around it.** The rate limiter's composition did both, so every global
  middleware folded around a `RateLimiter` was abstract.

**What the trimmed probe serves now:** the six original requests; CORS (a preflight and a simple
request); the CSRF and cross-origin refusals; the session read back through its cookie; the rate
limiter's burst (`200`, `200`, `429`); and the global pipeline's `GET /plaintext` and preflight.
Five answer wrongly, all behind the follow-ups: a session write (`500`), the global session read
(`500`), and the three bearer-token requests (`401`, the JWT claims).

**What it asks of an application under `serialize = false`.** A raw handler value reaching
`SecurityHeaders`, `Cors` or `RateLimiter` passes through without their headers; reaching
`SessionMiddleware` or `CSRFMiddleware` while their cookie is due, it raises (a `500`, as the
`MethodError` on `main` was). Both are in the upgrade entry #741 opened.

**Allocations per request**, in bytes, through `setupmiddleware` / through `internalrequest`, at
`-O2`, `main` against the branch:

| Route | `main` | after |
|---|---:|---:|
| plaintext | 496 / 1888 | 496 / 1888 |
| `Cors` | 800 / 2240 | 800 / 2240 |
| `SessionMiddleware`, a new session written | 2800 / 4240 | 2656 / 4096 |
| `SessionMiddleware` + `CSRFMiddleware`, `GET` | 1856 / 3296 | 1856 / 3296 |
| `RateLimiter` | 1120 / 2560 | 1056 / 2496 |
| global `Tuple` (`Cors`, `SessionMiddleware`, `RateLimiter`) | 1568 | 1504 |

Throughput is pending, to be measured as §4 asks.

**A fatal error in a compiled executable prints secrets (#749, #750).** An exception that escapes
`main` in a juliac executable is printed by the runtime (`fatal: error thrown and no exception
handler available.`), which walks raw fields and never calls Nitro's secret-safe `show` methods
(#307). The extended probe, crashing in `setupmiddleware` before this change, printed its CSRF
secret and its JWT keyset in clear to `stderr`. In a served app the request path catches what a
handler throws. A failure at start-up, in `serve` or in the app's own boot, printed whatever its
arguments reached. Two parts now cover it:

- **`serve` rethrows a value-free exception in a juliac executable.** Both public `serve` forms
  catch at their outermost frame (`_rethrow_value_free`, `src/methods.jl`) and, when `_trimmed()`
  or `_juliac_executable()` (#752, below), `rethrow` a `LoggedException` built by
  `Errors._value_free`. It keeps the type's name, the
  message of an `ArgumentError` or an `ErrorException`, the address of an
  `HTTP.AddressInUseError` (a failed bind), and nothing else. It never calls
  `showerror`, which the image cannot dispatch for an arbitrary exception. `rethrow(x)` keeps the
  original backtrace. Interrupts, and everything under the JIT, pass through unchanged. Both
  helpers take `@nospecialize` arguments: without that, the call on the caught `e::Any` is itself
  a dynamic dispatch, and in the trimmed image it failed with a `MethodError` that printed the
  original exception as its argument.
- **The app's `@main` catches what runs before `serve`**, printing
  `Nitro.startup_failure_text(e)` on `Core.stderr` (#752; it printed `nameof(typeof(e))` before).
  That is the recipe in `docs/src/tutorial/deployment.md`.

`bench/juliac/fatal.jl` fails on purpose with a CSRF secret, a JWT secret and a closure-captured
key in reach, and `bench/juliac/fatal_check.sh` greps its `stderr` for them (Julia 1.13.2, JuliaC
0.3.12, Linux x86-64):

| `FAIL=` | `--trim=unsafe-warn`, `main` | `--trim=unsafe-warn`, after | `--trim=no`, after |
|---|---|---|---|
| `serve` (inside `serve`) | all three leak | `LoggedException(type=:MethodError, …)`, nothing leaks | all three leak |
| `boot` (before `serve`, under the recipe) | `start-up failed: StartupFailed` | the same | the same |
| `bare` (before `serve`, no recipe) | all three leak | all three leak | all three leak |

The `--trim=no` column answers #744's printing question: an untrimmed executable uses the same
static printer, but `_trimmed()` stays `false` there, so `serve` could not tell it from the JIT
(#752). The same held for a trimmed image that registers no route at top level, since
`_trimmed()` flips only when the build exports one (`_flip_trimmed!`). `bare` is the limit no
change in Nitro can reach: the failure never enters Nitro's frames. The verifier counts do not
move: the minimal app is 10 errors on `main` and after (this toolchain counts 10 where the count
above read 11), and `ENTRY=fatal` is 63 on both.

**The signal for "a juliac executable" (#752).** `serve` needs one fact at the moment it fails, at
run time: is this process a juliac executable, trimmed or not? It must be false under the JIT, in
`Pkg.precompile`, and in a PackageCompiler sysimage. The candidates, measured with a probe package
that prints each fact (Julia 1.13.2, JuliaC 0.3.12, PackageCompiler 2.4.5, Linux x86-64):

| candidate | JIT | `Pkg.precompile` | JuliaC build | JuliaC exe, run | PackageCompiler build | `julia -J` run |
|---|---|---|---|---|---|---|
| `generating_output(false)` | false | false | **true** | false | `precompile_execution_file`: false; `script`: **true** | false |
| `JLOptions().trim` | 0 | 0 | 0 / 3 | **0** in both | 0 | 0 |
| `JLOptions().image_file_specified` | 0 | 1 | 1 | 0 | 1 | 1 |
| `JLOptions().julia_bin` basename | `julia` | `julia` | `julia` | the exe's name | `julia` | `julia` |
| a flag set in `__init__` | — | `Core.eval` there is an `ErrorException` | **never runs** | — | — | — |
| a flag set by a call at the app's top level | false | false | set | **true** | `script`: set | **true** |
| `isdefined(Main, :_main)` | false | false | true | **true** in both | false | false |

- **`__init__` cannot set a build-time flag.** A non-incremental build (`--output-incremental=no`,
  which JuliaC passes) defers a loaded package's `__init__` to the image's start-up. Nothing runs
  it while the image is built.
- **A flag set by a Nitro call at the app's top level** (`App()`, `urlpatterns`) is frozen into
  the image, trimmed or not, but it is not exact. PackageCompiler's `script` keyword runs a file in
  the `--output-o` process, where `generating_output(false)` is true as well. A sysimage built
  that way kept the flag, and `julia -J` read it. It also misses an app that builds its `App`
  inside `main`.
- **`trim`, `image_file_specified` and `julia_bin`** do not tell an executable from a JIT session.
  `trim` is 0 at run time even in a trimmed executable. `image_file_specified` is 0 under a plain
  `julia` too. `julia_bin` is whatever the file is named.
- **`isdefined(Main, :_main)` is exact for the drivers that exist.** JuliaC's build script and the
  one Julia 1.12 bundles both define `Main._main(argc, argv)`, the C entry point that calls the
  app's `main` (with no exception handler, which is why the runtime's fatal printer gets the
  exception). Nothing else defines it unless an application names a global `_main` itself, which
  the deployment docs warn against. It is read at run time, in `Nitro._juliac_executable()`, and
  costs one binding lookup on a path that is already failing. It is trim-safe. Its weak point: if
  JuliaC renames `_main`, it reads `false` and the untrimmed executable leaks again. CI has no
  JuliaC, so `fatal_check.sh` on a `--trim=no` build is what catches that. `_trimmed()` stays in
  the gate, so a trimmed image that registered a route is covered either way.

After the change (`bench/juliac/fatal_check.sh`):

| `FAIL=` | `--trim=no` | `--trim=unsafe-warn` | `--trim=unsafe-warn`, no route (`FATAL_ROUTES=0`) |
|---|---|---|---|
| `serve` | `LoggedException(type=:StartupFailed, …)`, nothing leaks | `LoggedException(type=:MethodError, …)`, nothing leaks | the same, nothing leaks |
| `boot` (recipe) | `start-up failed: StartupFailed …` | the same | the same |
| `wrapped` (recipe) | `start-up failed: StartupFailed …` | `start-up failed: MethodError …` | the same |
| `bare` (no recipe) | all three leak | all three leak | all three leak |

Before it, `serve` leaked all three in the `--trim=no` and the no-route builds. The verifier counts
do not move: the minimal app 10, `ENTRY=fatal` 63, the no-route build 113.

Under the JIT the same probe found that `jwt_validator` captures a string secret as a plain
`String`, so Base's default display of an exception holding the chain prints the JWT secret, while
the CSRF one prints masked. That is #751.

**The next walls:**
- The session store's internals: the auth-marker compare and the dirty check over the session's
  `Any` values, `deepcopy`, `set_cookie!`'s attribute `Dict`, and LRUCache.jl's untyped fields.
  `SessionMiddleware` cannot answer a request in a trimmed image until they are cleared.
- Auth: JWT claims read as `Any` (`_principal`, `_claim_int`, `_warn_iss`, the guards' claim
  compare), `unauthorized::Function`, and the validator's arity check by reflection. The claims
  want the same closed dispatch over JSON values that the session's values do.
- The `@with` HAMT (unchanged). The request body read inside HTTP.jl is cleared on HTTP 2.13
  (§3.9).
- **New since this count:** JSON.jl 1.13.0's `parse` with a `dicttype` keyword, which the JWT
  claims read passes. On the probe it is 106 rows at `_parse_json_bounded`, plus 4 inside
  StructUtils.jl (§3.9).

### 3.9 The recount on HTTP 2.13

Built 2026-10-29 with Julia 1.13.2 and JuliaC 0.3.12 on Linux x86-64, `unsafe-warn`, counted by
first frame, from two trees:
- `main` before #778 (`71b3fd1f`), on HTTP.jl 2.11.2;
- `main` after it (`050d7782`), on HTTP.jl 2.13.1.

Both use Reseau 1.6.3 and JSON.jl 1.13.0 (each tree's bench environment resolved fresh). No
Nitro code on these paths changed between the two trees
([#779](https://github.com/PingoLee/Nitro.jl/issues/779)).

| `ENTRY=app` | HTTP 2.11.2 | HTTP 2.13.1 |
|---|---:|---:|
| `src/core/transport.jl` `_http_stream_request` (the body read) | 3 | 0 |
| `src/core/transport.jl` `_swallow_request_body!` | 3 | 0 |
| `src/core/pipeline.jl` `_app_context_seed`'s `@with` | 2 | 2 |
| outside `src/`: the libuv read callback (`uv_readcb`), OpenSSL's `getproperty` | 2 | 2 |
| **total** | **10** | **4** |

All six body-read rows are gone; none survived. The 4 left are Base's `ScopedValue` HAMT (§3.5)
and two upstream sites.

**What the trimmed app serves.** It answered every request the same way in both trees, except
the ones with a body:

| request | HTTP 2.11.2 | HTTP 2.13.1 |
|---|---|---|
| `GET /plaintext`, before and after the rest | `200 "Hello, World!"` | the same |
| `GET` of a miss | `404` | the same |
| `POST /plaintext`, a JSON body | `500` | `405`, as under the JIT |
| `POST` of a miss, a JSON body | `500` | `404` |
| `POST /plaintext`, a chunked body | `500` | `405` |

`app.jl` has no route that binds a body (`Json{T}`). These bodies are read by the transport,
which reads every request's body before routing, and that read was the wall.

**The probe does not move on HTTP.** It calls the pipeline directly, so the transport's body read
was never on its path. It reads **231 in both trees, row for row**, and answers its 22 requests
identically. The 5 wrong answers are §3.8's, all behind #747 and #748:
- a session write (`500`) and the global session read (`500`);
- the three bearer-token requests (`401`).

None of its `POST`s carries a body.

**JSON.jl 1.13.0 is a new wall on the probe.** Built again with JSON.jl pinned at 1.12.2, the
version this record's earlier counts were built with, the after tree's probe reads **121**:

| rows that move | JSON 1.13.0 | JSON 1.12.2 |
|---|---:|---:|
| `src/utilities/bodyparsers.jl` `_parse_json_bounded` | 108 | 2 |
| outside `src/`: StructUtils.jl | 4 | 0 |
| outside `src/`: `show.jl` `gettypeinfos` | 1 | 0 |
| outside `src/`: `util.jl` `with_output_color` | 1 | 2 |
| **probe total** | **231** | **121** |

- **The call.** It is the JWT claims read's `_parse_json_bounded(…; dicttype = Dict{String, Any})`
  (`src/Auth/jwt.jl`). The keyword's value travels as a `DataType`, and JSON.jl 1.13.0's `parse`
  dispatches on it at run time.
- **Who clears it.** Nitro can avoid it by passing the dict type in a form the compiler sees as a
  constant, or JSON.jl can resolve it. It is not chosen here.
- **The other 6 rows.** 121 is 6 more than §3.8's 115: 4 at `csrf_middleware.jl`
  `_foreign_binding` (the trimmed image's refusal of a non-`String` session id) and 2 more
  outside `src/`. Neither is root-caused here.

**The fatal check (#749, #752) still passes on HTTP 2.13.** On the after tree, `fatal_check.sh`
gives the table at the end of §3.8, mode for mode, for all three builds:
- `--trim=no`;
- `--trim=unsafe-warn`;
- `--trim=unsafe-warn` with no route.

Only `bare` leaks. The verifier counts are 59 errors with 2 warnings (`ENTRY=fatal`) and 107 with
4 (no route), against §3.8's 63 and 113. No before-tree build was made, so those two moves are
not split by first frame.

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

0. **The harness is on Julia 1.13. Done:** `bench/juliac/build.sh` builds with JuliaC.jl, the
   1.12 driver left with the 1.12 floor (#526), and §3.5 gives the backlog its 1.13 counts.
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
5. **§3.4, the lifecycle hooks ([#719](https://github.com/PingoLee/Nitro.jl/issues/719)). Done:**
   a `LifecycleEntry` per registered object, through an exported thunk or a `@cfunction`. With it,
   a trimmed build refuses Revise and compiles none of it, and Nitro's own request-time middleware
   reaches the response and the request context at concrete types (§3.8). The minimal app went
   from 27 to 11 on 1.13; what is left on it is outside Nitro.
6. **Outside Nitro.** HTTP.jl's request body read: **cleared** on HTTP 2.13 (§3.9). OpenSSL.jl
   and the libuv read callback: reported upstream. With those gone, the last row on the minimal
   app with a frame in `src/` is Base's `ScopedValue` HAMT, behind `_app_context_seed`'s `@with`
   (§3.5).
7. **The extended probe's walls, largest first** (§3.9):
   - JSON.jl 1.13.0's `parse` with a `dicttype` keyword, 110 rows;
   - Auth's claims, 60 with the guards' claim compare ([#747](https://github.com/PingoLee/Nitro.jl/issues/747));
   - the session store's internals, 37 with `set_cookie!` and LRUCache.jl
     ([#748](https://github.com/PingoLee/Nitro.jl/issues/748)).

Two rules come with the target:

- **The JIT build is the one users run today, so it must not pay for the target.** A change made
  for `--trim` that costs the JIT request path more than the noise, such as a `FunctionWrapper`
  trampoline per request where a function barrier would do (§3.2), has to justify that cost with
  a measurement (`bench/socket/run.sh`, interleaved with `main`).
- **Every wall cleared is re-measured with `bench/juliac/build.sh unsafe-warn`, counted by first
  frame in `src/`**, so this record's §3 stays the live backlog. Once the minimal app passes
  `--trim=safe`, the trimmed exe's first request, resident memory and throughput against the JIT
  are the numbers that say whether the target paid off.
