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

    # ── Special Handler Tests ─────────────────────────────────────────────────
    "sse_tests.jl",
    "websocket_tests.jl",
    "streaming_tests.jl",
    "handler_tests.jl",

    # ── Core Tests ────────────────────────────────────────────────────────────
    "util_tests.jl",
    "cookies_tests.jl",
    "session_tests.jl",
    "sessionstores_tests.jl",
    "workers_tests.jl",
    "reexports_tests.jl",
    "precompilation_test.jl",
    "extractor_tests.jl",
    "render_tests.jl",
    "bodyparser_tests.jl",
    "ergonomics_tests.jl",
    "instance_tests.jl",
    "parallel_tests.jl",
    "middleware_tests.jl",
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
    "middleware/session_middleware_tests.jl",
    "middleware/guards_tests.jl",

    # ── Quality Gate ──────────────────────────────────────────────────────────
    "aqua_tests.jl",
]

# ── CLI argument parsing ───────────────────────────────────────────────────────
# Supports:
#   julia --project=. test/runtests.jl test/sessionstores_tests.jl
#   julia --project=. test/runtests.jl --tags core --name "Session stores"
#   julia -t auto --project=. test/runtests.jl --workers 2
#   julia --project=. test/runtests.jl test/sessionstores_tests.jl --workers 2
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
