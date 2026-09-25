module Crypto

using OpenSSL
using SHA
using Base64
using UUIDs
using Dates
using Dates: DateTime
using ..Errors
using ..Errors: is_unrecoverable

import JSON

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

# ── base64url ───────────────────────────────────────────────────────────────────
#
# The ONE codec for every base64url value Nitro mints or reads: JWT segments (`Auth`), sealed
# cookies (below), CSRF tokens (#350). It lives here rather than in `Auth` because `Auth` is
# layered above `Core`, and the cookie and CSRF code below it need the same one.

# Unpadded, URL-safe alphabet (RFC 4648 §5; RFC 7515 §2 for JWTs).
function base64url_encode(data::Vector{UInt8})
    s = base64encode(data)
    s = replace(s, '+' => '-', '/' => '_')
    return replace(s, '=' => "")
end

# Strict: canonical base64url and nothing else (#321, #350). The lenient decoder this replaced
# translated `-_` to `+/` and padded, so the standard alphabet, `=` padding, and -- in the last
# character -- any of the 4 (or 16) letters differing only in bits the decoder discards all
# decoded to the same bytes. One token then had many strings, and anything keyed on the raw
# token (a denylist, a replay cache) could be walked around: a JWT signature in `Auth` until
# #321, a sealed cookie here until #350. It also padded by `length` (characters) rather than
# code units, so a non-ASCII input was padded wrongly before it was refused.
#
# Canonical means: the URL-safe alphabet only, no padding, a length that is not 1 mod 4, and
# zero in the bits of the last character that fall past the final byte -- the low 4 bits when
# 2 characters are left over, the low 2 when 3 are. That last rule is checked on the value
# directly rather than by re-encoding and comparing, which did the same job at three times
# the cost on every segment of every request. The test suite holds it to the re-encoding
# definition exhaustively over every 2- and 3-character input, so the two cannot drift.
#
# Throws ArgumentError, the one type its callers catch: `_decode_jwt`'s two sites map it to an
# `AuthError`, and `decrypt_payload` to a `CookieError`.
function base64url_decode(data::AbstractString)
    units = codeunits(data)
    count = length(units)
    remainder = mod(count, 4)
    remainder == 1 && throw(ArgumentError("not base64url: impossible length"))
    # Translated to the standard alphabet and padded in one buffer, for `base64decode`.
    standard = Vector{UInt8}(undef, remainder == 0 ? count : count + 4 - remainder)
    last_value = 0x00
    for (index, byte) in enumerate(units)
        last_value, translated = if UInt8('A') <= byte <= UInt8('Z')
            byte - UInt8('A'), byte
        elseif UInt8('a') <= byte <= UInt8('z')
            byte - UInt8('a') + 0x1a, byte
        elseif UInt8('0') <= byte <= UInt8('9')
            byte - UInt8('0') + 0x34, byte
        elseif byte == UInt8('-')
            0x3e, UInt8('+')
        elseif byte == UInt8('_')
            0x3f, UInt8('/')
        else
            throw(ArgumentError("not base64url"))
        end
        standard[index] = translated
    end
    discarded = remainder == 2 ? 0x0f : remainder == 3 ? 0x03 : 0x00
    last_value & discarded == 0x00 || throw(ArgumentError("not canonical base64url"))
    for index in (count + 1):length(standard)
        standard[index] = UInt8('=')
    end
    return base64decode(standard)
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

# Is `secret` the empty HMAC key? By HMAC key, not by `isempty`: HMAC-SHA256 zero-pads a
# key up to its 64-byte block, so "\0" -- or any run of NULs up to the block size -- IS the
# empty key, and a MAC computed with "" verifies against it. A longer key is hashed first,
# and no SHA-256 output is the zero block, so past 64 bytes nothing is empty. This is
# `hmac_sha256(key, UInt8[]) == hmac_sha256(UInt8[], UInt8[])` exactly, without the
# allocation or the HMAC -- which matters because the JWT plain-string secret path and
# `validate_csrf_token` run it per request. It lives here rather than in `Auth` because
# both `Auth` (#264) and the CSRF middleware (#269) must refuse the same keys, and `Auth`
# is layered above `Core`.
function _empty_hmac_key(secret::AbstractString)
    ncodeunits(secret) <= 64 || return false
    for byte in codeunits(secret)
        byte == 0x00 || return false
    end
    return true
end

