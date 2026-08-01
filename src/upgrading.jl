# upgrade_guide — version-scoped emitter over UPGRADING.md
#
# Nitro versions per *release train*, not per PR: a breaking/behavior PR appends an entry to the
# `## Unreleased` section of UPGRADING.md without touching Project.toml, and the maintainer cuts a
# train (bump + stamp + tag) via the `nitro-cut-release` skill. This file is the read side of that
# model — it turns the log into the slice a given consuming app still has to port.

# An entry with no `- **Version**:` bullet at all (malformed, or written before it was stamped by
# hand) sorts below every real release, so a scoped lookup never silently swallows it into the
# current train. `0.1.0` is the baseline of the policy; nothing legitimately predates it.
const _UNSTAMPED_VERSION = v"0.1.0-"

# Entries under the `## Unreleased` heading carry `- **Version**: Unreleased` — changes merged but
# not yet cut into a release train. They sort ABOVE every real version so a consumer dev'ing Nitro
# at HEAD sees the uncut work they are actually running; cutting the train rewrites `Unreleased` to
# the assigned release number.
const _UNRELEASED_VERSION = v"1000000.0.0"

# `_UNRELEASED_VERSION` is an internal sort key, never a user-facing version. Render it as the
# literal `UPGRADING.md` token so output reads "0.1.0 → Unreleased" and not "0.1.0 → 1000000.0.0".
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

_asver(v::VersionNumber) = v
_asver(v::AbstractString) = VersionNumber(v)

"""
    _read_upgrading_entries() -> Vector{_UpgradeEntry}

Parse the `UPGRADING.md` bundled with the resolved Nitro install into change entries, newest-first.
"""
function _read_upgrading_entries()
    path = joinpath(Base.pkgdir(@__MODULE__), "UPGRADING.md")
    isfile(path) || throw(ArgumentError(
        "UPGRADING.md not found next to the installed Nitro (looked in $(dirname(path)))."))
    return _parse_upgrading(read(path, String))
end

"""
    _parse_upgrading(text::AbstractString) -> Vector{_UpgradeEntry}

Parse raw `UPGRADING.md` text into change entries, newest-first (see `_read_upgrading_entries`).
Split out so the parser can be exercised on hand-fed text — the CRLF-robustness case in particular
— without touching the on-disk file.

Line endings are normalized to `\\n` up front: a Windows checkout can store `UPGRADING.md` with
`\\r\\n`, and the `(?m)^---[ \\t]*\$` block separator never matches a `---\\r` line — without this
the whole file collapses into a single bogus entry and every scoped lookup comes back empty.
"""
function _parse_upgrading(text::AbstractString)
    text = replace(text, "\r\n" => "\n", "\r" => "\n")

    # Drop the "## Template for new entries" section: its body is an HTML comment holding a
    # fake `## …` heading and a `- **Version**:` placeholder that would parse as a bogus entry.
    tmpl = findfirst("## Template for new entries", text)
    tmpl === nothing || (text = text[1:prevind(text, first(tmpl))])

    entries = _UpgradeEntry[]
    for block in split(text, r"(?m)^---[ \t]*$")
        # A cut writes the release marker (`## 0.1.0 — 2026-07-31`) directly above the first entry
        # of that release with NO `---` between them, so the first `##` in a block is not
        # necessarily the entry's own heading. Take the first non-marker heading instead —
        # otherwise the first entry of every release is titled with the release date and its real
        # title is lost (visible via `structured = true`).
        title_m = nothing
        for h in eachmatch(r"(?m)^##[ \t]+(.+)$", block)
            occursin(_RELEASE_MARKER, strip(h[1])) && continue
            title_m = h
            break
        end

        # A real change entry has a non-marker `## ` heading AND a `- **Recorded**:` bullet — this
        # rejects the header/recipe prose and any stray section, regardless of `---` placement.
        (title_m === nothing || !occursin(r"(?m)^-[ \t]+\*\*Recorded\*\*:", block)) && continue

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
    end
    return entries
end

"""
    upgrade_guide([io::IO = stdout]; from, to = <current code>, structured = false)

Print the `UPGRADING.md` entries a consuming app must work through to move from Nitro version
`from` up to `to`. The default `to` covers the **current code** — every released entry **plus** the
uncut `## Unreleased` changes the install is running (release-train model), so a consumer dev'ing
Nitro at HEAD sees work that has not been stamped with a release number yet. Pass
`to = pkgversion(Nitro)` to scope to the installed *release* only. Reads the `UPGRADING.md` shipped
with the *resolved* Nitro install, so the scope is accurate against the version your app actually
depends on — not a latest-on-GitHub copy that may not match.

Entries print newest-first; each keeps its "How to find the calls to migrate" grep and its
`before → after`.

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
