module Crypto

using OpenSSL
using SHA
using Base64
using UUIDs
using ..Errors

export encrypt_payload, decrypt_payload, secure_random_bytes, secure_uuid4,
       SecretString, reveal

"""
    secure_random_bytes(n::Int) -> Vector{UInt8}

Return `n` cryptographically secure random bytes sourced from OpenSSL's CSPRNG
(`RAND_bytes`). Throws if the underlying generator reports failure, so callers
never receive low-entropy output. Use this for tokens, salts, and session IDs —
never `Base.rand`, whose default generator is not cryptographically secure.
"""
function secure_random_bytes(n::Int)
    n >= 0 || throw(ArgumentError("n must be non-negative, got $n"))
    buf = Vector{UInt8}(undef, n)
    n == 0 && return buf
    ret = ccall((:RAND_bytes, OpenSSL.libcrypto), Cint, (Ptr{UInt8}, Cint), buf, n)
    ret == 1 || throw(ErrorException("RAND_bytes failed to produce secure random data (code $ret)"))
    return buf
end

"""
    secure_uuid4() -> UUID

Generate a version-4 UUID using [`secure_random_bytes`](@ref) as the entropy
source, instead of `UUIDs.uuid4()` which draws from the task-local, non-CSPRNG
default RNG. Suitable for unguessable session identifiers.
"""
function secure_uuid4()
    bytes = secure_random_bytes(16)
    bytes[7] = (bytes[7] & 0x0f) | 0x40  # version 4
    bytes[9] = (bytes[9] & 0x3f) | 0x80  # RFC 4122 variant
    value = UInt128(0)
    for b in bytes
        value = (value << 8) | b
    end
    return UUIDs.UUID(value)
end

# Helper for URL-safe Base64
function base64url_encode(data::Vector{UInt8})
    s = base64encode(data)
    s = replace(s, '+' => '-', '/' => '_')
    return replace(s, '=' => "")
end

function base64url_decode(s::String)
    s = replace(s, '-' => '+', '_' => '/')
    padding = length(s) % 4
    if padding > 0
        s *= "=" ^ (4 - padding)
    end
    return base64decode(s)
end

function encrypt_payload(secret::String, payload::String)
    key = SHA.sha256(secret)

    # Cryptographically secure IV; `secure_random_bytes` checks RAND_bytes and
    # throws on failure, so we never encrypt under a low-entropy / zero IV (which
    # would be catastrophic for GCM nonce uniqueness).
    iv = secure_random_bytes(12)

    cipher_ptr = ccall((:EVP_get_cipherbyname, OpenSSL.libcrypto), Ptr{Cvoid}, (Cstring,), "AES-256-GCM")
    cipher = OpenSSL.EvpCipher(cipher_ptr)
    ctx = OpenSSL.EvpCipherContext()

    try
        OpenSSL.encrypt_init(ctx, cipher, key, iv)
        ciphertext = OpenSSL.cipher_update(ctx, Vector{UInt8}(payload))
        final_part = OpenSSL.cipher_final(ctx)

        tag = Vector{UInt8}(undef, 16)
        # EVP_CTRL_GCM_GET_TAG (0x10) returns 1 on success. A silent failure here
        # would emit an all-undefined tag and produce undecryptable ciphertext.
        ret = ccall((:EVP_CIPHER_CTX_ctrl, OpenSSL.libcrypto), Cint,
              (OpenSSL.EvpCipherContext, Cint, Cint, Ptr{UInt8}),
              ctx, 0x10, 16, tag)
        ret == 1 || throw(CookieError("Encryption failed: could not read authentication tag"))

        return base64url_encode(vcat(iv, ciphertext, final_part, tag))
    finally
        # context cleaned by finalizer
    end
end

