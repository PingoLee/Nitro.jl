@testitem "Workers" tags=[:core] setup=[NitroCommon] begin

using Test
using Dates
using Nitro
using Nitro.Workers
using Nitro.Errors: AuthorizationError

function wait_for(predicate::Function; timeout::Real=5.0)
    return timedwait(predicate, timeout)
end

@testset "Immediate task execution and deduplication" begin
    store = InMemoryWorkerStore()
    calls = Ref(0)
    gate = Base.Event()

    try
        task_id = submit_task("immediate-task", () -> begin
            calls[] += 1
            wait(gate)
            return "done"
        end, Owner("user-a"); store=store)

        # Same user, same key, still running: deduplicates onto the live task.
        duplicate_id = submit_task("immediate-task", () -> begin
            calls[] += 100
            return "duplicate"
        end, Owner("user-a"); store=store)

        @test task_id == "user-a::immediate-task"
        @test duplicate_id == task_id

        notify(gate)
        @test wait_for(() -> get_task_status(task_id, Owner("user-a"); store=store)[:status] == "COMPLETED") == :ok

        status = get_task_status(task_id, Owner("user-a"); store=store)
        @test status[:result] == "done"
        @test status[:watcher_count] == 1
        @test calls[] == 1
    finally
        notify(gate)
        reset_store!(store)
    end
end

@testset "Sequential queues preserve order" begin
    store = InMemoryWorkerStore()
    observed = String[]

    try
        ids = String[]
        for index in 1:3
            push!(ids, submit_sequential_task("reports", "queued-$(index)", task_info -> begin
                push!(observed, task_info.id)
                sleep(0.05)
                return task_info.id
            end, Owner("user"); store=store))
        end

        @test ids == ["user::queued-1", "user::queued-2", "user::queued-3"]
        @test wait_for(() -> all(get_task_status(id, Owner("user"); store=store)[:status] == "COMPLETED" for id in ids)) == :ok
        @test observed == ids

        queue_status = get_queue_status("reports", System(); store=store)
        @test queue_status[:running] == true
        @test queue_status[:current_task] === nothing
        @test queue_status[:total_load] == 0
    finally
        reset_store!(store)
    end
end

@testset "Retry, cancellation, and cleanup" begin
    store = InMemoryWorkerStore()
    attempts = Ref(0)
    started = Base.Event()

    try
        retry_id = submit_task("retry-task", () -> begin
            attempts[] += 1
            if attempts[] < 3
                error("retry me")
            end
            return "ok"
        end, Owner("user"); options=TaskOptions(retry_on_failure=true, max_retries=2), store=store)

        @test wait_for(() -> get_task_status(retry_id, Owner("user"); store=store)[:status] == "COMPLETED"; timeout=10.0) == :ok
        @test attempts[] == 3

        cancel_id = submit_task("cancel-task", task_info -> begin
            notify(started)
            while true
                sleep(0.01)
            end
            return task_info.id
        end, Owner("user"); store=store)

        wait(started)
        cancel_result = cancel_task(cancel_id, Owner("user"); store=store)
        @test cancel_result[:status] == "Task cancelled"
        @test wait_for(() -> get_task_status(cancel_id, Owner("user"); store=store)[:status] == "CANCELLED") == :ok

        lock(store.task_lock) do
            expired = TaskInfo("expired-task")
            expired.status = COMPLETED
            expired.completed_at = Dates.now(Dates.UTC) - Dates.Day(10)
            store.task_registry[expired.id] = expired
        end

        @test cleanup_old_tasks(7; store=store) == 1
        @test get_task_status("expired-task", System(); store=store)[:status] == "NOT_FOUND"
    finally
        reset_store!(store)
    end
end

