@testitem "Static mount security" tags=[:core, :security] setup=[NitroCommon] begin

using Test
using HTTP
using Nitro
import SHA

const MOUNTABLE   = Nitro.Core.Util.mountable_files
const MOUNTFOLDER = Nitro.Core.Util.mountfolder

# `mountfolder` returns `route => filepath` pairs (#102). Most assertions here are about the route
# set alone, so unwrap once. This is not a convenience: a `String` is never `isequal` to a `Pair`, so
# leaving a `∉` to compare against the raw pair vector makes it VACUOUSLY TRUE -- every negative
# assertion below would keep passing while testing nothing, and the negatives are the security half.
mountroutes(args...; kw...) = first.(MOUNTFOLDER(args...; kw...))

# Read a response body WITHOUT consuming it.
#
# `String(::Vector{UInt8})` takes ownership and leaves the source vector empty. `staticfiles` and
# `spafiles` hand back ONE cached `Response` per file, so a plain `String(resp.body)` drains it for
# every later request that resolves to the same file -- and since #221 several URLs legitimately do
# (an encoded name and its raw spelling, a mount-root `index.html` and the bare mount route, every
# unmatched path under an SPA mount). The next read then sees `""` and the failure looks like a
# serving bug rather than a test one.
function bodystr(r)
    b = r.body
    b isa AbstractString        && return String(b)
    b isa AbstractVector{UInt8} && return String(copy(b))
    b isa HTTP.BytesBody        && return String(copy(b.data))
    return ""   # HTTP.EmptyBody -- what a bare `Response(404)` carries
end

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
            @test !occursin("hunter2", bodystr(r))
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

@testset "a mountdir that would register as a route pattern is refused" begin
    # The rule above has always applied to *filenames*, on the grounds that a file must not claim
    # URLs other than its own. Nothing applied it to `mountdir`, so a mount could do exactly what a
    # file is forbidden from doing: `staticfiles(dir, "*")` registered `/*/<file>` **and** a bare
    # `/*`, so `GET /anything` was answered by the mount's index.html. `**` and `{id}` already threw
    # at registration; `*` was the one that came up clean, which is what made it worth closing (#101).
    for md in ("*", "**", "{id}", "a/{id}/b", "assets/*", "}")
        @test_throws ArgumentError MOUNTFOLDER(root, md, (_r, _p, _k) -> nothing)
    end

    # The public entry points, not just the helper -- that is where the footgun was reachable.
    resetstate()
    try
        @test_throws ArgumentError staticfiles(root, "*")
        @test_throws ArgumentError spafiles(root, "*")
        @test_throws ArgumentError dynamicfiles(root, "*")
        # `mountdir` is canonicalized before enumeration, so a refusal registers nothing on the way
        # out -- these are the two requests the wildcard mount used to answer.
        @test internalrequest(HTTP.Request("GET", "/anything")).status == 404
        @test internalrequest(HTTP.Request("GET", "/x/visible.txt")).status == 404
    finally
        resetstate()
    end
end

@testset "a mountdir that is not a legal URL path segment is refused" begin
    # HTTP.jl splits the request target on "/" and compares segments byte for byte; it never
    # percent-decodes. A segment outside RFC 3986 pchar therefore registers routes no *conforming*
    # client can reach. For `"my static"` that is absolute -- a space cannot appear in a request
    # line at all -- which is the silent case #101 calls the worst of the three options. For
    # `"café"` and the bracket/pipe family it is not: those answered a raw-byte client (curl), so
    # refusing them is a real capability change, recorded in the #101 upgrade-log entry rather than
    # papered over. `..` is here because `.` is *unreserved*, so it passes the
    # encoding test and is still stripped by the client before the request is sent.
    for md in ("my static", "café", "a?b", "a#b", "%", "a%2", "%GG", "100%", "a[b]", "a|b", "..")
        @test_throws ArgumentError MOUNTFOLDER(root, md, (_r, _p, _k) -> nothing)
    end

    # pchar, not "ASCII alphanumeric" -- these are legal path segments and must still mount.
    for md in ("my%20static", "a:b", "a@b", "a+b", "a.b-c_d~e", "caf%C3%A9")
        @test !isempty(MOUNTFOLDER(root, md, (_r, _p, _k) -> nothing))
    end

    # The whole justification for allowing `%XX`: the encoded spelling is the one a conforming client
    # actually sends, so refusing "my static" while accepting "my%20static" turns a dead mount into a
    # working one. That framing holds for a space, which no request line can carry; it does NOT
    # generalize to "café" and friends, which were reachable by a raw-byte client.
    resetstate()
    try
        staticfiles(root, "my%20static")
        @test internalrequest(HTTP.Request("GET", "/my%20static/visible.txt")).status == 200
    finally
        resetstate()
    end
end

# ── #121: the filename half of the same defect, answered the other way round ──────────────────────
#
# A `mountdir` that is not a legal URL path segment THROWS (#101, above). A *filename* that is not
# one is percent-ENCODED and served at the encoded route, because filenames arrive in bulk from the
# filesystem and a refusal at that layer skips silently -- which would trade a route nobody can
# reach for a file nobody can reach.
#
# Its own tree, not the shared `root`: these names would otherwise change the route sets that the
# `mountfolder`/`mountdir`-spelling testsets above and below assert against.
enc_root = mktempdir()

# Every fixture below is created through this, and a name only enters the assertion set if the
# filesystem actually produced *that* name. Two distinct hazards, and `isfile` catches neither:
#
#  - `write` can THROW. `a:b.txt` is legal `pchar` but reserved on Windows, where `<tmp>\a:b.txt` is
#    NTFS alternate-data-stream syntax (base file `a`, stream `b.txt`). An unguarded write there
#    either throws -- taking every assertion in this test item down with it, including the symlink
#    and hidden-file security ones -- or silently creates a file named `a`.
#  - A NORMALIZING filesystem can create the file under a *different* name. On an NFD-normalizing
#    volume `isfile("café.txt")` is true while `readdir` returns the NFD spelling, so the route
#    would be `cafe%CC%81.txt` and the assertion would fail confusingly rather than skip.
#
# Checking membership in `readdir` is what distinguishes "not created" from "created under another
# name". Same reason the `has_star` guard above exists -- `:` is just the one that is easy to miss.
function make_fixture(dir, name, content)
    try
        write(joinpath(dir, name), content)
        return name ∈ readdir(dir)
    catch
        return false
    end
end

# Names that must survive byte for byte. Every one of these is legal `pchar`, so a conforming client
# sends it raw and it already worked -- this is the half that must NOT move.
#
# Against the full Windows rule set (reserved `< > : " / \ | ? *`, device names, trailing dot or
# space) exactly one of these is hostile: `a:b.txt`, where `<tmp>\a:b.txt` is ADS syntax. Parens,
# `+` and `@` are unreserved there, and `~` is special only in 8.3 short-name *generation*, never in
# a literal name. `a:b.txt`'s route property is a pure string fact and is pinned filesystem-free in
# test/util_tests.jl, so nothing is lost by not writing that file.
const PCHAR_CANDIDATES = ["plain.txt", "report(1).txt", "a+b.txt", "v1.2~beta.txt", "a:b.txt",
                          "a@b.txt", "file.min.js", "myfile"]
