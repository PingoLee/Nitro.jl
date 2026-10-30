# Shared harness metadata -- the single source of truth for WHAT the suite runs and WHICH
# tags exist. Two consumers need it, and neither can see the other:
#
#   * `test/runtests.jl` and the runner it includes (`test/runner/`) -- build the run from
#     TEST_FILES, select with `selects`, and refuse a filter that would select nothing.
#   * `test/harness_tests.jl` -- a `@testitem`, which runs in a fresh module where none of
#     `runtests.jl`'s bindings are visible. It re-includes this file by absolute
#     path, the same way `docs_deploy_tests.jl` reads the shipped `docs/make.jl`.
#
# Both read the same objects. A guard that instead text-parsed `runtests.jl` could be green
# while the real list said something else -- which is the exact failure it exists to catch.
#
# Named `*_manifest.jl` on purpose: discovery (`is_test_file`, below) keys on the
# `_test(s).jl` / `-test(s).jl` suffixes, so this file can never be picked up AS a test
# file by a bare-path or directory run.
#
# Base only. One consumer loads it before `using Nitro`; the other inside an anonymous
# module in a worker.

module NitroTestHarness

# The files the suite is made of -- NOT the order they run in. The run is in lexical path
# order (see `test/runtests.jl`), as it was under ReTestItems, so a file's position here
# changes nothing about when it runs. The groups below are for reading.
const TEST_FILES = [
    # -- Harness self-check ---------------------------------------------------
    # It validates a PRECONDITION of the run (is this list honest?). Needs no
    # @testsetup and binds no socket.
    "harness_tests.jl",
    # The runner's own checks: collection refusals, selection, `--shuffle`, and the watchdog
    # and setup/TEST_END guards provoked in child processes (#754).
    "runner_tests.jl",

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
    "extensions/pormg_worker_log_exposure_tests.jl",
    "extensions/pormg_env_tests.jl",
    "extensions/pormg_pools_tests.jl",
    "extensions/newapp_pormg_tests.jl",

    # ── Special Handler Tests ─────────────────────────────────────────────────
    "sse_tests.jl",
    "websocket_tests.jl",
    "streaming_tests.jl",
    "handler_tests.jl",

    # ── Core Tests ────────────────────────────────────────────────────────────
    "util_tests.jl",
    "environment_tests.jl",
    "upgrade_guide_tests.jl",
    "newapp_tests.jl",
    "examples_tests.jl",
    "docs_deploy_tests.jl",
    "docs_lint_tests.jl",
    "cookies_tests.jl",
    "session_tests.jl",
    "sessionstores_tests.jl",
    "ctrl_c_child_tests.jl",
    "workers_tests.jl",
    "workers_consumer_e2e_tests.jl",
    "workers_thread1_hijack_tests.jl",
    "reexports_tests.jl",
    "http_internals_contract_tests.jl",
    "juliac_internals_contract_tests.jl",
    "precompilation_test.jl",
    "precompile_warmth_tests.jl",
    "extractor_tests.jl",
    "reflection_tests.jl",
    "binding_tests.jl",
    "response_tests.jl",
    "streaming_write_tests.jl",
    "bodyparser_tests.jl",
    "max_body_bytes_tests.jl",
    "max_fields_tests.jl",
    "ergonomics_tests.jl",
    "app_tests.jl",
    "server_show_tests.jl",
    "server_lifecycle_tests.jl",
    "request_cancellation_tests.jl",
    "h2c_tests.jl",
    "parallel_tests.jl",
    "middleware_tests.jl",
    "middleware_cache_tests.jl",
    "middleware_cache_race_tests.jl",
    "custommiddleware_tests.jl",
    "route_endpoint_tests.jl",
    "response_type_tests.jl",
    "appcontext_tests.jl",
    "appcontext_race_tests.jl",
    "path_prefix_tests.jl",
    "request_target_tests.jl",
    "routing_tests.jl",
    "original_tests.jl",
    "spa_tests.jl",
    "staticfiles_security_tests.jl",
    "dx_tests.jl",
    "auth_module_tests.jl",
    "auth_keyset_tests.jl",
    "auth_tests.jl",
    "revise_test.jl",

    # ── Scenario Tests ────────────────────────────────────────────────────────
    "scenarios/thunderingherd_test.jl",

    # ── Prebuilt Middleware Tests ─────────────────────────────────────────────
    "middleware/janitor_tests.jl",
    "middleware/extract_ip_tests.jl",
    "middleware/websocket_origins_tests.jl",
    "middleware/ratelimitter_tests.jl",
    "middleware/ratelimitter_lru_tests.jl",
    "middleware/authmiddleware_tests.jl",
    "middleware/cors_middleware_tests.jl",
    "middleware/security_headers_tests.jl",
    "middleware/lifecycle_middleware_tests.jl",
    "middleware/access_log_tests.jl",
    "middleware/csrf_middleware_tests.jl",
    "middleware/cross_origin_protection_tests.jl",
    "middleware/session_middleware_tests.jl",
    "middleware/shared_response_mutation_tests.jl",
    "middleware/guards_tests.jl",
    "middleware/middleware_error_boundary_tests.jl",
    "middleware/log_exposure_tests.jl",

    # ── Quality Gate ──────────────────────────────────────────────────────────
    "closure_boxing_tests.jl",
    "aqua_tests.jl",
]

