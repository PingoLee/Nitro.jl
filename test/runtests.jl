# ── Bootstrap test-only dependencies ──────────────────────────────────────────
# Test-only deps (Suppressor, ProtoBuf, …) live in `[extras]` / `[targets].test`,
# so they are only on the load path under `Pkg.test()`. When this file is run
# directly — `julia --project=. test/runtests.jl <args>` — those packages are
# missing and every test item errors with "Package X not found in current path".
# Detect that case and re-dispatch through `Pkg.test` once, forwarding the CLI
# args, so all the documented commands below work without extra ceremony.
if Base.identify_package("Suppressor") === nothing && get(ENV, "NITRO_TEST_REDISPATCH", "0") == "0"
    import Pkg
    withenv("NITRO_TEST_REDISPATCH" => "1") do
        # Forward this launcher's thread count to the test subprocess, so
        # `julia -t auto … runtests.jl` still runs test items multithreaded
        # after the re-dispatch (relevant for in-process runs, i.e. no --workers).
        Pkg.test(; test_args = ARGS, julia_args = `-t $(Threads.nthreads())`)
    end
    exit(0)
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
# NOTE: The explicit file list below is intentional. Several tests mutate the
# global Nitro router via `urlpatterns(...)`, so execution order matters.
# Do NOT replace with `runtests(Nitro)` — filesystem-walk order differs from
# this safe sequence and will cause spurious failures.

const TEST_FILES = [
    # ── Shared setup ──────────────────────────────────────────────────────────
    "setup_tests.jl",

    # ── Security & Robustness ─────────────────────────────────────────────────
    "security_tests.jl",

    # ── Extension Tests ───────────────────────────────────────────────────────
    "extensions/timezone_tests.jl",
    "extensions/templating_tests.jl",
    "extensions/protobuf/protobuf_tests.jl",
    "extensions/crypto_tests.jl",
    "extensions/pormg_session_tests.jl",
    "extensions/pormg_worker_tests.jl",

    # ── Special Handler Tests ─────────────────────────────────────────────────
    "sse_tests.jl",
    "websocket_tests.jl",
    "streaming_tests.jl",
    "handler_tests.jl",

    # ── Core Tests ────────────────────────────────────────────────────────────
    "util_tests.jl",
    "upgrade_guide_tests.jl",
    "docs_deploy_tests.jl",
    "cookies_tests.jl",
    "session_tests.jl",
    "sessionstores_tests.jl",
    "workers_tests.jl",
    "reexports_tests.jl",
    "http_internals_contract_tests.jl",
    "precompilation_test.jl",
    "extractor_tests.jl",
    "reflection_tests.jl",
    "render_tests.jl",
    "bodyparser_tests.jl",
    "ergonomics_tests.jl",
    "instance_tests.jl",
    "server_show_tests.jl",
    "server_lifecycle_tests.jl",
    "parallel_tests.jl",
    "middleware_tests.jl",
    "middleware_cache_tests.jl",
    "middleware_cache_race_tests.jl",
    "custommiddleware_tests.jl",
    "appcontext_tests.jl",
    "path_prefix_tests.jl",
    "routing_tests.jl",
    "original_tests.jl",
    "spa_tests.jl",
    "staticfiles_security_tests.jl",
    "dx_tests.jl",
    "auth_module_tests.jl",
    "auth_tests.jl",
    "revise_test.jl",

    # ── Scenario Tests ────────────────────────────────────────────────────────
    "scenarios/thunderingherd_test.jl",

    # ── Prebuilt Middleware Tests ─────────────────────────────────────────────
    "middleware/extract_ip_tests.jl",
    "middleware/ratelimitter_tests.jl",
    "middleware/ratelimitter_lru_tests.jl",
    "middleware/authmiddleware_tests.jl",
    "middleware/cors_middleware_tests.jl",
    "middleware/lifecycle_middleware_tests.jl",
    "middleware/access_log_tests.jl",
    "middleware/session_middleware_tests.jl",
    "middleware/shared_response_mutation_tests.jl",
    "middleware/guards_tests.jl",

    # ── Quality Gate ──────────────────────────────────────────────────────────
    "aqua_tests.jl",
]

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
#   julia --project=. test/runtests.jl --workers 3             # parallel worker processes
#   julia --project=. test/runtests.jl test\middleware\ratelimitter_lru_tests.jl
#
#   Flags: --tags <tag>   filter by @testitem tag
#          --name <name>  filter by test item name (substring)
#          --workers <n>  number of ReTestItems worker processes
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

    if isempty(paths)
        paths = [joinpath(@__DIR__, f) for f in TEST_FILES]
    else
        # Always prepend setup_tests.jl so NitroCommon @testsetup is available.
        setup = joinpath(@__DIR__, "setup_tests.jl")
        if setup ∉ paths
            pushfirst!(paths, setup)
        end
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
        testitem_timeout = 600,
        test_end_expr = TEST_END,
        nworkers = covering ? 0 : (nworkers < 0 ? 1 : nworkers),
        nworker_threads = string(Threads.nthreads()),
        tags     = isempty(tags) ? nothing : tags,
        name     = isnothing(name_filt) ? nothing : name_filt,
    )
end