const PCHAR_SKIPPABLE  = Sys.iswindows() ? ["a:b.txt"] : String[]
pchar_clean = String[]
for n in PCHAR_CANDIDATES
    make_fixture(enc_root, n, "BODY:" * n) && push!(pchar_clean, n)
end

# Names that need encoding, paired with the route they must register.
made_encoding = Dict{String,String}()
for (name, route) in ("café.txt"      => "caf%C3%A9.txt",
                      "my file.txt"   => "my%20file.txt",
                      "100%.txt"      => "100%25.txt",
                      "my%20file.txt" => "my%2520file.txt")
    make_fixture(enc_root, name, "BODY:" * name) && (made_encoding[name] = route)
end

# A directory whose own name needs encoding, holding both an ordinary file and an `index.html`.
# The `index.html` is not decoration: `mountfolder` derives the bare directory route from the
# ENCODED segments while testing the RAW leaf name, and this is the only fixture in the suite that
# exercises that combination.
has_spaced_dir = try
    mkpath(joinpath(enc_root, "sub dir"))
    a = make_fixture(joinpath(enc_root, "sub dir"), "x.txt", "BODY:sub dir/x.txt")
    b = make_fixture(joinpath(enc_root, "sub dir"), "index.html", "BODY:sub dir/index.html")
    a && b
catch
    false
end

# A vacuity tripwire, and it must sit AFTER every guard it checks. All of these names are legal on
# ext4, APFS and NTFS (bar the one Windows exception noted above), so no supported platform should skip
# them -- and a guard that ever did fire would turn its testsets into silent no-ops while the run
# still reported green. `has_spaced_dir` is the one that matters most: the assertions behind it are
# the ONLY coverage anywhere in the suite of the branch this change edited (`mountfolder` testing
# the raw leaf name while `bare_path` derives from the encoded segments).
@testset "the #121 fixtures were actually created" begin
    @test has_spaced_dir
    # `setdiff` rather than a count, so a failure names the missing fixture. A count of 7 cannot
    # tell "Windows skipped `a:b.txt`" from "some host silently skipped `a@b.txt` instead".
    @test setdiff(PCHAR_CANDIDATES, pchar_clean) ⊆ PCHAR_SKIPPABLE
    @test length(made_encoding) == 4
end

@testset "a filename that must be percent-encoded mounts at its encoded route" begin
    routes = Set(mountroutes(enc_root, "enc", (_r, _p, _k) -> nothing))

    encoded_routes = Set("/enc/" * e for e in values(made_encoding))
    for (name, encoded) in made_encoding
        @test "/enc/$encoded" ∈ routes
        # The discriminating half: the raw spelling is NOT registered. Without this the assertion
        # above would pass on unpatched code for any name that needed no encoding.
        #
        # Guarded, because the two namespaces overlap in exactly one direction: the raw name
        # `my%20file.txt` IS a registered route -- it is the *encoded* route of the sibling file
        # `my file.txt`. So skip the negative where a name collides with another fixture's encoded
        # route, and let the injectivity testset below pin that the two resolve to different files.
        if "/enc/$name" ∉ encoded_routes
            @test "/enc/$name" ∉ routes
        end
    end

    if has_spaced_dir
        # An intermediate directory segment is encoded too -- a directory named `sub dir/` is as
        # unreachable as a file would be.
        @test "/enc/sub%20dir/x.txt" ∈ routes
        @test "/enc/sub dir/x.txt" ∉ routes

        # The BARE directory route of an encoded directory. This is the line `mountfolder` changed:
        # the `index.html` test now reads the RAW leaf name while `bare_path` is still built from
        # the ENCODED segments. Revert either half and this is the assertion that catches it --
        # otherwise the bare route of every space-bearing SPA subdirectory goes unreachable, or the
        # two spellings drift apart, with nothing else in the suite noticing.
        @test "/enc/sub%20dir/index.html" ∈ routes
        @test "/enc/sub%20dir"            ∈ routes
        @test "/enc/sub dir"              ∉ routes
    end

    # Through the router, which is the claim that actually matters: the encoded URL is the one a
    # browser sends, and before #121 it was a 404.
    resetstate()
    try
        staticfiles(enc_root, "enc")
        for (name, encoded) in made_encoding
            resp = internalrequest(HTTP.Request("GET", "/enc/$encoded"))
            @test resp.status == 200
            # Not just a 200 -- the *right* file. `my file.txt` and `my%20file.txt` both exist in
            # this tree and their routes are one `%25` apart, so a body check is what proves the
            # encoding did not collapse them onto each other.
            @test bodystr(resp) == "BODY:" * name
        end
        if has_spaced_dir
            @test internalrequest(HTTP.Request("GET", "/enc/sub%20dir/x.txt")).status == 200
            # The bare directory route serves the index, through the router.
            bare = internalrequest(HTTP.Request("GET", "/enc/sub%20dir"))
            @test bare.status == 200
            @test bodystr(bare) == "BODY:sub dir/index.html"
        end

        # BOTH spellings now serve the file, and this assertion is REVERSED from what it asserted
        # before #221.
        #
        # It used to read `status == 404` for the raw spelling, and that was correct for its design:
        # a mount registered one literal route per file, HTTP.jl matched path segments byte for
        # byte, and `caf%C3%A9.txt` and `café.txt` are disjoint byte strings -- so #101 and #121
        # each had to CHOOSE which of the two clients to serve, and both chose the browser. The
        # `upgrading/2026-09-18-121-encoded-filename-routes.md` entry records the other half as a
        # cost it could not avoid: "A non-browser client sending raw bytes loses `café.txt` ...
        # Changing the server does not migrate such a client."
        #
        # #221 removes the choice instead of making it. The mount registers ONE `/<prefix>/**`
        # handler and decodes the remainder before looking it up in the enumerated table, so both
        # spellings normalize to the one key `café.txt` and both are served. That is the behaviour
        # every comparable framework has, and it is why the whole #101/#94/#121 class is gone rather
        # than handled.
        #
        # The router's byte-exactness is UNCHANGED and is still load-bearing -- `Types.pathparams`
        # would double-decode if it ever went away. It is pinned where it belongs, on the router
        # itself, in `test/http_internals_contract_tests.jl` ("router hands over STILL-ENCODED path
        # segments"), rather than indirectly through a mount that no longer depends on it.
        if haskey(made_encoding, "café.txt")
            encoded = internalrequest(HTTP.Request("GET", "/enc/caf%C3%A9.txt"))
            raw     = internalrequest(HTTP.Request("GET", "/enc/café.txt"))
            @test encoded.status == 200
            @test raw.status == 200
            # `bodystr` copies: both spellings resolve to the SAME cached `Response`, and
            # `String(::Vector{UInt8})` takes ownership of the vector it is handed.
            @test bodystr(raw) == "BODY:café.txt"
            @test bodystr(encoded) == "BODY:café.txt"
        end
    finally
        resetstate()
    end
