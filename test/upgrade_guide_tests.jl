@testitem "upgrade_guide" tags=[:core] setup=[NitroCommon] begin
using Test
using Nitro
using Nitro: _parse_upgrading, _read_upgrading_entries, _version_label,
             _UNRELEASED_VERSION, _UNSTAMPED_VERSION, _RELEASE_MARKER

# A miniature UPGRADING.md exercising the shapes the real file (and a cut) produce:
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

@testset "scoping against the real UPGRADING.md" begin
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

@testset "shipped UPGRADING.md parses" begin
    entries = _read_upgrading_entries()
    @test !isempty(entries)
    # Every entry carries a real stamp — no unstamped strays, and the `## Unreleased`
    # section is either empty or holds genuinely uncut work.
    @test all(e -> e.version >= v"0.1.0", entries)
    # The template block must never parse as an entry.
    @test !any(e -> occursin("<api>", e.title), entries)
end

@testset "no shipped entry swallows the next one" begin
    # `_parse_upgrading` splits on `---` and takes ONE entry per block, so an entry prepended
    # without its trailing separator is silently absorbed into the previous entry's body: its
    # prose still renders, but under the wrong title, and `structured = true` loses it entirely.
    # That is invisible to a "does it parse" check — it shipped once (#20 under #73), so assert
    # the shape directly. A body may only carry its own heading.
    for e in _read_upgrading_entries()
        swallowed = [strip(m[1]) for m in eachmatch(r"(?m)^##[ \t]+(.+)$", e.body)
                     if strip(m[1]) != e.title && !occursin(_RELEASE_MARKER, strip(m[1]))]
        @test isempty(swallowed)
    end
end

end
