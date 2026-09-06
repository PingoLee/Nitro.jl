@testitem "Static mount security" tags=[:core, :security] setup=[NitroCommon] begin

using Test
using HTTP
using Nitro

const MOUNTABLE   = Nitro.Core.Util.mountable_files
const MOUNTFOLDER = Nitro.Core.Util.mountfolder

# `symlink` needs Developer Mode or admin on Windows, and an unprivileged *file* symlink has no
# equivalent there at all. A directory **junction** does (`mklink /J`), and Julia's `islink` reports
# one as a link while `walkdir` classifies it as a file.
#
# A junction does NOT isolate the escape rule, though: it is also not a regular file, so it is
# refused even with `allow_symlink_escape=true`. On a host without file symlinks the containment
# logic is covered by the direct `_is_within` / `_resolves_hidden` unit tests below, which need no
# filesystem support at all — that is what keeps the Windows leg honest rather than vacuous.
#
# Never replace any of this with a committed symlink fixture: git on Windows checks a symlink out as
# a plain text file containing the target path unless `core.symlinks=true` and Developer Mode is on,
# which would make these assertions pass while testing nothing.
function make_link(target::String, link::String; isdir_target::Bool=false)
    try
        if Sys.iswindows() && isdir_target
            run(pipeline(`cmd /c mklink /J $link $target`; stdout=devnull, stderr=devnull))
        else
            symlink(target, link)
        end
        return islink(link)
    catch
        return false
    end
end

relunix(p, root) = replace(relpath(p, root), '\\' => '/')
servable(root; kw...) = Set(relunix(p, root) for p in MOUNTABLE(root; kw...))

# ── fixture tree ──────────────────────────────────────────────────────────────
root    = mktempdir()
outside = mktempdir()
write(joinpath(outside, "secret.txt"), "TOP SECRET")

write(joinpath(root, "visible.txt"), "visible")
write(joinpath(root, "file.min.js"), "minified")     # interior dots — must NOT be read as hidden
write(joinpath(root, "myfile"), "no extension")
write(joinpath(root, "index.html"), "<h1>index</h1>")
write(joinpath(root, ".env"), "TOKEN=hunter2")
mkpath(joinpath(root, ".git"))
write(joinpath(root, ".git", "config"), "[core]")
mkpath(joinpath(root, "sub"))
write(joinpath(root, "sub", "nested.txt"), "nested")
write(joinpath(root, "{id}.txt"), "would become a path variable")

# `*` is not a legal filename character on Windows.
has_star = try
    write(joinpath(root, "**"), "would become a wildcard"); true
catch
    false
end

has_escape_dir  = make_link(outside, joinpath(root, "escape_dir"); isdir_target=true)
has_escape_file = make_link(joinpath(outside, "secret.txt"), joinpath(root, "escape.csv"))
has_inside_file = make_link(joinpath(root, "visible.txt"), joinpath(root, "inside_link.txt"))
has_inside_dir  = make_link(joinpath(root, "sub"), joinpath(root, "sub_link"); isdir_target=true)
has_dangling    = make_link(joinpath(root, "nope.txt"), joinpath(root, "dangling.txt"))
# Innocent name, hidden target, both inside the mount — the dotfile-rule bypass.
has_inside_hidden_link = make_link(joinpath(root, ".env"), joinpath(root, "innocent.txt"))

@testset "containment: _is_within" begin
    # Both sides go through `splitpath` so these assert the comparison logic rather than a guess at
    # how `splitpath` spells a root on this platform. Runs everywhere — no symlink support needed,
    # which is what gives the escape rule real coverage on unprivileged Windows.
    W = Nitro.Core.Util._is_within
    within(root, path) = W(splitpath(root), path)

    @test within("/srv/app", "/srv/app/js/a.js")
    @test within("/srv/app", "/srv/app/deep/er/x")
    @test !within("/srv/app", "/srv/app-secrets/x")   # prefix-boundary trap: NOT a string prefix
    @test !within("/srv/app", "/srv/app")             # the root is never inside itself
    @test !within("/srv/app", "/srv")
    @test !within("/srv/app", "/etc/passwd")

    if Sys.iswindows()
        @test within(raw"C:\srv\app", raw"C:\srv\app\a.txt")
        @test !within(raw"C:\srv\app", raw"C:\srv\app-secrets\x")
        @test within("C:\\", raw"C:\Windows\win.ini")
        # A cross-drive target has no `..` relationship at all, which is why containment cannot be
        # written with `relpath` — it would fail open here.
        @test !within(raw"C:\srv\app", raw"D:\srv\app\a.txt")

        # `splitpath` drops the trailing separator from a UNC share root standing alone but keeps it
        # when components follow, so the two spellings must still compare equal.
        @test splitpath(raw"\\host\share") != splitpath(raw"\\host\share\sub")[1:1]
        @test within(raw"\\host\share", raw"\\host\share\pub\a.txt")
        @test within(raw"\\host\share" * "\\", raw"\\host\share\pub\a.txt")
        @test !within(raw"\\host\share", raw"\\other\share\pub\a.txt")
    end
