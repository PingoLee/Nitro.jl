@testitem "Util" tags=[:core] setup=[NitroCommon] begin
using Test
using UUIDs
using Nitro.Core.Util
using Nitro.Core.Util: mount_segments, mount_route
using Nitro.Core: serverwelcome
using Nitro: ValidationError
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

@testset "serverwelcome banner includes environment when available" begin
    output = mktemp() do path, io
        redirect_stdout(io) do
            withenv("NITRO_ENV" => "dev") do
                serverwelcome("http://127.0.0.1:8080", nothing, false)
            end
        end
        flush(io)
        read(path, String)
    end

    @test occursin("Environment: dev", output)
    @test occursin("Starting server at http://127.0.0.1:8080", output)

    output_without_env = mktemp() do path, io
        redirect_stdout(io) do
            withenv("NITRO_ENV" => nothing) do
                serverwelcome("http://127.0.0.1:8080", "/api", true)
            end
        end
        flush(io)
        read(path, String)
    end

    @test !occursin("Environment:", output_without_env)
    @test occursin("Global prefix: /api", output_without_env)
    @test occursin("parallel mode:", output_without_env)
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

end