# Files that exist on disk, look like test files, and are deliberately NOT run.
#
# Empty today, and that is the point: an entry here is a decision someone wrote down and
# can be argued with, rather than a file that quietly fell out of the run. `TEST_FILES`
# omission used to be silent -- `test/middleware/simple_http_test.jl` sat unlisted and
# unexecuted, and nothing said so (#34).
const UNLISTED_OK = String[]

# Test files permitted to contain `@test_skip` / `@test_broken`, as "file.jl" entries.
#
# Empty today, and -- exactly like `UNLISTED_OK` above -- that is the point. A skip is a
# decision to ship less coverage, so it should be a decision someone wrote down here and
# can be argued with, not a branch added quietly inside a test file.
#
# The two that used to be here are gone rather than listed: `extensions/pormg_worker_tests.jl`
# and `revise_test.jl` both guarded on a declared `[targets].test` dependency being
# importable and skipped when it was not. That is an environment bug reporting itself as a
# pass (#128); both now fail, and `test/runtests.jl` refuses the run even earlier.
#
# Before adding an entry, check it is genuinely not one of those. A skip is defensible when
# the missing capability is a property of the PLATFORM (no symlink privilege, no /proc) that
# no amount of provisioning can supply. It is not defensible when the missing capability is a
# package the suite already declares it needs.
const SKIPS_OK = String[]

# The complete tag vocabulary.
#
# `--tags x` for an `x` outside this set is a typo, not a filter. It would fail anyway, as a
# selection of zero items, but that says nothing about WHY, so `runtests.jl` checks against
# this set first and names the vocabulary instead.
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

# ── Discovery -- the rule the runner itself uses ──────────────────────────────────────
# Four suffixes, and a hidden-path rule (skip dirs AND files starting with `.`), kept from
# ReTestItems. The runner expands a directory path with this very function
# (`test/runner/collect.jl`), so the guard flags exactly the files a directory run would
# execute. `test/.helpers/` holds `run_auth_tests.jl`, a helper whose name ends in
# `_tests.jl` -- it is skipped for being under a dot-directory, so the guard does not cry
# wolf. (`.TestPackage/` and `extensions/protobuf/.messages/` are pruned by the same rule;
# nothing in them currently matches the suffixes.)
#
# Scope note: this walks `test/`. A stray `src/foo_tests.jl` would be invisible here -- not
# reachable, since the launcher only ever passes paths under `test/` or named explicitly.
is_test_file(p) = any(s -> endswith(p, s),
                      ("_test.jl", "_tests.jl", "-test.jl", "-tests.jl"))

# A plain recursive `readdir`, NOT `walkdir` with `filter!` on the yielded `dirs` (#297).
# `walkdir` never promised in-place pruning: its producer task puts `(path, dirs, files)`
# on an unbuffered channel and then iterates that same `dirs` itself. The producer is
# sticky, so on one thread it waits for the consumer to yield and the prune looked like it
# worked. In a test item the consumer is migratable, so at 2 threads the two run in
# parallel. The producer then either descends before the prune (a `.helpers/` "orphan") or
# reads the vector mid-`filter!` (`UndefRefError` → `TaskFailedException`).
#
# Classification is `walkdir(follow_symlinks = false)`'s: a symlink is a file, never
# descended, whatever it points at.
function discover_test_files(root)
    out = String[]
    function walk(dir)
        for name in readdir(dir)
            startswith(name, '.') && continue
            path = joinpath(dir, name)
            if !islink(path) && isdir(path)
                walk(path)
            elseif is_test_file(name)
                push!(out, replace(relpath(path, root), '\\' => '/'))
            end
        end
    end
    walk(root)
    return sort!(out)
