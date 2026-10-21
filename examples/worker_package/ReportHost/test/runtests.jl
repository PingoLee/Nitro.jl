using Test, HTTP, Nitro, ReportKit, ReportHost
using Nitro.Workers: InMemoryWorkerStore, uninstall!

@testset "ReportHost" begin
    # A fresh App, so the test never touches `ReportHost.app`, the one `main()` serves.
    app = App(mod = ReportHost)
    ReportKit.register_jobs!(app)
    worker_startup(app; queues = [ReportHost.QUEUE], store = InMemoryWorkerStore())
    tokens = [SecretString("alice-token") => "alice", SecretString("bob-token") => "bob"]
    urlpatterns(app, "", ReportHost.urls(app, tokens))

    submit(headers) = internalrequest(app, HTTP.Request("POST", "/api/reports",
        ["Content-Type" => "application/json", headers...], """{"title": "totals", "rows": 10}"""))
    status(id, headers) = internalrequest(app, HTTP.Request("GET", "/api/reports/$id", headers))
    alice = ["Authorization" => "Bearer alice-token"]
    bob = ["Authorization" => "Bearer bob-token"]

    try
        @test internalrequest(app, HTTP.Request("GET", "/health")).status == 200
        @test submit([]).status == 401                                          # no token
        @test submit(["Authorization" => "Bearer wrong"]).status == 401

        res = submit(alice)
        @test res.status == 202
        id = Nitro.json(res)["id"]
        @test Nitro.json(res)["status_url"] == "/api/reports/$id"   # under the host's prefix

        deadline = time() + 30
        report = Nitro.json(status(id, alice))
        while report["status"] in ("PENDING", "RUNNING") && time() < deadline
            sleep(0.05)
            report = Nitro.json(status(id, alice))
        end
        @test report["status"] == "COMPLETED"
        @test report["result"]["total"] == 55
        @test status(id, bob).status == 404                                     # alice's, not bob's

        @test_throws ArgumentError ReportHost.token_auth([SecretString("") => "nobody"])
    finally
        uninstall!(app)
    end
end
