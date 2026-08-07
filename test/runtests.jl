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
    "parallel_tests.jl",
    "middleware_tests.jl",
    "middleware_cache_tests.jl",
    "appcontext_tests.jl",
    "path_prefix_tests.jl",
    "routing_tests.jl",
    "original_tests.jl",
    "spa_tests.jl",
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
#   Threads vs workers: `-t auto` gives the in-process run multiple threads (used
#   when --workers is omitted). With --workers <n>, items run in worker processes
#   whose thread count is ReTestItems' nworker_threads (1 by default), so `-t` on
#   the launcher does not affect them.
let args = copy(ARGS)
    paths     = String[]
    tags      = Symbol[]
    name_filt = nothing
    nworkers  = 0

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

    runtests(
        paths...;
        testitem_timeout = 600,
        nworkers = nworkers,
        tags     = isempty(tags) ? nothing : tags,
        name     = isnothing(name_filt) ? nothing : name_filt,
    )
end
