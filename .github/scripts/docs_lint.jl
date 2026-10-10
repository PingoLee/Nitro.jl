#!/usr/bin/env julia
#
# docs_lint.jl — guard the contributor and agent docs against drift.
#
# The doc system is built on one rule: *one fact, one home*. `AGENTS.md` is a thin
# pointer, `CONTRIBUTING.md` is the canonical hub (design lineage, the rules that apply
# everywhere, the hard-stop index, the area rule table, the architecture map, the
# verification commands), the area files under `.github/instructions/` own their area,
# and `.github/skills/` holds the three skills this repository ships. The maintainer's
# process rules, process skills and subagent are NOT in this repository: they reach a
# local checkout only as gitignored symlinks and a gitignored `CLAUDE.local.md`, so a
# fresh clone — and CI — never sees them. The hub stays honest only if every
# *cross-reference* between the public files is checked, and the public sets are pinned so
# a process file re-committed by mistake fails loudly.
#
# This lint fails CI on the mechanically-checkable classes of that drift.
#
# What it checks:
#   A. Path references — every repo-relative path mentioned in backticks
#      (`src/...`, `ext/...`, `test/...`, `docs/...`, `.github/...`) exists.
#   B. Markdown link targets — every `[text](target)` local link resolves to a
#      real file (fragment/anchor and external URLs are ignored).
#   C. Public-symbol existence — a curated set of API names the docs commit to
#      must still be defined somewhere in `src/` or `ext/`.
#   D. Front-matter — every skill declares `name` (matching its directory) and a
#      non-empty `description`; every instruction file declares a `description`.
#   E. Registry parity — the set of tracked skill directories under `.github/skills/`
#      and the set of `.github/instructions/*.instructions.md` files are BOTH pinned
#      here (PUBLIC_SKILLS, PUBLIC_RULES), and every member is listed in the hub. A
#      skill nobody links to is invisible; a table row for a deleted skill is a lie; and
#      a process file reappearing as a tracked file is the regression this exists for.
#   F. Discovery stubs — Claude Code registers a skill only from
#      `.claude/skills/<name>/SKILL.md`, so each public skill has a tracked stub there
#      whose front-matter is byte-identical to the canonical file's, whose body names
#      the canonical path, and which stays under a size ceiling (a stub fails by slowly
#      growing into a second, stale copy of the skill). Symlinked entries are the
#      maintainer's private skills and are ignored. The front-matter of both trees is
#      also checked for the YAML hazards that make discovery fail silently.
#   G. Section-anchor references — a pointer like `[nitro-core §4](…)` or
#      "`nitro-core.instructions.md` §4" must resolve to a real `## 4.` heading in
#      that file. The hub's hard-stop index is built entirely out of these, so an
#      unchecked § pointer is exactly how the index rots.
#
# What it does NOT catch (documented so nobody trusts it too far):
#   - Wrong overload / signature drift (e.g. `Res.status(code, msg)` when only
#     `Res.status(code)` exists). Symbol-*existence* only; no Julia parsing.
#   - A symbol that exists in the wrong namespace (`Res.html` vs `html`) — check C
#     is namespace-blind. Add such pairs to REQUIRED_SYMBOLS only by their
#     defining name.
#   - Prose that is merely stale but references nothing concrete.
#   - Anything in the private process material: it is not tracked here, so it is not
#     read here. Its own cross-links are the maintainer's to keep.
#
# Run locally:  julia .github/scripts/docs_lint.jl
# Exit code 1 on any finding.

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))

# Docs whose references are linted.
const DOC_GLOBS = String[
    "AGENTS.md",
    "CLAUDE.md",
    "CONTRIBUTING.md",
]
const DOC_DIRS = String[
    joinpath(".github", "instructions"),
    joinpath(".github", "skills"),
    joinpath(".claude", "skills"),
]

# The canonical hub: the file that must list every public skill and every rule file.
const HUB = "CONTRIBUTING.md"

const SKILLS_DIR        = joinpath(ROOT, ".github", "skills")
const CLAUDE_SKILLS_DIR = joinpath(ROOT, ".claude", "skills")
const INSTRUCTIONS_DIR  = joinpath(ROOT, ".github", "instructions")

# The skills this repository ships, and the rule files it keeps. Adding to either list is
# the deliberate edit; a directory or file that appears without it fails the lint. The
# maintainer's process skills and ruleset left this repository on purpose and reach a
# checkout only as gitignored symlinks — one of them reappearing as a tracked file is the
# regression check E exists to catch.
const PUBLIC_SKILLS = String["add-route", "deploy-checklist", "nitro-usage"]
const PUBLIC_RULES  = String[
    "concurrency.instructions.md",
    "nitro-config.instructions.md",
    "nitro-core.instructions.md",
    "nitro-docs.instructions.md",
    "workers.instructions.md",
]

