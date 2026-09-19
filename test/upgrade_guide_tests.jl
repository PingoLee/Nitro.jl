@testitem "upgrade_guide" tags=[:core] setup=[NitroCommon] begin
using Test
using Nitro
using Nitro: _parse_upgrading, _read_upgrading_entries, _version_label,
             _UNRELEASED_VERSION, _UNSTAMPED_VERSION, _RELEASE_MARKER,
             _upgrading_dir, _upgrading_files, _upgrading_problems, _UpgradeProblem,
             _WHY_NO_RECORDED, _WHY_NO_HEADING, _WHY_SWALLOWED

# A miniature single-file log exercising every shape the parser must handle. It is deliberately
# NOT the shape the shipped log has any more — #192 gives each entry its own file, but the grammar
# below is unchanged, so these fixtures keep pinning the release-marker filter, the `---` split and
# the #89 diagnostics on text the shipped log can no longer produce:
# a header block with no `- **Recorded**:`, a release marker glued to its first entry,
# a second entry in the same release, an older release, and the template comment.
const SAMPLE = """
# Upgrading Nitro — consumer-app rollout log

Prose header. Not an entry: no Recorded bullet.

## Writing an entry

- One `##` entry per breaking change, newest first.

---

## Unreleased — next `0.3.0`

_Placeholder note for uncut work._

---

## `newest_api` — uncut change

- **Version**: Unreleased
- **Recorded**: 2026-07-31
- **Severity**: breaking

### What changed
Uncut body.

---

## 0.2.0 — 2026-07-30

## `second_api` — first entry of the 0.2.0 release

- **Version**: 0.2.0
- **Recorded**: 2026-07-29
- **Severity**: breaking

### What changed
Second body.

---

## `third_api` — second entry of the same release

- **Version**: 0.2.0
- **Recorded**: 2026-07-28
- **Severity**: behavior change

### What changed
Third body.

---

## 0.1.0 — 2026-07-01

## `oldest_api` — baseline entry

- **Version**: 0.1.0
- **Recorded**: 2026-07-01
- **Severity**: breaking

### What changed
Oldest body.

---

## Template for new entries

<!--
## `<api>` — <summary>

- **Version**: Unreleased
- **Recorded**: <YYYY-MM-DD>
-->
"""

@testset "parser" begin
    entries = _parse_upgrading(SAMPLE)

    # Four real entries — the prose header, the "Writing an entry" section, the two release
    # markers and the template comment are all rejected.
    @test length(entries) == 4
    @test [e.version for e in entries] ==
          [_UNRELEASED_VERSION, v"0.2.0", v"0.2.0", v"0.1.0"]

    # The release marker glued above `second_api` must not become its title.
    @test entries[2].title == "`second_api` — first entry of the 0.2.0 release"
    @test entries[1].title == "`newest_api` — uncut change"
    @test entries[4].title == "`oldest_api` — baseline entry"

    # Body starts at the entry's own heading, so the marker line is dropped.
    @test startswith(entries[2].body, "## `second_api`")
    @test !occursin("2026-07-30", entries[2].body)
    @test occursin("Second body.", entries[2].body)
end

@testset "CRLF checkout" begin
    # A Windows checkout stores `---\r\n`; the block splitter must still fire, or the whole
    # file collapses into one bogus entry and every scoped lookup comes back empty.
    crlf = replace(SAMPLE, "\n" => "\r\n")
    @test _parse_upgrading(crlf) == _parse_upgrading(SAMPLE)
end

@testset "release marker requires the em-dash" begin
    # An entry whose title merely starts with a version is an entry, not a marker.
    text = """
    ## 0.5.0 config format is now strict

    - **Version**: 0.5.0
    - **Recorded**: 2026-07-31

    ### What changed
    Body.
    """
    entries = _parse_upgrading(text)
    @test length(entries) == 1
    @test entries[1].title == "0.5.0 config format is now strict"
end

@testset "unstamped entry sorts below the baseline" begin
    text = """
    ## `mystery_api` — no Version bullet

    - **Recorded**: 2026-07-31

    ### What changed
    Body.
    """
    entries = _parse_upgrading(text)
    @test length(entries) == 1
    @test entries[1].version == _UNSTAMPED_VERSION
    @test entries[1].version < v"0.1.0"
