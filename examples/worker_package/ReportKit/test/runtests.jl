using Test, HTTP, Nitro, ReportKit
using Nitro.Workers: InMemoryWorkerStore, uninstall!

# Poll a report until it leaves PENDING/RUNNING, or give up after `timeout` seconds.
function await_report(get_status, id; timeout = 30)
    deadline = time() + timeout
    while true
        body = Nitro.json(get_status(id))
        body["status"] in ("PENDING", "RUNNING") || return body
        time() > deadline && error("report $id still $(body["status"]) after $(timeout) s")
        sleep(0.05)
    end
end

@testset "ReportKit" begin
    app = App(mod = ReportKit)
    register_jobs!(app)
    worker_startup(app; queues = ["reports"], store = InMemoryWorkerStore())
    # Tests stand in for the host's auth middleware with a header; a host must never trust one.
    user_of(req) = (user = HTTP.header(req, "X-Test-User", ""); isempty(user) ? nothing : user)
    urlpatterns(app, "", routes(app; queue = "reports", user_of))

    submit(user, body) = internalrequest(app, HTTP.Request("POST", "/reports",
        ["Content-Type" => "application/json", "X-Test-User" => user], body))
    status(user) = id -> internalrequest(app, HTTP.Request("GET", "/reports/$id", ["X-Test-User" => user]))

    try
        @testset "routes() returns definitions and registers nothing" begin
            defs = routes(app; queue = "reports", user_of, prefix = "/jobs", namespace = "jobs")
            @test defs isa Vector{RouteDefinition}
            @test sort([d.name for d in defs]) == ["jobs.status", "jobs.submit"]
            # Building them registered nothing: only the mount above is on the app.
            @test internalrequest(app, HTTP.Request("POST", "/jobs")).status == 404
            @test url(app, "reports.status"; id = "0123456789abcdef") == "/reports/0123456789abcdef"
        end

        @testset "a job is registered once per app" begin
            @test_throws ArgumentError register_jobs!(app)
            register_jobs!(App(mod = ReportKit))   # another app has its own registry
        end

        @testset "submit, then poll to the result" begin
            res = submit("alice", """{"title": "totals", "rows": 1000}""")
            @test res.status == 202
            body = Nitro.json(res)
            id = body["id"]
            @test occursin(r"^[0-9a-f]{16}$", id)
            @test body["status_url"] == "/reports/$id"

            report = await_report(status("alice"), id)
            @test report["status"] == "COMPLETED"
            @test report["progress"] == 100
            @test report["result"] == Dict("title" => "totals", "rows" => 1000, "total" => 500500)
            @test report["error"] === nothing
        end

        @testset "a report is visible to its owner only" begin
            id = Nitro.json(submit("alice", """{"title": "mine"}"""))["id"]
            @test await_report(status("alice"), id)["status"] == "COMPLETED"
            @test status("bob")(id).status == 404          # the same answer as a missing report
            @test status("alice")("0123456789abcdef").status == 404
            @test status("alice")("not-an-id").status == 404
        end

        @testset "refusals" begin
            @test submit("", """{"title": "t"}""").status == 401
            @test internalrequest(app, HTTP.Request("GET", "/reports/0123456789abcdef")).status == 401
            @test submit("alice", """{"rows": 5}""").status == 400              # no title
            @test submit("alice", """{"title": "t", "rows": 0}""").status == 400
        end

        @testset "a failed report does not echo its exception" begin
            failing = App(mod = ReportKit)
            Nitro.Workers.register_job!(failing, "reportkit.build", ReportRequest) do task_info, report
                error("secret detail")
            end
            worker_startup(failing; queues = ["reports"], store = InMemoryWorkerStore())
            urlpatterns(failing, "", routes(failing; queue = "reports", user_of))
            try
                res = internalrequest(failing, HTTP.Request("POST", "/reports",
                    ["Content-Type" => "application/json", "X-Test-User" => "alice"], """{"title": "t"}"""))
                id = Nitro.json(res)["id"]
                report = await_report(id -> internalrequest(failing,
                    HTTP.Request("GET", "/reports/$id", ["X-Test-User" => "alice"])), id)
                @test report["status"] == "FAILED"
                @test report["error"] == "the report could not be built"
            finally
                uninstall!(failing)
            end
        end

        @testset "a user_of that returns no string is a loud wiring error" begin
            # A host passing `getuser` where its auth middleware stores a dict there.
            dict_user = req -> Dict("id" => "alice")
            @test_throws "`user_of` must return a user id String" ReportKit.request_owner(
                dict_user, HTTP.Request("GET", "/"))
            other = App(mod = ReportKit)
            urlpatterns(other, "", routes(other; queue = "reports", user_of = dict_user))
            @test internalrequest(other, HTTP.Request("POST", "/reports",
                ["Content-Type" => "application/json"], """{"title": "t"}""")).status == 500
        end
    finally
        uninstall!(app)
    end
end
