@testitem "Util" tags=[:core] setup=[NitroCommon] begin
using Test
using UUIDs
using Nitro.Core.Util
using Nitro.Core: serverwelcome
using Nitro: ValidationError

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

    # The member method must not unescape a second time.
    @test parseparam(Union{Int, String}, "a%2520b") == "a%20b"
    @test parseparam(Union{Int, String}, "a%20b"; escape=false) == "a%20b"
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

end