end

@testset "a pchar-clean filename keeps its route byte for byte" begin
    # The invariance half of #121, and the reason the encoder's safe set is `_is_pchar` rather than
    # `HTTP.escapeuri`'s. `escapeuri` keeps only `A-Za-z0-9-._`, so it would also encode `~` and
    # every sub-delim plus `:` and `@` -- measured over a socket, all of the names below serve today
    # at their literal routes and 404 at the over-encoded ones. Encoding with `escapeuri` would have
    # broken five working shapes to fix three.
    #
    # These assertions pass against unpatched code by design: that IS the property under test.
    # The discriminating siblings are in the testset above.
    routes = Set(mountroutes(enc_root, "enc", (_r, _p, _k) -> nothing))
    for n in pchar_clean
        @test "/enc/$n" ∈ routes
    end

    # And the over-encoded spellings `escapeuri` would have produced are NOT registered.
    for bad in ("report%281%29.txt", "a%2Bb.txt", "v1.2%7Ebeta.txt", "a%3Ab.txt", "a%40b.txt")
        @test "/enc/$bad" ∉ routes
    end
end

@testset "a literal percent in a filename is encoded, not passed through" begin
    # The one place the filename rule deliberately disagrees with the `mountdir` rule, and the one
    # case where a route a *browser* could already reach moves.
    #
    # A `mountdir` is AUTHORED: `"my%20static"` is someone spelling a space on purpose, so the
    # triplet is validated and passed through (the #101 testset above pins that).
    # A filename is DATA: a file named `my%20file.txt` contains the three characters `%`, `2`, `0`,
    # so its route is `my%2520file.txt`. Passing the triplet through here would make one URL name
    # two different files.
    if haskey(made_encoding, "my%20file.txt") && haskey(made_encoding, "my file.txt")
        routes = Set(mountroutes(enc_root, "enc", (_r, _p, _k) -> nothing))
        @test "/enc/my%2520file.txt" ∈ routes      # the literal-% file
        @test "/enc/my%20file.txt"   ∈ routes      # `my file.txt`, whose encoded form this is
        # Both present, and each resolves to its own file -- pinned by body in the first testset.
        # Before #121 the literal-% file owned `/enc/my%20file.txt` and `my file.txt` owned nothing
        # a client could send.

        # Side by side with the mountdir half, so the asymmetry is pinned in one place rather than
        # inferred from two testsets that never meet.
        @test Nitro.Core.Util.mount_segments("my%20static") == ["my%20static"]
        @test Nitro.Core.Util._route_encode("my%20static") == "my%2520static"
    end
end

@testset "distinct filenames cannot collapse onto one route" begin
    # `_route_encode` is injective because `%` is itself encoded, so no two names can be given the
    # same route -- which would otherwise mean one file silently shadowing another through HTTP.jl's
    # `replacing existing registered route` path.
    inj = mktempdir()
    # Derived from what landed on disk, not asserted by writing `true` -- a name that failed to be
    # created would otherwise make this whole testset a no-op that still reports green.
    ok = make_fixture(inj, "a b.txt", "BODY:space") &&
         make_fixture(inj, "a%20b.txt", "BODY:literal")
    @test ok          # both names are legal everywhere; a skip here would be a silent no-op
    if ok
        routes = mountroutes(inj, "i", (_r, _p, _k) -> nothing)
        @test length(routes) == length(Set(routes))
        @test Set(routes) == Set(["/i/a%20b.txt", "/i/a%2520b.txt"])

        resetstate()
        try
            staticfiles(inj, "i")
            @test String(internalrequest(HTTP.Request("GET", "/i/a%20b.txt")).body)   == "BODY:space"
            @test String(internalrequest(HTTP.Request("GET", "/i/a%2520b.txt")).body) == "BODY:literal"
        finally
            resetstate()
        end
    end
end

@testset "route-pattern filenames are refused, not encoded" begin
    # `*` and `**` are legal `pchar`, so `_route_encode` leaves them alone -- nothing but the
    # `_is_route_pattern` refusal stops a file named `*` from shadowing its siblings. Braces WOULD
    # be encoded, but the refusal runs first, so `{id}.txt` stays skipped rather than becoming
    # servable at `%7Bid%7D.txt`. Encoding braces would change WHAT a mount serves, not only where.
    routes = Set(mountroutes(root, "x", (_r, _p, _k) -> nothing))
    @test "/x/{id}.txt"      ∉ routes
    @test "/x/%7Bid%7D.txt"  ∉ routes
    if has_star
        @test "/x/**"   ∉ routes
        @test "/x/%2A%2A" ∉ routes
    end
end

@testset "the encoded route pairs with the raw filesystem path" begin
    # #102's contract survives #121: the route half may now be encoded, but the filepath half is
    # still `joinpath(root, name)` verbatim, so `joinpath` remains a valid key into the pair vector.
    # That is what `spafiles` relies on to find its index by file.
    pairs_ = MOUNTFOLDER(enc_root, "enc", (_r, _p, _k) -> nothing)
    for (name, encoded) in made_encoding
        idx = findfirst(p -> last(p) == joinpath(enc_root, name), pairs_)
        @test idx !== nothing
        @test first(pairs_[idx]) == "/enc/$encoded"
    end
end

@testset "spafiles serves an encoded asset instead of falling back to index.html" begin
    # The masking case, and the reason #121 is worse than a 404 under `spafiles`: the `/<prefix>/**`
    # history fallback answered the encoded asset URL with `index.html` and a 200, so the asset
    # silently resolved to the app shell.
    spa = mktempdir()
    write(joinpath(spa, "index.html"), "BODY:SHELL")
    ok = make_fixture(spa, "café.txt", "BODY:asset")
    @test ok          # legal everywhere; a skip here would be a silent no-op
    if ok
        resetstate()
        try
            spafiles(spa, "app")
            resp = internalrequest(HTTP.Request("GET", "/app/caf%C3%A9.txt"))
            @test resp.status == 200
            @test bodystr(resp) == "BODY:asset"
            # The fallback itself still works for a genuinely unmatched path.
            @test String(internalrequest(HTTP.Request("GET", "/app/no/such/route")).body) == "BODY:SHELL"
        finally
            resetstate()
        end
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

@testset "mountable_files returns joinpath(root, ...) verbatim" begin
    # `spafiles` identifies its index by comparing `joinpath(folder, "index.html")` against this
    # output (#102), so the un-normalized path is a contract, not an accident. A `realpath`,
    # `abspath` or `normpath` added to the enumerator would silently drop every SPA fallback --
    # the lookup misses, `spafiles` warns and registers nothing, and no assertion in this file
    # would fail. Pinned for every spelling of the root, because both sides must agree byte for byte.
    d = mktempdir()
    write(joinpath(d, "index.html"), "<h1>i</h1>")
    for folder in (d, d * "/", d * Base.Filesystem.path_separator)
        @test joinpath(folder, "index.html") ∈ MOUNTABLE(folder)
        @test joinpath(folder, "index.html") ∈ last.(MOUNTFOLDER(folder, "app", (_r, _p, _k) -> nothing))
    end
