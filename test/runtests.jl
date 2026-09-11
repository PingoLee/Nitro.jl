# ── Bootstrap test-only dependencies ──────────────────────────────────────────
# Test-only deps (Suppressor, ProtoBuf, PormG, …) live in `[extras]` /
# `[targets].test`, so they are on the load path only under `Pkg.test()`. When this
# file is run directly — `julia --project=. test/runtests.jl <args>` — they are
# missing and every test item errors with "Package X not found in current path".
# Detect that case and re-dispatch through `Pkg.test` once, forwarding the CLI
# args, so all the documented commands below work without extra ceremony.
#
# PROBE EVERY TARGET, NOT ONE OF THEM (#128). This used to ask a single question --
# `Base.identify_package("Suppressor") === nothing` -- and treat the answer as "am I
# in the test environment?". That is a PROXY, and `Base.identify_package` searches the
# whole `LOAD_PATH`, including the user's global `@v#.#` environment. So on a machine
# with `Suppressor` installed globally the probe answered "already provisioned", the
# re-dispatch never fired, and the run proceeded with the registry packages resolving
# from the global env while `PormG` -- a `[sources]` path dep, which can never be
# globally installed -- stayed missing.
#
# That combination is the one that does not announce itself. A missing `ReTestItems`
# kills the run on line 1; a missing `PormG` only makes `extensions/pormg_worker_tests.jl`
# take its skip branch, so 112 assertions vanish and the run still exits 0.
#
# Reading `[targets].test` keeps the probe honest by construction: adding a test
# dependency to `Project.toml` extends this check with no edit here.
#
# `Pkg.TOML`, not the `TOML` stdlib: under `Pkg.test` the temporary test environment
# declares only `[targets].test`, and an stdlib that is not among them is NOT importable
# there. `Pkg` is on that list. (`test/revise_test.jl` reaches TOML the same way.)
import Pkg
let project_file = joinpath(@__DIR__, "..", "Project.toml"),
    project = Pkg.TOML.parsefile(project_file)

    targets = String[string(p) for p in get(get(project, "targets", Dict{String,Any}()),
                                            "test", String[])]
    missing_deps = filter(p -> Base.identify_package(p) === nothing, targets)

    # "Have I already re-dispatched?" asked two ways, because the env var alone is a flag
    # the PARENT sets and `Pkg.test()` does not. Invoked as `Pkg.test()` directly, the var
    # is unset -- so a dependency unresolvable inside the temp env would make this spawn a
    # SECOND `Pkg.test` from inside the first, and report that mess instead of the refusal
    # written below. The active project is the durable signal: under `Pkg.test` it is a
    # temporary environment, never this repo's own `Project.toml`.
    #
    # `samefile`, not string comparison. The two paths are built from different sources --
    # `active` from however `--project` was spelled, `project_file` from `@__DIR__` -- so
    # comparing text asks whether they were TYPED alike, when the question is whether they
    # ARE the same file. On Windows that is case-insensitive, and this repo reaches its
    # worktrees through directory junctions, either of which makes equal files compare
    # unequal and turn a normal run into a refusal. `samefile` compares device + inode and
    # returns false (rather than throwing) when a path does not exist.
    # Named for what it actually tests. It is true for ANY active project that is not this
    # repo's -- a `Pkg.test` temp env, the global `@v#.#` env, an unrelated project -- so a
    # name like `in_test_env` would license the message below to assert "you are under
    # Pkg.test", which is exactly the wrong thing to tell someone who simply forgot
    # `--project=.`.
    active = Base.active_project()
    active_is_not_ours = active === nothing ||
                         !Base.Filesystem.samefile(active, project_file)
    redispatched = get(ENV, "NITRO_TEST_REDISPATCH", "0") != "0" || active_is_not_ours

    if !isempty(missing_deps)
        if !redispatched
            withenv("NITRO_TEST_REDISPATCH" => "1") do
                # Forward this launcher's thread count to the test subprocess, so
                # `julia -t auto … runtests.jl` still runs test items multithreaded
                # after the re-dispatch (relevant for in-process runs, i.e. no --workers).
                Pkg.test(; test_args = ARGS, julia_args = `-t $(Threads.nthreads())`)
            end
            exit(0)
        end

        # Already inside `Pkg.test` and a declared test dependency is STILL missing.
        # That is an environment bug, not a valid configuration -- and it must not be
        # allowed to degrade quietly into a shorter suite. Refuse before a single item
        # runs. This costs nobody a run they could otherwise have had: without a sibling
        # `../PormG.jl` every Pkg operation already dies at resolve time.
        error(
            "Nitro test environment is incomplete.\n\n" *
            "Missing declared `[targets].test` dependencies:\n" *
            join(("  - $p" for p in missing_deps), "\n") * "\n\n" *
            # Print both, always. Which environment is live is the single most useful fact
            # here and the one the caller cannot see -- and when the two differ, that IS
            # the diagnosis rather than any of the causes listed below.
            "Active project: " * (active === nothing ? "(none)" : active) * "\n" *
            "Expected:       " * abspath(project_file) * "\n\n" *
            "Refusing to run. A suite missing a test dependency does not fail -- it runs\n" *
            "SHORT and still exits 0, because the items behind that dependency skip\n" *
            "instead of erroring. That is #128, and it hid 112 assertions.\n\n" *
            "Likely causes:\n" *
            # First, because it is the only one a reader can confirm from the two lines
            # directly above, and because "every single target is missing" -- rather than a
            # subset -- is the tell. Omitting it made this message confidently misdiagnose
            # the most ordinary mistake there is.
            "  * No Nitro environment is active -- you ran without `--project=.`. That is\n" *
            "    this message when the two paths above differ and EVERY target is listed.\n" *
            "  * `NITRO_TEST_REDISPATCH` is stale in your shell from an interrupted run.\n" *
            "    Unset it and re-run.\n" *
            "  * A worktree with no sibling `../PormG.jl`: `bash scripts/worktree_setup.sh`.\n" *
            "  * The environment was re-resolved (`Pkg.update`, `Pkg.resolve`) and dropped a\n" *
            "    path dependency. `Pkg.test()` re-provisions it."
        )
    end
