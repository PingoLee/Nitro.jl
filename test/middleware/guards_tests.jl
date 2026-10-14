@testitem "Guards" tags=[:middleware, :auth] setup=[NitroCommon] begin
using HTTP
using Nitro: GuardMiddleware, login_required, role_required, permission_required,
    claim_required, kid_required, Principal, GET, text

@testset "GuardMiddleware" begin

    @testset "guard blocks unauthenticated" begin
        # A guard that checks for a custom header as a simple auth proxy
        function require_auth(req::HTTP.Request)
            auth = HTTP.header(req, "X-Auth-Token", "")
            if isempty(auth)
                return HTTP.Response(401, ["Content-Type" => "application/json"],
                    codeunits("{\"error\":\"Unauthorized\"}"))
            end
            nothing
        end

        # Create the middleware and compose it with a handler
        mw = GuardMiddleware(require_auth)
        handler = function(req::HTTP.Request)
            return HTTP.Response(200, "OK")
        end
        wrapped = mw(handler)

        # Request without auth header → blocked
        r = wrapped(HTTP.Request("GET", "/guarded"))
        @test r.status == 401

        # Request with auth header → allowed
        r2 = wrapped(HTTP.Request("GET", "/guarded", ["X-Auth-Token" => "valid-token"]))
        @test r2.status == 200
    end

    @testset "multiple stacked guards" begin
        function guard_one(req::HTTP.Request)
            # Always passes
            nothing
        end

        function guard_two(req::HTTP.Request)
            # Blocks if no X-Role header
            role = HTTP.header(req, "X-Role", "")
            if role != "admin"
                return HTTP.Response(403, ["Content-Type" => "text/plain"],
                    codeunits("Forbidden"))
            end
            nothing
        end

        mw = GuardMiddleware(guard_one, guard_two)
        handler = function(req::HTTP.Request)
            return HTTP.Response(200, "Welcome admin!")
        end
        wrapped = mw(handler)

        # No role → blocked by guard_two
        r = wrapped(HTTP.Request("GET", "/multi-guard"))
        @test r.status == 403

        # With admin role → passes both guards
        r2 = wrapped(HTTP.Request("GET", "/multi-guard", ["X-Role" => "admin"]))
        @test r2.status == 200
    end

    @testset "login_required guard" begin
        guard = login_required(redirect_url="/login")

        # No user context → should redirect
        req_no_session = HTTP.Request("GET", "/test")
        result = guard(req_no_session)
        @test result isa HTTP.Response
        @test result.status == 302
        location = HTTP.header(result, "Location", "")
        @test location == "/login"

        # With user context → should pass
        req_with_session = HTTP.Request("GET", "/test")
        req_with_session.context[:user] = Dict{String,Any}("user_id" => 42)
        result2 = guard(req_with_session)
        @test isnothing(result2)

        # An explicitly-set identity WITHOUT the session_key (e.g. JWT claims keyed by
        # `sub`, not `user_id`) is still authenticated — a middleware vouched for it.
        # Requiring the marker here would lock out legitimate token-authenticated users.
        req_claims = HTTP.Request("GET", "/test")
        req_claims.context[:user] = Dict{String,Any}("sub" => "user-123", "exp" => 9999999999)
        @test isnothing(guard(req_claims))

        # A non-Dict identity object set by middleware (e.g. a user struct / NamedTuple)
        # is authenticated too.
        req_struct = HTTP.Request("GET", "/test")
        req_struct.context[:user] = (id = 7, name = "alice")
        @test isnothing(guard(req_struct))

        # Defensive: an EMPTY context[:user] Dict carries no identity → redirect.
        req_empty_user = HTTP.Request("GET", "/test")
        req_empty_user.context[:user] = Dict{String,Any}()
        result_empty = guard(req_empty_user)
        @test result_empty isa HTTP.Response
        @test result_empty.status == 302

        # Auth bypass (regression): an ANONYMOUS visitor with session data but no
        # context[:user] must be redirected — the raw session is NOT an authenticated
        # identity, so it counts only when it carries the login marker.
        req_anon_session = HTTP.Request("GET", "/test")
        req_anon_session.context[:session] = Dict{String,Any}("cart" => [1, 2, 3], "prefs" => "dark")
        result_anon = guard(req_anon_session)
        @test result_anon isa HTTP.Response
        @test result_anon.status == 302

        # Session-based auth via the fallback: a session carrying the session_key (and
        # no context[:user]) is a logged-in user → pass.
        req_session_auth = HTTP.Request("GET", "/test")
        req_session_auth.context[:session] = Dict{String,Any}("user_id" => 7, "cart" => [1])
        @test isnothing(guard(req_session_auth))

        # Custom session_key is honored on the fallback path.
        guard_custom = login_required(redirect_url="/login", session_key="uid")
        req_custom_ok = HTTP.Request("GET", "/test")
        req_custom_ok.context[:session] = Dict{String,Any}("uid" => 99)
        @test isnothing(guard_custom(req_custom_ok))
        req_custom_no = HTTP.Request("GET", "/test")
        req_custom_no.context[:session] = Dict{String,Any}("user_id" => 99)  # wrong key for this guard
        @test guard_custom(req_custom_no).status == 302
    end

    # #313: `login_required` refuses exactly what the auth middleware refuses (`_is_identity`,
    # src/types.jl). Before, any non-`nothing` `:user` except an empty dict passed, so a
    # predicate validator's `false` counted as logged in.
    @testset "login_required refuses a non-identity (#313)" begin
        guard = login_required(redirect_url="/login")
        for bogus in (false, true, "", missing, Dict{String,Any}(), Principal(Dict{String,Any}()))
            req = HTTP.Request("GET", "/test")
            req.context[:user] = bogus
            result = guard(req)
            @test result isa HTTP.Response && result.status == 302
        end

        # A set-but-empty `:user` is a denial, not a fall-through to a logged-in session:
        # the layer that set it vouched for nobody.
        req_vouched_nobody = HTTP.Request("GET", "/test")
        req_vouched_nobody.context[:user] = false
        req_vouched_nobody.context[:session] = Dict{String,Any}("user_id" => 7)
        @test guard(req_vouched_nobody).status == 302

        # The session marker must hold an identity too. A logout that nulls the key instead
        # of deleting it is not a login.
        for bogus in (nothing, false, "")
            req = HTTP.Request("GET", "/test")
            req.context[:session] = Dict{String,Any}("user_id" => bogus, "cart" => [1])
            @test guard(req).status == 302
        end

        # Still identities: a user id of 0, a string id, a non-empty Principal without an
        # `id` (a service token — the documented case), and a claim-less Principal that does
        # carry one (a keyset-verified signer).
        for real in (0, "alice", Principal(Dict{String,Any}("action" => "sync")),
                     Principal(Dict{String,Any}(); id = "service-a", kid = "service-a", source = :kid))
            req = HTTP.Request("GET", "/test")
            req.context[:user] = real
            @test isnothing(guard(req))
        end
        req_zero = HTTP.Request("GET", "/test")
        req_zero.context[:session] = Dict{String,Any}("user_id" => 0)
        @test isnothing(guard(req_zero))
        req_sym = HTTP.Request("GET", "/test")
        req_sym.context[:session] = Dict{Symbol,Any}(:user_id => 5)
        @test isnothing(guard(req_sym))
    end

    @testset "role_required guard" begin
        guard = role_required("admin")

        # No user → blocked
        req_no_session = HTTP.Request("GET", "/test")
        result = guard(req_no_session)
        @test result isa HTTP.Response
        @test result.status == 403

        # Wrong role → blocked
        req_wrong_role = HTTP.Request("GET", "/test")
        req_wrong_role.context[:user] = Dict{String,Any}("role" => "user")
        result2 = guard(req_wrong_role)
        @test result2 isa HTTP.Response
        @test result2.status == 403

        # Correct role → passes
        req_admin = HTTP.Request("GET", "/test")
        req_admin.context[:user] = Dict{String,Any}("role" => "admin")
        result3 = guard(req_admin)
        @test isnothing(result3)
    end

    @testset "permission_required guard" begin
        guard = permission_required("reports:read")

        req_missing = HTTP.Request("GET", "/test")
        req_missing.context[:user] = Dict{String,Any}("permissions" => ["reports:write"])
        result = guard(req_missing)
        @test result isa HTTP.Response
        @test result.status == 403

        req_allowed = HTTP.Request("GET", "/test")
        req_allowed.context[:user] = Dict{String,Any}("permissions" => ["reports:read", "reports:write"])
        @test isnothing(guard(req_allowed))
    end

    @testset "claim_required guard" begin
        @testset ":equals" begin
            guard = claim_required("action", "reports:generate")

            # No user → 403 with the contract body
            req_no_user = HTTP.Request("GET", "/test")
            result = guard(req_no_user)
            @test result isa HTTP.Response
            @test result.status == 403
            @test text(result) == "Forbidden"

            # Wrong claim value → 403
            req_wrong = HTTP.Request("GET", "/test")
            req_wrong.context[:user] = Dict{String,Any}("action" => "reports:read")
            @test guard(req_wrong).status == 403

            # Non-dict user with NO claims source anywhere → 403. A plain user struct is
            # an identity, not a claims collection; it fails closed.
            req_struct = HTTP.Request("GET", "/test")
            req_struct.context[:user] = (action = "reports:generate",)
            @test guard(req_struct).status == 403

            # Matching claim → pass
            req_ok = HTTP.Request("GET", "/test")
            req_ok.context[:user] = Dict{String,Any}("action" => "reports:generate")
            @test isnothing(guard(req_ok))

            # Session fallback (session-based apps store claims in the session dict) — only
            # for a logged-in session, one carrying the login marker (#337)
            req_session = HTTP.Request("GET", "/test")
            req_session.context[:session] = Dict{String,Any}("user_id" => 1, "action" => "reports:generate")
            @test isnothing(guard(req_session))
        end

        @testset ":contains" begin
            guard = claim_required("scopes", "read"; kind=:contains)

            req_ok = HTTP.Request("GET", "/test")
            req_ok.context[:user] = Dict{String,Any}("scopes" => ["read", "write"])
            @test isnothing(guard(req_ok))

            req_missing = HTTP.Request("GET", "/test")
            req_missing.context[:user] = Dict{String,Any}("scopes" => ["write"])
            @test guard(req_missing).status == 403

            # A non-vector claim never satisfies :contains
            req_scalar = HTTP.Request("GET", "/test")
            req_scalar.context[:user] = Dict{String,Any}("scopes" => "read")
            @test guard(req_scalar).status == 403
        end

        @testset "invalid kind" begin
            @test_throws ArgumentError claim_required("role", "admin"; kind=:matches)
        end

        @testset "wrappers delegate to claim_required" begin
            # role_required/permission_required are aliases — same behavior, same body
            req = HTTP.Request("GET", "/test")
            req.context[:user] = Dict{String,Any}("role" => "user")
            denied = role_required("admin")(req)
            @test denied.status == 403
            @test text(denied) == "Forbidden"
        end
    end

    @testset "guards accept Principal" begin
        principal = Principal(Dict{String,Any}("sub" => "u1", "role" => "admin", "permissions" => ["reports:read"]); id="u1")

        req = HTTP.Request("GET", "/test")
        req.context[:user] = principal
        @test isnothing(login_required()(req))
        @test isnothing(role_required("admin")(req))
        @test isnothing(permission_required("reports:read")(req))
        @test isnothing(claim_required("sub", "u1")(req))

        # Defensive: an empty-claims Principal carries no identity → login_required redirects
        req_empty = HTTP.Request("GET", "/test")
        req_empty.context[:user] = Principal(Dict{String,Any}())
        @test login_required()(req_empty).status == 302
    end

    # #24: a `user_validator` parks the app's user object at `:user` and the VERIFIED
    # `Principal` at `:auth_claims`. `kid_required` always read both slots; the claim
    # guards read only `:user`, so a correctly-authenticated struct user got a 403.
    @testset "claim guards resolve :auth_claims when :user is not a claims source" begin
        # The app's own user object — a non-dict identity, as a `user_validator` commonly
        # returns. `Principal` rides along at `:auth_claims`.
        app_user = (id = 7, name = "alice")
        principal = Principal(
            Dict{String,Any}("sub" => "u7", "role" => "admin", "permissions" => ["reports:read"]);
            id="u7",
        )

        # The fix: every claim guard reads through to the verified claims.
        req = HTTP.Request("GET", "/test")
        req.context[:user] = app_user
        req.context[:auth_claims] = principal
        @test isnothing(role_required("admin")(req))
        @test isnothing(permission_required("reports:read")(req))
        @test isnothing(claim_required("sub", "u7")(req))
        # ...and a claim the token does NOT carry is still denied.
        @test role_required("superuser")(req).status == 403

        # No silent escalation: a dict `:user` IS a claims source, so it stays
        # authoritative and an absent claim means denial. The token's claims are verified
        # but STALE — a demoted user's unexpired token must not out-rank the app's fresh
        # lookup, and dropping the key is a legitimate way for the app to say "no".
        req_demoted = HTTP.Request("GET", "/test")
        req_demoted.context[:user] = Dict{String,Any}("sub" => "u7")   # role deliberately absent
        req_demoted.context[:auth_claims] = principal                   # still says role=admin
        @test role_required("admin")(req_demoted).status == 403

        # A non-claims `:user` suppresses the raw-session fallback: a middleware vouched
        # for this request with a struct identity, so an unauthenticated session dict is
        # not promoted into a claims source for it. These sessions carry the login marker
        # (#337) so each denial below is owed to the rule it names, not to the marker gate.
        req_session = HTTP.Request("GET", "/test")
        req_session.context[:user] = app_user
        req_session.context[:session] = Dict{String,Any}("user_id" => 7, "role" => "admin")
        @test role_required("admin")(req_session).status == 403

        # `:user` is the VOUCHING slot, and only it gates the session fallback. A non-dict
        # `:auth_claims` is not a claims source and vouches for nothing, so with no `:user`
        # the session is still consulted... (it carries the login marker: since #337 a
        # session without one is no claims source at all, which is not what this checks)
        req_bad_claims_session = HTTP.Request("GET", "/test")
        req_bad_claims_session.context[:auth_claims] = "not-a-claims-object"
        req_bad_claims_session.context[:session] = Dict{String,Any}("user_id" => 7, "role" => "admin")
        @test isnothing(role_required("admin")(req_bad_claims_session))

        # ...whereas a non-dict `:user` does gate it, whatever `:auth_claims` holds.
        req_bad_claims = HTTP.Request("GET", "/test")
        req_bad_claims.context[:user] = app_user
        req_bad_claims.context[:auth_claims] = "not-a-claims-object"
        req_bad_claims.context[:session] = Dict{String,Any}("user_id" => 7, "role" => "admin")
        @test role_required("admin")(req_bad_claims).status == 403

        # `:auth_claims` alone (no `:user`) resolves — same trust tier as an app-set
        # `:user`, and strictly more trustworthy than the session fallback below it.
        req_claims_only = HTTP.Request("GET", "/test")
        req_claims_only.context[:auth_claims] = Dict{String,Any}("role" => "admin")
        @test isnothing(role_required("admin")(req_claims_only))

        # Fail-closed behavior change (#24): `:auth_claims` now outranks the session, so a
        # non-matching claims object denies instead of falling through to a matching
        # session. Reachable only if app code sets `:auth_claims` without a `:user`.
        req_claims_over_session = HTTP.Request("GET", "/test")
        req_claims_over_session.context[:auth_claims] = Dict{String,Any}("role" => "viewer")
        req_claims_over_session.context[:session] = Dict{String,Any}("user_id" => 7, "role" => "admin")
        @test role_required("admin")(req_claims_over_session).status == 403

        # Unchanged: `login_required` does not route through the claims resolver, so a
        # struct identity still authenticates regardless of `:auth_claims`.
        @test isnothing(login_required()(req))
        @test isnothing(login_required()(req_session))
    end

    # #337: the raw session is a claims source only while it carries the login marker —
    # the same `_is_identity` test `login_required` applies. Before, any session dict was,
    # so a logout that dropped `user_id` but kept `role` stayed authorized as that role.
    @testset "claim guards gate the session fallback on the login marker (#337)" begin
        session_req(data) = (r = HTTP.Request("GET", "/test"); r.context[:session] = data; r)

        # Never logged in: claim-like keys alone authorize nothing.
        @test role_required("admin")(session_req(Dict{String,Any}("role" => "admin"))).status == 403

        # The issue's scenario: a logout that deleted or nulled the marker, keeping `role`.
        for bogus in (nothing, false, "")
            req = session_req(Dict{String,Any}("user_id" => bogus, "role" => "admin",
                                               "permissions" => ["reports:read"]))
            @test role_required("admin")(req).status == 403
            @test permission_required("reports:read")(req).status == 403
            @test claim_required("role", "admin")(req).status == 403
        end

        # Logged in: the session still serves session-based apps, whatever the id's shape.
        for uid in (7, 0, "alice")
            req = session_req(Dict{String,Any}("user_id" => uid, "role" => "admin",
                                               "permissions" => ["reports:read"]))
            @test isnothing(role_required("admin")(req))
            @test isnothing(permission_required("reports:read")(req))
            @test isnothing(claim_required("role", "admin")(req))
            # ...and the marker gates the source, it does not grant the claim.
            @test role_required("superuser")(req).status == 403
        end
        # The marker lookup falls back to a Symbol key, as `login_required`'s does; the claim
        # itself is still read by its String name.
        @test isnothing(role_required("admin")(session_req(Dict{Any,Any}(:user_id => 5, "role" => "admin"))))
        @test role_required("admin")(session_req(Dict{Any,Any}(:user_id => nothing, "role" => "admin"))).status == 403

        # A custom `session_key` is honored on every claim guard, and the default key is then
        # not a login for it.
        uid_session = Dict{String,Any}("uid" => 9, "role" => "admin", "permissions" => ["reports:read"])
        @test isnothing(role_required("admin"; session_key = "uid")(session_req(uid_session)))
        @test isnothing(permission_required("reports:read"; session_key = "uid")(session_req(uid_session)))
        @test isnothing(claim_required("role", "admin"; session_key = "uid")(session_req(uid_session)))
        @test role_required("admin")(session_req(uid_session)).status == 403
        user_id_session = Dict{String,Any}("user_id" => 9, "role" => "admin")
        @test role_required("admin"; session_key = "uid")(session_req(user_id_session)).status == 403

        # Unchanged: an auth layer's `:user` is not subject to the session marker.
        req_ctx = HTTP.Request("GET", "/test")
        req_ctx.context[:user] = Dict{String,Any}("role" => "admin")
        @test isnothing(role_required("admin")(req_ctx))
    end

    @testset "kid_required guard" begin
        allowed = kid_required(["service-a", "service-b"])

        # Principal with a verified kid in the allowlist → pass
        req_ok = HTTP.Request("GET", "/test")
        req_ok.context[:user] = Principal(Dict{String,Any}("action" => "sync"); id="service-a", kid="service-a", source=:kid)
        @test isnothing(allowed(req_ok))

        # Verified kid not in the allowlist → 403
        req_denied = HTTP.Request("GET", "/test")
        req_denied.context[:user] = Principal(Dict{String,Any}(); kid="service-c")
        denied = allowed(req_denied)
        @test denied.status == 403
        @test text(denied) == "Forbidden"

        # No kid anywhere (single-secret tokens, plain dict users, sessions) → 403
        req_no_kid = HTTP.Request("GET", "/test")
        req_no_kid.context[:user] = Principal(Dict{String,Any}("sub" => "u1"); id="u1")
        @test allowed(req_no_kid).status == 403
        req_dict_user = HTTP.Request("GET", "/test")
        req_dict_user.context[:user] = Dict{String,Any}("kid" => "service-a")  # a CLAIM named kid is not a verified kid
        @test allowed(req_dict_user).status == 403
        req_session_only = HTTP.Request("GET", "/test")
        req_session_only.context[:session] = Dict{String,Any}("user_id" => 1)
        @test allowed(req_session_only).status == 403

        # user_validator flow: app user in :user, Principal in :auth_claims → kid found there
        req_tuple = HTTP.Request("GET", "/test")
        req_tuple.context[:user] = Dict{String,Any}("uid" => 7)
        req_tuple.context[:auth_claims] = Principal(Dict{String,Any}(); kid="service-b")
        @test isnothing(allowed(req_tuple))

        # #517: the TOKEN's Principal at :auth_claims decides, never an app-built one at :user.
        # Single-secret token (no verified kid) under an app Principal that writes one -> 403.
        req_app_kid = HTTP.Request("GET", "/test")
        req_app_kid.context[:user] = Principal(Dict{String,Any}(); id="u1", kid="service-a")
        req_app_kid.context[:auth_claims] = Principal(Dict{String,Any}(); id="u1")
        @test allowed(req_app_kid).status == 403
        # A relabelled kid: the token was verified against a key outside the allowlist -> 403.
        req_relabel = HTTP.Request("GET", "/test")
        req_relabel.context[:user] = Principal(Dict{String,Any}(); id="u1", kid="service-a")
        req_relabel.context[:auth_claims] = Principal(Dict{String,Any}(); id="u1", kid="service-c")
        @test allowed(req_relabel).status == 403
        # ...and the reverse: the token's verified kid admits whatever the app object says.
        req_token_ok = HTTP.Request("GET", "/test")
        req_token_ok.context[:user] = Principal(Dict{String,Any}(); id="u1", kid="service-c")
        req_token_ok.context[:auth_claims] = Principal(Dict{String,Any}(); id="u1", kid="service-b")
        @test isnothing(allowed(req_token_ok))
        # A custom validator returning a bare Principal (no tuple, nothing at :auth_claims) still
        # opts in through :user -- that one IS the token's Principal.
        @test isnothing(allowed(req_ok))

        # Single-string allowlist form
        single = kid_required("service-a")
        @test isnothing(single(req_ok))
        @test single(req_tuple).status == 403

        # Empty allowlist is a construction error
        @test_throws ArgumentError kid_required(String[])

        # Repeated denials serve the shared const response with an intact body each time
        for _ in 1:3
            repeat_denied = allowed(HTTP.Request("GET", "/test"))
            @test repeat_denied.status == 403
            @test text(repeat_denied) == "Forbidden"
        end
    end

