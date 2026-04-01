# Plan: Migrate Nitro.jl Tests to ReTestItems.jl + Aqua.jl

## Summary

Adopt `ReTestItems.jl` for ordered test execution, isolation, progress reporting, and optional parallel execution. Add `Aqua.jl` as a separate structural quality check inside the test suite.

The migration should be done in two passes:

1. **Parity pass**: preserve current behavior with minimal churn, aiming for green `Pkg.test()` first.
2. **Performance pass**: split large files into smaller `@testitem`s and make network-bound tests parallel-safe.

This is safer than converting every nested `@testset` into its own `@testitem` immediately.

---

## Key decisions

- Drop `module XxxTests ... end` wrappers as files are converted. Each `@testitem` already runs in an isolated module.
- Do **not** assume all current tests are parallel-safe. Any test that calls `serve(...)`, `HTTP.get(...)`, or binds a fixed port must be audited first.
- Keep nested `@testset`s inside each `@testitem` during the first pass. That preserves current grouping and reduces migration risk.
- Keep `test/constants.jl` and `test/test_utils.jl` for compatibility. `test/common_setup.jl` currently depends on `test/test_utils.jl`, and some standalone test workflows still expect these files to exist.
- Treat `Aqua.jl` as complementary to behavioral tests. It should be added early, but some checks may need explicit configuration if they surface pre-existing package issues.
- Be precise about concurrency: `ReTestItems.jl` parallelism uses multiple Julia worker processes for test execution. This is a test-runner choice, not a change to Nitro's runtime architecture.

---

## Goals

1. Replace the include-based `test/runtests.jl` orchestration with an explicit ordered `ReTestItems` file list.
2. Keep `Pkg.test()` as the default verification entrypoint.
3. Add an Aqua quality gate to catch structural issues such as ambiguities, stale deps, and export mistakes.
4. Preserve the current REPL-oriented test workflow in `test/common_setup.jl`.
5. Enable parallel test runs only after network-bound tests stop sharing fixed ports.
6. Support targeted runs by file, tag, and test-item name without renaming the existing test files.

---

## Phase 1 - Dependencies

1. Add `ReTestItems` and `Aqua` to the root `Project.toml` under `[extras]` and include them in `[targets].test`.
2. Add `ReTestItems` and `Aqua` to `test/dev_project/Project.toml` under `[deps]` so the REPL dev environment can run the same test helpers and test items.
3. Do not change runtime dependencies in `src/`; these packages are test-only.

---

## Phase 2 - Shared test infrastructure

Create a new `test/setup.jl` with a shared `@testsetup module NitroCommon` that provides:

- `using Test, HTTP, Nitro, Dates, JSON, UUIDs`
- Common constants currently defined in `test/constants.jl`
- Common helper functions currently defined in `test/test_utils.jl`
- A `get_free_port()` helper for tests that need a real listening server
- Optional small lifecycle helpers if they reduce duplicated `serve(...)` / `terminate()` / `resetstate()` patterns

Notes:

- Keep `test/constants.jl` and `test/test_utils.jl` in place during the migration.
- `test/common_setup.jl` should continue to work without requiring immediate rewrites.
- If useful, `test/common_setup.jl` can later include `setup.jl`, but that is a follow-up cleanup, not a blocker for the migration.

---

## Phase 3 - Runner conversion

1. Replace `test/runtests.jl` with a ReTestItems entrypoint that preserves the current include order explicitly.

```julia
using ReTestItems

const TEST_FILES = [
	"securitytests.jl",
	"extensions/timezonetests.jl",
	"extensions/templatingtests.jl",
	"extensions/protobuf/protobuftests.jl",
	"extensions/cryptotests.jl",
	"ssetests.jl",
	"websockettests.jl",
	"streamingtests.jl",
	"handlertests.jl",
	# ... keep the full current order from test/runtests.jl
]

run_all_tests(; kwargs...) = runtests(TEST_FILES; kwargs...)

if get(ENV, "NITRO_TEST_SKIP_AUTO", "0") != "1"
	run_all_tests()
end
```

2. Add `test/aqua_tests.jl` with a single `@testitem` that runs `Aqua.test_all(Nitro)`.
3. Append `"aqua_tests.jl"` to the ordered file list so Aqua runs at a predictable point in the suite.
4. Keep the initial runner configuration simple. Let `Pkg.test()` run with the ordered ReTestItems list first, then tune local parallel execution separately.
5. Do not rely on filename auto-discovery in the first migration. The current names should remain unchanged unless there is a separate cleanup pass later.

---

## Phase 4 - Parity migration of test files

Convert the suite file-by-file, not testset-by-testset.