end

using ReTestItems
using Nitro

# ── Run all tests ─────────────────────────────────────────────────────────────
#
#   Pkg.test()
#   julia --project=. test/runtests.jl
#
# ── Run a single file or directory (CLI) ──────────────────────────────────────
#
#   julia --project=. test/runtests.jl test/sessionstores_tests.jl
#   julia --project=. test/runtests.jl test/middleware/guards_tests.jl
#   julia --project=. test/runtests.jl test/middleware/
#
# ── Filter by name or tag (CLI) ───────────────────────────────────────────────
#
#   julia --project=. test/runtests.jl --tags core
#   julia --project=. test/runtests.jl --name "Session stores"
#
# ── Interactive REPL (single file) ────────────────────────────────────────────
#
#   $ julia --project=.        (or: julia; pkg> activate .)
#   julia> using ReTestItems, Nitro
#   julia> runtests("test/setup_tests.jl", "test/sessionstores_tests.jl")
#   julia> runtests("test/setup_tests.jl", "test/middleware/guards_tests.jl")
#
#   NOTE: setup_tests.jl must always be included first — it defines the
#   NitroCommon @testsetup that most test items depend on.
#   When using the CLI (runtests.jl), setup_tests.jl is prepended automatically.
#
# -- Shared harness metadata --------------------------------------------------
# `TEST_FILES` (the ordered run list) and `KNOWN_TAGS` (the tag vocabulary) live in
# `harness_manifest.jl`, because `test/harness_tests.jl` must read the SAME objects to
# check they are honest -- and that guard runs as a `@testitem`, in a worker process where
# this file was never loaded. The header of that file explains why a guard that instead
# text-parsed this one could pass while being wrong.
#
# The list is still hand-ordered and still must not become `runtests(Nitro)`: several items
# mutate the global Nitro router via `urlpatterns(...)`, so execution order is load-bearing.
# #31 is the design issue that would make it stop being load-bearing.
include(joinpath(@__DIR__, "harness_manifest.jl"))
using .NitroTestHarness: TEST_FILES, KNOWN_TAGS, discover_test_files, testitems


