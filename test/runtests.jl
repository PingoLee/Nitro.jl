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
# That combination is the one that does not announce itself. A missing `Suppressor`
# errors every item that loads it; a missing `PormG` only made `extensions/pormg_worker_tests.jl`
# take its skip branch, so 112 assertions vanished and the run still exited 0.
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
                # Forward this launcher's thread layout -- default AND interactive pools --
                # to the test subprocess, which hands the same layout on to the child that
                # runs the items. `-t N` alone would turn `-t 2,0` into 2,1.
                threads = "$(Threads.nthreads(:default)),$(Threads.nthreads(:interactive))"
                Pkg.test(; test_args = ARGS, julia_args = `--threads=$threads`)
            end
            exit(0)
        end

        # Already inside `Pkg.test` and a declared test dependency is STILL missing.
        # That is an environment bug, not a valid configuration -- and it must not be
        # allowed to degrade quietly into a shorter suite. Refuse before a single item
        # runs. This costs nobody a run they could otherwise have had: if the environment
        # could not be provisioned, `Pkg.test` already failed before reaching this point.
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
            "  * A checkout or worktree that has never been instantiated, or a cold depot with\n" *
            "    no network -- `[sources]` fetches the pinned PormG commit from GitHub.\n" *
            "    Run: bash scripts/worktree_setup.sh\n" *
            "  * The environment was re-resolved (`Pkg.update`, `Pkg.resolve`) and dropped the\n" *
            "    weak dependency. `Pkg.test()` re-provisions it."
        )
    end
end

# ── The runner ────────────────────────────────────────────────────────────────
# `test/runner/` is Nitro's own `@testitem` runner (#754). It accepts the syntax ReTestItems
# defined, unchanged, and runs every selected item SEQUENTIALLY in ONE child process, under a
# watchdog parent that kills the child when an item runs past its timeout. Its header says what
# it deliberately does not do (parallel items, retries, a process per item).
#
# `NitroTestHarness` -- `TEST_FILES` (the files the suite is made of) and `KNOWN_TAGS` (the tag
# vocabulary) -- lives in `harness_manifest.jl`, because `test/harness_tests.jl` must read the
# SAME objects to check they are honest, and that guard runs as an item, in a fresh module
# where this file's bindings are not visible. The runner includes it, so there is one copy.
include(joinpath(@__DIR__, "runner", "NitroTestRunner.jl"))
using .NitroTestRunner
using .NitroTestRunner.NitroTestHarness: TEST_FILES, KNOWN_TAGS

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
# ── Exclude by tag (CLI) ──────────────────────────────────────────────────────
#
#   julia --project=. test/runtests.jl --skip-tags network --skip-tags slow
#   julia --project=. test/runtests.jl --tags middleware --skip-tags network
#
# The first is the fast, socket-free pass over the WHOLE suite -- the thing honest
# `:network`/`:slow` tags are actually for, and what `--tags` alone can never express
# (#214). See the `--skip-tags` entry in the Flags block below for the semantics.
#
# ── Order check (CLI) ─────────────────────────────────────────────────────────
#
#   julia --project=. test/runtests.jl --shuffle 1234
#
# Not yet a gate: several items mutate the global router and never reset it, so a red here
# can be an order dependence rather than a regression. #755 removes that and puts this
# check in CI; until then it is run by hand, and a seed that fails is a finding for #755.
#
# ── Without the watchdog: debugging, or a REPL ────────────────────────────────
#
#   julia --project=. test/runtests.jl --in-process test/sessionstores_tests.jl
#
# `--in-process` runs the items in the process that read the command line, with NO per-item
# timeout: what a debugger or `@show` needs. The watched child is this same file, invoked with
# `--in-process` -- one code path, not two.
#
# THE RUN ORDER is lexical by path (`app_tests.jl` first, a directory's files where the
# directory sorts), and items in source order -- which is what ReTestItems did, and therefore
# the order this suite has always passed in. It is NOT the order of `TEST_FILES`, whatever
# older comments said: that list is the set of files the harness checks for completeness. Order
# still matters, because several items mutate the global Nitro router via `urlpatterns(...)`
# and never reset it, which is why the run is one process and `--shuffle` is not a gate yet (#755).


