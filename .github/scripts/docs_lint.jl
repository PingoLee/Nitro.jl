#!/usr/bin/env julia
#
# docs_lint.jl — guard the agent-context docs against drift.
#
# Instruction/skill docs (AGENTS.md, .github/instructions/*, .github/skills/**)
# restate rules and reference concrete files and API symbols. When code moves or
# a symbol is renamed, those references silently rot. This lint fails CI on the
# mechanically-checkable classes of that drift.
#
# What it checks:
#   A. Path references — every repo-relative path mentioned in backticks
#      (`src/...`, `ext/...`, `test/...`, `docs/...`, `.github/...`) exists.
#   B. Markdown link targets — every `[text](target)` local link resolves to a
#      real file (fragment/anchor and external URLs are ignored).
#   C. Public-symbol existence — a curated set of API names the docs commit to
#      must still be defined somewhere in `src/` or `ext/`.
#
# What it does NOT catch (documented so nobody trusts it too far):
#   - Wrong overload / signature drift (e.g. `startup(...)` vs `worker_startup(...)`
#     when both names exist). Symbol-*existence* only; no Julia parsing.
#   - Prose that is merely stale but references nothing concrete.
#
# Run locally:  julia .github/scripts/docs_lint.jl
# Exit code 1 on any finding.

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))

# Docs whose references are linted.
const DOC_GLOBS = String[
    "AGENTS.md",
    "CLAUDE.md",
]
const DOC_DIRS = String[
    joinpath(".github", "instructions"),
    joinpath(".github", "skills"),
]

# Some docs illustrate a *downstream app's* file layout (not this repo's). Those
# example paths are intentionally absent here — allowlist them so the path check
# doesn't flag them. Fail-closed: a NEW example path fails until it is listed,
# which keeps real drift (a moved core file) from hiding behind "it's an example".
const IGNORE_PATHS = Set{String}([
    "src/Routes.jl",   # nitro-docs / add-route: app route-declaration file
])
const IGNORE_PREFIXES = String[
    "src/Routes/",     # app sub-router files
    "src/Handlers/",   # app handler modules
]

# Check C: API names the docs rely on. If any is renamed/removed, the docs that
# name it are wrong — fail until either the code or the docs are updated.
const REQUIRED_SYMBOLS = String[
    "worker_startup", "serve",
    "path", "urlpatterns", "include_routes",
    "submit_task", "get_task_status", "cancel_task", "get_all_tasks",
    "set_queue_authorizer!", "pormg_nitro_worker",
    "add_response_headers", "own_response_headers",
    "login_required", "role_required",
]

# ---- helpers ---------------------------------------------------------------

function collect_docs()
    docs = String[]
    for g in DOC_GLOBS
        p = joinpath(ROOT, g)
        isfile(p) && push!(docs, p)
    end
    for d in DOC_DIRS
        base = joinpath(ROOT, d)
        isdir(base) || continue
        for (dir, _, files) in walkdir(base), f in files
            endswith(f, ".md") && push!(docs, joinpath(dir, f))
        end
    end
    return docs
end

# Strip inline/fenced code so link-like text inside code samples isn't linted as
# a real path, and vice-versa: we lint backtick paths (A) and md links (B)
# directly off the raw text, so we keep the raw content and match precisely.

# A: repo-relative paths inside backticks.
#   PATH_RE — file-ish, ends in an extension, e.g. `src/utilities/misc.jl`
#   DIR_RE  — directory-ish, trailing slash, e.g. `ext/NitroPormGExt/`
#             (bug #1's shape: a dir written where a `.jl` file was meant).
const PATH_RE = r"`((?:src|ext|test|docs|\.github)/[A-Za-z0-9_./\-]+\.[A-Za-z0-9]+)`"
const DIR_RE  = r"`((?:src|ext|test|docs|\.github)/[A-Za-z0-9_./\-]+/)`"

# B: markdown links `](target)` — capture the target.
const LINK_RE = r"\]\(([^)]+)\)"

function lint_paths(file, text, errors)
    for re in (PATH_RE, DIR_RE), m in eachmatch(re, text)
        rel = m.captures[1]
        (rel in IGNORE_PATHS || any(p -> startswith(rel, p), IGNORE_PREFIXES)) && continue
        isfile(joinpath(ROOT, rel)) || isdir(joinpath(ROOT, rel)) ||
            push!(errors, "$(relpath(file, ROOT)): backtick path `$(rel)` does not exist")
    end
end

function lint_links(file, text, errors)
    for m in eachmatch(LINK_RE, text)
        target = strip(m.captures[1])
        # Skip external URLs and same-page anchors.
        (occursin("://", target) || startswith(target, "#") || startswith(target, "mailto:")) && continue
        # Drop any #fragment (line anchors like #L42).
        path = first(split(target, '#'))
        isempty(path) && continue
        resolved = normpath(joinpath(dirname(file), path))
        isfile(resolved) || isdir(resolved) ||
            push!(errors, "$(relpath(file, ROOT)): link target `$(target)` does not resolve to a file")
    end
end

# C: is `sym` defined anywhere under src/ or ext/?
function symbol_defined(sym)
    # Escape regex metachars in the symbol (e.g. trailing `!`).
    esc = replace(sym, r"([!])" => s"\\\1")
    pat = Regex("(?:^|[^A-Za-z0-9_!])" * esc * "\\s*(?:\\(|=)")
    for sub in ("src", "ext")
        base = joinpath(ROOT, sub)
        isdir(base) || continue
        for (dir, _, files) in walkdir(base), f in files
            endswith(f, ".jl") || continue
            occursin(pat, read(joinpath(dir, f), String)) && return true
        end
    end
    return false
end

# ---- run -------------------------------------------------------------------

function main()
    errors = String[]
    docs = collect_docs()
    isempty(docs) && (println(stderr, "docs_lint: no docs found — check DOC_GLOBS/DOC_DIRS"); exit(2))

    for file in docs
        text = read(file, String)
        lint_paths(file, text, errors)
        lint_links(file, text, errors)
    end

    for sym in REQUIRED_SYMBOLS
        symbol_defined(sym) ||
            push!(errors, "REQUIRED_SYMBOLS: `$(sym)` referenced by docs is not defined in src/ or ext/")
    end

    if isempty(errors)
        println("docs_lint: OK — $(length(docs)) docs, $(length(REQUIRED_SYMBOLS)) symbols checked")
        exit(0)
    else
        println(stderr, "docs_lint: $(length(errors)) finding(s):")
        for e in errors
            println(stderr, "  - $e")
        end
        exit(1)
    end
end

# Run as a script; stay importable (no auto-run) when `include`d for testing.
if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