# A stub is front-matter + a few lines of pointer prose. The canonical files run 3-25 KB,
# so this ceiling sits an order of magnitude below the thing it protects against. Raising
# it is a deliberate edit, and the answer is almost always "put that sentence in the
# canonical file".
const STUB_MAX_BYTES = 2_048

# Some docs illustrate a *downstream app's* file layout (not this repo's). Those
# example paths are intentionally absent here — allowlist them so the path check
# doesn't flag them. Fail-closed: a NEW example path fails until it is listed,
# which keeps real drift (a moved core file) from hiding behind "it's an example".
const IGNORE_PATHS = Set{String}([
    "src/Routes.jl",   # nitro-docs / add-route / nitro-usage: app route file
    "src/App.jl",      # nitro-usage: app entry point
    "src/main.jl",     # nitro-docs: app entry point
])
const IGNORE_PREFIXES = String[
    "src/Routes/",     # app sub-router files
    "src/Handlers/",   # app handler modules
]

# Check C: API names the docs rely on. If any is renamed/removed, the docs that
# name it are wrong — fail until either the code or the docs are updated.
const REQUIRED_SYMBOLS = String[
    "App",
    "worker_startup", "serve", "terminate", "resetstate", "internalrequest",
    "path", "urlpatterns", "include_routes", "url",
    "submit_task", "submit_sequential_task", "get_task_status", "cancel_task", "get_all_tasks",
    "set_queue_authorizer!", "set_watch_authorizer!", "scoped_task_key", "DEFAULT_QUEUE_NAME",
    "cancel_requested", "update_progress!",
    "TaskAuthority", "Owner", "System", "owner_of",
    "pormg_nitro_worker",
    # Environment resolution (#55) and its PormG bridge.
    "current_env", "sync_pormg_env!",
    "add_response_headers", "own_response_headers",
    "login_required", "role_required", "permission_required", "claim_required",
    "kid_required", "Principal",
    # Response builders. `html` is the markup sink the security rules name; `text`,
    # `json` and `binary` are the request-body parsers (#28 removed the same-named
    # response constructors, so these now resolve in `bodyparsers.jl`).
    "html", "text", "binary",
    # Request/body plumbing the usage skill teaches.
    "formdata", "multipart", "payload", "getcontext", "regenerate_session!",
    # The request accessors (#151 removed the `req.<prop>` shorthands these replaced, so the
    # docs now name the functions directly -- every one of them has to keep existing).
    "getparams", "getquery", "getjson", "getform", "getfiles", "getpost",
    "getsession", "setsession!", "getuser", "getip", "setip!",
    "staticfiles", "spafiles", "dynamicfiles",
    # Middleware constructors.
    "SessionMiddleware", "CSRFMiddleware", "Cors", "RateLimiter", "ExtractIP",
    "extract_ip", "getpeerip",
    "BearerAuth", "CookieAuthMiddleware", "GuardMiddleware", "AccessLog",
    "SecretString", "reveal",
    # Release-train tooling — the versioning rule names these.
    "upgrade_guide", "_parse_upgrading",
]

# ---- helpers ---------------------------------------------------------------

# Tracked entries only: a symlinked directory under `.claude/skills/` (or a symlinked
# file anywhere) is the maintainer's private material, linked in locally, and is not part
# of what this repository ships — so it is not part of what this lint reads.
tracked_subdirs(dir) = isdir(dir) ?
    String[d for d in sort(readdir(dir)) if isdir(joinpath(dir, d)) && !islink(joinpath(dir, d))] :
    String[]

function collect_docs()
    docs = String[]
    for g in DOC_GLOBS
        p = joinpath(ROOT, g)
        isfile(p) && push!(docs, p)
    end
    for d in DOC_DIRS
        base = joinpath(ROOT, d)
        isdir(base) || continue
        # walkdir does not follow symlinked directories, and a symlinked file is skipped
        # explicitly, so the private material linked in locally is never read.
        for (dir, _, files) in walkdir(base), f in files
            p = joinpath(dir, f)
            endswith(f, ".md") && !islink(p) && push!(docs, p)
        end
    end
    return docs
end

