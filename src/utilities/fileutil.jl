using HTTP

export readfile, mountfolder, mountable_files

"""
    readfile(filepath::String)

Reads a file as a String
"""
function readfile(filepath::String)
    return read(filepath, String)
end

"""
    _is_within(root_parts::Vector{String}, path::String) -> Bool

Whether `path` sits strictly underneath the directory whose `splitpath` is `root_parts`.

**Both sides must already be resolved with `realpath` by the caller.** Comparing a resolved path
against a raw one is wrong on macOS, where `mktempdir()` returns `/var/folders/…` but `/var` is a
symlink to `/private/var`, so every resolved file would look like an escape.

The comparison is component-wise rather than a string prefix, so `/srv/app` does not appear to
contain `/srv/app-secrets`.

`relpath` is deliberately *not* used for this: on Windows `relpath("D:/x", "C:/y")` returns
`"D:\\\\x"` with no `..` component at all, so a `..`-based containment test fails **open** across
drives. Comparison is byte-exact and must stay that way — `realpath` returns the case the
filesystem stores, so both sides already agree on Windows, and case-folding would be wrong on Linux.

The one component that cannot be compared verbatim is the root itself, because `splitpath` spells it
two ways. A UNC share root standing alone keeps no trailing separator, but the same root followed by
further components does:

```
splitpath(raw"\\\\host\\share")        == ["\\\\\\\\host\\\\share"]
splitpath(raw"\\\\host\\share\\sub")   == ["\\\\\\\\host\\\\share\\\\", "sub"]
```

Comparing those verbatim makes **every** file under a UNC-mounted folder look like an escape, which
fails closed as a blanket 404. Drive roots (`"C:\\\\"`) and `/` are consistent, but are normalized the
same way so there is only one rule.
"""
function _is_within(root_parts::Vector{String}, path::String)::Bool
    parts = splitpath(path)
    # Strictly greater: a file is never the root itself.
    length(parts) > length(root_parts) || return false
    isempty(root_parts) && return false
    _same_root(parts[1], root_parts[1]) || return false
    for i in 2:length(root_parts)
        parts[i] == root_parts[i] || return false
    end
    return true
end

"""
    _same_root(a, b) -> Bool

Compare two filesystem-root components ignoring a trailing separator, which `splitpath` includes or
omits depending on whether the root stands alone. See [`_is_within`](@ref).
"""
_same_root(a::AbstractString, b::AbstractString) =
    rstrip(a, ('/', '\\')) == rstrip(b, ('/', '\\'))

"""
    _resolves_hidden(root_parts::Vector{String}, resolved::String) -> Bool

Whether `resolved` lands on a hidden entry once expressed relative to the mount root — i.e. whether
any component *below* the root starts with `.`.

This exists because the hidden rule is otherwise applied to the name of the directory entry being
walked, which says nothing about where a symlink points. A link named `innocent.txt` pointing at
`.env` in the same folder is not dot-prefixed, resolves inside the root, and is a regular file, so
containment alone would serve it — re-opening the hole the hidden rule closes.

Both arguments must be `realpath`-resolved, and `resolved` must already be known to be inside the
root (`_is_within`); for a target outside it, "relative to the mount" has no meaning.
"""
function _resolves_hidden(root_parts::Vector{String}, resolved::String)::Bool
    parts = splitpath(resolved)
    length(parts) > length(root_parts) || return false
    for i in (length(root_parts) + 1):length(parts)
        startswith(parts[i], '.') && return true
    end
    return false
end

"""
    _is_route_pattern(component::AbstractString) -> Bool

Whether a single path component would be treated as something other than a literal segment by the
routing layer. Two distinct failures, both refused:

- `*` and `**` are HTTP.jl wildcards. A file named `*` shadows its siblings — a request for any
  unmatched path under the mount is answered with that file's body.
- A component containing `{` or `}` is read as a path parameter by `parse_func_params`
  (`src/core/registration.jl`), whose brace test is `contains(value, r"({)|(})")` — deliberately broader than
  HTTP.jl's own `isvariable`, so `{id}.txt` counts even though it is not a well-formed variable.
  Registration then throws `ArgumentError` because a mount's handler takes no such parameter, which
  means a single brace-named file made `serve()` fail to boot.

Applied to two things, by two callers with different consequences. [`mountable_files`](@ref) *skips*
a filename that matches, because filenames arrive in bulk from the filesystem. [`mount_segments`](@ref)
*throws* on a `mountdir` segment that matches, because that is one app-authored value with an obvious
correction — and until #101 it was not checked at all, so a mount could claim URLs a file may not.

This rule survived #121's route encoding, and has to. `*` and `**` are legal `pchar`, so
[`_route_encode`](@ref) leaves them untouched: nothing but this refusal stops a file named `*` from
shadowing every sibling URL under the mount. Braces *would* be encoded, but are caught here first,
so `{id}.txt` stays skipped rather than becoming servable at `%7Bid%7D.txt`.
"""
_is_route_pattern(component::AbstractString) =
    component == "*" || component == "**" || occursin('{', component) || occursin('}', component)

