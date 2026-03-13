module AuthModuleTests

using Test
using HTTP
using Nitro
import Nitro.Auth: PasswordValidator, validate
import Nitro.Auth: encode, matches, upgrade_encoding, PBKDF2PasswordEncoder, BCryptPasswordEncoder,
    DelegatingPasswordEncoder, SpringSecurityPBKDF2PasswordEncoder

const NOW_TS = trunc(Int, time())

@testset "Auth module cookie helpers" begin
    res = HTTP.Response(200)
    Nitro.Auth.set_auth_cookie!(res, "token-123"; secure=false)
    cookie_header = HTTP.header(res, "Set-Cookie")
    @test occursin("auth_token=token-123", cookie_header)
    @test !occursin("Secure", cookie_header)

    logout = HTTP.Response(200)
    Nitro.Auth.clear_auth_cookie!(logout; secure=false)
    cleared = HTTP.header(logout, "Set-Cookie")
    @test occursin("Max-Age=0", cleared)
end

@testset "JWT encode/decode and validation" begin
    keyset = Dict("default" => "secret-a", "rotated" => "secret-b")
    token = Nitro.Auth.encode_jwt(
        Dict(
            "sub" => "42",
            "iss" => "nitro-tests",
            "aud" => ["nitro"],
            "exp" => NOW_TS + 60,
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

    plain_text = "password123"
    @test_logs (:warn, r"Unknown hash format") matches(delegating, plain_text, plain_text)
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
    token = Nitro.Auth.encode_jwt(Dict("sub" => "9", "exp" => NOW_TS + 60), "secret-a")
    validator = Nitro.Auth.jwt_validator("secret-a")
    claims = validator(token)
    @test claims["sub"] == "9"

    store = Nitro.Types.MemoryStore{String, Dict{String,Any}}()
    Nitro.Types.set_session!(store, "sess-1", Dict{String,Any}("user" => Dict("id" => 5)); ttl=60)
    session_validator = Nitro.Auth.session_user_validator(store)
    @test session_validator("sess-1")["id"] == 5
end

end