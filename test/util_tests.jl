@testitem "Util" tags=[:core] setup=[NitroCommon] begin
using Test
using UUIDs
using Nitro.Core.Util
using Nitro.Core.Util: mount_segments, mount_route, _route_encode, mount_remainder
using Nitro.Core: serverwelcome
using Nitro: ValidationError
import Nitro                          # for `pkgversion(Nitro)` below
using Nitro.Core.Errors: cause_report   # unexported on purpose — see src/errors.jl

@testset "join_url_path" begin
    # prefix == nothing returns route verbatim (current implementation)
    @test join_url_path(nothing, "/users") == "/users"
    @test join_url_path(nothing, "users") == "users"
    @test join_url_path(nothing, "/") == "/"

    # prefix without trailing slash, route with leading slash
    @test join_url_path("/api", "/users") == "/api/users"
    @test join_url_path("/api", "/users/") == "/api/users/"

    # prefix with trailing slash, route without leading slash
    @test join_url_path("/api/", "users") == "/api/users"
    @test join_url_path("api/", "users") == "api/users"   # preserves prefix exactly as implemented

    # mixed variations - ensure no duplicate slashes and trailing slash preserved
    @test join_url_path("/api/", "/users") == "/api/users"
    @test join_url_path("/api/", "/users/") == "/api/users/"

    # empty route
    @test join_url_path("/api", "") == "/api"
    @test join_url_path("", "/") == "/"
end

@testset "join_url_path additional edge cases" begin
    # empty route cases
    @test join_url_path(nothing, "") == ""            # current implementation returns route verbatim
    @test join_url_path("", "") == ""                # prefix "" produces root

    # multiple leading slashes in route should be normalized by lstrip
    @test join_url_path("/api", "///users") == "/api/users"

    # route with query string preserved
    @test join_url_path("/api", "/users/?q=1") == "/api/users/?q=1"
    @test join_url_path(nothing, "/users/?q=1") == "/users/?q=1"

    # prefix == "/" behaves as expected
    @test join_url_path("/", "/users") == "/users"
    @test join_url_path("/", "/") == "/"

    # prefix made only of slashes (demonstrates current behavior)
    @test join_url_path("///", "/users") == "///users"

    @test join_url_path("http://localhost:8080", "/users") == "http://localhost:8080/users"
    @test join_url_path("http://localhost:8080/", "users") == "http://localhost:8080/users"
    @test join_url_path("http://localhost:8080", "") == "http://localhost:8080"
    @test join_url_path("http://localhost:8080/api", "/users") == "http://localhost:8080/api/users"

    # additional fake HTTPS domains (no port)
    @test join_url_path("https://example.com", "/users") == "https://example.com/users"
    @test join_url_path("https://example.com/", "users") == "https://example.com/users"
    @test join_url_path("https://example.com", "") == "https://example.com"
    @test join_url_path("https://api.example.com", "/v1/items") == "https://api.example.com/v1/items"
    @test join_url_path("https://service.local", "/") == "https://service.local/"
end

@testset "join_url_path exhaustive edge cases" begin
    # prefix variations (leading/trailing slash differences)
    @test join_url_path("api", "/users") == "api/users"
    @test join_url_path("/api", "users") == "/api/users"
    @test join_url_path("", "users") == "/users"
    @test join_url_path("/", "users") == "/users"
    @test join_url_path("/", "/") == "/"

    # route consisting only of slashes -> treat as root of prefix
    @test join_url_path("/api", "///") == "/api/"

    # query string and fragment must be preserved
    @test join_url_path("/api", "/users/?q=1#frag") == "/api/users/?q=1#frag"
    @test join_url_path(nothing, "/users/?q=1#frag") == "/users/?q=1#frag"

    # percent-encoding and unicode preserved
    @test join_url_path("/путь", "/пользователь") == "/путь/пользователь"
    @test join_url_path("/api", "/file%20name.txt") == "/api/file%20name.txt"

    # backslashes in route are unchanged (function should not convert separators)
    @test join_url_path("/api", "\\windows\\path") == "/api/\\windows\\path"

    # very long inputs (performance / correctness for large strings)
    longp = "/" * repeat("a", 1000)
    longr = "/" * repeat("b", 1000)
    @test join_url_path(longp, longr) == "/" * repeat("a", 1000) * "/" * repeat("b", 1000)