@testset "Cleanup scheduler and per-context stores" begin
    store = InMemoryWorkerStore()
    ctx_one = Nitro.Core.ServerContext()
    ctx_two = Nitro.Core.ServerContext()

    try
        install!(ctx_one; store=store)
        other_store = install!(ctx_two)

        @test worker_store(ctx_one) === store
        @test worker_store(ctx_two) === other_store

        lock(store.task_lock) do
            expired = TaskInfo("scheduled-expired")
            expired.status = COMPLETED
            expired.completed_at = Dates.now(Dates.UTC) - Dates.Day(10)
            store.task_registry[expired.id] = expired
        end

        scheduler = start_cleanup_scheduler(; interval_hours=0.00005, retain_days=7, store=store)
        @test wait_for(() -> get_task_status("scheduled-expired", System(); store=store)[:status] == "NOT_FOUND") == :ok
        stop_cleanup_scheduler!(scheduler)

        ctx_task_id = submit_task(ctx_one, "ctx-task", () -> "ctx-one", Owner("user"))
        @test ctx_task_id == "user::ctx-task"
        @test wait_for(() -> get_task_status(ctx_one, ctx_task_id, Owner("user"))[:status] == "COMPLETED") == :ok
        @test get_task_status(ctx_one, ctx_task_id, Owner("user"))[:result] == "ctx-one"
        @test get_task_status(ctx_two, ctx_task_id, Owner("user"))[:status] == "NOT_FOUND"
    finally
        uninstall!(ctx_one)
        uninstall!(ctx_two)
        reset_store!(store)
    end
end

@testset "Public worker startup API bootstraps lifecycle" begin
    ctx = Nitro.Core.ServerContext()

    lifecycle = startup(
        ctx;
        queues=["reports"],
        cleanup_enabled=true,
        cleanup_interval_hours=0.00005,
        cleanup_retain_days=7,
    )

    processed = Nitro.Core.process_middleware(ctx, [lifecycle])
    @test length(processed) == 1
    @test isnothing(worker_store(ctx))

    lifecycle.on_startup()

    store = worker_store(ctx)
    @test store isa InMemoryWorkerStore
    @test get_queue_status(ctx, "reports", System())[:running] == true
    @test store.cleanup_scheduler[] isa CleanupScheduler

    lock(store.task_lock) do
        expired = TaskInfo("lifecycle-expired")
        expired.status = COMPLETED
        expired.completed_at = Dates.now(Dates.UTC) - Dates.Day(10)
        store.task_registry[expired.id] = expired
    end

    @test wait_for(() -> get_task_status(ctx, "lifecycle-expired", System())[:status] == "NOT_FOUND") == :ok

    lifecycle.on_shutdown()
    @test isnothing(worker_store(ctx))
end

@testset "User access control and queue authorization" begin
    store = InMemoryWorkerStore()
    
    # Configure a mock queue authorizer
    set_queue_authorizer!(store, (queue_name, user_id) -> begin
        if queue_name == "admin-queue"
            return user_id == "admin-user"
        end
        return true
    end)

    try
        # 1. Queue Authorization test
        # Authorized user succeeds
        task1 = submit_sequential_task("admin-queue", "task-auth-ok", () -> "ok", Owner("admin-user"); store=store)
        @test task1 == "admin-user::task-auth-ok"

        # Unauthorized user throws AuthorizationError
        @test_throws AuthorizationError submit_sequential_task("admin-queue", "task-auth-fail", () -> "fail", Owner("other-user"); store=store)

        # 2. Task querying and watchers access control
        # submit a task by user-a (so user-a is the first watcher)
        task_id = submit_task("task-access", () -> "data", Owner("user-a"); store=store)
        @test task_id == "user-a::task-access"

        # user-a can check status
        status_a = get_task_status(task_id, Owner("user-a"); store=store)
        @test status_a[:id] == task_id

        # user-b cannot check status (throws AuthorizationError)
        @test_throws AuthorizationError get_task_status(task_id, Owner("user-b"); store=store)

        # The bypass still exists, but it is now a value you have to name.
        @test get_task_status(task_id, System(); store=store)[:id] == task_id

        # ...and there is no arity that reaches it by omission. This is #48: the
        # unsafe call used to be the SHORTER one, so a call site that had merely
        # forgotten to scope was indistinguishable from one that meant not to.
        @test_throws MethodError get_task_status(task_id; store=store)
        @test_throws MethodError cancel_task(task_id; store=store)
        @test_throws MethodError get_all_tasks(; store=store)
        @test_throws MethodError get_all_tasks(RUNNING; store=store)
        # A bare user id is not an authority either — `""` used to be a second,
        # quieter bypass, reachable by reading a missing claim into an empty string.
        @test_throws MethodError get_task_status(task_id, "user-a"; store=store)

        # 3. Listing tasks (get_all_tasks)
        # add another task by user-b
        task_b_id = submit_task("task-user-b", () -> "data", Owner("user-b"); store=store)

        # get_all_tasks for user-a only returns task-access
        tasks_a = get_all_tasks(Owner("user-a"); store=store)
        @test length(tasks_a) == 1
        @test tasks_a[1][:id] == task_id

        # get_all_tasks for user-b only returns task-user-b
        tasks_b = get_all_tasks(Owner("user-b"); store=store)
        @test length(tasks_b) == 1
        @test tasks_b[1][:id] == task_b_id

        # get_all_tasks without user returns both
        all_tasks = get_all_tasks(System(); store=store)
        @test length(all_tasks) == 3 # task-auth-ok + task-access + task-user-b

        # 4. Cancellation access control
        # user-b cannot cancel user-a's task
        @test_throws AuthorizationError cancel_task(task_id, Owner("user-b"); store=store)

        # user-a can cancel their own task
        cancel_res = cancel_task(task_id, Owner("user-a"); store=store)
        @test cancel_res[:status] == "Task cancelled"
    finally
        reset_store!(store)
    end
