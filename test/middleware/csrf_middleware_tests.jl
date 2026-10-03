@testitem "CSRF middleware" tags=[:middleware, :security, :csrf] setup=[NitroCommon] begin

using HTTP
using JSON
using Nitro
using Nitro: CSRFMiddleware, SessionMiddleware, CookieConfig, regenerate_session!, csrf_token!
using Nitro.Core.Types: MemoryStore

# The private surface. Every one of these is security-relevant and none is reachable through the
# public API alone, so they are exercised directly -- a defect in `_constant_time_equals` or
# `SAFE_METHODS` is invisible to a functional round-trip test.
#
# `issue_csrf_token!` and `validate_csrf_token` are also reached this way: `CSRFMiddleware_`
# exports them and `Core` re-exports them, but `src/Nitro.jl` does a plain `using .Core`, so
# `CSRFMiddleware` is the only one of the three that is public from `Nitro` itself.
const CSRF = Nitro.Core.Middleware.CSRFMiddleware_
using Nitro.Core.Middleware.CSRFMiddleware_: issue_csrf_token!, validate_csrf_token

const SECRET = "csrf-unit-secret"
const SESSION_A = "11111111-1111-4111-8111-111111111111"
const SESSION_B = "22222222-2222-4222-8222-222222222222"

# ── helpers ───────────────────────────────────────────────────────────────────
# Nothing here ever prints a token, a cookie value or the secret: assertions compare, they do
# not display. A failing @test shows the comparison, which is why the booleans are named.

set_cookie_headers(res) = [h.second for h in res.headers if lowercase(h.first) == "set-cookie"]
cookie_line(res, name) = only(filter(h -> startswith(h, "$name="), set_cookie_headers(res)))
cookie_value(res, name) = String(match(Regex("$(name)=([^;]+)"), cookie_line(res, name)).captures[1])
raw_half(cookie) = String(split(cookie, '.', limit = 2)[1])     # the raw token in the cookie
# The raw token behind a masked one (#436). `csrf_token!` and `issue_csrf_token!` hand out a new
# mask every call, so a test that means "the same token" compares through this, never with `==`.
unmasked(token) = CSRF._unmask_token(token)
session_count(store) = length(store.data)

"""Build a request already carrying `cookies` (a name => value dict) plus `headers`."""
function request(method, cookies::Dict{String,String} = Dict{String,String}(); headers = Pair{String,String}[], body = nothing)
    hs = Pair{String,String}[h for h in headers]
    isempty(cookies) || push!(hs, "Cookie" => join(("$k=$v" for (k, v) in cookies), "; "))
    return body === nothing ? HTTP.Request(method, "/form", hs) : HTTP.Request(method, "/form", hs, body)
end

ok_handler(req) = HTTP.Response(200, "ok")

# Asks for the token, the way a form page or an SPA bootstrap endpoint does. Since #431 a new
# visitor gets a token only when something asks, so every testset that needs a first-visit token
# goes through this handler.
token_handler(req) = (csrf_token!(req); HTTP.Response(200, "ok"))

"""A CSRF layer whose binding is fixed to `session_id`, with no SessionMiddleware involved."""
function bound_layer(session_id::String; kwargs...)
    csrf = CSRFMiddleware(SECRET; kwargs...)(ok_handler)
    return function (req::HTTP.Request)
        req.context[:session_id] = session_id
        return csrf(req)
    end
end

"""A real SessionMiddleware wrapped around CSRFMiddleware, plus its store."""
function session_layer(; csrf_kwargs = (;), handler = ok_handler,
                       store = MemoryStore{String, Dict{String,Any}}())
    layer = SessionMiddleware(cookie_name = "unit_session", store = store).middleware(
        CSRFMiddleware(SECRET; csrf_kwargs...)(handler))
    return layer, store
end

# ── the primitives ────────────────────────────────────────────────────────────

@testset "_csrf_signature binds the token to the session" begin
    token = CSRF._generate_raw_token()

    # Deterministic for a fixed (secret, token, binding) triple ...
    @test CSRF._csrf_signature(SECRET, token, SESSION_A) == CSRF._csrf_signature(SECRET, token, SESSION_A)
    # ... and different along every one of the three axes. The binding axis is the #23 fix: before
    # it, the signature was a function of the token alone and this assertion could not hold.
    @test CSRF._csrf_signature(SECRET, token, SESSION_A) != CSRF._csrf_signature(SECRET, token, SESSION_B)
    @test CSRF._csrf_signature(SECRET, token, SESSION_A) != CSRF._csrf_signature("other-secret", token, SESSION_A)
    @test CSRF._csrf_signature(SECRET, CSRF._generate_raw_token(), SESSION_A) !=
          CSRF._csrf_signature(SECRET, token, SESSION_A)

    # base64url alphabet, unpadded: the value goes into a cookie, where '+' '/' '=' are trouble.
    signature = CSRF._csrf_signature(SECRET, token, SESSION_A)
    @test occursin(r"^[A-Za-z0-9_-]+$", signature)
    @test length(signature) == 43        # 32 HMAC-SHA256 bytes, unpadded base64url
end

@testset "_constant_time_equals" begin
    @test CSRF._constant_time_equals("abc", "abc")
    @test !CSRF._constant_time_equals("abc", "abd")
    @test !CSRF._constant_time_equals("abc", "abcd")     # length mismatch
    @test !CSRF._constant_time_equals("", "a")
    @test CSRF._constant_time_equals("", "")
    # Differences at either end are caught: an implementation that degraded to a prefix or
    # suffix compare would pass one of these and fail the other.
    @test !CSRF._constant_time_equals("Xbc", "abc")
    @test !CSRF._constant_time_equals("abX", "abc")
    # SubString and String compare by content, which is what the validator feeds it.
    @test CSRF._constant_time_equals(split("abc.def", '.')[1], "abc")
end

@testset "_generate_raw_token entropy" begin
    tokens = [CSRF._generate_raw_token() for _ in 1:256]
    @test all(t -> length(t) == 43, tokens)              # 32 random bytes, unpadded base64url
    @test all(t -> occursin(r"^[A-Za-z0-9_-]+$", t), tokens)
    @test length(Set(tokens)) == 256                     # no repeats => the CSPRNG is wired up
    @test !any(t -> occursin('.', t), tokens)            # '.' is the signed-token separator
end

@testset "_parse_signed_token rejects malformed input" begin
    @test CSRF._parse_signed_token("nodot") == (nothing, nothing)
    @test CSRF._parse_signed_token("") == (nothing, nothing)

    raw, sig = CSRF._parse_signed_token("abc.def")
    @test raw == "abc" && sig == "def"

    # `limit=2` means everything after the FIRST dot is the signature, not a third field.
    raw, sig = CSRF._parse_signed_token("abc.def.ghi")
    @test raw == "abc" && sig == "def.ghi"

    # Empty halves parse but can never verify -- checked through the gate below.
    @test CSRF._parse_signed_token("abc.") == ("abc", "")
    @test CSRF._parse_signed_token(".def") == ("", "def")
end