end

end

# ── #515 ────────────────────────────────────────────────────────────────────────────────────
# Every shipped guard takes `denied = (req, reason) -> HTTP.Response`. The factory shapes the
# refusal; it cannot turn one into an admission, which matters MORE here than in the auth
# middleware: `GuardMiddleware` admits any guard result that is not a response.
@testitem "Guards — configurable denial responses (#515)" tags=[:middleware, :auth, :security] setup=[NitroCommon] begin
using HTTP
using Nitro

function recorder()
    seen = Symbol[]
    f = (req, reason) -> (push!(seen, reason); Res.json(Dict("error" => "Unauthorized"); status = 401))
    return f, seen
end
with_user(user) = (req = HTTP.Request("GET", "/"); req.context[:user] = user; req)
reader = Dict{String,Any}("role" => "reader", "permissions" => ["read"])
signer(kid) = Principal(Dict{String,Any}(); id = kid, kid = kid, source = :kid)

@testset "the claim and kid guards report :forbidden, and only on a denial" begin
    for (label, make, denied_req, admitted_req) in (
            ("claim :equals",   d -> claim_required("role", "admin"; denied = d),              with_user(reader), with_user(Dict{String,Any}("role" => "admin"))),
            ("claim :contains", d -> claim_required("permissions", "write"; kind = :contains, denied = d), with_user(reader), with_user(Dict{String,Any}("permissions" => ["write"]))),
            ("role_required",   d -> role_required("admin"; denied = d),                       with_user(reader), with_user(Dict{String,Any}("role" => "admin"))),
            ("permission_required", d -> permission_required("write"; denied = d),             with_user(reader), with_user(Dict{String,Any}("permissions" => ["write"]))),
            ("kid_required",    d -> kid_required(["importer"]; denied = d),                    with_user(signer("other")), with_user(signer("importer"))))
        f, seen = recorder()
        guard = make(f)
        res = guard(denied_req)
        @test (label, res.status, text(res), seen) == (label, 401, "{\"error\":\"Unauthorized\"}", [:forbidden])
        @test (label, guard(admitted_req)) == (label, nothing)
        @test (label, length(seen)) == (label, 1)
    end