end

@testset "store write primitives are atomic and intent-scoped (#88)" begin
    store = InMemoryWorkerStore()
    try
        info = TaskInfo("alice::job")
        push!(info.watchers, "alice")
        replace_task!(store, info.id, info)

        @testset "add_watcher! is idempotent and reports absence" begin
            @test add_watcher!(store, "alice::job", "bob") == true
            @test add_watcher!(store, "alice::job", "bob") == true       # idempotent
            @test get_task_info(store, "alice::job").watchers == ["alice", "bob"]
            @test add_watcher!(store, "no-such-task", "bob") == false    # absent, not an error
        end

        @testset "set_task! carries state, never grants" begin
            # The #88 regression, expressed against the store contract: an ordinary
            # state transition must not carry a stale watcher list along with it.
            # A caller holding a TaskInfo read *before* a grant was added...
            stale = TaskInfo("alice::job")           # a view that predates the grant
            push!(stale.watchers, "alice")
            stale.status = COMPLETED

            set_task!(store, "alice::job", stale)    # ...saves progress/status only

            @test "bob" in get_task_info(store, "alice::job").watchers

            # replace_task! is the one call that *may* reset them, and is what the
            # documented "re-running a finished key resets watchers" path uses.
            fresh = TaskInfo("alice::job")
            push!(fresh.watchers, "carol")
            replace_task!(store, "alice::job", fresh)
            @test get_task_info(store, "alice::job").watchers == ["carol"]
        end

        @testset "try_transition! only fires from the expected status" begin
            t = TaskInfo("alice::cas")
            replace_task!(store, t.id, t)            # starts PENDING

            @test try_transition!(store, "alice::cas", (PENDING, RUNNING), CANCELLED;
                                  error="Cancelled", completed_at=Dates.now(Dates.UTC)) == true
            after = get_task_info(store, "alice::cas")
            @test after.status == CANCELLED
            @test after.error == "Cancelled"

            # Already left the `from` set: no second transition, and nothing written.
            @test try_transition!(store, "alice::cas", (PENDING, RUNNING), COMPLETED) == false
            @test get_task_info(store, "alice::cas").status == CANCELLED
            @test try_transition!(store, "no-such-task", (PENDING,), CANCELLED) == false
        end

        @testset "concurrent add_watcher! loses no grant" begin
            t = TaskInfo("alice::concurrent")
            push!(t.watchers, "alice")
            replace_task!(store, t.id, t)

            @sync for i in 1:20
                Threads.@spawn add_watcher!(store, "alice::concurrent", "u$(i)")
            end

            got = get_task_info(store, "alice::concurrent").watchers
            @test length(got) == 21
            @test Set(got) == Set(vcat("alice", ["u$(i)" for i in 1:20]))
        end
    finally
        reset_store!(store)
    end
