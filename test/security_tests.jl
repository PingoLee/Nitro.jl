@testitem "Security: Crypto Robustness" tags=[:security, :core] setup=[NitroCommon] begin
using Nitro
using Test
using HTTP

@testset "Security: Crypto Robustness" begin
    res = HTTP.Response(200)
    # This should succeed without error since cryptography is built-in
    set_cookie!(res, "session", "secret-data", secret_key="my-key")
    @test length(res.headers) == 1
    cookie_header = res.headers[1][2]
    @test contains(cookie_header, "session=")

    req = HTTP.Request("GET", "/", ["Cookie" => cookie_header])
    # Should decrypt properly
    val = get_cookie(req, "session", encrypted=true, secret_key="my-key")
    @test val == "secret-data"

    # Should fail if bad key
    @test_throws Nitro.Core.Errors.CookieError get_cookie(req, "session", encrypted=true, secret_key="wrong-key")

    # Encrypted operations should fail closed when the key is missing or empty
    @test_throws Nitro.Core.Errors.CookieError set_cookie!(HTTP.Response(200), "session", "secret-data", encrypted=true)
    @test_throws Nitro.Core.Errors.CookieError set_cookie!(HTTP.Response(200), "session", "secret-data", encrypted=true, secret_key="")
    @test_throws Nitro.Core.Errors.CookieError get_cookie(HTTP.Request("GET", "/", ["Cookie" => "session=plaintext"]), "session", encrypted=true)
    @test_throws Nitro.Core.Errors.CookieError get_cookie(HTTP.Request("GET", "/", ["Cookie" => "session=plaintext"]), "session", encrypted=true, secret_key="")
end

@testset "Security: Cookie Header Validation" begin
    @test_throws ArgumentError set_cookie!(HTTP.Response(200), "bad;name", "value", encrypted=false)
    @test_throws ArgumentError set_cookie!(HTTP.Response(200), "session", "abc; Domain=evil.com", encrypted=false)
    @test_throws ArgumentError set_cookie!(HTTP.Response(200), "session", "abc\r\nSet-Cookie: other=value", encrypted=false)
    @test_throws ArgumentError set_cookie!(HTTP.Response(200), "session", "value", path="/api;Secure", encrypted=false)
end
end

@testitem "Security: Access log redacts query strings" tags=[:security, :core] setup=[NitroCommon] begin
using Nitro
using Test
using HTTP

# AccessLogMiddleware must not leak query strings — reset tokens, API keys, OAuth
# `code`/`state`, signed-URL signatures routinely ride there and access logs are
# frequently shipped to third-party aggregators. Only the path is logged by default.
run_once(mw, req) = begin
    logger = Test.TestLogger()
    Base.CoreLogging.with_logger(logger) do
        mw(_req -> HTTP.Response(200))(req)
    end
    logger.logs
end

@testset "query string redacted by default" begin
    logs = run_once(Nitro.Core.AccessLogMiddleware(),
                    HTTP.Request("GET", "/reset?token=SECRET-XYZ&api_key=abc123"))
    @test length(logs) == 1
    msg = logs[1].message
    @test occursin("/reset", msg)        # path is kept
    @test !occursin("SECRET-XYZ", msg)   # token value gone
    @test !occursin("api_key", msg)      # query keys gone
    @test !occursin("token=", msg)
    @test !occursin('?', msg)
end

@testset "log_query=true opts back into the full target" begin
    logs = run_once(Nitro.Core.AccessLogMiddleware(log_query=true),
                    HTTP.Request("GET", "/reset?token=SECRET-XYZ"))
    @test occursin("token=SECRET-XYZ", logs[1].message)
end

