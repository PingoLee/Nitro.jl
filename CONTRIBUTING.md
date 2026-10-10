# Contributing to Nitro.jl

**Nitro.jl** is an SPA/API-first web framework for Julia. This page holds what a contributor —
human or agent — needs to find their way around the source, the rules that apply to every change,
and the commands that verify one. User documentation is at
[pingolee.github.io/Nitro.jl](https://pingolee.github.io/Nitro.jl/); writing an application *on*
Nitro is covered by the [`nitro-usage`](.github/skills/nitro-usage/SKILL.md) skill, and two
smaller workflow skills ship beside it: [`add-route`](.github/skills/add-route/SKILL.md) (a new
endpoint end-to-end) and [`deploy-checklist`](.github/skills/deploy-checklist/SKILL.md) (a
pre-production audit). Claude Code finds each one through its tracked discovery stub
`.claude/skills/<name>/SKILL.md`; every other agent reads `.github/skills/<name>/SKILL.md`
directly.

## Design lineage — four traditions, deliberately

When you design or review, judge a proposal against the tradition that owns that layer, and say
which one you are appealing to:

| Layer | Inspiration | What that means here |
|-------|-------------|----------------------|
| Routing, sessions, project layout | **Django** | Centralized `urlpatterns`, typed path converters, `include_routes()` composition, handlers/routes separation, session middleware with pluggable stores |
| Concurrency & runtime | **Go** | Every request on `Threads.@spawn` — goroutine-style, *not* a Node event loop and *not* a PM2/cluster multi-process model. `julia -t auto` is the scaling story. No `serveparallel()` |
| Response & middleware ergonomics | **Node.js / Express** | `res.json()`-style response builders, a linear top-down middleware chain, first-class JSON/CORS/SPA-history support |
| Typed binding, authorization, app context | **Spring Boot** | Extractors (`Json{T}`, `Query{T}`, `Path{T}`, `Form{T}`, `MultipartForm{T}`) + `validate` are `@RequestBody`/`@RequestParam`/`@Valid`; `Principal` and the `claim_required`/`role_required`/`kid_required` guards are Spring Security's declarative model; typed app-config structs are `@ConfigurationProperties` |

**Where the lineages disagree, Spring's application-context model is the tiebreaker for lifecycle.**
Django and Express both tolerate a process-wide singleton; Spring does not, because an
`ApplicationContext` is an *object*, so several can coexist and tests get their own. Nitro followed
Spring here in [#31](https://github.com/PingoLee/Nitro.jl/issues/31): **`App` is the public
application handle**, and every routing, serving and cookie function takes one as its first argument
(`app = App(mod = @__MODULE__)`). The `CONTEXT[]` singleton (`src/Nitro.jl`, `src/methods.jl`)
remains only as the argument-less convenience layer over one app — prefer an explicit `App` in new
code and in tests.

Julia adds a constraint none of them have: **precompilation and type stability are part of the API
design**, not an optimization pass. A choice that is idiomatic in Express but forces `Any` through
the request path is the wrong choice here.

**Secondary references — reach for these when designing something new.** These are not in the code
today; they are the best prior art for Nitro's *open* architectural questions. Cite the reference and
the trade-off when you propose a design.

| Open question | Study | Why it is the right reference |
|---------------|-------|-------------------------------|
| Typed app state with no global, type-stable through the request path ([#31](https://github.com/PingoLee/Nitro.jl/issues/31), [#37](https://github.com/PingoLee/Nitro.jl/issues/37)) | Rust **`axum`** — `Router<S>`, `State<S>`, `FromRequestParts` | A statically-typed language solving exactly Nitro's problem: app state is a *type parameter on the router*, and extractors resolve at compile time. Structurally the closest match Julia has — much closer than Express |
| Handing a handler what a guard resolved, instead of only gating it ([#24](https://github.com/PingoLee/Nitro.jl/issues/24)) | **FastAPI** `Depends` | Nitro's guards authorize but cannot *inject* — they throw away the principal, DB handle, or tenant they just resolved. `Depends` is the dependency-injection generalization of a guard, and composes with typed extraction |
| Middleware that cannot corrupt a shared response (nitro-core §4) | **Phoenix / Plug** `Plug.Conn` | Plug threads one `conn` value through the pipeline and every plug returns a *new* one. Nitro enforces the same discipline by rule; Plug enforces it by shape. If the rule keeps getting violated, adopt the shape |
| Worker semantics: uniqueness keys, retry/backoff, dead-letter, ownership ([#19](https://github.com/PingoLee/Nitro.jl/issues/19), [#9](https://github.com/PingoLee/Nitro.jl/issues/9), [#10](https://github.com/PingoLee/Nitro.jl/issues/10)) | **Sidekiq**, Go **River** | Settled vocabulary for problems Nitro's queue is currently rediscovering. Also Elixir supervision trees for restart/ownership semantics |
| Streaming bodies and upload caps without whole-file reads ([#41](https://github.com/PingoLee/Nitro.jl/issues/41), [#17](https://github.com/PingoLee/Nitro.jl/issues/17)) | Go **`net/http`** | `io.Reader`/`io.Copy` streaming and `http.MaxBytesReader` — the same tradition Nitro already took its concurrency model from |

**Fork lineage — Oxygen.jl (anti-inspiration).** Nitro is a fork of
[Oxygen.jl](https://github.com/OxygenFramework/Oxygen.jl) (MIT, Nathan Ortega — see
[`LICENSE.md`](LICENSE.md)); a sibling `../Oxygen.jl` checkout is often present locally.
Capabilities were removed **on purpose**: macro and function route registrars, cron, repeat tasks,
metrics, and autodoc. Finding one of them in Oxygen — or in a Stack Overflow answer about Oxygen — is
**not** a reason to reintroduce it; check nitro-core §1–§3 first. `serveparallel()` is the one
survivor: it still exists in `src/methods.jl` as a deprecated shim that just forwards to `serve()`.
Never use or suggest it — and note that under the pre-publish posture below, a shim like this is a
candidate for deletion, not preservation.
`test/original_tests.jl` is the retained upstream integration suite and is why some tests read in an
older style than the rest of `test/`.

## Rules that apply everywhere

These are canonical here — no other file owns them. Area-specific rules live in the files indexed
under *Area rule files* and are canonical **there**.

- **Pre-publish (not on Julia General; single maintainer, no external users):** breaking changes are
  cheap — get the API, naming, and architecture *right* over backward compatibility. Do not add
  deprecation shims or compatibility aliases to preserve a design you believe is wrong; propose the
  clean break. Whether and when to publish is the maintainer's judgment; what blocks registration
  today, and the routes out of it, are recorded in
  [`docs/design/registry-publication.md`](docs/design/registry-publication.md).

- **Upgrade log — a breaking or behavior change is done only with its entry.** It ships code +
  tests + docs **and** one new file under [`upgrading/`](upgrading/) carrying
  `- **Version**: Unreleased`, and it does **not** bump `Project.toml` — the maintainer cuts release
  trains. The entry's shape (one file per entry, the *"How to find the calls to migrate"* grep, the
  `before → after`, what does *not* belong in the log) is the contract in
  [`UPGRADING.md`](UPGRADING.md); the user-facing model is [`docs/src/upgrading.md`](docs/src/upgrading.md),
  and the read side is `upgrade_guide(from = v"<pin>")` in [`src/upgrading.jl`](src/upgrading.jl).
  There is deliberately **no `CHANGELOG.md`**.

- **Bumping the PormG pin — run its upgrade guide first.** Nitro pins PormG twice, and **both pins
  live in `Project.toml`**: `[sources]` names the immutable commit
  (`PormG = {url = "https://github.com/PingoLee/PormG.jl.git", rev = "<40-hex sha>"}`) and
  `[compat]` names the range Pkg may resolve. PormG uses the same release-train model, so **before**
  raising either one run `PormG.upgrade_guide(from = v"<current pin>")` and apply every entry it
  lists — bumping the pin without applying them is the exact failure the model exists to prevent.
  PormG is a weakdep, so run it from PormG's own env, not Nitro's. Nitro's PormG surface is
  confined to `ext/NitroPormGExt.jl`, which keeps most entries inapplicable — but confirm that per
  entry with its grep rather than assuming, and re-run the `test/extensions/pormg_*` tests. Entries
  can be **data** migrations rather than code ones: PormG's UTC canonicalization of `DateTimeField`
  requires a one-time re-normalization of existing **SQLite** rows, which reaches the `expires_at` and
  timestamp columns Nitro's session and worker stores write.

  **The two pins move together, and pass the guide the LOWER BOUND** of the `[compat]` range, not
  the range: if the entry reads `PormG = "^0.6"`, the argument is `v"0.6.0"`. Raising only
  `[compat]` leaves the resolver admitting code nothing fetches; raising only `[sources]` leaves a
  commit `[compat]` does not admit — both make CI say something about a configuration nobody ships.

  **The `rev` is a full 40-character SHA, never a tag or a branch.** A tag is mutable and can be
  re-pointed, which is precisely the immutability the pin exists to provide.

  This used to be split across two files: a `[sources]` **path** dep gives Pkg nothing to pin
  against, so the immutable commit had to be enforced out of band by `PORMG_REV` in `ci.yml` plus a
  hand-rolled sibling checkout ([#21](https://github.com/PingoLee/Nitro.jl/issues/21)). A `url` +
  `rev` source gives Pkg the pin directly — it fetches that commit itself and records its tree hash
  — so `PORMG_REV` and both checkout steps are gone. Do not reintroduce them; a second pin is the
  drift this consolidation removed. The trade is that a local `../PormG.jl` is no longer live: to
  co-develop the two, `Pkg.develop` it into the worktree's manifest (uncommitted) and remember that
  "works locally" then stops being evidence about CI until the `rev` is bumped.

- **No runtime side effects in module bodies.** Cached precompilation runs a module body **only in
  the precompile worker** — loading from cache does not re-run it. Top-level `atexit`, `ENV`
  mutation, global registry writes, and service wiring therefore never run at runtime. Put
  load-time runtime wiring in `__init__()`. This applies to `src/precompile.jl` workloads and to
  every `ext/` extension's registration path.

- **`Project.toml` carries no comments — put the reasoning in this file or `README.md`.**
  CompatHelper rewrites `Project.toml` through a TOML round-trip that silently drops **every**
  comment line; no flag disables it. Rationale parked there survives only until the next dependency
  bump. Keep the file comment-free *on purpose*, and never "fix" a stripped comment by restoring it.
  The standing case: **`julia = "^1.12"` is intentional — do not lower it to the 1.10 LTS**, and
  `HTTP` is pinned with `~` (one minor series), never `^`, because core depends on
  `HTTP.BytesBody` and other internals no SemVer covers (see nitro-core §4); moving it is a
  deliberate bump that re-runs `test/http_internals_contract_tests.jl` and writes an `upgrading/`
  entry, never a CompatHelper merge.

- **Never log or serialize secrets.** No session payloads, CSRF tokens, JWTs, cookie values,
  connection strings, or `SecretString` contents in logs, error bodies, or issue text. Use
  structured logging (`@error "Msg" exception=e key=value`). Access logging redacts query strings by
  default (`serve(...; access_log_query=false)`) — keep it that way.

- **Ship tests with behavior changes.** New or changed runtime behavior needs coverage under
  `test/`; changes to `ext/` need coverage under `test/extensions/`. See *Verification* below.

## Hard stops — index only

Each rule below is **canonical in its linked section**. This table exists so a reader who opens
only this file still avoids the architecturally-invalid moves. It carries no rationale and no
exceptions on purpose — read the canonical section before writing code in that area.

| Hard stop | Canonical |
|-----------|-----------|
| Routes are declared with `path()` / `urlpatterns()` / `include_routes()` only — no macro or function registrars | [nitro-core §3](.github/instructions/nitro-core.instructions.md) |
| Never feed unescaped user input into `Res.html()`, `Res.send(...; content_type=...)`, or a template rendered by `mustache()`/`otera()` — those are the markup sinks | [nitro-core §4](.github/instructions/nitro-core.instructions.md) |
| Never mutate a `Response` returned by an inner middleware layer — build a new one | [nitro-core §4](.github/instructions/nitro-core.instructions.md) |
| Never route response bodies through HTTP.jl's consuming write path | [nitro-core §4](.github/instructions/nitro-core.instructions.md) |
| `PormG` may be imported only inside `ext/NitroPormGExt.jl` — never in `src/` | [nitro-core §6](.github/instructions/nitro-core.instructions.md) |
| No `Any` in the request hot path | [nitro-core §7](.github/instructions/nitro-core.instructions.md) |
| No `Nitro.config` global — applications own their typed config structs | [nitro-config §1](.github/instructions/nitro-config.instructions.md) |
| Bootstrap order: load config → resolve secrets → run initializers → `serve(context=...)` | [nitro-config §2](.github/instructions/nitro-config.instructions.md) |
| Task submission requires `user_id`; new backends implement `AbstractWorkerStore` | [workers §2](.github/instructions/workers.instructions.md) |
| Worker DB logic lives only in `ext/NitroPormGExt.jl` | [workers §6](.github/instructions/workers.instructions.md) |
| Docs examples use generic models and current routing only | [nitro-docs §3](.github/instructions/nitro-docs.instructions.md) |

## Area rule files

Nothing attaches these files automatically: open the one for the area you are editing, driven by
this table. Treat *When to read* as a hard prerequisite: the non-consuming response-write path in nitro-core §4 is load-bearing, and editing
`src/core.jl` without reading it risks a silent, suite-wide regression.

| Area | Rule file | When to read |
|------|-----------|--------------|
| Core framework, routing, responses, security | [`nitro-core.instructions.md`](.github/instructions/nitro-core.instructions.md) | Any `src/*.jl` change |
| Config & bootstrap | [`nitro-config.instructions.md`](.github/instructions/nitro-config.instructions.md) | App config or `serve()` design |
| Documentation | [`nitro-docs.instructions.md`](.github/instructions/nitro-docs.instructions.md) | `docs/**/*.md` edits |
| Workers + PormG ext | [`workers.instructions.md`](.github/instructions/workers.instructions.md) | `src/Workers/`, `ext/`, worker tests |
| Concurrency & task model | [`concurrency.instructions.md`](.github/instructions/concurrency.instructions.md) | Spawning, parking or stopping a task; background loops; interrupts; work on HTTP.jl's connection task |

`.github/scripts/docs_lint.jl` (run in CI) keeps this page, `AGENTS.md`, the area rule files and
the public skills honest: every backtick path and local link must resolve, every `§` pointer must
hit a real heading, and the sets of rule files, skills and discovery stubs are pinned.

## Architecture

The map below is also the review **architecture checkpoint**: when a file appears in `src/` that no
row covers, flag it and add a row.

**Layering (enforced by the include chain in `src/Nitro.jl`).** `src/core.jl` defines the `Core`
module and pulls in types, context, routing, middleware, and utilities; `Auth`, `Instances`, and
`Workers` are layered on top of `Core` and may use it, never the reverse. Shared vocabulary — an
abstract type, a constant, an exception type — belongs in `src/types.jl`, `src/constants.jl`, or
`src/errors.jl`, not part-way down the chain, or modules included earlier cannot name it.

**`src/methods.jl` is where the API is coupled to global state.** The top-level convenience methods
bind to the process-wide `CONTEXT[]` singleton declared in `src/Nitro.jl`. Every one of them also
has an `(app::App, …)` method defined **in that same file** — reach for that form in tests and in
any code that must not touch the global. The exceptions are `resetstate` (singleton-shaped by
definition) and `route` (plumbing, not public API). `serveparallel` has none either, but it is a
deprecated shim awaiting deletion, not a principled exception.

That placement is load-bearing, not incidental: `methods.jl` defines these names inside `Nitro`, so
they **shadow** the same-named functions `using .Core` brings in. An `(app, …)` method added only in
`Core` is unreachable through `using Nitro`. Add it here.

| Path | Role |
|------|------|
| `src/Nitro.jl` | Package root — include chain, the `CONTEXT[]` singleton, and the public `export` surface |
| `src/core.jl` | `Core` module hub — the submodule include chain, the accessor forward-declaration stubs, the public `export` surface, and the `src/core/` includes. No implementation of its own (#32) |
| `src/core/request.jl` | Per-request caches and the exported request accessors — `getparams`/`getquery`/`getjson`/`getform`/`getfiles`/`getpost`/`getsession`/`getuser`/`getip`/`getpeerip`/`getcontext`, `payload` |
| `src/core/transport.jl` | HTTP.jl v2 / Reseau internals: the stream-request shim, `_peer_ip` (via the public `HTTP.peeraddr`), the **non-consuming response write path** (`_write_response_body!`), and the stream handlers |
| `src/core/framework_middleware.jl` | The Core-owned layers `setupmiddleware` installs: `AccessLogMiddleware`, `PrefixStripMiddleware`, `DefaultSerializer` |
| `src/core/pipeline.jl` | Middleware assembly — `setupmiddleware`, `_app_context_seed` — and the in-process entry point `internalrequest` |
| `src/core/lifecycle.jl` | Server lifecycle — `serve`/`terminate`/`startserver`, the startup banner, Revise wiring, and the secret-safe `NitroStreamHandler` `show` |
| `src/core/parambinding.jl` | Per-parameter binding strategies (#37) and `create_param_parser` |
| `src/core/registration.jl` | Route registration and handler introspection: `parse_route`, `parse_func_params`, `register`/`register_internal`, `registerhandler` |
| `src/core/staticfiles.jl` | Static, SPA and dynamic mounts — `staticfiles`, `spafiles`, `dynamicfiles` |
| `src/routing.jl` | Django-style routing: `path`, `urlpatterns`, `include_routes`, `url`, the path-converter registry |
| `src/routerhof.jl` | Higher-order router internals (`HOFRouter`) — plumbing, not public API |
| `src/context.jl` | `AppContext` module — the public **`App`** handle and its secret-safe `show`, plus `Service`, app-context storage, extension slots, lifecycle services |
| `src/methods.jl` | The `(app::App, …)` public surface **and** the argument-less conveniences bound to the global `CONTEXT[]`. Both live here because definitions in `Nitro` shadow `Core`'s |
| `src/types.jl`, `src/constants.jl`, `src/errors.jl` | Shared vocabulary: `Nullable`, `Principal`, HTTP method constants, `ValidationError`/`CookieError`/`AuthorizationError` |
| `src/environment.jl` | `Environment` module — `current_env()`, the `NITRO_ENV`/`GENIE_ENV` precedence and its closed value set. Reports the environment; deliberately gates nothing (#55) |
| `src/response.jl` | The `Res` module — the response builders handlers use: `json`, `html`, `send`, `status`, `file`, `redirect` |
| `src/utilities/bodyparsers.jl` | Request body parsing: `text`, `json`, `binary`, `formdata`, `multipart`, `FormFile` |
| `src/utilities/misc.jl` | `parseparam`, `format_response`, `response` (content-sniffing builder used by the templating extensions — a markup sink), `add_response_headers`, `own_response_headers`, request plumbing |
| `src/utilities/fileutil.jl` | `readfile`, `mountable_files`, `mountfolder` — static-mount helpers; `mountable_files` owns which files a mount will expose (dotfiles, symlink confinement, route-pattern names) |
| `src/extractors.jl` | Typed extractors: `Path`, `Query`, `Header`, `Json`, `JsonFragment`, `Form`, `Body`, `Cookie`, `Session`, `Files`, `MultipartForm` |
| `src/reflection.jl` | `struct_builder`, `splitdef`, `extract_struct_info` — the machinery extractors bind through |
| `src/handlers.jl` | Handler dispatch — `select_handler`, first-argument typing |
| `src/middleware.jl`, `src/middleware/` | Middleware: `ExtractIP`, `WebSocketOrigins`, `RateLimiter`, auth (`BearerAuth`/`CookieAuthMiddleware`), `Cors`, `SecurityHeaders`, `CSRFMiddleware`, `CrossOriginProtection` (tokenless Fetch-Metadata CSRF, #437), `SessionMiddleware`, `GuardMiddleware` + guards, `AccessLog` |
| `src/middleware/janitor.jl` | `_janitor` — the **single** periodic-background-janitor discipline: spawn, per-activation stop token, per-tick `try`, `InterruptException` rethrow, and the activation reset that keeps a dead janitor restartable (#190). Internal, not re-exported. `SessionMiddleware`/`SessionPruner` and `FixedRateLimiter` are its only callers; `AccessLog`'s writer is event-driven and deliberately stays out |
| `src/Auth.jl`, `src/Auth/` | JWT, claims, password hashing, cookie auth, guard re-exports |
| `src/Workers.jl`, `src/Workers/` | Background task queue: API, execution, registry. **`AbstractWorkerStore` is data access only**; `src/Workers/runtime.jl`'s `WorkerRuntime` owns the queues, cleanup scheduler and run handles, and is what `shutdown!` takes (#167) |
| `src/cookies.jl`, `src/crypto.jl` | Signed/encrypted cookies, `SecretString`, AES-GCM, secure randomness |
| `src/exts.jl` | Partial definitions every package extension fills in (`pormg_nitro_worker`, `protobuf`, `mustache`, …) |
| `src/precompile.jl` | `PrecompileTools` workload — keep in sync when the hot path changes |
| `ext/` | Weak extensions: `NitroPormGExt`, `NitroReviseExt`, `MustacheExt`, `OteraEngineExt`, `ProtoBufExt`, `TimeZonesExt`. The **only** place a weak dependency may be imported |
| `test/` | `ReTestItems` suite driven by the explicit ordered list in `test/runtests.jl` |
| `docs/src/` | User documentation (Documenter) |
| `docs/design/` | Design records — accepted rationale and open proposals that are not user docs |
| `upgrading/` | The change log `upgrade_guide` reads — **one file per breaking/behavior entry**, `YYYY-MM-DD-<slug>.md`. Every `.md` here is an entry; nothing else belongs in it |

## Verification

Run the narrowest relevant slice first; broaden only after green.

Every `test/runtests.jl` invocation below re-dispatches through `Pkg.test` to provision
`[targets].test` (`PormG` included), so the `--project=.` and `Pkg.test()` forms are equivalent —
not a cheap run versus a full one. What neither will do any more is run *short*: a missing declared
test dependency is refused before the first item rather than skipped
([#128](https://github.com/PingoLee/Nitro.jl/issues/128)). The smoke test is the deliberate
exception and does not re-dispatch — that is the whole point of it, see its comment below.

```bash
# Full suite
julia --project -e 'using Pkg; Pkg.test()'

# Single file or directory
julia --project=. test/runtests.jl test/workers_tests.jl
julia --project=. test/runtests.jl test/middleware/

# By tag or name. Tags are AND-combined; --name is an EXACT item name, not a substring.
# A filter matching nothing is an error, not an empty pass.
julia --project=. test/runtests.jl --tags core --name "Session stores"

# By tag EXCLUSION -- `--skip-tags` is repeatable and is the DUAL of `--tags`, not its
# mirror: an item is dropped if it carries ANY listed tag, where `--tags` demands ALL of
# them. The first line is the fast socket-free pass over the whole suite; the second is
# what honest per-item tags buy -- the same tag, minus the items that bind a port.
julia --project=. test/runtests.jl --skip-tags network --skip-tags slow
julia --project=. test/runtests.jl --tags middleware --skip-tags network

# `--workers N` for N > 1 is refused -- the suite shares one global router and depends on
# the TEST_FILES order, so splitting items across processes silently changes what they see.
# `julia -t auto` still runs the items themselves multithreaded.
julia -t auto --project=. test/runtests.jl

# Agent-docs reference lint (paths, links, symbols, § anchors, public skill/rule sets, stubs)
julia .github/scripts/docs_lint.jl

# Smoke test — loads, routes and serves using NOTHING test-only (Nitro + HTTP + stdlib).
# Use it when ReTestItems cannot run on a Julia version: `Pkg.test()` then dies before the
# first assertion, so the suite says nothing about whether `src/` actually works there.
julia --project=. .github/scripts/smoke_test.jl

# Docs build (the package env has no Documenter — `--project=.` fails)
julia --project=docs -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate()'
julia --project=docs docs/make.jl
```

- **CI runs the suite on Julia 1.12 across Linux/macOS/Windows at `JULIA_NUM_THREADS` 1 **and** 2.**
  A change that only passes single-threaded is not green.
- **`PormG` is a git-pinned source dependency** (`[sources] PormG = {url = …, rev = <sha>}`) and a
  hard test dependency: Pkg fetches that exact commit into the depot, so `Pkg.test()` resolves with
  no sibling checkout and needs network on a cold depot. It used to be a `path` dep, which
  meant a sibling `../PormG.jl` had to exist *and* be on a compatible version — so unrelated work in
  that checkout could stop Nitro resolving at all. It is also
  the one test dependency whose absence used to be **quiet**: everything else errors on import,
  while `PormG` merely made the `PormGWorkerStore` testset skip — 112 assertions gone from a run
  that still exited 0. Both ends of that are closed now. `test/runtests.jl` probes every
  `[targets].test` entry rather than one proxy package, and refuses an incomplete environment;
  `test/harness_tests.jl` fails on any skip not written down in `SKIPS_OK`
  (`test/harness_manifest.jl`) — `@test_skip`, `@test_broken`, and the keyword forms
  `@test ex skip=true` / `@test ex broken=true`, which report as `Broken` just the same.
  **A green suite is again evidence that the suite ran.**
- **Worktrees.** `bash scripts/worktree_setup.sh [<path>]` gives a fresh worktree the main
  checkout's manifest resolution, so a version difference does not later read as a flake.
