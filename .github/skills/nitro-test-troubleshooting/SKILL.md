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

# Parallel workers (separate processes — changes isolation, see below)
julia -t auto --project=. test/runtests.jl --workers 2

# Interactive REPL — setup_tests.jl MUST come first
julia> using ReTestItems, Nitro
julia> runtests("test/setup_tests.jl", "test/middleware/guards_tests.jl")
```

**Available tags:** `:core`, `:middleware`, `:auth`, `:security`, `:handler`, `:extension`,
`:pormg`, `:network`, `:scenario`, `:slow`, `:aqua`.

Useful combination when you only want fast feedback: exclude the network-bound items by selecting a
narrower tag rather than running everything.

---

## Known recurring failure classes

### 1. Global router state leaking across test items

**The single most common cause of "passes alone, fails in suite."**

`urlpatterns(...)` mutates the process-wide `CONTEXT[]` router (`src/Nitro.jl`, `src/methods.jl`).
Test items that register routes therefore affect every later item in the same process.

`test/runtests.jl` compensates with an **explicit, hand-ordered `TEST_FILES` list** and a comment
saying so. Consequences:

- **Do not** replace the list with `runtests(Nitro)` — filesystem-walk order differs and will produce
  spurious failures.
- **A new test file that is not added to `TEST_FILES` is silently skipped.** It will never run, never
  fail, and look like passing coverage. If a test you wrote "isn't running," check the list first.
  (Tracked as [#34](https://github.com/PingoLee/Nitro.jl/issues/34).)
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
args and the launcher's thread count (guarded by the `NITRO_TEST_REDISPATCH` env var). So the direct
commands work — but if you see this error anyway:

- You are running a test file *directly* (`julia --project=. test/foo_tests.jl`) instead of through
  `test/runtests.jl`. Go through the runner.
- Or `NITRO_TEST_REDISPATCH` is stale in your shell from an interrupted run — unset it.

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

- **Address already in use** — a previous run's server did not shut down. Look for an orphaned Julia
  process; `terminate()` is what tests should call in cleanup.
- **Two suites at once** — a second `Pkg.test()` in another terminal or worktree competing for the
  same fixed port. Run one at a time.
- **Connection refused right after `serve(async=true)`** — the server had not finished binding.
  Tests should wait on readiness rather than sleeping a fixed interval.
- Windows and macOS runners are slower to bind than Linux; a timeout tuned on Linux may be too tight.

### 6. `internalrequest` vs a live server

`internalrequest(req; context=…)` sets the app context on the **global** `CONTEXT[]`. If a live
server started by another test item is running in the same process, the two race and either can see
the other's context ([#31](https://github.com/PingoLee/Nitro.jl/issues/31)).

Symptom: a handler reads someone else's config, intermittently. Fix: use `instance(...)` or an
explicit `ServerContext`, and don't interleave `internalrequest(context=…)` with a running server.

### 7. `--workers N` changes isolation, and can hide or create failures

Workers are separate processes, so global router state is *not* shared between them. A suite that is
green with `--workers 2` but red in-process is telling you it has an ordering dependency (class 1),
not that the in-process run is broken. Reproduce failures with the same worker setting CI used.

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
4. **Check `TEST_FILES`** if the item never appears in the output at all.
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
- Adding a test file without adding it to `TEST_FILES` — it silently never runs.
- Replacing the ordered `TEST_FILES` list with `runtests(Nitro)`.
- Calling `resetstate()` inside an item to fix your own failure without checking what later items
  depend on.
- "Fixing" an ordering failure by reordering `TEST_FILES` when the real fix is to take the test off
  the global router (`instance(...)` or an explicit `ServerContext`).
- Reporting a suite as passing when only a tag subset was run — say which slice you ran.
