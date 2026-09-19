# upgrade_guide — version-scoped emitter over the `upgrading/` change log
#
# Nitro versions per *release train*, not per PR: a breaking/behavior PR adds ONE NEW FILE to
# `upgrading/` carrying `- **Version**: Unreleased`, without touching Project.toml, and the
# maintainer cuts a train (bump + stamp + tag) via the `nitro-cut-release` skill. This file is the
# read side of that model — it turns the log into the slice a given consuming app still has to port.
#
# One file per entry is deliberate (#192). The log used to be a single UPGRADING.md whose
# `## Unreleased` header was the one anchor every session prepended to, which made a merge conflict
# CERTAIN between any two concurrent sessions that both owed an entry — and certain in the one file
# whose whole job is to be the compatibility story. A file per entry makes that conflict
# unrepresentable rather than merely auto-resolvable. UPGRADING.md survives as the authoring
# contract and is no longer parsed.
#
# The entry GRAMMAR below is unchanged by that split, on purpose: a one-entry file is a single
# block, so the `^---$` split, the release-marker filter and the #89 diagnostics all still hold —
# they now describe what may appear inside one file rather than between entries in one log.

# An entry with no `- **Version**:` bullet at all (malformed, or written before it was stamped by
# hand) sorts below every real release, so a scoped lookup never silently swallows it into the
# current train. `0.1.0` is the baseline of the policy; nothing legitimately predates it.
const _UNSTAMPED_VERSION = v"0.1.0-"

# An uncut entry carries `- **Version**: Unreleased` — merged but not yet cut into a release
# train. They sort ABOVE every real version so a consumer dev'ing Nitro
# at HEAD sees the uncut work they are actually running; cutting the train rewrites `Unreleased` to
# the assigned release number.
const _UNRELEASED_VERSION = v"1000000.0.0"

# `_UNRELEASED_VERSION` is an internal sort key, never a user-facing version. Render it as the
# literal change-log token so output reads "0.1.0 → Unreleased" and not "0.1.0 → 1000000.0.0".
_version_label(v::VersionNumber) = v == _UNRELEASED_VERSION ? "Unreleased" : string(v)

const _UpgradeEntry = @NamedTuple{version::VersionNumber, title::String, body::String}

# A release marker heading — `## 0.1.0 — 2026-07-31` or `## Unreleased — next \`0.2.0\``, both
# written when cutting a train. It groups the entries of one release; it is NOT an entry title.
#
# The em-dash separator is REQUIRED, not decoration: without it this also matches a real entry whose
# title merely starts with a version (`## 0.5.0 config format is now strict`), and the parser then
# finds no other `##` in that block and drops the entry SILENTLY — it just disappears from the
# guide. Both forms the cut writes carry the separator, so requiring it costs nothing.
const _RELEASE_MARKER = r"^(?:Unreleased|\d+\.\d+\.\d+)\s+—"

# The bullets a change entry writes at column 0. A block carrying any of them is *claiming to be an
# entry*, and that claim is what separates a malformed entry — worth reporting, because otherwise it
# vanishes from `upgrade_guide` without a trace — from legitimate non-entry prose. The shipped log
# holds nothing but entries now, so this matters for hand-fed text: the header and `## Writing an
# entry` recipe of a single-file log, or a bare release marker with nothing cut under it yet.
#
# Structural, not positional, on purpose. "Everything above the first `---` is preamble" also
# describes today's file, but it is a fact about layout rather than content: it cannot be exercised
# on the single-block texts this parser's own tests hand it, it would warn forever on any prose
# section added elsewhere in the file, and `_parse_upgrading` is documented as parsing hand-fed text,
# so it has no business acquiring a notion of position within a file.
#
# The recipe in the header survives this because it writes its example indented AND inside backticks,
# so the anchored `^-` never matches it. `test/upgrade_guide_tests.jl` pins that, so a reformat fails
# loudly there instead of spraying a warning at every consuming app.
const _ENTRY_BULLET = r"(?m)^-[ \t]+\*\*(?:Version|Recorded|Severity|Nitro ref)\*\*:"

const _WHY_NO_RECORDED = "missing its `- **Recorded**:` bullet"
const _WHY_NO_HEADING  = "entry bullets under no `## ` heading of its own"
const _WHY_SWALLOWED   = "a second entry in the same block, so it was absorbed into the entry above"