@testset "SAFE_METHODS is exactly the four read-only methods" begin
    # An over-broad set is a silent bypass: every method in here skips validation entirely.
    @test CSRF.SAFE_METHODS == Set(("GET", "HEAD", "OPTIONS", "TRACE"))
    @test !("POST" in CSRF.SAFE_METHODS)
    @test !("PUT" in CSRF.SAFE_METHODS)
    @test !("PATCH" in CSRF.SAFE_METHODS)
    @test !("DELETE" in CSRF.SAFE_METHODS)
end

@testset "_binding reads the session id, and only a string one" begin
    req = HTTP.Request("GET", "/form")
    @test CSRF._binding(req) === nothing               # no SessionMiddleware ran
    req.context[:session_id] = SESSION_A
    @test CSRF._binding(req) == SESSION_A
    req.context[:session_id] = 42                      # a non-string id is not a binding
    @test CSRF._binding(req) === nothing
end

@testset "_presented_token: header, form field, JSON body" begin
    header_req = request("POST", headers = ["X-CSRF-Token" => "  tok-header  "])
    @test CSRF._presented_token(header_req, "X-CSRF-Token", "_csrf") == "tok-header"   # trimmed

    form_req = HTTP.Request("POST", "/form",
        ["Content-Type" => "application/x-www-form-urlencoded"], "_csrf=tok-form&other=1")
    @test CSRF._presented_token(form_req, "X-CSRF-Token", "_csrf") == "tok-form"

    # Only a body that is a form, or says nothing, is read as one (#345): the same `_csrf=` pair
    # under another declared type is not a presented token.
    untyped_req = HTTP.Request("POST", "/form", [], "_csrf=tok-form")
    @test CSRF._presented_token(untyped_req, "X-CSRF-Token", "_csrf") == "tok-form"
    for ct in ("text/plain", "application/xml", "text/html")
        other_req = HTTP.Request("POST", "/form", ["Content-Type" => ct], "_csrf=tok-form&other=1")
        @test CSRF._presented_token(other_req, "X-CSRF-Token", "_csrf") === nothing
    end

    json_req = HTTP.Request("POST", "/form",
        ["Content-Type" => "application/json"], JSON.json(Dict("_csrf" => "tok-json")))
    @test CSRF._presented_token(json_req, "X-CSRF-Token", "_csrf") == "tok-json"

    # Header wins over a body field when both are present.
    both_req = HTTP.Request("POST", "/form",
        ["Content-Type" => "application/json", "X-CSRF-Token" => "tok-header"],
        JSON.json(Dict("_csrf" => "tok-json")))
    @test CSRF._presented_token(both_req, "X-CSRF-Token", "_csrf") == "tok-header"

    # Nothing presented, and a body that is not a dict, both yield `nothing` rather than throwing.
    @test CSRF._presented_token(request("POST"), "X-CSRF-Token", "_csrf") === nothing
    array_req = HTTP.Request("POST", "/form", ["Content-Type" => "application/json"], "[1,2,3]")
    @test CSRF._presented_token(array_req, "X-CSRF-Token", "_csrf") === nothing

    # A custom field name is honoured on both body paths.
    custom = HTTP.Request("POST", "/form",
        ["Content-Type" => "application/json"], JSON.json(Dict("csrfmiddlewaretoken" => "tok-x")))
    @test CSRF._presented_token(custom, "X-CSRF-Token", "csrfmiddlewaretoken") == "tok-x"
end

# ── issue_csrf_token! ─────────────────────────────────────────────────────────

@testset "issue_csrf_token! cookie flags and TTL" begin
    res = HTTP.Response(200, "ok")
    masked = issue_csrf_token!(res, SECRET; binding = SESSION_A)
    raw = unmasked(masked)
    @test raw isa String                              # it returns the token masked (#436)
    @test masked != raw
    line = cookie_line(res, "__Host-csrf_token")
    @test !occursin(masked, line)                     # the cookie keeps the raw token

    @test occursin("Secure", line)                    # required by the __Host- prefix
    @test occursin("Path=/", line)                    # required by the __Host- prefix
    @test !occursin("Domain=", line)                  # required by the __Host- prefix
    @test !occursin("HttpOnly", line)                 # deliberate: the SPA has to read it
    @test occursin("SameSite=Lax", line)
    # Seven days by default (#441): one hour sent idle SPAs and open forms into a 403 while their
    # session was still alive.
    @test occursin("Max-Age=604800", line)

    # The cookie carries `<raw>.<sig>` and verifies under the binding it was minted for.
    value = cookie_value(res, "__Host-csrf_token")
    @test startswith(value, raw * ".")
    @test CSRF._verify_signed_token(SECRET, value, SESSION_A) == raw
    @test CSRF._verify_signed_token(SECRET, value, SESSION_B) === nothing
    # The binding itself must never appear in the JS-readable cookie -- only its HMAC.
    @test !occursin(SESSION_A, line)

    # A custom TTL reaches Max-Age.
    short = HTTP.Response(200, "ok")
    issue_csrf_token!(short, SECRET; binding = SESSION_A, ttl = 60)
    @test occursin("Max-Age=60", cookie_line(short, "__Host-csrf_token"))
end

@testset "the default ttl matches the session's absolute lifetime (#441)" begin
    # `CSRFMiddleware` cannot read `SessionMiddleware`'s settings, so the two defaults are kept
    # equal by hand. A CSRF cookie that dies first is a 403 for a client whose session is alive.
    @test CSRF.DEFAULT_TTL == Nitro.Core.Middleware.SessionMiddleware_.DEFAULT_ABSOLUTE_MAX_AGE

    # The middleware's own default reaches the cookie it issues, not just `issue_csrf_token!`'s.
    layer, _ = session_layer(handler = token_handler)
    res = layer(HTTP.Request("GET", "/form"))
    @test occursin("Max-Age=$(CSRF.DEFAULT_TTL)", cookie_line(res, "__Host-csrf_token"))
end

@testset "issue_csrf_token! requires a binding" begin
    # No default: minting an unbound token is the defect #23 removed, so omission must not compile
    # into a silently unbound cookie.
    @test_throws UndefKeywordError issue_csrf_token!(HTTP.Response(200, "ok"), SECRET)
end

# ── the __Host- prefix guard ──────────────────────────────────────────────────

