using Test, HTTP, Nitro, AuthKit, AuthHost

@testset "AuthHost" begin
    # A cheap hash keeps the suite fast; `demo_users` takes `make_password`'s default cost.
    cheap_hash(password) = Auth.make_password(password; iterations = 1_000)
    users = AuthHost.Users([Account("1", "alice", cheap_hash("wonderland"), "admin"),
                            Account("2", "bob", cheap_hash("builder"), "member")])
    config = AuthConfig(secret = "s"^32,
                        find_by_username = name -> get(users.by_username, name, nothing),
                        find_by_id = id -> get(users.by_id, id, nothing))

    # A fresh App, so the test never touches `AuthHost.app`, the one `main()` serves.
    app = App(mod = AuthHost)
    urlpatterns(app, "", AuthHost.urls(config))

    token_for(username, password) = Nitro.json(internalrequest(app, HTTP.Request("POST", "/auth/login",
        ["Content-Type" => "application/json"], """{"username": "$username", "password": "$password"}""")))["token"]
    report(headers = []) = internalrequest(app, HTTP.Request("GET", "/admin/report", headers))

    @test internalrequest(app, HTTP.Request("GET", "/health")).status == 200

    alice = token_for("alice", "wonderland")
    bob = token_for("bob", "builder")

    @test report().status == 401                                     # TokenAuth: no token
    @test report(["Authorization" => "Bearer $bob"]).status == 403   # the guard: wrong role
    res = report(["Authorization" => "Bearer $alice"])
    @test res.status == 200
    @test Nitro.json(res) == Dict("report" => "monthly totals", "requested_by" => "alice",
                                  "token_subject" => "1")

    # The role is read from the user table on every request, not from the token: demoting alice
    # takes effect on her next request, with the token she already holds.
    demoted = Account("1", "alice", users.by_id["1"].password_hash, "member")
    users.by_id["1"] = demoted
    users.by_username["alice"] = demoted
    @test report(["Authorization" => "Bearer $alice"]).status == 403

    # The package's route names, under the prefix the host chose.
    @test url(app, "auth.login") == "/auth/login"
    @test url(app, "admin.report") == "/admin/report"
end
