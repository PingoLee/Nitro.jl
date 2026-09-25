@testitem "JWTKeyset (#260)" tags=[:auth, :core] setup=[NitroCommon] begin

using Test
using JSON
using HTTP
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

@testset "a scoped key asserts only what its scope allows (#349)" begin
    # The issue's shape: a registry partner that may say who it is and what it does, and may
    # be a reader -- never an admin, and never anyone it likes under identity_from=:claim.
    registry = JWTKeyset("self" => jwtkey("s-self");
        verify = ["partner" => jwtkey("s-part"), "rotated" => jwtkey("s-old")],
        claims = Dict("partner" => ["sub", "action", "role" => ["reader"], :permissions => ("read", "list")]))
    as_partner(claims) = encode_jwt(claims, JWTKeyset("partner" => jwtkey("s-part")); expires_in = 60)
    as_self(claims) = encode_jwt(claims, registry; expires_in = 60)
    # Kid-less: the scope follows the key that VERIFIED the token, not a header label.
    kidless_partner(claims) = encode_jwt(claims, jwtkey("s-part"); expires_in = 60)
    rejected(f) = (err = caught(f); err isa Nitro.Auth.AuthError && occursin("not permitted", err.msg))

    validator = jwt_validator(registry)
    for sign in (as_partner, kidless_partner)
        # Inside the scope: listed names, a pinned value, a list of pinned values, the
        # implicit time and id claims (`iat` and `exp` are stamped by encode_jwt).
        ok = sign(Dict("sub" => "p-1", "action" => "sync", "role" => "reader",
                       "permissions" => ["read", "list"], "nbf" => 0, "jti" => "t-1"))
        principal = validator(ok)
        @test (principal.id, principal.kid, principal["role"]) == ("p-1", "partner", "reader")
        @test decode_jwt(ok, registry)["action"] == "sync"
        @test validator(sign(Dict("permissions" => String[]))) isa Nitro.Principal

        for (label, claims) in (
                ("unlisted role claim", Dict("sub" => "p-1", "admin" => true)),
                ("pinned role, other value", Dict("sub" => "p-1", "role" => "admin")),
                ("one disallowed list element", Dict("permissions" => ["read", "delete"])),
                ("non-string under a pin", Dict("role" => 1)),
                ("null under a pin", Dict("role" => nothing)),
                ("object under a pin", Dict("role" => Dict("name" => "reader"))),
                ("nested list under a pin", Dict("permissions" => [["read"]])),
                ("unlisted iss", Dict("iss" => "https://idp.example")))
            token = sign(claims)
            # BOTH entry points: the check is in `_decode_jwt`, so a direct caller holding the
            # keyset gets it as well as the auth validator.
            @test (label, rejected(() -> decode_jwt(token, registry))) == (label, true)
            @test (label, rejected(() -> validator(token))) == (label, true)
        end
    end

    # Under identity_from=:claim, `sub` IS the identity: a key not scoped for it cannot name one.
    no_sub = JWTKeyset("self" => jwtkey("s-self"); verify = ["partner" => jwtkey("s-part")],
                       claims = Dict("partner" => ["action"]))
    @test rejected(() -> jwt_validator(no_sub)(as_partner(Dict("sub" => "admin-user"))))
    @test jwt_validator(no_sub)(as_partner(Dict("action" => "sync"))).id === nothing

    # Unscoped keys are untouched: the signing key and the rotation key assert anything.
    @test validator(as_self(Dict("sub" => "u", "role" => "admin")))["role"] == "admin"
    rotated = encode_jwt(Dict("role" => "admin"), JWTKeyset("rotated" => jwtkey("s-old")); expires_in = 60)
    @test validator(rotated)["role"] == "admin"
    # A string secret has no keys, so no scope.
    @test decode_jwt(encode_jwt(Dict("role" => "admin"), jwtkey("s-part")), jwtkey("s-part"))["role"] == "admin"
    # verify=false is offline inspection: no key vouched, so nothing is scoped.
    @test decode_jwt(as_partner(Dict("role" => "admin")), registry; verify = false)["role"] == "admin"
    # A scope can also sit on the signing key, and on a lifted Dict. Decoding holds the
    # signing key to it -- here against a token its HMAC key signed through another keyset.
    self_scoped = JWTKeyset("self" => jwtkey("s-self"); claims = ["self" => ["sub", "role" => "reader"]])
    minted_elsewhere = encode_jwt(Dict("role" => "admin"), JWTKeyset("self" => jwtkey("s-self")))
    @test rejected(() -> decode_jwt(minted_elsewhere, self_scoped))
    # And encoding refuses to mint what its own keyset would reject (#349 review) -- the
    # #314 rule, a token `_decode_jwt` refuses is not one to issue.
    err = caught(() -> encode_jwt(Dict("role" => "admin"), self_scoped))
    @test err isa ArgumentError && occursin("\"self\"", sprint(showerror, err))
    @test !occursin("admin", sprint(showerror, err))
    # The check sees the claims as they will decode: a Symbol is a JSON string by then.
    @test decode_jwt(encode_jwt(Dict("sub" => "u", "role" => :reader), self_scoped), self_scoped)["role"] == "reader"
    lifted = JWTKeyset(Dict("default" => jwtkey("s-self"), "partner" => jwtkey("s-part"));
                       claims = Dict(:partner => ["sub"]))
    @test rejected(() -> decode_jwt(as_partner(Dict("role" => "admin")), lifted))

    # The request path: the partner's forged admin token is a 401 from the auth layer, and
    # never reaches `role_required` -- nor the handler.
    reached = Ref(false)
    handler = BearerAuth(validator)(GuardMiddleware(role_required("admin"))(req -> (reached[] = true; HTTP.Response(200))))
    bearer(token) = HTTP.Request("GET", "/", ["Authorization" => "Bearer $token"])
    @test handler(bearer(as_partner(Dict("sub" => "p-1", "role" => "admin")))).status == 401
    @test !reached[]
    # A reader token authenticates and is then refused by the guard, as a reader should be.
    @test handler(bearer(as_partner(Dict("sub" => "p-1", "role" => "reader")))).status == 403
    @test handler(bearer(as_self(Dict("sub" => "u", "role" => "admin")))).status == 200

    # The rejection does not echo the claim or its value, both of which the token chose.
    loud = as_partner(Dict("NITRO-CLAIM-NAME-7c1d" => "NITRO-CLAIM-VALUE-2b9e"))
    text = message(() -> decode_jwt(loud, registry))
    @test !occursin("NITRO-CLAIM-NAME-7c1d", text) && !occursin("NITRO-CLAIM-VALUE-2b9e", text)
    @test occursin("\"partner\"", text)

    # Still one concrete tuple shape on the validator's path (nitro-core §7, #265).
    DT = Tuple{Dict{String, Any}, Nullable{String}}
    @test (@inferred DT Nitro.Auth._decode_jwt(as_partner(Dict("sub" => "p")), registry)) isa DT
