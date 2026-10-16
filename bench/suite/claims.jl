# `Claims{T}` (#527): what binding the verified claims to a struct costs, against the two untyped
# reads a handler does without it. Both sides read the same `Principal` from `:auth_claims` on one
# request, so the difference is the bind itself: one `StructUtils.make` over the claims `Dict`,
# behind `claims_bind`'s inference barrier, plus `getprincipal`. The bind is paid once per request;
# what it buys is everything after it in the handler being typed, which the reads leave `Any`.
#
# `extract` directly, not `internalrequest`: the pipeline around it is the same on both sides, and
# would drown a difference of this size. One thread, in-process.
SUITE["claims"] = BenchmarkGroup()

struct BenchClaims
    sub::String
    role::String
    org_id::Int
end

const CLAIMS_PARAM = Nitro.Param(:claims, Nitro.Claims{BenchClaims}, nothing, false)

function claims_request()
    req = HTTP.Request("GET", "/bench/claims")
    req.context[:auth_claims] = Nitro.Principal(Dict{String, Any}(
        "sub" => "user-17", "role" => "admin", "org_id" => 42, "exp" => 1_900_000_000,
        "iat" => 1_800_000_000, "iss" => "bench"); id = "user-17")
    return req
end

SUITE["claims"]["claims_bind"] = @benchmarkable Nitro.extract(CLAIMS_PARAM, lr) setup=(
    lr = Nitro.LazyRequest(request = claims_request()))

SUITE["claims"]["getprincipal_two_reads"] = @benchmarkable begin
    p = Nitro.getprincipal(req)
    (p["role"], p["org_id"])
end setup=(req = claims_request())