end

@testset "queue introspection is an admin surface (#87)" begin
    store = InMemoryWorkerStore()
    try
        submit_sequential_task("reports", "job", () -> "ok", Owner("user-a"); store=store)

        # `:pending_tasks` and `:current_task` enumerate ids that carry their owner in
        # the "<owner>::<key>" prefix, and queue depth is a fact about the queue rather
        # than about any one user. So there is no scoped form: an Owner does not compile.
        @test get_queue_status("reports", System(); store=store)[:running] == true
        @test_throws MethodError get_queue_status("reports", Owner("user-a"); store=store)
        # ...and, as everywhere else, omitting the authority is not a way in either.
        @test_throws MethodError get_queue_status("reports"; store=store)

        # `is_task_running` took no user id at all — any caller who could name an id
        # learned whether it was live. Retired rather than hardened; it had no tests and
        # no docs, and `get_task_status` answers the same question with authorization.
        @test !isdefined(Nitro.Workers, :is_task_running)
    finally
        reset_store!(store)
    end
end

@testset "Owner validates its identity; System is the named bypass" begin
    # Every shape that would make the owner half of a `:user` id ambiguous, plus the
    # empty id, which used to mean "skip the ownership check".
    @test_throws ArgumentError Owner("")
    @test_throws ArgumentError Owner("::")
    @test_throws ArgumentError Owner("bad::uid")
    @test_throws ArgumentError Owner("alice:")

    # A colon anywhere else in an owner stays legal — "google:12345" is a real shape.
    @test Owner("google:12345").user_id == "google:12345"
    @test Owner("user-a") isa TaskAuthority
    @test System() isa TaskAuthority
end

@testset "owner_of derives ownership from the id" begin
    @test owner_of("user-a::export_42") == "user-a"
    # A :user *key* may contain the delimiter; the first occurrence is the split.
    @test owner_of("user-a::a::b") == "user-a"
    # The rival parse here is owner "alice:", which `Owner` cannot construct.
    @test owner_of("alice:::report") == "alice"
    # :global ids are stored verbatim and have no owner half.
    @test owner_of("export_42") === nothing
    # Not producible by the API, but must fail closed rather than yield "".
    @test owner_of("::x") === nothing
    @test owner_of("") === nothing

    # The round trip, and the equivalence the SQL pre-filter in the PormG store
    # depends on: `owner_of(id) == u` iff `startswith(id, u * "::")`.
    for (key, uid) in [("export_42", "user-a"), ("a::b", "user-a"), (":report", "alice"),
                       ("report", "google:12345")]
        id = scoped_task_key(key, Owner(uid))
        @test owner_of(id) == uid
        @test startswith(id, uid * "::")
    end
end

@testset "ownership comes from the id, watchers only add to it" begin
    store = InMemoryWorkerStore()
    try
        # A :user task: the owner is derivable from the id, so emptying `watchers`
        # cannot revoke it. That is the authorization half of #88 — a lost append,
        # or a full-row write from another process, can no longer evict an owner
        # from their own task.
        uid = submit_task("report", () -> "secret", Owner("alice"); store=store)
        info = get_task_info(store, uid)
        empty!(info.watchers)
        set_task!(store, uid, info)

        @test isempty(get_task_info(store, uid).watchers)
        @test get_task_status(uid, Owner("alice"); store=store)[:id] == uid
        @test get_task_status(uid, Owner("alice"); store=store)[:owner] == "alice"
        @test_throws AuthorizationError get_task_status(uid, Owner("mallory"); store=store)
        # It still lists for its owner, with no watcher entry backing that up.
        @test length(get_all_tasks(Owner("alice"); store=store)) == 1

        # A :global task has no owner half, so `watchers` remains the whole gate and
        # emptying it authorizes nobody — including the submitter. The asymmetry is
        # deliberate: B adds an authority source for :user ids, it removes none.
        gid = submit_task("shared", () -> "x", Owner("gus"); scope=:global, store=store)
        @test owner_of(gid) === nothing
        ginfo = get_task_info(store, gid)
        empty!(ginfo.watchers)
        set_task!(store, gid, ginfo)

        @test_throws AuthorizationError get_task_status(gid, Owner("gus"); store=store)
        @test get_task_status(gid, System(); store=store)[:id] == gid
        @test isempty(get_all_tasks(Owner("gus"); store=store))
    finally
        reset_store!(store)
    end
