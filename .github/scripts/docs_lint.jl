#!/usr/bin/env julia
#
# docs_lint.jl — guard the agent-context docs against drift.
#
# The agent-doc system is built on one rule: *one fact, one home*. AGENTS.md is a
# thin pointer, `.github/instructions/nitro-general.instructions.md` is the
# canonical hub, area files own their area, and `.github/skills/` holds
# workflows. That only stays true if every *cross-reference* between them is
# checked — otherwise the hub silently rots into a second, wrong copy.
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
#      non-empty `description`; every instruction file declares `applyTo` and
#      `description`.
#   E. Registry parity — every directory under `.github/skills/` is listed in the
#      hub's skill table, and every instruction file is listed in its rule table.
#      A skill nobody links to is invisible; a table row for a deleted skill is a
#      lie.
#   F. Plugin manifest — `.github/skills/` is the ONLY home for skill content.
#      Copilot and Codex read it directly; Claude Code reaches it through the
#      repo-local plugin in `.claude-plugin/`, whose `skills` path points there.
#      This check pins that pointer, verifies the marketplace lists the plugin,
#      and fails if a second `.claude/skills/` tree ever reappears.
#   G. Section-anchor references — a pointer like `[nitro-core §4](…)` or
#      "`nitro-core.instructions.md` §4" must resolve to a real `## 4.` heading in
#      that file. The hub's hard-stop index is built entirely out of these, so an
#      unchecked § pointer is exactly how the index rots.
#   I. Subagent envelopes — a quarantined agent (one whose purpose is that it
#      CANNOT act) must declare an explicit tools list containing no acting tool.
#      A quarantine that silently gains Bash is worse than none, because every
#      doc still claims it holds. See docs/design/agent-security.md.
#   H. `applyTo` coverage — every glob in an instruction file's front-matter
#      matches at least one tracked file. Catches a rule scoped to a directory
#      that has since been renamed.
#
# What it does NOT catch (documented so nobody trusts it too far):
#   - Wrong overload / signature drift (e.g. `Res.status(code, msg)` when only
#     `Res.status(code)` exists). Symbol-*existence* only; no Julia parsing.
#   - A symbol that exists in the wrong namespace (`Res.html` vs `html`) — check C
#     is namespace-blind. Add such pairs to REQUIRED_SYMBOLS only by their
#     defining name.
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
    joinpath(".claude", "agents"),
    joinpath(".github", "instructions"),
    joinpath(".github", "skills"),
]

# The canonical hub: the file that must list every skill and every rule file.
const HUB = joinpath(".github", "instructions", "nitro-general.instructions.md")

const SKILLS_DIR       = joinpath(ROOT, ".github", "skills")
const CLAUDE_SKILLS_DIR = joinpath(ROOT, ".claude", "skills")
const PLUGIN_MANIFEST  = joinpath(ROOT, ".claude-plugin", "plugin.json")
const PLUGIN_MARKET    = joinpath(ROOT, ".claude-plugin", "marketplace.json")
const CLAUDE_AGENTS_DIR = joinpath(ROOT, ".claude", "agents")
const INSTRUCTIONS_DIR = joinpath(ROOT, ".github", "instructions")

# Subagents whose whole purpose is a reduced capability envelope. If one of these
# ever gains a tool that can act (Bash, Write, Edit, WebFetch), the quarantine it
# implements is silently gone while every doc still claims it holds — so the
# allowed toolset is pinned here and checked. See docs/design/agent-security.md.
const QUARANTINED_AGENTS = Dict{String,Set{String}}(
    "issue-reader" => Set(["Read", "Grep", "Glob"]),
)

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
    "worker_startup", "serve", "terminate", "resetstate", "internalrequest", "instance",
    "path", "urlpatterns", "include_routes", "url",
    "submit_task", "get_task_status", "cancel_task", "get_all_tasks",
    "set_queue_authorizer!", "pormg_nitro_worker",
    "add_response_headers", "own_response_headers",
    "login_required", "role_required", "permission_required", "claim_required",
    "kid_required", "Principal",
    # Response constructors — the markup sinks the security rules name.
    "html", "js", "css", "xml", "text", "binary",
    # Request/body plumbing the usage skill teaches.
    "formdata", "multipart", "payload", "getcontext", "regenerate_session!",
    "staticfiles", "spafiles", "dynamicfiles",
    # Middleware constructors.
    "SessionMiddleware", "CSRFMiddleware", "Cors", "RateLimiter", "ExtractIP",
    "extract_ip", "getpeerip",
    "BearerAuth", "CookieAuthMiddleware", "GuardMiddleware", "AccessLog",
    "SecretString", "reveal",
    # Release-train tooling — the versioning rule and cut-release skill name these.
    "upgrade_guide", "_parse_upgrading",
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

normalize_ws(s) = replace(strip(s), r"\s+" => " ")