const _PCHAR_PUNCT = ('-', '.', '_', '~',                                          # unreserved
                      '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=',      # sub-delims
                      ':', '@')

"""
    _is_pchar(c::Char) -> Bool

Whether `c` may stand unencoded in a URL path segment: RFC 3986's `pchar` minus `pct-encoded`, i.e.
`unreserved / sub-delims / ":" / "@"`.

The `isascii` guard is load-bearing, not defensive. Julia's `isletter` and friends are
Unicode-aware, so `isletter('Ａ')` — the fullwidth `A` — is `true`, and without the guard a
non-ASCII segment would be accepted as a literal route. A *conforming* client percent-encodes it and
the router compares raw path segments, so the two never meet; a client that sends raw bytes does
reach such a route, which is why refusing it is a deliberate trade rather than a free win — see
[`mount_segments`](@ref). `isdigit` and `isxdigit` are already ASCII-only in Julia, so only the
letter test needs the guard; applying it to the whole predicate keeps that from being a detail a
reader has to know.
"""
_is_pchar(c::Char) = isascii(c) && (isletter(c) || isdigit(c) || c in _PCHAR_PUNCT)

"""
    _first_unroutable(segment::AbstractString) -> Char or nothing

The first character of `segment` that could not appear in a URL path unencoded, or `nothing` when
every one of them could.

`%` is accepted only as the head of a well-formed `%XX` triplet, so a prefix the app already encoded
itself (`"my%20static"`) passes — it really is reachable — while a literal percent (`"100%"`), a
non-hex escape (`"%zz"`) and a truncated one (`"a%"`) do not.

The return type is deliberately unannotated rather than `Nullable{Char}`: `src/core.jl` includes
`util.jl` *before* `types.jl`, so the `Nullable` alias does not exist yet at this point in the chain.
"""
function _first_unroutable(segment::AbstractString)
    chars = collect(segment)
    n = length(chars)
    i = 1
    while i <= n
        c = chars[i]
        if c == '%'
            # A valid escape consumes three characters; anything else is a literal `%`, which is
            # itself unroutable — report the `%` rather than the byte that followed it.
            (i + 2 <= n && isxdigit(chars[i + 1]) && isxdigit(chars[i + 2])) || return '%'
            i += 3
        elseif !_is_pchar(c)
            return c
        else
            i += 1
        end
    end
    return nothing
end

"""
    _route_encode(name::AbstractString) -> String

Percent-encode a *filename* into a URL path segment: every byte that could not stand unencoded
becomes an uppercase `%XX` triplet. `name` is returned unchanged when every byte is already
[`_is_pchar`](@ref), which is the overwhelmingly common case.

Triplets are **uppercase**, and because the router matches bytes rather than testing RFC 3986
equivalence, a client that sends the lowercase spelling (`caf%c3%a9.txt`) gets a 404. Browsers emit
uppercase, so this is a compatibility footnote rather than a defect — and it is the same fact that
forbids case-normalizing a `mountdir`'s triplets in [`mount_segments`](@ref), so the two rules agree.

This is the filename half of the rule [`mount_segments`](@ref) enforces on `mountdir`. The router
compares path segments byte for byte and never percent-decodes, so a file whose name needs encoding
used to register a route that no conforming client could ever match — enumerated, registered,
counted and logged as served, and a 404 in every browser
([#121](https://github.com/PingoLee/Nitro.jl/issues/121)). Encoding the route is the only one of the
available responses that *fixes* that rather than reporting it, and it is only expressible because
`mountfolder` returns `route => filepath` pairs, so the route no longer has to equal the filesystem
name ([#102](https://github.com/PingoLee/Nitro.jl/issues/102)).

Three properties are load-bearing; changing any of them changes which URLs a mount answers.

**The safe set is [`_is_pchar`](@ref) exactly — not `HTTP.escapeuri`'s.** `URIs.issafe` keeps only
`A-Za-z0-9`, `-`, `.` and `_`, so it also encodes `~` and every sub-delim (`!`, `\$`, `&`, `'`, `(`,
`)`, `*`, `+`, `,`, `;`, `=`) plus `:` and `@`. Those are all legal `pchar`, browsers send them raw,
and measurement over a socket confirms `report(1).txt`, `a+b.txt`, `v1.2~beta.txt`, `a:b.txt` and
`a@b.txt` serve today at their literal routes and 404 at the over-encoded ones. Using `escapeuri`
here would therefore *break* five working shapes to fix three broken ones. With `_is_pchar`, a
pchar-clean filename keeps its route byte for byte, so no route a *conforming* client could already
reach moves — the sole exception being the literal-`%` case below.

**A literal `%` is always encoded, and that is the one place this deliberately disagrees with
[`mount_segments`](@ref).** A `mountdir` is *authored*, so `"my%20static"` is someone spelling a
space on purpose and the triplet is validated and passed through. A filename is *data*: a file named
`my%20file.txt` contains the three characters `%`, `2`, `0`, and the URL that names it is
`my%2520file.txt`. Passing the triplet through would make one URL mean two different files — the
literal `my%20file.txt` and the encoded form of `my file.txt` — so `%` is not in `_PCHAR_PUNCT` and
is encoded like any other non-`pchar` byte. This is the one case where a route that a *browser* could
reach does move; it is recorded in the #121 upgrade-log entry.

**It does not replace the [`_is_route_pattern`](@ref) refusal, which still runs first.** `*` and `**`
are perfectly legal `pchar`, so this function leaves them alone and a file named `*` would still
shadow every sibling URL under the mount. `{` and `}` *would* be encoded here, but the refusal
catches them earlier and keeps `{id}.txt` skipped — encoding them instead would change *what* a
mount serves rather than only where, which is a separate decision.

Encoding is **injective** on byte strings (`%` itself is encoded, so the image decodes
unambiguously), so two distinct filenames can never collapse onto one route. Checked exhaustively:
all 256 single bytes agree between the fast-path guard and the loop, and all 65536 two-byte names
produce 65536 distinct routes.

Sweeping every **one-byte name** leaves exactly two whose output is not an inert literal *segment*,
and neither needs a rule here — worth writing down, since the dot-segment half is the class #101's
review found late for `mountdir`:

- A name that **is** `"*"` (or `"**"`) is refused by [`_is_route_pattern`](@ref) before enumeration
  reaches encoding. Note that rule tests the *whole* segment, so an **embedded** `*` — `a*b.txt`,
  the common case — does reach this function and is deliberately passed through: HTTP.jl gives `*`
  meaning only as a complete segment, so `/x/a*b.txt` matches `/x/a*b.txt` and nothing else.
- `"."` and `".."` can never *be* a name segment at all: `readdir` does not report them, and
  `relpath` runs both arguments through `normpath`, so a path `walkdir` produced under `root` cannot
  relativize to a `..` component.

A change to either upstream guard would need a rule here.

Iteration is over **bytes**, not `Char`s, for two reasons: it is the level the router compares at, so
one non-ASCII character correctly yields one triplet per UTF-8 byte; and `readdir` can hand back a
name that is not valid UTF-8, where `codepoint` on a malformed `Char` would throw.
"""
function _route_encode(name::AbstractString)
    bytes = codeunits(name)
    all(b -> b < 0x80 && _is_pchar(Char(b)), bytes) && return String(name)

    io = IOBuffer()
    for b in bytes
        if b < 0x80 && _is_pchar(Char(b))
            write(io, b)
        else
            print(io, '%', uppercase(string(b; base = 16, pad = 2)))
        end
    end
    return String(take!(io))