end

@testset "get_all_tasks returns owned and granted tasks, and nothing else" begin
    store = InMemoryWorkerStore()
    try
        mine = submit_task("mine", () -> "a", Owner("alice"); store=store)
        theirs = submit_task("theirs", () -> "b", Owner("bob"); store=store)
        # A :global task alice is a watcher of but does not own.
        shared = submit_task("shared", () -> "c", Owner("carol"); scope=:global, store=store)
        info = get_task_info(store, shared)
        push!(info.watchers, "alice")
        set_task!(store, shared, info)

        ids = Set(t[:id] for t in get_all_tasks(Owner("alice"); store=store))
        @test ids == Set([mine, shared])       # owned by prefix, granted by watchers
        @test !(theirs in ids)
        @test Set(t[:id] for t in get_all_tasks(Owner("bob"); store=store)) == Set([theirs])
        @test length(get_all_tasks(System(); store=store)) == 3
    finally
        reset_store!(store)
    end
end

@testset "scoped_task_key resolves and validates the stored id" begin
    @test scoped_task_key("export_42", Owner("user-a")) == "user-a::export_42"
    @test scoped_task_key("export_42", Owner("user-a"); scope=:user) == "user-a::export_42"
    @test scoped_task_key("export_42", Owner("user-a"); scope=:global) == "export_42"

    # A :user task key may contain the delimiter; the owner may not, or
    # ("a", "::b") and ("a::", "b") would resolve to the same id. The owner half is
    # now rejected by `Owner` on construction, so it can never reach this function.
    @test scoped_task_key("a::b", Owner("user-a")) == "user-a::a::b"

    # An owner ending in ':' is the one remaining collision: without this rule
    # (":report", "alice") and ("report", "alice:") both give "alice:::report".
    @test scoped_task_key(":report", Owner("alice")) == "alice:::report"
    # A colon elsewhere in the owner is still legal and stays unambiguous.
    @test scoped_task_key("report", Owner("google:12345")) == "google:12345::report"

    # A :global key may not contain it at all, or it could forge a :user id:
    # global "victim::export_42" is exactly what victim's own "export_42" resolves to.
    @test_throws ArgumentError scoped_task_key("victim::export_42", Owner("attacker"); scope=:global)
    @test scoped_task_key("victim::export_42", Owner("attacker")) == "attacker::victim::export_42"

    @test_throws ArgumentError scoped_task_key("export_42", Owner("user-a"); scope=:tenant)

    # The submit paths route through it, including the validation.
    store = InMemoryWorkerStore()
    try
        @test submit_task("k", () -> 1, Owner("u"); scope=:global, store=store) == "k"
        @test_throws ArgumentError submit_task("k3", () -> 1, Owner("u"); scope=:tenant, store=store)
        @test_throws ArgumentError submit_sequential_task("q", "k4", () -> 1, Owner("u"); scope=:tenant, store=store)

        # A global submit cannot squat a user-scoped id.
        @test_throws ArgumentError submit_task("victim::k5", () -> 1, Owner("attacker"); scope=:global, store=store)
        @test_throws ArgumentError submit_sequential_task("q", "victim::k6", () -> 1, Owner("attacker"); scope=:global, store=store)
    finally
        reset_store!(store)
    end
end

@testset "Sequential submits share the cross-user gate (#19)" begin
    store = InMemoryWorkerStore()
    release = Base.Event()

    try
        owner_id = submit_sequential_task("reports", "nightly-rollup", task_info -> begin
            wait(release)
            return "owner-result"
        end, Owner("owner"); scope=:global, store=store)
        @test owner_id == "nightly-rollup"

        @test_throws AuthorizationError submit_sequential_task(
            "reports", "nightly-rollup", () -> "noop", Owner("attacker"); scope=:global, store=store)

        notify(release)
        @test wait_for(() -> get_task_status(owner_id, Owner("owner"); store=store)[:status] == "COMPLETED") == :ok
        @test get_task_status(owner_id, Owner("owner"); store=store)[:result] == "owner-result"
        @test_throws AuthorizationError get_task_status(owner_id, Owner("attacker"); store=store)

        # Terminal state is gated on the sequential path too.
        @test_throws AuthorizationError submit_sequential_task(
            "reports", "nightly-rollup", () -> "noop", Owner("attacker"); scope=:global, store=store)
    finally
        notify(release)
        reset_store!(store)
    end