end

@testset "parseparam unions" begin
    # A union member that legitimately accepts anything still wins — the raw string is a
    # parsed `String`, not the old unparsed fallback.
    @test parseparam(Union{Bool, String}, "asdfasd") == "asdfasd"
    @test parseparam(Union{Bool, String}, "true") === true

    # No member parses -> a ValidationError (400), not the raw String spliced into a
    # handler that declared a different type.
    @test_throws ValidationError parseparam(Union{Int, UUID}, "notanumber")

    # `Nothing` is never a parse target: `JSON.parse(str, Nothing)` succeeds for any valid
    # JSON document and `Base.uniontypes` puts `Nothing` first, so trying it silently
    # discarded the client's value.
    @test Base.uniontypes(Union{Nothing, Int})[1] === Nothing   # guards the premise
    @test parseparam(Union{Nothing, Int}, "5") === 5
    @test parseparam(Union{Nothing, String}, "5") == "5"
    @test_throws ValidationError parseparam(Union{Nothing, Int}, "abc")

    # `Missing` has exactly the same shape -- JSON.parse(str, Missing) also succeeds for
    # any valid JSON document -- so it is skipped too.
    @test Base.uniontypes(Union{Missing, Int})[1] === Missing   # guards the premise
    @test parseparam(Union{Missing, Int}, "5") === 5
    @test_throws ValidationError parseparam(Union{Missing, Int}, "abc")

    # A literal "null" is no longer absorbed by the skipped `Nothing` member: it is a value
    # the declared type cannot represent, so it is rejected rather than silently bound.
    @test_throws ValidationError parseparam(Union{Nothing, Int}, "null")

    # `parseparam` NEVER percent-decodes -- not in the union method, not in the member it
    # delegates to. Decoding happens once upstream in the `Types.*` accessor (#70), so a value
    # arriving here is already decoded and must pass through byte-identical.
    @test parseparam(Union{Int, String}, "a%20b") == "a%20b"
    @test parseparam(Union{Int, String}, "a%2520b") == "a%2520b"
end

@testset "parseparam does not percent-decode (#70)" begin
    # The `escape` keyword is gone: a converter is the wrong place to decide how its input was
    # transported. These pin the whole family, so reintroducing a decode in any single method
    # fails here rather than silently mangling one parameter source.
    @test parseparam(String, "a%2Bb")   == "a%2Bb"
    @test parseparam(Any,    "100%25")  == "100%25"
    @test parseparam(Symbol, "a%20b")   === Symbol("a%20b")
    @test parseparam(Char,   "%41")     === '%'          # NOT 'A'
    @test parseparam(Regex,  "a%2Bb")   == r"a%2Bb"

    # The keyword itself must be gone, not merely defaulted to false -- otherwise a call site
    # could opt back into the double decode.
    @test_throws MethodError parseparam(String, "a%20b"; escape=true)
end