function decrypt_payload(secret::String, payload::String)
    data = try
        base64url_decode(payload)
    catch
        throw(CookieError("Invalid Base64 payload"))
    end

    if length(data) < 28
        throw(CookieError("Payload too short"))
    end

    iv = data[1:12]
    tag = data[end-15:end]
    ciphertext = data[13:end-16]
    key = SHA.sha256(secret)

    cipher_ptr = ccall((:EVP_get_cipherbyname, OpenSSL.libcrypto), Ptr{Cvoid}, (Cstring,), "AES-256-GCM")
    cipher = OpenSSL.EvpCipher(cipher_ptr)
    ctx = OpenSSL.EvpCipherContext()

    try
        OpenSSL.decrypt_init(ctx, cipher, key, iv)
        plaintext = OpenSSL.cipher_update(ctx, Vector{UInt8}(ciphertext))

        # EVP_CTRL_GCM_SET_TAG (0x11) returns 1 on success; a failure means the
        # tag was rejected outright, so abort rather than continue to final.
        set_tag = ccall((:EVP_CIPHER_CTX_ctrl, OpenSSL.libcrypto), Cint,
              (OpenSSL.EvpCipherContext, Cint, Cint, Ptr{UInt8}),
              ctx, 0x11, 16, Vector{UInt8}(tag))
        set_tag == 1 || throw(CookieError("Decryption failed: integrity check failed"))

        final_res = Vector{UInt8}(undef, 16)
        outlen = Ref{Cint}(0)
        
        # EVP_DecryptFinal_ex returns 1 on success
        ret = ccall((:EVP_DecryptFinal_ex, OpenSSL.libcrypto), Cint,
                    (OpenSSL.EvpCipherContext, Ptr{UInt8}, Ptr{Cint}),
                    ctx, final_res, outlen)
        
        if ret != 1
            throw(CookieError("Decryption failed: integrity check failed"))
        end

        return String(vcat(plaintext, final_res[1:outlen[]]))
    catch e
        if e isa CookieError; rethrow(e); end
        # Don't surface the underlying exception detail to callers (it can reach
        # clients); keep the failure reason generic.
        throw(CookieError("Decryption failed"))
    end
end

# ── Secret handling ─────────────────────────────────────────────────────────────

# Constant-time byte comparison. The early length check leaks only the *length*
# mismatch (standard and accepted — cf. Python's hmac.compare_digest); when lengths
# match, every byte is visited regardless of where the first difference occurs, so
# timing reveals nothing about the content.
function ct_compare(a::AbstractVector{UInt8}, b::AbstractVector{UInt8})::Bool
    length(a) == length(b) || return false
    diff = UInt8(0)
    for i in eachindex(a, b)
        @inbounds diff |= a[i] ⊻ b[i]
    end
    return diff == 0x00
end
ct_compare(a::AbstractString, b::AbstractString)::Bool =
    ct_compare(codeunits(String(a)), codeunits(String(b)))

"""
    SecretString(value::AbstractString)

Wrapper for secrets (API keys, signing keys, tokens) that redacts itself under
display: `show`, `repr`, string interpolation, logging, and the default recursive
`show` of any *containing* struct all print `SecretString("****")` instead of the
value. Use it for secret fields in app config structs passed via `serve(context=…)`
so an accidental `@show config` or REPL display never prints the secret.

Access the underlying value only via [`reveal`](@ref) — the explicit unwrap keeps
every use of the raw secret greppable. `SecretString` is deliberately **not** an
`AbstractString`: it cannot flow into string operations or output unnoticed.

Comparing with `==` (against another `SecretString` or an `AbstractString`) is
constant-time in the content, making it safe for auth-style checks such as
`config.api_key == request_token`.

!!! warning
    Redaction covers display, not reflection: `dump` and `getfield` still reach
    the raw value. This guards against *accidental* disclosure only.
"""
struct SecretString
    value::String
end
SecretString(s::AbstractString) = SecretString(String(s))
SecretString(s::SecretString) = s               # idempotent

"""
    reveal(s::SecretString) -> String

Return the wrapped secret value. This is the only sanctioned way to read a
[`SecretString`](@ref); keeping the unwrap explicit makes every use of the raw
secret auditable with a single grep.
"""
reveal(s::SecretString)::String = s.value

Base.show(io::IO, ::SecretString) = print(io, "SecretString(\"****\")")
Base.show(io::IO, ::MIME"text/plain", s::SecretString) = show(io, s)

# Constant-time equality (see ct_compare); mixed comparisons cover the common
# auth shape `stored_secret == client_supplied_token`.
Base.:(==)(a::SecretString, b::SecretString) = ct_compare(a.value, b.value)
Base.:(==)(a::SecretString, b::AbstractString) = ct_compare(a.value, String(b))
Base.:(==)(a::AbstractString, b::SecretString) = b == a
# Hash by value so `==`-equal secrets (and equal plain strings) hash equally,
# keeping the Dict/Set contract intact.
Base.hash(s::SecretString, h::UInt) = hash(s.value, h)

end