end

@testset "User-scoped keys isolate same-key submissions across users (#19)" begin
    store = InMemoryWorkerStore()
    a_calls = Ref(0)
    b_calls = Ref(0)
    release = Base.Event()

    try
        # Both users submit the SAME caller-supplied key.
        a_id = submit_task("export_report_42", () -> begin
            a_calls[] += 1
            wait(release)
            return "victim-secret"
        end, Owner("user-a"); store=store)

        b_id = submit_task("export_report_42", () -> begin
            b_calls[] += 1
            wait(release)
            return "attacker-data"
        end, Owner("user-b"); store=store)

        @test a_id == "user-a::export_report_42"
        @test b_id == "user-b::export_report_42"
        @test a_id != b_id

        # Two independent tasks: no deduplication across users, so both run.
        notify(release)
        @test wait_for(() -> get_task_status(a_id, Owner("user-a"); store=store)[:status] == "COMPLETED") == :ok
        @test wait_for(() -> get_task_status(b_id, Owner("user-b"); store=store)[:status] == "COMPLETED") == :ok
        @test a_calls[] == 1
        @test b_calls[] == 1

        # Neither user became a watcher of the other's task.
        @test get_task_status(a_id, Owner("user-a"); store=store)[:watcher_count] == 1
        @test get_task_status(b_id, Owner("user-b"); store=store)[:watcher_count] == 1

        # The escalation the issue reports: reading and cancelling across users.
        @test get_task_status(a_id, Owner("user-a"); store=store)[:result] == "victim-secret"
        @test_throws AuthorizationError get_task_status(a_id, Owner("user-b"); store=store)
        @test_throws AuthorizationError cancel_task(a_id, Owner("user-b"); store=store)
    finally
        notify(release)
        reset_store!(store)
    end
end

@testset "Global-scoped keys refuse cross-user join and reuse (#19)" begin
    store = InMemoryWorkerStore()
    release = Base.Event()
    attacker_calls = Ref(0)

    try
        owner_id = submit_task("shared-export", () -> begin
            wait(release)
            return "victim-secret"
        end, Owner("victim"); scope=:global, store=store)
        @test owner_id == "shared-export"

        # Case 1 — the task is live. Joining it would hand over read/cancel rights.
        @test_throws AuthorizationError submit_task("shared-export", () -> begin
            attacker_calls[] += 1
            return "noop"
        end, Owner("attacker"); scope=:global, store=store)

        # The refused submit left no trace on the victim's task.
        @test get_task_status(owner_id, Owner("victim"); store=store)[:watcher_count] == 1
        @test_throws AuthorizationError get_task_status(owner_id, Owner("attacker"); store=store)
        @test_throws AuthorizationError cancel_task(owner_id, Owner("attacker"); store=store)

        notify(release)
        @test wait_for(() -> get_task_status(owner_id, Owner("victim"); store=store)[:status] == "COMPLETED") == :ok

        # Case 2 — the task is finished. Re-running the key would overwrite the
        # owner's stored result and drop them from the watcher list.
        @test_throws AuthorizationError submit_task("shared-export", () -> begin
            attacker_calls[] += 1
            return "noop"
        end, Owner("attacker"); scope=:global, store=store)

        after = get_task_status(owner_id, Owner("victim"); store=store)
        @test after[:status] == "COMPLETED"
        @test after[:result] == "victim-secret"
        @test after[:watcher_count] == 1
        @test attacker_calls[] == 0

        # The owner may still re-run their own finished key.
        again = submit_task("shared-export", () -> "second-run", Owner("victim"); scope=:global, store=store)
        @test again == owner_id
        @test wait_for(() -> get_task_status(owner_id, Owner("victim"); store=store)[:result] == "second-run") == :ok
    finally
        notify(release)
        reset_store!(store)
    end