end

@testset "login_required: `denied` replaces the redirect" begin
    f, seen = recorder()
    guard = login_required(denied = f)
    res = guard(HTTP.Request("GET", "/"))
    @test res.status == 401
    @test seen == [:login_required]
    @test guard(with_user("alice")) === nothing
    # Both at once is a contradiction, not a precedence rule to remember.
    @test_throws ArgumentError login_required(redirect_url = "/signin", denied = f)
    # The redirect keeps working, with its default and with an explicit URL.
    @test HTTP.header(login_required()(HTTP.Request("GET", "/")), "Location") == "/login"
    @test HTTP.header(login_required(redirect_url = "/signin")(HTTP.Request("GET", "/")), "Location") == "/signin"
end

@testset "without `denied`, the defaults are unchanged" begin
    FORBIDDEN = Nitro.Core.Middleware.GuardsMiddleware.FORBIDDEN
    @test role_required("admin")(with_user(reader)) === FORBIDDEN
    @test kid_required("importer")(with_user(signer("other"))) === FORBIDDEN
    @test login_required()(HTTP.Request("GET", "/")).status == 302
end

# The bypass this rule exists for: a factory that "returns the error" as data, or nothing.
@testset "a factory that returns no response fails closed -- the handler never runs" begin
    for bad in ((r, _) -> nothing, (r, _) -> Dict("error" => "Unauthorized"), (r, _) -> 403)
        for guard in (kid_required(["importer"]; denied = bad), role_required("admin"; denied = bad),
                      permission_required("write"; denied = bad), login_required(denied = bad))
            ran = Ref(false)
            handler = GuardMiddleware(guard)(_ -> (ran[] = true; HTTP.Response(200)))
            # Anonymous: every one of these guards denies it.
            @test_throws ArgumentError handler(HTTP.Request("GET", "/"))
            @test !ran[]
        end
    end
