@testitem "Principal" tags=[:auth, :core] setup=[NitroCommon] begin

using Test
using JSON
using Nitro: Principal

@testset "read-only dict interface over claims" begin
    claims = Dict{String,Any}("sub" => "42", "role" => "admin", "scopes" => ["read"])
    principal = Principal(claims; id="42")

    # Typed fields
    @test principal.id == "42"
    @test principal.kid === nothing
    @test principal.source === :claim

    # Dict reads pass through to the verified claims
    @test principal["role"] == "admin"
    @test get(principal, "role", nothing) == "admin"
    @test get(principal, "nope", :default) === :default
    @test get(() -> :computed, principal, "nope") === :computed
    @test haskey(principal, "sub")
    @test !haskey(principal, "nope")
    @test Set(keys(principal)) == Set(["sub", "role", "scopes"])
    @test "admin" in collect(values(principal))
    @test length(principal) == 3
    @test !isempty(principal)
    @test Dict(pairs(principal)) == claims

    # AbstractDict generic fallbacks
    @test principal == claims
    @test principal isa AbstractDict
    @test Dict(principal) == claims && Dict(principal) isa Dict
    @test occursin("sub", sprint(show, MIME"text/plain"(), principal))

    # Immutable: a verified security artifact cannot be mutated
    @test_throws MethodError principal["extra"] = 1
    @test_throws MethodError delete!(principal, "sub")

    # Empty principal
    @test isempty(Principal(Dict{String,Any}()))
end

@testset "constructor coercions" begin
    # Non-string id is stringified; Symbol-keyed claims are normalized
    principal = Principal(Dict(:sub => 42); id=42, kid="service-a", source=:kid)
    @test principal.id == "42"
    @test principal.kid == "service-a"
    @test principal.source === :kid
    @test principal["sub"] == 42
end

@testset "JSON wire shape equals the claims object" begin
    claims = Dict{String,Any}("sub" => "42", "iat" => 1234, "role" => "admin")
    principal = Principal(claims; id="42", kid="k1")
    # id/kid/source metadata must never leak into serialized output (key order is
    # not significant in JSON, so compare parsed objects)
    @test JSON.parse(JSON.json(principal)) == JSON.parse(JSON.json(claims))
end

end

@testitem "Auth module" tags=[:auth, :core] setup=[NitroCommon] begin

using Test
using HTTP
using Nitro
using Base64
using JSON
using SHA
import Nitro.Auth: PasswordValidator, validate
import Nitro.Auth: encode, matches, upgrade_encoding, PBKDF2PasswordEncoder, BCryptPasswordEncoder,
    DelegatingPasswordEncoder, SpringSecurityPBKDF2PasswordEncoder
import Nitro.Auth: is_password_usable, set_default_algorithm!, SUPPORTED_ALGORITHMS, DEFAULT_ALGORITHM

const NOW_TS = trunc(Int, time())

@testset "Auth module cookie helpers" begin
    res = HTTP.Response(200)
    Nitro.Auth.set_auth_cookie!(res, "token-123"; ttl=900, secure=false)
    cookie_header = HTTP.header(res, "Set-Cookie")
    @test occursin("auth_token=token-123", cookie_header)
    @test !occursin("Secure", cookie_header)
    # The caller's `ttl` reaches the wire verbatim -- nothing rounds it or clamps it.
    @test occursin("Max-Age=900", cookie_header)

    logout = HTTP.Response(200)
    Nitro.Auth.clear_auth_cookie!(logout; secure=false)
    cleared = HTTP.header(logout, "Set-Cookie")
    @test occursin("Max-Age=0", cleared)
end

@testset "set_auth_cookie! refuses to guess a TTL (#232)" begin
    # The defect was a 24h default on a helper that never decodes the token, against a
    # 15-minute default token bound: the browser kept sending a credential guaranteed to
    # 401, which reads as a server fault rather than an expired session. The fix is that
    # `ttl` has no default at all, so the two regression guards are (a) omitting it is an
    # error and (b) no constant exists for anyone to restore one from.
    res = HTTP.Response(200)
    @test_throws UndefKeywordError Nitro.Auth.set_auth_cookie!(res, "token-123"; secure=false)

    # Asserted on the MODULE, not on a call: a reintroduced default would otherwise only
    # surface once some call site started relying on it again.
    @test !isdefined(Nitro.Auth, :DEFAULT_AUTH_COOKIE_TTL)

    # A caller that mints with its own lifetime gets that lifetime on the cookie, which is
    # the case the old default was always wrong for.
    minted = HTTP.Response(200)
    Nitro.Auth.set_auth_cookie!(minted, "token-abc"; ttl=60, secure=false)
    @test occursin("Max-Age=60", HTTP.header(minted, "Set-Cookie"))
end

