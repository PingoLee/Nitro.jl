# The request-path probe `juliac` is pointed at with `ENTRY=probe` (#718). `app.jl` reaches the
# request path only through `serve` → `HTTP.listen!`, and the verifier stops at the first dynamic
# call on each path, so a wall in front of the listener hides everything behind it. This file
# calls the pipeline itself: `@main` builds it with `setupmiddleware` and hands it requests, so the
# verifier walks `compose`, the per-route chains and the router terminal whatever the listener does.
#
# Routes are registered at TOP LEVEL, as in `app.jl`: under `juliac` that runs at build time and
# the route table is a value in the image. They cover the shapes a route table mixes: an exact
# route, a converter route, and three distinct middleware stacks, two of them through an
# `include_routes` group. Run as a script it is the JIT check that the same requests serve.
#
# The second half covers Nitro's own request-time middleware, which a real app installs and the
# routes above do not: `Cors`, `SessionMiddleware` on a `MemoryStore`, `CSRFMiddleware`,
# `CrossOriginProtection`, a `RateLimiter`, `BearerAuth` over `jwt_validator`, a `GuardMiddleware`
# and the access log. Each runs as route middleware on a group of its own (`MW_ROUTES`) and, in a
# second pipeline, as global middleware passed as a `Tuple` (`GLOBAL_TARGETS`). The first six
# requests and their answers are unchanged, so counts before and after the extension compare.
using Nitro
const Second = Nitro.Core.Dates.Second   # Dates is not a dependency of bench/juliac either
const HTTP = Nitro.Core.HTTP     # not a dependency of bench/juliac in its own right

const PLAINTEXT = "Hello, World!"
const app = App()

# A user middleware in its documented shape, `handler -> (req -> response)`. Each `tag` is a
# closure of its own type, as an application's middleware would be.
tag(name::String) = handler -> function (req::HTTP.Request)
    res = handler(req)
    return res
end
const MW_A, MW_B, MW_C = tag("a"), tag("b"), tag("c")

urlpatterns(app, "",
    path("/plaintext", req -> Res.send(PLAINTEXT); method = "GET"),
    path("/users/<int:id>", (req, id::Int) -> Res.send(string(id)); method = "GET"),
    path("/mw", req -> Res.send("mw"); method = "GET", middleware = [MW_C, MW_A]),
)
urlpatterns(app, "", include_routes("/api", [
    path("/items", req -> Res.send("items"); method = "GET"),
    path("/admin", req -> Res.send("admin"); method = "GET", middleware = [MW_B]),
]; middleware = [MW_A]))

const TARGETS = ("/plaintext", "/users/7", "/mw", "/api/items", "/api/admin", "/missing")

# ── Nitro's own middleware ──────────────────────────────────────────────────────────────────────
#
# Test-only secrets, built at top level. Neither is ever printed, and nor is a cookie or a token.
const JWT_SECRET = "probe-only-jwt-secret-not-for-production-0123456789"
const CSRF_SECRET = "probe-only-csrf-secret-not-for-production-0123456789"
const ORIGIN = "https://app.example"
# The peer address the transport sets on every request it builds (`internalrequest` sets the same
# one); the rate limiter keys on it.
const PEER = Nitro.Core.Sockets.IPv4("127.0.0.1")

# The session handler writes one key; the second request reads it back through the cookie. Both
# narrow what `getsession` returns, as a trimmed app's handler has to: it is an `Any`.
function session_set(req::HTTP.Request)
    s = getsession(req)
    s isa Dict{String,Any} && (s["n"] = 1)
    return Res.send("set")
end
function session_get(req::HTTP.Request)
    s = getsession(req)
    s isa Dict{String,Any} || return Res.send("none")
    n = get(s, "n", 0)
    return Res.send(n isa Int ? string(n) : "?")
end

urlpatterns(app, "", include_routes("/cors", [
    path("/data", req -> Res.send("cors"); method = "GET"),
    # A route-level `Cors` sees a preflight only on a route that takes `OPTIONS`.
    path("/data", req -> Res.send("cors"); method = "OPTIONS"),
]; middleware = [Cors(allowed_origins = [ORIGIN])]))
urlpatterns(app, "", include_routes("/session", [
    path("/set", session_set; method = "GET"),
    path("/get", session_get; method = "GET"),
    path("/post", req -> Res.send("posted"); method = "POST"),
]; middleware = [SessionMiddleware(store = MemoryStore()), CSRFMiddleware(CSRF_SECRET)]))
urlpatterns(app, "",
    path("/coop", req -> Res.send("coop"); method = "POST", middleware = [CrossOriginProtection()]),
    path("/limited", req -> Res.send("limited"); method = "GET",
         middleware = [RateLimiter(strategy = :fixed_window, rate_limit = 2, window = Second(60))]),
)
const VALIDATE = Nitro.Auth.jwt_validator(JWT_SECRET)
urlpatterns(app, "", include_routes("/auth", [
    path("/me", req -> Res.send("me"); method = "GET"),
    path("/admin", req -> Res.send("admin"); method = "GET",
         middleware = [GuardMiddleware(role_required("admin"))]),
]; middleware = [BearerAuth(VALIDATE)]))