end

@testset "policy applies to what a link resolves to, not just its name" begin
    # The hidden rule tests the *entry name*. A link whose name is innocent but whose target is a
    # dotfile inside the mount passes the name test, passes containment, and is a regular file — so
    # without a resolved-target check it re-opens exactly the hole the hidden rule closes.
    R = Nitro.Core.Util._resolves_hidden
    within(root, path) = (splitpath(root), path)

    rp, p = within("/srv/app", "/srv/app/.env")
    @test R(rp, p)
    rp, p = within("/srv/app", "/srv/app/.git/config")
    @test R(rp, p)
    rp, p = within("/srv/app", "/srv/app/assets/app.js")
    @test !R(rp, p)
    rp, p = within("/srv/app", "/srv/app/file.min.js")
    @test !R(rp, p)
    # The root's own name is below nothing, so a dotted mount root is never self-refusing.
    rp, p = within("/srv/.well-known", "/srv/.well-known/security.txt")
    @test !R(rp, p)

    if has_inside_hidden_link
        files = servable(root)
        @test "innocent.txt" ∉ files                          # -> .env
        @test "innocent.txt" ∈ servable(root; include_hidden=true)

        resetstate()
        try
            staticfiles(root, "static")
            r = internalrequest(HTTP.Request("GET", "/static/innocent.txt"))
            @test r.status == 404
            @test !occursin("hunter2", String(r.body))
        finally
            resetstate()
        end
    end
end

@testset "link fixtures are available where the platform supports them" begin
    # Makes coverage degradation visible instead of silent: if file symlinks ever stop working on
    # POSIX CI, the guarded assertions below would quietly vanish and the suite would still pass.
    if Sys.isunix()
        @test has_escape_file
        @test has_inside_file
        @test has_dangling
        @test has_star
        @test has_inside_hidden_link
    else
        @info "file symlinks unavailable on this host — link-dependent assertions are skipped; \
               containment is covered by the _is_within / _resolves_hidden testsets" has_escape_dir has_escape_file has_star
        @test has_escape_dir   # junctions must work on Windows, or nothing here tests links at all
    end
end

@testset "hidden entries are refused by default" begin
    files = servable(root)
    @test ".env" ∉ files
    @test ".git/config" ∉ files

    opened = servable(root; include_hidden=true)
    @test ".env" ∈ opened
    @test ".git/config" ∈ opened
end

@testset "ordinary names are unaffected" begin
    files = servable(root)
    @test "visible.txt" ∈ files
    @test "file.min.js" ∈ files      # a naive `occursin('.')` predicate would drop this
    @test "myfile" ∈ files
    @test "sub/nested.txt" ∈ files
end

@testset "filenames that would register as route patterns are always refused" begin
    @test "{id}.txt" ∉ servable(root)
    # Not an opt-out: a file cannot claim other URLs even when hidden files are allowed.
    @test "{id}.txt" ∉ servable(root; include_hidden=true)
    @test "{id}.txt" ∉ servable(root; allow_symlink_escape=true)
    if has_star
        @test "**" ∉ servable(root)
    end
end