# The redaction above is enforced by `_log_target_path` (#39), which slices an origin-form
# target instead of parsing a full `HTTP.URI`. These pin the two ways that slice could leak
# more than the path: an absolute-form target, whose authority may carry credentials, and a
# fragment, which binds tighter than the query delimiter.
@testset "target reduction redacts on every request-target form" begin
    tp = Nitro.Core._log_target_path

    @testset "origin-form (the common case) is a pure slice" begin
        @test tp("/plain") == "/plain"                    # no query at all
        @test tp("/p?") == "/p"                           # empty query
        @test tp("/a?b?c=SECRET") == "/a"                 # first '?' wins
        @test tp("/café/ü?k=SECRET") == "/café/ü"   # multibyte path before '?'
        @test tp("/foo#frag?k=SECRET") == "/foo"          # '#' binds tighter than '?'
        @test tp("/foo?k=a#frag") == "/foo"
    end

    @testset "a leading // is an authority, not a path" begin
        # The trap: this DOES start with '/', so a naive origin-form test slices it and logs
        # `//user:pa55w0rd@evil.example/x` verbatim. It must be parsed like absolute-form.
        @test tp("//user:pa55w0rd@evil.example/x?k=SECRET") == "/x"
        @test !occursin("pa55w0rd", tp("//user:pa55w0rd@evil.example/x?k=SECRET"))
        @test !occursin("evil.example", tp("//user:pa55w0rd@evil.example/x?k=SECRET"))
        @test tp("//evil.example/x") == "/x"
    end

    @testset "authority-form and asterisk-form" begin
        # `CONNECT h.example:443` has no path at all; `HTTP.URI` reads it as scheme+path and
        # yields "443", so the result is rejected for not being an absolute path.
        @test tp("h.example:443") == "-"
        @test tp("user:pa55w0rd@h.example:443") == "-"
        @test !occursin("pa55w0rd", tp("user:pa55w0rd@h.example:443"))
        # `OPTIONS *` is a fixed literal carrying no user content.
        @test tp("*") == "*"
    end

    @testset "absolute-form never leaks userinfo into the log" begin
        # RFC 9112 §3.2.2 — a server MUST accept this form, and HTTP.jl passes the target
        # through verbatim. A prefix slice would keep `scheme://user:pass@host`, putting
        # credentials in a log that is routinely shipped off-box.
        @test tp("http://h.example/v1/x?k=SECRET") == "/v1/x"
        @test tp("http://user:pa55w0rd@h.example/v1/x?k=SECRET") == "/v1/x"
        @test !occursin("pa55w0rd", tp("http://user:pa55w0rd@h.example/v1/x"))
        @test !occursin("h.example", tp("http://user:pa55w0rd@h.example/v1/x"))
    end

    @testset "a target with no usable path logs a placeholder, never the raw target" begin
        # Returning the target unchanged here is what would leak; "-" is the standard
        # access-log stand-in for a value that is not available.
        @test tp("?token=SECRET") == "-"
        @test tp("") == "-"
        @test !occursin("SECRET", tp("?token=SECRET"))
    end

    # End-to-end through the middleware: every one of these must produce exactly one log
    # line, carrying no query, no fragment and no credentials.
    @testset "end-to-end redaction across target forms" begin
        for bad in ("/a b?token=SECRET", "/%ZZ?token=SECRET",
                    "http://user:pa55w0rd@h.example/v1/x?token=SECRET",
                    "//user:pa55w0rd@evil.example/v1/x?token=SECRET",
                    "user:pa55w0rd@h.example:443",
                    "?token=SECRET", "/foo#frag?token=SECRET", "*")
            logs = run_once(Nitro.Core.AccessLogMiddleware(), HTTP.Request("GET", bad))
            @test length(logs) == 1
            msg = logs[1].message
            @test !occursin("SECRET", msg)
            @test !occursin("pa55w0rd", msg)
            @test !occursin('?', msg)
        end
    end
end
end

@testitem "Security: SecretString redaction" tags=[:security, :core] setup=[NitroCommon] begin
using Nitro
using Test
using JSON

const RAW = "NITRO-RAW-SECRET-77aa1e"

# App-config shape from docs/src/tutorial/secrets.md: the secret sits in a struct
# whose default recursive `show` must hit the SecretString mask at the leaf.
struct SecretTestConfig
    name::String
    api_key::SecretString
end

@testset "every display path masks the value" begin
    s = SecretString(RAW)
    for rendered in (sprint(show, s),
                     sprint((io, x) -> show(io, MIME("text/plain"), x), s),
                     repr(s),
                     string(s),
                     "interpolated: $s")
        @test !occursin(RAW, rendered)
        @test occursin("****", rendered)
    end
end

@testset "containing structs mask through default recursive show" begin
    cfg = SecretTestConfig("app", SecretString(RAW))
    shown = sprint(show, cfg)
    @test !occursin(RAW, shown)
    @test occursin("****", shown)
    @test occursin("app", shown)            # non-secret fields still display normally
end

