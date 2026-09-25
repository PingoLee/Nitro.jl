@testitem "JWTKeyset (#260)" tags=[:auth, :core] setup=[NitroCommon] begin

using Test
using JSON
using Nitro
using Nitro.Auth: JWTKeyset, encode_jwt, decode_jwt, jwt_validator

caught(f) = try; f(); nothing; catch err; err; end
message(f) = sprint(showerror, caught(f))
kids(ks::JWTKeyset) = [kid for (kid, _) in Nitro.Auth._verify_candidates(ks, nothing)]
header_kid(tok) = get(
    JSON.parse(String(Nitro.Crypto.base64url_decode(split(tok, '.')[1]))), "kid", nothing)

@testset "exactly one signing key, by construction" begin
    ks = JWTKeyset("current" => jwtkey("s-cur"); verify = ["previous" => jwtkey("s-prev"), "partner" => jwtkey("s-part")])
    # The signing key first, then the rest by kid -- the kid-less trial order.
    @test kids(ks) == ["current", "partner", "previous"]
    @test header_kid(encode_jwt(Dict("sub" => "1"), ks)) == "current"
    # A verify-only key verifies; it just never signs.
    as_previous = encode_jwt(Dict("sub" => "1"), JWTKeyset("previous" => jwtkey("s-prev")))
    @test decode_jwt(as_previous, ks; with_kid = true)[2] == "previous"

    # Symbol kids and SecretString values are accepted, and a keyset is idempotent.
    mixed = JWTKeyset(:current => SecretString(jwtkey("s-cur")); verify = [:old => SecretString(jwtkey("s-old"))])
    @test kids(mixed) == ["current", "old"]
    @test JWTKeyset(mixed) === mixed
end

@testset "the constructor owns the value contract" begin
    for (label, build, needle) in (
            ("duplicate kid", () -> JWTKeyset("a" => jwtkey("s1"); verify = ["a" => jwtkey("s2")]), "more than once"),
            ("signer kid reused", () -> JWTKeyset("a" => jwtkey("s1"); verify = [:a => jwtkey("s2")]), "more than once"),
            ("same HMAC key", () -> JWTKeyset("a" => jwtkey("s"); verify = ["b" => jwtkey("s")]), "same HMAC key"),
            ("zero-padded twin", () -> JWTKeyset("a" => jwtkey("k"); verify = ["b" => jwtkey("k") * "\0"]), "same HMAC key"),
            ("empty secret", () -> JWTKeyset("a" => ""), "empty"),
            # HMAC zero-pads a short key, so NULs are the empty key under another spelling.
            ("NUL secret", () -> JWTKeyset("a" => "\0"), "equivalent to the empty HMAC key"),
            ("NUL verify secret", () -> JWTKeyset("a" => jwtkey("s"); verify = ["b" => "\0\0\0"]), "empty"),
            ("empty kid", () -> JWTKeyset("" => jwtkey("s")), "must not be empty"),
            ("integer kid", () -> JWTKeyset(1 => jwtkey("s")), "String or Symbol"),
            ("integer secret", () -> JWTKeyset("a" => 42), "Int64"),
            ("verify not pairs", () -> JWTKeyset("a" => jwtkey("s"); verify = ["b"]), "kid => secret pairs"),
            # RFC 7518 §3.2 (#321): the floor holds for verify-only keys too.
            ("short secret", () -> JWTKeyset("a" => "k"^31), "31 bytes"),
            ("short verify secret", () -> JWTKeyset("a" => jwtkey("s"); verify = ["b" => "k"^31]), "31 bytes"))
        err = caught(build)
        @test (label, err isa ArgumentError) == (label, true)
        @test (label, occursin(needle, sprint(showerror, err))) == (label, true)
    end

    # The byte-vector trap: refused BEFORE it is read, so the caller's buffer survives.
    # `String(::Vector{UInt8})` would have taken ownership and emptied it.
    secret = Vector{UInt8}(codeunits("real-secret"))
    @test caught(() -> JWTKeyset("a" => secret)) isa ArgumentError
    @test secret == codeunits("real-secret")
    # ... and the message never echoes the value.
    @test !occursin("real-secret", message(() -> JWTKeyset("a" => secret)))