@testset "__Host-/__Secure- prefixes are validated at construction" begin
    insecure = CookieConfig(httponly = false, secure = false, samesite = "Lax", path = "/")
    scoped   = CookieConfig(httponly = false, secure = true, samesite = "Lax", path = "/app")
    domained = CookieConfig(httponly = false, secure = true, samesite = "Lax", path = "/", domain = "example.com")

    # Browsers discard these silently, so Nitro refuses to build them.
    @test_throws ArgumentError CSRFMiddleware(SECRET; config = insecure)
    @test_throws ArgumentError CSRFMiddleware(SECRET; config = scoped)
    @test_throws ArgumentError CSRFMiddleware(SECRET; config = domained)
    @test_throws ArgumentError CSRFMiddleware(SECRET; cookie_name = "__Secure-csrf", config = insecure)
    @test_throws ArgumentError issue_csrf_token!(HTTP.Response(200, "ok"), SECRET;
                                                 binding = SESSION_A, config = insecure)

    # The prefix rules are matched case-insensitively, exactly as browsers match them.
    @test_throws ArgumentError CSRFMiddleware(SECRET; cookie_name = "__host-csrf", config = insecure)

    # __Secure- has no Path/Domain constraint -- only Secure.
    @test CSRFMiddleware(SECRET; cookie_name = "__Secure-csrf", config = scoped) isa Function
    # An unprefixed name is unconstrained: this is the documented plain-HTTP escape hatch.
    @test CSRFMiddleware(SECRET; cookie_name = "csrf_token", config = insecure) isa Function
end

# ── the secret ────────────────────────────────────────────────────────────────

@testset "an empty or NUL-only secret is refused (#269)" begin
    # HMAC-SHA256 zero-pads a key to its 64-byte block, so every one of these IS the empty key:
    # a token signed with "" verifies under it. `get(ENV, "CSRF_SECRET", "")` with the variable
    # unset is how an app ends up here, so construction -- app startup -- is where it must fail.
    # Matched on type AND message: the cookie-prefix guard also throws `ArgumentError`, and would
    # satisfy a bare type check if the default config ever changed. Anchoring on the printed
    # `ArgumentError: ` keeps the type the docs promise, which a message-only regex would drop.
    refused = r"^ArgumentError: the CSRF secret is empty"
    for secret in ("", "\0", "\0"^64)
        @test_throws refused CSRFMiddleware(secret)
        # The two primitives are reachable from a handler, so each refuses on its own ...
        @test_throws refused issue_csrf_token!(HTTP.Response(200, "ok"), secret; binding = SESSION_A)
        @test_throws refused validate_csrf_token(request("POST"), secret; binding = SESSION_A)
        # ... including on the early-`false` paths (no binding, no cookie), so a misconfiguration
        # does not hide until the first request that happens to carry a cookie.
        @test_throws refused validate_csrf_token(request("POST"), secret)
    end

    # The message names the cause and never quotes the secret.
    message = sprint(showerror, try CSRFMiddleware("\0"^8); catch e; e; end)
    @test occursin("CSRF secret is empty", message)
    @test !occursin('\0', message) && !occursin("\\0", message)

    # Past the 64-byte block HMAC hashes the key, so a NUL run that long is a real key, and a
    # NUL anywhere beside another byte is too. These are accepted, as before.
    @test CSRFMiddleware("\0"^65) isa Function
    @test CSRFMiddleware("a\0") isa Function
end

# ── validate_csrf_token / CSRFMiddleware ──────────────────────────────────────

@testset "safe methods issue a token and skip validation" begin
    for method in ("GET", "HEAD", "OPTIONS", "TRACE")
        res = bound_layer(SESSION_A)(request(method))
        @test res.status == 200
        value = cookie_value(res, "__Host-csrf_token")
        @test CSRF._verify_signed_token(SECRET, value, SESSION_A) !== nothing
    end
end

@testset "a valid round trip is accepted" begin
    layer = bound_layer(SESSION_A)
    issued = cookie_value(layer(request("GET")), "__Host-csrf_token")
    raw = String(split(issued, '.', limit = 2)[1])

    for method in ("POST", "PUT", "PATCH", "DELETE")
        res = layer(request(method, Dict("__Host-csrf_token" => issued);
                            headers = ["X-CSRF-Token" => raw]))
        @test res.status == 200
    end

    # The double-submit fallback: presenting the FULL signed cookie value is also accepted.
    @test layer(request("POST", Dict("__Host-csrf_token" => issued);
                        headers = ["X-CSRF-Token" => issued])).status == 200

    # And through the form field / JSON body rather than the header.
    form = HTTP.Request("POST", "/form",
        ["Content-Type" => "application/x-www-form-urlencoded",
         "Cookie" => "__Host-csrf_token=$issued"], "_csrf=$raw")
    @test layer(form).status == 200

    json = HTTP.Request("POST", "/form",
        ["Content-Type" => "application/json", "Cookie" => "__Host-csrf_token=$issued"],
        JSON.json(Dict("_csrf" => raw)))
    @test layer(json).status == 200
end

@testset "a JSON-body token nested past the depth bound is not presented (#314)" begin
    # The JSON-body fallback reads the token through `getjson`, whose parse is depth-bounded:
    # past 512 levels the body is malformed JSON, so no token is presented and the request is
    # the ordinary 403. One level shallower, the same token is accepted -- so the 403 is the
    # bound's, not a broken round trip. The pre-#314 parser accepted both.
    layer = bound_layer(SESSION_A)
    issued = cookie_value(layer(request("GET")), "__Host-csrf_token")
    raw = String(split(issued, '.', limit = 2)[1])
    padded(d) = "{\"_csrf\":\"" * raw * "\",\"pad\":" * repeat("[", d) * repeat("]", d) * "}"
    post(body) = layer(request("POST", Dict("__Host-csrf_token" => issued);
                               headers = ["Content-Type" => "application/json"], body = body))

    @test CSRF._presented_token(request("POST"; headers = ["Content-Type" => "application/json"],
                                        body = padded(512)), "X-CSRF-Token", "_csrf") === nothing
    @test post(padded(512)).status == 403
    @test post(padded(511)).status == 200
end

@testset "unsafe requests are rejected without a valid pair" begin
    layer = bound_layer(SESSION_A)
    issued = cookie_value(layer(request("GET")), "__Host-csrf_token")
    raw, sig = String.(split(issued, '.', limit = 2))

    reject(req) = layer(req).status == 403

    @test reject(request("POST"))                                                   # nothing at all
    @test reject(request("POST", Dict("__Host-csrf_token" => issued)))              # cookie, no header
    @test reject(request("POST"; headers = ["X-CSRF-Token" => raw]))                # header, no cookie
    @test reject(request("POST", Dict("__Host-csrf_token" => issued);
                         headers = ["X-CSRF-Token" => CSRF._generate_raw_token()])) # wrong token

    # Tampered signature: the raw half still matches the header, so only the HMAC check stops it.
    tampered_sig = raw * "." * CSRF._csrf_signature(SECRET, raw, SESSION_B)
    @test reject(request("POST", Dict("__Host-csrf_token" => tampered_sig);
                         headers = ["X-CSRF-Token" => raw]))

    # Tampered raw half, signature left intact.
    other_raw = CSRF._generate_raw_token()
    @test reject(request("POST", Dict("__Host-csrf_token" => other_raw * "." * sig);
                         headers = ["X-CSRF-Token" => other_raw]))

    # Malformed cookies reach `_parse_signed_token`; none of these may 200.
    for malformed in ("nodot", "", ".", "$raw.", ".$sig", "$raw.$(sig)x")
        @test reject(request("POST", Dict("__Host-csrf_token" => malformed);
                             headers = ["X-CSRF-Token" => raw]))
    end
end