end

@testset "version labels" begin
    @test _version_label(_UNRELEASED_VERSION) == "Unreleased"
    @test _version_label(v"0.1.0") == "0.1.0"
end

@testset "from is required" begin
    @test_throws ArgumentError upgrade_guide()
    err = try; upgrade_guide(); catch e; e; end
    @test occursin("requires `from`", err.msg)
end

@testset "scoping against the shipped log" begin
    # A consumer already pinned to the current release has nothing to do. Both bounds are derived
    # from `pkgversion` on purpose: a literal `from` couples this test to the release state and
    # starts failing the moment a train is cut and its entries are stamped with the new version.
    io = IOBuffer()
    current = pkgversion(Nitro)
    upgrade_guide(io; from = current, to = current)
    @test occursin("nothing to port between $(current) and", String(take!(io)))

    # The `to` upper bound excludes everything above it — no entry predates the 0.1.0 baseline.
    io = IOBuffer()
    upgrade_guide(io; from = v"0.0.1", to = v"0.0.2")
    @test occursin("nothing to port between 0.0.1 and", String(take!(io)))

    # `from` below the baseline surfaces the 0.1.0 wave.
    io = IOBuffer()
    upgrade_guide(io; from = v"0.0.1")
    out = String(take!(io))
    @test occursin("Porting a Nitro consumer from 0.0.1 → Unreleased", out)
    @test occursin("jwt_validator", out)
    @test occursin("Migrate your app", out)

    # Strings and VersionNumbers are interchangeable.
    @test upgrade_guide(from = "0.0.1", structured = true) ==
          upgrade_guide(from = v"0.0.1", structured = true)
end

@testset "structured output" begin
    entries = upgrade_guide(from = v"0.0.1", structured = true)
    @test !isempty(entries)
    @test all(e -> e.version >= v"0.1.0", entries)
    # Newest-first ordering is the contract callers rely on to apply entries in order.
    @test issorted(entries, by = e -> e.version, rev = true)
    @test all(e -> !isempty(e.title) && !isempty(e.body), entries)
end

@testset "shipped log parses" begin
    entries = _read_upgrading_entries()
    @test !isempty(entries)
    # Every entry carries a real stamp — no unstamped strays, and the uncut entries are
    # either absent or genuinely uncut work.
    @test all(e -> e.version >= v"0.1.0", entries)
    # The authoring template lives in UPGRADING.md, which is no longer parsed. If it ever
    # leaks into `upgrading/` it would parse as a bogus entry, so keep asserting it does not.
    @test !any(e -> occursin("<api>", e.title), entries)
end

@testset "the log directory holds one entry per file" begin
    # #192 replaced a single `## Unreleased` anchor with a file per entry, which is only a real
    # fix while the invariant holds. Two entries in one file re-create the swallow case that
    # #89 is about, and a stray column-0 `---` splits a body and silently truncates it — the
    # parser keeps the `^---$` split, so that hazard moved into the file rather than vanishing.
    files = _upgrading_files()
    @test !isempty(files)
    @test isdir(_upgrading_dir())

    # `_upgrading_files` keeps only `.md`, and that extension filter is the one selection step the
    # reader still has. It has to be asserted HERE, against a raw `readdir`, because every other
    # check in this file — including *"every shipped entry heading becomes an entry"*, the #89 net
    # — now derives its expected set by iterating `_upgrading_files()` too. A file the filter drops
    # therefore disappears from BOTH sides of that comparison and every assertion passes while the
    # entry is missing from the guide: `foo.markdown`, `foo.MD` on a case-sensitive filesystem, a
    # `foo.md.orig` merge leftover, or an entry filed into a subdirectory. Under the single-file
    # layout this was unrepresentable — there was no file-selection step to share. This is the
    # assertion that keeps the #89 net independent of the reader.
    for f in readdir(_upgrading_dir())
        @test (f, endswith(f, ".md")) == (f, true)
    end

    for path in files
        text = read(path, String)
        name = basename(path)
        # `== 1`, not `>= 1`: a second entry here is exactly the silent-loss shape.
        @test length(_parse_upgrading(text; source = name)) == 1
        @test _upgrading_problems(text) == _UpgradeProblem[]
        # Named in the message via the interpolation so a failure says WHICH file.
        @test (name, occursin(r"(?m)^---[ \t]*$", text)) == (name, false)
    end