# PBKDF2-HMAC-SHA256 (RFC 8018) through libcrypto's `PKCS5_PBKDF2_HMAC`, for the password
# hashers in `Auth` (#311). It replaced a pure-Julia loop that called `SHA.hmac_sha256` per
# iteration: HMAC re-hashes a key longer than its 64-byte block on every call, so that loop
# cost password length x iterations, and it ran several times slower than this at any length.
# libcrypto keys the HMAC once per derivation, and the output is byte-identical, so every
# stored hash still verifies.
#
# `gc_safe = true` is load-bearing: at the default cost this call runs for ~0.2 s, and a
# ccall that is not GC-safe makes every other request thread wait for it at the next
# stop-the-world collection. It is sound here because libcrypto touches only the buffers
# passed in, which the ccall keeps rooted and Julia's non-moving GC never relocates.
#
# The caller owns the policy bounds (`Auth`'s `MAX_*` constants); this only refuses what
# the C signature cannot represent.
function _pbkdf2_hmac_sha256(password::AbstractString, salt::AbstractString, iterations::Integer, key_length::Integer)
    pass = String(password)
    saltstr = String(salt)
    1 <= iterations <= typemax(Cint) || throw(ArgumentError("PBKDF2 iterations out of range: $iterations"))
    1 <= key_length <= typemax(Cint) || throw(ArgumentError("PBKDF2 key length out of range: $key_length"))
    (sizeof(pass) <= typemax(Cint) && sizeof(saltstr) <= typemax(Cint)) ||
        throw(ArgumentError("PBKDF2 password or salt too long"))
    out = Vector{UInt8}(undef, key_length)
    md = @ccall OpenSSL.libcrypto.EVP_sha256()::Ptr{Cvoid}
    ret = @ccall gc_safe = true OpenSSL.libcrypto.PKCS5_PBKDF2_HMAC(
        pass::Ptr{UInt8}, sizeof(pass)::Cint, saltstr::Ptr{UInt8}, sizeof(saltstr)::Cint,
        iterations::Cint, md::Ptr{Cvoid}, key_length::Cint, out::Ptr{UInt8})::Cint
    if ret != 1
        # The error queue is per OS thread; leave nothing behind for an unrelated TLS call.
        @ccall OpenSSL.libcrypto.ERR_clear_error()::Cvoid
        throw(ErrorException("PKCS5_PBKDF2_HMAC failed (code $ret)"))
    end
    return out
end