@testset "JWT encode/decode and validation" begin
    keyset = Dict("default" => "secret-a", "rotated" => "secret-b")
    token = Nitro.Auth.encode_jwt(
        Dict(
            "sub" => "42",
            "iss" => "nitro-tests",
            "aud" => ["nitro"],
            "exp" => NOW_TS + 3600,
            "nbf" => NOW_TS - 1,
        ),
        keyset;
        kid="rotated"
    )

    claims, kid = Nitro.Auth.decode_jwt(token, keyset; issuer="nitro-tests", audience="nitro", with_kid=true)
    @test claims["sub"] == "42"
    @test kid == "rotated"

    expired = Nitro.Auth.encode_jwt(Dict("sub" => "42", "exp" => NOW_TS - 120), "secret-a")
    @test_throws Nitro.Auth.AuthError Nitro.Auth.decode_jwt(expired, "secret-a")

    # A token without an exp claim is accepted by default only as a short-lived
    # access token bounded by iat + 15 minutes.
    no_exp = Nitro.Auth.encode_jwt(Dict("sub" => "42"), "secret-a")
    @test Nitro.Auth.decode_jwt(no_exp, "secret-a")["sub"] == "42"

    old_no_exp = Nitro.Auth.encode_jwt(Dict("sub" => "42", "iat" => NOW_TS - 901), "secret-a")
    @test_throws Nitro.Auth.AuthError Nitro.Auth.decode_jwt(old_no_exp, "secret-a"; iat_skew=0)

    # Apps can require an explicit exp claim, or choose a longer fallback max age.
    @test_throws Nitro.Auth.AuthError Nitro.Auth.decode_jwt(no_exp, "secret-a"; require_exp=true)
    @test Nitro.Auth.decode_jwt(no_exp, "secret-a"; exp_timeout=3600)["sub"] == "42"

    # Explicit exp remains authoritative and is not capped by the default iat fallback.
    explicit_exp = Nitro.Auth.encode_jwt(Dict("sub" => "42", "iat" => NOW_TS - 1200, "exp" => NOW_TS + 3600), "secret-a")
    @test Nitro.Auth.decode_jwt(explicit_exp, "secret-a"; iat_skew=0)["sub"] == "42"

    # A token with neither exp nor iat has no secure lifetime anchor.
    b64json(data) = replace(replace(replace(Base64.base64encode(Vector{UInt8}(codeunits(JSON.json(data)))), '+' => '-'), '/' => '_'), '=' => "")
    missing_iat = string(b64json(Dict("alg" => "HS256", "typ" => "JWT")), ".", b64json(Dict("sub" => "42")), ".")
    @test_throws Nitro.Auth.AuthError Nitro.Auth.decode_jwt(missing_iat, "secret-a"; verify=false)

    # encode_jwt(expires_in=...) stamps an exp so the token is time-bounded.
    ttl_token = Nitro.Auth.encode_jwt(Dict("sub" => "42"), "secret-a"; expires_in=3600)
    @test Nitro.Auth.decode_jwt(ttl_token, "secret-a")["sub"] == "42"

    short_lived = Nitro.Auth.encode_jwt(Dict("sub" => "42"), "secret-a"; expires_in=-120)
    @test_throws Nitro.Auth.AuthError Nitro.Auth.decode_jwt(short_lived, "secret-a")

    # required_claims: named claims must be present (any value), else AuthError.
    @test Nitro.Auth.decode_jwt(ttl_token, "secret-a"; required_claims=["sub", "exp"])["sub"] == "42"
    @test_throws Nitro.Auth.AuthError Nitro.Auth.decode_jwt(ttl_token, "secret-a"; required_claims=["aud"])
    @test Nitro.Auth.validate_claims(Dict("sub" => "1", "exp" => NOW_TS + 60); required_claims=["sub"]) isa AbstractDict
    @test_throws Nitro.Auth.AuthError Nitro.Auth.validate_claims(Dict("exp" => NOW_TS + 60); required_claims=["sub"])
    # Symbol-keyed claims are honored, matching the rest of claim validation.
    @test Nitro.Auth.validate_claims(Dict(:sub => "1", :exp => NOW_TS + 60); required_claims=["sub"]) isa AbstractDict
end