@testset "symlinks escaping the mount are refused" begin
    files = servable(root)

    if has_escape_dir
        @test "escape_dir" ∉ files
        # A junction/dirlink is refused even with the escape opt-out: it is not a regular file, and
        # registering it would make the eager read in `staticfiles` throw at startup.
        @test "escape_dir" ∉ servable(root; allow_symlink_escape=true)
    end

    if has_escape_file
        @test "escape.csv" ∉ files
        @test "escape.csv" ∈ servable(root; allow_symlink_escape=true)
    end

    if !has_escape_dir && !has_escape_file
        @info "no link type available on this host — escape assertions skipped"
    end
end

@testset "links that stay inside the mount" begin
    if has_inside_file
        # Confinement, not refusal: an intra-mount link is legitimate and still served.
        @test "inside_link.txt" ∈ servable(root)
    end
    if has_inside_dir
        # Refused because it is a directory, not because it escapes — and crucially the mount must
        # not throw, which is what registering a directory-backed route used to cause.
        @test "sub_link" ∉ servable(root)
    end
end

if has_dangling
    @testset "dangling links are skipped, not propagated" begin
        @test "dangling.txt" ∉ servable(root)

        # A `realpath` that throws must be caught and the entry skipped, not propagated out of the
        # enumerator — returning the surviving file *is* the assertion that nothing escaped.
        clean = mktempdir()
        write(joinpath(clean, "kept.txt"), "kept")
        @test make_link(joinpath(clean, "gone.txt"), joinpath(clean, "broken.txt"))
        @test servable(clean) == Set(["kept.txt"])
    end
end

@testset "a missing mount root is an error, not an empty mount" begin
    @test_throws ArgumentError MOUNTABLE(joinpath(root, "does_not_exist"))
    @test_throws ArgumentError MOUNTABLE(joinpath(root, "visible.txt"))   # a file is not a folder
end

@testset "mountfolder reports the routes it registered" begin
    registered = String[]
    routes = MOUNTFOLDER(root, "assets", (route, _path) -> push!(registered, route))

    @test routes == registered
    @test "/assets/visible.txt" ∈ routes
    @test "/assets/.env" ∉ routes
    @test "/assets/{id}.txt" ∉ routes
    # index.html also claims the bare directory path
    @test "/assets/index.html" ∈ routes
    @test "/assets" ∈ routes
end

@testset "every spelling of a mountdir names the same mount" begin
    # `mountdir` is canonicalized once, in `mount_segments` -- the three public mount functions no
    # longer strip anything themselves (#93). Driving `mountfolder` directly needs no router and no
    # global state, so this is the cheap place to pin the whole equivalence class.
    baseline = MOUNTFOLDER(root, "assets", (_r, _p) -> nothing)
    for md in ("/assets", "assets/", "/assets/", "//assets//", " /assets/ ")
        @test MOUNTFOLDER(root, md, (_r, _p) -> nothing) == baseline
    end

    # `""` used to throw a BoundsError at the entry point, while everything downstream already
    # treated it as "mount at the root".
    root_baseline = MOUNTFOLDER(root, "", (_r, _p) -> nothing)
    for md in ("/", "   ", " / ")
        @test MOUNTFOLDER(root, md, (_r, _p) -> nothing) == root_baseline
    end
    @test "/visible.txt" ∈ root_baseline
    @test "/index.html" ∈ root_baseline

    # Routes are rebuilt by joining segments, so a doubled separator is unrepresentable. Interior
    # separators are still a real nested mount, not a spelling variant.
    for md in ("assets", "/assets/", "//assets//", "", "/", "a/b")
        for route in MOUNTFOLDER(root, md, (_r, _p) -> nothing)
            @test !occursin("//", route)
            @test startswith(route, "/")
        end
    end
    @test "/a/b/visible.txt" ∈ MOUNTFOLDER(root, "a/b", (_r, _p) -> nothing)
end