@testset "a token is not portable between sessions" begin
    # #23: the attacker mints a token for THEIR session, plants cookie + header on the victim, and
    # under the unbound implementation it validated. Both halves are genuine here -- only the
    # binding differs.
    victim = bound_layer(SESSION_A)
    attacker_cookie = cookie_value(bound_layer(SESSION_B)(request("GET")), "__Host-csrf_token")
    attacker_raw = String(split(attacker_cookie, '.', limit = 2)[1])

    forged = request("POST", Dict("__Host-csrf_token" => attacker_cookie);
                     headers = ["X-CSRF-Token" => attacker_raw])
    @test victim(forged).status == 403

    # ... and it still works for the session it belongs to, so the rejection is about binding.
    @test bound_layer(SESSION_B)(request("POST", Dict("__Host-csrf_token" => attacker_cookie);
                                         headers = ["X-CSRF-Token" => attacker_raw])).status == 200
end

@testset "validate_csrf_token honours an explicit binding" begin
    res = HTTP.Response(200, "ok")
    token = issue_csrf_token!(res, SECRET; binding = SESSION_A)
    value = cookie_value(res, "__Host-csrf_token")
    req = request("POST", Dict("__Host-csrf_token" => value); headers = ["X-CSRF-Token" => token])

    @test validate_csrf_token(req, SECRET; binding = SESSION_A)
    @test !validate_csrf_token(req, SECRET; binding = SESSION_B)
    @test !validate_csrf_token(req, SECRET; binding = nothing)
    # A request with no session on its context defaults to `nothing` and so fails closed.
    @test !validate_csrf_token(req, SECRET)
end

@testset "no session means no token and no mutation" begin
    # Fail closed. The pipeline is misconfigured (SessionMiddleware missing or inside CSRF), and
    # that must be loud at the first mutation rather than a silent fallback to unbound tokens.
    layer = CSRFMiddleware(SECRET)(ok_handler)

    get_res = layer(HTTP.Request("GET", "/form"))
    @test get_res.status == 200
    @test isempty(set_cookie_headers(get_res))            # nothing to bind to => nothing issued

    post_res = layer(HTTP.Request("POST", "/form", ["X-CSRF-Token" => CSRF._generate_raw_token()]))
    @test post_res.status == 403
end

# ── integration with SessionMiddleware ────────────────────────────────────────

@testset "issued once, then reused while the session holds" begin
    asking, store = session_layer(handler = token_handler)
    layer, _ = session_layer(store = store)

    first = asking(HTTP.Request("GET", "/form"))
    session_id = cookie_value(first, "unit_session")
    token_cookie = cookie_value(first, "__Host-csrf_token")
    jar = Dict("unit_session" => session_id, "__Host-csrf_token" => token_cookie)

    # A second safe request with a still-valid cookie must NOT mint a replacement.
    second = layer(request("GET", jar))
    @test !any(startswith("__Host-csrf_token="), set_cookie_headers(second))
    # Asking again re-sends the cookie to refresh its Max-Age, but with the SAME token.
    @test raw_half(cookie_value(asking(request("GET", jar)), "__Host-csrf_token")) == raw_half(token_cookie)
end

# #317: `SessionMiddleware` now saves a NEW session only when something marks it modified. A token
# is bound to the session id, so every path that hands one out must keep the session -- or the
# anonymous visitor's next request gets a fresh id, the token no longer verifies, and every POST
# is a 403. These three testsets are the three issuing paths. The first used to be any safe
# request; since #431 it is a request whose handler asked with `csrf_token!`.
@testset "an anonymous visitor's first GET keeps the session its token is bound to (#317)" begin
    layer, store = session_layer(handler = token_handler)

    first = layer(HTTP.Request("GET", "/form"))
    session_id = cookie_value(first, "unit_session")
    token_cookie = cookie_value(first, "__Host-csrf_token")
    @test Base.get(store, session_id, nothing) !== nothing        # saved, though still empty
    @test CSRF._verify_signed_token(SECRET, token_cookie, session_id) !== nothing

    raw = String(split(token_cookie, '.', limit = 2)[1])
    post = layer(request("POST", Dict("unit_session" => session_id,
                                      "__Host-csrf_token" => token_cookie);
                         headers = ["X-CSRF-Token" => raw]))
    @test post.status == 200
end

@testset "a handler-minted token keeps its session too (#317)" begin
    minting(req) = begin
        res = HTTP.Response(200, "ok")
        issue_csrf_token!(res, SECRET; binding = req.context[:session_id])
        res
    end
    layer, store = session_layer(handler = minting)

    res = layer(HTTP.Request("GET", "/form"))
    session_id = cookie_value(res, "unit_session")
    @test Base.get(store, session_id, nothing) !== nothing
    @test CSRF._verify_signed_token(SECRET, cookie_value(res, "__Host-csrf_token"), session_id) !== nothing
end

@testset "a refused POST on a lost session re-issues against a session that is kept (#317)" begin
    # The client holds a genuine token pair, but its session is gone (pruned, or the store
    # restarted): the presented id is unknown, so `SessionMiddleware` mints a fresh one. The
    # rejection path re-issues a token bound to that fresh id -- which is only usable if the
    # fresh session is saved and handed to the client in the same response.
    layer, store = session_layer()
    lost = "33333333-3333-4333-8333-333333333333"
    stale = HTTP.Response(200, "ok")
    issue_csrf_token!(stale, SECRET; binding = lost)
    token_cookie = cookie_value(stale, "__Host-csrf_token")
    raw = String(split(token_cookie, '.', limit = 2)[1])

    refused = layer(request("POST", Dict("unit_session" => lost, "__Host-csrf_token" => token_cookie);
                            headers = ["X-CSRF-Token" => raw]))
    @test refused.status == 403
    fresh_session = cookie_value(refused, "unit_session")
    fresh_token = cookie_value(refused, "__Host-csrf_token")
    @test fresh_session != lost
    @test Base.get(store, fresh_session, nothing) !== nothing
    @test CSRF._verify_signed_token(SECRET, fresh_token, fresh_session) !== nothing

    fresh_raw = String(split(fresh_token, '.', limit = 2)[1])
    retry = layer(request("POST", Dict("unit_session" => fresh_session,
                                       "__Host-csrf_token" => fresh_token);
                          headers = ["X-CSRF-Token" => fresh_raw]))
    @test retry.status == 200
end

@testset "a handler-driven rotation re-issues the token in the same response" begin
    # `regenerate_session!` orphans a token bound to the old id. Issuing only when the cookie is
    # ABSENT would leave the client holding a permanently invalid token -- a login that locks out
    # every later mutation. The re-issue below is what prevents that.
    store = MemoryStore{String, Dict{String,Any}}()
    rotating(req) = (regenerate_session!(req, store); HTTP.Response(200, "ok"))
    layer = SessionMiddleware(cookie_name = "unit_session", store = store).middleware(
        CSRFMiddleware(SECRET)(rotating))

    res = layer(HTTP.Request("GET", "/form"))
    new_session = cookie_value(res, "unit_session")
    new_token = cookie_value(res, "__Host-csrf_token")

    # The token in that same response is bound to the POST-rotation session id.
    @test CSRF._verify_signed_token(SECRET, new_token, new_session) !== nothing

    # And it is immediately usable.
    raw = String(split(new_token, '.', limit = 2)[1])
    followup = layer(request("POST", Dict("unit_session" => new_session,
                                          "__Host-csrf_token" => new_token);
                             headers = ["X-CSRF-Token" => raw]))
    @test followup.status == 200
