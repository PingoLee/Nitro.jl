using ReTestItems
using Nitro # Ensure the package itself is loaded

# Ordered list of test files — preserves the current execution order.
# ReTestItems runs them sequentially by default; parallel execution
# is NOT enabled until every file is verified parallel-safe.
const TEST_FILES = [
    # ── Shared setup ──
    "setup_tests.jl",

    # ── Security & Robustness ──
    "security_tests.jl",

    # ── Extension Tests ──
    "extensions/timezone_tests.jl",
    "extensions/templating_tests.jl",
    "extensions/protobuf/protobuf_tests.jl",
    "extensions/crypto_tests.jl",

    # ── Special Handler Tests ──
    "sse_tests.jl",
    "websocket_tests.jl",
    "streaming_tests.jl",
    "handler_tests.jl",

    # ── Core Tests ──
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

    # ── Scenario Tests ──
    "scenarios/thunderingherd_test.jl",

    # ── Prebuilt Middleware Tests ──
    "middleware/extract_ip_tests.jl",
    "middleware/ratelimitter_tests.jl",
    "middleware/ratelimitter_lru_tests.jl",
    "middleware/authmiddleware_tests.jl",
    "middleware/cors_middleware_tests.jl",
    "middleware/lifecycle_middleware_tests.jl",
    "middleware/session_middleware_tests.jl",
    "middleware/guards_tests.jl",

    # ── Quality Gate ──
    "aqua_tests.jl",
]

function run_all_tests(; kwargs...)
    paths = [joinpath(@__DIR__, f) for f in TEST_FILES]
    runtests(paths...; testitem_timeout=600, kwargs...)
end

if get(ENV, "NITRO_TEST_SKIP_AUTO", "0") != "1"
    run_all_tests()
end

# julia --project -e 'using Pkg; Pkg.test()'