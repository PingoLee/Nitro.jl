"""
    AuthKit

A reusable Nitro auth package: login, logout and "who am I" endpoints that issue and accept
bearer JWTs, plus the middleware a host puts in front of its own routes. It follows the
reusable-package checklist in the *Extension Points* tutorial:

- [`routes`](@ref) **returns** route definitions and registers nothing.
- [`TokenAuth`](@ref) is a keyword-only middleware factory.
- The user lookup and the signing key arrive as arguments, in an [`AuthConfig`](@ref) the host
  builds. The package keeps no global and owns no user table.
"""
module AuthKit

using HTTP
using Nitro
using Random: RandomDevice

export Account, AuthConfig, Revocations, TokenAuth, TokenClaims, routes

"""
    Account(id, username, password_hash, role)

What the host's user lookup returns. `password_hash` is a string from `Auth.make_password`;
AuthKit never sees or stores a plain password.
"""
struct Account
    id::String
    username::String
    password_hash::String
    role::String
end

"""
    TokenClaims

The claims every token AuthKit issues carries, as a struct a host handler can bind with
`Claims{TokenClaims}`: the account id (`sub`), the token's own id (`jti`, what logout revokes)
and its expiry.
"""
@kwdef struct TokenClaims
    sub::String
    jti::String
    exp::Int
end

"""
    Revocations()

The token ids logout has revoked, each kept until its token would have expired anyway. It lives
in this process's memory, which is right for one process. Several processes behind a load
balancer need it in a shared store instead (a database table, Redis), or a token signed out on
one of them still works on the others.
"""
struct Revocations
    lock::ReentrantLock
    until::Dict{String,Int}   # jti => the token's exp, in Unix seconds
end
Revocations() = Revocations(ReentrantLock(), Dict{String,Int}())

function revoke!(revoked::Revocations, jti::String, exp::Int)
    now = round(Int, time())
    lock(revoked.lock) do
        filter!(entry -> entry.second > now, revoked.until)   # an expired token needs no entry
        revoked.until[jti] = exp
    end
    return nothing
end

isrevoked(revoked::Revocations, jti::String) = lock(() -> haskey(revoked.until, jti), revoked.lock)

"""
    AuthConfig(; secret, find_by_username, find_by_id, ttl = 3600, issuer = "authkit",
               revoked = Revocations())

Everything AuthKit needs from its host:

- `secret`: the HMAC key tokens are signed with, at least 32 bytes. Read it from the
  environment in `main()`, never from a module body, and give AuthKit a key of its own: any
  token another component signs with it, carrying the right claims, would be accepted.
- `find_by_username(username)` and `find_by_id(id)`: the host's user lookup. Each returns an
  [`Account`](@ref), or `nothing` when there is no such user.
- `ttl`: token lifetime in seconds.
- `issuer`: the `iss` claim AuthKit stamps on its tokens and requires back.
- `revoked`: where logout records revoked tokens; see [`Revocations`](@ref).

The functions run on request threads, concurrently, so they must be safe to call that way.
"""
struct AuthConfig{U<:Function,I<:Function}
    secret::String
    find_by_username::U
    find_by_id::I
    ttl::Int
    issuer::String
    revoked::Revocations
end

function AuthConfig(; secret::AbstractString, find_by_username::Function, find_by_id::Function,
                    ttl::Integer = 3600, issuer::AbstractString = "authkit",
                    revoked::Revocations = Revocations())
    ttl > 0 || throw(ArgumentError("AuthConfig: `ttl` must be positive"))
    return AuthConfig(String(secret), find_by_username, find_by_id, Int(ttl), String(issuer), revoked)
end

# Never print the signing key: a config that reaches a log or an error page would leak it.
Base.show(io::IO, config::AuthConfig) = print(io, "AuthConfig(ttl = ", config.ttl, ", secret = <redacted>)")