end

@testset "the factory must take (req, reason) -- checked when the guard is built" begin
    one_arg = req -> HTTP.Response(401)
    @test_throws ArgumentError kid_required(["k"]; denied = one_arg)
    @test_throws ArgumentError claim_required("role", "admin"; denied = one_arg)
    @test_throws ArgumentError role_required("admin"; denied = one_arg)
    @test_throws ArgumentError permission_required("write"; denied = one_arg)
    @test_throws ArgumentError login_required(denied = one_arg)
end

end

@testitem "GuardMiddleware fails closed on a non-response guard result (#519)" tags=[:middleware, :auth, :security] setup=[NitroCommon] begin
using HTTP
using Nitro

# A guard runs, and a handler that records whether it was reached.
function guarded(guards...)
    ran = Ref(false)
    return GuardMiddleware(guards...)(_ -> (ran[] = true; HTTP.Response(200, "handler"))), ran
end

# Every one of these LOOKS like a denial, and every one of them used to admit the request.
@testset "a guard that 'denies' with $(typeof(bad)) is an error -- the handler never runs" for bad in (
        false, true, Dict("error" => "forbidden"), "forbidden", 403, :forbidden, missing)
    handler, ran = guarded(_ -> bad)
    @test_throws ArgumentError handler(HTTP.Request("GET", "/"))
    @test !ran[]