end

# ── Tag extraction -- AST, not regex ──────────────────────────────────────────────────
# A regex over source silently misses every file starting with a UTF-8 BOM, and 33 of our
# 61 test files do (`^@testitem` simply does not match there). `Meta.parseall` handles the
# BOM. Kept independent of the runner's own collection, so the guard is a second reader of
# the files rather than the runner checking itself; `test/runner_tests.jl` asserts the two
# agree on every file.
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

# ── Selection -- the one rule both the launcher and its guard read ────────────────────
# The run selects items with this rule (`select_items` in `test/runner/collect.jl`), and
# `test/harness_tests.jl` unit-tests it. Under ReTestItems the launcher kept a REPLICA of the
# library's filter to explain a zero-item selection, and a replica that drifts from the real
# run is worse than none -- #214 is the receipt: adding `--skip-tags` without teaching the
# replica about exclusion was exactly that drift. Now there is one rule and no replica.
#
# The three clauses keep the semantics ReTestItems' `TestItemFilter` had:
#
#   tags       AND-combined, `issubset(requested, item.tags)` -- "has AT LEAST all of these"
#   name       EXACT, `name == ti.name`, never a substring (#34)
#   skip_tags  the DUAL of `tags`, and NOT its mirror image: `isdisjoint` drops an item that
#              carries ANY listed tag, where `issubset` demands ALL of them. So
#              `--skip-tags network --skip-tags slow` means "neither", while
#              `--tags network --tags slow` means "both". ANDed with the two above.
selects(nm, tg; tags = Symbol[], skip_tags = Symbol[], name = nothing) =
    issubset(tags, tg) && isdisjoint(skip_tags, tg) && (isnothing(name) || nm == name)

# ── Skip detection -- AST, not regex, for the same BOM reason as above ────────────────
# A conditional skip turns missing coverage into a PASS. `@test_skip` and `@test_broken`
# both report as `Broken`, which is one line in a 3,500-assertion summary and leaves the
# exit code at 0 -- so the suite says "green" while being materially weaker. #128 is the
# receipt: `extensions/pormg_worker_tests.jl` skipped its entire real-store testset (112
# assertions, the only coverage the shipped `ext/NitroPormGExt.jl` store gets) whenever
# PormG was missing from the environment, and every run still passed.
#
# `test/harness_tests.jl` asserts this finds nothing outside `SKIPS_OK`.
#
# THREE spellings, because a check that knows only one is a check you route around without
# meaning to:
#   * bare      -- `@test_skip ex`
#   * qualified -- `Test.@test_skip ex`, arbitrarily nested (`Main.Test.@test_skip`)
#   * KEYWORD   -- `@test ex skip=true` / `@test ex broken=true`
#
# The keyword form is the one that matters most, and it is not an exotic dodge: it is the
# modern Test.jl idiom (Julia >= 1.7), it is what the Test stdlib documentation reaches for
# first, and it reports as `Broken` exactly like `@test_skip`. `@test store() skip=(PormG
# === nothing)` would have reconstituted #128 in full while this guard stayed green.
#
# Flagged regardless of the keyword's VALUE. `skip=false` is pointless to write, and
# `skip=<expr>` is not statically evaluable -- which is precisely the conditional-skip case
# that has to be argued for in `SKIPS_OK` rather than slipped in.
const SKIP_MACROS = (Symbol("@test_skip"), Symbol("@test_broken"))
const SKIP_KWARGS = (:skip, :broken)

_macroname(x::Symbol) = x
_macroname(x::Expr) = (x.head === :. && length(x.args) == 2 && x.args[2] isa QuoteNode) ?
                      x.args[2].value : nothing
_macroname(::Any) = nothing

