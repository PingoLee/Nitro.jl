module Auth

using HTTP
using JSON
using Dates
using SHA
using Random
using Base64

using ..Core
using ..Core: CookieConfig, get_cookie, set_cookie!
using ..Core.Types: AbstractSessionStore, get_session

export AuthError,
    set_auth_cookie!, clear_auth_cookie!, extract_auth_token,
    encode_jwt, decode_jwt, validate_iat, validate_claims,
    make_password, check_password, validate_password, password_needs_upgrade,
    ValidationResult, PasswordValidator,
    PasswordEncoder, PBKDF2PasswordEncoder, BCryptPasswordEncoder, SpringSecurityPBKDF2PasswordEncoder,
    DelegatingPasswordEncoder, encode, matches, upgrade_encoding,
    jwt_validator, session_user_validator, no_auth_validator,
    GuardMiddleware, login_required, role_required, permission_required

struct AuthError <: Exception
    msg::String
end

Base.showerror(io::IO, error::AuthError) = print(io, error.msg)

include("Auth/claims.jl")
include("Auth/jwt.jl")
include("Auth/cookies.jl")
include("Auth/passwords.jl")
include("Auth/validators.jl")
include("Auth/guards.jl")

end