end

@testset "entry filenames sort the log newest-first" begin
    # The date prefix is not decoration: `_upgrading_files` sorts by filename, and that is what
    # orders entries sharing a version. A file named anything else still parses — the reader has
    # no name gate, deliberately — but it would sort arbitrarily, so pin the convention here,
    # where the failure is loud.
    for path in _upgrading_files()
        name = basename(path)
        @test (name, occursin(r"^\d{4}-\d{2}-\d{2}-[a-z0-9.-]+\.md$", name)) == (name, true)
    end

    # Every file's prefix must be the date the entry itself records, or the sort is a lie.
    for path in _upgrading_files()
        name = basename(path)
        m = match(r"(?m)^-[ \t]+\*\*Recorded\*\*:[ \t]*(\d{4}-\d{2}-\d{2})", read(path, String))
        @test (name, m === nothing ? "" : m[1]) == (name, first(name, 10))
    end
end

@testset "every cut release is recorded in the Release trains table" begin
    # A release's DATE used to live in a `## <ver> — <date>` marker sitting in the same file as its
    # entries, so forgetting one was visible in the diff that stamped them. #192 moved it into a
    # table in `UPGRADING.md` — a file nothing parses and, without this, nothing tests. That would
    # leave `nitro-cut-release`'s "skipping it loses the date for good" as the only guard, which is
    # exactly the say-so-only shape this suite exists to replace.
    contract = read(joinpath(pkgdir(Nitro), "UPGRADING.md"), String)
    cut = sort(unique(e.version for e in _read_upgrading_entries() if e.version != _UNRELEASED_VERSION))
    @test !isempty(cut)

    for v in cut
        # Match the row, not just the number: a bare `occursin` would be satisfied by any prose
        # mentioning the version, and the thing being guarded is that a DATE was recorded with it.
        row = Regex("(?m)^\\|\\s*`" * replace(string(v), "." => "\\.") * "`\\s*\\|\\s*\\d{4}-\\d{2}-\\d{2}\\s*\\|")
        @test (string(v), occursin(row, contract)) == (string(v), true)
    end
end

@testset "every shipped entry heading becomes an entry" begin
    # #89: the parser loses an entry in two invisible ways. A second entry sharing a block merges
    # into its neighbour — the prose still renders, under the wrong title, and `structured = true`
    # never sees it. A header with no `- **Recorded**:` is dropped outright. Both leave a guide
    # that looks perfectly well-formed, so a "does it parse" check passes either way.
    #
    # The expected set below is derived WITHOUT splitting on `---`, and that independence is the
    # whole point: no separator can move a heading, so a swallowed entry surfaces here as a title
    # the parser failed to produce. Deriving it from `_scan_upgrading` instead would make this a
    # tautology that passes on a collapsed file — do NOT "dedupe" it into `src/upgrading.jl`.
    #
    # #192 made this *simpler*, not weaker: with a file per entry there is no preamble to skip and
    # no template section to truncate, so the derivation is now "every non-marker `## ` heading in
    # the log directory" with no positional reasoning at all.
    #
    # Known limitation, deliberate: this scan is text-level and would also pick up a `^## ` line
    # inside a fenced code block in an entry body. None exists, and an entry needing to show a
    # literal `## ` example must indent it. The failure is loud and the fix obvious — the right
    # trade for keeping this derivation independent of the parser.
    expected = String[]
    for path in _upgrading_files()
        text = replace(read(path, String), "\r\n" => "\n", "\r" => "\n")
        append!(expected, [String(strip(m[1])) for m in eachmatch(r"(?m)^##[ \t]+(.+)$", text)
                           if !occursin(_RELEASE_MARKER, strip(m[1]))])
    end
    parsed = [e.title for e in _read_upgrading_entries()]

    @test !isempty(expected)                      # the derivation itself still finds headings

    # `== String[]`, not `isempty(...)`: a failing `@test a == b` prints both operands, so the
    # report reads `Evaluated: ["`foo_api` — …"] == String[]` and NAMES the entry that went
    # missing, instead of an uninterpretable `34 != 33`.
    @test setdiff(expected, parsed) == String[]   # dropped, or swallowed into a neighbour's body
    @test setdiff(parsed, expected) == String[]   # a title the parser invented — e.g. a release
                                                  # marker written without its em-dash
    @test length(parsed) == length(expected)      # setdiff ignores multiplicity