end

@testset "mountfolder reports the routes it registered" begin
    registered = Pair{String,String}[]
    mounted_pairs = MOUNTFOLDER(root, "assets", (route, path, _k) -> push!(registered, route => path))

    # The pair carries both halves (#102): the returned filepath must be exactly the one handed to
    # `addroute`, or `spafiles` cannot trust it to identify the index by file.
    @test mounted_pairs == registered
    @test eltype(mounted_pairs) == Pair{String,String}
    routes = first.(mounted_pairs)

    # An index.html contributes TWO pairs naming the SAME file -- its own route and the bare
    # directory route. That aliasing is precisely why a route *name* cannot identify a file, and it
    # is the property `spafiles` must not depend on.
    @test last(mounted_pairs[findfirst(p -> first(p) == "/assets/index.html", mounted_pairs)]) ==
          last(mounted_pairs[findfirst(p -> first(p) == "/assets", mounted_pairs)]) ==
          joinpath(root, "index.html")

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
    baseline = MOUNTFOLDER(root, "assets", (_r, _p, _k) -> nothing)
    for md in ("/assets", "assets/", "/assets/", "//assets//", " /assets/ ")
        @test MOUNTFOLDER(root, md, (_r, _p, _k) -> nothing) == baseline
    end

    # `""` used to throw a BoundsError at the entry point, while everything downstream already
    # treated it as "mount at the root".
    root_baseline = MOUNTFOLDER(root, "", (_r, _p, _k) -> nothing)
    for md in ("/", "   ", " / ")
        @test MOUNTFOLDER(root, md, (_r, _p, _k) -> nothing) == root_baseline
    end
    # The whole-vector `==` comparisons above hold unchanged on pairs, and get strictly stronger --
    # two spellings must now agree on the filepaths as well as the routes. Membership tests do NOT
    # survive: unwrap, or a String-vs-Pair comparison silently answers "not a member".
    @test "/visible.txt" ∈ first.(root_baseline)
    @test "/index.html" ∈ first.(root_baseline)

    # Routes are rebuilt by joining segments, so a doubled separator is unrepresentable. Interior
    # separators are still a real nested mount, not a spelling variant.
    for md in ("assets", "/assets/", "//assets//", "", "/", "a/b")
        for (route, filepath) in MOUNTFOLDER(root, md, (_r, _p, _k) -> nothing)
            @test !occursin("//", route)
            @test startswith(route, "/")
            # The filepath half is a real, servable file for every route -- including the bare
            # directory route, which reuses the index's path rather than naming a directory.
            @test isfile(filepath)
        end
    end
    @test "/a/b/visible.txt" ∈ mountroutes(root, "a/b", (_r, _p, _k) -> nothing)
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

    routes = mountroutes(nested, "assets", (_r, _p, _k) -> nothing)
    @test "/assets/index.html/index.html" ∈ routes
    @test "/assets/index.html" ∈ routes   # the bare path of the NESTED index
    @test "/assets" ∉ routes              # the hijack: this was the nested file's bare path
    @test "" ∉ routes

    # #102: identifying the index by ROUTE NAME resolves `/assets/index.html` to the NESTED file --
    # a real, readable file -- and would silently register a fallback where #94 deliberately refuses
    # one. Identifying it by FILE cannot: `<nested>/index.html` is a directory, and a directory is
    # never a `mountable_files` result. This pair of assertions is why `spafiles` matches on the
    # filepath half; the end-to-end consequence is pinned by the `@test_logs` block below.
    mounted_pairs = MOUNTFOLDER(nested, "assets", (_r, _p, _k) -> nothing)
    @test last(mounted_pairs[findfirst(p -> first(p) == "/assets/index.html", mounted_pairs)]) ==
          joinpath(nested, "index.html", "index.html")
    @test findfirst(p -> last(p) == joinpath(nested, "index.html"), mounted_pairs) === nothing

    # A root mount's bare directory route is spelled "/", not "".
    root_routes = mountroutes(nested, "", (_r, _p, _k) -> nothing)
    @test "/index.html/index.html" ∈ root_routes
    @test "/index.html" ∈ root_routes
    @test "/" ∉ root_routes               # nothing here is a *top-level* index.html
    @test "" ∉ root_routes

    # A genuine top-level index.html claims "/" rather than the empty string.
    @test "/" ∈ mountroutes(root, "", (_r, _p, _k) -> nothing)
    @test "" ∉ mountroutes(root, "", (_r, _p, _k) -> nothing)

    resetstate()
    try
        staticfiles(nested, "assets")
        r = internalrequest(HTTP.Request("GET", "/assets/index.html"))
        @test r.status == 200
        @test bodystr(r) == "<h1>nested</h1>"
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

    routes = mountroutes(tree, "assets", (_r, _p, _k) -> nothing)
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
            @test !occursin("TOP SECRET", bodystr(r))
        end
    finally
        resetstate()
    end
end