end

"""
    _mount_root_parts(root::String) -> Vector{String}

The `splitpath` of `root` resolved through `realpath`, for use as the left-hand side of
[`_is_within`](@ref) and [`_resolves_hidden`](@ref).

Throws `ArgumentError` when `root` is missing or not a directory. That has to be an error rather
than an empty result: `mountable_files` logs-and-continues past unreadable *subdirectories*, so
without this a typo'd folder name would quietly mount nothing at all.
"""
function _mount_root_parts(root::String)::Vector{String}
    isdir(root) || throw(ArgumentError("mount folder does not exist or is not a directory: $root"))
    return splitpath(realpath(root))
end

# NOTE: enumeration here is deliberately mount-time only. An earlier revision also re-checked on
# every request, to catch a file swapped for a symlink after startup. That was removed on purpose:
# it could not close the race (the caller re-opens the unresolved path after the check, and a hard
# link is undetectable either way), while costing a `realpath` + stat + `splitpath` allocation on
# every `dynamicfiles` request. A partial in-app mitigation is the wrong tool for "an attacker can
# write to the directory you are serving" — put a reverse proxy in front, or do not serve that
# directory. See docs/design/static-serving-boundary.md.

"""
    mountable_files(root::String; include_hidden=false, allow_symlink_escape=false) -> Vector{String}

Return the filesystem paths under `root` that are safe to expose over HTTP, in walk order.

This is the single enumerator behind [`mountfolder`](@ref) and therefore behind `staticfiles`,
`spafiles` and `dynamicfiles`. It refuses four classes of entry by default:

- **Hidden entries** — any file whose path *relative to `root`* has a component starting with `.`.
  That covers `.env` as well as everything under `.git/`. The test is relative on purpose: an
  absolute-path test would refuse every file whenever the project itself lives under a dot-directory.
  Names with interior dots (`file.min.js`) are unaffected. Set `include_hidden=true` to serve them.

  The rule applies to a symlink's **resolved target** as well as to its own name
  ([`_resolves_hidden`](@ref)) — otherwise `innocent.txt -> .env` walks straight through a name-only
  test. It does **not** catch a *hard* link to a dotfile: `islink` is false, so nothing resolves, and
  `realpath` legitimately reports the in-mount path. That gap is inherent at this layer.
- **Symlinks escaping the mount** — resolved with `realpath` and required to stay under the resolved
  `root`, so a link to a file *inside* the mount still works while `data.csv -> /etc/passwd` does
  not. Set `allow_symlink_escape=true` to serve them anyway. Note this also disables the
  resolved-target hidden check for escaping links, since "hidden relative to the mount" stops meaning
  anything once the target is outside it.
- **Filenames that are router patterns** — see [`_is_route_pattern`](@ref). Always refused; a file
  cannot opt into claiming other URLs.
- **Anything that is not a regular file** — symlinked *directories* (`walkdir` reports every link as
  a file, so without this a route would be registered whose target is a directory and the eager read
  in `staticfiles` would throw at startup), plus FIFOs, sockets and devices, where the per-request
  read in `dynamicfiles` would block or grow without bound.

  A symlinked **directory** is warned about **by name**, unlike the rest of that class
  ([#95](https://github.com/PingoLee/Nitro.jl/issues/95)). It is the one entry whose refusal hides a
  whole *subtree* rather than one file, and `dist/assets -> ../shared/assets` is an ordinary deploy
  layout — so folded into a count, the only signal that a hundred files were dropped was the number
  going up. Traversing it stays a non-goal (`docs/design/static-serving-boundary.md` §7):
  `walkdir(follow_symlinks=true)` has no cycle detection, and every intermediate component would
  become checkable surface, voiding the "walkdir never descends a link, so testing the leaf is
  complete" invariant this function rests on. **Mount the target separately instead** —
  `staticfiles("shared/assets", "assets")` works today and needs no new code — or serve it from the
  proxy.

A name that is not a legal URL path segment is **not** in that list: `café.txt` and `my file.txt` are
enumerated and served, at their percent-encoded routes. That is [`mountfolder`](@ref)'s job via
[`_route_encode`](@ref), not a refusal here
([#121](https://github.com/PingoLee/Nitro.jl/issues/121)) — the alternative was dropping a file a
mount serves today, and refusals at this layer skip rather than throw, so it would have been silent.

Every refusal fails closed: a `realpath` that throws — a dangling link, `ELOOP`, a permission error
— skips the entry rather than propagating. An unreadable *subdirectory* is logged and skipped too,
which is why a missing `root` throws `ArgumentError` up front instead: a mount folder that does not
exist is a programming error, and it must not be silently indistinguishable from an empty one.

**Returned paths are `joinpath(dir, name)` for each kept `walkdir` entry, verbatim** — never
`realpath`-resolved, `abspath`-ed or `normpath`-ed, whatever spelling of `root` the caller passed.
`realpath` *is* computed for the symlink checks above and then deliberately discarded. That makes
`joinpath(root, rel)` a valid key into this result, which is how `spafiles` identifies its index by
file rather than by route name ([#102](https://github.com/PingoLee/Nitro.jl/issues/102)).
Normalizing here would silently drop every SPA fallback — the lookup would miss, `spafiles` would
warn and register nothing, and no test in the mount suite would fail.
"""
function mountable_files(root::String;
                         include_hidden::Bool=false,
                         allow_symlink_escape::Bool=false)::Vector{String}

    root_parts = _mount_root_parts(root)
    kept       = String[]
    examples   = String[]
    n_hidden = n_escaped = n_pattern = n_unresolvable = n_irregular = n_linkdir = 0

    # Default is `onerror=throw`, which makes one unreadable subdirectory anywhere under the mount
    # abort `serve()`. Logging and continuing fails closed — fewer files get served, never more.
    onerror = e -> @debug "mountable_files: skipping unreadable directory" exception=e

    for (dir, _, names) in walkdir(root; follow_symlinks=false, onerror=onerror)
        reldir     = relpath(dir, root)
        hidden_dir = reldir != "." && any(startswith("."), splitpath(reldir))

        for name in names
            rel  = reldir == "." ? name : joinpath(reldir, name)
            path = joinpath(dir, name)
            # Only ever record the mount-relative path. A resolved target may name something
            # sensitive (a link to `~/.ssh/id_rsa`), and logs must not carry it.
            note!() = (length(examples) < 5 && push!(examples, rel); nothing)

            if !include_hidden && (hidden_dir || startswith(name, '.'))
                n_hidden += 1; note!(); continue
            end

            if any(_is_route_pattern, splitpath(rel))
                n_pattern += 1
                # Warn on the first few only. These names can come from a user-writable upload
                # directory, so one log line per file is an attacker-controlled log flood.
                n_pattern <= 5 && @warn "mountable_files: refusing a filename that the router would read as a pattern rather than a literal path" path=rel
                note!(); continue
            end

            # `walkdir(follow_symlinks=false)` never descends a link, so no walked path can have a
            # symlinked *intermediate* component — testing the leaf is a complete test, and an
            # ordinary tree pays no `realpath` calls at all.
            if islink(path)
                resolved = try
                    realpath(path)
                catch e
                    e isa Base.IOError || rethrow()
                    n_unresolvable += 1; note!(); continue
                end
                inside = _is_within(root_parts, resolved)
                if !allow_symlink_escape && !inside
                    n_escaped += 1; note!(); continue
                end
                # A link's *name* passing the hidden test says nothing about its target.
                # `innocent.txt -> .env` is not dot-prefixed, resolves inside the root, and is a
                # regular file — so containment alone would re-expose exactly what the hidden rule
                # exists to refuse. Only meaningful for a target inside the root; an escaping one is
                # already either refused above or explicitly opted into.
                if !include_hidden && inside && _resolves_hidden(root_parts, resolved)
                    n_hidden += 1; note!(); continue
                end
            end

            if !isfile(path)
                n_irregular += 1; note!()
                # A symlinked DIRECTORY is the one irregular entry that is almost always a
                # mistake rather than a deliberate exclusion, and the only one whose refusal
                # silently hides a whole subtree instead of a single file
                # ([#95](https://github.com/PingoLee/Nitro.jl/issues/95)). `dist/assets ->
                # ../shared/assets` is an ordinary deploy layout and `current -> releases/N` is
                # the standard atomic-release shape, so someone will hit this; folded into the
                # `not_a_regular_file` count below, the only signal was a number.
                #
                # Traversing it is a deliberate NON-GOAL (docs/design/static-serving-boundary.md
                # §7): `walkdir(follow_symlinks=true)` has no cycle detection, so `a -> .`
                # descends until the OS refuses, and every intermediate component would become
                # checkable surface — the "walkdir never descends a link, so testing the leaf is
                # complete" invariant this function rests on would be void. Naming the directory
                # is the cheap half, and #95 says it is worth doing whether or not traversal ever
                # lands.
                #
                # Capped at five like the route-pattern and percent-encoding warnings, for the
                # same reason: a user-writable upload directory would otherwise be an
                # attacker-controlled log flood. Only the mount-relative path is logged, never
                # the resolved target, which may name something sensitive.
                if islink(path) && isdir(path)
                    n_linkdir += 1
                    n_linkdir <= 5 && @warn "mountable_files: skipping a symlinked directory — its whole subtree is unreachable. Mount it separately (`staticfiles(\"<target>\", \"<prefix>\")`) or serve it from the proxy; traversal is a non-goal, see docs/design/static-serving-boundary.md §7" path=rel
                end
                continue
            end

            push!(kept, path)
        end
    end

    n_skipped = n_hidden + n_escaped + n_pattern + n_unresolvable + n_irregular
    if n_skipped > 0
        @info "mountable_files: $n_skipped entry/entries under $root will not be served" hidden=n_hidden symlink_escape=n_escaped route_pattern=n_pattern unresolvable_link=n_unresolvable not_a_regular_file=n_irregular symlinked_directory=n_linkdir examples=examples
    end
    n_linkdir > 5 && @warn "mountable_files: $n_linkdir symlinked directories under $root were skipped; their subtrees are not served" shown=5
    isempty(kept) && @warn "mountable_files: no servable files found under $root"

    return kept