# `title` is the entry that failed to reach the guide, empty when the block had no heading to name
# it with. `near` is where to go looking: the block's first non-blank line when there is no title,
# or the title of the entry that swallowed this one.
const _UpgradeProblem = @NamedTuple{title::String, near::String, reason::String}

# First non-blank line of a block, truncated — locates a problem block that has no heading to name.
function _first_line(block::AbstractString, width::Int = 60)
    for ln in eachsplit(block, '\n')
        s = strip(ln)
        isempty(s) || return String(first(s, width))
    end
    return ""
end

# One line per problem for the warning's `missing_entries` field.
function _describe(p::_UpgradeProblem)
    isempty(p.title) && return "(no heading, near \"$(p.near)\") — $(p.reason)"
    isempty(p.near)  && return "$(p.title) — $(p.reason)"
    return "$(p.title) — $(p.reason): \"$(p.near)\""
end

_asver(v::VersionNumber) = v
_asver(v::AbstractString) = VersionNumber(v)

"""
    _upgrading_dir() -> String

Absolute path to the `upgrading/` change log bundled with the resolved Nitro install. Split out so
the test suite reads the same directory the parser does, instead of recomputing the join and
drifting from it.
"""
function _upgrading_dir()
    dir = joinpath(Base.pkgdir(@__MODULE__), "upgrading")
    isdir(dir) || throw(ArgumentError(
        "upgrading/ not found next to the installed Nitro (looked in $(dirname(dir)))."))
    return dir
end

"""
    _upgrading_files() -> Vector{String}

Every change-entry file in `upgrading/`, newest-first by filename.

**Every `.md` in the directory is an entry — there is no name-pattern gate**, deliberately. A
reader that skipped files not matching `<date>-<slug>.md` would make a mis-named entry vanish from
the guide silently, which is precisely the failure class #89 exists to prevent. The naming
convention is enforced by the test suite, where a violation is loud, rather than by the reader,
where it would be mute.
"""
function _upgrading_files()
    dir = _upgrading_dir()
    return [joinpath(dir, f) for f in sort(readdir(dir), rev = true) if endswith(f, ".md")]
end

"""
    _read_upgrading_entries() -> Vector{_UpgradeEntry}

Parse the `upgrading/` change log bundled with the resolved Nitro install into change entries,
newest-first.

The sort is the contract, not the directory listing. Under the old single-file log, newest-first
was a property of the hand-maintained layout that the parser merely preserved — nothing enforced
it. Sorting by version here makes it hold by construction; `MergeSort` is stable, so entries
sharing a version keep `_upgrading_files`' filename-descending (= date-descending) order.
"""
function _read_upgrading_entries()
    entries = _UpgradeEntry[]
    for path in _upgrading_files()
        append!(entries, _parse_upgrading(read(path, String); source = path))
    end
    return sort!(entries; by = e -> e.version, rev = true, alg = MergeSort)
end