# What the auth middleware puts at `getuser(req)`: the account as it is NOW, read from the host's
# lookup on every request rather than copied into the token at login. A dict, so `role_required`
# reads the current role and a demotion takes effect on the next request rather than when the
# token expires.
user_claims(account::Account) =
    Dict{String,Any}("id" => account.id, "username" => account.username, "role" => account.role)

"""
    TokenAuth(; config::AuthConfig)

Middleware that accepts `Authorization: Bearer <token>` for a token AuthKit issued, and answers
`401` otherwise. A token is refused when its signature, expiry or issuer does not check out, when
logout revoked it, or when its account no longer exists. On success:

- `getuser(req)` is the account's current claims (`"id"`, `"username"`, `"role"`), so the
  guards `login_required()` and `role_required(...)` work after it;
- `getprincipal(req)` is the verified token, which a handler can also bind as
  `Claims{TokenClaims}`.

A keyword-only factory: list it **called**, `middleware = [TokenAuth(config = config)]`.
"""
function TokenAuth(; config::AuthConfig)
    resolve = function (principal)
        jti = get(principal, "jti", nothing)
        (jti isa String && !isrevoked(config.revoked, jti)) || return nothing
        account = config.find_by_id(principal.id)
        return account === nothing ? nothing : user_claims(account)
    end
    validator = Auth.jwt_validator(config.secret; user_validator = resolve, issuer = config.issuer,
                                   require_exp = true, required_claims = ["sub", "jti"])
    return BearerAuth(validator)
end

@kwdef struct Credentials
    username::String
    password::String
end

new_jti() = bytes2hex(rand(RandomDevice(), UInt8, 16))

function login(config::AuthConfig)
    return function (req::HTTP.Request, body::Json{Credentials})
        credentials = body.payload
        account = config.find_by_username(credentials.username)
        # `nothing` for an unknown user still hashes once, so a wrong username takes as long
        # as a wrong password and the endpoint does not reveal which accounts exist.
        Auth.check_password(credentials.password, account === nothing ? nothing : account.password_hash) ||
            return Res.json(Dict("error" => "invalid credentials"); status = 401)
        token = Auth.encode_jwt(Dict("iss" => config.issuer, "sub" => account.id, "jti" => new_jti()),
                                config.secret; expires_in = config.ttl)
        # A credential: no cache between here and the client may keep a copy (RFC 6749 §5.1).
        return Res.json(Dict("token" => token, "token_type" => "Bearer", "expires_in" => config.ttl);
                        headers = ["Cache-Control" => "no-store"])
    end
end

function logout(config::AuthConfig)
    return function (req::HTTP.Request, claims::Claims{TokenClaims})
        revoke!(config.revoked, claims.payload.jti, claims.payload.exp)
        return Res.status(204)
    end
end

me(req::HTTP.Request) = Res.json(getuser(req))

"""
    routes(config::AuthConfig; prefix = "/auth", namespace = "auth") -> Vector{RouteDefinition}

The routes this package contributes, all under `prefix`:

| Method | Path | Name | |
|--------|------|------|-|
| `POST` | `prefix/login` | `"<namespace>.login"` | `{"username", "password"}` → `{"token", "token_type", "expires_in"}`, or `401` |
| `POST` | `prefix/logout` | `"<namespace>.logout"` | revokes the bearer token; `204` |
| `GET`  | `prefix/me` | `"<namespace>.me"` | the signed-in account; `401` without a valid token |

Returns a value and registers nothing: pass it to `urlpatterns(app, …)`.
"""
function routes(config::AuthConfig; prefix::String = "/auth", namespace::String = "auth")
    authenticated = [TokenAuth(config = config)]
    return include_routes(prefix, [
        path("/login", login(config); method = "POST", name = "$namespace.login"),
        path("/logout", logout(config); method = "POST", name = "$namespace.logout",
             middleware = authenticated),
        path("/me", me; method = "GET", name = "$namespace.me", middleware = authenticated),
    ])
end

end # module