@testset "a directory named index.html does not claim the mount root" begin
    # The bare directory route is the mount path minus its last segment. Deriving it by stripping a
    # "/index.html" suffix took the *first* occurrence, so a directory literally named `index.html`
    # hijacked the route above it (#94). `test/content/` cannot host this fixture: it is flat, and a
    # committed directory named `index.html` would change `original_tests.jl`'s `/static/` case.
    nested = mktempdir()
    write(joinpath(nested, "app.js"), "console.log(1)")
    mkpath(joinpath(nested, "index.html"))
    write(joinpath(nested, "index.html", "index.html"), "<h1>nested</h1>")

    routes = MOUNTFOLDER(nested, "assets", (_r, _p) -> nothing)
    @test "/assets/index.html/index.html" ∈ routes
    @test "/assets/index.html" ∈ routes   # the bare path of the NESTED index
    @test "/assets" ∉ routes              # the hijack: this was the nested file's bare path
    @test "" ∉ routes

    # A root mount's bare directory route is spelled "/", not "".
    root_routes = MOUNTFOLDER(nested, "", (_r, _p) -> nothing)
    @test "/index.html/index.html" ∈ root_routes
    @test "/index.html" ∈ root_routes
    @test "/" ∉ root_routes               # nothing here is a *top-level* index.html
    @test "" ∉ root_routes

    # A genuine top-level index.html claims "/" rather than the empty string.
    @test "/" ∈ MOUNTFOLDER(root, "", (_r, _p) -> nothing)
    @test "" ∉ MOUNTFOLDER(root, "", (_r, _p) -> nothing)

    resetstate()
    try
        staticfiles(nested, "assets")
        r = internalrequest(HTTP.Request("GET", "/assets/index.html"))
        @test r.status == 200
        @test String(r.body) == "<h1>nested</h1>"
        @test internalrequest(HTTP.Request("GET", "/assets")).status == 404
    finally
        resetstate()
    end

    # `spafiles` gates its history-mode fallback on the mount having registered an index route --
    # but a route name does not say what produced it. Here `/assets/index.html` is the *bare* route
    # of `index.html/index.html`, so the name matches while `<folder>/index.html` is a directory.
    # Registering the fallback against it made every unmatched request 500 on `read(::dir)`.
    resetstate()
    try
        @test_logs (:warn, r"no servable 'index.html'") spafiles(nested, "assets")
        @test internalrequest(HTTP.Request("GET", "/assets/deep/link")).status == 404
    finally
        resetstate()
    end
end

@testset "the index.html hijack was a prefix match, at any depth" begin
    # The old derivation matched the first occurrence of the *substring* "/index.html", so it was
    # never limited to a directory named exactly `index.html` -- `index.html.bak/` (an editor or
    # build backup, entirely plausible) hijacked the route above it just the same, and a match
    # deeper in the tree hijacked everything above that.
    tree = mktempdir()
    mkpath(joinpath(tree, "index.html.bak"))
    write(joinpath(tree, "index.html.bak", "index.html"), "<h1>backup</h1>")
    mkpath(joinpath(tree, "docs", "index.htmlx", "guide"))
    write(joinpath(tree, "docs", "index.htmlx", "guide", "index.html"), "<h1>guide</h1>")

    routes = MOUNTFOLDER(tree, "assets", (_r, _p) -> nothing)
    @test "/assets/index.html.bak" ∈ routes            # old code produced "/assets"
    @test "/assets/docs/index.htmlx/guide" ∈ routes    # old code produced "/assets/docs"
    @test "/assets" ∉ routes
    @test "" ∉ routes

    resetstate()
    try
        staticfiles(tree, "assets")
        @test String(internalrequest(HTTP.Request("GET", "/assets/index.html.bak")).body) == "<h1>backup</h1>"
        @test internalrequest(HTTP.Request("GET", "/assets")).status == 404
    finally
        resetstate()
    end
end

@testset "the three mount functions accept a root mountdir" begin
    # The literal #93 report: `staticfiles(folder, "")` died on `first("")` before doing anything.
    resetstate()
    try
        staticfiles(root, "")
        @test internalrequest(HTTP.Request("GET", "/visible.txt")).status == 200
        @test internalrequest(HTTP.Request("GET", "/.env")).status == 404
    finally
        resetstate()
    end

    # `"/"` alone would not discriminate here: the old code stripped it to `""` and `mount_prefix`
    # accepted that. `""` is the spelling that used to throw.
    resetstate()
    try
        dynamicfiles(root, "")
        @test internalrequest(HTTP.Request("GET", "/visible.txt")).status == 200
        @test internalrequest(HTTP.Request("GET", "/.env")).status == 404
    finally
        resetstate()
    end

    # spafiles registers `GET /**` for a root mount, which swallows every 404 -- so it gets its own
    # block and asserts nothing negative.
    resetstate()
    try
        spafiles(root, "")
        @test internalrequest(HTTP.Request("GET", "/visible.txt")).status == 200
        @test internalrequest(HTTP.Request("GET", "/index.html")).status == 200
    finally
        resetstate()
    end