@testset "parseparam_checked" begin
    @test parseparam_checked(Int, "42", "id", :path) === 42
    @test parseparam_checked(Float64, "3.5", "ratio", :query) === 3.5

    # Every parse failure becomes a ValidationError (400), including the ones that are not
    # `ArgumentError`: `first("")` is a BoundsError, an out-of-range Enum is an ArgumentError.
    @test_throws ValidationError parseparam_checked(Int, "abc", "id", :path)
    @test_throws ValidationError parseparam_checked(Char, "", "c", :query)
    @test_throws ValidationError parseparam_checked(Int, "99999999999999999999", "id", :path)

    # The message names the parameter but never echoes the submitted value: `.msg` is
    # app-reachable (showerror, an app-level `catch ValidationError`), and a parameter
    # value can be a token.
    err = try
        parseparam_checked(Int, "s3cr3t", "limit", :query)
        nothing
    catch e
        e
    end
    @test err isa ValidationError
    @test occursin("limit", err.msg)
    @test occursin("query", err.msg)
    @test !occursin("s3cr3t", err.msg)

    # #130: the parse failure IS attached as `.cause` and DOES quote the value — JSON.jl
    # renders it with a caret pointing at the offending byte. Neither rendered form may
    # show it. Both halves asserted: the positive one is what keeps the negatives from
    # passing for the wrong reason.
    @test err.cause isa Exception
    @test occursin("s3cr3t", sprint(showerror, err.cause))
    @test !occursin("s3cr3t", sprint(showerror, err))
    @test !occursin("Caused by", sprint(showerror, err))
    @test !occursin("s3cr3t", sprint(show, err))
    @test occursin("s3cr3t", cause_report(err))   # ...but the opt-in still reaches it

    # A ValidationError raised inside parseparam passes through unwrapped.
    capped = try
        parseparam_checked(Regex, repeat("x", 300), "pat", :path)
        nothing
    catch e
        e
    end
    @test capped isa ValidationError
    @test isnothing(capped.cause)
    @test occursin("maximum length", capped.msg)
end

# #130: the type-level contract, independent of any extractor. Four sites attach a `.cause`
# (`safe_extract`, `parseparam_checked`, and both `Types.*` decode accessors) and every one of
# them wraps CLIENT input, so the rule belongs to the type rather than to each site.
@testset "ValidationError renders no cause by default (#130)" begin
    plain = ValidationError("bad param 'limit'")
    wrap  = ValidationError("bad param 'limit'", ArgumentError("SENTINEL-VALUE"))

    # No cause: every form agrees, and `show` still round-trips as a constructor call.
    @test sprint(showerror, plain) == "Validation Error: bad param 'limit'"
    @test sprint(io -> showerror(io, plain; cause = true)) == sprint(showerror, plain)
    @test cause_report(plain) == sprint(showerror, plain)
    @test sprint(show, plain) == "ValidationError(\"bad param 'limit'\")"

    # With a cause: the default is value-free, the opt-in renders it.
    @test !occursin("SENTINEL-VALUE", sprint(showerror, wrap))
    @test !occursin("Caused by", sprint(showerror, wrap))
    @test occursin("bad param 'limit'", sprint(showerror, wrap))
    @test occursin("SENTINEL-VALUE", sprint(io -> showerror(io, wrap; cause = true)))
    @test cause_report(wrap) == sprint(io -> showerror(io, wrap; cause = true))

    # `show` is a SECOND render path, not a restatement of the first. A logger that treats
    # `exception=` as an ordinary value reaches `show`, and the default struct `show` prints
    # every field — so masking `showerror` alone would have left the likeliest leak open.
    # The cause's TYPE survives (it carries no input); its message does not.
    @test !occursin("SENTINEL-VALUE", sprint(show, wrap))
    @test occursin("ArgumentError", sprint(show, wrap))
    @test !occursin("SENTINEL-VALUE", repr(wrap))
    @test !occursin("SENTINEL-VALUE", repr("text/plain", wrap))

    # Base's OWN paths — what an uncaught rejection and `@error … exception=err` go through.
    # If the 2-arg method did not cover these the fix would be skin-deep.
    bt = try throw(wrap) catch; catch_backtrace() end
    @test !occursin("SENTINEL-VALUE", sprint(io -> showerror(io, wrap, bt; backtrace = false)))
    @test !occursin("SENTINEL-VALUE", sprint(io -> Base.display_error(io, wrap, bt)))

    # Both stdlib loggers, both `exception=` spellings. `SimpleLogger` renders the value with
    # `show`; `ConsoleLogger` special-cases exceptions and renders with `showerror`. The two
    # take genuinely different paths, which is why both are pinned.
    for L in (Base.CoreLogging.SimpleLogger, Base.CoreLogging.ConsoleLogger)
        for ex in (wrap, (wrap, bt))
            buf = IOBuffer()
            Base.CoreLogging.with_logger(L(buf, Base.CoreLogging.Debug)) do
                @error "rejected" exception = ex
            end
            @test !occursin("SENTINEL-VALUE", String(take!(buf)))
        end
    end

    # A nested chain renders whole under the opt-in — no silent truncation. Nothing in `src/`
    # nests a ValidationError today, but an application can.
    nested = ValidationError("outer", ValidationError("inner", ArgumentError("SENTINEL-VALUE")))
    @test !occursin("SENTINEL-VALUE", sprint(showerror, nested))
    @test occursin("inner", cause_report(nested))
    @test occursin("SENTINEL-VALUE", cause_report(nested))

    # Siblings are msg-only, have no wrap site, and are deliberately unchanged: a `cause`
    # kwarg they would ignore is dead API implying a capability the type does not have.
    @test sprint(showerror, Nitro.Core.Errors.CookieError("nope")) == "Cookie Error: nope"
    @test sprint(showerror, Nitro.Core.Errors.AuthorizationError("nope")) ==
          "Authorization Error: nope"