@testset "JWT algorithm and key-id rejection (#45)" begin
    # These properties were sound on `main` and completely untested: the string "alg"
    # appeared exactly once in all of test/, as scaffolding for an unrelated case. An
    # audit found the verification path safe, which is precisely when it is cheapest for
    # a later refactor to weaken it silently. This testset is the pin.

    secret = "secret-a"
    b64json(data) = replace(replace(replace(Base64.base64encode(Vector{UInt8}(codeunits(JSON.json(data)))), '+' => '-'), '/' => '_'), '=' => "")

    # Build a token with an arbitrary header but a genuinely valid HS256 signature. This
    # is the whole point of the suite: a forged-header token whose MAC actually checks
    # out, which no amount of signature verification can reject.
    function signed(header, claims; key = secret)
        input = string(b64json(header), ".", b64json(claims))
        return string(input, ".", Nitro.Auth._base64url_encode(Nitro.Auth._hmac_sha256(key, input)))
    end
    payload = Dict("sub" => "42", "exp" => NOW_TS + 3600)

    caught(f) = try; f(); nothing; catch err; err; end

    # -- Control. Identical machinery, correct alg: the only difference between this and
    # the RS256 case below is the header string, so a failure there cannot be blamed on
    # the hand-rolled signing.
    ok = signed(Dict("alg" => "HS256", "typ" => "JWT"), payload)
    @test Nitro.Auth.decode_jwt(ok, secret)["sub"] == "42"

    # -- Algorithm confusion. Before #45 this was ACCEPTED: `decode_jwt` parsed the
    # header's alg and never read it, so an RS256-advertising token verified fine as long
    # as its signature was a valid HS256 MAC. Nitro never loads a public key, so this was
    # not the classic RS256->HS256 downgrade -- but "safe by omission" is exactly what a
    # refactor erases without noticing.
    confused = signed(Dict("alg" => "RS256", "typ" => "JWT"), payload)
    err = caught(() -> Nitro.Auth.decode_jwt(confused, secret))
    @test err isa Nitro.Auth.AuthError
    # Pinned on the message too: rejecting for the RIGHT reason is the property. A future
    # signature-check regression would also throw AuthError here and look like a pass.
    @test occursin("Unsupported JWT algorithm", sprint(showerror, err))

    # -- alg=none, both shapes. BOTH of these already threw AuthError before #45 --
    # `_constant_time_equals` compares a 32-byte HMAC against 0 or 9 bytes and loses on the
    # length check -- so a bare `@test_throws AuthError` here would be green theater: it
    # passes against the unfixed code and constrains nothing. The property that is actually
    # new is WHICH rejection fires: the algorithm, before any key is resolved.
    none_empty = string(b64json(Dict("alg" => "none", "typ" => "JWT")), ".", b64json(payload), ".")
    err = caught(() -> Nitro.Auth.decode_jwt(none_empty, secret))
    @test err isa Nitro.Auth.AuthError
    @test occursin("Unsupported JWT algorithm", sprint(showerror, err))

    none_garbage = string(b64json(Dict("alg" => "none", "typ" => "JWT")), ".", b64json(payload), ".bm90LWEtc2ln")
    err = caught(() -> Nitro.Auth.decode_jwt(none_garbage, secret))
    @test err isa Nitro.Auth.AuthError
    @test occursin("Unsupported JWT algorithm", sprint(showerror, err))

    # -- A header with no alg at all is not a free pass either. This one DOES discriminate
    # on the type alone (it was accepted outright before #45), but pin the message too so
    # it matches its neighbours and cannot drift into passing for the wrong reason.
    no_alg = signed(Dict("typ" => "JWT"), payload)
    err = caught(() -> Nitro.Auth.decode_jwt(no_alg, secret))
    @test err isa Nitro.Auth.AuthError
    @test occursin("Unsupported JWT algorithm", sprint(showerror, err))

    # -- A non-string alg must not inherit the malformed-header MethodError class below:
    # `== "HS256"` is false for any type, so this is an ordinary rejection.
    @test_throws Nitro.Auth.AuthError Nitro.Auth.decode_jwt(signed(Dict("alg" => 123, "typ" => "JWT"), payload), secret)

    # -- Offline inspection still parses anything. `verify=false` is the documented
    # escape hatch for reading a token you are not authenticating, so the alg gate lives
    # inside `if verify` and must not reach it.
    @test Nitro.Auth.decode_jwt(confused, secret; verify=false)["sub"] == "42"

    # -- Key id. An unknown kid resolves against no key and must never fall back to a
    # default one; that silent fallback is how a revoked signer keeps working. This held
    # before #45 too -- it is a PIN on existing behavior, not a regression guard for this
    # commit, and it is here because #45 is about locking the guarantees down.
    keyset = Dict("default" => "secret-a", "rotated" => "secret-b")
    ghost = signed(Dict("alg" => "HS256", "typ" => "JWT", "kid" => "ghost"), payload)
    err = caught(() -> Nitro.Auth.decode_jwt(ghost, keyset))
    @test err isa Nitro.Auth.AuthError
    @test occursin("Unknown JWT key id", sprint(showerror, err))

    # -- A JSON kid is whatever the token's author typed. A number used to reach
    # `_resolve_secret`, whose `kid` parameter is itself typed, as a MethodError -- so it
    # fired for a plain STRING secret exactly as it did for a keyset. Auth middleware
    # renders any throw as 401, so this was never an authz hole, but a direct `decode_jwt`
    # caller got an exception type the API does not document.
    numeric_kid = signed(Dict("alg" => "HS256", "typ" => "JWT", "kid" => 123), payload)
    for verifier in (keyset, secret)
        err = caught(() -> Nitro.Auth.decode_jwt(numeric_kid, verifier))
        @test err isa Nitro.Auth.AuthError
        @test occursin("Invalid JWT key id", sprint(showerror, err))
    end
    list_kid = signed(Dict("alg" => "HS256", "typ" => "JWT", "kid" => ["a"]), payload)
    err = caught(() -> Nitro.Auth.decode_jwt(list_kid, keyset))
    @test err isa Nitro.Auth.AuthError
    @test occursin("Invalid JWT key id", sprint(showerror, err))

    # Checked before `verify`, like the three-segment check: a non-string kid is a
    # malformed header, not an algorithm choice, and `with_kid=true` promises a String.
    # This is a REAL behavior change on the offline path -- before #45 this call returned
    # the claims with no error at all -- so the upgrade entry says so rather than claiming
    # `verify=false` is untouched.
    @test_throws Nitro.Auth.AuthError Nitro.Auth.decode_jwt(numeric_kid, keyset; verify=false)

    # -- Same defect class, one level up: neither segment is necessarily a JSON object.
    # A header of `[]` made `get(::Vector{Any}, "alg", nothing)` a MethodError, and a
    # non-object claims segment made `validate_claims(::AbstractDict)` one. Fixing only the
    # kid would have left the class half closed.
    arr = "W10"                                   # base64url of `[]`
    err = caught(() -> Nitro.Auth.decode_jwt(string(arr, ".", b64json(payload), ".x"), secret))
    @test err isa Nitro.Auth.AuthError
    @test occursin("Invalid JWT header", sprint(showerror, err))

    err = caught(() -> Nitro.Auth.decode_jwt(string(b64json(Dict("alg" => "HS256")), ".", arr, ".x"), secret))
    @test err isa Nitro.Auth.AuthError
    @test occursin("Invalid JWT claims", sprint(showerror, err))

    # The header case is reachable from an attacker-controlled bearer token; the CLAIMS case
    # is not, on `verify=true` -- you cannot reach `validate_claims` without first passing
    # the signature check, so an attacker gets "Invalid JWT signature". It is reachable
    # offline, and by a secret-holder. Both must stay AuthError on both paths.
    @test_throws Nitro.Auth.AuthError Nitro.Auth.decode_jwt("W10.W10.x", secret)
    @test_throws Nitro.Auth.AuthError Nitro.Auth.decode_jwt("W10.W10.x", secret; verify=false)

    # -- The rest of the same class: the DECODERS are sinks too, and both run before the
    # `isa AbstractDict` guards above. `base64decode` throws ArgumentError on a bad alphabet
    # or an unpaddable length, `JSON.parse` on anything that is not JSON. Guarding only the
    # parsed value left the class half closed, and length-dependently so -- which is exactly
    # what makes a partial fix read as complete.
    raw64(str) = replace(replace(replace(Base64.base64encode(Vector{UInt8}(codeunits(str))), '+' => '-'), '/' => '_'), '=' => "")
    good_claims = b64json(payload)
    good_header = b64json(Dict("alg" => "HS256", "typ" => "JWT"))
    # Note which sink each case actually reaches -- `base64decode("!!!!")` and
    # `base64decode("")` do NOT throw, they return bytes that then fail to parse, so four
    # of these five land on `JSON.parse`. Only an UNPADDABLE length reaches base64decode's
    # own throw, which is why "header unpaddable" is here and not folded into the first row.
    malformed = [
        ("header unpaddable",     string("x", ".", good_claims, ".x")),      # -> base64decode
        ("header bad alphabet",   string("!!!!", ".", good_claims, ".x")),   # -> JSON.parse
        ("header not JSON",       string(raw64("foo"), ".", good_claims, ".x")),
        ("header truncated JSON", string(raw64("{\"alg\":"), ".", good_claims, ".x")),
        ("header empty",          string("", ".", good_claims, ".x")),
        ("claims not JSON",       string(good_header, ".", raw64("foo"), ".x")),
    ]
    for (label, tok) in malformed, v in (true, false)
        err = caught(() -> Nitro.Auth.decode_jwt(tok, secret; verify=v))
        @test (label, v, err isa Nitro.Auth.AuthError) == (label, v, true)
        # Pin the message, like every other assertion in this testset: `err isa AuthError`
        # alone is satisfied by any rejection, including one for the wrong reason.
        @test (label, v, occursin("Invalid JWT encoding", sprint(showerror, err))) == (label, v, true)
    end

    # The sharpest instance, and the one that is NOT length-independent: a well-formed
    # header and claims with a one-character signature segment. `_base64url_decode("x")`
    # pads to "x===", which `base64decode` refuses -- on the authenticated path. The
    # four-character case is the contrast that makes the point: it decodes fine and reaches
    # the comparison, so it was ALREADY a clean AuthError before this change (a pin), while
    # the one-character case escaped as ArgumentError (a guard).
    #
    # The two carry different messages on purpose. An undecodable signature is what a
    # TRUNCATED token looks like -- a cookie past the 4KB limit, a proxy trimming a header --
    # and sending the operator to check transport rather than key rotation is worth one word.
    for (sig, want) in (("x", "Invalid JWT signature encoding"), ("!!!!", "Invalid JWT signature"))
        err = caught(() -> Nitro.Auth.decode_jwt(string(good_header, ".", good_claims, ".", sig), secret))
        @test (sig, err isa Nitro.Auth.AuthError) == (sig, true)
        @test (sig, sprint(showerror, err)) == (sig, want)
    end

    # -- An empty keyset has nothing to fall back to. `first(keys(...))` raised a
    # BoundsError from inside `_resolve_kid`.
    kidless = Nitro.Auth.encode_jwt(payload, secret)
    err = caught(() -> Nitro.Auth.decode_jwt(kidless, Dict{String, String}()))
    @test err isa Nitro.Auth.AuthError
    @test occursin("Unknown JWT key id", sprint(showerror, err))

    # -- A valid kid still resolves, and a token signed under one key is not accepted
    # under another key's id. Also a pin on pre-existing behavior; it constrains the
    # kid -> secret mapping, which the alg gate sits directly upstream of.
    rotated = Nitro.Auth.encode_jwt(payload, keyset; kid="rotated")
    claims, kid = Nitro.Auth.decode_jwt(rotated, keyset; with_kid=true)
    @test (claims["sub"], kid) == ("42", "rotated")
    mislabeled = signed(Dict("alg" => "HS256", "typ" => "JWT", "kid" => "default"), payload; key = "secret-b")
    @test_throws Nitro.Auth.AuthError Nitro.Auth.decode_jwt(mislabeled, keyset)