@testset "one prefix handler resolves the DECODED request against the enumeration (#221)" begin
    # A mount registers `/<prefix>/**` plus the bare route, and resolves the decoded remainder
    # against the table `mountable_files` produced. These are the properties that shape buys and
    # per-file registration could not have.
    resetstate()
    try
        staticfiles(root, "static")

        @testset "the mount registers a catch-all, not a route per file" begin
            # The route TABLE is unchanged -- still one pair per enumerated file, still encoded,
            # still no `**` in it (#102/#121). What changed is what is registered with the router.
            pairs_ = MOUNTFOLDER(root, "static", (_r, _p, _k) -> nothing)
            @test !isempty(pairs_)
            @test "/static/**" ∉ first.(pairs_)
            @test "/static/visible.txt" ∈ first.(pairs_)
        end

        @testset "traversal resolves to a key that does not exist, never to the filesystem" begin
            # `%2e%2e%2f` decodes to `../`, which is not a nameable segment and therefore not a
            # key. Nothing is `stat`ed; there is no `safe_join` to get wrong. This is the half
            # that is strictly stronger than the surveyed frameworks, which resolve against the
            # filesystem and must defend the join.
            for target in ("/static/%2e%2e%2fetc%2fpasswd",
                           "/static/..%2fetc",
                           "/static/../../etc/passwd",
                           "/static/%2e%2e/%2e%2e/etc",
                           "/static/sub%2Fnested.txt",   # encoded separator must not cross a level
                           "/static/sub%5Cnested.txt",   # ... nor a Windows one
                           "/static/%00visible.txt")
                r = internalrequest(HTTP.Request("GET", target))
                @test r.status == 404
                @test !occursin("TOP SECRET", bodystr(r))
                @test !occursin("hunter2", bodystr(r))
            end
            # The nested file IS reachable by its honest spelling -- otherwise the assertions
            # above would pass on a mount that simply serves nothing.
            @test internalrequest(HTTP.Request("GET", "/static/sub/nested.txt")).status == 200
        end

        @testset "a malformed escape is a 400, not a 500 or a silent 404" begin
            # Same boundary rule `Types.pathparams` applies to `{var}` routes (#70), and the same
            # answer Express's `send` gives. A silent 404 would be the wrong report: the request
            # is not naming a missing file, it is not a well-formed request target.
            for target in ("/static/%ZZ.txt", "/static/%.txt", "/static/visible%.txt")
                @test internalrequest(HTTP.Request("GET", target)).status == 400
            end
            # Invalid UTF-8 that `unescapeuri` accepts without throwing is refused too, rather
            # than being allowed to miss quietly against a `Dict` keyed by valid Strings.
            @test internalrequest(HTTP.Request("GET", "/static/%80.txt")).status == 400
        end

        @testset "the query string is not part of the key" begin
            r = internalrequest(HTTP.Request("GET", "/static/visible.txt?v=deadbeef&x=1"))
            @test r.status == 200
            @test bodystr(r) == "visible"
        end

        @testset "a miss still goes through the router's own not-found handler" begin
            # The `**` route MATCHES every unmatched path under the prefix, so the mount handler
            # -- not the router -- decides what a miss returns. It must defer rather than invent
            # a response, or an app that supplied `Service(router = Router(my404))` would find it
            # silently disabled underneath every mount.
            @test internalrequest(HTTP.Request("GET", "/static/nope.txt")).status == 404
            # ... and a path outside the mount is untouched by any of this.
            @test internalrequest(HTTP.Request("GET", "/elsewhere/nope.txt")).status == 404

            # Asserting `status == 404` alone is NOT the property: a hardcoded
            # `HTTP.Response(404)` in the mount handler satisfies it while silently disabling the
            # app's own handler. Give the router a custom 404 with a recognisable body and
            # require the mount's miss to carry it.
            custom = Nitro.Core.App(service = Nitro.Core.Service(
                router = HTTP.Router(_ -> HTTP.Response(404, "CUSTOM-NOT-FOUND"))))
            staticfiles(custom, root, "static")
            miss = internalrequest(custom, HTTP.Request("GET", "/static/nope.txt"))
            @test miss.status == 404
            @test bodystr(miss) == "CUSTOM-NOT-FOUND"
            # A hit is unaffected.
            @test bodystr(internalrequest(custom, HTTP.Request("GET", "/static/visible.txt"))) == "visible"
        end

        @testset "an application route still beats the mount at the same path" begin
            # Exact literal beats `**` in HTTP.jl's matcher (exact -> conditional -> wildcard ->
            # doublestar), which is what keeps a catch-all mount from swallowing app routes that
            # live under its prefix.
            urlpatterns("", [path("/static/api/ping", req -> Res.json(Dict("pong" => true)))])
            r = internalrequest(HTTP.Request("GET", "/static/api/ping"))
            @test r.status == 200
            @test occursin("pong", bodystr(r))
        end
    finally
        resetstate()
    end
end

@testset "mounts answer conditional GETs and ranges (#40)" begin
    resetstate()
    try
        staticfiles(root, "static"; cache_control = "public, max-age=60")

        r = internalrequest(HTTP.Request("GET", "/static/visible.txt"))
        etag, lastmod = HTTP.header(r, "ETag"), HTTP.header(r, "Last-Modified")
        @test r.status == 200
        @test bodystr(r) == "visible"
        @test !isempty(etag)
        @test !isempty(lastmod)
        @test HTTP.header(r, "Accept-Ranges") == "bytes"
        @test HTTP.header(r, "Cache-Control") == "public, max-age=60"

        fresh = internalrequest(HTTP.Request("GET", "/static/visible.txt", ["If-None-Match" => etag]))
        @test fresh.status == 304
        @test isempty(bodystr(fresh))

        @test internalrequest(HTTP.Request("GET", "/static/visible.txt",
                                           ["If-Modified-Since" => lastmod])).status == 304
        # A non-matching validator must still send the body, or "always 304" would satisfy the
        # assertions above.
        stale = internalrequest(HTTP.Request("GET", "/static/visible.txt",
                                             ["If-None-Match" => "\"nope\""]))
        @test stale.status == 200
        @test bodystr(stale) == "visible"

        part = internalrequest(HTTP.Request("GET", "/static/visible.txt", ["Range" => "bytes=0-2"]))
        @test part.status == 206
        @test bodystr(part) == "vis"
        @test internalrequest(HTTP.Request("GET", "/static/visible.txt",
                                           ["Range" => "bytes=900-"])).status == 416
    finally
        resetstate()
    end

    # No Cache-Control unless the mount asked for one: guessing a max-age on an app's behalf pins
    # clients to a stale asset with no way to recover.
    resetstate()
    try
        staticfiles(root, "static")
        @test HTTP.header(internalrequest(HTTP.Request("GET", "/static/visible.txt")),
                          "Cache-Control", "") == ""
    finally
        resetstate()
    end
end

@testset "the SPA fallback carries validators, like the file it serves" begin
    # The history fallback is an SPA server's hottest path. It used to re-`read` index.html per
    # request and emit no validators at all, so every deep link cost a full body (#40).
    spa = mktempdir()
    write(joinpath(spa, "index.html"), "SHELL")
    write(joinpath(spa, "app.js"), "APP")
    resetstate()
    try
        spafiles(spa, "app")
        deep = internalrequest(HTTP.Request("GET", "/app/some/client/route"))
        etag = HTTP.header(deep, "ETag")
        @test deep.status == 200
        @test bodystr(deep) == "SHELL"
        @test !isempty(etag)

        @test internalrequest(HTTP.Request("GET", "/app/other/route",
                                           ["If-None-Match" => etag])).status == 304
        # The fallback and the direct index route describe the same file, so they must agree on
        # its validator -- otherwise a client revalidating a deep link would refetch the shell.
        direct = internalrequest(HTTP.Request("GET", "/app/index.html"))
        @test HTTP.header(direct, "ETag") == etag
    finally
        resetstate()
    end
end