end

@testset "no shipped entry swallows the next one" begin
    # The swallow half of #89, kept as the *diagnostic* companion to the set check above. That one
    # is the net — it catches this and the silent-drop direction too — but it can only say which
    # title went missing. This one names the entry that ATE it, which is where the second entry
    # needs splitting out into a file of its own. When both fail together the diagnosis is free.
    #
    # `_parse_upgrading` splits on `---` and takes ONE entry per block, so a second entry written
    # into an existing file is silently absorbed into the first entry's body: its prose still
    # renders, but under the wrong title, and `structured = true` loses it entirely. That is
    # invisible to a "does it parse" check — it shipped once (at 49f1a23 the `## Unreleased`
    # section ran #71, #18 and #16 with no `---` between them, so #18 and #16 were lost), so assert
    # the shape directly. A body may only carry its own heading.
    #
    # Kept after #192 even though "one entry per file" is asserted directly above, because these
    # catch different things: that one counts entries per file, this one catches a heading the
    # parser folded into a body without ever counting it as an entry.
    for e in _read_upgrading_entries()
        swallowed = [strip(m[1]) for m in eachmatch(r"(?m)^##[ \t]+(.+)$", e.body)
                     if strip(m[1]) != e.title && !occursin(_RELEASE_MARKER, strip(m[1]))]
        @test isempty(swallowed)
    end
end

@testset "a malformed entry warns instead of vanishing" begin
    # #89's other direction. #71's header carried `- **Version**: Unreleased` and nothing else; it
    # survived only by being glued into a block that held its neighbours' bullets. Separated, it
    # disappeared. It still does not parse — acceptance is unchanged on purpose — but it is no
    # longer silent about it.
    missing_recorded = """
    ## `header_only` — landed without its Recorded bullet

    - **Version**: Unreleased
    - **Severity**: breaking

    ### What changed
    Body.
    """
    entries = @test_logs (:warn, r"upgrade log") _parse_upgrading(missing_recorded)
    @test isempty(entries)                        # acceptance identical to before this landed

    probs = _upgrading_problems(missing_recorded)
    @test length(probs) == 1
    @test probs[1].title == "`header_only` — landed without its Recorded bullet"
    @test probs[1].reason == _WHY_NO_RECORDED

    # The data accessor is the quiet one — a test asserting "no problems" must not have to suppress
    # a warning in order to say it.
    @test_logs min_level = Base.CoreLogging.Warn _upgrading_problems(missing_recorded)

    # The other silent-drop shape: entry bullets written under a release marker with no entry
    # heading of their own. There is no title to report, so the record points at the block instead.
    no_heading = """
    ## 0.3.0 — 2026-09-09

    - **Version**: 0.3.0
    - **Recorded**: 2026-09-09
    """
    @test_logs (:warn, r"upgrade log") _parse_upgrading(no_heading)
    probs = _upgrading_problems(no_heading)
    @test length(probs) == 1
    @test probs[1].title == ""
    @test probs[1].reason == _WHY_NO_HEADING
    @test occursin("0.3.0 — 2026-09-09", probs[1].near)
end