end

@testset "kid-less tokens try every key in the keyset (#253)" begin
    caught(f) = try; f(); nothing; catch err; err; end
    NOW_TS = trunc(Int, time())
    payload = Dict("sub" => "42", "exp" => NOW_TS + 3600)
    keyset = Dict("default" => "secret-a", "rotated" => "secret-b")

    # -- The issue's own repro, inverted into an assertion. A foreign issuer's kid-less
    # token signed with the NON-default key used to be rejected as "Invalid JWT
    # signature" -- live for the whole of a rotation window, and with a diagnostic that
    # sent the operator to check the shared secret and clock skew.
    kidless_rotated = Nitro.Auth.encode_jwt(payload, "secret-b")
    claims, kid = Nitro.Auth.decode_jwt(kidless_rotated, keyset; with_kid=true)
    @test (claims["sub"], kid) == ("42", "rotated")

    # -- Ordering. These fixtures deliberately hold ONE secret under TWO names, because
    # that is the only shape in which trial order is observable: with distinct secrets
    # exactly one key can match and the assertion would pass under any order, pinning
    # nothing. `jwt_validator` refuses such a keyset at construction, so the fixture has
    # to go through `decode_jwt`, which has no construction time to refuse it at.
    #
    # Reverse the sort or move the "default" push to the end of `_verify_candidates` and
    # these two fail. Nothing else in this file does.
    @test Nitro.Auth.decode_jwt(kidless_rotated, Dict("zulu" => "secret-b", "alpha" => "secret-b");
                                with_kid=true)[2] == "alpha"      # sorted by name
    @test Nitro.Auth.decode_jwt(kidless_rotated, Dict("zebra" => "secret-b", "default" => "secret-b");
                                with_kid=true)[2] == "default"    # ... but "default" first

    # -- And the ordinary case still resolves: a kid-less token signed with the default key.
    kidless_default = Nitro.Auth.encode_jwt(payload, "secret-a")
    @test Nitro.Auth.decode_jwt(kidless_default, keyset; with_kid=true)[2] == "default"

    # -- The message names key selection ONLY when key selection was in play. One
    # candidate keeps the old wording byte for byte, so the overwhelmingly common
    # single-key and string-secret cases do not churn.
    for (label, key) in (("single-key keyset", Dict("only" => "secret-z")), ("string secret", "secret-z"))
        err = caught(() -> Nitro.Auth.decode_jwt(kidless_rotated, key))
        @test (label, sprint(showerror, err)) == (label, "Invalid JWT signature")
    end
    err = caught(() -> Nitro.Auth.decode_jwt(kidless_rotated, Dict("a" => "x", "b" => "y")))
    @test sprint(showerror, err) == "No key in the JWT keyset verified this token"

    # -- A token that NAMES its key gets that key and no other: no trial loop, so a
    # forged kid-bearing token still costs exactly one HMAC, and a token signed under
    # one key is still not accepted under another key's id.
    mislabeled = Nitro.Auth.encode_jwt(payload, Dict("default" => "secret-b"); kid="default")
    err = caught(() -> Nitro.Auth.decode_jwt(mislabeled, keyset))
    @test sprint(showerror, err) == "Invalid JWT signature"
    err = caught(() -> Nitro.Auth.decode_jwt(mislabeled, Dict("elsewhere" => "secret-b")))
    @test sprint(showerror, err) == "Unknown JWT key id"

    # -- Error ORDERING: candidates resolve before the signature is base64-decoded, so an
    # unknown kid is reported as such and not pre-empted by a signature that also happens
    # to be malformed. One token, two keysets, two different answers -- move the `provided`
    # decode above the candidate resolution in `decode_jwt` and the first line fails.
    parts = split(Nitro.Auth.encode_jwt(payload, keyset; kid="rotated"), '.')
    undecodable = string(parts[1], ".", parts[2], ".x")
    @test sprint(showerror, caught(() -> Nitro.Auth.decode_jwt(undecodable, Dict("elsewhere" => "s")))) ==
        "Unknown JWT key id"
    @test sprint(showerror, caught(() -> Nitro.Auth.decode_jwt(undecodable, keyset))) ==
        "Invalid JWT signature encoding"

    # -- Pins from #252 that the rewrite must not drop.
    err = caught(() -> Nitro.Auth.decode_jwt(kidless_rotated, Dict{String, String}()))
    @test sprint(showerror, err) == "Unknown JWT key id"
    @test_throws ArgumentError Nitro.Auth.decode_jwt(kidless_rotated, 42)

    # -- verify=false bypasses key selection entirely and passes the RAW header kid
    # through, unverified. `_verify_candidates` is never reached.
    labelled = Nitro.Auth.encode_jwt(payload, "secret-b"; kid="not-in-any-keyset")
    @test Nitro.Auth.decode_jwt(labelled, keyset; verify=false, with_kid=true)[2] == "not-in-any-keyset"

    # -- The principal reports the key that actually verified, which is what makes
    # `identity_from=:kid` honest for a kid-less token rather than a "default" guess.
    validator = Nitro.Auth.jwt_validator(keyset)
    @test validator(kidless_rotated).kid == "rotated"
    signer = Nitro.Auth.jwt_validator(keyset; identity_from=:kid)(kidless_rotated)
    @test (signer.id, signer.kid, signer.source) == ("rotated", "rotated", :kid)