end

@testset "SessionMiddleware's rotate_on_auth login does not lock the client out" begin
    # The regression this file exists to catch. `rotate_on_auth` rotates the session id in
    # SessionMiddleware's POST-handler block -- AFTER CSRFMiddleware has returned -- so the login
    # response cannot carry a re-issued token, and the client's cookie is orphaned the moment the
    # response lands. Without the re-issue on the rejection path, an SPA that only ever POSTs
    # 403s forever: nothing in its traffic is a safe method, so nothing ever mints a replacement.
    store = MemoryStore{String, Dict{String,Any}}()
    # Only the POST logs in; a GET that also set `user_id` would leave the auth marker unchanged
    # on the POST and nothing would rotate -- the fixture has to model a real login. The GET is
    # the login page, which asks for the token it would put in the form (#431).
    login(req) = begin
        req.method == "GET" && csrf_token!(req)
        req.method == "POST" && (getsession(req)["user_id"] = "u1")
        HTTP.Response(200, "ok")
    end
    layer = SessionMiddleware(cookie_name = "unit_session", store = store).middleware(
        CSRFMiddleware(SECRET)(login))

    first = layer(HTTP.Request("GET", "/form"))
    session_id = cookie_value(first, "unit_session")
    token_cookie = cookie_value(first, "__Host-csrf_token")
    raw = String(split(token_cookie, '.', limit = 2)[1])

    login_res = layer(request("POST", Dict("unit_session" => session_id,
                                           "__Host-csrf_token" => token_cookie);
                              headers = ["X-CSRF-Token" => raw]))
    @test login_res.status == 200
    rotated_session = cookie_value(login_res, "unit_session")
    @test rotated_session != session_id                                    # the session rotated
    @test CSRF._verify_signed_token(SECRET, token_cookie, rotated_session) === nothing  # orphaned

    # The next mutation is refused -- correctly, the token no longer belongs to this session --
    # but it must come back carrying a usable replacement rather than leaving a dead end.
    refused = layer(request("POST", Dict("unit_session" => rotated_session,
                                         "__Host-csrf_token" => token_cookie);
                            headers = ["X-CSRF-Token" => raw]))
    @test refused.status == 403
    fresh = cookie_value(refused, "__Host-csrf_token")
    @test CSRF._verify_signed_token(SECRET, fresh, rotated_session) !== nothing

    # ... and the retry with it succeeds, so the client is never stuck.
    fresh_raw = String(split(fresh, '.', limit = 2)[1])
    retry = layer(request("POST", Dict("unit_session" => rotated_session,
                                       "__Host-csrf_token" => fresh);
                          headers = ["X-CSRF-Token" => fresh_raw]))
    @test retry.status == 200
end

@testset "a blind replay is refused WITHOUT being handed a token" begin
    # The recovery above is kept off the blind-replay path by `_client_echoed_own_cookie`. That
    # check proves self-consistency, NOT authenticity -- a client that plants its own `x.y` + `x`
    # pair satisfies it -- so this testset claims only what it demonstrates: a replayed cookie
    # with a guessed token gets nothing back. What actually bounds the churn risk is the cookie
    # configuration (`__Host-`, `SameSite=Lax`); see `_client_echoed_own_cookie`'s docstring.
    layer = bound_layer(SESSION_A)
    victim_cookie = cookie_value(layer(request("GET")), "__Host-csrf_token")

    # Replayed cookie, guessed token: the shape of a real cross-site forgery.
    forged = layer(request("POST", Dict("__Host-csrf_token" => victim_cookie);
                           headers = ["X-CSRF-Token" => CSRF._generate_raw_token()]))
    @test forged.status == 403
    @test isempty(set_cookie_headers(forged))

    # No cookie at all, likewise.
    @test isempty(set_cookie_headers(layer(request("POST"))))
end

@testset "the signed message is unambiguous across the token/binding split" begin
    # A `token * sep * binding` encoding lets an attacker whose binding is "X|<victim>" take a
    # server-minted signature and re-slice it so the same bytes verify for the victim. The
    # length prefix makes each (token, binding) pair encode exactly one way.
    token = CSRF._generate_raw_token()
    victim = SESSION_A
    attacker = "X|" * victim

    minted = CSRF._csrf_signature(SECRET, token, attacker)          # legitimately the attacker's
    resliced_token = token * "|X"                                   # ... re-cut across the seam
    @test CSRF._csrf_signature(SECRET, resliced_token, victim) != minted

    # Pairs that collide under a `|` join specifically -- move the separator across the split and
    # the joined message is byte-identical, so only a length-prefixed encoding tells them apart.
    @test CSRF._csrf_signature(SECRET, "a", "b|c") != CSRF._csrf_signature(SECRET, "a|b", "c")
    @test CSRF._csrf_signature(SECRET, "", "a|b") != CSRF._csrf_signature(SECRET, "|a", "b")
    # ... and under a bare concatenation with no separator at all.
    @test CSRF._csrf_signature(SECRET, "a", "bc") != CSRF._csrf_signature(SECRET, "ab", "c")
end

@testset "a handler that mints its own token is not shadowed" begin
    # `set_cookie!` appends and the browser keeps the last cookie, so a middleware re-issue on
    # top of a handler-minted token would hand the client a cookie that does not match the raw
    # token the handler returned in its body -- every later mutation would 403.
    minting(req) = begin
        res = HTTP.Response(200, "ok")
        issue_csrf_token!(res, SECRET; binding = req.context[:session_id])
        res
    end
    layer, _ = session_layer(handler = minting)

    res = layer(HTTP.Request("GET", "/form"))
    @test count(startswith("__Host-csrf_token="), set_cookie_headers(res)) == 1
end

@testset "a stale token is replaced on the next safe request" begin
    # The replacement is unasked: the second request's handler never calls `csrf_token!`. It is
    # minted because the session already exists, so the token costs no new store row (#431).
    store = MemoryStore{String, Dict{String,Any}}()
    asking, _ = session_layer(handler = token_handler, store = store)
    layer, _ = session_layer(store = store)
    first = asking(HTTP.Request("GET", "/form"))
    session_id = cookie_value(first, "unit_session")

    # Simulate a token minted under a different session (or an expired secret): still well-formed,
    # just not valid here.
    stale = HTTP.Response(200, "ok")
    issue_csrf_token!(stale, SECRET; binding = SESSION_B)
    stale_value = cookie_value(stale, "__Host-csrf_token")

    refreshed = layer(request("GET", Dict("unit_session" => session_id,
                                          "__Host-csrf_token" => stale_value)))
    fresh = cookie_value(refreshed, "__Host-csrf_token")
    @test fresh != stale_value
    @test CSRF._verify_signed_token(SECRET, fresh, session_id) !== nothing