end

"""
    mount_segments(mountdir) -> Vector{String}

The canonical URL path segments a mount contributes, or an empty vector when it mounts at the root.

This is the one place `mountdir` is normalized: `staticfiles`, `spafiles` and `dynamicfiles` strip
nothing themselves, so `mountfolder` and `spafiles`' history-mode fallback derive their routes from
the raw value through this function and cannot spell it differently. Keeping that single-source
property is why an earlier all-whitespace `mountdir` bug — the mount registering `/index.html` while
`spafiles` looked for `"/  /index.html"`, dropping the fallback behind a warning claiming no
servable `index.html` existed — cannot recur.

Canonicalizing to *segments* rather than normalizing a string is what makes a whole class of route
defect unrepresentable. Every spelling of the same mount reduces to the same value — `""`, `"/"` and
whitespace to `String[]`; `"static"`, `"/static"`, `"static/"`, `"/static/"` and `" /static/ "` to
`["static"]` — and routes are rebuilt with [`mount_route`](@ref) by joining, never by interpolating
a prefix that might already carry a separator.

It normalizes **and** validates. A `mountdir` is judged by the same rule as a *filename* — see
[`mountable_files`](@ref) — because a mount must not be able to claim URLs a file may not. Every
surviving segment is refused, with an `ArgumentError` naming it, when it is either:

- **a router pattern** ([`_is_route_pattern`](@ref)) — `staticfiles(dir, "*")` used to register
  `/*/<file>` *and* a bare `/*`, so `GET /anything` was answered by the mount. `**` and `{id}` failed
  loudly at registration; `*` was the one that did not, which is what made it worth refusing here
  (#101); or
- **not a legal URL path segment** ([`_first_unroutable`](@ref)) — anything outside RFC 3986 `pchar`.
  The router compares raw path segments and never percent-decodes, and a conforming client
  percent-encodes these characters before sending, so the registered route and the request can never
  meet. Write the prefix pre-encoded (`"my%20static"`, `"caf%C3%A9"`) and it mounts and serves.

  Be precise about what this costs, because the two halves differ. `" "`, `"?"` and control
  characters are **strictly** unmatchable — the request line cannot carry them, so such a mount was
  always dead. The rest — `"café"`, `"a#b"`, `"a|b"`, `"a[b]"`, `"100%"` — *were* reachable by a client that
  sends raw bytes rather than encoding them (curl does), so refusing them **does** take a working
  mount away from those callers, and the encoded spelling is a different byte string that does not
  answer them. That is a deliberate trade: one rule, judged like a filename, and a prefix no browser
  can reach is a footgun whatever curl can do with it.

A relative dot-segment (`.`, `..`) is refused for the same reason, separately: `.` is `unreserved`, so
it passes the encoding test, and clients still strip it before sending.

Refusing is deliberate rather than warning: `mountdir` is a single app-authored value with an obvious
correction, so failing at boot is cheaper than a dead mount nobody notices. **Filenames are handled
the other way round — they are encoded, not refused** ([`_route_encode`](@ref),
[#121](https://github.com/PingoLee/Nitro.jl/issues/121)), because they arrive in bulk from the
filesystem and a refusal at that layer skips silently. The split is not inconsistency: a `mountdir`
is *authored*, so `"my%20static"` is someone spelling a space deliberately and the triplet is passed
through, while a filename is *data*, so a file named `my%20file.txt` really does contain `%`, `2`,
`0` and its route must be `my%2520file.txt`. One rule cannot do both without losing information.

**Validated, never re-encoded.** A percent triplet is checked for well-formedness and then passed
through byte for byte — `"%2f"` stays `"%2f"`. Do not add case-normalization or decoding of
unreserved triplets here, however much "the one place `mountdir` is normalized" invites it: HTTP.jl
matches path segments with a byte comparison, not an RFC 3986 equivalence test, so rewriting `"%2f"`
to `"%2F"` would stop matching the client that sends the lowercase form.

Note this runs **before** enumeration: [`mountfolder`](@ref) calls this function first, so
`staticfiles("does_not_exist", "*")` reports the bad `mountdir`, not the missing folder. Both are
`ArgumentError`.
"""
function mount_segments(mountdir::AbstractString)::Vector{String}
    segments = String[]
    for raw in split(mountdir, '/')
        segment = String(strip(raw))
        isempty(segment) && continue

        # Order matters: `*` is a perfectly legal `pchar`, so the pattern test has to run first or a
        # wildcard mount would be reported as an encoding problem, which is not what is wrong with it.
        _is_route_pattern(segment) && throw(ArgumentError(
            "mountdir segment $(repr(segment)) would register as a route pattern rather than a " *
            "literal path: a mount may not claim URLs other than its own. Use a literal prefix."))

        # `.` and `..` are `pchar`-clean — `.` is unreserved — so the encoding test below waves them
        # through, and they are still unreachable: RFC 3986 §5.2.4 dot-segment removal is done by the
        # client, so nothing that would match `/../x` ever reaches the router.
        (segment == "." || segment == "..") && throw(ArgumentError(
            "mountdir segment $(repr(segment)) is a relative dot-segment. Clients remove `.` and " *
            "`..` from a path before sending it, so this mount would register routes no request " *
            "could reach. Spell the prefix without it."))

        bad = _first_unroutable(segment)
        bad === nothing || throw(ArgumentError(
            "mountdir segment $(repr(segment)) contains $(repr(bad)), which must be " *
            "percent-encoded to appear in a URL path. The router matches raw path segments, so " *
            "this mount would register routes no request could reach. Write the prefix " *
            "pre-encoded (e.g. \"my%20static\") or choose a different one."))

        push!(segments, segment)
    end
    return segments