end

@testset "the contract that stays: `nothing` admits, a response denies as-is" begin
    handler, ran = guarded(_ -> nothing)
    @test text(handler(HTTP.Request("GET", "/"))) == "handler"
    @test ran[]

    DENIED = HTTP.Response(403, "no")
    handler, ran = guarded(_ -> nothing, _ -> DENIED)
    @test handler(HTTP.Request("GET", "/")) === DENIED
    @test !ran[]
end

@testset "a denial before a malformed guard short-circuits it; a malformed guard stops the rest" begin
    reached = Ref(false)
    later = _ -> (reached[] = true; nothing)

    handler, ran = guarded(_ -> HTTP.Response(403), _ -> false)
    @test handler(HTTP.Request("GET", "/")).status == 403
    @test !ran[]

    handler, ran = guarded(_ -> false, later)
    @test_throws ArgumentError handler(HTTP.Request("GET", "/"))
    @test !reached[] && !ran[]
end

@testset "the error names the guard and the type, never the value" begin
    secret = "sk_live_DO_NOT_LOG"
    function only_admins(req::HTTP.Request)
        return Dict("error" => "forbidden", "token" => secret)
    end
    handler, _ = guarded(_ -> nothing, only_admins)
    err = try
        handler(HTTP.Request("GET", "/"))
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("guard #2", err.msg)
    @test occursin("only_admins", err.msg)
    @test occursin("returned a Dict;", err.msg)
    @test !occursin(secret, err.msg)

    # A value can ride in a type parameter; only the type's NAME is reported.
    handler, _ = guarded(_ -> Val(Symbol(secret)))
    err = try
        handler(HTTP.Request("GET", "/"))
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("returned a Val;", err.msg)
    @test !occursin(secret, err.msg)
