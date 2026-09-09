@testitem "CSRF middleware" tags=[:middleware, :security, :csrf] setup=[NitroCommon] begin

using HTTP
using JSON
using Nitro
using Nitro: CSRFMiddleware, SessionMiddleware, CookieConfig, regenerate_session!
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

"""Build a request already carrying `cookies` (a name => value dict) plus `headers`."""
function request(method, cookies::Dict{String,String} = Dict{String,String}(); headers = Pair{String,String}[], body = nothing)
    hs = Pair{String,String}[h for h in headers]
    isempty(cookies) || push!(hs, "Cookie" => join(("$k=$v" for (k, v) in cookies), "; "))
    return body === nothing ? HTTP.Request(method, "/form", hs) : HTTP.Request(method, "/form", hs, body)
end

ok_handler(req) = HTTP.Response(200, "ok")

"""A CSRF layer whose binding is fixed to `session_id`, with no SessionMiddleware involved."""
function bound_layer(session_id::String; kwargs...)
    csrf = CSRFMiddleware(SECRET; kwargs...)(ok_handler)
    return function (req::HTTP.Request)
        req.context[:session_id] = session_id
        return csrf(req)
    end
end

"""A real SessionMiddleware wrapped around CSRFMiddleware, plus its store."""
function session_layer(; csrf_kwargs = (;), handler = ok_handler)
    store = MemoryStore{String, Dict{String,Any}}()
    layer = SessionMiddleware(cookie_name = "unit_session", store = store, prune_probability = 0.0)(
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
    raw = issue_csrf_token!(res, SECRET; binding = SESSION_A)
    line = cookie_line(res, "__Host-csrf_token")

    @test occursin("Secure", line)                    # required by the __Host- prefix
    @test occursin("Path=/", line)                    # required by the __Host- prefix
    @test !occursin("Domain=", line)                  # required by the __Host- prefix
    @test !occursin("HttpOnly", line)                 # deliberate: the SPA has to read it
    @test occursin("SameSite=Lax", line)
    @test occursin("Max-Age=3600", line)

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
    raw = issue_csrf_token!(res, SECRET; binding = SESSION_A)
    value = cookie_value(res, "__Host-csrf_token")
    req = request("POST", Dict("__Host-csrf_token" => value); headers = ["X-CSRF-Token" => raw])

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
    layer, _ = session_layer()

    first = layer(HTTP.Request("GET", "/form"))
    session_id = cookie_value(first, "unit_session")
    token_cookie = cookie_value(first, "__Host-csrf_token")
    jar = Dict("unit_session" => session_id, "__Host-csrf_token" => token_cookie)

    # A second safe request with a still-valid cookie must NOT mint a replacement.
    second = layer(request("GET", jar))
    @test !any(startswith("__Host-csrf_token="), set_cookie_headers(second))
end

@testset "a handler-driven rotation re-issues the token in the same response" begin
    # `regenerate_session!` orphans a token bound to the old id. Issuing only when the cookie is
    # ABSENT would leave the client holding a permanently invalid token -- a login that locks out
    # every later mutation. The re-issue below is what prevents that.
    store = MemoryStore{String, Dict{String,Any}}()
    rotating(req) = (regenerate_session!(req, store); HTTP.Response(200, "ok"))
    layer = SessionMiddleware(cookie_name = "unit_session", store = store, prune_probability = 0.0)(
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
    # on the POST and nothing would rotate -- the fixture has to model a real login.
    login(req) = (req.method == "POST" && (req.session["user_id"] = "u1"); HTTP.Response(200, "ok"))
    layer = SessionMiddleware(cookie_name = "unit_session", store = store, prune_probability = 0.0)(
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
    layer, _ = session_layer()
    first = layer(HTTP.Request("GET", "/form"))
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

@testset "req.context[:csrf_token] carries the raw token to the handler" begin
    seen = Ref{Any}(:unset)
    capture(req) = (seen[] = Base.get(req.context, :csrf_token, :missing); HTTP.Response(200, "ok"))
    layer, _ = session_layer(handler = capture)

    # First visit: no cookie yet, so the handler sees `nothing` and the token is minted after.
    first = layer(HTTP.Request("GET", "/form"))
    @test seen[] === nothing
    session_id = cookie_value(first, "unit_session")
    token_cookie = cookie_value(first, "__Host-csrf_token")

    # Second visit: the handler sees the raw token, not the signed cookie value.
    layer(request("GET", Dict("unit_session" => session_id, "__Host-csrf_token" => token_cookie)))
    @test seen[] == String(split(token_cookie, '.', limit = 2)[1])
end

end