@testset "reveal is the explicit unwrap" begin
    @test reveal(SecretString(RAW)) == RAW
    @test reveal(SecretString(SubString("abc-def", 1, 3))) == "abc"   # AbstractString ctor
    s = SecretString(RAW)
    @test SecretString(s) === s             # idempotent — no double wrapping
end

@testset "constant-time equality semantics" begin
    @test SecretString("k1") == SecretString("k1")
    @test SecretString("k1") != SecretString("k2")
    @test SecretString("k1") == "k1"        # auth shape: stored secret vs client token
    @test "k1" == SecretString("k1")
    @test SecretString("k1") != "k1-longer" # length mismatch
    @test SecretString("") == SecretString("")
end

@testset "hash honors the == contract" begin
    @test hash(SecretString("k1")) == hash(SecretString("k1"))
    @test hash(SecretString("k1")) == hash("k1")    # consistent with mixed ==
    d = Dict(SecretString("k1") => 1)
    @test d[SecretString("k1")] == 1
end

# #25: `show` masked the value but JSON did not, so returning or logging a struct
# holding a SecretString shipped the raw secret. Every shape below reflected the
# underlying `value` field before the `JSON.lower` mask landed.
@testset "every JSON shape masks the value" begin
    cfg = SecretTestConfig("app", SecretString(RAW))
    for encoded in (JSON.json(SecretString(RAW)),          # bare
                    JSON.json(cfg),                        # struct field
                    JSON.json(Dict("k" => SecretString(RAW))),
                    JSON.json([SecretString(RAW)]),
                    JSON.json((SecretString(RAW), 1)))
        @test !occursin(RAW, encoded)
        @test occursin("****", encoded)
    end
    # A mask that swallowed the whole struct would satisfy the loop above while
    # breaking every caller, so pin that non-secret fields still serialize.
    @test occursin("\"app\"", JSON.json(cfg))
end

# The mask is deliberately one-way: no `StructUtils.lift` accompanies the `lower`.
# Reconstructing a `SecretString("****")` would parse cleanly and then fail an auth
# comparison far from the parse site, so the throw here is the better failure. Pin
# it, so adding a `lift` later is a deliberate decision rather than an accident.
@testset "serialization is one-way" begin
    encoded = JSON.json(SecretTestConfig("app", SecretString(RAW)))
    @test_throws ArgumentError JSON.parse(encoded, SecretTestConfig)

    # As a Dict *key* a SecretString routes through `StructUtils.lowerkey`, which
    # has no method here. Pre-existing, and fails closed rather than leaking.
    @test_throws ArgumentError JSON.json(Dict(SecretString(RAW) => 1))
end

@testset "the response path masks the value" begin
    cfg = SecretTestConfig("app", SecretString(RAW))
    # Res.json is the explicit builder; format_response is the automatic
    # struct-to-JSON path a handler hits by returning the config struct directly.
    for body in (text(Nitro.Res.json(cfg)), text(Nitro.Core.format_response(cfg)))
        @test !occursin(RAW, body)
        @test occursin("****", body)
        @test occursin("app", body)
    end
end
end

# #130: `ValidationError.cause` is the wrapped underlying exception, and parsers quote their
# input -- a JSON parse `ArgumentError` echoes the submitted bytes. `showerror` was the leak the
# issue was filed for; `show` and JSON are INDEPENDENT output paths that leaked the same value,
# and the JSON one reaches the CLIENT rather than the log. Same pairing, same reasoning, and the
# same test shape as the `SecretString` redaction item above (#25) -- the display-path contract
# for this type lives in `test/util_tests.jl`.
@testitem "Security: ValidationError cause redaction" tags=[:security, :core] setup=[NitroCommon] begin
using Nitro
using Test
using JSON
using Nitro: ValidationError

const PAYLOAD = "NITRO-SUBMITTED-PASSWORD-91fe3c"

# An app-level error envelope: the single most likely way a ValidationError is serialized.
struct ErrorEnvelope
    ok::Bool
    error::ValidationError
end

err() = ValidationError("Invalid query parameter 'limit': expected Int64",
                        ArgumentError("invalid JSON parsing type Any: $PAYLOAD"))