end

@testset "jwt_validator refuses a keyset with duplicate secrets (#253)" begin
    caught(f) = try; f(); nothing; catch err; err; end
    # Trial order is only observable when two entries hold the SAME secret -- and then
    # the same token attributes to a different signer run to run. Refused at
    # construction, which is app startup, so at most one candidate can ever match.
    err = caught(() -> Nitro.Auth.jwt_validator(Dict("alpha" => "s", "bravo" => "s")))
    @test err isa ArgumentError
    msg = sprint(showerror, err)
    @test occursin("\"alpha\"", msg) && occursin("\"bravo\"", msg)

    # String equality is the WRONG equivalence: HMAC-SHA256 pre-hashes any key past its
    # 64-byte block, so `K` and `sha256(K)` are one key, and zero-padding makes `"a"` and
    # `"a\0"` one key. Both are textually distinct and both must still be refused --
    # otherwise a holder of one entry's secret authenticates as the other entry.
    long_key = repeat("abcdefghij", 10)
    @test caught(() -> Nitro.Auth.jwt_validator(
        Dict("long" => long_key, "short" => String(SHA.sha256(long_key))))) isa ArgumentError
    @test caught(() -> Nitro.Auth.jwt_validator(Dict("bare" => "a", "padded" => "a\0"))) isa ArgumentError

    # A keyset whose keys are neither String nor Symbol resolves to no name at all, so
    # every request would 401 with no startup signal. Refused at construction instead --
    # and with a named ArgumentError, not the MethodError this used to be.
    err = caught(() -> Nitro.Auth.jwt_validator(Dict(1 => "s1", 2 => "s2")))
    @test err isa ArgumentError
    @test occursin("none with a String or Symbol key", sprint(showerror, err))
    @test Nitro.Auth.jwt_validator(Dict(:alpha => "s1", :bravo => "s2")) isa Function

    # A `Vector{UInt8}` value is refused WITHOUT being read. `String(::Vector{UInt8})`
    # takes ownership and empties the buffer, so merely inspecting such a keyset would
    # blank every secret -- after which a token signed with "" authenticates as any kid.
    # The assertion that matters is the second one: the caller's bytes survive.
    bytes = Dict("prod" => Vector{UInt8}(codeunits("real-prod-secret")),
                 "old"  => Vector{UInt8}(codeunits("real-old-secret")))
    err = caught(() -> Nitro.Auth.jwt_validator(bytes))
    @test err isa ArgumentError
    @test all(!isempty, values(bytes))

    # Distinct secrets, a single-key keyset, and a plain string secret are unaffected.
    @test Nitro.Auth.jwt_validator(Dict("alpha" => "s1", "bravo" => "s2")) isa Function
    @test Nitro.Auth.jwt_validator(Dict("only" => "s")) isa Function
    @test Nitro.Auth.jwt_validator("s") isa Function
end

@testset "Password helpers" begin
    hash = Nitro.Auth.make_password("ValidPass1!")
    @test Nitro.Auth.check_password("ValidPass1!", hash)
    @test !Nitro.Auth.check_password("WrongPass1!", hash)

    bcrypt_hash = Nitro.Auth.make_password("ValidPass1!"; algorithm="bcrypt", bcrypt_cost=4)
    @test startswith(bcrypt_hash, "\$2")
    @test Nitro.Auth.check_password("ValidPass1!", bcrypt_hash)
    @test Nitro.Auth.check_password("ValidPass1!", string("{bcrypt}", bcrypt_hash))
    @test !Nitro.Auth.check_password("WrongPass1!", bcrypt_hash)

    validation = Nitro.Auth.validate_password("weak")
    @test !validation.valid
    @test !isempty(validation.errors)
end

@testset "Password Validation i18n" begin
    validator_en = PasswordValidator(min_length=8)
    result_en = validate(validator_en, "short")
    @test !result_en.valid
    @test result_en.errors[1] == "Password must be at least 8 characters long"

    pt_messages = Dict(
        :min_length => "A senha deve ter pelo menos %d caracteres",
        :require_uppercase => "A senha deve conter pelo menos uma letra maiúscula",
        :require_digit => "A senha deve conter pelo menos um número",
        :common_password => "Senha muito comum",
    )

    validator_pt = PasswordValidator(
        min_length=10,
        require_uppercase=true,
        require_digit=true,
        messages=pt_messages,
    )

    result_pt = validate(validator_pt, "senha")
    @test !result_pt.valid
    @test "A senha deve ter pelo menos 10 caracteres" in result_pt.errors
    @test "A senha deve conter pelo menos uma letra maiúscula" in result_pt.errors

    result_digit = validate(validator_pt, "SENHA CURTA")
    @test "A senha deve conter pelo menos um número" in result_digit.errors

    validator_common = PasswordValidator(messages=pt_messages)
    result_common = validate(validator_common, "password")
    @test "Senha muito comum" in result_common.errors
end

@testset "Partial Message Override" begin
    custom = Dict(:min_length => "Too short: %d")
    validator = PasswordValidator(min_length=8, require_digit=true, messages=custom)

    result = validate(validator, "abc")
    @test "Too short: 8" in result.errors
    @test "Password must contain at least one digit" in result.errors
end

@testset "High-level validate_password i18n" begin
    custom = Dict(:min_length => "Erro: %d")
    result = Nitro.Auth.validate_password("abc", min_length=12, messages=custom)

    @test !result.valid
    @test "Erro: 12" in result.errors
end