"""
    _scan_upgrading(text::AbstractString) -> (; entries, problems)

One pass over one change-entry file's text producing both halves: the accepted change entries, and
the change entries that never reached the guide (`problems`) — a block that looked like an entry
and was rejected, or an entry absorbed into its neighbour because they share a block.

The diagnostic is built here, in the same branch as the acceptance rule, so the two cannot drift — a
reason to reject a block and a reason to report it are literally the same condition. `problems` is
observation only: it never changes which entries come back.

Line endings are normalized to `\\n` up front: a Windows checkout can store an entry file with
`\\r\\n`, and the `(?m)^---[ \\t]*\$` block separator never matches a `---\\r` line — without this
the whole text collapses into a single bogus entry and every scoped lookup comes back empty.
"""
function _scan_upgrading(text::AbstractString)
    text = replace(text, "\r\n" => "\n", "\r" => "\n")

    # Drop the "## Template for new entries" section: its body is an HTML comment holding a
    # fake `## …` heading and a `- **Version**:` placeholder that would parse as a bogus entry.
    tmpl = findfirst("## Template for new entries", text)
    tmpl === nothing || (text = text[1:prevind(text, first(tmpl))])

    entries  = _UpgradeEntry[]
    problems = _UpgradeProblem[]

    for block in split(text, r"(?m)^---[ \t]*$")
        # A cut writes the release marker (`## 0.1.0 — 2026-07-31`) directly above the first entry
        # of that release with NO `---` between them, so the first `##` in a block is not
        # necessarily the entry's own heading. Take the first non-marker heading instead —
        # otherwise the first entry of every release is titled with the release date and its real
        # title is lost (visible via `structured = true`).
        heads = [h for h in eachmatch(r"(?m)^##[ \t]+(.+)$", block)
                 if !occursin(_RELEASE_MARKER, strip(h[1]))]
        title_m = isempty(heads) ? nothing : first(heads)

        # A real change entry has a non-marker `## ` heading AND a `- **Recorded**:` bullet — this
        # rejects the header/recipe prose and any stray section, regardless of `---` placement.
        if title_m === nothing || !occursin(r"(?m)^-[ \t]+\*\*Recorded\*\*:", block)
            # #89: this used to be a bare `continue`, which made a MALFORMED entry and an ABSENT
            # entry indistinguishable — the entry simply stopped existing, in the guide and in
            # `structured = true`, with nothing said in either direction. Record the blocks that
            # were *trying* to be entries (`_ENTRY_BULLET`). The acceptance test above is
            # unchanged; this branch only observes.
            occursin(_ENTRY_BULLET, block) && push!(problems, (
                title  = title_m === nothing ? "" : String(strip(title_m[1])),
                near   = title_m === nothing ? _first_line(block) : "",
                reason = title_m === nothing ? _WHY_NO_HEADING : _WHY_NO_RECORDED))
            continue
        end

        ver_m = match(r"(?m)^-[ \t]+\*\*Version\*\*:[ \t]*(\S+)", block)
        version = ver_m === nothing        ? _UNSTAMPED_VERSION  :
                  ver_m[1] == "Unreleased" ? _UNRELEASED_VERSION :
                                             VersionNumber(ver_m[1])

        # Start the body at the entry's own heading. This drops a leading release marker, so every
        # entry renders identically — otherwise only the first entry of a release carries the
        # `## <ver> — <date>` line, making later entries from *other* releases look like they
        # belonged to it. Each entry states its own `- **Version**:`, so nothing is lost.
        body = block[title_m.offset:end]

        push!(entries, (version = version,
                        title = String(strip(title_m[1])),
                        body = String(strip(body))))

        # #89's other half, and the one that actually shipped: at 49f1a23 the `## Unreleased`
        # section ran #71, #18 and #16 with no `---` between them, so all three parsed as #71 and
        # the last two vanished. An entry prepended without its trailing `---` lands in THIS block,
        # so the block still satisfies acceptance above — as its neighbour. The swallowed entry's
        # prose renders under the wrong title and `structured = true` loses it outright, with
        # nothing said. (That same block is the missing-`Recorded` case too: #71's header carried
        # only `- **Version**: Unreleased`, and it survived solely by being glued to its
        # neighbours' bullets. Both halves of #89 came out of one block.)
        for (i, h) in Iterators.drop(enumerate(heads), 1)
            # Only a heading that carries entry bullets of its own is a swallowed *entry*. A `## `
            # line inside a fenced code block in an entry body is not — an entry showing the
            # markdown it changes would otherwise report itself.
            stop = i < length(heads) ? prevind(block, heads[i + 1].offset) : lastindex(block)
            occursin(_ENTRY_BULLET, block[h.offset:stop]) || continue

            push!(problems, (title  = String(strip(h[1])),
                             near   = String(strip(title_m[1])),
                             reason = _WHY_SWALLOWED))
        end
    end
    return (entries = entries, problems = problems)
end