end

@testset "lifting a Dict" begin
    @test kids(JWTKeyset(Dict("default" => jwtkey("s1"), "zed" => jwtkey("s2"), "alpha" => jwtkey("s3")))) ==
        ["default", "alpha", "zed"]
    @test kids(JWTKeyset(Dict("only" => jwtkey("s1")))) == ["only"]
    @test kids(JWTKeyset(Dict(:default => jwtkey("s1"), :other => jwtkey("s2")))) == ["default", "other"]
    @test kids(JWTKeyset(Dict("default" => SecretString(jwtkey("s1"))))) == ["default"]

    # A Symbol-keyed Dict resolves a String header kid end to end -- the job the deleted
    # `_lookup_key`'s `Symbol(kid)` fallback used to do, now done once by the lift.
    symbolic = Dict(:default => jwtkey("s1"), :other => jwtkey("s2"))
    as_other = encode_jwt(Dict("sub" => "1"), JWTKeyset(:other => jwtkey("s2")))
    @test header_kid(as_other) == "other"
    @test decode_jwt(as_other, symbolic; with_kid = true)[2] == "other"
    @test jwt_validator(symbolic; identity_from = :kid)(as_other).kid == "other"

    msg = message(() -> JWTKeyset(Dict("primary" => jwtkey("s1"), "rotated" => jwtkey("s2"))))
    @test occursin("no \"default\"", msg) && occursin("JWTKeyset(", msg)
    @test occursin("empty", message(() -> JWTKeyset(Dict{String, String}())))
    # "a" and :a would have been one name, the String silently shadowing the Symbol.
    @test occursin("both", message(() -> JWTKeyset(Dict{Any, String}("a" => jwtkey("s1"), :a => jwtkey("s2")))))
    @test occursin("String or Symbol", message(() -> JWTKeyset(Dict(1 => jwtkey("s1")))))
end

@testset "display never carries a secret" begin
    RAW = "NITRO-RAW-KEYSET-SECRET-9f3c-4e1a"
    ks = JWTKeyset("current" => RAW; verify = ["previous" => SecretString(RAW * "-old")])
    for rendered in (sprint(show, ks),
                     sprint((io, x) -> show(io, MIME("text/plain"), x), ks),
                     repr(ks),
                     string(ks),
                     "interpolated: $ks",
                     JSON.json(ks),
                     JSON.json(Dict("auth" => ks)),
                     sprint(show, ks.keys[1]))
        @test !occursin(RAW, rendered)
    end
    @test sprint(show, ks) == "JWTKeyset(sign=\"current\", verify=[\"previous\"])"
    @test JSON.parse(JSON.json(ks)) == Dict("sign" => "current", "verify" => ["previous"])
end

@testset "a direct decode_jwt gets the same checks as jwt_validator" begin
    token = encode_jwt(Dict("sub" => "1"), jwtkey("s"))
    # Two names for one HMAC key used to slip past a direct `decode_jwt` caller, which
    # has no construction time -- the lift gives it one.
    @test caught(() -> decode_jwt(token, Dict("default" => jwtkey("s"), "twin" => jwtkey("s")))) isa ArgumentError
    bytes = Dict("default" => Vector{UInt8}(codeunits("real-prod-secret")))
    @test caught(() -> decode_jwt(token, bytes)) isa ArgumentError
    @test bytes["default"] == codeunits("real-prod-secret")
end