@testset "cache policy and streaming threshold (#41)" begin
    big_dir = mktempdir()
    write(joinpath(big_dir, "small.txt"), "small")
    # Comfortably over the threshold used below, and over one 64 KiB write chunk, so the
    # streaming loop actually iterates rather than completing in a single pass.
    big_bytes = rand(UInt8, 300_000)
    write(joinpath(big_dir, "big.bin"), big_bytes)

    @testset "policy validation rejects nonsense rather than silently defaulting" begin
        MP = Nitro.Core.MountPolicy
        @test_throws ArgumentError MP(:sometimes, 1024, 1024, :weak_stat)
        @test_throws ArgumentError MP(:eager, -1, 1024, :weak_stat)
        @test_throws ArgumentError MP(:eager, 1024, 0, :weak_stat)
        # The validating constructor must be INNER: an outer method with this signature would be
        # less specific than the compiler-generated one for `Int` arguments, which is exactly how
        # it is called, and every check above would be skipped.
        @test_throws ArgumentError MP(:eager, 1024, 1024, :nonsense)
        @test MP(:eager, 1024, 1024, :weak_stat) isa MP
        @test_throws ArgumentError staticfiles(big_dir, "x"; cache = :sometimes)
    end

    @testset "a file over the threshold is streamed, not held" begin
        resetstate()
        try
            staticfiles(big_dir, "big"; stream_threshold = 100_000)
            tbl = nothing   # reach the mount table only through behaviour, not internals

            r = internalrequest(HTTP.Request("GET", "/big/big.bin"))
            @test r.status == 200
            # The body is a streaming cursor, not a byte buffer -- that IS the observable
            # difference. Drain it the way the write path does.
            @test r.body isa HTTP.AbstractBody
            @test !(r.body isa HTTP.BytesBody)
            buf = UInt8[]
            chunk = Vector{UInt8}(undef, 64 * 1024)
            while !HTTP.body_closed(r.body)
                n = HTTP.body_read!(r.body, chunk)
                n == 0 && break
                append!(buf, @view(chunk[1:n]))
            end
            @test buf == big_bytes
            @test HTTP.header(r, "Content-Length") == string(length(big_bytes))

            # A small file under the same mount is still buffered.
            s = internalrequest(HTTP.Request("GET", "/big/small.txt"))
            @test s.status == 200
            @test !(s.body isa HTTP.AbstractBody) || s.body isa HTTP.BytesBody
            @test bodystr(s) == "small"

            # A streamed file still answers conditional GETs -- the 304 path carries no body at
            # all, which is where a leaked handle would otherwise accumulate fastest.
            etag = HTTP.header(r, "ETag")
            @test !isempty(etag)
            for _ in 1:5
                @test internalrequest(HTTP.Request("GET", "/big/big.bin",
                                                   ["If-None-Match" => etag])).status == 304
            end
        finally
            resetstate()
        end
    end

    @testset "stream_threshold = 0 disables streaming entirely" begin
        resetstate()
        try
            staticfiles(big_dir, "big"; stream_threshold = 0)
            r = internalrequest(HTTP.Request("GET", "/big/big.bin"))
            @test r.status == 200
            @test !(r.body isa HTTP.AbstractBody) || r.body isa HTTP.BytesBody
        finally
            resetstate()
        end
    end

    @testset ":lazy actually caches, and the byte budget actually evicts" begin
        # A `loadfile` counter is what makes this DISCRIMINATING: asserting only that the right
        # bytes come back passes identically if `:lazy` silently degrades to `:none` (re-read
        # every time) or to `:eager` (read everything at mount). Counting reads separates all
        # three.
        reads = Dict{String,Int}()
        counting_loadfile = p -> (reads[basename(p)] = get(reads, basename(p), 0) + 1; read(p))

        resetstate()
        try
            staticfiles(big_dir, "big"; cache = :lazy, stream_threshold = 0,
                        cache_max_bytes = 128 * 1024, loadfile = counting_loadfile)
            # Nothing is read at mount time -- that is what makes it lazy rather than eager.
            @test isempty(reads)

            for _ in 1:3
                @test bodystr(internalrequest(HTTP.Request("GET", "/big/small.txt"))) == "small"
            end
            # Read ONCE across three hits: the cache is real.
            @test reads["small.txt"] == 1

            # big.bin is 300 KB against a 128 KB budget. LRUCache does NOT evict to make room for
            # an entry larger than `maxsize` -- it declines to store it and leaves the cache
            # intact -- so this is the "oversized entry cannot wedge the cache" case: it is
            # served correctly, re-read every time, and small.txt keeps its slot.
            for _ in 1:2
                r = internalrequest(HTTP.Request("GET", "/big/big.bin"))
                @test r.status == 200
                @test length(r.body) == length(big_bytes)
            end
            @test reads["big.bin"] == 2          # never cached, so re-read each time
            @test reads["small.txt"] == 1        # ... and it did not displace small.txt

            # Eviction proper needs entries that each FIT but together do not -- next block.
        finally
            resetstate()
        end

        reads2 = Dict{String,Int}()
        # The `* 4` is load-bearing, not decoration: it makes the BODY a different size from the
        # FILE. A weak tag built from `stat` rather than from the cached bytes is identical to a
        # correct one whenever those two agree -- which they do for a plain `read` -- so without
        # a size-changing `loadfile` the drift this block exists to catch is unobservable.
        counting2 = p -> (reads2[basename(p)] = get(reads2, basename(p), 0) + 1;
                          vcat(read(p), Vector{UInt8}("XXXX")))
        evict_dir = mktempdir()
        write(joinpath(evict_dir, "a.bin"), rand(UInt8, 50_000))
        write(joinpath(evict_dir, "b.bin"), rand(UInt8, 50_000))
        resetstate()
        try
            staticfiles(evict_dir, "ev"; cache = :lazy, stream_threshold = 0,
                        cache_max_bytes = 80_000, loadfile = counting2)
            internalrequest(HTTP.Request("GET", "/ev/a.bin"))
            internalrequest(HTTP.Request("GET", "/ev/a.bin"))
            @test reads2["a.bin"] == 1                  # cached

            tag_a = HTTP.header(internalrequest(HTTP.Request("GET", "/ev/a.bin")), "ETag")

            internalrequest(HTTP.Request("GET", "/ev/b.bin"))   # 100 KB > 80 KB budget
            # a.bin was evicted to make room for b.bin. Change it on disk BEFORE the re-read, so
            # the re-read produces different bytes than the first one did. This is the exact
            # scenario `CachedBody` exists for: a tag derived from a `stat` rather than from the
            # cached bytes survives every other assertion here and fails only this one.
            sleep(1.1)
            write(joinpath(evict_dir, "a.bin"), rand(UInt8, 70_000))

            r_a = internalrequest(HTTP.Request("GET", "/ev/a.bin"))
            # It had to be read again -- a COUNT-based bound of two entries would have kept both
            # and left this at 1, which is what distinguishes a byte budget from an entry count.
            @test reads2["a.bin"] == 2
            @test reads2["b.bin"] == 1
            @test length(r_a.body) == 70_004          # 70 000 on disk + the loadfile's 4 bytes
            # The tag describes the BODY in hand -- not the one cached before, and not the file on
            # disk. `70004` vs `70000` is what separates a tag built from the cached bytes from one
            # built from a `stat`; they are indistinguishable whenever the two sizes agree.
            @test HTTP.header(r_a, "ETag") != tag_a
            @test occursin("70004", HTTP.header(r_a, "ETag"))
            @test !occursin("70000-", HTTP.header(r_a, "ETag"))
            # ... and the pre-eviction tag no longer short-circuits, while the current one does.
            @test internalrequest(HTTP.Request("GET", "/ev/a.bin",
                                               ["If-None-Match" => tag_a])).status == 200
            @test internalrequest(HTTP.Request("GET", "/ev/a.bin",
                                   ["If-None-Match" => HTTP.header(r_a, "ETag")])).status == 304
        finally
            resetstate()
        end
    end

    @testset "validators describe the bytes actually sent, not the mount-time snapshot" begin
        # The regression this guards is severe and silent: with the tag frozen at mount time, a
        # re-reading mount served changed content under the OLD ETag and then answered 304 to a
        # client holding it -- pinning that client to content the server no longer has. It
        # defeats the single property `dynamicfiles` exists for.
        # `:none` re-reads content, so BOTH the body and the validator must track the disk.
        d = mktempdir(); f = joinpath(d, "page.txt"); write(f, "first")
        resetstate()
        try
            staticfiles(d, "m"; cache = :none, stream_threshold = 0)
            r1 = internalrequest(HTTP.Request("GET", "/m/page.txt"))
            tag1 = HTTP.header(r1, "ETag")
            @test bodystr(r1) == "first"
            @test !isempty(tag1)

            sleep(1.1)                                       # mtime granularity
            write(f, "second-much-longer-content")
            r2 = internalrequest(HTTP.Request("GET", "/m/page.txt"))
            @test bodystr(r2) == "second-much-longer-content"
            # The tag MOVED with the content. Without this, the assertion below is the bug.
            @test HTTP.header(r2, "ETag") != tag1
            # The stale validator no longer short-circuits -- this is the regression that would
            # otherwise pin a client to content the server no longer has.
            @test internalrequest(HTTP.Request("GET", "/m/page.txt",
                                               ["If-None-Match" => tag1])).status == 200
            # ... while the CURRENT tag still does, or conditional GET would be broken outright.
            @test internalrequest(HTTP.Request("GET", "/m/page.txt",
                                   ["If-None-Match" => HTTP.header(r2, "ETag")])).status == 304
        finally
            resetstate()
        end

        # `:eager` and `:lazy` both serve a SNAPSHOT -- eager from mount time, lazy from first
        # request -- so neither is expected to notice a disk change while it holds the bytes.
        # The property that matters for them is SELF-CONSISTENCY: the tag must describe the body
        # being sent. Before the fix, a `:lazy` mount's tag came from a `stat` taken at mount
        # time with no bytes in hand, so after an eviction re-read the two could disagree.
        for policy in (:eager, :lazy)
            d2 = mktempdir(); f2 = joinpath(d2, "page.txt"); write(f2, "first")
            resetstate()
            try
                staticfiles(d2, "e"; cache = policy, stream_threshold = 0)
                r0 = internalrequest(HTTP.Request("GET", "/e/page.txt"))
                tag = HTTP.header(r0, "ETag")
                @test bodystr(r0) == "first"

                sleep(1.1); write(f2, "changed on disk")
                r = internalrequest(HTTP.Request("GET", "/e/page.txt"))
                @test bodystr(r) == "first"                  # snapshot, by design
                @test HTTP.header(r, "ETag") == tag          # ... and the tag agrees with it
                # The tag it emits is the one that revalidates. A tag describing the file on
                # disk rather than the body in hand would fail here.
                @test internalrequest(HTTP.Request("GET", "/e/page.txt",
                                       ["If-None-Match" => tag])).status == 304
            finally
                resetstate()
            end
        end
    end

    @testset "a strong ETag hashes the bytes served, under every cache policy" begin
        # `loadfile` decides the body, so hashing the file on disk would identify a
        # representation that was never sent -- and a strong tag is exactly what `If-Match` and
        # `If-Range` rely on to splice a resumed download correctly.
        d = mktempdir(); write(joinpath(d, "a.txt"), "RAW")
        want = "\"" * bytes2hex(SHA.sha256("TRANSFORMED")) * "\""
        raw  = "\"" * bytes2hex(SHA.sha256("RAW")) * "\""
        @test want != raw
        for policy in (:eager, :lazy, :none)
            resetstate()
            try
                staticfiles(d, "s"; cache = policy, etag = :strong,
                            loadfile = _ -> "TRANSFORMED")
                r = internalrequest(HTTP.Request("GET", "/s/a.txt"))
                @test bodystr(r) == "TRANSFORMED"
                @test HTTP.header(r, "ETag") == want
                @test HTTP.header(r, "ETag") != raw
            finally
                resetstate()
            end
        end
    end

    @testset ":none re-reads content, like dynamicfiles" begin
        d = mktempdir()
        f = joinpath(d, "changing.txt")
        write(f, "first")
        resetstate()
        try
            staticfiles(d, "s"; cache = :none)
            @test bodystr(internalrequest(HTTP.Request("GET", "/s/changing.txt"))) == "first"
            write(f, "second")
            @test bodystr(internalrequest(HTTP.Request("GET", "/s/changing.txt"))) == "second"
            # :eager is the opposite, and still the default -- the mount serves its snapshot.
            resetstate()
            staticfiles(d, "e")
            write(f, "third")
            @test bodystr(internalrequest(HTTP.Request("GET", "/e/changing.txt"))) == "second"
        finally
            resetstate()
        end
    end