end

@testset "non-canonical mountdir spellings reach the router" begin
    # The deleted leading-slash strips lived in the three *public* functions, so the equivalence
    # class above -- which drives `mountfolder` directly -- cannot prove they are gone. These do.
    for mountdir in ("assets", "/assets", "assets/", "/assets/", "//assets//", " /assets/ ")
        resetstate()
        try
            staticfiles(root, mountdir)
            @test internalrequest(HTTP.Request("GET", "/assets/visible.txt")).status == 200
            @test internalrequest(HTTP.Request("GET", "/assets")).status == 200   # bare index.html
            @test internalrequest(HTTP.Request("GET", "/assets/.env")).status == 404
        finally
            resetstate()
        end
    end
end

@testset "refused files are not reachable through the router" begin
    resetstate()
    try
        staticfiles(root, "static")

        @test internalrequest(HTTP.Request("GET", "/static/visible.txt")).status == 200
        @test internalrequest(HTTP.Request("GET", "/static/.env")).status == 404
        @test internalrequest(HTTP.Request("GET", "/static/.git/config")).status == 404
        @test internalrequest(HTTP.Request("GET", "/static/{id}.txt")).status == 404

        if has_escape_file
            r = internalrequest(HTTP.Request("GET", "/static/escape.csv"))
            @test r.status == 404
            @test !occursin("TOP SECRET", String(r.body))
        end
    finally
        resetstate()
    end
end

@testset "include_hidden=true is a real opt-in" begin
    resetstate()
    try
        staticfiles(root, "static"; include_hidden=true)
        r = internalrequest(HTTP.Request("GET", "/static/.env"))
        @test r.status == 200
        @test occursin("hunter2", String(r.body))
    finally
        resetstate()
    end
end

@testset "dynamicfiles applies the mount rules and re-reads content" begin
    # Enumeration is mount-time only by design — a directory whose contents an attacker can change
    # belongs behind a proxy, not behind a partial in-app re-check. See
    # docs/design/static-serving-boundary.md. What `dynamicfiles` does promise is that the *content*
    # is re-read per request, and that refused files never get a route in the first place.
    live = mktempdir()
    write(joinpath(live, "page.txt"), "first")
    write(joinpath(live, ".env"), "SECRET=1")

    resetstate()
    try
        dynamicfiles(live, "media")

        r = internalrequest(HTTP.Request("GET", "/media/page.txt"))
        @test r.status == 200
        @test String(r.body) == "first"

        write(joinpath(live, "page.txt"), "second")
        @test String(internalrequest(HTTP.Request("GET", "/media/page.txt")).body) == "second"

        @test internalrequest(HTTP.Request("GET", "/media/.env")).status == 404
    finally
        resetstate()
    end
end

@testset "spafiles does not fall back to an unservable index.html" begin
    spa = mktempdir()
    write(joinpath(spa, "app.js"), "console.log(1)")

    if make_link(joinpath(outside, "secret.txt"), joinpath(spa, "index.html"))
        resetstate()
        try
            spafiles(spa, "app")
            # The mount refuses the index, so the history-mode catch-all must not be registered —
            # otherwise the refused file is served on *every* unmatched path under the mount.
            @test internalrequest(HTTP.Request("GET", "/app/index.html")).status == 404
            r = internalrequest(HTTP.Request("GET", "/app/deep/link"))
            @test r.status == 404
            @test !occursin("TOP SECRET", String(r.body))
        finally
            resetstate()
        end
    else
        @info "file symlinks unavailable on this host — spafiles fallback assertion skipped"
    end

    # A servable index.html still gets its fallback.
    ok = mktempdir()
    write(joinpath(ok, "index.html"), "<h1>spa</h1>")
    resetstate()
    try
        spafiles(ok, "app2")
        r = internalrequest(HTTP.Request("GET", "/app2/deep/link"))
        @test r.status == 200
        @test occursin("spa", String(r.body))
    finally
        resetstate()
    end
end

end