end

"""
    mount_route(segments) -> String

Join canonical mount segments into a route. The empty vector is the router root, spelled `"/"`
rather than left as `""` — HTTP.jl happens to treat the two alike, but relying on that made the
bare-directory route of a root mount correct only by accident.
"""
mount_route(segments::AbstractVector{<:AbstractString})::String =
    isempty(segments) ? "/" : "/" * join(segments, "/")

# The request path, without the query or fragment, and still percent-encoded.
#
# Origin-form (`/static/app.js`) is the overwhelmingly common case and is handled by a scan
# rather than by building an `HTTP.URI`, because this runs on every request to a mount.
# Absolute-form targets (`http://host/static/app.js`) are legal in a request line and fall back
# to the URI parser, which also does not unescape.
function _target_path(target::AbstractString)::SubString{String}
    s = String(target)
    if !isempty(s) && first(s) == '/'
        cut = findfirst(c -> c === '?' || c === '#', s)
        return cut === nothing ? SubString(s, 1) : SubString(s, 1, prevind(s, cut))
    end
    return SubString(String(HTTP.URI(s).path), 1)
end

# Whether a DECODED segment can name a single mounted path component.
#
# This runs after `unescapeuri`, which is the only reason it can see a separator at all: `%2F`
# and `%5C` survive the split on '/' as one segment and decode into one afterwards. Without this,
# `/static/a%2Fb` would be keyed `"a/b"` and match the nested file `a/b` — letting one URL name a
# file whose own route is a different URL. `.`/`..` are refused for the same reason (`%2e%2e%2f`
# decodes to `"../"`), and NUL because it truncates paths in the C layer beneath `stat`.
#
# Note this is defence in depth, not the containment boundary. Containment comes from resolving
# against the ENUMERATED set: a key that is not in the mount table is a 404 whatever it spells,
# and the filesystem is never consulted. That is what `mountable_files` already decided.
_is_nameable_segment(s::AbstractString)::Bool =
    !isempty(s) && s != "." && s != ".." &&
    !occursin('/', s) && !occursin('\\', s) && !occursin('\0', s)