function skip_macros(path)
    out = Tuple{Symbol, Int}[]
    line = 0
    function walk(e)
        e isa Expr || return
        if e.head === :macrocall && !isempty(e.args)
            nm = _macroname(e.args[1])
            ln = (length(e.args) >= 2 && e.args[2] isa LineNumberNode) ?
                 e.args[2].line : line
            if nm !== nothing && nm in SKIP_MACROS
                push!(out, (nm, ln))
            elseif nm === Symbol("@test")
                # `@test ex skip=true` parses the keyword as `Expr(:(=), :skip, true)` --
                # NOT `Expr(:kw, ...)`, which is what a function-call keyword produces.
                #
                # From args[4]: args[3] is the test-EXPRESSION slot, so scanning from 3
                # reads `@test (skip = true)` -- an assignment written as the expression --
                # as a keyword skip. Meaningless code, but the narrower range costs nothing.
                for a in e.args[4:end]
                    a isa Expr && a.head === :(=) && a.args[1] in SKIP_KWARGS || continue
                    push!(out, (Symbol("@test ", a.args[1], "="), ln))
                end
            end
        end
        for a in e.args
            a isa LineNumberNode && (line = a.line)
            walk(a)
        end
    end
    walk(Meta.parseall(read(path, String)))
    return out
end

# ── Bare global-API calls: a ratchet (#755) ───────────────────────────────────────────
#
# A call that reaches the process-wide `CONTEXT[]` app is how one test item leaks routes,
# middleware or a running server into the next, and that makes the suite pass only in some
# orders. `App` (#31) is the cure: an item that builds its own and uses the `(app, …)` forms
# cannot be reached by a neighbour. `global_api_calls` counts the calls that WRITE to the
# global app, by their argument-less spelling:
#
#   * `urlpatterns("…", …)` and `router("…")` -- a string literal where the `App` goes;
#   * `serve(…)` and `worker_startup(…)` with no positional argument;
#   * `staticfiles`/`spafiles`/`dynamicfiles` with one or two positional arguments (the
#     `App` form is written with all three);
#   * `configcookies(…)` with no positional argument, or a `Dict(…)` literal;
#   * `CONTEXT[]` -- the singleton itself.
#
# Syntax cannot see types, so two spellings slip through: a prefix or a `Dict` held in a
# variable (`urlpatterns(p, …)`, `configcookies(d)`) reads as the `App` form. Write the
# literal. The readers -- `terminate()`, `internalrequest(req)`, `url`, `getexternalurl` --
# are not counted: they see only what a counted call put there.
#
# This is the guard that matters for leaks through the global app: the per-item reset in
# `test/runtests.jl` means `--shuffle` no longer sees them.
#
# `GLOBAL_API_BASELINE` is how many of them each `TEST_FILES` entry holds today, and
# `test/harness_tests.jl` asserts every file matches its number EXACTLY (a file not listed
# here must hold none). Exact rather than "at most", so the number cannot drift: a new bare
# call fails, and so does a migration that forgets to lower the baseline. The counts only go
# down.
#
# Two kinds of entry, and only the first is permanent:
#
#   * the files that TEST the argument-less convenience layer -- `src/methods.jl`'s global
#     methods, `resetstate`, the singleton `serve`/`terminate` -- and `original_tests.jl`,
#     the retained Oxygen suite, whose style is kept. The global app is what they are
#     about, and the cleanup net hands each of them a fresh one;
#   * everything else, which is debt. The per-item cleanup net in `test/runtests.jl` resets
#     the global app after every item, so these calls no longer leak into a neighbour, and
#     they are not rewritten for their own sake. They are still debt: an item that serves
#     on the singleton tests the convenience layer by accident, never `App`, and is one
#     missing reset away from a leak again. An item that is rewritten moves to an explicit
#     `App` and lowers its file's number; a file leaves the list at zero.
const GLOBAL_API_BASELINE = Dict{String, Int}(
    # Permanent: the convenience layer, and the retained Oxygen suite.
    "app_tests.jl"                         => 3,   # CONTEXT[] untouched by an explicit App
    "appcontext_race_tests.jl"             => 5,   # the global app under concurrency
    "cookies_tests.jl"                     => 14,  # argument-less cookie helpers (#308)
    "original_tests.jl"                    => 10,
    "server_lifecycle_tests.jl"            => 5,   # the singleton serve guard
    "workers_tests.jl"                     => 5,   # bare worker_startup (#322)
    # Debt: lower the number when the file moves to an explicit App.
    "appcontext_tests.jl"                  => 4,
    "environment_tests.jl"                 => 2,
    "extensions/templating_tests.jl"       => 1,
    "extensions/timezone_tests.jl"         => 2,
    "extractor_tests.jl"                   => 1,
    "handler_tests.jl"                     => 2,
    "max_body_bytes_tests.jl"              => 6,
    "middleware/authmiddleware_tests.jl"   => 2,
    "middleware/cors_middleware_tests.jl"  => 10,
    "middleware/ratelimitter_lru_tests.jl" => 9,
    "middleware/ratelimitter_tests.jl"     => 10,
    "middleware_tests.jl"                  => 1,
    "parallel_tests.jl"                    => 4,
    "path_prefix_tests.jl"                 => 2,
    "revise_test.jl"                       => 5,
    "routing_tests.jl"                     => 8,
    "scenarios/thunderingherd_test.jl"     => 2,
    "server_show_tests.jl"                 => 2,
    "session_tests.jl"                     => 13,
    "spa_tests.jl"                         => 7,
    "staticfiles_security_tests.jl"        => 43,
    "streaming_tests.jl"                   => 2,
    "websocket_tests.jl"                   => 2,
)