"""
Parse the leading `---` front-matter block into a Dict{String,String}.
Handles plain `key: value` and folded `key: >-` blocks (subsequent indented
lines are joined with spaces). Returns an empty Dict when there is no block.
"""
function front_matter(text)
    lines = split(text, '\n')
    (isempty(lines) || strip(lines[1]) != "---") && return Dict{String,String}()
    close_idx = findnext(l -> strip(l) == "---", lines, 2)
    close_idx === nothing && return Dict{String,String}()

    fm = Dict{String,String}()
    key = ""
    for i in 2:(close_idx - 1)
        line = lines[i]
        m = match(r"^([A-Za-z_][A-Za-z0-9_]*):[ \t]*(.*)$", line)
        if m !== nothing && !startswith(line, " ") && !startswith(line, "\t")
            key = m.captures[1]
            val = strip(m.captures[2])
            fm[key] = (val == ">-" || val == ">" || val == "|") ? "" : val
        elseif !isempty(key)
            fm[key] = strip(fm[key] * " " * strip(line))
        end
    end
    return fm
end

"""
The raw front-matter block of `text`, delimiters included, exactly as on disk — or
`nothing` when the file does not open with a `---` line. Check F compares two of these
byte for byte, because the stub's `name`/`description` are the only bytes that exist
twice in the repo by design.
"""
function front_matter_block(text)
    lines = split(text, '\n')
    (isempty(lines) || strip(lines[1]) != "---") && return nothing
    close_idx = findnext(l -> strip(l) == "---", lines, 2)
    close_idx === nothing && return nothing
    return join(lines[1:close_idx], "\n")
end

"""
`nothing` if the `key: value` line is safe as plain YAML, else a reason string.

Deliberately not a YAML parser — the script is stdlib-only. It pins the hazards that make
skill discovery fail *silently*: an unquoted `": "` makes the block unparseable, so the
skill is never registered; an unquoted `" #"` opens a comment and truncates the
description mid-sentence, so the skill registers and advertises half a sentence. A value
the author quoted is exempt.
"""
function yaml_scalar_problem(key, value)
    v = strip(value)
    isempty(v) && return "`$key` is empty"
    (startswith(v, '"') && endswith(v, '"')) && return nothing
    (startswith(v, '\'') && endswith(v, '\'')) && return nothing
    occursin(": ", v) && return "`$key` contains \": \" but is not quoted"
    occursin(" #", v) && return "`$key` contains ' #' but is not quoted"
    occursin(first(v), "\"'{}[]&*!|>%@`#") && return "`$key` starts with the YAML indicator '$(first(v))'"
    return nothing
end

# Is `key:` written as a YAML block scalar (`>`, `>-`, `|`, `|-`) in the front-matter?
function block_scalar(text, key)
    m = match(Regex("(?m)^" * key * ":[ \\t]*([>|][-+]?)[ \\t]*\$"), text)
    return m !== nothing
end

normalize_ws(s) = replace(strip(s), r"\s+" => " ")

# A: repo-relative paths inside backticks.
#   PATH_RE — file-ish, ends in an extension, e.g. `src/utilities/misc.jl`
#   DIR_RE  — directory-ish, trailing slash, e.g. `ext/NitroPormGExt/`
const PATH_RE = r"`((?:src|ext|test|docs|upgrading|\.github)/[A-Za-z0-9_./\-]+\.[A-Za-z0-9]+)`"
const DIR_RE  = r"`((?:src|ext|test|docs|upgrading|\.github)/[A-Za-z0-9_./\-]+/)`"

# B: markdown links `](target)` — capture the target.
const LINK_RE = r"\]\(([^)]+)\)"

# G: section pointers, all three spellings.
#   linked:   [nitro-core §4](nitro-core.instructions.md)          -- § inside the brackets
#   backtick: `nitro-core.instructions.md` §4
#   trailing: [`workers.instructions.md`](…/workers.instructions.md) §1   -- § after the link
# The trailing form is how skill-to-skill pointers are written; without it the check
# covered only the instruction-file pointers and cross-references rotted silently.
const SECTION_LINK_RE  = r"\[[^\]]*?§(\d+)\]\(([^)#]+)(?:#[^)]*)?\)"
const SECTION_TICK_RE  = r"`([A-Za-z0-9_\-]+\.instructions\.md)`[^\n]{0,12}?§(\d+)"
const SECTION_TRAIL_RE = r"\]\(([^)#\s]+\.md)(?:#[^)]*)?\)[ ]{0,2}§(\d+)"

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
        (occursin("://", target) || startswith(target, "#") || startswith(target, "mailto:")) && continue
        path = first(split(target, '#'))
        isempty(path) && continue
        resolved = normpath(joinpath(dirname(file), path))
        isfile(resolved) || isdir(resolved) ||
            push!(errors, "$(relpath(file, ROOT)): link target `$(target)` does not resolve to a file")
    end
