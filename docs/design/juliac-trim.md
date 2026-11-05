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
> calls the pipeline directly. It read 231 on a fresh resolve while JSON.jl 1.13.0–1.13.3 were
> current, 110 of them from [JuliaIO/JSON.jl#543](https://github.com/JuliaIO/JSON.jl/pull/543),
> under which a typed parse with a custom read style no longer verified: Nitro's is
> `_parseparam_fallback`'s `JSON.parse(str, Int64; style = NITRO_READ_STYLE)`, the JSON
> fall-through of a scalar parameter. **Cleared upstream in JSON.jl 1.13.4** (reported as
> [JuliaIO/JSON.jl#553](https://github.com/JuliaIO/JSON.jl/issues/553), fixed by #555, released
> 2026-10-30): re-measured on 2026-11-02 the probe reads 121 on 1.13.4, row for row what it reads
> on 1.12.2 ([#801](https://github.com/PingoLee/Nitro.jl/issues/801#issuecomment-6567855388)).
> Nitro floors `JSON` at 1.13.4 so the count no longer depends on the resolve date; no Nitro code
> changed.

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

## 3. Remaining (40 errors on the minimal app on Julia 1.12.7; on 1.13, 96, then 87 after §3.6, 59 after the start-up walls, 27 after §3.7, 11 after §3.8 and 4 on HTTP 2.13, §3.9, then 8 since #840, §3.13; the probe 22 after §3.11, 18 after #851; on 1.14, the app 5 and the probe 20, §3.12, then 3 and 18, §3.13; on 1.14 alpha2, 2 and 18, then 2 and 14 with no row in `src/`, §3.14)

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
  valid, but a `Vector` of mixed closures is folded dynamically, and the pipeline's type (with the
  listener built around it) is then left to runtime. A `LifecycleMiddleware` member no longer
  breaks the `Tuple` form: since [#719](https://github.com/PingoLee/Nitro.jl/issues/719) it is
  parameterized on its functions' types, so a tuple holding one is concrete (§3.4).

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

- `LifecycleMiddleware{M,S,D}` was parameterized on its three functions. The keyword constructor
  is unchanged, and the bare name still serves for `isa` and `LifecycleMiddleware[]`. A
  `serve(middleware = (…))` tuple holding one is concrete, which also types the global fold
  through `.middleware` (§3.8). Code that compares two of their types, or reads the registry,
  changes; `upgrading/2026-10-24-719-lifecycle-registry-entries.md` has the edits.
  [#161](https://github.com/PingoLee/Nitro.jl/issues/161) added a fourth, the post-drain
  `on_stopped` (`LifecycleMiddleware{M,S,D,P}`); its hook goes through the same pointers, as
  phase code `2` in the `Cint` that was the `up` flag.
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
  declared as the `HTTP.Request` UnionAll. The trimmed build resolves it (§3.5). §3.14 types the
  field.

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
- ~~The session store's internals: the auth-marker compare and the dirty check over the session's
  `Any` values, `deepcopy`, `set_cookie!`'s attribute `Dict`, and LRUCache.jl's untyped fields.~~
  **Cleared** (§3.11, #748 and #850): `SessionMiddleware` answers in a trimmed image.
- Auth: JWT claims read as `Any` (`_principal`, `_claim_int`, `_warn_iss`, the guards' claim
  compare), `unauthorized::Function`, and the validator's arity check by reflection. The claims
  want the same closed dispatch over JSON values that the session's values do.
- The `@with` HAMT (unchanged). The request body read inside HTTP.jl is cleared on HTTP 2.13
  (§3.9).
- **New since this count, and cleared since:** JSON.jl 1.13.0 (JuliaIO/JSON.jl#543), under which
  a typed parse with a custom `StructStyle` was no longer trim-verifiable. Nitro's is
  `_parseparam_fallback`'s `_parse_json_bounded(str, T; style = NITRO_READ_STYLE)`
  (`src/utilities/misc.jl`), reached from every scalar path or query parameter. On the probe it
  was 106 rows at `_parse_json_bounded`, plus 4 inside StructUtils.jl (§3.9). **JSON.jl 1.13.4
  fixed it** (JuliaIO/JSON.jl#553 / #555), and Nitro floors `JSON` there. The JWT claims read's
  `dicttype` keyword is a separate, version-independent 2-row wall (§3.9, #747).

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

- **The call.** Not the JWT claims read, as this section first said. The hermetic repro on
  [#801](https://github.com/PingoLee/Nitro.jl/issues/801#issuecomment-6512246547) (2026-10-30)
  traced the 110 rows to `_parseparam_fallback`'s
  `_parse_json_bounded(str, T; style = BodyParsers.NITRO_READ_STYLE)` (`src/utilities/misc.jl`),
  the JSON fall-through of a scalar parameter parse, with `T = Int64` on the probe. A 12-line
  script with only `JSON.parse("42", Int64; style = MyStyle())` reads 0 rows on JSON 1.12.2 and
  116 on 1.13.0, bisected to JuliaIO/JSON.jl#543: an object or array met under a non-default
  style now goes through `StructUtils.make(style, Any, x)`, whose recursion infers `Any` (26 rows)
  and whose `cannot parse` message interpolates a `LazyValue` (90 rows). The rows are real at run
  time: on `[1]` the trimmed 1.13.0 image fails with a different `MethodError` from the JIT's.
- **Who cleared it: upstream.** Reported as [JuliaIO/JSON.jl#553](https://github.com/JuliaIO/JSON.jl/issues/553),
  fixed by #555 ("Let typed parses with a custom read style compile under juliac --trim"),
  released in JSON.jl 1.13.4 on 2026-10-30. Re-measured on 2026-11-02 on `main` at `702ad510`
  (Julia 1.13.2, JuliaC 0.3.12, three bench environments with JSON pinned exactly, everything
  else resolving the same): 1.13.0 still reads 231, with the same 108 + 4 + 1 + 1 rows as this
  table; 1.13.4 reads **121**, and `frames.jl`'s output is identical to 1.12.2's
  ([#801](https://github.com/PingoLee/Nitro.jl/issues/801#issuecomment-6567855388)). The three
  images behave the same (the probe sends no parameter that reaches the parse, so this shows the
  fix changes nothing at run time; it does not exercise the fixed path). Nitro's `[compat]` floor
  moved from `JSON = "1.12.1"` to `"1.13.4"`, so a fresh resolve cannot land on 1.13.0–1.13.3; no
  Nitro code changed, and the Nitro-side dispatch once proposed on #801 (a number target under
  the default style) is not needed.
- **The `dicttype` keyword** of the JWT claims read is the 2 rows that stay on both versions: a
  type passed as a keyword reaches `parse`'s body as a `DataType`, and the trimmed image dies at
  that call with a `MethodError`. JSON.jl cannot resolve it from inside `parse`; typing the claims
  (#747) removes the call.
- **The other 6 rows.** 121 is 6 more than §3.8's 115: 4 at `csrf_middleware.jl`
  `_foreign_binding` (the trimmed image's refusal of a non-`String` session id) and 2 more
  outside `src/`. Neither is root-caused here; §3.11 finds the cause of the 4 and clears them
  (#851).

**The fatal check (#749, #752) still passes on HTTP 2.13.** On the after tree, `fatal_check.sh`
gives the table at the end of §3.8, mode for mode, for all three builds:
- `--trim=no`;
- `--trim=unsafe-warn`;
- `--trim=unsafe-warn` with no route.

Only `bare` leaks. The verifier counts are 59 errors with 2 warnings (`ENTRY=fatal`) and 107 with
4 (no route), against §3.8's 63 and 113. No before-tree build was made, so those two moves are
not split by first frame.

### 3.10 The `serve` call from the app: cleared in #845

This one is not a verifier error, and it showed up in the untrimmed build too: JuliaC compiles
into the image what `main` reaches statically, and the realapp's `serve(app; middleware = …)` was
a dynamic `Core.kwcall`. `worker_startup(app; store = …)` returned a `LifecycleMiddleware` whose
`on_startup` closure captured a `WorkerRuntime{S}` with `S` open, because `_start_runtime_for!`
narrowed the runtime it read from the `Any` extension slot only to the UnionAll. So neither the
`serve` specialization nor HTTP's `_serve_listener!` closure was in the image, and every first
request paid for compiling them.

#845 gives the `store` form its own method, which reuses an installed runtime only when it is a
`WorkerRuntime{S}` over that very store. That changes no behavior: the only constructor is
`WorkerRuntime(store::S) = new{S}(…)`. `serve` is now a static `invoke` from `main` with either
middleware form (probed); `test/workers_tests.jl` pins the `Tuple` form. Measured on the realapp
(`--trim=no`, native,
[#744](https://github.com/PingoLee/Nitro.jl/issues/744#issuecomment-6612245023)), first request
on `health`: JIT 1,917 ms, `Vector` 1,660 ms, `Tuple` **0.8 ms**. The `Vector` still builds its
listener at run time, so only the `Tuple` loses the closure. Five of the six non-database routes
read 0.8–6.6 ms; `json_validate` reads 297 ms (13%), a cost it shares with `write`, not
root-caused. The PormG routes read 22–38% of the JIT: see #813, and #744's start-up workload
follow-up.

### 3.11 JWT claims and the session's values: a closed dispatch over JSON (#747, #748)

Built 2026-11-04 with Julia 1.13.2, JuliaC 0.3.12, HTTP.jl 2.13.1 and JSON.jl 1.13.4 on Linux
x86-64, `ENTRY=probe`, `unsafe-warn`, counted by first frame, from `main` at `7f1609b7` and the
change on top of it. `main` reads **121**, §3.9's count, with the same 5 wrong answers.

**The machinery, shared by both.** A verified token's claims and a loaded session are
`Dict{String, Any}`. Their values are whatever the token's author or the application put there,
so every compare, copy or `string` of one was a dynamic call. `Types.with_json_value`
(`src/jsonvalue.jl`) is the closed dispatch over the types JSON.jl parses into (`String`, `Int64`,
`Float64`, `Bool`, `Nothing`, `Vector{Any}`, `Dict{String, Any}`, `JSON.Object{String, Any}`), in
the style of `with_response` and `with_session`. Anything else keeps the JIT's dynamic call and is
refused in a trimmed image. Three walks over those values replace Base where a trimmed image needs
them: `_json_equal` (`==` and `isequal`), `_json_copy` (`deepcopy`) and `_json_dicts` (a `dicttype`
parse). Their tests take every expected value from Base on the same inputs.

**A recursive walk must be one self-recursive method.** The first version recursed back through
`with_json_value`'s `f`. That verified with no error at the walk, but the image threw at run time
at the first call into the cycle ("unresolved invoke" of `_json_dicts_typed(::JSON.Object)`): the
verifier leaves a cycle of method instances unresolved. Each walk is now one `@nospecialize`
method that calls itself, with its own chain of `isa` tests, and folds its object cases inline.
Splitting them into helpers would bring the cycle back.

**JWT claims (#747).** 62 rows, all cleared:

| First frame in `src/` | `main` | after | What it was, and the change |
|---|---:|---:|---|
| `Auth/jwt.jl` `_decode_jwt` (the header) | 12 | 0 | the header narrowed only to `AbstractDict`, so `get`, `haskey` and the `alg` compare dispatched. It is checked at `JSON.Object{String, Any}`, the one type that parse produces, and `kid` and `alg` at `String`, the one type a JSON string parses to |
| `utilities/bodyparsers.jl` `_parse_json_bounded` (the claims, `dicttype`) | 2 | 0 | below |
| `Auth/validators.jl` `_principal`, `_warn_iss` | 14 | 0 | `string` of a claim value: `_claim_string`, static for a JSON scalar |
| `Auth/claims.jl` `_claim_int` | 6 | 0 | `trunc` on `AbstractFloat`, `tryparse` on `AbstractString`: `Float64` and `String` branches first |
| `middleware/guards.jl` the claim compare, `_session_claims` | 10 | 0 | the claims source read as `AbstractDict` and its value as `Any`; `_with_claims` (a `Principal`, a `Dict{String, Any}`, a `JSON.Object`) and `with_json_value`. `_is_identity` is unspecialized, with the concrete string and dict types first |
| `middleware/auth_middleware.jl` `_handle_validated` | 8 | 0 | `_deny(unauthorized::Function, …)`: Julia does not specialize on a function argument a method only passes on; `unauthorized::U where U` |
| `utilities/misc.jl` `_has_two_arg_method` | 10 | 0 | the validator's arity by reflection on a memo miss. Answered when the middleware is built, and used in a trimmed image; the JIT keeps its per-request memo, which exists for Revise |

**`dicttype` is a wall twice over.** A type keyword reaches `JSON.parse`'s keyword body as a plain
`DataType`, so the keyword call itself does not resolve. That is not about forwarding: a literal
`dicttype = Dict{String, Any}` at the call site reads the same, because a `NamedTuple` types the
field `DataType`. `Core.kwcall` with a `NamedTuple` whose field is typed `Type{Dict{String, Any}}`
does resolve (`_parse_json_dict_bounded`, kept for the JIT's static call). Past that call, JSON.jl's
parse under a non-default `dicttype` goes through `StructUtils.make`, whose `applyarray` and
`applyobject` calls the verifier rejects, while its default-object parse verifies clean. So a
trimmed image parses the claims to `JSON.Object`s and rebuilds them as `Dict{String, Any}`
(`_json_dicts`), and the JIT keeps JSON.jl's own parse (`Auth._parse_jwt_claims`, behind
`_trimmed()`). This corrects §3.9 and #801's comment, which said the constant form verifies.

The trimmed probe's three bearer-token requests now answer `200`, `401` and `403`, as under the
JIT. The probe reads **59**.

The validator's arity is still found by reflection (`Base.methods`), only now when `BearerAuth`,
`CookieAuthMiddleware` or `jwt_validator` is called. Built at top level, as the probe and an
application's `urlpatterns` do, that runs while the image is built. Built inside `main`, it runs in
the image, and the `misc.jl` rows come back: build the auth middleware at top level.

What a trimmed image asks of an application, all on paths that refuse rather than misanswer: a
claim value outside the JSON types (one a custom claims dict holds) is an `ArgumentError`, which
the auth middleware answers `401` and a guard `500`; and an application's own claims dict type in
`req.context[:user]` is refused the same way. A guard's configured value is compared at its own
type, so `claim_required("role", "admin")` is static, but a container value
(`claim_required("roles", ["a"])`) still compares element by element through a dynamic `==`.

**The session store (#748).** 37 rows on top of the 59, 28 of them Nitro's:

| First frame in `src/` | before | after | What it was, and the change |
|---|---:|---:|---|
| `middleware/session_middleware.jl` the auth-marker compare | 6 | 0 | `isequal` on two `Any`s: `_json_equal(isequal, …)`, unspecialized |
| `middleware/session_middleware.jl` the dirty check | 4 | 0 | `Dict{String, Any}` `!=`, which compares values as `Any`: `_json_equal(==, …)` in a trimmed image, Base's `!=` under the JIT (`_session_changed`), because Base's dict `==` is three-valued and a `MemoryStore` session can hold a `missing` |
| `middleware/session_middleware.jl` `_load_session` | 2 | 0 | `deepcopy` of the loaded payload, read as `Any`: `_copy_session`, which is `deepcopy` under the JIT and `_json_copy` in a trimmed image |
| `types.jl` `MemoryStore`'s copy (#318) | 0 | 0 | newly reached once the above cleared (2 rows); the same `_trimmed()` switch |
| `cookies.jl` `set_cookie!` | 16 | 0 | its `attrs` branch, a `Dict{Symbol, Any}`. Every framework write (the session id, the CSRF token, the auth cookie) passes no `attrs`, and now calls `_set_framework_cookie!`, the `attrs`-free path, directly |
| `types.jl` LRUCache.jl's `by` and `finalizer` | 9 | 0 | **cleared** in #850: Nitro's own `BoundedLRU`, below |

The copy is the one place the two builds differ on purpose. `deepcopy` keeps two keys that share
one mutable value sharing one copy, and the JIT keeps that. A trimmed image's walk gives each a
copy of its own, which nothing parsed from JSON can tell apart.

**LRUCache.jl kept the session write failing, until #850.** With the rows above cleared the probe
read **31**, and the trimmed session write and the global session read still answered `500`. Built
with the pipeline's error catching off, the image said why: `storesession!` threw a `MethodError`,
which is how a trimmed image fails a call it never compiled. `LRU{K, V}` declared `by::Any` and
`finalizer::Any` (LRUCache.jl 1.6.2), and `setindex!` called both on every insert. So the 9 rows
were not cosmetic: a `MemoryStore` could not store a session in a trimmed image, and a `:lazy`
static mount's cache, the same type, could not cache. The first plan was to wait for
JuliaCollections/LRUCache.jl#56, which makes `LRU` trim-compatible and is still open.

[#850](https://github.com/PingoLee/Nitro.jl/issues/850) replaced it instead with `Util.BoundedLRU{K,
V, F}` (`src/utilities/boundedlru.jl`): a `Dict` plus an intrusive recency list, with `by` a type
parameter and no finalizer, so every call in it is static. It keeps LRUCache 1.6's recency and
oversized-entry rules, and LRUCache.jl is no longer a dependency. Rebuilt 2026-11-04 at the
branch on `b89ce573`, same toolchain as above, the probe reads **22**: the 9 rows are gone, no row
was added, and every probe answers as under the JIT, `/session/set` and the global
`/session/get` with `200`.

Of those 22, 4 were at `csrf_middleware.jl` `_foreign_binding`, which §3.9 left without a cause.
They were its refusal message. `nameof(typeof(value))` on a `value::AbstractString` is itself an
unresolved call, because `typeof` of an abstractly typed value infers `Type{<:AbstractString}`.
The refusals in this section take their argument `@nospecialize` with no annotation; there
`typeof` infers `DataType`, and they verify clean. [#851](https://github.com/PingoLee/Nitro.jl/issues/851)
dropped the annotation the same way. Rebuilt 2026-11-04 from `main` at `6e0022ca` with Julia
1.13.2, JuliaC 0.3.12, HTTP.jl 2.13.5 and JSON.jl 1.13.4, the probe reads **18**: the 4 rows
are gone, no row was added, and every probe answers as under the JIT. The JIT is unchanged: its
one caller has already checked `value isa AbstractString`, and the conversion is the same
`String(value)`. `test/middleware/csrf_middleware_tests.jl` pins it without a build, in a child
with `_trimmed()` redefined to `true`: under the JIT the refusal is dead code, so inference never
looks at it.

The 18 left are the `@with` HAMT inside Base (4, §3.5) and 14 outside `src/`.

What a trimmed image asks of an application's session: values of the JSON types, as a JSON
store holds anyway. A `MemoryStore` session holding another value (a `Symbol`, a `DateTime`) is
refused when it is copied or compared, as an `ArgumentError`, which the request answers `500`.

### 3.12 Julia 1.14: two calls that were static only by inlining (#856)

**Julia 1.14 is outside CI** (#526: CI runs 1.13 only). These counts are from local builds, and
a non-blocking 1.14 leg in CI is an open proposal on #856.

A trimmed app that serves did not start on Julia 1.14: `serve` died with a `MethodError`. #730
found it; it is the first release line that ships `libjulia-internal.a`, so the first on which a
single-file deploy could exist. Two calls, both verified on 1.13, were left unresolved:

- `CookieConfig(; secret_key, httponly, …)` in `serve`, where the start-up dies;
- `Request(method, target; headers, trailers, …)` in `_http_stream_request`, which would fail every
  served request after it.

**The cause is Nitro's calls, not a 1.14 regression.** Each passes values that are `Union`s:
the five `Nullable` fields of the App's current config, and the request's body (`EmptyBody` or
`BytesBody`) and `host`. A call on those types is static only if the compiler inlines it, or splits
it over at most 4 combinations of concrete types. Past that limit, a call that is not inlined
dispatches at run time, on 1.13 as on 1.14. Checked under the JIT with `code_typed`:

- on 1.13, the keyword `CookieConfig` call inlined down to a `new`, and the keyword `Request` call
  split into four static invokes of its keyword body (body × `host`);
- on 1.14, both are a `Core.apply_type` of an abstract `NamedTuple` followed by a dynamic
  `Core.kwcall`;
- on 1.14, the positional `CookieConfig(…)` with the same nine values is dynamic too. So the
  keyword form was never the point: the argument types were.

A minimal repro with no Nitro did not show 1.14 doing worse. A struct of up to 12 keyword fields,
any number of them `Union`s, resolves on both. With the keyword body kept out of line, 1.13 leaves
every `Union`-valued call dynamic while 1.14 resolves it. What differs is which callees each
version inlines, so no upstream report was filed.

**The fix gives both calls argument types that resolve without inlining:**

- `serve` builds its config through `_serve_cookies`, which calls an internal `base` form of
  `CookieConfig`: `CookieConfig(base, secret_key, httponly, secure, samesite)`. It carries over
  `base`'s path and limits, and its domain, which was normalized when `base` was built. Its only
  `Union` argument is the key, which splits statically. Both constructors seal the key through
  `_cookie_secret` and derive its AES key through one helper, and the keyword form is unchanged.
  `serve`'s keyword body is pinned too: it calls `_serve_cookies`, and makes no keyword call of
  `CookieConfig` (`keyword_body`, `calls_to`).
- The transport builds its request through HTTP's typed positional `_request_nocopy`. HTTP's own
  server rebuilds a request the same way, for the same reason. It sets the same fields as the
  keyword form with `copyheaders = false`, which `test/http_internals_contract_tests.jl` checks
  field by field on two served requests, and it is pinned there as a private name.

The pins are in today's 1.13 CI: `kwcalls(…; optimize = false)` and `constructs` (`NitroCommon`).
They pin the shape and not 1.13's verdict, since on 1.13 both keyword calls were static too.

Built 2026-11-04 on `55b7ced6` with JuliaC 0.3.12 (registry), HTTP.jl 2.13.5,
`--trim=unsafe-warn`, `JULIA_CPU_TARGET=native`:

| | 1.13.2, before | 1.13.2, after | 1.14.0-alpha1.112 (`80ba946e97e`), before | 1.14, after |
|---|--:|--:|--:|--:|
| `ENTRY=app` verifier | 8 | 8 | 8 | **5** |
| `ENTRY=app` served | starts, `/plaintext` 200 | the same | `MethodError` at `serve` | **starts, `/plaintext` 200, `/missing` 404** |
| `ENTRY=probe` verifier | 18 | 18 | 20 | 20 |
| probe answers not as expected | 0 | 0 | 14 | 14 |

The three rows cleared on 1.14 are `serve` (2) and `_http_stream_request` (1). Nothing changed
on 1.13. There the app reads 8, not §3.9's 4. The extra rows are `_broadcast_lifecycle`
(`src/core/lifecycle.jl`) and `src/core/pipeline.jl`, unrelated to these calls and not chased
here.

**What 1.14 has left, not cleared here:**

- `lock(f, l) do … end` now goes through `Base.#lock#448(DEFAULT_CANCEL, lock, f::Function, l)`,
  which the verifier cannot resolve. It shows up at `cache_chain!` (`src/types.jl`, the route-chain
  cache) and at `_await_phase_change` (`src/context.jl`).
- Path-parameter binding: `parseparam_checked` at `src/core/parambinding.jl` and `pathparams` on
  a `LazyRequest` (`src/types.jl`).
- OpenSSL's `get_error`, and Base's `uv_readcb`.

The probe never reaches either call fixed here: it builds the pipeline with `setupmiddleware`. Its
14 unexpected answers, every routed request answering 500 and only the 404 path working, come
from that wall. Its output is the same before and after.

§3.13 takes up the `lock` and path-parameter rows, and the 1.13 app's 8.

### 3.13 Julia 1.14's `lock(f, l)`, a `Type{T}` field, and the 1.13 app's 8 (#861)

Built 2026-11-04 with JuliaC 0.3.12 (registry), HTTP.jl 2.13.5, JSON.jl 1.13.4,
`--trim=unsafe-warn`, `JULIA_CPU_TARGET=native`, on Julia 1.13.2 and on 1.14.0-alpha1.112
(`80ba946e97e`). Counted by first frame.

**On 1.13 the app's 4 → 8 is the `ScopedValue` HAMT in a new place, recorded rather than fixed.**
A `git bisect run` over `main`'s merges between `050d7782` (4) and `55b7ced6` (8) points at #840
(`5e96696e`, the one commit `860b89be`, "terminate cancels a start and waits for a stop"). Every
step was built from the same pinned HTTP, JSON, Reseau and OpenSSL, and `050d7782` reads 4 under
them too, so the rise is Nitro's, not a dependency's. The four rows:

| first frame | rows | statement |
|---|--:|---|
| `src/core/lifecycle.jl` `_broadcast_lifecycle`, through the `stopped` hooks of `serve`'s cleanup (`_blocking_serve_cleanup!` → `_terminate_run` → `_teardown!`) | 2 | `HashState(h, getfield(leaf, :key)::AbstractScopedValue)` in Base's `insert!` (`hamt.jl:205`) |
| the same | 2 | `next(h::HashState{K} where K)` (`hamt.jl:220`) |

#840 runs every lifecycle broadcast inside `@with IN_LIFECYCLE_HOOK => true`, so a `terminate`
that a hook calls does not wait for the run that is running it. That `@with` inserts into the
scope's HAMT, which is §3.5's upstream wall, the same 2 + 2 statements as `_app_context_seed`'s
row. The flag stays a `ScopedValue` on purpose: it must reach a task the hook spawns, which
`task_local_storage` would not. The app still starts, serves and stops; these rows are reached
only on the way out.

**Where these `lock` rows stand, 2026-11-05.** They are the 1.14 alpha1 nightly's
(`1.14.0-alpha1.112`), not 1.14.0's. JuliaLang/julia#64415 (merged 2026-10-29, in the alpha2
nightly) made Base's method `lock(f::F, c::GenericCondition) where {F}`, which is the
`_await_phase_change` mechanism below fixed upstream: on `1.14.0-alpha2.122` the trimmed `main`
app reads **2** (`get_error`, `uv_readcb`), the `close(::BufferStream)` row gone. And
JuliaLang/julia#64651 (merged 2026-11-05) reverted the task-cancellation work from the 1.14
branch to 1.15, so 1.14.0 ships no `cancel` keyword on `lock` at all; the keyword body this
section describes is 1.15's shape. Nothing in Nitro moves: `_locked` is correct on every version,
and `cache_chain!`'s `chain::F` was Nitro's own abstract signature. The upstream report for this
row was dropped on #729 (item 6).

**On the 1.14 alpha1 nightly, `lock(f, l)` went through a keyword body, and two of Nitro's sites
stopped verifying.** Its `lock` takes a `cancel` keyword (`base/lock.jl`). `lock(f, l::ReentrantLock)` now forwards
to `#lock#448(DEFAULT_CANCEL, lock, f, l)`, and that call resolves only when the compiler sees
`f`'s concrete type:
- **`cache_chain!`** (`src/types.jl`, every routed request on a cache miss) took `chain::Function`
  and only captured it, so it was compiled for the abstract type. Its closure's type was a
  `UnionAll`, and the call into the keyword body was dynamic (2 rows on the probe, 1 on the app).
  In a trimmed image it failed, and the probe answered 500 on every routed request.
- **`_await_phase_change`** (`src/context.jl`, `terminate`'s wait) called `lock(f, ::Threads.Condition)`,
  which is Base's `lock(f, c::GenericCondition) = lock(f, c.lock)`. That method only passes `f` on,
  so it is compiled for `f::Function`, and its inner call is dynamic (2 rows on the app).

Both now go through `_locked` (`src/utilities/locked.jl`): `lock(l)`, `try f() finally unlock(l)`,
specialized on `f`. `cache_chain!` also takes `chain::F`, which by itself should clear its row:
under the JIT on 1.14, `lock(f, ::ReentrantLock)` with a concrete closure resolves to static
invokes, and the `lock(chains_lock) do` in `_route_chain` beside it is not reported. No build was
made with `chain::F` alone. `_locked` is used there as well so the two sites lock the same way. At
`_await_phase_change` it is the fix, since Base's `lock(f, ::Threads.Condition)` loses `f`'s
type whatever the caller holds. Cancellation does not change: the
positional `lock(l)` is `lock(l; cancel = DEFAULT_CANCEL)` on 1.14, which is what `lock(f, l)`
passes. Only these two sites move. `test/locked_tests.jl` pins the helper and the two sites'
shape in 1.13's CI, and the pins fail against the old code. Under the JIT on 1.13 a routed
`internalrequest` allocates the same before and after (2,112 B on an exact route, 2,784 B on a
converter route). `cache_chain!` on an already cached key goes from 80 B to 0, since its closure
is no longer boxed.

**The path-parameter rows are #460, and the cause is Julia's.** `PathParamStrategy` reads its type
from `param.type`, a field declared `::Type{T}`. 1.13 folds that `getfield` to the constant `Int64`
and calls `parseparam_checked` statically. 1.14 does not: the value stays `Type{Int64}`, which is
not a dispatch type there (a type's own type is now `Core.TypeEgal{T}`). The call becomes dynamic
(`parseparam_checked`, 2 rows) and its result `Any`, which is #460's `Tuple{Any, String, Any}`. A
repro with JSON.jl and no Nitro shows the same: `JSON.parse(s, p.type)` is an `invoke` returning
`Int64` on 1.13, and a dynamic call returning `Any` on 1.14, while `JSON.parse(s, T)` with the
static parameter stays `Int64`. Not worked around here; §3.14 does. The `pathparams(::LazyRequest)` row
(2) sits beside it: `LazyRequest.req` is typed `HTTP.Request`, a `UnionAll`, so the call on it is
the #856 pattern, static on 1.13 only by inlining.

**Outside Nitro on 1.14:**
- OpenSSL.jl's `get_error` (`OpenSSL.jl:3307`) is reached from OpenSSL's own `__init__`
  (`OpenSSLInit` → `OpenSSLError()`): a `string(…)` of an untyped `jl_eqtable_get` result. It is
  OpenSSL.jl's, on every load.
- With `_await_phase_change` cleared, the app shows Base's `close(::BufferStream)`
  (`stream.jl:2232`), reached from HTTP's `SSEStream` close in `_release_response_body!`. It is
  `lock(f, ::GenericCondition)` inside Base, the same mechanism, with no Nitro site to change.
- `uv_readcb`, as on 1.13 (§3.9).

| | 1.13.2, `main` | 1.13.2, after | 1.14, `main` | 1.14, after |
|---|--:|--:|--:|--:|
| `ENTRY=app` verifier | 8 | 8 | 5 | **3** |
| `ENTRY=probe` verifier | 18 | 18 | 20 | **18** |
| probe answers not as expected | 0 | 0 | 14 | **1**: `GET /users/7` → 500, the path-parameter rows |

On 1.14 the app's 3 are `get_error`, `close(::BufferStream)` and `uv_readcb`, and the probe's 18 are
the path-parameter rows (4) and 14 outside `src/`. On 1.13 the app's 8 are §3.9's 4 and #840's 4,
and the probe's 18 have no row in `src/` but the `_app_context_seed` HAMT.

### 3.14 Path-parameter binding on Julia 1.14 (#460)

Built 2026-11-04 with JuliaC 0.3.12 (registry), HTTP.jl 2.13.5, JSON.jl 1.13.4,
`--trim=unsafe-warn`, `JULIA_CPU_TARGET=native`, on Julia 1.13.2 and on 1.14.0-alpha2.122
(`a8aa31d2a1b`), from `main` at `9d7c18e9` (§3.13 merged) and the change on top of it. Counted by
first frame.

**The 1.14 nightly moved since §3.13** (alpha1.112 → alpha2.122), and the counts with it. On the
newer alpha, `main` reads app 2 and probe 18. Base's `close(::BufferStream)` row (§3.13) is gone
from the app. The probe's 18 still hold the 4 path-parameter rows, and `GET /users/7` still answers
500. The "before" column below is that alpha, not §3.13's.

**The four rows**, two statements, each reported once per request body type (`EmptyBody`,
`BytesBody`):

| first frame | rows | statement |
|---|--:|---|
| `src/core/parambinding.jl` `PathParamStrategy` | 2 | `parseparam_checked(getfield(getfield(s, :param), :type)::Type{Int64}, …)::Any` |
| `src/types.jl` `pathparams(::LazyRequest)` | 2 | `pathparams(getfield(request, :req)::Request)` |

**The first is Julia's, worked around on Nitro's side.** §3.13 has the cause: 1.13 folds the
`::Type{T}` field to a constant, 1.14 does not. The three scalar strategies (`PathParamStrategy`,
`QueryParamStrategy`, `RequiredQueryParamStrategy`) now pass `parseparam_checked` their own type
parameter `T`, which is the same type, known statically on any version. `Param`'s `type::Type{T}`
field does not change, so a JuliaLang report (queued on #729) still has its repro.

**The second is Nitro's: `LazyRequest` now carries the request's type**, as
`LazyRequest{R<:HTTP.Request}`. `HTTP.Request` alone is a `UnionAll` over its body type, so
`req::HTTP.Request` was an abstract field, and every accessor on a `LazyRequest` dispatched at run
time. Under the JIT on 1.13 that was already the case: `code_typed` of `pathparams`, `queryvars`
and `headers` on a `LazyRequest` shows a dynamic `:call` each. The 1.13 build accepted the path
strategy only because it inlined the strategies into the parser, which forwards the concrete
request it was called with through the `LazyRequest` it builds. 1.14 does not inline them. The
parser builds the `LazyRequest` positionally, `LazyRequest(req)`, not through a keyword call (§3.12);
the keyword form stays for callers. Every `::LazyRequest` signature still matches.

A function barrier at the call (a closed dispatch over the transport's two request types, as
`with_response` does for responses) would also clear the row. It was not taken: it repeats the
request-shape list `src/routeendpoint.jl` already owns, and it fixes one call site where the type
parameter fixes every accessor, the extractors' body readers included. Under the JIT on 1.13 a
routed `internalrequest` allocates the same before and after (2,048 B on an exact route and
2,720 B on a converter route, the median of 101 with the request built outside the measure).

| | 1.13.2, `main` | 1.13.2, after | 1.14 alpha2, `main` | 1.14 alpha2, after |
|---|--:|--:|--:|--:|
| `ENTRY=app` verifier | 8 | 8 | 2 | 2 |
| `ENTRY=app` served | `/plaintext` 200, `/missing` 404 | the same | the same | the same |
| `ENTRY=probe` verifier | 18 | 18 | 18 | **14** |
| probe: `GET /users/7` | 200 | 200 | 500 | **200** |
| probe: middleware answers | as expected | as expected | as expected | as expected |

The 1.13 `main` column is §3.13's "after" column, which used the same toolchain. The probe's
`all middleware probes answered as expected` line covers only its middleware section. The six
`TARGETS` it prints first, `/users/7` among them, are not counted in that line, so read them too.

**What 1.14 has left is outside `src/`.** The app's 2 are OpenSSL.jl's `get_error` and Base's
`uv_readcb`. The probe's 14 are `task.jl` (5), `get_error` (2), `with_output_color` (2),
`asyncevent.jl` (2), `uv_readcb`, `scrub_repl_backtrace` and `show_exception_stack`. On 1.13 nothing
moved: the app's 8 and the probe's 18 are §3.13's.

**The pins** are in `test/handler_tests.jl`, beside #37's guard, and run in 1.13's CI:
- **The strategies.** Each scalar strategy's lowered code passes `parseparam_checked` its static
  parameter. 1.13's inference folds the field read, so only the lowered code can tell the two
  shapes apart. The pin therefore holds the shape, not 1.13's verdict.
- **`LazyRequest`.** Its `req` field is concrete. `pathparams`, `queryvars` and `headers` on it call
  the request's accessor through a static `invoke`. The parser makes no keyword call to
  `LazyRequest`.
- **Each pin fails against a local revert of its change.** The behaviour readings beside them pass
  on 1.13 either way: each strategy's inferred type, and the `invoke` of `parseparam_checked`.

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
  (indicative, §3.5);
- one file to deploy, with `--static-runtime` (JuliaLang/JuliaC.jl#182, a draft; measured in
  [#730](https://github.com/PingoLee/Nitro.jl/issues/730#issuecomment-6631936426), on a 1.15
  nightly, 2026-11-04). The flag links `libjulia-internal.a` into the exe, which needs Julia
  1.14 or later; 1.13 does not ship the archive.
  - **`RouteEndpoint` works with it.** JuliaC links with `-Wl,--export-dynamic`, so every
    `nitro_route_endpoint_*` thunk stays in `.dynsym` through `--gc-sections`, and `jl_dlsym`
    finds it at run time.
  - **It does not give one file yet.** On the minimal app, the exe grows from 8.8 to 14.4 MB and
    drops `libjulia*`. It still NEEDs `libunwind`, `libzstd`, `libatomic` and `libstdc++`, and
    loads OpenSSL, so the bundle keeps 22 files of 24. Its stack is executable (`GNU_STACK RWE`).
    A process that runs requests through the pipeline and exits takes 1.5–2 ms less.
  - **It does not apply to `--trim=no`.** The archive's codegen is a stub, so an untrimmed
    image segfaults at start-up.
  - **The served app's size, listen and RSS rows wait** until the trimmed app starts on Julia
    1.14 and later. Two keyword calls verify on 1.13 but not there: `CookieConfig(; …)` in
    `serve`, and the request constructor in `_http_stream_request`.

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
   - ~~JSON.jl 1.13.0's typed parse under a custom style (JuliaIO/JSON.jl#543), 110 rows, reached
     from `_parseparam_fallback`~~ **cleared** in JSON.jl 1.13.4 (JuliaIO/JSON.jl#553 / #555;
     #801, re-measured 2026-11-02: 231 → 121). The `dicttype` keyword's 2 rows belong to #747;
   - Auth's claims, 60 with the guards' claim compare ([#747](https://github.com/PingoLee/Nitro.jl/issues/747));
   - ~~the session store's internals, 37 with `set_cookie!` and LRUCache.jl
     ([#748](https://github.com/PingoLee/Nitro.jl/issues/748))~~ **cleared** (§3.11; LRUCache.jl
     replaced by `BoundedLRU`, [#850](https://github.com/PingoLee/Nitro.jl/issues/850)).

Two rules come with the target:

- **The JIT build is the one users run today, so it must not pay for the target.** A change made
  for `--trim` that costs the JIT request path more than the noise, such as a `FunctionWrapper`
  trampoline per request where a function barrier would do (§3.2), has to justify that cost with
  a measurement (`bench/socket/run.sh`, interleaved with `main`).
- **Every wall cleared is re-measured with `bench/juliac/build.sh unsafe-warn`, counted by first
  frame in `src/`**, so this record's §3 stays the live backlog. Once the minimal app passes
  `--trim=safe`, the trimmed exe's first request, resident memory and throughput against the JIT
  are the numbers that say whether the target paid off.
