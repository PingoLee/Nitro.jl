module Auth

using HTTP
using JSON
using Dates
using SHA
using Random
using Base64

using ..Core
using ..Core: CookieConfig, get_cookie, set_cookie!
using ..Core.Cookies: _set_framework_cookie!
using ..Core.Types: AbstractSessionStore, get_session, _is_identity, _session_auth_hash_current,
                    _trimmed, with_json_value, _json_dicts, LifecycleMiddleware,
                    AbstractRefreshTokenStore, RefreshTokenRecord, RefreshTokenMiss,
                    missing_refresh_store_methods
# Imported, not `using`: `MemoryRefreshTokenStore` (src/Auth/refresh.jl) adds methods to them.
import ..Core.Types: record_refresh_token!, consume_refresh_token!, revoke_refresh_family!,
                     prune_refresh_tokens!
using ..Core.Crypto: _empty_hmac_key, _hmac_sha256, _pbkdf2_hmac_sha256, base64url_encode, base64url_decode,
                     secure_random_bytes
using ..Core.Middleware.JanitorMiddleware: _janitor
using ..Core.Util.BodyParsers: _parse_json_bounded, _parse_json_dict_bounded
using ..Core.Util: _auth_credential, _takes_request, BoundedLRU, _count_one

export AuthError,
    set_auth_cookie!, clear_auth_cookie!, extract_auth_token,
    encode_jwt, decode_jwt, validate_iat, validate_claims, JWTKeyset,
    make_password, check_password, validate_password, password_needs_upgrade, is_password_usable,
    set_default_algorithm!, SUPPORTED_ALGORITHMS, DEFAULT_ALGORITHM,
    password_concurrency, set_password_concurrency!,
    ValidationResult, PasswordValidator,
    PasswordEncoder, PBKDF2PasswordEncoder, BCryptPasswordEncoder, SpringSecurityPBKDF2PasswordEncoder,
    DelegatingPasswordEncoder, Argon2PasswordEncoder, parse_argon2_phc,
    encode, matches, upgrade_encoding,
    jwt_validator, session_user_validator, no_auth_validator,
    GuardMiddleware, login_required, role_required, permission_required,
    claim_required, kid_required, Principal, getprincipal,
    # Refresh-token lifecycle (#231): the store contract, the in-memory store and its pruner,
    # and the rotation functions.
    AbstractRefreshTokenStore, MemoryRefreshTokenStore, RefreshTokenPruner,
    RefreshTokenRecord, RefreshTokenMiss,
    record_refresh_token!, consume_refresh_token!, revoke_refresh_family!, prune_refresh_tokens!,
    missing_refresh_store_methods

struct AuthError <: Exception
    msg::String
end

Base.showerror(io::IO, error::AuthError) = print(io, error.msg)

include("Auth/claims.jl")
include("Auth/keyset.jl")
include("Auth/jwt.jl")
include("Auth/cookies.jl")
include("Auth/passwords.jl")
include("Auth/validators.jl")
include("Auth/guards.jl")
include("Auth/refresh.jl")

end