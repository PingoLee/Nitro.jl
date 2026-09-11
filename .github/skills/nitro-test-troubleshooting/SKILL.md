---
name: nitro-test-troubleshooting
description: >-
  Diagnose failing, flaky, or environment-dependent Nitro.jl tests — global router state leaking
  across test items, ordering dependencies in the explicit runtests.jl list, thread-count-dependent
  failures, port binding and network tests, the Pkg.test re-dispatch, and the PormG sibling
  dependency. Read when a test is red and the cause isn't an obvious code regression.
---

# Nitro.jl Test Troubleshooting

## Purpose

Use this skill when a test fails and it is not immediately clear whether that is a real regression in
your change or an environment/infrastructure issue this repo has hit before. It captures the
recurring failure classes and how to tell them apart, so you don't bisect a known-shape problem.

If the failure is obviously caused by the code you just wrote, fix the code — don't come here first.

## Use this skill for

- A test that passes alone but fails in the full suite (or vice versa)
- A test that passes at 1 thread and fails at 2 (or only on CI)
- "Package X not found in current path" when running `test/runtests.jl` directly
- Port-binding, connection-refused, or hanging network tests
- Extension (`ext/`) tests failing to load, or PormG resolution errors
- A test file you added that never seems to run

---

## Test layout and how to run a narrow slice

The suite uses **ReTestItems**. Test items are `@testitem` blocks with `tags=[...]` and
`setup=[NitroCommon]`.

```bash
# Full suite (what CI runs)
julia --project -e 'using Pkg; Pkg.test()'

# One file, or one directory
julia --project=. test/runtests.jl test/sessionstores_tests.jl
julia --project=. test/runtests.jl test/middleware/

# Filter by tag or name
julia --project=. test/runtests.jl --tags core
julia --project=. test/runtests.jl --name "Session stores"

# Multithreaded items (one worker process, TEST_FILES order preserved).
# `--workers N` for N > 1 is refused — see §7.
julia -t auto --project=. test/runtests.jl

# Interactive REPL — setup_tests.jl MUST come first
julia> using ReTestItems, Nitro
julia> runtests("test/setup_tests.jl", "test/middleware/guards_tests.jl")
```

**Available tags:** `:core`, `:middleware`, `:auth`, `:security`, `:csrf`, `:handler`,
`:extension`, `:pormg`, `:network`, `:scenario`, `:slow`, `:aqua`, `:workers`.

That list is prose; the machine-checked copy is `KNOWN_TAGS` in `test/harness_manifest.jl`, and
`test/harness_tests.jl` asserts it matches the tags actually in use **in both directions**. An
unknown `--tags` value is now an error naming the vocabulary. ReTestItems already fails a zero-match
filter with `No test items found.`; the guard exists because that message names neither the
vocabulary nor the AND/exact-match semantics. The genuinely silent case was a **mistyped path** —
warned and dropped, run still green — which `validate_paths = true` now turns into a throw.

Useful combination when you only want fast feedback: exclude the network-bound items by selecting a
narrower tag rather than running everything.

---

## Known recurring failure classes

### 1. Global router state leaking across test items

**The single most common cause of "passes alone, fails in suite."**

`urlpatterns(...)` mutates the process-wide `CONTEXT[]` router (`src/Nitro.jl`, `src/methods.jl`).
Test items that register routes therefore affect every later item in the same process.

The suite compensates with an **explicit, hand-ordered `TEST_FILES` list**, which lives in
`test/harness_manifest.jl` and is read by both `test/runtests.jl` and the guard below. Consequences:

- **Do not** replace the list with `runtests(Nitro)` — filesystem-walk order differs and will produce
  spurious failures.