end

@testset "req.context[:csrf_token] carries the token to the handler, masked (#436)" begin
    seen = Ref{Any}(:unset)
    capture(req) = (seen[] = Base.get(req.context, :csrf_token, :missing); HTTP.Response(200, "ok"))
    store = MemoryStore{String, Dict{String,Any}}()
    layer, _ = session_layer(handler = capture, store = store)
    asking, _ = session_layer(handler = token_handler, store = store)

    # First visit: no cookie yet, so the handler sees `nothing` -- and since it did not ask,
    # nothing is minted after it either (#431).
    unasked = layer(HTTP.Request("GET", "/form"))
    @test seen[] === nothing
    @test isempty(set_cookie_headers(unasked))

    first = asking(HTTP.Request("GET", "/form"))
    session_id = cookie_value(first, "unit_session")
    token_cookie = cookie_value(first, "__Host-csrf_token")

    # Second visit: the handler sees the client's token masked -- neither the signed cookie value
    # nor the raw token, which is the fixed secret a compressed body must never carry.
    jar = Dict("unit_session" => session_id, "__Host-csrf_token" => token_cookie)
    layer(request("GET", jar))
    first_seen = seen[]
    @test first_seen isa String
    @test first_seen != raw_half(token_cookie)
    @test unmasked(first_seen) == raw_half(token_cookie)
    # A new request, a new mask over the same token.
    layer(request("GET", jar))
    @test seen[] != first_seen
    @test unmasked(seen[]) == raw_half(token_cookie)
end

# ── masking (#436) ────────────────────────────────────────────────────────────
# Since #431 the token goes into response bodies. A compressed body holding a fixed secret next to
# reflected input leaks the secret through its length (BREACH), so every value handed out is
# `mask ‖ (mask ⊕ raw)` under a fresh mask, and validation unmasks before comparing.

@testset "csrf_token! masks the token per call, and every mask verifies (#436)" begin
    tokens = String[]
    twice(req) = (push!(tokens, csrf_token!(req)); push!(tokens, csrf_token!(req));
                  HTTP.Response(200, "ok"))
    layer, _ = session_layer(handler = twice)
    res = layer(HTTP.Request("GET", "/form"))
    session_id = cookie_value(res, "unit_session")
    token_cookie = cookie_value(res, "__Host-csrf_token")
    jar = Dict("unit_session" => session_id, "__Host-csrf_token" => token_cookie)

    # A copy: every request below runs `twice` again and appends to `tokens`.
    handed = copy(tokens)
    @test length(handed) == 2
    @test handed[1] != handed[2]                                  # nothing stable to leak
    @test all(t -> ncodeunits(t) == CSRF._MASKED_LENGTH, handed)
    @test all(t -> occursin(r"^[A-Za-z0-9_-]+$", t), handed)      # still needs no HTML escaping
    @test all(t -> unmasked(t) == raw_half(token_cookie), handed) # one token, two masks
    for t in handed
        @test layer(request("POST", jar; headers = ["X-CSRF-Token" => t])).status == 200
    end

    # The form field and the JSON key take the masked form too.
    cookie_header = "unit_session=$session_id; __Host-csrf_token=$token_cookie"
    form = HTTP.Request("POST", "/form",
        ["Content-Type" => "application/x-www-form-urlencoded", "Cookie" => cookie_header],
        "_csrf=$(handed[1])")
    @test layer(form).status == 200
    json = HTTP.Request("POST", "/form",
        ["Content-Type" => "application/json", "Cookie" => cookie_header],
        JSON.json(Dict("_csrf" => handed[2])))
    @test layer(json).status == 200

    # The raw token -- the cookie's part before the first `.`, which a single-page app can read
    # from `document.cookie` -- is still accepted. Nitro never writes it into a body.
    @test layer(request("POST", jar; headers = ["X-CSRF-Token" => raw_half(token_cookie)])).status == 200
end

@testset "after the handler, req.context[:csrf_token] is the value it was handed (#436)" begin
    # An outer layer reading the context sees what the handler put in its body, not a re-mask:
    # the middleware re-masks only a token it minted itself after the handler.
    returned = Ref{String}("")
    asking(req) = (returned[] = csrf_token!(req); HTTP.Response(200, "ok"))
    store = MemoryStore{String, Dict{String,Any}}()
    layer, _ = session_layer(handler = asking, store = store)

    first_visit = HTTP.Request("GET", "/form")          # minted by `csrf_token!` here
    res = layer(first_visit)
    @test first_visit.context[:csrf_token] == returned[]
    jar = Dict("unit_session" => cookie_value(res, "unit_session"),
               "__Host-csrf_token" => cookie_value(res, "__Host-csrf_token"))

    again = request("GET", jar)                          # the client's own token, refreshed
    layer(again)
    @test again.context[:csrf_token] == returned[]

    # Minted by the middleware itself (a written session, nobody asked): masked, and it is the
    # token in the cookie.
    writes(req) = (getsession(req)["seen"] = true; HTTP.Response(200, "ok"))
    wlayer, _ = session_layer(handler = writes)
    unasked = HTTP.Request("GET", "/form")
    wres = wlayer(unasked)
    @test unasked.context[:csrf_token] != raw_half(cookie_value(wres, "__Host-csrf_token"))
    @test unmasked(unasked.context[:csrf_token]) == raw_half(cookie_value(wres, "__Host-csrf_token"))
end

@testset "a verified cookie of a shape Nitro never mints is not a token (#436)" begin
    # `_mask_token` decodes the verified raw half, so a validly-signed value of another shape
    # must be refused at verification -- not reach the mask and throw a 500 on every request.
    odd_raw = "short"
    odd = odd_raw * "." * CSRF._csrf_signature(SECRET, odd_raw, SESSION_A)
    @test CSRF._verify_signed_token(SECRET, odd, SESSION_A) === nothing
    res = bound_layer(SESSION_A)(request("GET", Dict("__Host-csrf_token" => odd)))
    @test res.status == 200
end

@testset "a masked token is bound to its session like a raw one (#436)" begin
    res = HTTP.Response(200, "ok")
    masked = issue_csrf_token!(res, SECRET; binding = SESSION_A)
    cookie = Dict("__Host-csrf_token" => cookie_value(res, "__Host-csrf_token"))

    @test bound_layer(SESSION_A)(request("POST", cookie; headers = ["X-CSRF-Token" => masked])).status == 200
    @test bound_layer(SESSION_B)(request("POST", cookie; headers = ["X-CSRF-Token" => masked])).status == 403

    # A masked copy of a DIFFERENT token never matches, however well-formed.
    other = CSRF._mask_token(CSRF._generate_raw_token())
    @test bound_layer(SESSION_A)(request("POST", cookie; headers = ["X-CSRF-Token" => other])).status == 403
end