# A: repo-relative paths inside backticks.
#   PATH_RE — file-ish, ends in an extension, e.g. `src/utilities/misc.jl`
#   DIR_RE  — directory-ish, trailing slash, e.g. `ext/NitroPormGExt/`
const PATH_RE = r"`((?:src|ext|test|docs|\.github)/[A-Za-z0-9_./\-]+\.[A-Za-z0-9]+)`"
const DIR_RE  = r"`((?:src|ext|test|docs|\.github)/[A-Za-z0-9_./\-]+/)`"

# B: markdown links `](target)` — capture the target.
const LINK_RE = r"\]\(([^)]+)\)"

# G: section pointers, both spellings.
#   linked:   [nitro-core §4](nitro-core.instructions.md)
#   backtick: `nitro-core.instructions.md` §4
const SECTION_LINK_RE = r"\[[^\]]*?§(\d+)\]\(([^)#]+)(?:#[^)]*)?\)"
const SECTION_TICK_RE = r"`([A-Za-z0-9_\-]+\.instructions\.md)`[^\n]{0,12}?§(\d+)"

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
    pat = Regex("(?:^|[^A-Za-z0-9_!])" * esc * "\\s*(?:\\(|=|\\{)")
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
end

# H: convert a front-matter glob to a regex and test it against tracked files.
function glob_matches_any(glob, all_files)
    pat = replace(glob, r"[.()\[\]+^$]" => s -> "\\" * s)
    pat = replace(pat, "**/" => "\x00")     # `**/` may match zero segments
    pat = replace(pat, "**" => "\x01")
    pat = replace(pat, "*" => "[^/]*")
    pat = replace(pat, "\x00" => "(?:.*/)?")
    pat = replace(pat, "\x01" => ".*")
    re = Regex("^" * pat * "\$")
    return any(f -> occursin(re, f), all_files)
end

function tracked_files()
    files = String[]
    for (dir, _, fs) in walkdir(ROOT)
        occursin(joinpath(ROOT, ".git"), dir) && continue
        for f in fs
            push!(files, replace(relpath(joinpath(dir, f), ROOT), '\\' => '/'))
        end
    end
    return files
end

# ---- structural checks -----------------------------------------------------

function lint_skill_frontmatter(errors)
    isdir(SKILLS_DIR) || return
    for name in sort(readdir(SKILLS_DIR))
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

function lint_instruction_frontmatter(errors, all_files)
    isdir(INSTRUCTIONS_DIR) || return
    for f in sort(readdir(INSTRUCTIONS_DIR))
        endswith(f, ".md") || continue
        fm = front_matter(read(joinpath(INSTRUCTIONS_DIR, f), String))
        isempty(get(fm, "description", "")) &&
            push!(errors, ".github/instructions/$(f): empty or missing `description`")
        applyto = get(fm, "applyTo", "")
        if isempty(applyto)
            push!(errors, ".github/instructions/$(f): missing `applyTo` glob")
            continue
        end
        for glob in split(strip(applyto, ['\'', '"']), ',')
            g = strip(glob)
            (isempty(g) || g == "**") && continue
            glob_matches_any(g, all_files) ||
                push!(errors, ".github/instructions/$(f): applyTo glob `$(g)` matches no file")
        end
    end
end

function lint_registry(errors)
    hub = joinpath(ROOT, HUB)
    if !isfile(hub)
        push!(errors, "$(HUB): canonical hub is missing")
        return
    end
    text = read(hub, String)

    listed_skills = Set{String}(m.captures[1] for m in
        eachmatch(r"\.github/skills/([A-Za-z0-9_\-]+)/SKILL\.md", text))
    actual_skills = isdir(SKILLS_DIR) ?
        Set{String}(d for d in readdir(SKILLS_DIR) if isdir(joinpath(SKILLS_DIR, d))) : Set{String}()

    for s in sort(collect(setdiff(actual_skills, listed_skills)))
        push!(errors, "$(HUB): skill `$(s)` exists but is not listed in the skill registry table")
    end
    for s in sort(collect(setdiff(listed_skills, actual_skills)))
        push!(errors, "$(HUB): skill registry lists `$(s)` but `.github/skills/$(s)/` does not exist")
    end

    listed_rules = Set{String}(m.captures[1] for m in
        eachmatch(r"([A-Za-z0-9_\-]+\.instructions\.md)", text))
    actual_rules = isdir(INSTRUCTIONS_DIR) ?
        Set{String}(f for f in readdir(INSTRUCTIONS_DIR) if endswith(f, ".instructions.md")) : Set{String}()
    hub_basename = basename(HUB)

    for r in sort(collect(setdiff(actual_rules, union(listed_rules, Set([hub_basename])))))
        push!(errors, "$(HUB): rule file `$(r)` exists but is not listed in the deep-dive table")
    end
end