end

# ADJUDICATED (#55). This testset previously asserted `!occursin("Environment:", ...)` when
# `NITRO_ENV` was unset -- an expectation written against the world where the variable was
# COSMETIC and the environment was therefore sometimes unknown. #55 makes it functional, so
# there is always a resolved environment and the banner always names it. Keeping the old
# assertion would mean a production box that forgot `NITRO_ENV` prints nothing while silently
# running as `dev`, which is the exact failure the issue exists to prevent. The expectation
# moved deliberately; it was not stale-by-accident.
#
# Both blocks now pin `GENIE_ENV` too: it is a real fallback now, so a block that only pins
# `NITRO_ENV` passes in CI and fails on any machine that exports `GENIE_ENV`.
@testset "serverwelcome banner always names the resolved environment" begin
    output = mktemp() do path, io
        redirect_stdout(io) do
            withenv("NITRO_ENV" => "dev", "GENIE_ENV" => nothing) do
                serverwelcome("http://127.0.0.1:8080", nothing, false)
            end
        end
        flush(io)
        read(path, String)
    end

    @test occursin("Environment: dev", output)
    @test occursin("Starting server at http://127.0.0.1:8080", output)

    output_env_unset = mktemp() do path, io
        redirect_stdout(io) do
            withenv("NITRO_ENV" => nothing, "GENIE_ENV" => nothing) do
                serverwelcome("http://127.0.0.1:8080", "/api", true)
            end
        end
        flush(io)
        read(path, String)
    end

    @test occursin("Environment: dev", output_env_unset)   # the DEFAULT is announced too
    @test occursin("Global prefix: /api", output_env_unset)
    @test occursin("parallel mode:", output_env_unset)

    # A non-default value is reported as itself, and the GENIE_ENV fallback reaches the banner.
    output_prod = mktemp() do path, io
        redirect_stdout(io) do
            withenv("NITRO_ENV" => nothing, "GENIE_ENV" => "prod") do
                serverwelcome("http://127.0.0.1:8080", nothing, false)
            end
        end
        flush(io)
        read(path, String)
    end
    @test occursin("Environment: prod", output_prod)
end