@testset "PBKDF2PasswordEncoder" begin
    pbkdf2 = PBKDF2PasswordEncoder()

    password = "test123!@#"
    hash = encode(pbkdf2, password)

    @test startswith(hash, "pbkdf2_sha256\$")
    @test contains(hash, "720000")
    @test matches(pbkdf2, password, hash) == true
    @test matches(pbkdf2, "wrong_password", hash) == false
    @test_throws ArgumentError encode(pbkdf2, "")

    pbkdf2_custom = PBKDF2PasswordEncoder(iterations=100000)
    hash_custom = encode(pbkdf2_custom, password)
    @test contains(hash_custom, "100000")
    @test matches(pbkdf2_custom, password, hash_custom) == true

    old_hash = "pbkdf2_sha256\$100000\$salt\$hash"
    @test matches(pbkdf2, "password", old_hash) == false
    @test upgrade_encoding(pbkdf2, old_hash) == true
end

@testset "BCryptPasswordEncoder" begin
    bcrypt = BCryptPasswordEncoder(cost=4)

    password = "test123!@#"
    hash = encode(bcrypt, password)

    @test startswith(hash, "\$2a\$") || startswith(hash, "\$2b\$") || startswith(hash, "\$2y\$")
    @test contains(hash, "04")
    @test matches(bcrypt, password, hash) == true
    @test matches(bcrypt, "wrong_password", hash) == false
    @test_throws ArgumentError encode(bcrypt, "")

    bcrypt_high = BCryptPasswordEncoder(cost=6)
    hash_high = encode(bcrypt_high, password)
    @test contains(hash_high, "06")
    @test matches(bcrypt_high, password, hash_high) == true

    @test_throws ArgumentError BCryptPasswordEncoder(cost=3)
    @test_throws ArgumentError BCryptPasswordEncoder(cost=32)

    long_password = repeat("a", 80)
    @test_logs (:warn, r"Password exceeds 72 bytes") encode(bcrypt, long_password)

    old_hash = "\$2a\$04\$somehash"
    bcrypt_new = BCryptPasswordEncoder(cost=6)
    @test upgrade_encoding(bcrypt_new, old_hash) == true
end

@testset "SpringSecurityPBKDF2PasswordEncoder" begin
    spring = SpringSecurityPBKDF2PasswordEncoder()

    password = "test123!@#"
    hash = encode(spring, password)

    @test startswith(hash, "sha256:")
    @test contains(hash, "310000")

    parts = split(hash, ':')
    @test length(parts) == 5
    @test parts[1] == "sha256"
    @test parts[3] == "32"

    @test matches(spring, password, hash) == true
    @test matches(spring, "wrong_password", hash) == false
    @test_throws ArgumentError encode(spring, "")

    spring_custom = SpringSecurityPBKDF2PasswordEncoder(iterations=64000)
    hash_custom = encode(spring_custom, password)
    @test contains(hash_custom, "64000")
    @test matches(spring_custom, password, hash_custom) == true

    old_hash = "sha256:64000:32:salt:hash"
    @test upgrade_encoding(spring, old_hash) == true

    spring_hash = "sha256:64000:32:gexlBXpu2dKK1BvW2jw8+XZAo99/g9d7:aPXcE36dbNMo0ssJV0QGiX6/r4jHu8HUfvElVQB5erA="
    @test !matches(spring, "wrong_password", spring_hash)
end

@testset "DelegatingPasswordEncoder" begin
    delegating = DelegatingPasswordEncoder()

    password = "test123!@#"

    hash = encode(delegating, password)
    @test startswith(hash, "pbkdf2_sha256\$")
    @test matches(delegating, password, hash) == true

    pbkdf2 = PBKDF2PasswordEncoder()
    pbkdf2_hash = encode(pbkdf2, password)
    @test matches(delegating, password, pbkdf2_hash) == true

    bcrypt = BCryptPasswordEncoder(cost=4)
    bcrypt_hash = encode(bcrypt, password)
    @test matches(delegating, password, bcrypt_hash) == true

    spring = SpringSecurityPBKDF2PasswordEncoder(iterations=64000)
    spring_hash = encode(spring, password)
    @test matches(delegating, password, spring_hash) == true

    @test matches(delegating, "wrong", pbkdf2_hash) == false
    @test matches(delegating, "wrong", bcrypt_hash) == false

    delegating_bcrypt = DelegatingPasswordEncoder(default_algorithm="bcrypt", bcrypt_cost=4)
    hash_bcrypt = encode(delegating_bcrypt, password)
    @test startswith(hash_bcrypt, "\$2a\$") || startswith(hash_bcrypt, "\$2b\$") || startswith(hash_bcrypt, "\$2y\$")
    @test matches(delegating_bcrypt, password, hash_bcrypt) == true

    @test upgrade_encoding(delegating, pbkdf2_hash) == false

    # An unrecognized hash format must never authenticate via a plaintext
    # comparison: it warns and returns false (no plaintext fallback).
    plain_text = "password123"
    @test_logs (:warn, r"Unknown or unsupported password hash format") matches(delegating, plain_text, plain_text)
    @test matches(delegating, plain_text, plain_text) == false
end

@testset "Cross-Encoder Compatibility" begin
    password = "mySecurePassword!@#"

    pbkdf2 = PBKDF2PasswordEncoder()
    bcrypt = BCryptPasswordEncoder(cost=4)
    spring = SpringSecurityPBKDF2PasswordEncoder(iterations=64000)
    delegating = DelegatingPasswordEncoder()

    pbkdf2_hash = encode(pbkdf2, password)
    bcrypt_hash = encode(bcrypt, password)
    spring_hash = encode(spring, password)

    @test matches(delegating, password, pbkdf2_hash)
    @test matches(delegating, password, bcrypt_hash)
    @test matches(delegating, password, spring_hash)
    @test !matches(delegating, "wrong", pbkdf2_hash)
    @test !matches(delegating, "wrong", bcrypt_hash)
    @test !matches(delegating, "wrong", spring_hash)
end

@testset "Validator factories" begin
    token = Nitro.Auth.encode_jwt(Dict("sub" => "9", "exp" => NOW_TS + 3600), "secret-a")
    validator = Nitro.Auth.jwt_validator("secret-a")
    claims = validator(token)
    @test claims["sub"] == "9"

    store = Nitro.Types.MemoryStore{String, Dict{String,Any}}()
    Nitro.Types.set_session!(store, "sess-1", Dict{String,Any}("user" => Dict("id" => 5)); ttl=60)
    session_validator = Nitro.Auth.session_user_validator(store)
    @test session_validator("sess-1")["id"] == 5
    # The optional second argument is the middleware arity-dispatch slot; an HTTP.Request
    # there must not be mistaken for session data.
    @test session_validator("sess-1", HTTP.Request("GET", "/"))["id"] == 5