# The callee's own name for `f(...)` and `Mod.f(...)`; `nothing` for anything else.
_calleename(x::Symbol) = x
_calleename(x::Expr) = (x.head === :. && length(x.args) == 2 && x.args[2] isa QuoteNode) ?
                       x.args[2].value : nothing
_calleename(::Any) = nothing

# The leftmost module of `A.B.f`, so `HTTP.serve` is not mistaken for Nitro's.
_rootname(x::Symbol) = x
_rootname(x::Expr) = x.head === :. ? _rootname(x.args[1]) : nothing
_rootname(::Any) = nothing

# Positional arguments of a call expression: neither `;`-parameters nor `k = v` keywords.
_positional(e::Expr) = [a for a in e.args[2:end]
                        if !(a isa Expr && a.head in (:parameters, :kw))]

# A string literal, interpolated or not. An `App` is never one, so a string where the `App`
# goes marks the argument-less form.
_stringish(x) = x isa String || (x isa Expr && x.head === :string)

# Whether a call to `nm` with positional arguments `pos` is the argument-less form.
function _bare_call(nm::Symbol, pos::Vector)
    nm in (:serve, :worker_startup) && return isempty(pos)
    nm === :urlpatterns && return !isempty(pos) && _stringish(pos[1])
    nm === :router && return isempty(pos) || _stringish(pos[1])
    # `staticfiles(folder, mount)` and `staticfiles(app, folder)` parse alike, so two
    # positional arguments count as the global form: spell the `App` form with its mount,
    # `staticfiles(app, folder, "static")`, as every test does.
    nm in (:staticfiles, :spafiles, :dynamicfiles) && return length(pos) in (1, 2)
    # `configcookies(Dict(…))` is the global form; a `Dict` held in a variable reads as an `App`.
    if nm === :configcookies
        isempty(pos) && return true
        length(pos) == 1 && pos[1] isa Expr && pos[1].head === :call || return false
        f = pos[1].args[1]
        return f === :Dict || (f isa Expr && f.head === :curly && f.args[1] === :Dict)
    end
    return false
end

"""
    global_api_calls(src::AbstractString) -> Vector{Tuple{Symbol, Int}}

Every bare global-API call in the source text `src`, as `(kind, line)`: `kind` is the
callee's name (`:urlpatterns`, `:serve`, `:router`, `:staticfiles`, `:spafiles`,
`:dynamicfiles`, `:configcookies`, `:worker_startup`) or `:CONTEXT`. An AST walk, so
comments, strings and docstrings that mention the calls are not counted. See
`GLOBAL_API_BASELINE`.
"""
function global_api_calls(src::AbstractString)
    out = Tuple{Symbol, Int}[]
    line = 0
    function walk(e)
        e isa Expr || return
        # A method definition's signature parses as a `:call` too; walk only its body, so a
        # local helper named `serve` is not read as a call to Nitro's.
        if (e.head === :function || (e.head === :(=) && e.args[1] isa Expr &&
                                     e.args[1].head in (:call, :where))) && length(e.args) == 2
            return walk(e.args[2])
        end
        if e.head === :call && !isempty(e.args)
            nm = _calleename(e.args[1])
            if nm isa Symbol && _rootname(e.args[1]) !== :HTTP && _bare_call(nm, _positional(e))
                push!(out, (nm, line))
            end
        elseif e.head === :ref && length(e.args) == 1 && _calleename(e.args[1]) === :CONTEXT
            push!(out, (:CONTEXT, line))
        end
        for a in e.args
            a isa LineNumberNode && (line = a.line)
            walk(a)
        end
    end
    walk(Meta.parseall(src))
    return out
end

end # module NitroTestHarness