end

# The request path: the throw reaches the server's error boundary, which answers 500.
@testset "through a routed app the client gets a 500, and the handler does not run" begin
    ran = Ref(false)
    app = App()
    urlpatterns(app, "",
        path("/admin", _ -> (ran[] = true; Res.send("admin"));
             middleware = [GuardMiddleware(req -> HTTP.header(req, "X-Role", "") == "admin")]))
    logger = Test.TestLogger(min_level = Base.CoreLogging.Error)
    r = Base.CoreLogging.with_logger(logger) do
        internalrequest(app, HTTP.Request("GET", "/admin"))
    end
    @test r.status == 500
    @test !ran[]
    # A guard returning `true` is no admission either: the check is on the type, not the truth.
    r = Base.CoreLogging.with_logger(logger) do
        internalrequest(app, HTTP.Request("GET", "/admin", ["X-Role" => "admin"]))
    end
    @test r.status == 500
    @test !ran[]
end

end

@testitem "kid_required reads the token's kid, not an app-built one (#517)" tags=[:middleware, :auth, :security] setup=[NitroCommon] begin
using HTTP
using Nitro

# The issue's repro, end to end: a `user_validator` that "enriches" the token's Principal by
# copying it into a new `Principal(...; kid = ...)`. Before #517 the guard read that kid first.
enrich(kid) = p -> Principal(Dict{String,Any}(p); id = p.id, kid = kid)

