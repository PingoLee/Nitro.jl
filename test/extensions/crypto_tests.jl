@testitem "Crypto extension" tags=[:extension, :security] setup=[NitroCommon] begin
using OpenSSL
using SHA
using Base64

@testset "NitroCryptoExt Tests" begin

    secret = "super-secret-key-0123456789abcdef"
    payload = "sensitive-user-data-123"
    # #309: a token is sealed for one purpose (the cookie name) and opens only for it.
    purpose = "crypto-test"

    @testset "Basic Encrypt/Decrypt" begin
        # extension should be loaded since we imported OpenSSL in this test
        encrypted = Nitro.Crypto.encrypt_payload(secret, payload; purpose)

        @test encrypted != payload
        @test !isempty(encrypted)

        decrypted = Nitro.Crypto.decrypt_payload(secret, encrypted; purpose)
        @test decrypted == payload
    end

    @testset "Base64URL Validity" begin
        encrypted = Nitro.Crypto.encrypt_payload(secret, payload; purpose)

        # Check that it doesn't contain standard Base64 chars that are problematic in URLs/Cookies
        @test !contains(encrypted, "+")
        @test !contains(encrypted, "/")
        @test !contains(encrypted, "=")
    end

    @testset "Integrity Check (Tampering)" begin
        encrypted = Nitro.Crypto.encrypt_payload(secret, payload; purpose)

        # Tamper with the ciphertext (Base64 encoded)
        # We replace one valid Base64URL char with another near the end. Not the LAST char: with
        # the #309 layout this token's byte count leaves 2 unused bits in the last char, so an
        # A<->B flip there can change nothing at all.
        chars = collect(encrypted)
        chars[end-1] = chars[end-1] == 'A' ? 'B' : 'A'
        tampered = join(chars)

        @test_throws Nitro.Errors.CookieError Nitro.Crypto.decrypt_payload(secret, tampered; purpose)
    end

    @testset "Invalid Secret" begin
        encrypted = Nitro.Crypto.encrypt_payload(secret, payload; purpose)
        @test_throws Nitro.Errors.CookieError Nitro.Crypto.decrypt_payload("wrong-secret-0123456789abcdefghij", encrypted; purpose)
    end

    @testset "Malformed Payloads" begin
        @test_throws Nitro.Errors.CookieError Nitro.Crypto.decrypt_payload(secret, "not-base64-!@#\$"; purpose)
        @test_throws Nitro.Errors.CookieError Nitro.Crypto.decrypt_payload(secret, "abcd"; purpose) # too short
    end

    @testset "Large Payloads" begin
        large_payload = "a" ^ 10_000
        encrypted = Nitro.Crypto.encrypt_payload(secret, large_payload; purpose)
        decrypted = Nitro.Crypto.decrypt_payload(secret, encrypted; purpose)
        @test decrypted == large_payload
    end

    @testset "Non-Determinism (IV Randomization)" begin
        # Encrypting the same thing twice should yield different results due to random IV
        enc1 = Nitro.Crypto.encrypt_payload(secret, payload; purpose)
        enc2 = Nitro.Crypto.encrypt_payload(secret, payload; purpose)
        @test enc1 != enc2
        @test Nitro.Crypto.decrypt_payload(secret, enc1; purpose) == payload
        @test Nitro.Crypto.decrypt_payload(secret, enc2; purpose) == payload
    end

    @testset "Unicode & Special Characters" begin
        unicode_payload = "🚀 Nitro.jl is fast! ⚡ (ñ, ü, 中文)"
        encrypted = Nitro.Crypto.encrypt_payload(secret, unicode_payload; purpose)
        decrypted = Nitro.Crypto.decrypt_payload(secret, encrypted; purpose)
        @test decrypted == unicode_payload
    end

    @testset "Empty Payload" begin
        empty_payload = ""
        encrypted = Nitro.Crypto.encrypt_payload(secret, empty_payload; purpose)
        decrypted = Nitro.Crypto.decrypt_payload(secret, encrypted; purpose)
        @test decrypted == empty_payload
    end

    @testset "Base64URL Padding Symmetry" begin
        # Test strings of different lengths to trigger 0, 1, 2 pad variations in the manual decoder
        for len in 1:10
            p = "x" ^ len
            enc = Nitro.Crypto.encrypt_payload(secret, p; purpose)
            @test Nitro.Crypto.decrypt_payload(secret, enc; purpose) == p
        end
    end

    @testset "Key Derivation Consistency" begin
        # Same secret should always produce same encryption (deterministic key derivation)
        # Note: IV is random, so encrypted values differ, but decryption with same key succeeds
        secret_consistent = "consistent-key-for-derivation-0123"
        payload1 = "data1"
        payload2 = "data2"

        enc1a = Nitro.Crypto.encrypt_payload(secret_consistent, payload1; purpose)
        enc1b = Nitro.Crypto.encrypt_payload(secret_consistent, payload1; purpose)

        # Both encrypt to different ciphertexts (different IVs) but both decrypt correctly
        @test enc1a != enc1b
        @test Nitro.Crypto.decrypt_payload(secret_consistent, enc1a; purpose) == payload1
        @test Nitro.Crypto.decrypt_payload(secret_consistent, enc1b; purpose) == payload1

        # Different payloads produce different ciphertexts
        enc2 = Nitro.Crypto.encrypt_payload(secret_consistent, payload2; purpose)
        @test enc2 != enc1a
        @test enc2 != enc1b
    end

    @testset "IV Uniqueness Protection" begin
        # Verify that sequential encryptions use different IVs
        payload_iv = "test-payload-for-iv"

        encrypted_values = [Nitro.Crypto.encrypt_payload(secret, payload_iv; purpose) for _ in 1:10]

        # All encrypted values should be unique (due to random IV)
        @test length(unique(encrypted_values)) == 10

        # But all should decrypt to same value
        decrypted_values = [Nitro.Crypto.decrypt_payload(secret, enc; purpose) for enc in encrypted_values]
        @test all(dv == payload_iv for dv in decrypted_values)
    end

    @testset "Thread-Safe Concurrent Operations" begin
        # Test concurrent encrypt/decrypt in multiple threads
        n_threads = 10
        n_ops = 20

        results = Vector{String}(undef, n_threads * n_ops)
        payloads = ["payload_$i" for i in 1:(n_threads * n_ops)]

        # Concurrent encryption
        Threads.@threads for i in 1:(n_threads * n_ops)
            enc = Nitro.Crypto.encrypt_payload(secret, payloads[i]; purpose)
            results[i] = enc
        end

        # Concurrent decryption
        decrypted = Vector{String}(undef, n_threads * n_ops)
        Threads.@threads for i in 1:(n_threads * n_ops)
            decrypted[i] = Nitro.Crypto.decrypt_payload(secret, results[i]; purpose)
        end

        # Verify all decrypted correctly
        @test all(decrypted[i] == payloads[i] for i in 1:(n_threads * n_ops))
    end

    @testset "IV Region Tampering Specific" begin
        # Test that tampering specifically in the IV region is detected. Since #309 the token
        # leads with a version byte, so the IV is decoded bytes 2:13.
        encrypted = Nitro.Crypto.encrypt_payload(secret, payload; purpose)

        # Base64 chars 1-2 carry the version byte; char 3 carries decoded bytes 2-3, both IV
        chars = collect(encrypted)

        # Tamper with the third character (guaranteed to be in IV region)
        chars[3] = chars[3] == 'A' ? 'B' : 'A'
        tampered_iv = join(chars)

        # Should fail due to IV mismatch in GCM authentication
        @test_throws Nitro.Errors.CookieError Nitro.Crypto.decrypt_payload(secret, tampered_iv; purpose)
    end

    @testset "Auth Tag Tampering Detection" begin
        # Test that tampering in the authentication tag is detected
        encrypted = Nitro.Crypto.encrypt_payload(secret, payload; purpose)

        # Auth tag is the last ~21 Base64 characters (16 bytes)
        chars = collect(encrypted)

        # Flip a character in the tag region. Not the LAST one: since #309 this token's byte
        # count leaves 2 unused bits there, so turning a 'B'/'C'/'D' into 'A' would change no
        # byte at all -- a ~5% flake. The second-to-last character is all data bits.
        chars[end-1] = chars[end-1] == 'A' ? 'Z' : 'A'
        tampered_tag = join(chars)

        @test_throws Nitro.Errors.CookieError Nitro.Crypto.decrypt_payload(secret, tampered_tag; purpose)
    end

    @testset "Short Secret Key Handling" begin
        # #309: a key under 32 bytes is REFUSED, in both directions. This testset used to assert
        # a 5-byte key worked; the third source adjudicating the inversion is
        # docs/src/tutorial/cookies/security.md, whose key example has always read
        # "k3y-must-be-32-bytes-long". HKDF assumes a high-entropy key, and one captured cookie is
        # enough to test guesses against a short one offline.
        short_key = "short"
        payload_short = "data-with-short-key"

        # Encryption refuses the short key -- configuration, so ArgumentError, not CookieError
        @test_throws ArgumentError Nitro.Crypto.encrypt_payload(short_key, payload_short; purpose)

        # Decryption refuses it too, before it looks at the token
        encrypted = Nitro.Crypto.encrypt_payload(secret, payload_short; purpose)
        @test_throws ArgumentError Nitro.Crypto.decrypt_payload(short_key, encrypted; purpose)
        @test_throws ArgumentError Nitro.Crypto.decrypt_payload("wrong", encrypted; purpose)
    end

    @testset "Ciphertext Structure Validation" begin
        # Validate the Basic structure of encrypted output
        # Expected: Base64URL-encoded (version || IV || ciphertext || auth_tag) since #309
        encrypted = Nitro.Crypto.encrypt_payload(secret, payload; purpose)

        # Should be non-empty Base64URL string
        @test !isempty(encrypted)
        @test isa(encrypted, String)

        # Should only contain Base64URL characters (no +, /, =)
        @test !contains(encrypted, "+")
        @test !contains(encrypted, "/")
        @test !contains(encrypted, "=")

        # Should be decodable as Base64
        try
            # Convert Base64URL to standard Base64 for validation
            std_b64 = replace(encrypted, '-' => '+', '_' => '/')
            padding = length(std_b64) % 4
            if padding > 0
                std_b64 *= "=" ^ (4 - padding)
            end
            decoded = base64decode(std_b64)
            # #309: at least version (1) + IV (12) + iat/exp header (16) + Tag (16); was IV + Tag
            @test length(decoded) >= 45
        catch
            @test false  # Should not fail Base64 decode
        end
    end

    @testset "Decryption State Consistency" begin
        # Test that decryption doesn't have side effects
        payload_state = "state-test-payload"
        encrypted_state = Nitro.Crypto.encrypt_payload(secret, payload_state; purpose)

        # Decrypt multiple times, should always succeed
        for _ in 1:5
            result = Nitro.Crypto.decrypt_payload(secret, encrypted_state; purpose)
            @test result == payload_state
        end

        # Interleaved encrypt/decrypt should maintain state
        p1 = "first"
        p2 = "second"
        enc1 = Nitro.Crypto.encrypt_payload(secret, p1; purpose)
        enc2 = Nitro.Crypto.encrypt_payload(secret, p2; purpose)

        # Decrypt in mixed order
        @test Nitro.Crypto.decrypt_payload(secret, enc2; purpose) == p2
        @test Nitro.Crypto.decrypt_payload(secret, enc1; purpose) == p1
        @test Nitro.Crypto.decrypt_payload(secret, enc2; purpose) == p2
    end

    @testset "Multiple Secrets Isolation" begin
        # Test that data encrypted with one secret cannot be decrypted with another
        secret1 = "secret-one-1234567890-0123456789ab"
        secret2 = "secret-two-1234567890-0123456789ab"
        payload_isolation = "isolated-message"

        enc_with_secret1 = Nitro.Crypto.encrypt_payload(secret1, payload_isolation; purpose)

        # Should decrypt with correct secret
        @test Nitro.Crypto.decrypt_payload(secret1, enc_with_secret1; purpose) == payload_isolation

        # Should NOT decrypt with wrong secret
        @test_throws Nitro.Errors.CookieError Nitro.Crypto.decrypt_payload(secret2, enc_with_secret1; purpose)
    end

    @testset "Null Byte Handling" begin
        # Test payloads containing null bytes
        payload_null = "data\0with\0nulls"
        encrypted_null = Nitro.Crypto.encrypt_payload(secret, payload_null; purpose)
        decrypted_null = Nitro.Crypto.decrypt_payload(secret, encrypted_null; purpose)

        @test decrypted_null == payload_null
        @test contains(decrypted_null, "\0")
    end

end
end