end

@testset "jwt_validator identity and profiles" begin
    keyset = Dict("service-a" => "secret-a", "service-b" => "secret-b")

    @testset "returns a normalized Principal" begin
        validator = Nitro.Auth.jwt_validator("secret-a")
        principal = validator(Nitro.Auth.encode_jwt(Dict("sub" => 9, "role" => "admin"), "secret-a"; expires_in=3600))
        @test principal isa Nitro.Principal
        @test principal.id == "9"            # default identity claim "sub", stringified
        @test principal.source === :claim
        @test principal["role"] == "admin"   # claims read through

        # A token without the identity claim still authenticates (service tokens)
        subless = validator(Nitro.Auth.encode_jwt(Dict("action" => "sync"), "secret-a"; expires_in=3600))
        @test subless isa Nitro.Principal
        @test subless.id === nothing
        @test subless["action"] == "sync"

        # Custom identity claim
        action_validator = Nitro.Auth.jwt_validator("secret-a"; identity_claim="action")
        @test action_validator(Nitro.Auth.encode_jwt(Dict("action" => "sync"), "secret-a"; expires_in=3600)).id == "sync"
    end

    @testset "kid trust model" begin
        # Keyset-verified kid is exposed on the principal
        keyset_validator = Nitro.Auth.jwt_validator(keyset)
        principal = keyset_validator(Nitro.Auth.encode_jwt(Dict("sub" => "9"), keyset; kid="service-b", expires_in=3600))
        @test principal.kid == "service-b"
        @test principal.id == "9"

        # identity_from=:kid — the verified signer is the principal
        kid_validator = Nitro.Auth.jwt_validator(keyset; identity_from=:kid)
        signer = kid_validator(Nitro.Auth.encode_jwt(Dict("action" => "sync"), keyset; kid="service-a", expires_in=3600))
        @test signer.id == "service-a"
        @test signer.kid == "service-a"
        @test signer.source === :kid

        # A kid header on a SINGLE-SECRET token is an unverified label → never exposed
        single_validator = Nitro.Auth.jwt_validator("secret-a")
        spoofable = single_validator(Nitro.Auth.encode_jwt(Dict("sub" => "9"), "secret-a"; expires_in=3600))
        @test spoofable.kid === nothing
    end

    @testset "user_validator receives the Principal, tuple carries it" begin
        seen = Ref{Any}(nothing)
        validator = Nitro.Auth.jwt_validator(keyset;
            user_validator = principal -> (seen[] = principal; Dict("uid" => principal.id)))
        result = validator(Nitro.Auth.encode_jwt(Dict("sub" => "7"), keyset; kid="service-a", expires_in=3600))
        @test seen[] isa Nitro.Principal
        @test seen[]["sub"] == "7"           # dict-compatible with old claims-style validators
        @test result isa Tuple && length(result) == 2
        @test result[1] == Dict("uid" => "7")
        @test result[2] isa Nitro.Principal  # normalized artifact rides in the tuple
        @test result[2].kid == "service-a"

        # A rejecting user_validator still yields nothing
        rejecting = Nitro.Auth.jwt_validator(keyset; user_validator = _ -> nothing)
        @test rejecting(Nitro.Auth.encode_jwt(Dict("sub" => "7"), keyset; expires_in=3600)) === nothing
    end

    @testset "construction-time validation" begin
        @test_throws ArgumentError Nitro.Auth.jwt_validator("secret-a"; identity_from=:header)
        @test_throws ArgumentError Nitro.Auth.jwt_validator("secret-a"; profile=:lenient)
        @test_throws ArgumentError Nitro.Auth.jwt_validator("secret-a"; with_kid=true)
        # Signature verification can never be disabled through the validator — otherwise a
        # forged token (with an attacker-chosen kid) would authenticate and pass kid_required.
        @test_throws ArgumentError Nitro.Auth.jwt_validator("secret-a"; verify=false)
        @test_throws ArgumentError Nitro.Auth.jwt_validator(keyset; verify=false)
        @test_throws ArgumentError Nitro.Auth.jwt_validator("secret-a"; profile=:strict, issuer="iss", audience="aud", verify=false)
        # :kid identity requires a keyset — a header kid is unverified against one secret
        @test_throws ArgumentError Nitro.Auth.jwt_validator("secret-a"; identity_from=:kid)
        # :strict demands issuer + audience and forbids weakening require_exp
        @test_throws ArgumentError Nitro.Auth.jwt_validator("secret-a"; profile=:strict)
        @test_throws ArgumentError Nitro.Auth.jwt_validator("secret-a"; profile=:strict, issuer="iss")
        @test_throws ArgumentError Nitro.Auth.jwt_validator("secret-a"; profile=:strict, issuer="iss", audience="aud", require_exp=false)
    end

    @testset "strict profile" begin
        strict = Nitro.Auth.jwt_validator("secret-a"; profile=:strict, issuer="iss", audience="aud", required_claims=["sub"])
        good = Nitro.Auth.encode_jwt(Dict("sub" => "1", "iss" => "iss", "aud" => "aud"), "secret-a"; expires_in=3600)
        @test strict(good).id == "1"

        # Missing exp is rejected (require_exp forced)
        no_exp = Nitro.Auth.encode_jwt(Dict("sub" => "1", "iss" => "iss", "aud" => "aud"), "secret-a")
        @test_throws Nitro.Auth.AuthError strict(no_exp)
        # Wrong issuer/audience rejected
        wrong_iss = Nitro.Auth.encode_jwt(Dict("sub" => "1", "iss" => "other", "aud" => "aud"), "secret-a"; expires_in=3600)
        @test_throws Nitro.Auth.AuthError strict(wrong_iss)
        # required_claims enforced
        no_sub = Nitro.Auth.encode_jwt(Dict("iss" => "iss", "aud" => "aud"), "secret-a"; expires_in=3600)
        @test_throws Nitro.Auth.AuthError strict(no_sub)
    end
end

@testset "SUPPORTED_ALGORITHMS constant" begin
    @test "pbkdf2_sha256" in SUPPORTED_ALGORITHMS
    @test "bcrypt" in SUPPORTED_ALGORITHMS
    @test "spring_sha256" in SUPPORTED_ALGORITHMS
end