function serve_kid(validator, allowed)
    seen = Ref{Any}(nothing)
    handler = BearerAuth(validator)(GuardMiddleware(kid_required(allowed))(
        req -> (seen[] = getprincipal(req); HTTP.Response(200, "in"))))
    return handler, seen
end
bearer(token) = HTTP.Request("GET", "/import", ["Authorization" => "Bearer $token"])

@testset "single secret: an app-written kid authorizes nothing" begin
    secret = jwtkey("single-secret")
    token = Nitro.Auth.encode_jwt(Dict("sub" => "7"), secret; expires_in = 3600)
    handler, seen = serve_kid(Nitro.Auth.jwt_validator(secret; user_validator = enrich("importer")), "importer")
    @test handler(bearer(token)).status == 403
    @test seen[] === nothing
end

@testset "keyset: a relabelled kid is refused, the verified one is honoured" begin
    keyset = Nitro.Auth.JWTKeyset("importer" => jwtkey("secret-importer"); verify = ["other" => jwtkey("secret-other")])
    by_other = Nitro.Auth.encode_jwt(Dict("sub" => "7"), Nitro.Auth.JWTKeyset("other" => jwtkey("secret-other")); expires_in = 3600)
    by_importer = Nitro.Auth.encode_jwt(Dict("sub" => "7"), Nitro.Auth.JWTKeyset("importer" => jwtkey("secret-importer")); expires_in = 3600)

    # Signed by "other", relabelled "importer" by the app: refused.
    handler, seen = serve_kid(Nitro.Auth.jwt_validator(keyset; user_validator = enrich("importer")), "importer")
    @test handler(bearer(by_other)).status == 403
    @test seen[] === nothing

    # Signed by "importer", relabelled "other" by the app: admitted on the token's kid, and the
    # handler sees the same kid the guard authorized.
    handler, seen = serve_kid(Nitro.Auth.jwt_validator(keyset; user_validator = enrich("other")), "importer")
    @test handler(bearer(by_importer)).status == 200
    @test seen[].kid == "importer"