end

@testset "a claim scope is checked at construction (#349)" begin
    build(claims) = () -> JWTKeyset("self" => jwtkey("s-self"); verify = ["partner" => jwtkey("s-part")], claims = claims)
    for (label, claims, needle) in (
            ("unknown kid", Dict("partnr" => ["sub"]), "not in the keyset"),
            ("kid twice", ["partner" => ["sub"], :partner => ["action"]], "more than once"),
            ("integer kid", Dict(1 => ["sub"]), "String or Symbol"),
            ("claims not a collection", "partner", "kid => claim scope"),
            ("scope not a list", Dict("partner" => "sub"), "must be a list"),
            ("entry not a name", Dict("partner" => [42]), "an entry is a claim name"),
            ("empty name", Dict("partner" => [""]), "empty claim"),
            ("name twice", Dict("partner" => ["sub", "sub" => ["a"]]), "more than once"),
            ("always-allowed exp", Dict("partner" => ["exp"]), "always assert"),
            ("pinned jti", Dict("partner" => ["jti" => ["x"]]), "always assert"),
            ("empty pin", Dict("partner" => ["role" => String[]]), "no values are pinned"),
            ("numeric pin", Dict("partner" => ["tier" => [1]]), "must be a String"),
            ("Bool pin", Dict("partner" => ["admin" => true]), "String or a list"))
        err = caught(build(claims))
        @test (label, err isa ArgumentError) == (label, true)
        @test (label, occursin(needle, sprint(showerror, err))) == (label, true)
    end
    # A single pinned value stands alone, and an empty scope allows only the implicit claims.
    single = build(Dict("partner" => ["role" => "reader"]))()
    @test Nitro.Auth._key_scope(single, "partner") == Dict("role" => Set(["reader"]))
    only_implicit = build(Dict("partner" => []))()
    token = encode_jwt(Dict{String, Any}(), JWTKeyset("partner" => jwtkey("s-part")); expires_in = 60)
    @test decode_jwt(token, only_implicit) isa Dict{String, Any}

    # A validator that REQUIRES a claim some scoped key may not assert could never admit that
    # key -- fail closed, but only as 401s. It is a startup error instead (#349 review).
    scoped = build(Dict("partner" => ["sub"]))()
    for (label, kwargs, needle) in (
            ("issuer", (issuer = "https://idp.example",), "iss"),
            ("audience", (audience = "api",), "aud"),
            ("required_claims", (required_claims = ["tenant", "sub", "exp"],), "tenant"),
            ("strict profile", (profile = :strict, issuer = "i", audience = "a"), "iss, aud"))
        err = caught(() -> jwt_validator(scoped; kwargs...))
        @test (label, err isa ArgumentError) == (label, true)
        text = sprint(showerror, err)
        @test (label, occursin(needle, text) && occursin("\"partner\"", text)) == (label, true)
    end
    # A pin that excludes the configured value is the same dead key: `iss = idp` fails the
    # scope and anything else fails the issuer check.
    pinned = build(Dict("partner" => ["sub", "iss" => ["other-idp"], "aud" => ["api", "web"]]))()
    for (label, kwargs, needle) in (("issuer pin", (issuer = "idp",), "iss"),
                                    ("audience pin", (audience = "admin",), "aud"))
        err = caught(() -> jwt_validator(pinned; kwargs...))
        @test (label, err isa ArgumentError && occursin(needle, sprint(showerror, err))) == (label, true)
    end
    @test jwt_validator(pinned; issuer = "other-idp", audience = "web") isa Function
    # A list audience is not one fixed value, so only the listing is checked.
    @test jwt_validator(pinned; audience = ["admin", "api"]) isa Function

    # Listed claims, the always-allowed ones, and unscoped keys are all fine.
    @test jwt_validator(scoped; required_claims = ["sub", "exp", "jti"]) isa Function
    @test jwt_validator(build(Dict("partner" => ["sub", "iss", "aud"]))(); issuer = "i", audience = "a") isa Function
    @test jwt_validator(build(())(); issuer = "i", required_claims = ["tenant"]) isa Function
end

@testset "display names scoped claims, never a secret or a pinned value (#349)" begin
    RAW = "NITRO-RAW-SCOPED-SECRET-5e0a-7f21-44c8"   # past the 32-byte floor
    ks = JWTKeyset("self" => RAW; verify = ["partner" => RAW * "-partner"],
                   claims = Dict("partner" => ["sub", "role" => ["NITRO-PINNED-VALUE"]]))
    for rendered in (sprint(show, ks), repr(ks), JSON.json(ks), sprint(show, ks.keys[2]))
        @test !occursin(RAW, rendered)
        @test !occursin("NITRO-PINNED-VALUE", rendered)
    end
    @test sprint(show, ks) == "JWTKeyset(sign=\"self\", verify=[\"partner\"], scoped=[\"partner\"])"
    @test JSON.parse(JSON.json(ks)) ==
        Dict("sign" => "self", "verify" => ["partner"], "claims" => Dict("partner" => ["role", "sub"]))
    @test sprint(show, ks.keys[2]) == "JWTKey(\"partner\", :verify, scoped)"
end

end