end

@testset "a skipped symlinked directory is named, not folded into a count (#95)" begin
    # `walkdir(follow_symlinks=false)` reports every link as a FILE, so a link pointing at a
    # directory fails the regular-file check and its whole subtree silently disappears.
    # `dist/assets -> ../shared/assets` is an ordinary deploy layout, so this is not exotic.
    if has_inside_dir
        logs = Test.collect_test_logs() do
            MOUNTABLE(root)
        end
        msgs = [string(r.message) for r in logs[1]]
        named = filter(m -> occursin("skipping a symlinked directory", m), msgs)
        @test !isempty(named)
        # The point of the change: the offending directory is identified. A count cannot be
        # acted on; a name can.
        linkdir_records = [r for r in logs[1] if occursin("skipping a symlinked directory", string(r.message))]
        reported = reduce(vcat, [collect(keys(r.kwargs)) for r in linkdir_records]; init = Symbol[])
        @test :path in reported
        paths = [string(r.kwargs[:path]) for r in linkdir_records]
        has_inside_dir && @test "sub_link" in paths
        # Only the mount-relative path, never an absolute or resolved one -- a link may point
        # at something whose name is itself sensitive. `isabspath` is the discriminating check;
        # comparing against `outside` would be trivially true for a relative name.
        @test all(p -> !isabspath(p), paths)
        # The workaround has to be in the message, or naming the directory just relocates the
        # puzzle.
        @test any(m -> occursin("Mount it separately", m), named)

        # The summary line still carries the class, so the two agree.
        summary = filter(m -> occursin("will not be served", m), msgs)
        @test !isempty(summary)
        summary_rec = first(r for r in logs[1] if occursin("will not be served", string(r.message)))
        @test haskey(summary_rec.kwargs, :symlinked_directory)
        @test summary_rec.kwargs[:symlinked_directory] >= 1
    end

    # Traversal itself stays refused -- this issue was closed by naming the case, not by
    # following it (docs/design/static-serving-boundary.md §7).
    if has_inside_dir
        files = servable(root)
        @test "sub_link" ∉ files                 # the link itself is not served ...
        @test "sub_link/nested.txt" ∉ files      # ... and neither is anything under it
        @test "sub/nested.txt" ∈ files           # while the real directory still is
    end