"""
    mount_remainder(target, n_prefix) -> Union{String,Nothing}

The mount-relative key a request names, decoded exactly once, or `nothing` when the request
cannot name a mounted file at all.

`n_prefix` is the number of leading path segments the mount's own prefix occupies
([`mount_segments`](@ref)); they are dropped without being decoded, because
[`mount_segments`](@ref) validated them and they may legitimately carry their own `%XX`.
A target that stops at the prefix yields `""`, which is the key of the mount's bare route.

The returned key is in the same alphabet as [`mountfolder`](@ref)'s table: the raw, `/`-separated,
mount-relative filesystem path. So a file is reachable by **every** spelling a client can send —
`café.txt` answers both `/static/caf%C3%A9.txt` and raw `/static/café.txt`, which per-file route
registration could not do ([#121](https://github.com/PingoLee/Nitro.jl/issues/121),
[#101](https://github.com/PingoLee/Nitro.jl/issues/101)) because the router compares bytes.

**Decoding here is not a new rule.** It is the boundary discipline
[#70](https://github.com/PingoLee/Nitro.jl/issues/70) established — *percent-decoding happens
exactly once, where the raw request becomes a value* — applied to the one path that never got it.
`Types.pathparams` does the same for `{var}` routes, and for the same reasons this raises
`ValidationError` (a **400**) on a malformed escape or on bytes that are not valid UTF-8, rather
than letting either reach a handler. Express's `send` also answers 400 here.

`nothing` means *"no mounted file can have this name"* and is a **404**, not a 400: it is a miss,
and reporting it as a client error would tell an unauthenticated caller which spellings are
structurally interesting.
"""
function mount_remainder(target::AbstractString, n_prefix::Int)::Union{String,Nothing}
    segments = split(_target_path(target), '/'; keepempty=false)
    length(segments) <= n_prefix && return ""

    parts = Vector{String}(undef, length(segments) - n_prefix)
    for i in (n_prefix + 1):length(segments)
        decoded = try
            HTTP.unescapeuri(String(segments[i]))
        catch e
            e isa InterruptException && rethrow()
            # The offending segment is deliberately NOT interpolated: `.msg` is app-reachable
            # and a path segment can carry a token. Same rule as `Types.pathparams`.
            throw(ValidationError("Malformed percent-encoding in static mount path", e))
        end
        # `unescapeuri` does not validate what the bytes decode TO — "%80" yields an invalid
        # `String` with no error — and a `Dict` lookup on an invalid `String` would simply miss,
        # turning a malformed request into a silent 404. Refuse it at the boundary instead.
        isvalid(decoded) || throw(ValidationError("Invalid UTF-8 in static mount path"))
        _is_nameable_segment(decoded) || return nothing
        parts[i - n_prefix] = decoded
    end
    return join(parts, "/")