@testset "every JSON shape masks the cause" begin
    for encoded in (JSON.json(err()),                          # bare
                    JSON.json(ErrorEnvelope(false, err())),    # struct field
                    JSON.json(Dict("error" => err())),
                    JSON.json([err()]),
                    JSON.json((err(), 1)))
        @test !occursin(PAYLOAD, encoded)
        @test occursin("ArgumentError", encoded)               # the type survives
    end

    # A mask that swallowed the whole struct would satisfy the loop above while breaking every
    # caller, so pin that `.msg` -- which #72 made value-free precisely so it could be shown --
    # still serializes.
    @test occursin("Invalid query parameter 'limit'", JSON.json(err()))

    # No cause at all: the key is absent rather than null, and nothing else changes. Worth pinning
    # because the unpatched reflection emitted `"cause":null` here, so this assertion is a guard
    # rather than a restatement of the loop above.
    bare = JSON.json(ValidationError("Missing required query parameter 'q'"))
    @test occursin("Missing required query parameter 'q'", bare)
    @test !occursin("cause", bare)

    # A nested ValidationError does not recurse into the inner cause: `lower` hands back a String
    # for the type, so the chain stops at one level and the inner payload is unreachable.
    nested = ValidationError("outer", ValidationError("inner", ArgumentError(PAYLOAD)))
    @test !occursin(PAYLOAD, JSON.json(nested))
    @test occursin("ValidationError", JSON.json(nested))
end

# The mask is deliberately one-way and deliberately has no key form, matching `SecretString`
# above. Both already hold; pin them so adding a `lowerkey` or a `lift` for convenience is a
# deliberate decision rather than an accident that silently re-opens a path.
@testset "serialization is one-way and has no key form" begin
    # As a Dict *key* a ValidationError routes through `StructUtils.lowerkey`, which has no method
    # here. Fails closed rather than falling back to field reflection.
    @test_throws ArgumentError JSON.json(Dict(err() => 1))

    # No `StructUtils.lift` accompanies the `lower`, so a struct holding one does not parse back.
    @test_throws MethodError JSON.parse(JSON.json(ErrorEnvelope(false, err())), ErrorEnvelope)
end

@testset "the response path masks the cause" begin
    # Res.json is the explicit builder an app writes in a `catch ValidationError`;
    # format_response is the automatic struct-to-JSON path a handler hits by returning it.
    for body in (text(Nitro.Res.json(Dict("error" => err()))),
                 text(Nitro.Res.json(err())),
                 text(Nitro.Core.format_response(err())))
        @test !occursin(PAYLOAD, body)
        @test occursin("ArgumentError", body)
        @test occursin("Invalid query parameter 'limit'", body)
    end
end

# The end-to-end shape the issue is actually about: a real rejected request, serialized by an
# app that catches the error and reports it. Nothing synthetic -- the cause here is whatever
# JSON.jl actually threw.
#
# The sentinel is chosen ON PURPOSE and the assertion order below is what enforces it, because
# there are two ways a sentinel silently vanishes from the cause -- after which every negative
# assertion here passes for the wrong reason:
#
#   1. A value whose FIRST character is `N`, `n`, `I` or `i` is read as a would-be `NaN`/`Inf`,
#      and JSON.jl reports "possible `NaN`, `Inf`, or `-Inf`..." without quoting the input at all.
#      That rules out the sentinel names one would naturally reach for: `name-...`, `id-...`,
#      `nitro-...`. Measured, not assumed -- `true-...`, `7...` and `-1...` DO echo, so the rule is
#      narrower than "looks like a JSON literal".
#   2. Anything longer than 21 characters is truncated ("averyveryverylongsecr").
#
# So the POSITIVE assertion comes first: it fails loudly if a future edit picks a sentinel this
# parser does not echo, rather than letting the guards quietly become theater. It already caught
# one -- the first sentinel here began with "N".
@testset "a real rejected body does not round-trip to the client" begin
    echoed = "pw-91fe3c"
    real_err = try
        Nitro.Core.Util.parseparam_checked(Int, echoed, "limit", :query)
        nothing
    catch e
        e
    end
    @test real_err isa ValidationError
    @test occursin(echoed, sprint(showerror, real_err.cause))      # the cause DOES carry it
    @test !occursin(echoed, JSON.json(real_err))                   # ...and JSON does not
    @test !occursin(echoed, text(Nitro.Res.json(Dict("error" => real_err))))
    @test !occursin(echoed, sprint(show, real_err))
end
end