"""
    _parse_upgrading(text::AbstractString; source = "the upgrade log") -> Vector{_UpgradeEntry}

Parse one change-entry file's raw text into change entries (see `_read_upgrading_entries`), and
`@warn` about any change entry that did not reach the guide — a block that looked like an entry and
was rejected, or an entry absorbed into its neighbour because they share a block. Split out from
`_read_upgrading_entries` so the parser can be exercised on hand-fed text — the CRLF-robustness case
in particular — without touching the on-disk files. `source` only labels the warning.

Warn rather than throw: a defect in the log must not take `upgrade_guide` down for a consuming app
that had nothing to do with it, and the other entries are still correct and still needed. The
entries returned are byte-identical to what this returned before the diagnostic existed.
"""
function _parse_upgrading(text::AbstractString; source::AbstractString = "the upgrade log")
    (; entries, problems) = _scan_upgrading(text)

    # One aggregate record, deliberately without `maxlog`: `maxlog` keys on the call SITE, not the
    # message, so `maxlog = 1` would hide a second, *different* malformed block, and would report
    # all-clear on a re-parse after a failed fix attempt — the one answer that must never be wrong
    # here. Entry titles are public change-log prose, so no secret reaches this log.
    isempty(problems) || @warn(
        "Nitro's upgrade log holds change entries that `upgrade_guide` could not emit — each was " *
        "either skipped outright or absorbed into the entry above it, so it does NOT appear in " *
        "the output above. An entry needs a non-release-marker `## ` heading, a " *
        "`- **Recorded**:` bullet, and a file of its own under `upgrading/`. If you are a " *
        "consuming app rather than a Nitro maintainer, please report this: the upgrade slice you " *
        "were shown is incomplete.",
        source           = source,
        missing_entries  = _describe.(problems))

    return entries
end

"""
    _upgrading_problems(text::AbstractString) -> Vector{_UpgradeProblem}

The blocks `_parse_upgrading` would warn about, as data and **without logging** — so a test can
assert on them, including asserting there are none, without wrapping every call in `@test_logs`.
"""
_upgrading_problems(text::AbstractString) = _scan_upgrading(text).problems

"""
    upgrade_guide([io::IO = stdout]; from, to = <current code>, structured = false)

Print the change-log entries a consuming app must work through to move from Nitro version `from`
up to `to`. The default `to` covers the **current code** — every released entry **plus** the uncut
`Unreleased` changes the install is running (release-train model), so a consumer dev'ing Nitro at
HEAD sees work that has not been stamped with a release number yet. Pass
`to = pkgversion(Nitro)` to scope to the installed *release* only. Reads the `upgrading/` log
shipped with the *resolved* Nitro install, so the scope is accurate against the version your app
actually depends on — not a latest-on-GitHub copy that may not match.

Entries print newest-first; each keeps its "How to find the calls to migrate" grep and its
`before → after`.

If Nitro's log holds an entry this cannot emit, `upgrade_guide` warns and names it — either the
entry was rejected outright, or it shares a file with the entry above and was absorbed into it (its
prose then renders under that entry's title, and `structured = true` drops it). Either way it is
missing from the slice you were shown, so read it directly in the log and report it.

`from` is required — pass the Nitro version your app currently depends on. Both `from` and `to`
accept a `VersionNumber` or a version string (`v"0.1"` or `"0.1"`).

Pass `structured = true` to get the entries back as data instead of printing — a `Vector` of
`(; version, title, body)` named tuples, newest-first — for programmatic consumers.

# Examples
```julia
julia> using Nitro

julia> Nitro.upgrade_guide(from = v"0.1")            # everything newer than your pin

julia> Nitro.upgrade_guide(from = "0.1", to = "0.2")

julia> entries = Nitro.upgrade_guide(from = v"0.1", structured = true);
```
"""
function upgrade_guide(io::IO = stdout; from = nothing, to = _UNRELEASED_VERSION,
                       structured::Bool = false)
    from === nothing && throw(ArgumentError(
        "upgrade_guide requires `from` — the Nitro version your app currently depends on, " *
        "e.g. `upgrade_guide(from = v\"0.1\")`."))
    from_v = _asver(from)
    to_v   = _asver(to)

    entries = filter(e -> from_v < e.version <= to_v, _read_upgrading_entries())

    structured && return entries

    if isempty(entries)
        println(io, "# Nitro: nothing to port between $(_version_label(from_v)) and $(_version_label(to_v)).")
        return nothing
    end

    println(io, "# Porting a Nitro consumer from $(_version_label(from_v)) → $(_version_label(to_v))")
    println(io, "# Work newest-first; for each entry run its \"How to find the calls to migrate\"")
    println(io, "# grep, apply before → after, then run your app's tests.")
    for e in entries
        println(io)
        println(io, e.body)
    end
    return nothing
end