function lint_agents(errors)
    isdir(CLAUDE_AGENTS_DIR) || return
    hub = joinpath(ROOT, HUB)
    hubtext = isfile(hub) ? read(hub, String) : ""

    for f in sort(readdir(CLAUDE_AGENTS_DIR))
        endswith(f, ".md") || continue
        name = f[1:end-3]
        fm = front_matter(read(joinpath(CLAUDE_AGENTS_DIR, f), String))

        get(fm, "name", "") == name ||
            push!(errors, ".claude/agents/$(f): front-matter name `$(get(fm, "name", ""))` != filename `$(name)`")
        isempty(get(fm, "description", "")) &&
            push!(errors, ".claude/agents/$(f): empty or missing `description`")

        occursin(".claude/agents/$(f)", hubtext) ||
            push!(errors, "$(HUB): subagent `$(name)` exists but is not listed in the Subagents table")

        # Capability-envelope pin: a quarantined agent must never gain an acting tool.
        if haskey(QUARANTINED_AGENTS, name)
            declared = get(fm, "tools", "")
            if isempty(declared)
                push!(errors, ".claude/agents/$(f): quarantined agent must declare an explicit `tools:` list")
            else
                got = Set(strip(t) for t in split(declared, ',') if !isempty(strip(t)))
                allowed = QUARANTINED_AGENTS[name]
                extra = setdiff(got, allowed)
                isempty(extra) ||
                    push!(errors, ".claude/agents/$(f): quarantined agent grants disallowed tool(s) " *
                                  "$(join(sort(collect(extra)), ", ")) — the quarantine only holds while it cannot act")
            end
        end
    end

    for name in sort(collect(keys(QUARANTINED_AGENTS)))
        isfile(joinpath(CLAUDE_AGENTS_DIR, name * ".md")) ||
            push!(errors, ".claude/agents/$(name).md: pinned quarantined agent is missing")
    end
end

function lint_plugin_manifest(errors)
    # `.github/skills/` is the single home for skill content. Copilot and Codex read it
    # directly; Claude Code reaches it through the repo-local plugin declared in
    # `.claude-plugin/`, whose manifest carries a custom `skills` path. If that path drifts
    # from `.github/skills/`, every `/<name>` invocation silently stops resolving while the
    # files still look fine — so the pointer is checked here rather than trusted.
    #
    # Deliberately regex, not a JSON parse: this script runs on stdlib only (see ci.yml).

    if isdir(CLAUDE_SKILLS_DIR)
        push!(errors, ".claude/skills/: exists again — skills live only in .github/skills/, " *
                      "reached via .claude-plugin/plugin.json. Delete it.")
    end

    if !isfile(PLUGIN_MANIFEST)
        push!(errors, ".claude-plugin/plugin.json: missing — Claude Code cannot invoke any skill as /<name>")
        return
    end
    manifest = read(PLUGIN_MANIFEST, String)

    skills_m = match(r"\"skills\"\s*:\s*\"([^\"]*)\"", manifest)
    if skills_m === nothing
        push!(errors, ".claude-plugin/plugin.json: no `skills` field — it is what points Claude Code at .github/skills/")
    elseif !occursin(r"\.github/skills/?$", skills_m[1])
        push!(errors, ".claude-plugin/plugin.json: `skills` is \"$(skills_m[1])\", expected \"./.github/skills/\"")
    end

    plugin_name_m = match(r"\"name\"\s*:\s*\"([^\"]*)\"", manifest)
    plugin_name = plugin_name_m === nothing ? "" : plugin_name_m[1]
    isempty(plugin_name) && push!(errors, ".claude-plugin/plugin.json: no `name` field")

    if !isfile(PLUGIN_MARKET)
        push!(errors, ".claude-plugin/marketplace.json: missing — the plugin has nothing to install it from")
        return
    end
    market = read(PLUGIN_MARKET, String)
    if !isempty(plugin_name) && !occursin("\"$(plugin_name)\"", market)
        push!(errors, ".claude-plugin/marketplace.json: does not list plugin `$(plugin_name)`")
    end

    # Every skill directory must still carry a SKILL.md, or the plugin loads a partial set.
    isdir(SKILLS_DIR) || return
    for name in sort(readdir(SKILLS_DIR))
        dir = joinpath(SKILLS_DIR, name)
        isdir(dir) || continue
        isfile(joinpath(dir, "SKILL.md")) ||
            push!(errors, ".github/skills/$(name)/: no SKILL.md — the plugin will skip it")
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

    all_files = tracked_files()
    lint_skill_frontmatter(errors)
    lint_instruction_frontmatter(errors, all_files)
    lint_registry(errors)
    lint_plugin_manifest(errors)
    lint_agents(errors)

    if isempty(errors)
        println("docs_lint: OK — $(length(docs)) docs, $(length(REQUIRED_SYMBOLS)) symbols, " *
                "registry + plugin manifest + § anchors + applyTo globs checked")
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