end

# C: is `sym` defined anywhere under src/ or ext/?
function symbol_defined(sym)
    esc = replace(sym, r"([!])" => s"\\\1")
    # A call, an assignment, or a parametric use covers functions, constants and any
    # type with a constructor. A bare type declaration matches none of those --
    # `abstract type TaskAuthority end` has no `(`, `=` or `{` -- so match those too,
    # or the lint silently cannot verify an abstract type or a field-less struct.
    pat = Regex("(?:^|[^A-Za-z0-9_!])" * esc * "\\s*(?:\\(|=|\\{)" *
                "|(?:abstract\\s+type|primitive\\s+type|mutable\\s+struct|struct)\\s+" * esc * "\\b")
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

# G: does `file` contain a `## <n>.` heading?
function has_section(path, n)
    isfile(path) || return false
    return occursin(Regex("(?m)^#{2,3}\\s+" * string(n) * "\\."), read(path, String))
end

function lint_sections(file, text, errors)
    for m in eachmatch(SECTION_LINK_RE, text)
        n, target = m.captures[1], strip(m.captures[2])
        occursin("://", target) && continue
        resolved = normpath(joinpath(dirname(file), target))
        endswith(resolved, ".md") || continue
        has_section(resolved, n) ||
            push!(errors, "$(relpath(file, ROOT)): §$(n) pointer into `$(target)` has no matching `## $(n).` heading")
    end
    for m in eachmatch(SECTION_TICK_RE, text)
        target, n = m.captures[1], m.captures[2]
        resolved = joinpath(INSTRUCTIONS_DIR, target)
        has_section(resolved, n) ||
            push!(errors, "$(relpath(file, ROOT)): §$(n) pointer into `$(target)` has no matching `## $(n).` heading")
    end
    for m in eachmatch(SECTION_TRAIL_RE, text)
        target, n = strip(m.captures[1]), m.captures[2]
        occursin("://", target) && continue
        resolved = normpath(joinpath(dirname(file), target))
        has_section(resolved, n) ||
            push!(errors, "$(relpath(file, ROOT)): §$(n) pointer into `$(target)` has no matching `## $(n).` heading")
    end
end

# ---- structural checks -----------------------------------------------------

function lint_skill_frontmatter(errors)
    for name in tracked_subdirs(SKILLS_DIR)
        skill = joinpath(SKILLS_DIR, name, "SKILL.md")
        if !isfile(skill)
            push!(errors, ".github/skills/$(name)/: no SKILL.md")
            continue
        end
        fm = front_matter(read(skill, String))
        got = get(fm, "name", "")
        got == name ||
            push!(errors, ".github/skills/$(name)/SKILL.md: front-matter name `$(got)` != directory `$(name)`")
        isempty(get(fm, "description", "")) &&
            push!(errors, ".github/skills/$(name)/SKILL.md: empty or missing `description`")
    end
end

function lint_instruction_frontmatter(errors)
    isdir(INSTRUCTIONS_DIR) || return
    for f in sort(readdir(INSTRUCTIONS_DIR))
        endswith(f, ".md") || continue
        fm = front_matter(read(joinpath(INSTRUCTIONS_DIR, f), String))
        isempty(get(fm, "description", "")) &&
            push!(errors, ".github/instructions/$(f): empty or missing `description`")
    end
end