@testset "a plain string secret is held to the keyset's empty-key rule (#264)" begin
    # The predicate is HMAC's own equivalence, checked against HMAC itself: NULs up to the
    # 64-byte block are zero-padded into the empty key; a longer key is hashed first.
    oracle(s) = Nitro.Auth._hmac_fingerprint(SecretString(s)) ==
        Nitro.Auth.SHA.hmac_sha256(UInt8[], UInt8[])
    # The predicate lives in `Crypto` (#269) so the CSRF middleware, below `Auth`, shares it.
    empty_key = Nitro.Core.Crypto._empty_hmac_key
    @test Nitro.Auth._empty_hmac_key === empty_key
    for s in ("", "\0", "\0\0\0", "\0"^64, "\0"^65, "a", "a\0", "\0a", "\0"^63 * "a")
        @test (repr(s), empty_key(s)) == (repr(s), oracle(s))
    end
    @test empty_key("\0"^64)
    @test !empty_key("\0"^65)

    # The forged token an attacker builds when the server's secret is "" -- by hand,
    # because `encode_jwt` now refuses to sign it.
    function forge_with_empty_key(claims)
        seg(x) = Nitro.Crypto.base64url_encode(Vector{UInt8}(codeunits(JSON.json(x))))
        input = string(seg(Dict("alg" => "HS256", "typ" => "JWT")), ".", seg(claims))
        sig = Nitro.Crypto.base64url_encode(Nitro.Auth._hmac_sha256("", input))
        return string(input, ".", sig)
    end
    forged = forge_with_empty_key(Dict("sub" => "admin", "exp" => Nitro.Auth._current_timestamp() + 60))

    # The reported shape: `jwt_validator(get(ENV, "JWT_SECRET", ""))` used to return a
    # Principal for `forged`. Now there is no validator to ask.
    for secret in ("", "\0", "\0\0", SubString("x\0\0", 2))
        @test (repr(secret), caught(() -> jwt_validator(secret)) isa ArgumentError) == (repr(secret), true)
        @test (repr(secret), caught(() -> decode_jwt(forged, secret)) isa ArgumentError) == (repr(secret), true)
        @test (repr(secret), caught(() -> encode_jwt(Dict("sub" => "x"), secret)) isa ArgumentError) ==
            (repr(secret), true)
    end
    @test occursin("empty HMAC key", message(() -> jwt_validator("")))
    @test occursin("JWT_SECRET", message(() -> jwt_validator("")))
    # A real secret is untouched, and a forged token still fails its signature against it.
    @test jwt_validator(jwtkey("s1"))(encode_jwt(Dict("sub" => "1"), jwtkey("s1"); expires_in = 60)).id == "1"
    @test occursin("Invalid JWT signature", message(() -> jwt_validator(jwtkey("s1"))(forged)))
    # The message never echoes the value. Asserted as the exact fixed text, because a
    # `repr(secret)` regression would escape the NULs to `\\0` and slip past a
    # `!occursin("\0", ...)` check.
    @test message(() -> jwt_validator("\0\0")) ==
        "ArgumentError: " * Nitro.Auth._EMPTY_SECRET_MESSAGE
end