end

@testset "a mount does not claim a request it cannot serve" begin
    # The catch-all matches a path for EVERY method, so the handler -- not the router -- decides.
    # Registering `GET` alone made HTTP.jl answer 405 for every other method under the prefix, and
    # at a root mount that covered the whole application.
    #
    # No comparable framework claims such a request: `serve-static` calls `next()` by default,
    # `Plug.Static` returns the conn unchanged, Go's `FileServer` ignores the method entirely.
    resetstate()
    try
        staticfiles(root, "static")
        urlpatterns("", [path("/static/api/ping", req -> Res.json(Dict("ok" => true)), method = "POST")])

        @test internalrequest(HTTP.Request("GET",  "/static/visible.txt")).status == 200
        # A path naming a real file answers 405 WITH `Allow` -- more informative than falling
        # through to a 404, which is what Express does by default even for a file that exists.
        mna = internalrequest(HTTP.Request("POST", "/static/visible.txt"))
        @test mna.status == 405
        @test HTTP.header(mna, "Allow") == "GET, HEAD"
        # A path naming NOTHING defers to the app's not-found handler, whatever the method. This
        # is the assertion that fails if the catch-all goes back to being GET-only.
        @test internalrequest(HTTP.Request("POST",   "/static/nope.txt")).status == 404
        @test internalrequest(HTTP.Request("PUT",    "/static/nope.txt")).status == 404
        @test internalrequest(HTTP.Request("DELETE", "/static/nope.txt")).status == 404
        # An application route under the prefix still wins, on its own method.
        @test internalrequest(HTTP.Request("POST", "/static/api/ping")).status == 200

        # HEAD is served, and keeps its Content-Length. `servecontent` sets the header explicitly,
        # which is why this does not hit #146 (where builders that omit it lose it on HEAD).
        head = internalrequest(HTTP.Request("HEAD", "/static/visible.txt"))
        @test head.status == 200
        @test HTTP.header(head, "Content-Length") == string(sizeof("visible"))
    finally
        resetstate()
    end

    @testset "a ROOT mount does not turn every unrouted non-GET into a 405" begin
        # The severe case: with `staticfiles(dir, "")` the catch-all is `/**`, so a GET-only
        # registration made `POST /api/anything` a 405 across the whole application.
        resetstate()
        try
            staticfiles(root, "")
            urlpatterns("", [path("/api/thing", req -> Res.json(Dict("ok" => true)), method = "POST")])
            for m in ("POST", "PUT", "DELETE", "PATCH")
                @test internalrequest(HTTP.Request(m, "/api/unrouted")).status == 404
            end
            @test internalrequest(HTTP.Request("POST", "/api/thing")).status == 200
            @test internalrequest(HTTP.Request("GET",  "/visible.txt")).status == 200
            @test internalrequest(HTTP.Request("POST", "/visible.txt")).status == 405
        finally
            resetstate()
        end
    end

    @testset "spafiles does not hand the app shell to a non-navigation" begin
        spa = mktempdir()
        write(joinpath(spa, "index.html"), "SHELL")
        write(joinpath(spa, "app.js"), "APP")
        resetstate()
        try
            spafiles(spa, "app")
            # A navigation gets the shell ...
            @test bodystr(internalrequest(HTTP.Request("GET", "/app/users/1"))) == "SHELL"
            # ... a POST to the same client route does not. Answering it with HTML and a 200
            # would tell a form post that it succeeded.
            @test internalrequest(HTTP.Request("POST", "/app/users/1")).status == 404
            @test internalrequest(HTTP.Request("POST", "/app/app.js")).status == 405
        finally
            resetstate()
        end
    end
end

@testset "a streamed body is released even when it is never written (#41)" begin
    # `_write_response_body!` closes what it drains, but a 304, a HEAD, or a response a middleware
    # discards never reaches it. Those are the CHEAP requests a warm client makes constantly, so a
    # leak there accumulates fastest. `stream_handler`'s `finally` is the net -- the same place Go
    # (`defer f.Close()`) and Express (`onFinished(res, cleanup)`) put it.
    #
    # On Windows an open handle blocks deletion, which is what makes this observable without
    # counting descriptors.
    d = mktempdir()
    big = joinpath(d, "big.bin")
    write(big, rand(UInt8, 300_000))

    release = Nitro.Core._release_response_body!

    @testset "buffered bodies are NOT closed -- that would break shared responses" begin
        # Load-bearing exclusion: `body_close!` on a `BytesBody` sets `closed`, and HTTP 2.7's
        # pre-send check then answers 500 the next time a shared response is sent.
        bb = HTTP.BytesBody(Vector{UInt8}("shared"))
        release(bb)
        @test !HTTP.body_closed(bb)
        @test HTTP._check_response_body_unsent(HTTP.Response(200, bb)) === nothing
        release(HTTP.EmptyBody())            # must not throw
        release(Vector{UInt8}("plain"))      # nor for a raw body
        release("a string")
    end

    @testset "a streaming body IS closed, and its handle released" begin
        io = open(big, "r")
        resp = HTTP.servecontent(HTTP.Request("GET", "/x"), io; name = "big.bin")
        Nitro.Res.adopt_stream_io!(resp, io)
        @test isopen(io)
        release(resp.body)                   # what `stream_handler`'s `finally` does
        @test HTTP.body_closed(resp.body)
        @test !isopen(io)
        # Idempotent: the write path usually closes first, and the net runs anyway.
        release(resp.body)
        @test !isopen(io)
    end

    @testset "a mounted streamed file leaves nothing open after a 304" begin
        resetstate()
        try
            staticfiles(d, "big"; stream_threshold = 100_000)
            first = internalrequest(HTTP.Request("GET", "/big/big.bin"))
            etag  = HTTP.header(first, "ETag")
            HTTP.body_close!(first.body)     # `internalrequest` never reaches the write path
            # A 304 carries no body at all, so nothing would ever drain it.
            for _ in 1:20
                r = internalrequest(HTTP.Request("GET", "/big/big.bin", ["If-None-Match" => etag]))
                @test r.status == 304
            end
            # If any of those 20 held a handle, Windows would refuse this.
            GC.gc()
            @test (rm(big); true)
        finally
            resetstate()
        end
    end
end

@testset "include_hidden=true is a real opt-in" begin
    resetstate()
    try
        staticfiles(root, "static"; include_hidden=true)
        r = internalrequest(HTTP.Request("GET", "/static/.env"))
        @test r.status == 200
        @test occursin("hunter2", bodystr(r))
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
        @test bodystr(r) == "first"

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
            @test !occursin("TOP SECRET", bodystr(r))
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
        @test occursin("spa", bodystr(r))
    finally
        resetstate()
    end
end

end