@testset "a swallowed entry warns instead of vanishing" begin
    # The half of #89 that actually shipped, and the half a consuming app cannot otherwise detect:
    # two well-formed entries with no `---` between them parse as ONE. The block satisfies
    # acceptance — heading present, `Recorded` present — so nothing is rejected and the second entry
    # simply is not in the guide. Its prose renders under the first entry's title.
    #
    # At 49f1a23 that was #71, #18 and #16 in one block; #18 and #16 were lost. The same block is
    # also the missing-`Recorded` case above — #71's header carried only `- **Version**:
    # Unreleased` and survived only by being glued to its neighbours' bullets.
    #
    # Nitro's own suite catches this against the shipped file ("every shipped entry heading becomes
    # an entry"), but a consumer never runs that. Without the runtime record below, a short guide
    # and a complete one are indistinguishable to the app doing the upgrade.
    swallowed = """
    ## `first_api` — the entry that ate the next one

    - **Version**: Unreleased
    - **Recorded**: 2026-09-13

    ### What changed
    First body.

    ## `second_api` — prepended without its separator

    - **Version**: Unreleased
    - **Recorded**: 2026-09-13

    ### What changed
    Second body.
    """
    entries = @test_logs (:warn, r"upgrade log") _parse_upgrading(swallowed)

    # Acceptance is unchanged: this still parses as one entry, exactly as it did before #89.
    @test length(entries) == 1
    @test entries[1].title == "`first_api` — the entry that ate the next one"
    @test occursin("Second body.", entries[1].body)   # the prose is there, under the wrong title

    probs = _upgrading_problems(swallowed)
    @test length(probs) == 1
    @test probs[1].title  == "`second_api` — prepended without its separator"
    @test probs[1].reason == _WHY_SWALLOWED
    # `near` names the swallower, which is where the missing `---` has to go.
    @test probs[1].near == "`first_api` — the entry that ate the next one"

    # A release marker glued above the first entry is NOT a swallowed heading — that is the shape
    # every cut writes, and mistaking it for one would warn on every release.
    with_marker = "## 0.4.0 — 2026-09-13\n\n" * swallowed
    @test length(_upgrading_problems(with_marker)) == 1

    # Nor is a `## ` line inside a fenced example in an entry body. An entry documenting a change to
    # markdown would otherwise report itself, and a warning that fires on a correct log is worse
    # than none — a swallowed heading has to carry entry bullets of its OWN to count.
    fenced = """
    ## `docs_fmt` — an entry that shows markdown

    - **Version**: Unreleased
    - **Recorded**: 2026-09-13

    ### What changed
    Headings in the template moved:

    ```markdown
    ## `<api>` — <summary>
    ```
    """
    @test _upgrading_problems(fenced) == _UpgradeProblem[]
    @test_logs min_level = Base.CoreLogging.Warn _parse_upgrading(fenced)

    # ...but a genuine swallow in the same block is still reported, and only that one — the fenced
    # heading above it is skipped, the real entry after it is not.
    glued_on = """

    ## `real_api` — glued on after the fenced example

    - **Version**: Unreleased
    - **Recorded**: 2026-09-13

    ### What changed
    Body.
    """
    probs = _upgrading_problems(fenced * glued_on)
    @test [p.title for p in probs] == ["`real_api` — glued on after the fenced example"]
end

@testset "legitimate non-entry prose stays silent" begin
    # A warning that fires on the file's own header trains the maintainer to ignore the warning,
    # which is worse than not having one. SAMPLE carries both legitimate skips: the prose header
    # plus its `## Writing an entry` recipe, and a freshly-opened `## Unreleased` marker with
    # nothing under it yet — the exact shape `nitro-cut-release` leaves behind.
    @test _upgrading_problems(SAMPLE) == _UpgradeProblem[]
    @test_logs min_level = Base.CoreLogging.Warn _parse_upgrading(SAMPLE)

    # And the shipped log: a consumer running `upgrade_guide` must never see this.
    #
    # Asserted per file. Concatenating the log and scanning it once reports every entry after the
    # first as swallowed — which says nothing about the log and everything about the concatenation.
    for path in _upgrading_files()
        name = basename(path)
        @test (name, _upgrading_problems(read(path, String))) == (name, _UpgradeProblem[])
    end

    # The consumer's actual command, end to end.
    io = IOBuffer()
    @test_logs min_level = Base.CoreLogging.Warn upgrade_guide(io; from = v"0.0.1")
end

end