- **A new test file that is not added to `TEST_FILES` no longer fails silently.**
  `test/harness_tests.jl` walks `test/` the way ReTestItems does and fails naming any file that is
  neither listed nor in `UNLISTED_OK`. It used to be silent: a middleware smoke test sat unlisted
  and unexecuted for its whole life, and nothing said so ([#34](https://github.com/PingoLee/Nitro.jl/issues/34)).
  The omission is still easy to make — rung 1 runs your file *by path*, so it passes either way —
  but it is now caught before merge rather than never.
- If your item registers routes, either give paths a prefix unique to that item, or call
  `resetstate()` — but be aware `resetstate()` clears state a *later* item may have expected.
- Prefer `instance(...)` or the explicit `(ctx::ServerContext, …)` methods to keep a test off the
  global router entirely. This is the durable fix, not a workaround.

**Diagnosis:** run the file alone (`julia --project=. test/runtests.jl test/<file>.jl`). Green alone
+ red in suite ⇒ ordering/state, not your logic. Then bisect by running the suspect file *after* the
one you think dirtied the router.

### 2. Thread-count-dependent failures

CI runs the suite at `JULIA_NUM_THREADS` **1 and 2**, on Linux, macOS, and Windows. A change that
only passes single-threaded is **not green**.

Handlers run on `Threads.@spawn`, so anything sharing mutable state across requests can race. The
classic shapes:

- Middleware mutating a `Response` it received from an inner layer — the response may be a shared
  module-level `const`. Use `add_response_headers` / `own_response_headers` (regression coverage:
  `test/middleware/shared_response_mutation_tests.jl`).
- A cache or limiter reading a plain `Dict` outside the lock that guards its writes.
- Test items asserting on ordering of concurrently-produced output.

**Diagnosis:** `julia -t 1 --project=. test/runtests.jl <file>` vs `julia -t 2 …`. A difference is a
race, not flakiness — do not retry until it passes.

### 3. "Package X not found in current path"

Test-only dependencies (`Suppressor`, `ProtoBuf`, `ReTestItems`, `Aqua`, …) live in `[extras]` /
`[targets].test`, so they are on the load path **only** under `Pkg.test()`.

`test/runtests.jl` detects a direct run and **re-dispatches through `Pkg.test`** once, forwarding CLI
args and the launcher's thread count (guarded by the `NITRO_TEST_REDISPATCH` env var). It decides by
probing **every** `[targets].test` entry, read from `Project.toml`. It used to probe one package,
`Suppressor`, as a stand-in for "am I in the test env?" — and `Base.identify_package` searches the
whole `LOAD_PATH`, so on a machine with `Suppressor` installed in the global `@v#.#` environment the
answer was "already provisioned", the re-dispatch never fired, and `PormG` (a `[sources]` path dep,
never globally installable) stayed missing. See §3b. So the direct commands work — but if you see this error anyway:

- You are running a test file *directly* (`julia --project=. test/foo_tests.jl`) instead of through
  `test/runtests.jl`. Go through the runner.
- Or `NITRO_TEST_REDISPATCH` is stale in your shell from an interrupted run — unset it.

### 3b. "Nitro test environment is incomplete" — the run refused to start

Not a test failure: the suite declined to run because a package in `[targets].test` was not
importable, *after* the `Pkg.test` re-dispatch had already been spent. The message lists exactly
which ones.

This is deliberate, and it replaced a silent failure mode. A missing `ReTestItems` kills the run
immediately, but a missing `PormG` only made `test/extensions/pormg_worker_tests.jl` take a
`@test_skip` branch — `Broken 1` in a 3,500-assertion summary, exit code 0, 112 assertions gone
([#128](https://github.com/PingoLee/Nitro.jl/issues/128)). Refusing is the loud version of that.

**Read the two paths the message prints first** — `Active project:` and `Expected:`. If they differ,
that is the answer and the four causes below are noise. Then work through them in order:

1. **No Nitro environment is active** — you ran `julia test/runtests.jl` without `--project=.`. The
   tell is that *every* target is listed as missing rather than a subset, and the two paths above
   disagree.
2. **`NITRO_TEST_REDISPATCH` stale in your shell** from an interrupted run — `unset` it.
3. **A worktree with no sibling `../PormG.jl`** — `bash scripts/worktree_setup.sh` (§4).
4. **The environment was re-resolved and dropped a path dependency.** `Pkg.update("HTTP")` will do
   this: it re-resolves the *project* env, where `PormG` is only a weakdep, and prunes it without a
   word. `Pkg.test()` re-provisions it.

Related, and the reason (3) is easy to hit: after a `[compat]` bound is raised, `Pkg.resolve()`
**fails rather than upgrading** — it preserves versions, so a manifest still holding `HTTP@2.4.0`
against `HTTP = "~2.6"` dies with `empty intersection between HTTP@2.4.0 and project compatibility
2.6`. `scripts/worktree_setup.sh` now recovers from that by discarding the copied manifest and
resolving fresh; by hand, `Pkg.update("HTTP")` is what moves the pin.

### 4. PormG sibling checkout missing

`Project.toml` declares `[sources] PormG = {path = "../PormG.jl"}` and PormG is a **hard test
dependency**. Resolution fails without a sibling `../PormG.jl` checkout — CI clones one explicitly
before building.

Symptoms: `Pkg` resolver errors naming PormG, or every `:pormg` / `:extension` item erroring at load.
Fix: clone or symlink PormG next to the Nitro checkout. Note this also means **a worktree under
`.claude/worktrees/` does not have PormG as a sibling** — the relative path resolves to
`.claude/worktrees/PormG.jl`, which does not exist, so *every* Pkg operation fails before any test
runs. Fix it with `bash scripts/worktree_setup.sh`, which links the real clone into place (a
directory junction on Windows) and instantiates. Never point `[sources]` at an absolute path — that
change is committable and would break every other checkout.

### 5. Network and port-binding tests

Items tagged `:network` bind real sockets. Failure shapes:

- **A test answering from routes it never registered** — e.g. `precompilation_test.jl` receiving
  `"home"`, which `extractor_tests.jl` registers on the global router. This and *address already in
  use* are the same failure, and the mechanism ([#73](https://github.com/PingoLee/Nitro.jl/issues/73))
  is worth knowing because it presents as an unrelated assertion error in whichever item happened to
  be running. Before the fix, `terminate()` could hang forever: `HTTP.close(::Server)` releases the
  listener and then loops until every tracked connection is gone, force-closing only *idle* ones —
  and HTTP 2.4 never marks a connection `HIJACKED`, so a WebSocket/SSE/STREAM handler (or a
  `terminate()` called from *inside* a handler) pinned its connection `ACTIVE` and that loop never
  ended. With `nworkers = 0` — the default at the time — ReTestItems applies **no** per-item
  timeout, so the run wedged, someone killed it, and the orphaned child kept the port. On Windows
  `SO_REUSEADDR` then let the next run bind the *same* port alongside the corpse, splitting traffic
  between two routers instead of failing.
  Now: `terminate()` is a bounded drain then a force-close (`serve(shutdown_timeout=…)` /
  `terminate(timeout=…)`, default 10s), Nitro passes `reuseaddr=false` on Windows so a real conflict
  fails loudly, and `test/runtests.jl` runs `terminate()` in ReTestItems' `test_end_expr` after every
  item. If it recurs, check for an orphan from an older build (`netstat -ano | grep :<port>`), and
  whether something passed an explicit `reuseaddr=true`.
- **No test may use a fixed port.** `PORT`/`localhost` were deliberately removed from `NitroCommon` —
  a shared constant is what let one run's leftovers answer the next run. Call `get_free_port()` and
  build your own `localhost = "http://$HOST:$port"`.
- **Two suites at once** — a second `Pkg.test()` in another terminal or worktree. Still run one at a
  time: free ports remove the *fixed*-port collision, not contention for machine resources.
- **Connection refused right after `serve(async=true)`** — the server had not finished binding.
  Tests should wait on readiness rather than sleeping a fixed interval.
- Windows and macOS runners are slower to bind than Linux; a timeout tuned on Linux may be too tight.

### 6. `internalrequest` vs a live server

`internalrequest(req; context=…)` sets the app context on the **global** `CONTEXT[]`. If a live
server started by another test item is running in the same process, the two race and either can see
the other's context ([#31](https://github.com/PingoLee/Nitro.jl/issues/31)).

Symptom: a handler reads someone else's config, intermittently. Fix: use `instance(...)` or an
explicit `ServerContext`, and don't interleave `internalrequest(context=…)` with a running server.

### 7. `--workers N` is refused for N > 1

Workers are separate processes, so each gets its own `CONTEXT[]` and global router state is *not*
shared between them. That changes what every item sees: ~25 test files register routes on the global
and never reset, so an item asserting on 404 behaviour or on the total route set behaves differently
depending on which worker it landed on, and in what order.

The result is a spurious **pass or failure**, not a crash — evidence-shaped output that will not
reproduce under `Pkg.test()`. `test/runtests.jl` therefore **errors** on `--workers 2` rather than
warning, turning a silently-wrong result into a loud one. `--workers 0` (in-process, no per-item
timeout) and the default of 1 are unaffected.

The old diagnostic use — green under `--workers 2` but red in-process means an ordering dependency,
class 1 above — is still available, just not through the launcher:

```julia
julia> using ReTestItems, Nitro
julia> runtests("test/setup_tests.jl", "test/<file>.jl"; nworkers = 2)
```

The guard exists because router state is process-global. It comes out when
[#31](https://github.com/PingoLee/Nitro.jl/issues/31) lands and that stops being true.

### 8. Aqua and precompilation items

- `test/aqua_tests.jl` (`:aqua`) checks ambiguities, stale deps, and undefined exports. A new export
  in `src/Nitro.jl` with no definition, or a dep left in `Project.toml`, fails here — the message
  points at packaging, not logic.
- `test/precompilation_test.jl` catches work moved into a module body that must live in `__init__()`.
  If it fails after you added load-time wiring, that is the rule in the general instructions firing,
  not a flake.

---

## Diagnostic workflow

1. **Read the actual error**, not just the failed-item name — ReTestItems prints the item, file, and
   line.
2. **Run the file alone.** Green alone ⇒ suspect class 1 (ordering/global state).
3. **Vary thread count** (`-t 1` vs `-t 2`). A difference ⇒ class 2 (race).
4. **Check `TEST_FILES`** in `test/harness_manifest.jl` if the item never appears in the output
   at all — though `test/harness_tests.jl` should have failed first.
5. **Check the environment** — PormG sibling present, no orphaned server process, no second suite
   running.
6. **Only then bisect your diff.** `git stash` and confirm the failure predates your change before
   attributing it.
7. **Before claiming green, run what CI runs**: the full `Pkg.test()`, and at both thread counts if
   you touched anything concurrent.

---

## Anti-patterns

- Re-running a failing test until it passes and calling it flaky — thread-count failures are real
  races.
- Adding `sleep()` to fix a network timing failure instead of waiting on readiness.
- Adding a test file without adding it to `TEST_FILES` in `test/harness_manifest.jl` — it never
  runs. No longer silent (`test/harness_tests.jl` fails on it), but still your job to add.
- Replacing the ordered `TEST_FILES` list with `runtests(Nitro)`.
- Calling `resetstate()` inside an item to fix your own failure without checking what later items
  depend on.
- "Fixing" an ordering failure by reordering `TEST_FILES` when the real fix is to take the test off
  the global router (`instance(...)` or an explicit `ServerContext`).
- Reporting a suite as passing when only a tag subset was run — say which slice you ran.