end

@testset "Watch authorizer opts back into cross-user sharing" begin
    store = InMemoryWorkerStore()
    release = Base.Event()
    seen = Ref{Any}(nothing)

    set_watch_authorizer!(store, (task_key, watchers, user_id) -> begin
        seen[] = (task_key, watchers, user_id)
        return user_id == "teammate"
    end)

    try
        owner_id = submit_task("team-export", () -> begin
            wait(release)
            return "shared-result"
        end, Owner("owner"); scope=:global, store=store)

        # Denied: the hook says no.
        @test_throws AuthorizationError submit_task("team-export", () -> "noop", Owner("stranger"); scope=:global, store=store)
        @test seen[] == ("team-export", ["owner"], "stranger")

        # Allowed: the hook says yes, so the teammate joins as a watcher and
        # deduplicates onto the running task rather than starting a second one.
        joined = submit_task("team-export", () -> error("must not run"), Owner("teammate"); scope=:global, store=store)
        @test joined == owner_id

        notify(release)
        @test wait_for(() -> get_task_status(owner_id, Owner("owner"); store=store)[:status] == "COMPLETED") == :ok

        status = get_task_status(owner_id, Owner("teammate"); store=store)
        @test status[:result] == "shared-result"
        @test status[:watcher_count] == 2
        @test_throws AuthorizationError get_task_status(owner_id, Owner("stranger"); store=store)

        # The hook is not consulted for a user who already watches the task.
        seen[] = nothing
        @test submit_task("team-export", () -> "re-run", Owner("owner"); scope=:global, store=store) == owner_id
        @test seen[] === nothing

        # Re-running a finished key REPLACES the record, so the watcher list resets to
        # the submitter and previously-authorized sharers are evicted. Documented on
        # set_watch_authorizer! — asserted here so the behavior cannot drift silently.
        @test wait_for(() -> get_task_status(owner_id, Owner("owner"); store=store)[:result] == "re-run") == :ok
        @test get_task_status(owner_id, Owner("owner"); store=store)[:watcher_count] == 1
        @test_throws AuthorizationError get_task_status(owner_id, Owner("teammate"); store=store)
    finally
        notify(release)
        reset_store!(store)
    end
end

@testset "submit_task is subject to the queue authorizer under DEFAULT_QUEUE_NAME" begin
    store = InMemoryWorkerStore()
    calls = Ref(Tuple{String, String}[])

    set_queue_authorizer!(store, (queue_name, user_id) -> begin
        push!(calls[], (queue_name, user_id))
        return user_id == "allowed"
    end)

    try
        @test DEFAULT_QUEUE_NAME == "default"

        ok_id = submit_task("job", () -> "ran", Owner("allowed"); store=store)
        @test ok_id == "allowed::job"
        @test wait_for(() -> get_task_status(ok_id, Owner("allowed"); store=store)[:status] == "COMPLETED") == :ok

        @test_throws AuthorizationError submit_task("job", () -> "ran", Owner("denied"); store=store)

        # The denied submission never reached the store.
        @test get_task_status("denied::job", System(); store=store)[:status] == "NOT_FOUND"

        @test calls[] == [(DEFAULT_QUEUE_NAME, "allowed"), (DEFAULT_QUEUE_NAME, "denied")]
    finally
        reset_store!(store)
    end
end