end

"""
    mountfolder(folder::String, mountdir::String, addroute;
                include_hidden=false, allow_symlink_escape=false) -> Vector{Pair{String,String}}

Discover the servable files under `folder` and hand each one to `addroute`, leaving it to decide
*how* the file is served. Enumeration — and therefore which files are exposed — is owned by
[`mountable_files`](@ref); see it for what is refused and how to opt out.

`addroute` is called as `addroute(route, filepath, key)`:

| Argument | Spelling | Used for |
|---|---|---|
| `route` | percent-**encoded** (#121) | the URL the mount *emits*, and the first half of the returned pair |
| `filepath` | raw filesystem path | opening the file |
| `key` | raw, `/`-separated, mount-relative | the mount **table**, looked up by [`mount_remainder`](@ref) |

**`route` and `key` are different alphabets on purpose.** Since
[#221](https://github.com/PingoLee/Nitro.jl/issues/221) a mount registers one `/<prefix>/**` handler
rather than a literal route per file, and that handler decodes the request before looking it up —
so the table is keyed by the decoded name while the emitted URL stays encoded. Keying the table by
`route` would 404 every name that needed encoding, which is the defect #121 fixed from the other
side.

Returns `route => filepath` for everything it enumerated, in enumeration order. Callers need this
rather than re-deriving paths from the filesystem: `spafiles` uses it to decide whether its
history-mode fallback has a servable `index.html`, which keeps the fallback from drifting away from
the mount rules and re-opening the hole they close.

**Both halves are load-bearing, because a route name does not identify what produced it.** An
`index.html` contributes *two* pairs naming the *same* file — its own route and the bare directory
route — so `/<prefix>/index.html` is the direct route of `<folder>/index.html` and *also* the bare
route of `<folder>/index.html/index.html`. A caller that matches on the route string alone cannot
tell those apart, which is how the fallback once came to be registered against a directory
([#94](https://github.com/PingoLee/Nitro.jl/issues/94)). Match on the filepath and the ambiguity is
unrepresentable: a directory is never a `mountable_files` result
([#102](https://github.com/PingoLee/Nitro.jl/issues/102)).

`mountdir` is canonicalized by [`mount_segments`](@ref), so `"static"`, `"/static"`, `"static/"` and
`"/static/"` name the same mount, and `""`, `"/"` and whitespace all mount at the router root.

**File-derived segments are percent-encoded; the `mountdir` prefix is not.** A name that could not
stand unencoded in a URL path is routed at its encoded spelling by [`_route_encode`](@ref), so
`café.txt` registers `/<prefix>/caf%C3%A9.txt` — the route a conforming client actually sends —
while the pair's second half stays the raw filesystem path
([#121](https://github.com/PingoLee/Nitro.jl/issues/121)). That is the other half of why both halves
are load-bearing: for such a file the route is no longer *derivable* from the filename by joining,
and a caller re-deriving one from the other would miss. `prefix_segments` is left alone because
`mount_segments` validated it and it may already carry `%XX` of its own.
"""
function mountfolder(folder::String, mountdir::String, addroute;
                     include_hidden::Bool=false,
                     allow_symlink_escape::Bool=false) :: Vector{Pair{String,String}}

    separator       = Base.Filesystem.path_separator
    prefix_segments = mount_segments(mountdir)
    routes          = Pair{String,String}[]
    n_encoded       = 0

    for filepath in mountable_files(folder; include_hidden, allow_symlink_escape)

        # remove the first occurrence of the root folder from the filepath before "mounting"
        cleanedmountpath = relpath(filepath, folder)

        # make sure to replace any system path separator with "/"
        cleanedmountpath = replace(cleanedmountpath, separator => "/")

        # Build the route by joining canonical segments. Interpolating a prefix that might already
        # carry a separator is what used to emit routes like `/static//app.js`.
        #
        # Every file-derived segment is percent-encoded (#121) — intermediate directories too, since
        # a directory named `my assets/` is as unreachable as a file would be. `prefix_segments` is
        # deliberately NOT re-encoded: `mount_segments` already validated it and it may legitimately
        # carry its own `%XX`, which encoding again would turn into `%25XX`.
        name_segments    = String.(split(cleanedmountpath, '/'; keepempty=false))
        encoded_segments = map(_route_encode, name_segments)
        segments         = vcat(prefix_segments, encoded_segments)
        mountpath        = mount_route(segments)

        if encoded_segments != name_segments
            n_encoded += 1
            # Capped like the route-pattern warning above, and for the same reason: these names can
            # come from a user-writable upload directory. `@info`, not `@warn` — the file IS served,
            # and at the only route a conforming client can reach it by.
            n_encoded <= 5 && @info "mountfolder: serving a file at its percent-encoded route, because its name is not a legal URL path segment" name=cleanedmountpath route=mountpath
        end

        push!(routes, mountpath => filepath)
        # The third argument is the mount-relative path in its RAW spelling, which is the key
        # `mount_remainder` produces from a decoded request. It is deliberately not the route:
        # the route is percent-ENCODED for emission (#121), while lookup happens after decoding,
        # so the two are different alphabets and conflating them would 404 every encoded name.
        addroute(mountpath, filepath, cleanedmountpath)

        # also register file to the root of each subpath if this file is an index.html
        #
        # Tested against the *raw* leaf name, not the encoded one. `index.html` is pchar-clean so the
        # two are identical today; comparing the raw name is what keeps `bare_path` and the direct
        # route from drifting apart if `_route_encode`'s safe set is ever narrowed.
        if !isempty(name_segments) && last(name_segments) == "index.html"

            # /docs/metrics and /docs/metrics/ are the same path
            # when HTTP is considered.

            # Drop the last segment rather than stripping a "/index.html" suffix off the route. The
            # suffix form matched the *first* occurrence of the substring `/index.html`, so ANY
            # directory whose name starts with `index.html`, at any depth, hijacked the route above
            # it: `/assets/index.html.bak/index.html` yielded `/assets`, so `GET /assets` served a
            # file from inside the backup directory. A root mount yielded `""` (#94).
            bare_path = mount_route(segments[1:end-1])
            push!(routes, bare_path => filepath)
            # The bare route's key is the parent directory — `""` at the mount root, which is
            # exactly what `mount_remainder` returns for a request that stops at the prefix.
            addroute(bare_path, filepath, join(name_segments[1:end-1], "/"))
        end
    end

    # The per-file lines above stop at 5, so without this a mount with 40 encoded names reports 5
    # and never says the other 35 exist -- and the upgrade-log entry points app authors at this
    # log to find what moved. `mountable_files` solves the same problem the same way, with a
    # trailing summary carrying the total.
    n_encoded > 5 && @info "mountfolder: $n_encoded file(s) under $folder are mounted at a percent-encoded route" shown=5

    return routes
end