@testset "an HS256 key is at least 32 bytes, everywhere a key enters (#321)" begin
    @test Nitro.Auth.MIN_JWT_SECRET_BYTES == 32
    weak = "correct-horse-battery-staple-31"      # 31 bytes: one short
    @test ncodeunits(weak) == 31
    strong = weak * "!"                           # 32 bytes: exactly enough
    signed = encode_jwt(Dict("sub" => "1"), strong; expires_in = 60)

    for (label, f) in (
            ("jwt_validator(string)", () -> jwt_validator(weak)),
            ("jwt_validator(Dict)", () -> jwt_validator(Dict("default" => weak))),
            ("JWTKeyset", () -> JWTKeyset("current" => weak)),
            ("JWTKeyset(SecretString)", () -> JWTKeyset("current" => SecretString(weak))),
            ("encode_jwt", () -> encode_jwt(Dict("sub" => "1"), weak)),
            # The direct-caller path has no construction time; it is checked per call.
            ("decode_jwt", () -> decode_jwt(signed, weak)))
        err = caught(f)
        @test (label, err isa ArgumentError) == (label, true)
        text = sprint(showerror, err)
        @test (label, occursin("31 bytes", text) && occursin("RFC 7518", text)) == (label, true)
        # The message names the length, never the value.
        @test (label, occursin(weak, text)) == (label, false)
    end

    # Exactly 32 bytes is accepted on every path.
    @test jwt_validator(strong)(signed).id == "1"
    @test decode_jwt(signed, strong)["sub"] == "1"
    @test decode_jwt(encode_jwt(Dict("sub" => "1"), JWTKeyset("k" => strong)), Dict("k" => strong))["sub"] == "1"

    # The length is counted in BYTES, as HMAC sees the key: 11 three-byte characters is 33.
    @test jwt_validator("€"^11) isa Function
    @test caught(() -> jwt_validator("€"^10)) isa ArgumentError

    # An empty-equivalent key keeps its own, more specific message: 40 NULs is long enough
    # but is still the empty HMAC key, and an unset env var is still named as the cause.
    @test occursin("empty HMAC key", message(() -> jwt_validator("\0"^40)))
    @test occursin("JWT_SECRET", message(() -> jwt_validator("")))
end

@testset "signing as a peer of a registry" begin
    # The client-registry shape: permanent identities, none of them "retiring".
    registry = JWTKeyset("self" => jwtkey("s-self"); verify = ["reporting" => jwtkey("s-rep"), "batch" => jwtkey("s-batch")])
    validator = jwt_validator(registry; identity_from = :kid)
    # A peer signs with a one-key keyset whose signing key is its own identity.
    as_batch = encode_jwt(Dict("action" => "sync"), JWTKeyset("batch" => jwtkey("s-batch")); expires_in = 60)
    @test header_kid(as_batch) == "batch"
    principal = validator(as_batch)
    @test (principal.id, principal.kid, principal.source) == ("batch", "batch", :kid)
    # And a kid-less token from the same peer resolves to the key that verified it.
    kidless = encode_jwt(Dict("action" => "sync"), jwtkey("s-batch"); expires_in = 60)
    @test validator(kidless).kid == "batch"
end

@testset "jwt_validator lifts a Dict once, and keeps the snapshot" begin
    keymap = Dict("default" => jwtkey("s1"), "old" => jwtkey("s2"))
    validator = jwt_validator(keymap; identity_from = :kid)
    token = encode_jwt(Dict("sub" => "1"), JWTKeyset("old" => jwtkey("s2")); expires_in = 60)
    @test validator(token).kid == "old"
    # Mutating the caller's Dict no longer changes what a running validator accepts: the
    # construction-time checks could never have seen the mutation.
    delete!(keymap, "old")
    keymap["intruder"] = jwtkey("s2")
    @test validator(token).kid == "old"
    intruder = encode_jwt(Dict("sub" => "1"), JWTKeyset("intruder" => jwtkey("s2")); expires_in = 60)
    @test occursin("Unknown JWT key id", message(() -> validator(intruder)))

    # Misconfiguration is a construction-time error, which is app startup.
    @test caught(() -> jwt_validator(Dict("a" => jwtkey("s1"), "b" => jwtkey("s2")))) isa ArgumentError
    @test caught(() -> jwt_validator(42)) isa ArgumentError
end