@testset "set_default_algorithm! and DEFAULT_ALGORITHM" begin
    # Save original
    original = DEFAULT_ALGORITHM()
    @test original == "pbkdf2_sha256"

    # Switch to bcrypt
    set_default_algorithm!("bcrypt")
    @test DEFAULT_ALGORITHM() == "bcrypt"

    # make_password should now use bcrypt by default
    hash = Nitro.Auth.make_password("TestBcrypt1!")
    @test startswith(hash, "\$2a\$") || startswith(hash, "\$2b\$") || startswith(hash, "\$2y\$")

    # Switch to spring
    set_default_algorithm!("spring_sha256")
    @test DEFAULT_ALGORITHM() == "spring_sha256"
    hash_spring = Nitro.Auth.make_password("TestSpring1!")
    @test startswith(hash_spring, "sha256:")

    # Unsupported algorithm throws
    @test_throws ArgumentError set_default_algorithm!("argon2")
    @test_throws ArgumentError set_default_algorithm!("md5")

    # Restore original
    set_default_algorithm!("pbkdf2_sha256")
    @test DEFAULT_ALGORITHM() == "pbkdf2_sha256"
end

@testset "is_password_usable" begin
    # PBKDF2 Django format
    @test is_password_usable("pbkdf2_sha256\$720000\$salt\$hash")
    # BCrypt formats
    @test is_password_usable("\$2a\$12\$somehashvalue")
    @test is_password_usable("\$2b\$12\$somehashvalue")
    @test is_password_usable("\$2y\$12\$somehashvalue")
    # Spring Security format
    @test is_password_usable("sha256:310000:32:salt:hash")
    # Argon2 (future)
    @test is_password_usable("\$argon2id\$v=19\$m=65536,t=3,p=4\$salt\$hash")
    # Not usable
    @test !is_password_usable("")
    @test !is_password_usable("   ")
    @test !is_password_usable("plaintext_password")
    @test !is_password_usable("random_string_123")
end

@testset "Static cross-compatibility: Django 4.2 PBKDF2 fixture" begin
    # Hash in Django 4.2+ wire format (pbkdf2_sha256$iterations$salt$hash) for password "testpassword123"
    # Generated by Nitro.Auth.make_password which produces bitwise-identical format to Django.
    # To obtain a fixture from a real Django instance:
    #   python -c "from django.contrib.auth.hashers import make_password; print(make_password('testpassword123'))"
    django_hash = "pbkdf2_sha256\$720000\$IWFIz8pz6UvjQjqAsOmiD1\$eL/VlH4lhj0BOLkc3X1Hg/fpa9z/bfzNpTRHMckBlB8="
    @test Nitro.Auth.check_password("testpassword123", django_hash)
    @test !Nitro.Auth.check_password("wrongpassword", django_hash)
end

@testset "Static cross-compatibility: Spring Security 6.x PBKDF2 fixture" begin
    # Hash in Spring Security 6.x wire format (sha256:iterations:key_length:salt_b64:hash_b64)
    # for password "testpassword123". Generated by Nitro.Auth.make_password which produces
    # bitwise-identical format to Spring Security's Pbkdf2PasswordEncoder.
    spring_hash = "sha256:310000:32:ETRF/dCZk2LLCLnc7fcTbz72+/+ygPbH:IZhBZHPAmrOpp3oTWgm11QWsg8JkU2mPR1AQjdXDpq4="
    @test Nitro.Auth.check_password("testpassword123", spring_hash)
    @test !Nitro.Auth.check_password("wrongpassword", spring_hash)
end

@testset "Round-trip make_password / check_password all algorithms" begin
    password = "R0und!Trip_Test#2024"

    # PBKDF2 round-trip
    pbkdf2_hash = Nitro.Auth.make_password(password; algorithm="pbkdf2_sha256")
    @test startswith(pbkdf2_hash, "pbkdf2_sha256\$")
    @test Nitro.Auth.check_password(password, pbkdf2_hash)
    @test !Nitro.Auth.check_password("wrong", pbkdf2_hash)
    @test is_password_usable(pbkdf2_hash)

    # BCrypt round-trip
    bcrypt_hash = Nitro.Auth.make_password(password; algorithm="bcrypt", bcrypt_cost=4)
    @test startswith(bcrypt_hash, "\$2")
    @test Nitro.Auth.check_password(password, bcrypt_hash)
    @test !Nitro.Auth.check_password("wrong", bcrypt_hash)
    @test is_password_usable(bcrypt_hash)

    # Spring Security round-trip
    spring_hash = Nitro.Auth.make_password(password; algorithm="spring_sha256")
    @test startswith(spring_hash, "sha256:")
    @test Nitro.Auth.check_password(password, spring_hash)
    @test !Nitro.Auth.check_password("wrong", spring_hash)
    @test is_password_usable(spring_hash)
end

@testset "password_needs_upgrade detects old iterations" begin
    # Make with lower iterations — should be flagged as needing upgrade
    old_hash = Nitro.Auth.make_password("upgrade_me"; algorithm="pbkdf2_sha256", iterations=100000)
    @test Nitro.Auth.password_needs_upgrade(old_hash; min_iterations=720000)

    # Make with current iterations — should NOT need upgrade
    current_hash = Nitro.Auth.make_password("no_upgrade"; algorithm="pbkdf2_sha256", iterations=720000)
    @test !Nitro.Auth.password_needs_upgrade(current_hash; min_iterations=720000)

    # BCrypt with lower cost — should need upgrade
    bcrypt_low = Nitro.Auth.make_password("upgrade_bcrypt"; algorithm="bcrypt", bcrypt_cost=4)
    @test Nitro.Auth.password_needs_upgrade(bcrypt_low)

    # Spring with lower iterations — should need upgrade
    spring_low = Nitro.Auth.make_password("upgrade_spring"; algorithm="spring_sha256", iterations=64000)
    @test Nitro.Auth.password_needs_upgrade(spring_low)
end

@testset "Idempotency: already-encoded hash passes through check_password" begin
    raw = "MyP@ssw0rd!"
    hash = Nitro.Auth.make_password(raw)
    # Verify the hash itself — this is the core idempotency concern for the extension
    @test is_password_usable(hash)
    @test Nitro.Auth.check_password(raw, hash)
    # Re-hashing an already-encoded hash produces a different hash (not idempotent by design)
    rehash = Nitro.Auth.make_password(hash)
    @test rehash != hash
    # But is_password_usable can detect both as encoded
    @test is_password_usable(rehash)
end

end
