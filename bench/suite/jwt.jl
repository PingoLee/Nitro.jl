# What a bearer-authenticated request pays for its JWT (#723), against the request it rides on.
# The last number was #449's: `jwt_validator(...)(tok)` at 13.4 µs and 145 allocations, taken
# before #432 (base64url) and #449 (libcrypto HMAC).
#
#   decode                 `decode_jwt` with a service claim set (iss, aud, exp, iat, one scope)
#   validator_secret       `jwt_validator(secret)(tok)`: BearerAuth's per-request call
#   validator_keyset_kid   `jwt_validator(keyset; identity_from = :kid)` on a 4-key keyset, a token
#                          whose header names its kid: one HMAC
#   validator_keyset_nokid the same validator on a token with no kid, signed by the key tried
#                          last: the trial loop's worst case
#   request_plain          `internalrequest` to a trivial route
#   request_bearer         the same route behind `BearerAuth(jwt_validator(secret))`; the gap to
#                          `request_plain` is what auth costs inside the real pipeline
#   request_session        the same route behind `SessionMiddleware` on a `MemoryStore` with a
#                          loaded session, for scale (`session/middleware_loaded` is that layer
#                          alone)
#
# One thread, in-process. The tokens are minted at include time and are valid for 15 minutes,
# `decode_jwt`'s default maximum age, which a run of this group stays well inside.
SUITE["jwt"] = BenchmarkGroup()

const JWT_SECRET = "bench-service-secret-0123456789abcdef"
const JWT_ISS = "bench-issuer"
const JWT_AUD = "bench-api"
jwt_claims() = Dict{String, Any}("iss" => JWT_ISS, "aud" => JWT_AUD, "sub" => "billing",
                                 "scope" => "invoices:read")

const JWT_TOKEN = Nitro.Auth.encode_jwt(jwt_claims(), JWT_SECRET; expires_in = 900)

# Four callers, one key each. "audit" is a verify-only key and the last one listed, so a kid-less
# token signed with its secret is found only after every other key has failed.
const JWT_KEYS = ["billing" => "bench-billing-secret-0123456789abcdef",
                  "reports" => "bench-reports-secret-0123456789abcdef",
                  "search"  => "bench-search-secret-0123456789abcdef",
                  "audit"   => "bench-audit-secret-0123456789abcdefgh"]
const JWT_KEYSET = Nitro.Auth.JWTKeyset(JWT_KEYS[1]; verify = JWT_KEYS[2:end])
const JWT_TOKEN_KID = Nitro.Auth.encode_jwt(jwt_claims(), Nitro.Auth.JWTKeyset(JWT_KEYS[end]);
                                            expires_in = 900)
const JWT_TOKEN_NOKID = Nitro.Auth.encode_jwt(jwt_claims(), last(JWT_KEYS[end]); expires_in = 900)

const JWT_VALIDATE_SECRET = Nitro.Auth.jwt_validator(JWT_SECRET; issuer = JWT_ISS, audience = JWT_AUD)
const JWT_VALIDATE_KEYSET = Nitro.Auth.jwt_validator(JWT_KEYSET; identity_from = :kid,
                                                     issuer = JWT_ISS, audience = JWT_AUD)

const JWT_STORE = let s = Nitro.Core.Types.MemoryStore{String,Dict{String,Any}}()
    Nitro.Core.Types.set_session!(s, "sid-jwt", Dict{String,Any}("user_id" => 7, "role" => "service"); ttl = 7200)
    s
end

const JWT_APP = Nitro.Core.App()
jwt_ok(req) = Res.send("ok")
Nitro.Core.Routing.urlpatterns(JWT_APP, "", Nitro.RouteDefinition[
    Nitro.path("/svc/plain", jwt_ok; method = "GET"),
    Nitro.path("/svc/bearer", jwt_ok; method = "GET",
               middleware = [Nitro.BearerAuth(JWT_VALIDATE_SECRET)]),
    Nitro.path("/svc/session", jwt_ok; method = "GET",
               middleware = [Nitro.SessionMiddleware(cookie_name = "sid", store = JWT_STORE)]),
])

jwt_request(target, headers = Pair{String,String}[]) = HTTP.Request("GET", target, headers)
run_jwt_request(req::HTTP.Request) = Nitro.Core.internalrequest(JWT_APP, req)

# Fail at include time, not as a fast 401 that would read as a cheap validator.
let
    @assert JWT_VALIDATE_SECRET(JWT_TOKEN) !== nothing
    @assert JWT_VALIDATE_KEYSET(JWT_TOKEN_KID) !== nothing
    @assert JWT_VALIDATE_KEYSET(JWT_TOKEN_NOKID) !== nothing
    @assert run_jwt_request(jwt_request("/svc/plain")).status == 200
    @assert run_jwt_request(jwt_request("/svc/bearer", ["Authorization" => "Bearer $JWT_TOKEN"])).status == 200
    @assert run_jwt_request(jwt_request("/svc/bearer")).status == 401
    @assert run_jwt_request(jwt_request("/svc/session", ["Cookie" => "sid=sid-jwt"])).status == 200
end

SUITE["jwt"]["decode"] = @benchmarkable Nitro.Auth.decode_jwt($JWT_TOKEN, $JWT_SECRET;
                                                               issuer = $JWT_ISS, audience = $JWT_AUD)
SUITE["jwt"]["validator_secret"] = @benchmarkable $JWT_VALIDATE_SECRET($JWT_TOKEN)
SUITE["jwt"]["validator_keyset_kid"] = @benchmarkable $JWT_VALIDATE_KEYSET($JWT_TOKEN_KID)
SUITE["jwt"]["validator_keyset_nokid"] = @benchmarkable $JWT_VALIDATE_KEYSET($JWT_TOKEN_NOKID)

# Fresh Request per eval: internalrequest mutates req.context.
SUITE["jwt"]["request_plain"] = @benchmarkable run_jwt_request(r) setup=(
    r = jwt_request("/svc/plain")) evals=1
SUITE["jwt"]["request_bearer"] = @benchmarkable run_jwt_request(r) setup=(
    r = jwt_request("/svc/bearer", ["Authorization" => "Bearer $JWT_TOKEN"])) evals=1
SUITE["jwt"]["request_session"] = @benchmarkable run_jwt_request(r) setup=(
    r = jwt_request("/svc/session", ["Cookie" => "sid=sid-jwt"])) evals=1