# The banner used to print a hardcoded `Nitro 1.10.0` -- an Oxygen.jl-era literal that never
# matched this package (#240). It is the only place in the repo that claims a version at
# runtime, so a wrong one there is worse than none: it is what an operator reads during an
# incident. Derived from `pkgversion` now, and asserted against the same source, so a release
# cut never has to remember this line.
@testset "serverwelcome banner reports the package version" begin
    output = mktemp() do path, io
        redirect_stdout(io) do
            # Pin BOTH, per the block above: `serverwelcome` resolves the environment, and a
            # block pinning only `NITRO_ENV` fails on any machine that exports `GENIE_ENV`.
            withenv("NITRO_ENV" => "dev", "GENIE_ENV" => nothing) do
                serverwelcome("http://127.0.0.1:8080", nothing, false)
            end
        end
        flush(io)
        read(path, String)
    end

    @test occursin(" Nitro $(pkgversion(Nitro)) ", output)
    # Guards the regression directly: a re-hardcode of the fork-era literal fails here even if
    # someone also bumps `Project.toml` to match it.
    @test !occursin("1.10.0", output)
end

@testset "mount_segments canonicalization" begin
    # The SINGLE normalization point for `mountdir` (#93). staticfiles/spafiles/dynamicfiles no
    # longer strip anything themselves, so `mountfolder` and `spafiles`' history-mode fallback both
    # derive their routes from the raw value through this one function and cannot drift apart.
    for md in ("", "/", "//", "   ", "\t\n", " / ", "/ ", "/ / ")
        @test mount_segments(md) == String[]
    end

    for md in ("static", "/static", "static/", "/static/", "//static//", " static ", " / static / ")
        @test mount_segments(md) == ["static"]
    end

    # Interior separators are preserved -- a nested prefix is a real mount, not a spelling variant.
    @test mount_segments("a/b") == ["a", "b"]
    @test mount_segments("/a/b/") == ["a", "b"]

    # `::Vector{String}`, not a vector of SubStrings: the String() conversion is load-bearing.
    @test mount_segments("static") isa Vector{String}
end

@testset "mount_segments refuses a segment the router cannot reach" begin
    # `mountable_files` refuses a *filename* the router would read as a pattern, so a file cannot
    # claim URLs other than its own. Nothing applied that rule to `mountdir`, which could do exactly
    # what a file is forbidden from doing: `staticfiles(dir, "*")` registered `/*/<file>` AND a bare
    # `/*`, so `GET /anything` was answered by the mount (#101). `**` and `{id}` already failed
    # loudly at registration; refusing them here names the cause instead of surfacing as a router
    # error three frames later.
    for md in ("*", "/*/", "a/*", "*/a", "**", "{id}", "a{b", "b}c", "{}", "assets/{id}")
        @test_throws ArgumentError mount_segments(md)
    end

    # The second class: a segment that survives normalization but is not a legal URL path segment,
    # so a conforming client's request and the registered route can never meet -- the router matches
    # raw path segments and never percent-decodes.
    #
    # The cost is NOT uniform, and the honest split is worth recording next to the list. Measured by
    # driving HTTP.jl 2.4 over a socket with hand-written request lines: `"my static"` really is
    # unmatchable (400 -- a space cannot appear in a request line) and so is `"a?b"` (404 -- the
    # query is split off first). The rest answered 200 to a client that sends raw bytes rather than
    # encoding them, which curl does by default. So refusing `"café"` takes a working mount away
    # from such a caller, and the encoded spelling is a different byte string that will not answer
    # it. Deliberate: one rule, judged like a filename, and a prefix no browser can reach.
    for md in ("my static", "café", "a?b", "a#b", "a[b]", "a|b", "a<b>", "a\\b", "a\"b", "a^b", "a`b")
        @test_throws ArgumentError mount_segments(md)
    end
    # A bare `%` is not percent-encoding, and neither is a non-hex or truncated escape.
    for md in ("100%", "%zz", "%4", "a%", "%g0")
        @test_throws ArgumentError mount_segments(md)
    end
    # Non-ASCII is refused even where Julia's character predicates say "letter" or "digit":
    # `isletter('Ａ')` is true for the fullwidth form, so without the `isascii` guard in `_is_pchar`
    # it would be accepted. Like `café` above, these are in the reachable-but-refused half -- a
    # raw-byte client does reach them; no conforming one does.
    for md in ("Ａ", "٣", "naïve")
        @test_throws ArgumentError mount_segments(md)
    end

    # A relative dot-segment is `pchar`-clean (`.` is unreserved) and still unreachable: the client
    # removes it before sending, so nothing ever arrives that would match `/../x`.
    for md in (".", "..", "a/../b", "./a")
        @test_throws ArgumentError mount_segments(md)
    end
    # Only a *whole* segment is a dot-segment; a leading dot is an ordinary hidden-style name.
    @test mount_segments(".well-known") == [".well-known"]
    @test mount_segments("a..b") == ["a..b"]

    # Everything RFC 3986 allows in a path segment unencoded still mounts — including a prefix the
    # app pre-encoded itself, which IS reachable, so refusing it would be wrong.
    @test mount_segments("my%20static") == ["my%20static"]
    @test mount_segments("caf%C3%A9") == ["caf%C3%A9"]
    # Validated, never re-encoded. HTTP.jl compares path segments byte for byte rather than by RFC
    # 3986 equivalence, so case-normalizing `%2f` to `%2F` here would stop matching a client that
    # sends the lowercase form.
    @test mount_segments("%2f") == ["%2f"]
    @test mount_segments("%41") == ["%41"]
    @test mount_segments("v1.2~beta_x-y") == ["v1.2~beta_x-y"]
    for md in ("a:b", "a@b", "a+b", "a,b", "a;b", "a=b", "a\$b", "a&b", "a'b", "a!b", "(a)")
        @test mount_segments(md) == [md]
    end
    # `*` is a legal pchar, so the wildcard refusal is a *routing* rule, not an encoding one: only a
    # whole segment of `*`/`**` is a wildcard, and an interior star stays a literal, servable segment.
    @test mount_segments("a*b") == ["a*b"]

    # The message names the offending segment and why it was refused, so a boot failure is
    # self-diagnosing rather than a bare stack trace.
    pattern_err = try; mount_segments("*"); catch e; e; end
    @test pattern_err isa ArgumentError
    @test occursin("\"*\"", pattern_err.msg)
    @test occursin("route pattern", pattern_err.msg)

    encoding_err = try; mount_segments("my static"); catch e; e; end
    @test encoding_err isa ArgumentError
    @test occursin("my static", encoding_err.msg)
    @test occursin("percent-encoded", encoding_err.msg)