@testset "Zombie task recovery on startup" begin
    store = InMemoryWorkerStore()

    try
        # Setup a running task that has NO live execution handle
        lock(store.task_lock) do
            t1 = TaskInfo("zombie-running")
            t1.status = RUNNING
            t1.created_at = Dates.now(Dates.UTC)
            store.task_registry[t1.id] = t1

            # And a running task that DOES have a live execution handle (should NOT be recovered)
            t2 = TaskInfo("active-running")
            t2.status = RUNNING
            t2.created_at = Dates.now(Dates.UTC)
            store.task_registry[t2.id] = t2

            # Register in-memory active task
            store.active_tasks[t2.id] = @async sleep(0.05)
        end

        # Run recovery
        recovered_count = recover_zombie_tasks!(; store=store)
        @test recovered_count == 1

        # Test zombie is marked FAILED
        zombie_status = get_task_status("zombie-running", System(); store=store)
        @test zombie_status[:status] == "FAILED"
        @test zombie_status[:error] == "Worker process terminated unexpectedly mid-execution."
        @test zombie_status[:completed_at] isa DateTime

        # Test active running task is untouched
        active_status = get_task_status("active-running", System(); store=store)
        @test active_status[:status] == "RUNNING"

        # Cleanup active task
        wait(store.active_tasks["active-running"])
    finally
        reset_store!(store)
    end
end

@testset "cancel_task is atomic: completed task result is never overwritten" begin
    store = InMemoryWorkerStore()
    try
        # Regression: cancel_task used to read status outside the task lock,
        # so a concurrent _complete_task! could overwrite COMPLETED→CANCELLED.
        task_id = submit_task("race-task", () -> "safe-result", Owner("user"); store=store)
        @test wait_for(() -> get_task_status(task_id, Owner("user"); store=store)[:status] == "COMPLETED") == :ok

        # Cancelling an already-completed task must return an error, not overwrite the result.
        result = cancel_task(task_id, Owner("user"); store=store)
        @test haskey(result, :error)

        final = get_task_status(task_id, Owner("user"); store=store)
        @test final[:status] == "COMPLETED"
        @test final[:result] == "safe-result"
    finally
        reset_store!(store)
    end
end

@testset "terminal state fields are consistent: error and completed_at visible with status" begin
    store = InMemoryWorkerStore()
    try
        # Regression: _fail_task! and _cancel_task! used to write status before error/completed_at,
        # so concurrent readers could observe status=FAILED with error=nothing.
        task_id = submit_task("fail-task", () -> error("boom"), Owner("user"); store=store)
        @test wait_for(() -> get_task_status(task_id, Owner("user"); store=store)[:status] == "FAILED"; timeout=10.0) == :ok

        status = get_task_status(task_id, Owner("user"); store=store)
        @test status[:error] !== nothing
        @test occursin("boom", status[:error])
        @test status[:completed_at] !== nothing
    finally
        reset_store!(store)
    end

    store2 = InMemoryWorkerStore()
    started = Base.Event()
    try
        task_id2 = submit_task("cancel-fields-task", task_info -> begin
            notify(started)
            while true; sleep(0.01); end
        end, Owner("user"); store=store2)

        wait(started)
        cancel_task(task_id2, Owner("user"); store=store2)
        @test wait_for(() -> get_task_status(task_id2, Owner("user"); store=store2)[:status] == "CANCELLED") == :ok

        status2 = get_task_status(task_id2, Owner("user"); store=store2)
        @test status2[:error] !== nothing
        @test status2[:completed_at] !== nothing
    finally
        reset_store!(store2)
    end
end

@testset "concurrent cancel and task completion: always reaches a consistent terminal state" begin
    # Stress test for the TOCTOU race between cancel_task and _complete_task!.
    # Without the lock_tasks fix both could write to the same task, leaving it
    # CANCELLED with result=nothing even though the callback completed.
    store = InMemoryWorkerStore()
    try
        for trial in 1:30
            reset_store!(store)
            gate = Base.Event()

            task_id = submit_task("race-$(trial)", () -> begin
                notify(gate)
                sleep(0.001)
                return "result-$(trial)"
            end, Owner("user"); store=store)

            wait(gate)
            cancel_task(task_id, Owner("user"); store=store)

            # Let either path finish.
            wait_for(() -> get_task_status(task_id, Owner("user"); store=store)[:status] in ("COMPLETED", "CANCELLED"))

            final = get_task_status(task_id, Owner("user"); store=store)
            @test final[:status] in ("COMPLETED", "CANCELLED")
            if final[:status] == "COMPLETED"
                @test final[:result] == "result-$(trial)"
            else
                @test final[:error] !== nothing
                @test final[:completed_at] !== nothing
            end
        end
    finally
        reset_store!(store)
    end
end

end