"""
    SecretString(value::AbstractString)

Wrapper for secrets (API keys, signing keys, tokens) that redacts itself under two
paths — **display** and **JSON serialization**.

*Display*: `show`, `repr`, string interpolation, logging, and the default recursive
`show` of any *containing* struct all print `SecretString("****")` instead of the
value.

*JSON*: `JSON.json` emits `"****"` for a `SecretString` in any **value** position —
bare, as a struct field, or nested inside a `Dict`, `Vector` or `Tuple` — which
covers `Res.json`, the automatic struct-to-JSON return path, and any structured
logging that JSON-encodes a containing struct. A `SecretString` used as a `Dict`
*key* throws instead (JSON routes keys through `StructUtils.lowerkey`, which has no
method here); that is pre-existing and fails closed, so it never leaks.

Serialization is one-way: there is no matching `lift`, so a struct holding a
`SecretString` does not parse back from JSON. This is deliberate — reconstructing
`SecretString("****")` would fail an auth comparison far from the parse site
instead of throwing at it.

Use it for secret fields in app config structs passed via `serve(context=…)`, so
neither an accidental `@show config` nor a handler that returns the config struct
can disclose the secret.

Access the underlying value only via [`reveal`](@ref) — the explicit unwrap keeps
every use of the raw secret greppable. `SecretString` is deliberately **not** an
`AbstractString`: it cannot flow into string operations or output unnoticed.

Comparing with `==` (against another `SecretString` or an `AbstractString`) is
constant-time in the content, making it safe for auth-style checks such as
`config.api_key == request_token`.

!!! warning
    Redaction covers display and JSON, not reflection: `dump` and `getfield` still
    reach the raw value, and serializers other than JSON (ProtoBuf, template
    engines) see the underlying struct. This guards against *accidental*
    disclosure only.
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

# Serialization mask, parallel to the `show` mask above (#25). Without it the
# framework's primary output path — `Res.json`, and `format_response(::Any)` for a
# raw struct return — reflects a SecretString's fields and ships the raw secret to
# the client. JSON.jl routes every value through `StructUtils.lower` before writing,
# so this single method covers the value bare, as a struct field, and nested in a
# Dict/Vector/Tuple. Emit the same "****" the display mask uses.
JSON.lower(::SecretString) = "****"

# Constant-time equality (see ct_compare); mixed comparisons cover the common
# auth shape `stored_secret == client_supplied_token`.
Base.:(==)(a::SecretString, b::SecretString) = ct_compare(a.value, b.value)
Base.:(==)(a::SecretString, b::AbstractString) = ct_compare(a.value, String(b))
Base.:(==)(a::AbstractString, b::SecretString) = b == a
# Hash by value so `==`-equal secrets (and equal plain strings) hash equally,
# keeping the Dict/Set contract intact.
Base.hash(s::SecretString, h::UInt) = hash(s.value, h)

# ── Cookie encryption keys ──────────────────────────────────────────────────────
#
# The ONE place a cookie key enters Nitro (#307). `configcookies`, `serve(secret_key = …)`,
# `CookieConfig(secret_key = …)`, the per-call `secret_key` of `get_cookie`/`set_cookie!` and
# `CookieAuthMiddleware` all normalize through here, so a key is held as a `SecretString` from
# the moment it arrives -- masked in every `show`, `repr` and captured closure -- and unwrapped
# with `reveal` only at the cipher.
#
# It used to be `string(v)`, which is exactly wrong for the container the docs recommend:
# `SecretString` is deliberately not an `AbstractString`, so `string` goes through its masking
# `show` and every app passing one got the public key `SecretString("****")`. A
# `Base.SecretBuffer` failed the same way. Anything that is not a string is now refused WITHOUT
# being read, as `JWTKeyset` does (src/Auth/keyset.jl) -- `String(::Vector{UInt8})` would empty
# the caller's buffer. Deliberately no `repr(value)` in any message.
_cookie_secret(::Nothing) = nothing
function _cookie_secret(value)::SecretString
    wrapped = if value isa SecretString
        value
    elseif value isa AbstractString
        SecretString(value)
    else
        throw(ArgumentError(
            "a cookie secret_key is a $(typeof(value)); it must be an AbstractString or a " *
            "SecretString. Bytes and Base.SecretBuffer are refused without being read."))
    end
    isempty(reveal(wrapped)) && throw(ArgumentError(
        "the cookie secret_key is empty. An unset environment variable read as " *
        "get(ENV, \"COOKIE_SECRET\", \"\") is the usual cause -- read it with a `nothing` " *
        "default and fail at startup instead"))
    # #309: HKDF assumes a high-entropy key, and one captured cookie is enough to test guesses
    # against a short one offline. 32 bytes is the AES-256 key size and what the docs always said.
    ncodeunits(reveal(wrapped)) >= MIN_COOKIE_SECRET_BYTES || throw(ArgumentError(
        "the cookie secret_key is $(ncodeunits(reveal(wrapped))) bytes; it must be at least " *
        "$MIN_COOKIE_SECRET_BYTES random bytes. Generate one once -- e.g. " *
        "`bytes2hex(Nitro.Crypto.secure_random_bytes(32))` -- and read it from the " *
        "environment (ENV[\"COOKIE_SECRET\"]) rather than writing it in source"))
    return wrapped
end

# ── Sealed tokens (#309) ────────────────────────────────────────────────────────
#
# What `set_cookie!` writes and `get_cookie` opens. The old format was AES-256-GCM under
# `sha256(secret)` with nothing else: no associated data, so a ciphertext from ONE cookie opened
# as ANY other (an attacker-influenced `language` cookie pasted into `session_user`); no
# timestamp, so a captured cookie decrypted forever; and an unsalted fast hash of whatever key
# the app passed, so one captured cookie let an attacker test guesses offline.
#
# Version 1, every piece of which is authenticated:
#
#     token     = base64url( 0x01 ‖ iv[12] ‖ ciphertext ‖ tag[16] )
#     aad       = 0x01 ‖ purpose                 -- the cookie NAME, so a token opens for one name only
#     plaintext = iat::Int64 ‖ exp::Int64 ‖ value   (big-endian unix seconds; exp == 0 is "none")
#     key       = HKDF-SHA256(secret, info = COOKIE_KEY_INFO)[1:32]
#
# The version byte leads the token and is also in the AAD, so it cannot be swapped without
# failing the tag. HKDF rather than a password hash on purpose: HKDF is the right derivation for
# a HIGH-entropy key, which is why `_cookie_secret` requires 32 bytes; it gives nothing against a
# guessable one, and neither would a salt, since there is one key per app. Rails and Plug derive
# with PBKDF2 over a 64-byte `secret_key_base`; the label separation is the part copied here.

const TOKEN_VERSION = 0x01
const COOKIE_KEY_INFO = Vector{UInt8}(codeunits("nitro/cookie/aes-256-gcm/v1"))
const MIN_COOKIE_SECRET_BYTES = 32
# version + iv + tag + the iat/exp header inside the ciphertext
const MIN_TOKEN_BYTES = 1 + 12 + 16 + 16

"""
    _hkdf_sha256(ikm, salt, info, len) -> Vector{UInt8}