end

@testset "_route_encode encodes a filename into a reachable path segment" begin
    # The filename counterpart of the rule above: `mount_segments` THROWS on a segment that is not
    # legal `pchar`, `_route_encode` ENCODES it. A `mountdir` is one authored value with an obvious
    # correction; a filename is data arriving in bulk from the filesystem (#121).

    # Identity on everything that is legal `pchar` -- this is the property that keeps every
    # currently-reachable static URL byte-identical.
    for name in ("plain.txt", "file.min.js", "myfile", "report(1).txt", "a+b.txt", "v1.2~beta.txt",
                 "a:b.txt", "a@b.txt", "a!b.txt", "a\$b.txt", "a&b.txt", "a'b.txt", "a,b;c=d.txt",
                 "index.html", "a*b.txt", "-_.~", "A1")
        @test _route_encode(name) == name
    end

    # Encoded: uppercase hex, one triplet per UTF-8 byte.
    @test _route_encode("my file.txt")  == "my%20file.txt"
    @test _route_encode("café.txt")     == "caf%C3%A9.txt"      # é is two bytes
    @test _route_encode("日本.txt")      == "%E6%97%A5%E6%9C%AC.txt"  # three bytes each
    @test _route_encode("a#b.txt")      == "a%23b.txt"
    @test _route_encode("a?b.txt")      == "a%3Fb.txt"
    @test _route_encode("a|b.txt")      == "a%7Cb.txt"
    @test _route_encode("a[b].txt")     == "a%5Bb%5D.txt"
    @test _route_encode("a^b.txt")      == "a%5Eb.txt"
    @test _route_encode("a\\b.txt")     == "a%5Cb.txt"
    @test _route_encode("a\"b.txt")     == "a%22b.txt"
    @test _route_encode("a\tb.txt")     == "a%09b.txt"          # control character

    # Non-ASCII that Julia's Unicode-aware `isletter` would accept -- the `isascii` guard in
    # `_is_pchar` is what keeps these out of the safe set (see its docstring).
    @test _route_encode("Ａ.txt") == "%EF%BC%A1.txt"             # fullwidth A
    @test _route_encode("٣.txt")  == "%D9%A3.txt"               # Arabic-Indic digit three

    # `%` is ALWAYS encoded here, unlike in `mount_segments`, where a well-formed triplet is
    # validated and passed through. A file named `my%20file.txt` contains `%`, `2`, `0`; leaving the
    # triplet alone would make one URL name both it and the encoded form of `my file.txt`.
    @test _route_encode("100%.txt")      == "100%25.txt"
    @test _route_encode("my%20file.txt") == "my%2520file.txt"
    @test _route_encode("%GG")           == "%25GG"
    @test mount_segments("my%20static")  == ["my%20static"]     # the authored side, unchanged

    # Injective: `%` being encoded is what makes the image unambiguous, so two names can never be
    # given the same route.
    @test _route_encode("a b")   != _route_encode("a%20b")
    @test _route_encode("a%2Fb") != _route_encode("a/b")

    # Invalid UTF-8, which is the stated reason the implementation iterates BYTES rather than
    # `Char`s: `readdir` can hand back a name that is not valid UTF-8, and `codepoint` on a
    # malformed `Char` throws. A `for c in name` rewrite passes every other assertion here and
    # fails only in production, on a non-UTF-8 filesystem.
    @test _route_encode(String(UInt8[0x61, 0xff, 0x62]))       == "a%FFb"
    @test _route_encode(String(UInt8[0x61, 0xff, 0xfe, 0x62])) == "a%FF%FEb"

    # Idempotence is deliberately NOT a property: encoding an already-encoded name encodes its `%`
    # again. Nothing in `mountfolder` encodes twice, and asserting this pins that it must not.
    @test _route_encode(_route_encode("café.txt")) == "caf%25C3%25A9.txt"

    @test _route_encode("") == ""