# ── Per-item cleanup net ───────────────────────────────────────────────────────
# ReTestItems evaluates this in a `finally` after EVERY test item, whether it passed,
# failed, or errored — including in-process runs. That makes it strictly better than
# per-item `try`/`finally`: it also covers items that never call `terminate()` at all,
# and it still runs when an exception escapes an item's own cleanup.
#
# Why it matters: an item that throws between `serve()` and its trailing `terminate()`
# used to leave the listener bound for the life of the process, so the *next* item — or
# the next `Pkg.test()` run — got answers from a server it never started.
#
# `terminate()` is a cheap no-op when nothing is serving. Items that use their own
# `ServerContext`/`instance()` are NOT covered by this (it only reaches the global
# `CONTEXT[]`) and must still clean up after themselves.
const TEST_END = quote
    using Nitro
    # Swallow-and-report, never rethrow. ReTestItems evaluates this as
    # `try <item> finally <test_end_expr> end`, so an exception raised here REPLACES the
    # item's own failure — you would be told the cleanup broke and never learn which
    # assertion did. Cleanup is best-effort by definition; the item's result is the signal.
    try
        Nitro.terminate()
    catch err
        @error "test_end_expr: terminate() failed; a later :network item may hit a bound port" exception=err
    end
end

# ── CLI argument parsing ───────────────────────────────────────────────────────
# Supports (test deps are auto-provisioned via the bootstrap block above):
#   julia --project=. test/runtests.jl test/sessionstores_tests.jl
#   julia --project=. test/runtests.jl --tags core --name "Session stores"
#   julia -t auto --project=. test/runtests.jl                 # in-process, multithreaded
#   julia --project=. test/runtests.jl --workers 0             # in-process (no timeouts)
#   julia --project=. test/runtests.jl test\middleware\ratelimitter_lru_tests.jl
#
#   Flags: --tags <tag>   filter by @testitem tag. REPEATABLE and AND-combined --
#                         ReTestItems matches `issubset(requested, item.tags)`, so
#                         `--tags core --tags network` means BOTH, not either.
#          --name <name>  EXACT @testitem name, NOT a substring: ReTestItems compares
#                         `name == ti.name`. This comment said "substring" for a long
#                         time and was wrong (#34).
#          --workers <n>  0 or 1 only; >1 is refused, see the guard after the arg loop.
#
#   A filter that selects nothing is an error. ReTestItems already throws its own
#   `NoTestException("No test items found.")` in that case, so this is about the MESSAGE,
#   not about catching a silent pass: the guard below names the tag vocabulary and the
#   AND/exact-match semantics, which is what you actually need to know.
#   Bare paths select files/dirs; Windows (\) and POSIX (/) separators both work.
#
#   Threads vs workers: test items always run in a worker process now (one by default),
#   because ReTestItems applies `testitem_timeout` only when `nworkers > 0` -- see the
#   `runtests` call below. The launcher's `-t` is forwarded to the worker through
#   `nworker_threads`, so `julia -t auto ... runtests.jl` still runs items multithreaded
#   and CI's `JULIA_NUM_THREADS: 1` leg still runs them on one thread. `--workers 0` opts
#   back in to the old in-process mode for debugging, at the cost of per-item timeouts.
#   Running under `--code-coverage` also forces in-process, for the same reason -- see the
#   `runtests` call for why coverage and worker timeouts cannot both be had.
let args = copy(ARGS)
    paths     = String[]
    tags      = Symbol[]
    name_filt = nothing
    nworkers  = -1   # sentinel: `--workers` not given (see the `runtests` call below)

    while !isempty(args)
        a = popfirst!(args)
        if a == "--tags" && !isempty(args)
            push!(tags, Symbol(popfirst!(args)))
        elseif a == "--name" && !isempty(args)
            name_filt = popfirst!(args)
        elseif a == "--workers" && !isempty(args)
            nworkers = parse(Int, popfirst!(args))
        elseif !startswith(a, "--")
            a = replace(a, '\\' => '/')   # accept Windows-style separators on any OS
            push!(paths, isabspath(a) ? a : joinpath(@__DIR__, "..", a))
        end
    end

    # `--workers N` for N > 1 is REFUSED, not merely discouraged (#34).
    #
    # ReTestItems distributes items across worker PROCESSES in a non-deterministic order,
    # and each worker gets its own `Nitro.CONTEXT[]`. This suite's isolation is the
    # hand-ordered TEST_FILES sequence plus one shared, accumulating router: ~25 test files
    # register routes on the global and never reset, 5 call `resetstate()`, and `TEST_END`
    # only calls `terminate()`. Split those across processes and an item asserting on 404
    # behaviour, or on the total route set, sees a router it would not see under the
    # default run.
    #
    # The result is a spurious PASS or a spurious FAILURE, not a crash -- so a warning
    # would leave a mode running that manufactures evidence. Refusing converts a rung-2
    # defect (silently wrong) into a rung-3 one (loud), which is the whole trade.
    #
    # The diagnostic use documented in nitro-test-troubleshooting §7 is still available,
    # just not through this launcher: call `ReTestItems.runtests` directly with `nworkers`.
    #
    # Delete this guard when #31 lands and router state stops being process-global.
    # `--workers 0` (in-process; also forced by --code-coverage) and the default of 1 are
    # unaffected -- both keep every item in one process, in TEST_FILES order.
    if nworkers > 1
        error(
            "--workers $nworkers is not supported.\n\n" *
            "The suite shares one process-global `Nitro.CONTEXT[]` and depends on the\n" *
            "hand-ordered TEST_FILES sequence, so splitting items across processes\n" *
            "silently changes what each item sees -- a spurious pass or failure that\n" *
            "will not reproduce under `Pkg.test()`. Tracked as #34; the durable fix\n" *
            "is #31.\n\n" *
            "Use `--workers 0` (in-process, no per-item timeout), or omit the flag."
        )
    end

    if isempty(paths)
        paths = [joinpath(@__DIR__, f) for f in TEST_FILES]
    else
        # Always prepend setup_tests.jl so NitroCommon @testsetup is available.
        setup = joinpath(@__DIR__, "setup_tests.jl")
        if setup ∉ paths
            pushfirst!(paths, setup)
        end
    end

    # Explain a zero-selection filter instead of just reporting one (#34).
    #
    # ReTestItems does NOT pass silently here -- `runtests` throws
    # `NoTestException("No test items found.")` once AST filtering leaves nothing. #34
    # claimed otherwise ("ReTestItems reports that as a successful empty run"); that was
    # checked against the shipped package and is false. What the bare exception does not
    # tell you is WHY, and the three ways to get there are all easy to hit by accident:
    # a mistyped tag, an AND-combined pair with an empty intersection, and a `--name` that
    # is a substring rather than the exact item name.
    #
    # So this is a message-quality guard, and it is deliberately kept anyway: `--tags
    # workers` used to fail with "No test items found." and no hint that `:workers` simply
    # was not a tag anyone had applied.
    #
    # It cannot be a @testitem -- the same filter would delete the guard -- so it lives in
    # the coordinator, which is also the only place that can name the vocabulary.
    if !isempty(tags) || !isnothing(name_filt)
        unknown = setdiff(Set(tags), KNOWN_TAGS)
        isempty(unknown) || error(
            "Unknown test tag(s): $(join(sort!(collect(unknown)), ", ")).\n" *
            "Known tags: $(join(sort!(collect(KNOWN_TAGS)), ", ")).\n\n" *
            "A tag matching no @testitem would fail anyway, with ReTestItems'\n" *
            "`No test items found.` -- this message exists to name the vocabulary\n" *
            "instead. `KNOWN_TAGS` lives in test/harness_manifest.jl and is checked\n" *
            "against the suite by test/harness_tests.jl."
        )

        # A mistyped path must not be reported as a filter problem. Without this, a bad
        # path contributes zero items and the user is sent to debug a filter that is fine.
        # `validate_paths = true` on the `runtests` call catches it too, but only later.
        scan = String[]
        for p in paths
            if isdir(p)
                append!(scan, joinpath.(p, discover_test_files(p)))
            elseif isfile(p)
                push!(scan, p)
            else
                error("No such test path: $p")
            end
        end
        selected = 0
        for f in scan
            isfile(f) || continue
            for (nm, tg) in testitems(f)
                (isempty(tags) || issubset(tags, tg)) || continue
                (isnothing(name_filt) || nm == name_filt) || continue
                selected += 1
            end
        end
        selected == 0 && error(
            "This filter selects 0 test items. ReTestItems would fail with the less\n" *
            "specific `No test items found.`; the likely cause is one of these:\n" *
            "  --tags $(isempty(tags) ? "(none)" : join(tags, " "))\n" *
            "  --name $(something(name_filt, "(none)"))\n\n" *
            "`--tags` are AND-combined, not OR. `--name` is an EXACT @testitem name,\n" *
            "not a substring."
        )
    end

    # `testitem_timeout` is applied ONLY on the worker path -- ReTestItems documents this
    # itself ("Note timeouts are currently only applied when `nworkers > 0`"), and the
    # `Timer` that enforces it lives inside `manage_worker`. The in-process path runs items
    # in a plain loop with no timer at all. So under the old `nworkers = 0` default -- which
    # is how both `Pkg.test()` and CI invoke this file -- the `testitem_timeout` below was
    # dead configuration, and a hung item hung the entire run with no ceiling (#84).
    #
    # That is worse than merely unbounded. The observed failure was a wedged run that had to
    # be killed, whose orphaned child kept a port bound, which then broke the NEXT run's
    # `:network` items as an unrelated-looking assertion failure.
    #
    # One worker, not more: items stay sequential in a single process, which is what the
    # hand-ordered `TEST_FILES` list above depends on -- several items mutate the global
    # router via `urlpatterns`.
    #
    # `nworker_threads` must be passed explicitly. ReTestItems defaults it to "2", so
    # omitting it would silently run every item on two threads and quietly delete CI's
    # `JULIA_NUM_THREADS: 1` leg -- the one that exists to catch thread-count-dependent
    # races. Forwarding the launcher's own thread count keeps `-t` meaningful.
    #
    # ...but a worker cannot produce coverage, so the two are mutually exclusive.
    # ReTestItems' `terminate!` (workers.jl) always ends a worker with SIGTERM, escalating
    # to SIGINT/SIGKILL -- there is no clean-exit path -- and Julia writes `.cov` files only
    # on a clean exit. So on Linux the worker's coverage is discarded, and the run reports
    # only what the coordinator itself executed: ~0.3% instead of ~86%. (Windows survives
    # it, because `kill` there is `TerminateProcess` with different teardown -- the same
    # platform split that function documents inline. CI measures coverage on ubuntu.)
    #
    # Coverage therefore wins in the one job that collects it, and timeouts win everywhere
    # else. That is the right way round: exactly one CI job runs with `--code-coverage`,
    # and the other seven keep a per-item ceiling, so a hang is still caught -- just not by
    # the coverage job.
    covering = Base.JLOptions().code_coverage != 0
    runtests(
        paths...;
        # THE silent zero-test hole, and the one #34 was really looking for.
        #
        # This defaults to `false`, and then `_validated_paths` only `@warn`s on "No such
        # path" / "is not a test file" and DROPS the path. Give one good path and one
        # typo, and the run is green having never executed the file you asked for:
        #
        #   $ julia --project=. test/runtests.jl test/harness_tests.jl test/middlware/guards_tests.jl
        #   Warning: No such path ".../test/middlware/guards_tests.jl"
        #   [ Tests Completed: 1/1 test items were run.
        #        Testing Nitro tests passed
        #
        # (Worse, when EVERY path is invalid `runtests` returns `nothing` outright.) With
        # `true`, each of those becomes a throw. This is the path-axis twin of the
        # unlisted-file defect `test/harness_tests.jl` guards on the TEST_FILES axis.
        validate_paths = true,
        testitem_timeout = 600,
        test_end_expr = TEST_END,
        nworkers = covering ? 0 : (nworkers < 0 ? 1 : nworkers),
        nworker_threads = string(Threads.nthreads()),
        tags     = isempty(tags) ? nothing : tags,
        name     = isnothing(name_filt) ? nothing : name_filt,
    )
end