# ── Per-item cleanup net ───────────────────────────────────────────────────────
# The runner evaluates this in a `finally` after EVERY test item, whether it passed, failed,
# or errored. That makes it strictly better than per-item `try`/`finally`: it also covers
# items that never call `terminate()` at all, and it still runs when an exception escapes an
# item's own cleanup.
#
# Why it matters: an item that throws between `serve()` and its trailing `terminate()`
# used to leave the listener bound for the life of the process, so the *next* item — or
# the next `Pkg.test()` run — got answers from a server it never started.
#
# `terminate()` is a cheap no-op when nothing is serving. Items that use their own
# `App` are NOT covered by this (it only reaches the global
# `CONTEXT[]`) and must still clean up after themselves.
const TEST_END = quote
    using Nitro
    # Swallow-and-report, never rethrow. An exception raised here must not REPLACE the item's
    # own failure -- you would be told the cleanup broke and never learn which assertion did.
    # Cleanup is best-effort by definition; the item's result is the signal. (The runner adds
    # the same guard around this whole block, so a throw that escapes it is logged too.)
    try
        Nitro.terminate()
    catch err
        @error "TEST_END: terminate() failed; a later :network item may hit a bound port" exception=err
    end
end

# ── CLI argument parsing ───────────────────────────────────────────────────────
# Supports (test deps are auto-provisioned via the bootstrap block above):
#   julia --project=. test/runtests.jl test/sessionstores_tests.jl
#   julia --project=. test/runtests.jl --tags core --name "Session stores"
#   julia --project=. test/runtests.jl --skip-tags network --skip-tags slow
#   julia -t auto --project=. test/runtests.jl                 # items multithreaded
#   julia --project=. test/runtests.jl --in-process            # no watchdog, no timeout
#   julia --project=. test/runtests.jl test\middleware\ratelimitter_lru_tests.jl
#
#   Flags: --tags <tag>   filter by @testitem tag. REPEATABLE and AND-combined -- an item
#                         is selected when `issubset(requested, item.tags)`, so
#                         `--tags core --tags network` means BOTH, not either.
#          --skip-tags <tag>
#                         EXCLUDE items carrying the tag. REPEATABLE, and the DUAL of
#                         `--tags` rather than its mirror image: exclusion is
#                         `isdisjoint`, so `--skip-tags network --skip-tags slow` drops
#                         an item carrying EITHER, while `--tags` would demand BOTH.
#                         ANDed with `--tags` and `--name` by the one shared rule,
#                         `selects` -- so a tag named in both lists can only ever select
#                         nothing, and the arg guard below says so by name instead of
#                         letting it look like a typo. A MISSPELLED `--skip-tags` fails
#                         OPEN (it excludes nothing and the run looks normal), which is
#                         why it is validated against KNOWN_TAGS as strictly as `--tags`
#                         is (#214).
#          --name <name>  EXACT @testitem name, NOT a substring (#34).
#          --shuffle <seed>
#                         shuffle the file order, then the item order within each file,
#                         deterministically from the unsigned integer `seed` (printed).
#          --item-timeout <seconds>
#                         the watchdog's per-item limit; 600 by default.
#          --in-process   run here, with no watchdog and no timeout.
#
#   An unrecognised `--flag` is an error, and so is `--workers`, which is gone: there are no
#   worker processes to count (see its refusal below).
#
#   A filter that selects nothing is an error that names the tag vocabulary and the
#   AND/exact-match semantics -- which is what you actually need to know, since the four ways
#   to get there (a mistyped tag, an AND-combined pair with an empty intersection, a `--name`
#   that is a substring, a tag in both lists) are all easy to hit by accident.
#   Bare paths select files/dirs; Windows (\) and POSIX (/) separators both work. A path that
#   does not exist, or a file that is not a test file, is an error.
#
#   Threads: the watched child is started with exactly this process's thread layout,
#   `--threads=<default>,<interactive>`, so `julia -t auto ... runtests.jl` still runs items
#   multithreaded and CI's `JULIA_NUM_THREADS: 1` leg still runs them on one thread -- the leg
#   that exists to catch thread-count-dependent races.
let args = copy(ARGS)
    paths      = String[]
    tags       = Symbol[]
    skip_tags  = Symbol[]
    name_filt  = nothing
    seed       = nothing
    timeout    = 600.0
    in_process = false

    while !isempty(args)
        a = popfirst!(args)
        if a == "--tags" && !isempty(args)
            push!(tags, Symbol(popfirst!(args)))
        elseif a == "--skip-tags" && !isempty(args)
            push!(skip_tags, Symbol(popfirst!(args)))
        elseif a == "--name" && !isempty(args)
            name_filt = popfirst!(args)
        elseif a == "--shuffle" && !isempty(args)
            v = popfirst!(args)
            seed = tryparse(UInt64, v)
            seed === nothing && error("`--shuffle` takes an unsigned integer seed; got `$v`")
        elseif a == "--item-timeout" && !isempty(args)
            v = popfirst!(args)
            t = tryparse(Float64, v)
            (t === nothing || !(t > 0)) &&
                error("`--item-timeout` takes a positive number of seconds; got `$v`")
            timeout = t
        elseif a == "--in-process"
            in_process = true
        elseif a in ("--tags", "--skip-tags", "--name", "--shuffle", "--item-timeout")
            # Reached ONLY when a flag that takes a value is last with nothing after it --
            # every branch above also requires a value. Without this the flag would be
            # dropped silently.
            #
            # Refused rather than warned, because of where `--skip-tags` lands when it is
            # dropped: `skip_tags` stays empty, so the validation block below never runs,
            # nothing is excluded, and the full suite executes -- including the `:network`
            # items the caller asked to skip -- and reports an ordinary green. That is the
            # same fail-OPEN shape as a mistyped `--skip-tags`, which the guard below goes to
            # some trouble to close; leaving this hole open would make that guard's promise
            # false by one case. A dangling `--tags` merely runs MORE than asked, but all are
            # refused together: one rule is easier to keep true than an exception for the one
            # flag whose failure direction is worse.
            error(
                "`$a` requires a value, and nothing followed it.\n\n" *
                "It would otherwise be dropped silently. For `--skip-tags` that means\n" *
                "excluding nothing and running the very items you asked to skip, with a\n" *
                "perfectly ordinary green at the end."
            )
        elseif a == "--workers"
            # Refused by name, not as an unknown flag, because it used to mean something.
            # ReTestItems ran items on worker PROCESSES, and `--workers N > 1` was already
            # refused (#34): each process gets its own `Nitro.CONTEXT[]`, and this suite's
            # isolation is still one shared, accumulating router. The runner now always uses
            # exactly one child process, so there is no count left to choose, and the old
            # `--workers 0` (in-process, no timeout) is spelled `--in-process`.
            error(
                "`--workers` was removed with ReTestItems (#754).\n\n" *
                "Every run uses one child process under a timeout watchdog. Items cannot run in\n" *
                "several processes: they share one process-global `Nitro.CONTEXT[]` (#34, #755).\n\n" *
                "Use `--in-process` to run without the watchdog (no per-item timeout)."
            )
        elseif startswith(a, "--")
            # Refused, not ignored. A silently dropped flag is a run that is not the one asked
            # for -- the fail-open the dangling-value guard above exists to close.
            error("Unknown option `$a`. Options: --tags, --skip-tags, --name, --shuffle, " *
                  "--item-timeout, --in-process.")
        else
            a = replace(a, '\\' => '/')   # accept Windows-style separators on any OS
            push!(paths, isabspath(a) ? a : joinpath(@__DIR__, "..", a))
        end
    end

    if isempty(paths)
        paths = [joinpath(@__DIR__, f) for f in TEST_FILES]
    else
        # Always add setup_tests.jl so the NitroCommon @testsetup is available.
        setup = joinpath(@__DIR__, "setup_tests.jl")
        if setup ∉ paths
            pushfirst!(paths, setup)
        end
    end

    # Validated in BOTH processes, before anything is collected: the parent so a typo is
    # refused without starting a child, the child because it is this same code.
    if !isempty(tags) || !isempty(skip_tags)
        # BOTH tag lists, in one check. `--skip-tags` is the half that needs it more:
        # `--tags netwrok` fails CLOSED -- zero items, and the zero-selection guard names the
        # vocabulary -- whereas `--skip-tags netwrok` fails OPEN. It would exclude nothing,
        # run the whole suite including the `:network` items the caller meant to skip, and
        # report a perfectly ordinary green. A filter that silently stops filtering is the
        # same shape of defect as #128's silently-shorter suite (#214).
        unknown = setdiff(Set([tags; skip_tags]), KNOWN_TAGS)
        isempty(unknown) || error(
            "Unknown test tag(s): $(join(sort!(collect(unknown)), ", ")).\n" *
            "Known tags: $(join(sort!(collect(KNOWN_TAGS)), ", ")).\n\n" *
            "A tag matching no @testitem would select nothing and fail anyway -- this\n" *
            "message exists to name the vocabulary instead. A mistyped `--skip-tags` would\n" *
            "NOT fail on its own: it excludes nothing and the run looks normal, which is why\n" *
            "it is checked here too. `KNOWN_TAGS` lives in test/harness_manifest.jl and is\n" *
            "checked against the suite by test/harness_tests.jl."
        )

        # A tag in both lists is diagnosed by name rather than left to look like one of the
        # other causes. It needs no special handling to BEHAVE correctly -- `issubset`
        # demands the tag and `isdisjoint` forbids it, so the selection is necessarily empty
        # and exclusion wins by construction. What it needs is to not be reported as "your
        # filter selected 0 items, maybe a typo?", which is actively misleading here.
        conflict = intersect(Set(tags), Set(skip_tags))
        isempty(conflict) || error(
            "Tag(s) in both --tags and --skip-tags: " *
            "$(join(sort!(collect(conflict)), ", ")).\n\n" *
            "Exclusion wins, so this filter can only ever select 0 test items:\n" *
            "`--tags` requires an item to carry the tag and `--skip-tags` requires it\n" *
            "not to. Drop whichever half you did not mean."
        )
    end

    # "No such test path" is a THROW, never a warning and a shorter run. ReTestItems' default
    # warned and DROPPED a bad path, so one good path and one typo ran green having never
    # executed the file you asked for -- the path-axis twin of the unlisted-file defect
    # `test/harness_tests.jl` guards on the TEST_FILES axis (#34).
    files = NitroTestRunner.resolve_paths(paths)

    # Pin the environment for the whole run (#55). `serve()` now resolves and VALIDATES
    # `NITRO_ENV`/`GENIE_ENV`, and ~20 test files call `serve`. Without this, a developer with
    # `GENIE_ENV=staging` exported -- exactly the Genie migrant the fallback exists for -- gets
    # a broad, unrelated-looking suite failure, and every unpinned assertion about
    # `current_env()` reads their shell instead of a known value. Items that care set their own
    # value with `withenv`; the watched child inherits this one. `"test"` is the honest label
    # for a run of the test suite.
    status = withenv("NITRO_ENV" => "test", "GENIE_ENV" => nothing) do
        if !in_process
            # The watchdog. The child is this file with the same arguments plus
            # `--in-process`, under the flags `Base.julia_cmd()` carries (`-O`,
            # `--check-bounds`, `--code-coverage`, ...), this thread layout, and this
            # project -- under `Pkg.test`, its temporary test environment.
            #
            # Coverage and the timeout are no longer exclusive. ReTestItems enforced its
            # timeout by killing a worker with SIGTERM, which discarded the worker's coverage,
            # so the coverage job ran with no ceiling at all (#84, #244). The child here exits
            # normally when the run ends, pass or fail, and so writes its `.cov` files; it is
            # killed only when an item has already hung past the timeout.
            threads = "$(Threads.nthreads(:default)),$(Threads.nthreads(:interactive))"
            child = `$(Base.julia_cmd()) --threads=$threads --project=$(Base.active_project()) $(@__FILE__) $ARGS --in-process`
            return NitroTestRunner.watch(child; timeout)
        end

        items, setups = NitroTestRunner.collect_suite(files; root = joinpath(@__DIR__, ".."))
        # `select_items` applies `selects`, the SHARED rule in test/harness_manifest.jl that
        # test/harness_tests.jl unit-tests -- so the run and its guard cannot drift apart.
        selected = NitroTestRunner.select_items(items; tags, skip_tags, name = name_filt)
        isempty(selected) && error(
            "This filter selects 0 test items. The likely cause is one of these:\n" *
            "  --tags      $(isempty(tags) ? "(none)" : join(tags, " "))\n" *
            "  --skip-tags $(isempty(skip_tags) ? "(none)" : join(skip_tags, " "))\n" *
            "  --name      $(something(name_filt, "(none)"))\n\n" *
            "`--tags` are AND-combined, not OR -- an item must carry ALL of them.\n" *
            "`--skip-tags` is the dual: an item is dropped if it carries ANY of them.\n" *
            "`--name` is an EXACT @testitem name, not a substring."
        )
        if seed !== nothing
            println("Shuffle seed: $seed  (`--shuffle $seed` reproduces this order)")
            selected = NitroTestRunner.shuffle_items(selected, seed)
        end
        println("Running $(length(selected)) of $(length(items)) test items on ",
                "$(Threads.nthreads(:default)),$(Threads.nthreads(:interactive)) threads",
                in_process && get(ENV, "NITRO_TEST_WATCHED", "0") != "1" ? ", in-process (no timeout)" : "")
        return NitroTestRunner.run_items(selected, setups; name = "Nitro",
                                         imports = [:Test, :Nitro], test_end = TEST_END)
    end
    # A non-zero status must reach the exit code, which is all `Pkg.test` reads.
    status == 0 || exit(status)
end