For the **first pass**, the default pattern should be:

1. Remove the outer `module XxxTests ... end` wrapper.
2. Add one `@testitem` per file or per top-level scenario.
3. Keep existing nested `@testset` blocks inside the item.
4. Add tags to each top-level `@testitem` during conversion so targeted runs are available immediately.
5. Replace `using ..Constants` and similar include-chain assumptions with `setup=[NitroCommon]` or a file-local `@testsetup` module where needed.
6. Use a file-local `@testsetup` module for files with shared app/server state, such as multi-instance or long-lived server setup.

This keeps the first migration focused on compatibility rather than maximum parallelism.

---

## Phase 4.5 - Tagging strategy

Add tags in the first pass, not later. That gives immediate value even before the suite is fully parallel-safe.

Recommended tag set:

- `:security`
- `:extension`
- `:handler`
- `:core`
- `:auth`
- `:middleware`
- `:scenario`
- `:network`
- `:parallel_safe`
- `:slow`
- `:aqua`

Tagging rules:

1. Every converted file should get at least one domain tag, such as `:auth` or `:middleware`.
2. Any file that starts a real server or uses `HTTP.get(...)` should get `:network` until proven parallel-safe.
3. Only add `:parallel_safe` after the file passes repeated multi-worker runs without port or state collisions.
4. Use `:slow` for long-running scenario or streaming tests.
5. Tag the Aqua item with `:aqua` so it can be included or excluded explicitly.

Examples:

```julia
@testitem "auth module" tags=[:auth, :core] setup=[NitroCommon] begin
	@testset "..." begin
		# existing tests
	end
end

@testitem "websocket" tags=[:handler, :network, :slow] setup=[NitroCommon] begin
	@testset "..." begin
		# existing tests
	end
end
```

---

## Phase 5 - Parallel-safety audit and second-pass splitting

After the suite is green under ReTestItems, audit files for true parallel safety.

### Tests that are likely already easy to parallelize

- Pure helper or API tests that do not call `serve(...)`
- Tests that only use `internalrequest(...)` without booting a real server
- Files with no shared global app state and no fixed-port assumptions

### Tests that need explicit port/state work before parallel execution

- Any file that calls `serve(...)` on `PORT`, `PORT + 1`, or another hardcoded port
- Any file that uses `HTTP.get(...)` against `localhost`
- Any file that depends on global Nitro state that must be reset between cases

Representative files that should be treated as network/stateful until verified otherwise:

- `test/appcontexttests.jl`
- `test/instancetests.jl`
- `test/routingtests.jl`
- `test/spatests.jl`
- `test/ssetests.jl`
- `test/streamingtests.jl`
- `test/websockettests.jl`
- `test/scenarios/thunderingherd.jl`
- Middleware tests that boot servers under `test/middleware/`

Second-pass optimization rules:

1. Replace fixed ports with `get_free_port()` or an equivalent per-item allocation helper.
2. Split only the files that are slow enough to benefit from more granular `@testitem`s.
3. Prefer splitting files whose cases are independent and inexpensive to set up.
4. Avoid over-splitting stateful files if each item would need expensive server/bootstrap work.
5. Preserve explicit ordered execution in `TEST_FILES` even after adding more granular items, unless there is a deliberate decision to loosen ordering.

---

## Phase 6 - Special cases to validate during migration

- `@oxidize` is currently used at top level in some tests. Validate case-by-case that it behaves correctly when moved into a `@testitem` context.
- Extension tests under `test/extensions/` may need their own setup expectations because they trigger weak dependencies.
- Scenario tests and middleware subtree tests should be migrated deliberately, because they are currently included transitively by `test/runtests.jl` and may have stronger assumptions about load order.
- `test/routingfunctionstests.jl` exists in the tree but is **not** included by the current `test/runtests.jl`. Decide explicitly whether to migrate it, retire it, or keep it out of scope. Do not silently add it to the active suite during this migration.

---

## Phase 7 - Verification

Run verification in this order:

1. `julia --project -e 'using Pkg; Pkg.test()'`
2. `julia --project -e 'using ReTestItems; ENV["NITRO_TEST_SKIP_AUTO"] = "1"; include("test/runtests.jl"); run_all_tests(nworkers=1)'`
3. `julia --project -e 'using ReTestItems; ENV["NITRO_TEST_SKIP_AUTO"] = "1"; include("test/runtests.jl"); run_all_tests(nworkers=4)'`
4. `julia --project -e 'using ReTestItems; ENV["NITRO_TEST_SKIP_AUTO"] = "1"; include("test/runtests.jl"); runtests(["auth_tests.jl"]; nworkers=1)'`
5. `julia --project -e 'using ReTestItems; ENV["NITRO_TEST_SKIP_AUTO"] = "1"; include("test/runtests.jl"); runtests(TEST_FILES; tags=[:auth])'`