end

end

@testitem "getprincipal (#515)" tags=[:middleware, :auth] setup=[NitroCommon] begin
using HTTP
using Nitro

req(; user = nothing, claims = nothing, session = nothing) = begin
    r = HTTP.Request("GET", "/")
    user === nothing || (r.context[:user] = user)
    claims === nothing || (r.context[:auth_claims] = claims)
    session === nothing || (r.context[:session] = session)
    r
end
token = Principal(Dict{String,Any}("sub" => "u1"); id = "u1", kid = "importer", source = :claim)

# `jwt_validator` without a user_validator: the Principal is the user.
@test getprincipal(req(user = token)) === token
# With one: the app's object is the user, the token's Principal rides at :auth_claims.
@test getprincipal(req(user = Dict{String,Any}("uid" => 7), claims = token)) === token
# An app user_validator that returns its OWN Principal (never verified) does not shadow the
# token's -- the verified kid is what a handler behind `kid_required` must read.
enriched = Principal(Dict{String,Any}("sub" => "u1", "plan" => "pro"); id = "u1")
@test getprincipal(req(user = enriched, claims = token)).kid == "importer"
# ...not even one that writes a kid of its own: an app-built kid is a label, not a verification.
relabelled = Principal(Dict{String,Any}("sub" => "u1"); id = "u1", kid = "admin-key")
@test getprincipal(req(user = relabelled, claims = token)).kid == "importer"
single_secret = Principal(Dict{String,Any}("sub" => "u1"); id = "u1")   # no verified kid
@test getprincipal(req(user = relabelled, claims = single_secret)).kid === nothing
# No token principal: nothing.
@test getprincipal(req()) === nothing
@test getprincipal(req(user = "alice")) === nothing
@test getprincipal(req(user = Dict{String,Any}("kid" => "importer"))) === nothing
@test getprincipal(req(session = Dict{String,Any}("user_id" => 1))) === nothing
@test getprincipal(req(user = "alice", claims = Dict{String,Any}("sub" => "x"))) === nothing
# Exported from both places a handler looks.
@test Nitro.Auth.getprincipal === getprincipal
end