HKDF (RFC 5869) with HMAC-SHA256: extract a pseudorandom key from `ikm` under `salt`, then
expand it to `len` bytes bound to `info`. An empty `salt` is the RFC's all-zero salt (HMAC pads
the key to its block size either way).
"""
function _hkdf_sha256(ikm::AbstractVector{UInt8}, salt::AbstractVector{UInt8},
                      info::AbstractVector{UInt8}, len::Integer)
    0 < len <= 255 * 32 || throw(ArgumentError("HKDF-SHA256 output length must be 1:$(255 * 32), got $len"))
    prk = SHA.hmac_sha256(Vector{UInt8}(salt), Vector{UInt8}(ikm))
    okm = UInt8[]
    block = UInt8[]
    counter = 0x01
    while length(okm) < len
        block = SHA.hmac_sha256(prk, vcat(block, info, counter))
        append!(okm, block)
        counter += 0x01
    end
    return okm[1:len]
end

_cookie_key(secret::SecretString) =
    _hkdf_sha256(codeunits(reveal(secret)), UInt8[], COOKIE_KEY_INFO, 32)

_token_aad(purpose::AbstractString) = vcat(TOKEN_VERSION, Vector{UInt8}(codeunits(purpose)))

_unix_seconds(t::DateTime) = floor(Int64, Dates.datetime2unix(t))

function _int64_be(x::Int64)
    bytes = Vector{UInt8}(undef, 8)
    for i in 8:-1:1
        bytes[i] = UInt8(x & 0xff)
        x >>= 8
    end
    return bytes
end

function _read_int64_be(bytes::AbstractVector{UInt8}, offset::Int)
    x = Int64(0)
    for i in 0:7
        x = (x << 8) | Int64(bytes[offset + i])
    end
    return x
end

# GCM associated data goes through `EVP_CipherUpdate` with a NULL output buffer, after the key
# and iv are set and before any plaintext. `OpenSSL.cipher_update` always passes an output
# buffer, so it cannot express this; the argument types mirror its own `ccall`.
function _gcm_aad!(ctx::OpenSSL.EvpCipherContext, aad::Vector{UInt8})
    outlen = Ref{Int32}(0)
    ret = GC.@preserve aad outlen ccall((:EVP_CipherUpdate, OpenSSL.libcrypto), Cint,
        (OpenSSL.EvpCipherContext, Ptr{UInt8}, Ptr{Int32}, Ptr{UInt8}, Cint),
        ctx, C_NULL, outlen, aad, length(aad))
    ret == 1 || throw(CookieError("Cipher failed: could not bind the token's purpose"))
    return nothing
end

_gcm_cipher() = OpenSSL.EvpCipher(ccall((:EVP_get_cipherbyname, OpenSSL.libcrypto), Ptr{Cvoid},
                                        (Cstring,), "AES-256-GCM"))

"""
    encrypt_payload(secret, payload; purpose, expires = nothing, now = Dates.now(UTC)) -> String

Seal `payload` into an authenticated, URL-safe token that opens only under `secret` **and** only
for `purpose` — the cookie name, when `set_cookie!` calls it. `expires` (a UTC `DateTime`) is
sealed inside the token and enforced by [`decrypt_payload`](@ref); `nothing` means the token
does not expire on the server side. `now` is the issued-at time sealed alongside it.