# E: the public sets are pinned, and the hub lists every member.
function lint_registry(errors)
    hub = joinpath(ROOT, HUB)
    if !isfile(hub)
        push!(errors, "$(HUB): canonical hub is missing")
        return
    end
    text = read(hub, String)

    actual_skills = tracked_subdirs(SKILLS_DIR)
    actual_skills == PUBLIC_SKILLS ||
        push!(errors, ".github/skills/: tracked skills are $(actual_skills), expected exactly " *
                      "$(PUBLIC_SKILLS) — the process skills live outside this repository; " *
                      "adding a public skill means editing PUBLIC_SKILLS and shipping its stub")

    listed_skills = Set{String}(m.captures[1] for m in
        eachmatch(r"\.github/skills/([A-Za-z0-9_\-]+)/SKILL\.md", text))
    for s in actual_skills
        s in listed_skills ||
            push!(errors, "$(HUB): skill `$(s)` exists but is not listed in the hub")
    end
    for s in sort(collect(setdiff(listed_skills, Set(actual_skills))))
        push!(errors, "$(HUB): lists `.github/skills/$(s)/SKILL.md` but that skill does not exist")
    end

    actual_rules = isdir(INSTRUCTIONS_DIR) ?
        String[f for f in sort(readdir(INSTRUCTIONS_DIR)) if endswith(f, ".md") && !islink(joinpath(INSTRUCTIONS_DIR, f))] :
        String[]
    actual_rules == PUBLIC_RULES ||
        push!(errors, ".github/instructions/: tracked rule files are $(actual_rules), expected exactly " *
                      "$(PUBLIC_RULES) — the process ruleset lives outside this repository")

    listed_rules = Set{String}(m.captures[1] for m in
        eachmatch(r"([A-Za-z0-9_\-]+\.instructions\.md)", text))
    for r in actual_rules
        r in listed_rules ||
            push!(errors, "$(HUB): rule file `$(r)` exists but is not listed in the area rule table")
    end
    for r in sort(collect(setdiff(listed_rules, Set(actual_rules))))
        push!(errors, "$(HUB): names `$(r)` but `.github/instructions/$(r)` does not exist")
    end
end

# F: the discovery stubs.
function lint_skill_stubs(errors)
    stubs = tracked_subdirs(CLAUDE_SKILLS_DIR)
    stubs == PUBLIC_SKILLS ||
        push!(errors, ".claude/skills/: tracked stubs are $(stubs), expected exactly $(PUBLIC_SKILLS) " *
                      "— a public skill without a stub is invisible to Claude Code, and a stub with " *
                      "no canonical file points at nothing (symlinked entries are ignored)")

    for n in PUBLIC_SKILLS
        canon_path = joinpath(SKILLS_DIR, n, "SKILL.md")
        stub_path  = joinpath(CLAUDE_SKILLS_DIR, n, "SKILL.md")
        (isfile(canon_path) && isfile(stub_path) && !islink(stub_path)) || continue   # reported above

        canon = read(canon_path, String)
        stub  = read(stub_path, String)
        canon_fm = front_matter_block(canon)
        stub_fm  = front_matter_block(stub)
        canon_fm === nothing &&
            push!(errors, ".github/skills/$(n)/SKILL.md: no parseable front-matter block")
        stub_fm === nothing &&
            push!(errors, ".claude/skills/$(n)/SKILL.md: no parseable front-matter block — discovery fails silently")
        (canon_fm !== nothing && stub_fm !== nothing && canon_fm != stub_fm) &&
            push!(errors, ".claude/skills/$(n)/SKILL.md: front-matter differs from .github/skills/$(n)/SKILL.md " *
                          "— `name:` drift breaks invocation, `description:` drift breaks skill selection")

        occursin(".github/skills/$(n)/SKILL.md", stub) ||
            push!(errors, ".claude/skills/$(n)/SKILL.md: body does not name `.github/skills/$(n)/SKILL.md`")
        filesize(stub_path) <= STUB_MAX_BYTES ||
            push!(errors, ".claude/skills/$(n)/SKILL.md: $(filesize(stub_path)) bytes > $(STUB_MAX_BYTES) " *
                          "— a stub is a pointer; put the content in the canonical file")

        for (label, text) in ((".github/skills/$(n)/SKILL.md", canon), (".claude/skills/$(n)/SKILL.md", stub))
            fm = front_matter(text)
            for key in ("name", "description")
                haskey(fm, key) || continue
                # A folded/literal block (`description: >-` …) is not a plain scalar: `: ` and
                # ` #` are ordinary characters inside it, so only the inline form is policed.
                block_scalar(text, key) && continue
                problem = yaml_scalar_problem(key, fm[key])
                problem === nothing || push!(errors, "$(label): $(problem)")
            end
            get(fm, "name", "") == n ||
                push!(errors, "$(label): front-matter name `$(get(fm, "name", ""))` != `$(n)`")
        end
    end
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
        lint_sections(file, text, errors)
    end

    for sym in REQUIRED_SYMBOLS
        symbol_defined(sym) ||
            push!(errors, "REQUIRED_SYMBOLS: `$(sym)` referenced by docs is not defined in src/ or ext/")
    end

    lint_skill_frontmatter(errors)
    lint_instruction_frontmatter(errors)
    lint_registry(errors)
    lint_skill_stubs(errors)

    if isempty(errors)
        println("docs_lint: OK — $(length(docs)) docs, $(length(REQUIRED_SYMBOLS)) symbols, " *
                "public skill/rule sets + stubs + § anchors checked")
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