Verification goals:

- `Pkg.test()` remains the primary entrypoint and passes
- ReTestItems executes the full intended suite in the explicit order from `TEST_FILES`
- Parallel runs complete without port collisions or state leakage
- Targeted runs by file and tag work without renaming legacy test files
- Aqua reports useful quality findings

For Aqua:

- Start with `Aqua.test_all(Nitro)`
- If it fails on existing package issues, either fix the issue or add narrow, documented exclusions
- Do not blindly mark the entire Aqua item as broken

---

## Scope boundaries

- No changes to Nitro runtime architecture are required for this migration.
- No `Distributed` or production multi-process features should be introduced in `src/`.
- No routing API changes are part of this plan.
- Legacy helper files should not be deleted until all direct workflows and scripts have been migrated.
- The first pass should optimize for correctness and maintainability, not maximum theoretical concurrency.
- Existing test filenames should remain unchanged in this migration.

---

## Targeted execution outcomes

After this plan is implemented, the intended workflows should be:

1. Run the full suite with visible progress via `Pkg.test()`.
2. Run the full suite in the current explicit order via `run_all_tests()`.
3. Run a specific file by passing a subset of `TEST_FILES`, such as `runtests(["auth_tests.jl"])`.
4. Run a specific category through tags, such as `runtests(TEST_FILES; tags=[:middleware])`.
5. Run a specific item by exact name or regex when deeper splitting is introduced later.

---

## Active suite checklist

### Root test runner and shared infrastructure

- [ ] `test/runtests.jl`
- [ ] `test/setup.jl` *(new)*
- [ ] `test/aqua_tests.jl` *(new)*

### Core suite currently included by `test/runtests.jl`

- [ ] `test/securitytests.jl`
- [ ] `test/ssetests.jl`
- [ ] `test/websockettests.jl`
- [ ] `test/streamingtests.jl`
- [ ] `test/handlertests.jl`
- [ ] `test/utiltests.jl`
- [ ] `test/cookiestests.jl`
- [ ] `test/sessiontests.jl`
- [ ] `test/sessionstores_tests.jl`
- [ ] `test/workerstests.jl`
- [ ] `test/test_reexports.jl`
- [ ] `test/precompilationtest.jl`
- [ ] `test/extractortests.jl`
- [ ] `test/rendertests.jl`
- [ ] `test/bodyparsertests.jl`
- [ ] `test/ergonomics_tests.jl`
- [ ] `test/oxidise.jl`
- [ ] `test/instancetests.jl`
- [ ] `test/paralleltests.jl`
- [ ] `test/middlewaretests.jl`
- [ ] `test/appcontexttests.jl`
- [ ] `test/path_prefix_tests.jl`
- [ ] `test/routingtests.jl`
- [ ] `test/originaltests.jl`
- [ ] `test/spatests.jl`
- [ ] `test/dx_tests.jl`
- [ ] `test/auth_module_tests.jl`
- [ ] `test/auth_tests.jl`
- [ ] `test/revise.jl`

### Extension suite currently included by `test/runtests.jl`

- [ ] `test/extensions/timezonetests.jl`
- [ ] `test/extensions/templatingtests.jl`
- [ ] `test/extensions/protobuf/protobuftests.jl`
- [ ] `test/extensions/cryptotests.jl`

### Scenario suite currently included by `test/runtests.jl`

- [ ] `test/scenarios/thunderingherd.jl`

### Middleware subtree currently included by `test/runtests.jl`

- [ ] `test/middleware/extract_ip_tests.jl`
- [ ] `test/middleware/ratelimitter_tests.jl`
- [ ] `test/middleware/ratelimitter_lru_tests.jl`
- [ ] `test/middleware/authmiddleware_tests.jl`
- [ ] `test/middleware/cors_middleware_tests.jl`
- [ ] `test/middleware/lifecycle_middleware_tests.jl`
- [ ] `test/middleware/session_middleware_tests.jl`
- [ ] `test/middleware/guards_tests.jl`

### Compatibility files to keep during migration

- [ ] `test/constants.jl` *(keep for compatibility during migration)*
- [ ] `test/test_utils.jl` *(keep for compatibility during migration)*
- [ ] `test/common_setup.jl` *(verify REPL workflow still works)*

### Out-of-scope until explicitly decided

- [ ] `test/routingfunctionstests.jl` *(exists but is not currently included by `test/runtests.jl`)*