`secret` is an `AbstractString` or a `SecretString` of at least 32 bytes; anything else is an
`ArgumentError`. The key is derived from it with HKDF-SHA256 under a Nitro-specific label.
"""
function encrypt_payload(secret, payload::AbstractString; purpose::AbstractString,
                         expires::Union{Nothing, DateTime} = nothing,
                         now::DateTime = Dates.now(Dates.UTC))
    key = _cookie_key(_cookie_secret(secret))

    # Cryptographically secure IV; `secure_random_bytes` checks RAND_bytes and
    # throws on failure, so we never encrypt under a low-entropy / zero IV (which
    # would be catastrophic for GCM nonce uniqueness).
    iv = secure_random_bytes(12)

    # `exp == 0` is the "no expiry" sentinel, so an expiry at or before the epoch -- a logout
    # cookie's `Expires` -- is stored as 1: already past, never "none".
    exp = isnothing(expires) ? Int64(0) : max(Int64(1), _unix_seconds(expires))
    plaintext = vcat(_int64_be(_unix_seconds(now)), _int64_be(exp),
                     Vector{UInt8}(codeunits(String(payload))))

    ctx = OpenSSL.EvpCipherContext()
    OpenSSL.encrypt_init(ctx, _gcm_cipher(), key, iv)
    _gcm_aad!(ctx, _token_aad(purpose))
    ciphertext = OpenSSL.cipher_update(ctx, plaintext)
    final_part = OpenSSL.cipher_final(ctx)

    tag = Vector{UInt8}(undef, 16)
    # EVP_CTRL_GCM_GET_TAG (0x10) returns 1 on success. A silent failure here
    # would emit an all-undefined tag and produce undecryptable ciphertext.
    ret = ccall((:EVP_CIPHER_CTX_ctrl, OpenSSL.libcrypto), Cint,
          (OpenSSL.EvpCipherContext, Cint, Cint, Ptr{UInt8}),
          ctx, 0x10, 16, tag)
    ret == 1 || throw(CookieError("Encryption failed: could not read authentication tag"))

    return base64url_encode(vcat(TOKEN_VERSION, iv, ciphertext, final_part, tag))
end

"""
    decrypt_payload(secret, token; purpose, now = Dates.now(UTC)) -> String

Open a token made by [`encrypt_payload`](@ref) under the same `secret` and `purpose`, and return
the payload. Throws a `CookieError` when the token is malformed, from another format version,
fails authentication — tampered, sealed under another key, or sealed for another `purpose`, which
is what stops a ciphertext moving from one cookie to another — or has expired as of `now` (a UTC
`DateTime`; pass one to check against another instant). The messages are deliberately generic.

A `secret` shorter than 32 bytes, or not a string, is an `ArgumentError`: that is
configuration, not a bad token.
"""
function decrypt_payload(secret, token::AbstractString; purpose::AbstractString,
                         now::DateTime = Dates.now(Dates.UTC))
    key = _cookie_key(_cookie_secret(secret))
    # Both rescues below turn a failure into a `CookieError`, which `get_cookie` now reads as an
    # absent cookie (#309) -- so a corrupted process must not pass through them: an interrupt or
    # an OOM is not a missing cookie (#254, `is_unrecoverable`).
    # Canonical spellings only (#350): a sealed token has exactly one string.
    data = try
        base64url_decode(String(token))
    catch e
        is_unrecoverable(e) && rethrow()
        throw(CookieError("Invalid Base64 payload"))
    end

    length(data) < MIN_TOKEN_BYTES && throw(CookieError("Payload too short"))
    data[1] == TOKEN_VERSION || throw(CookieError("Unsupported token version"))

    iv = data[2:13]
    tag = data[end-15:end]
    ciphertext = data[14:end-16]

    plaintext = try
        ctx = OpenSSL.EvpCipherContext()
        OpenSSL.decrypt_init(ctx, _gcm_cipher(), key, iv)
        _gcm_aad!(ctx, _token_aad(purpose))
        opened = OpenSSL.cipher_update(ctx, ciphertext)

        # EVP_CTRL_GCM_SET_TAG (0x11) returns 1 on success; a failure means the
        # tag was rejected outright, so abort rather than continue to final.
        set_tag = ccall((:EVP_CIPHER_CTX_ctrl, OpenSSL.libcrypto), Cint,
              (OpenSSL.EvpCipherContext, Cint, Cint, Ptr{UInt8}),
              ctx, 0x11, 16, tag)
        set_tag == 1 || throw(CookieError("Decryption failed: integrity check failed"))

        final_res = Vector{UInt8}(undef, 16)
        outlen = Ref{Cint}(0)
        # EVP_DecryptFinal_ex returns 1 on success -- the tag check, which covers the purpose.
        ret = ccall((:EVP_DecryptFinal_ex, OpenSSL.libcrypto), Cint,
                    (OpenSSL.EvpCipherContext, Ptr{UInt8}, Ptr{Cint}),
                    ctx, final_res, outlen)
        ret == 1 || throw(CookieError("Decryption failed: integrity check failed"))
        vcat(opened, final_res[1:outlen[]])
    catch e
        (e isa CookieError || is_unrecoverable(e)) && rethrow()
        # Don't surface the underlying exception detail to callers (it can reach
        # clients); keep the failure reason generic.
        throw(CookieError("Decryption failed"))
    end

    # Authenticated from here on, so these reads cannot be steered by the client.
    exp = _read_int64_be(plaintext, 9)
    exp != 0 && _unix_seconds(now) >= exp && throw(CookieError("Token expired"))
    return String(plaintext[17:end])
end

end