end

@testset "mount_route joins segments" begin
    # The empty vector is the router root, spelled explicitly. HTTP.jl treats "" and "/" alike, but
    # relying on that made a root mount's bare-directory route correct only by accident (#94).
    @test mount_route(String[]) == "/"
    @test mount_route(["static"]) == "/static"
    @test mount_route(["static", "app.js"]) == "/static/app.js"
    @test mount_route(["a", "b", "c"]) == "/a/b/c"

    # Joining cannot produce a doubled separator, whatever the mountdir spelling was.
    for md in ("static", "/static", "static/", "/static/", "//static//", "", "/")
        route = mount_route(vcat(mount_segments(md), "app.js"))
        @test !occursin("//", route)
        @test startswith(route, "/")
    end
end

@testset "mount_remainder decodes the request into a mount key (#221)" begin
    # The request side of the mount. `mount_route`/`_route_encode` above build the URL a mount
    # EMITS; this turns the URL a client SENDS back into the raw, `/`-separated, mount-relative
    # key `mountfolder` tabled the file under. The two are different alphabets on purpose.

    @testset "the prefix is dropped, the remainder decoded exactly once" begin
        @test mount_remainder("/static/app.js", 1) == "app.js"
        @test mount_remainder("/static/sub/nested.txt", 1) == "sub/nested.txt"
        @test mount_remainder("/a/b/app.js", 2) == "app.js"
        @test mount_remainder("/app.js", 0) == "app.js"          # root mount

        # Decoded ONCE -- never twice. `%2520` is the encoding of the literal text "%20", so it
        # must decode to "%20" and stop. A second pass would turn it into a space and make one
        # URL name two different files, which is the collision `_route_encode` avoids by being
        # injective (#121).
        @test mount_remainder("/static/caf%C3%A9.txt", 1) == "café.txt"
        @test mount_remainder("/static/my%20file.txt", 1) == "my file.txt"
        @test mount_remainder("/static/my%2520file.txt", 1) == "my%20file.txt"
        @test mount_remainder("/static/100%25.txt", 1) == "100%.txt"

        # Both spellings of a name that needs encoding reach the SAME key. This is the property
        # per-file registration could not have -- the router compares bytes, so the encoded and
        # raw routes were disjoint strings and #101/#121 each had to pick one client to serve.
        @test mount_remainder("/static/café.txt", 1) == mount_remainder("/static/caf%C3%A9.txt", 1)
    end

    @testset "a target that stops at the prefix is the bare route" begin
        # `""` is the key `mountfolder` gives a mount-root `index.html`, which is what lets one
        # handler answer both `/static/**` and the bare `/static`.
        @test mount_remainder("/static", 1) == ""
        @test mount_remainder("/static/", 1) == ""
        @test mount_remainder("/", 0) == ""
        @test mount_remainder("", 0) == ""
    end

    @testset "the query and fragment are not part of the key" begin
        @test mount_remainder("/static/app.js?v=1", 1) == "app.js"
        @test mount_remainder("/static/app.js?a=1&b=2", 1) == "app.js"
        @test mount_remainder("/static/app.js#frag", 1) == "app.js"
        # Absolute-form targets are legal in a request line and fall back to the URI parser,
        # which also does not unescape.
        @test mount_remainder("http://example.test/static/caf%C3%A9.txt", 1) == "café.txt"
    end

    @testset "a segment that cannot name one path component yields nothing" begin
        # `nothing` means "no mounted file can be called this" -> a 404, never a 400. The
        # containment itself comes from the enumerated table, not from these checks: `../` is
        # simply not a key. This is defence in depth, and it is what stops an ENCODED separator
        # from crossing a level -- `%2F` survives the split on '/' as one segment and only
        # becomes a separator after decoding.
        @test mount_remainder("/static/..", 1) === nothing
        @test mount_remainder("/static/.", 1) === nothing
        @test mount_remainder("/static/%2e%2e", 1) === nothing
        @test mount_remainder("/static/%2e%2e%2fetc", 1) === nothing
        @test mount_remainder("/static/sub%2Fnested.txt", 1) === nothing
        @test mount_remainder("/static/sub%5Cnested.txt", 1) === nothing
        @test mount_remainder("/static/a%00b", 1) === nothing
        # A dot INSIDE a name is ordinary and must survive -- `..` is a whole segment, not a
        # substring.
        @test mount_remainder("/static/a..b.txt", 1) == "a..b.txt"
        @test mount_remainder("/static/.env", 1) == ".env"   # refused by ENUMERATION, not here
    end

    @testset "malformed input is a ValidationError, not a silent miss" begin
        # Same boundary rule `Types.pathparams` applies to `{var}` routes (#70): a malformed
        # escape is client error (400), not a missing file (404). `unescapeuri` throws EOFError
        # on a trailing '%' and ArgumentError on "%ZZ"; both are wrapped.
        @test_throws ValidationError mount_remainder("/static/%ZZ.txt", 1)
        @test_throws ValidationError mount_remainder("/static/%.txt", 1)
        @test_throws ValidationError mount_remainder("/static/app%", 1)
        # `unescapeuri` does NOT throw on bytes that are not valid UTF-8 -- it returns an invalid
        # String. Left alone it would simply miss the table and report a 404, hiding a malformed
        # request as a missing file.
        @test_throws ValidationError mount_remainder("/static/%80.txt", 1)

        # The offending segment must NOT be echoed: `.msg` is app-reachable and a path segment
        # can carry a token (#72).
        err = try; mount_remainder("/static/sekrit%ZZ.txt", 1); catch e; e; end
        @test err isa ValidationError
        @test !occursin("sekrit", err.msg)
    end
end

end