@testset "a tampered or malformed masked token is refused, never an error (#436)" begin
    res = HTTP.Response(200, "ok")
    masked = issue_csrf_token!(res, SECRET; binding = SESSION_A)
    cookie = Dict("__Host-csrf_token" => cookie_value(res, "__Host-csrf_token"))
    layer = bound_layer(SESSION_A)

    swap(c) = c == 'A' ? 'B' : 'A'
    flip(s, i) = string(s[1:i-1], swap(s[i]), s[i+1:end])
    half = CSRF._MASKED_LENGTH ÷ 2
    candidates = [
        "mask half"          => flip(masked, 1),
        "cipher half"        => flip(masked, half + 2),
        "one char short"     => masked[1:end-1],
        "one char long"      => masked * "A",
        "not base64url"      => "!"^CSRF._MASKED_LENGTH,
        "non-ASCII"          => "é"^(CSRF._MASKED_LENGTH ÷ 2),  # 86 code units, not 86 chars
        "padded base64"      => masked[1:end-2] * "==",
        "empty"              => "",
    ]
    for (label, bad) in candidates
        @test CSRF._unmask_token(bad) != unmasked(masked)
        refused = layer(request("POST", cookie; headers = ["X-CSRF-Token" => bad]))
        @test (label, refused.status) == (label, 403)
    end
    # The untouched value still verifies, so the refusals above are about the edits.
    @test layer(request("POST", cookie; headers = ["X-CSRF-Token" => masked])).status == 200
end

@testset "a stale MASKED token on a refused request still gets a fresh cookie (#436)" begin
    # The recovery path (`_client_echoed_own_cookie`) must recognise the client's own token in
    # the form `csrf_token!` handed out, not only the raw one -- or every SPA would be stuck.
    res = HTTP.Response(200, "ok")
    masked = issue_csrf_token!(res, SECRET; binding = SESSION_A)
    cookie = Dict("__Host-csrf_token" => cookie_value(res, "__Host-csrf_token"))

    refused = bound_layer(SESSION_B)(request("POST", cookie; headers = ["X-CSRF-Token" => masked]))
    @test refused.status == 403
    @test CSRF._verify_signed_token(SECRET, cookie_value(refused, "__Host-csrf_token"), SESSION_B) !== nothing

    # A masked value of some OTHER token is a blind replay: refused with nothing handed back.
    other = CSRF._mask_token(CSRF._generate_raw_token())
    blind = bound_layer(SESSION_B)(request("POST", cookie; headers = ["X-CSRF-Token" => other]))
    @test blind.status == 403
    @test !any(startswith("__Host-csrf_token="), set_cookie_headers(blind))
end

# ── lazy minting (#431) ───────────────────────────────────────────────────────
# A global `CSRFMiddleware` used to mint on every safe response and mark the session modified to
# keep the token's binding alive, so every cookieless GET -- health checks, bearer clients,
# scanners -- became a stored session: #317's growth, back through CSRF. Now a token goes out
# only when a handler asks (`csrf_token!`) or when the session is saved anyway.

@testset "a cookieless GET that nobody asked a token for creates nothing (#431)" begin
    reads_session(req) = (Base.get(getsession(req), "x", nothing); HTTP.Response(200, "ok"))
    layer, store = session_layer(handler = reads_session)

    res = layer(HTTP.Request("GET", "/form"))
    @test res.status == 200
    @test isempty(set_cookie_headers(res))           # neither a CSRF nor a session cookie
    @test session_count(store) == 0

    # The issue's reproduction, through an `App` and the request pipeline.
    app = App()
    urlpatterns(app, "", path("/x", req -> (Base.get(getsession(req), "x", nothing); Res.send("ok"));
                              method = "GET"))
    app_store = MemoryStore{String, Dict{String,Any}}()
    insecure = CookieConfig(httponly = false, secure = false, samesite = "Lax", path = "/", maxage = 3600)
    r = internalrequest(app, HTTP.Request("GET", "/x"); middleware = [
        SessionMiddleware(store = app_store, secure = false),
        CSRFMiddleware(SECRET; cookie_name = "csrf_token", config = insecure)])
    @test r.status == 200
    @test !any(h -> lowercase(h.first) == "set-cookie", r.headers)
    @test session_count(app_store) == 0
end

@testset "csrf_token! on a first visit mints the token it returns (#431)" begin
    returned = Ref{String}("")
    asking(req) = (returned[] = csrf_token!(req); HTTP.Response(200, returned[]))
    layer, store = session_layer(handler = asking)

    res = layer(HTTP.Request("GET", "/form"))
    session_id = cookie_value(res, "unit_session")
    token_cookie = cookie_value(res, "__Host-csrf_token")
    # The value the handler embedded is the cookie's raw half under a mask (#436): the body never
    # carries the raw token itself.
    @test raw_half(token_cookie) == unmasked(returned[])
    @test String(res.body) == returned[]
    @test !occursin(raw_half(token_cookie), String(res.body))
    @test CSRF._verify_signed_token(SECRET, token_cookie, session_id) == unmasked(returned[])
    @test session_count(store) == 1

    post = layer(request("POST", Dict("unit_session" => session_id, "__Host-csrf_token" => token_cookie);
                         headers = ["X-CSRF-Token" => returned[]]))
    @test post.status == 200
end

@testset "an existing session gets a token unasked, and no new row (#431)" begin
    store = MemoryStore{String, Dict{String,Any}}()
    Nitro.Types.set_session!(store, SESSION_A, Dict{String,Any}("cart" => [1]); ttl = 3600)
    layer, _ = session_layer(store = store)

    res = layer(request("GET", Dict("unit_session" => SESSION_A)))
    @test CSRF._verify_signed_token(SECRET, cookie_value(res, "__Host-csrf_token"), SESSION_A) !== nothing
    @test session_count(store) == 1
end

@testset "a new session the handler writes to gets a token unasked (#431)" begin
    writes(req) = (getsession(req)["seen"] = true; HTTP.Response(200, "ok"))
    layer, store = session_layer(handler = writes)

    res = layer(HTTP.Request("GET", "/form"))
    session_id = cookie_value(res, "unit_session")
    @test CSRF._verify_signed_token(SECRET, cookie_value(res, "__Host-csrf_token"), session_id) !== nothing
    @test session_count(store) == 1
end