# A token for a user without the admin role, minted at build time so `main` signs nothing.
const TOKEN = Nitro.Auth.encode_jwt(Dict{String,Any}("sub" => "probe-user", "role" => "user"),
                                    JWT_SECRET; expires_in = 10 * 365 * 86400)

# The same middleware as GLOBAL layers, in the documented `Tuple` form, built at top level as an
# application would. The access log's records go to a sink that drops them.
const GLOBAL_MIDDLEWARE = (
    Cors(allowed_origins = [ORIGIN]),
    SessionMiddleware(store = MemoryStore()),
    CrossOriginProtection(),
    RateLimiter(strategy = :fixed_window, rate_limit = 1000, window = Second(60)),
    AccessLog(records -> nothing),
)

struct Probe
    method::String
    target::String
    headers::Vector{Pair{String,String}}
    expect::Int
    cookie_from::Int     # take the `Cookie` from this earlier probe's `Set-Cookie` (0: none)
    body::String         # the expected body, when it says something ("" = not checked)
end
Probe(method, target, expect; headers = Pair{String,String}[], cookie_from = 0, body = "") =
    Probe(method, target, headers, expect, cookie_from, body)

const AUTH = ["Authorization" => "Bearer " * TOKEN]
const MW_ROUTES = (
    Probe("OPTIONS", "/cors/data", 200; headers = ["Origin" => ORIGIN,
                                                   "Access-Control-Request-Method" => "GET"]),
    Probe("GET", "/cors/data", 200; headers = ["Origin" => ORIGIN]),
    Probe("GET", "/session/set", 200),
    Probe("GET", "/session/get", 200; cookie_from = 3, body = "1"),
    Probe("POST", "/session/post", 403; cookie_from = 3),
    Probe("POST", "/coop", 403; headers = ["Sec-Fetch-Site" => "cross-site", "Origin" => "https://evil.example"]),
    Probe("GET", "/limited", 200),
    Probe("GET", "/limited", 200),
    Probe("GET", "/limited", 429),
    Probe("GET", "/auth/me", 200; headers = AUTH),
    Probe("GET", "/auth/me", 401),
    Probe("GET", "/auth/admin", 403; headers = AUTH),
)
const GLOBAL_TARGETS = (
    Probe("GET", "/plaintext", 200; headers = ["Origin" => ORIGIN]),
    Probe("OPTIONS", "/plaintext", 200; headers = ["Origin" => ORIGIN,
                                                   "Access-Control-Request-Method" => "GET"]),
    Probe("GET", "/session/get", 200),
    Probe("POST", "/coop", 403; headers = ["Sec-Fetch-Site" => "cross-site", "Origin" => "https://evil.example"]),
)

# The `Cookie` header a browser would send back: every `name=value` the response set (the session
# id and the CSRF token both), or "". Never printed.
# Takes the headers, not the response: `HTTP.Response` is abstract over its body, and a call on it
# would be this file's own dynamic call.
function cookie_of(headers::HTTP.Headers)::String
    pairs = String[]
    for (k, v) in headers
        lowercase(k) == "set-cookie" && push!(pairs, String(first(split(v, ';'))))
    end
    return join(pairs, "; ")
end

# The body as text, read at its concrete type: `res.body` on the `HTTP.Response` the pipeline
# returns is an `Any`, which would add this file's own rows to the count.
body_text(res::HTTP.Response)::String = Nitro.Core.Types.with_response(_body_text, res)
_body_text(r::HTTP.Response{String}) = r.body
_body_text(r::HTTP.Response{Vector{UInt8}}) = String(copy(r.body))
_body_text(::HTTP.Response) = ""

# Runs `probes` through `pipeline` and prints `method target status`, flagged when the status is
# not the expected one. Returns the number of mismatches.
function run_probes(pipeline, probes, label::String)::Int
    cookies = String[]
    bad = 0
    for p in probes
        headers = copy(p.headers)
        p.cookie_from > 0 && !isempty(cookies[p.cookie_from]) &&
            push!(headers, "Cookie" => cookies[p.cookie_from])
        req = HTTP.Request(p.method, p.target, headers)
        setip!(req, PEER)
        res = pipeline(req)
        push!(cookies, cookie_of(res.headers))
        ok = res.status == p.expect && (isempty(p.body) || body_text(res) == p.body)
        ok || (bad += 1)
        println(Core.stdout, label, " ", p.method, " ", p.target, " ", res.status,
                ok ? "" : string(" (expected ", p.expect, isempty(p.body) ? "" : " with its body", ")"))
    end
    return bad
end

function (@main)(args::Vector{String})::Cint
    pipeline = Nitro.Core.setupmiddleware(app)
    for target in TARGETS
        res = pipeline(HTTP.Request("GET", target))
        println(Core.stdout, target, " ", res.status)
    end
    bad = run_probes(pipeline, MW_ROUTES, "route")
    global_pipeline = Nitro.Core.setupmiddleware(app; middleware = GLOBAL_MIDDLEWARE, access_log = true)
    bad += run_probes(global_pipeline, GLOBAL_TARGETS, "global")
    println(Core.stdout, bad == 0 ? "all middleware probes answered as expected" :
                                    string(bad, " middleware probe(s) answered unexpectedly"))
    return Cint(bad == 0 ? 0 : 1)
end