@testset "the verify path is type-stable (nitro-core §7)" begin
    ks = JWTKeyset("current" => jwtkey("s1"); verify = ["previous" => jwtkey("s2")])
    T = Vector{Tuple{Nullable{String}, String}}
    @test (@inferred Nitro.Auth._verify_candidates(ks, nothing)) isa T
    @test (@inferred Nitro.Auth._verify_candidates(ks, "previous")) isa T
    @test (@inferred Nitro.Auth._verify_candidates(jwtkey("s1"), "label")) isa T
    @test (@inferred Nitro.Auth._signing_secret(ks)) == (jwtkey("s1"), "current")
    @test (@inferred Nitro.Auth._signing_secret(jwtkey("s1"))) == (jwtkey("s1"), nothing)

    # `_decode_jwt` is what the validator calls: one tuple shape, no `with_kid` Union (#265),
    # and a CONCRETE claims container (#274). This allowed type used to be
    # `Tuple{AbstractDict, …}`, which admitted the abstract inference it was meant to catch.
    DT = Tuple{Dict{String, Any}, Nullable{String}}
    token = encode_jwt(Dict("sub" => "1"), ks; expires_in = 60)
    @test (@inferred DT Nitro.Auth._decode_jwt(token, jwtkey("s1"))) isa DT
    @test (@inferred DT Nitro.Auth._decode_jwt(token, ks)) isa DT
    @test decode_jwt(token, ks; with_kid = true) == Nitro.Auth._decode_jwt(token, ks)
    @test decode_jwt(token, ks) == first(Nitro.Auth._decode_jwt(token, ks))
end

@testset "decode_jwt returns Dict{String, Any} claims, nested objects included (#274)" begin
    ks = JWTKeyset("current" => jwtkey("s1"))
    token = encode_jwt(Dict("sub" => "1", "ctx" => Dict("tenant" => "t1"),
        "roles" => [Dict("name" => "admin")]), ks; expires_in = 60)
    claims = decode_jwt(token, ks)
    @test claims isa Dict{String, Any}
    @test claims["ctx"] isa Dict{String, Any}
    @test claims["ctx"]["tenant"] == "t1"
    @test only(claims["roles"]) isa Dict{String, Any}
    # String keys only: the Symbol lookups `JSON.Object` answered are gone. The upgrade
    # entry names this as the migration.
    @test !haskey(claims, :sub)
    @test decode_jwt(token, ks; verify = false) isa Dict{String, Any}

    # Through `jwt_validator`, nested claim objects change type too -- the one-level-down
    # half of the upgrade entry. (`Principal.claims` was already a `Dict`.)
    @test jwt_validator(ks)(token)["ctx"] isa Dict{String, Any}

    # The Symbol-free `_claim_value` is a pure performance method: it infers `Any` exactly as
    # the generic one does, so nothing else would notice it going missing.
    @test which(Nitro.Auth._claim_value, (Dict{String, Any}, String, Nothing)).sig.parameters[2] ===
        Dict{String, Any}
end

@testset "the jwt_validator closure is unboxed on every profile (#265)" begin
    ks = JWTKeyset("current" => jwtkey("s1"))
    token = encode_jwt(Dict("sub" => "1", "iss" => "i", "aud" => "a"), ks; expires_in = 60)
    for (label, v) in (
            ("default", jwt_validator(jwtkey("s1"))),
            ("keyset", jwt_validator(ks; identity_from = :kid)),
            ("strict", jwt_validator(ks; profile = :strict, issuer = "i", audience = "a")),
            ("warn_claims", jwt_validator(ks; warn_claims = ["iss"])))
        # A captured variable reassigned anywhere in `jwt_validator` becomes a `Core.Box`,
        # and every request then dispatched `decode_jwt` dynamically.
        @test (label, any(T -> T === Core.Box, fieldtypes(typeof(v)))) == (label, false)
        # And no local of the per-request body is `Any` -- `claims`, `kid` and the
        # `warn_claims` `iss` all were.
        ci = only(code_typed(v, (String, Nothing); optimize = false)).first
        @test (label, filter(T -> T === Any, ci.slottypes)) == (label, [])
        # And `claims` itself is concrete, so `validate_claims`, `_claim_value` and
        # `Principal` specialize rather than dispatch per request (#274).
        @test (label, ci.slottypes[findfirst(==(:claims), ci.slotnames)]) == (label, Dict{String, Any})
        @test (label, v(token).kid) == (label, label == "default" ? nothing : "current")
    end
end

end