@testset "csrf_token! returns a valid token the client already holds (#431)" begin
    store = MemoryStore{String, Dict{String,Any}}()
    first = session_layer(handler = token_handler, store = store)[1](HTTP.Request("GET", "/form"))
    session_id = cookie_value(first, "unit_session")
    token_cookie = cookie_value(first, "__Host-csrf_token")
    jar = Dict("unit_session" => session_id, "__Host-csrf_token" => token_cookie)

    returned = Ref{String}("")
    asking(req) = (returned[] = csrf_token!(req); HTTP.Response(200, "ok"))
    layer, _ = session_layer(handler = asking, store = store)

    again = layer(request("GET", jar))
    @test unmasked(returned[]) == raw_half(token_cookie)
    # The cookie is re-sent with the SAME token, so its Max-Age starts again: a token just put in
    # a page must not expire before the page is used (Django re-sends whenever `get_token` runs).
    @test raw_half(cookie_value(again, "__Host-csrf_token")) == unmasked(returned[])
    @test occursin("Max-Age=604800", cookie_line(again, "__Host-csrf_token"))
    @test session_count(store) == 1
    # The refresh carries one visitor's token with no session write, so CSRF marks it private
    # itself: a shared cache must never hand A's token to B.
    @test occursin("private", HTTP.header(again, "Cache-Control"))
    @test any(h -> lowercase(h.first) == "vary" && occursin("Cookie", h.second), again.headers)
    # ... and it forces no session write: the stored expiry is untouched.
    expires_before = Base.get(store, session_id, nothing).expires
    sleep(0.01)
    layer(request("GET", jar))
    @test Base.get(store, session_id, nothing).expires == expires_before

    # After a validated POST the handler gets the token the client just presented, so a form
    # re-rendered with errors carries a token that still works.
    returned[] = ""
    post = layer(request("POST", jar; headers = ["X-CSRF-Token" => raw_half(token_cookie)]))
    @test post.status == 200
    @test unmasked(returned[]) == raw_half(token_cookie)
    @test raw_half(cookie_value(post, "__Host-csrf_token")) == unmasked(returned[])

    # A request that does not ask re-sends nothing while the cookie is valid.
    plain, _ = session_layer(store = store)
    @test !any(startswith("__Host-csrf_token="), set_cookie_headers(plain(request("GET", jar))))
end

@testset "a login rotation retires the client's existing token (#431)" begin
    # The client's token from BEFORE the rotation must not be re-bound to the post-login session:
    # whoever knew it before -- another user of a shared browser -- would keep a working token for
    # the victim's account. Django's `rotate_token` on login; the pre-#431 code minted fresh too.
    store = MemoryStore{String, Dict{String,Any}}()
    first = session_layer(handler = token_handler, store = store)[1](HTTP.Request("GET", "/form"))
    old_session = cookie_value(first, "unit_session")
    old_cookie = cookie_value(first, "__Host-csrf_token")
    jar = Dict("unit_session" => old_session, "__Host-csrf_token" => old_cookie)

    # Asked AFTER rotating, as a login should: a new token, returned and in the cookie.
    returned = Ref{String}("")
    login_then_ask(req) = (regenerate_session!(req, store); returned[] = csrf_token!(req);
                           HTTP.Response(200, "ok"))
    res = session_layer(handler = login_then_ask, store = store)[1](request("GET", jar))
    new_session = cookie_value(res, "unit_session")
    token_cookie = cookie_value(res, "__Host-csrf_token")
    @test new_session != old_session
    @test unmasked(returned[]) != raw_half(old_cookie)
    @test raw_half(token_cookie) == unmasked(returned[])
    @test CSRF._verify_signed_token(SECRET, token_cookie, new_session) == unmasked(returned[])

    # Asked BEFORE rotating: the handler got the old token, and the rotation still retires it --
    # the cookie carries a fresh one. (Documented: call `csrf_token!` after `regenerate_session!`.)
    store2 = MemoryStore{String, Dict{String,Any}}()
    first2 = session_layer(handler = token_handler, store = store2)[1](HTTP.Request("GET", "/form"))
    jar2 = Dict("unit_session" => cookie_value(first2, "unit_session"),
                "__Host-csrf_token" => cookie_value(first2, "__Host-csrf_token"))
    ask_then_login(req) = (returned[] = csrf_token!(req); regenerate_session!(req, store2);
                           HTTP.Response(200, "ok"))
    res2 = session_layer(handler = ask_then_login, store = store2)[1](request("GET", jar2))
    @test unmasked(returned[]) == raw_half(jar2["__Host-csrf_token"])
    @test raw_half(cookie_value(res2, "__Host-csrf_token")) != unmasked(returned[])
    @test CSRF._verify_signed_token(SECRET, cookie_value(res2, "__Host-csrf_token"),
                                    cookie_value(res2, "unit_session")) !== nothing
end

@testset "a new session marked modified, or rotated, gets a token unasked (#431)" begin
    # The two remaining ways a new session is saved without CSRF's help.
    flagging(req) = (req.context[:session_modified] = true; HTTP.Response(200, "ok"))
    layer, store = session_layer(handler = flagging)
    res = layer(HTTP.Request("GET", "/form"))
    @test CSRF._verify_signed_token(SECRET, cookie_value(res, "__Host-csrf_token"),
                                    cookie_value(res, "unit_session")) !== nothing
    @test session_count(store) == 1

    rstore = MemoryStore{String, Dict{String,Any}}()
    rotating(req) = (regenerate_session!(req, rstore); HTTP.Response(200, "ok"))
    rlayer, _ = session_layer(handler = rotating, store = rstore)
    rres = rlayer(HTTP.Request("GET", "/form"))
    @test CSRF._verify_signed_token(SECRET, cookie_value(rres, "__Host-csrf_token"),
                                    cookie_value(rres, "unit_session")) !== nothing
    @test session_count(rstore) == 1
end

@testset "csrf_token! then a rotation: the cookie carries the returned token (#431)" begin
    # The handler may already have written the token into its body when it rotates the session,
    # so the cookie must carry THAT token, signed for the new id -- not a fresh one.
    store = MemoryStore{String, Dict{String,Any}}()
    Nitro.Types.set_session!(store, SESSION_A, Dict{String,Any}(); ttl = 3600)
    returned = Ref{String}("")
    rotating(req) = begin
        returned[] = csrf_token!(req)
        regenerate_session!(req, store)
        HTTP.Response(200, "ok")
    end
    layer, _ = session_layer(handler = rotating, store = store)

    res = layer(request("GET", Dict("unit_session" => SESSION_A)))
    new_session = cookie_value(res, "unit_session")
    token_cookie = cookie_value(res, "__Host-csrf_token")
    @test new_session != SESSION_A
    @test raw_half(token_cookie) == unmasked(returned[])
    @test CSRF._verify_signed_token(SECRET, token_cookie, new_session) == unmasked(returned[])
    @test CSRF._verify_signed_token(SECRET, token_cookie, SESSION_A) === nothing
end

@testset "csrf_token! refuses to hand out an unbound token (#431)" begin
    # No CSRFMiddleware at all: there is no cookie to back the token, so it would never verify.
    # A session id IS present, so only the "middleware did not run" check can refuse it.
    bare = HTTP.Request("GET", "/form")
    bare.context[:session_id] = SESSION_A
    err = try csrf_token!(bare); nothing catch e; e end
    @test err isa ArgumentError
    @test occursin("did not handle", sprint(showerror, err))

    # CSRFMiddleware without a session: fail closed, never an unbound token.
    thrown = Ref{Any}(nothing)
    catching(req) = (try csrf_token!(req) catch e; thrown[] = e end; HTTP.Response(200, "ok"))
    res = CSRFMiddleware(SECRET)(catching)(HTTP.Request("GET", "/form"))
    @test thrown[] isa ArgumentError
    @test isempty(set_cookie_headers(res))
end

end
