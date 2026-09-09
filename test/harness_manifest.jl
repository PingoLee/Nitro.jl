# Shared harness metadata -- the single source of truth for WHAT the suite runs and WHICH
# tags exist. Two consumers need it, and neither can see the other:
#
#   * `test/runtests.jl` -- the coordinator. Builds the run list from TEST_FILES, and
#     refuses a `--tags`/`--name` filter that would select nothing.
#   * `test/harness_tests.jl` -- a `@testitem`, which ReTestItems evaluates in a WORKER
#     process where `runtests.jl` was never loaded. It re-includes this file by absolute
#     path, the same way `docs_deploy_tests.jl` reads the shipped `docs/make.jl`.
#
# Both read the same objects. A guard that instead text-parsed `runtests.jl` could be green
# while the real list said something else -- which is the exact failure it exists to catch.
#
# Named `*_manifest.jl` on purpose: ReTestItems' discovery (`is_test_file`) keys on the
# `_test(s).jl` / `-test(s).jl` suffixes, so this file can never be picked up AS a test
# file by a bare-path or directory run.
#
# Base only. One consumer loads it before `using Nitro`; the other inside an anonymous
# module in a worker.

module NitroTestHarness

const TEST_FILES = [
    # -- Harness self-check ---------------------------------------------------
    # First on purpose: it validates a PRECONDITION of the run (is this list
    # honest?), so a wrong list is reported before eighty items execute against
    # it. `aqua_tests.jl` stays last because it summarises the PACKAGE -- opposite
    # kind of guard, opposite end. Needs no @testsetup and binds no socket.
    "harness_tests.jl",

    # ── Shared setup ──────────────────────────────────────────────────────────
    "setup_tests.jl",

    # ── Security & Robustness ─────────────────────────────────────────────────
    "security_tests.jl",
    "ci_workflow_tests.jl",

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
    "middleware/csrf_middleware_tests.jl",
    "middleware/session_middleware_tests.jl",
    "middleware/shared_response_mutation_tests.jl",
    "middleware/guards_tests.jl",

    # ── Quality Gate ──────────────────────────────────────────────────────────
    "aqua_tests.jl",
]

# Files that exist on disk, look like test files, and are deliberately NOT run.
#
# Empty today, and that is the point: an entry here is a decision someone wrote down and
# can be argued with, rather than a file that quietly fell out of the run. `TEST_FILES`
# omission used to be silent -- `test/middleware/simple_http_test.jl` sat unlisted and
# unexecuted, and nothing said so (#34).
const UNLISTED_OK = String[]

# The complete tag vocabulary.
#
# `--tags x` for an `x` outside this set is a typo, not a filter. ReTestItems does fail on
# it -- `NoTestException("No test items found.")` -- but says nothing about WHY, so
# `runtests.jl` checks against this set first and names the vocabulary instead. (#34
# asserted ReTestItems reports a zero-match run as a *success*; that was checked against
# the shipped package and is false.)
#
# `test/harness_tests.jl` asserts this set matches the tags actually in use, in BOTH
# directions: a tag used but undocumented, and a tag documented but unused, are each a
# defect. The second direction is what stops a speculative tag being added here for a
# subsystem that has no test item to carry it -- `:csrf` was absent for exactly that reason
# until `middleware/csrf_middleware_tests.jl` arrived to carry it (#118).
const KNOWN_TAGS = Set([
    :core, :middleware, :network, :slow, :extension, :security,
    :handler, :auth, :pormg, :scenario, :aqua, :workers, :csrf,
])

# ── Discovery -- deliberately mirrors ReTestItems ─────────────────────────────────────
# Same four suffixes as ReTestItems' `is_test_file`, and the same hidden-path rule as its
# directory walk (skip dirs AND files starting with `.`). Mirroring is what keeps the guard
# honest: it flags exactly the files ReTestItems would have run. `test/.helpers/` holds
# `run_auth_tests.jl`, a helper whose name ends in `_tests.jl` -- ReTestItems skips it for
# being under a dot-directory, so this must too or the guard cries wolf. (`.TestPackage/`
# and `extensions/protobuf/.messages/` are pruned by the same rule; nothing in them
# currently matches the suffixes.)
#
# Scope note: this walks `test/`, whereas ReTestItems walks the project root. A stray
# `src/foo_tests.jl` would be invisible here -- not reachable today, since the launcher
# always passes explicit paths, but the asymmetry is deliberate rather than overlooked.
is_test_file(p) = any(s -> endswith(p, s),
                      ("_test.jl", "_tests.jl", "-test.jl", "-tests.jl"))

function discover_test_files(root)
    out = String[]
    for (dir, dirs, files) in walkdir(root; topdown = true)
        filter!(d -> !startswith(d, '.'), dirs)   # in-place: prunes the descent
        for f in files
            (startswith(f, '.') || !is_test_file(f)) && continue
            push!(out, replace(relpath(joinpath(dir, f), root), '\\' => '/'))
        end
    end
    return sort!(out)
end

# ── Tag extraction -- AST, not regex ──────────────────────────────────────────────────
# A regex over source silently misses every file starting with a UTF-8 BOM, and 33 of our
# 61 test files do (`^@testitem` simply does not match there). `Meta.parseall` handles the
# BOM. Reimplemented rather than calling ReTestItems' internals, so a guard on the suite
# does not depend on a private function of the package it is guarding.
function testitems(path)
    out = Tuple{String, Vector{Symbol}}[]
    function walk(e)
        e isa Expr || return
        if e.head === :macrocall && e.args[1] === Symbol("@testitem") && length(e.args) >= 4
            name = e.args[3]
            tags = Symbol[]
            for a in e.args[4:end]
                (a isa Expr && a.head === :(=) && a.args[1] === :tags) || continue
                v = a.args[2]
                (v isa Expr && v.head === :vect) || continue
                for tg in v.args
                    tg isa QuoteNode && tg.value isa Symbol && push!(tags, tg.value)
                end
            end
            name isa String && push!(out, (name, tags))
        end
        foreach(walk, e.args)
    end
    walk(Meta.parseall(read(path, String)))
    return out
end

end # module NitroTestHarness
