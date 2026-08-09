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
        end, "user-a"; store=store)

        # Same user, same key, still running: deduplicates onto the live task.
        duplicate_id = submit_task("immediate-task", () -> begin
            calls[] += 100
            return "duplicate"
        end, "user-a"; store=store)

        @test task_id == "user-a::immediate-task"
        @test duplicate_id == task_id

        notify(gate)
        @test wait_for(() -> get_task_status(task_id; store=store)[:status] == "COMPLETED") == :ok

        status = get_task_status(task_id; store=store)
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
            end, "user"; store=store))
        end

        @test ids == ["user::queued-1", "user::queued-2", "user::queued-3"]
        @test wait_for(() -> all(get_task_status(id; store=store)[:status] == "COMPLETED" for id in ids)) == :ok
        @test observed == ids

        queue_status = get_queue_status("reports"; store=store)
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
        end, "user"; options=TaskOptions(retry_on_failure=true, max_retries=2), store=store)

        @test wait_for(() -> get_task_status(retry_id; store=store)[:status] == "COMPLETED"; timeout=10.0) == :ok
        @test attempts[] == 3

        cancel_id = submit_task("cancel-task", task_info -> begin
            notify(started)
            while true
                sleep(0.01)
            end
            return task_info.id
        end, "user"; store=store)

        wait(started)
        cancel_result = cancel_task(cancel_id; store=store)
        @test cancel_result[:status] == "Task cancelled"
        @test wait_for(() -> get_task_status(cancel_id; store=store)[:status] == "CANCELLED") == :ok

        lock(store.task_lock) do
            expired = TaskInfo("expired-task")
            expired.status = COMPLETED
            expired.completed_at = Dates.now(Dates.UTC) - Dates.Day(10)
            store.task_registry[expired.id] = expired
        end

        @test cleanup_old_tasks(7; store=store) == 1
        @test get_task_status("expired-task"; store=store)[:status] == "NOT_FOUND"
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
        @test wait_for(() -> get_task_status("scheduled-expired"; store=store)[:status] == "NOT_FOUND") == :ok
        stop_cleanup_scheduler!(scheduler)

        ctx_task_id = submit_task(ctx_one, "ctx-task", () -> "ctx-one", "user")
        @test ctx_task_id == "user::ctx-task"
        @test wait_for(() -> get_task_status(ctx_one, ctx_task_id)[:status] == "COMPLETED") == :ok
        @test get_task_status(ctx_one, ctx_task_id)[:result] == "ctx-one"
        @test get_task_status(ctx_two, ctx_task_id)[:status] == "NOT_FOUND"
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
    @test get_queue_status(ctx, "reports")[:running] == true
    @test store.cleanup_scheduler[] isa CleanupScheduler

    lock(store.task_lock) do
        expired = TaskInfo("lifecycle-expired")
        expired.status = COMPLETED
        expired.completed_at = Dates.now(Dates.UTC) - Dates.Day(10)
        store.task_registry[expired.id] = expired
    end

    @test wait_for(() -> get_task_status(ctx, "lifecycle-expired")[:status] == "NOT_FOUND") == :ok

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
        task1 = submit_sequential_task("admin-queue", "task-auth-ok", () -> "ok", "admin-user"; store=store)
        @test task1 == "admin-user::task-auth-ok"

        # Unauthorized user throws AuthorizationError
        @test_throws AuthorizationError submit_sequential_task("admin-queue", "task-auth-fail", () -> "fail", "other-user"; store=store)

        # 2. Task querying and watchers access control
        # submit a task by user-a (so user-a is the first watcher)
        task_id = submit_task("task-access", () -> "data", "user-a"; store=store)
        @test task_id == "user-a::task-access"

        # user-a can check status
        status_a = get_task_status(task_id, "user-a"; store=store)
        @test status_a[:id] == task_id

        # user-b cannot check status (throws AuthorizationError)
        @test_throws AuthorizationError get_task_status(task_id, "user-b"; store=store)

        # check without user_id works (system bypass)
        @test get_task_status(task_id; store=store)[:id] == task_id

        # 3. Listing tasks (get_all_tasks)
        # add another task by user-b
        task_b_id = submit_task("task-user-b", () -> "data", "user-b"; store=store)

        # get_all_tasks for user-a only returns task-access
        tasks_a = get_all_tasks(nothing, "user-a"; store=store)
        @test length(tasks_a) == 1
        @test tasks_a[1][:id] == task_id

        # get_all_tasks for user-b only returns task-user-b
        tasks_b = get_all_tasks(nothing, "user-b"; store=store)
        @test length(tasks_b) == 1
        @test tasks_b[1][:id] == task_b_id

        # get_all_tasks without user returns both
        all_tasks = get_all_tasks(nothing; store=store)
        @test length(all_tasks) == 3 # task-auth-ok + task-access + task-user-b

        # 4. Cancellation access control
        # user-b cannot cancel user-a's task
        @test_throws AuthorizationError cancel_task(task_id, "user-b"; store=store)

        # user-a can cancel their own task
        cancel_res = cancel_task(task_id, "user-a"; store=store)
        @test cancel_res[:status] == "Task cancelled"
    finally
        reset_store!(store)
    end
end

@testset "scoped_task_key resolves and validates the stored id" begin
    @test scoped_task_key("export_42", "user-a") == "user-a::export_42"
    @test scoped_task_key("export_42", "user-a"; scope=:user) == "user-a::export_42"
    @test scoped_task_key("export_42", "user-a"; scope=:global) == "export_42"

    # A :user task key may contain the delimiter; the owner may not, or
    # ("a", "::b") and ("a::", "b") would resolve to the same id.
    @test scoped_task_key("a::b", "user-a") == "user-a::a::b"
    @test_throws ArgumentError scoped_task_key("b", "user-a::")
    @test_throws ArgumentError scoped_task_key("b", "::")

    # An owner ending in ':' is the one remaining collision: without this rule
    # (":report", "alice") and ("report", "alice:") both give "alice:::report".
    @test_throws ArgumentError scoped_task_key("report", "alice:")
    @test scoped_task_key(":report", "alice") == "alice:::report"
    # A colon elsewhere in the owner is still legal and stays unambiguous.
    @test scoped_task_key("report", "google:12345") == "google:12345::report"

    # A :global key may not contain it at all, or it could forge a :user id:
    # global "victim::export_42" is exactly what victim's own "export_42" resolves to.
    @test_throws ArgumentError scoped_task_key("victim::export_42", "attacker"; scope=:global)
    @test scoped_task_key("victim::export_42", "attacker") == "attacker::victim::export_42"

    @test_throws ArgumentError scoped_task_key("export_42", "user-a"; scope=:tenant)

    # The submit paths route through it, including the validation.
    store = InMemoryWorkerStore()
    try
        @test submit_task("k", () -> 1, "u"; scope=:global, store=store) == "k"
        @test_throws ArgumentError submit_task("k2", () -> 1, "bad::uid"; store=store)
        @test_throws ArgumentError submit_task("k3", () -> 1, "u"; scope=:tenant, store=store)
        @test_throws ArgumentError submit_sequential_task("q", "k4", () -> 1, "u"; scope=:tenant, store=store)

        # A global submit cannot squat a user-scoped id.
        @test_throws ArgumentError submit_task("victim::k5", () -> 1, "attacker"; scope=:global, store=store)
        @test_throws ArgumentError submit_sequential_task("q", "victim::k6", () -> 1, "attacker"; scope=:global, store=store)
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
        end, "owner"; scope=:global, store=store)
        @test owner_id == "nightly-rollup"

        @test_throws AuthorizationError submit_sequential_task(
            "reports", "nightly-rollup", () -> "noop", "attacker"; scope=:global, store=store)

        notify(release)
        @test wait_for(() -> get_task_status(owner_id; store=store)[:status] == "COMPLETED") == :ok
        @test get_task_status(owner_id, "owner"; store=store)[:result] == "owner-result"
        @test_throws AuthorizationError get_task_status(owner_id, "attacker"; store=store)

        # Terminal state is gated on the sequential path too.
        @test_throws AuthorizationError submit_sequential_task(
            "reports", "nightly-rollup", () -> "noop", "attacker"; scope=:global, store=store)
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
        end, "user-a"; store=store)

        b_id = submit_task("export_report_42", () -> begin
            b_calls[] += 1
            wait(release)
            return "attacker-data"
        end, "user-b"; store=store)

        @test a_id == "user-a::export_report_42"
        @test b_id == "user-b::export_report_42"
        @test a_id != b_id

        # Two independent tasks: no deduplication across users, so both run.
        notify(release)
        @test wait_for(() -> get_task_status(a_id; store=store)[:status] == "COMPLETED") == :ok
        @test wait_for(() -> get_task_status(b_id; store=store)[:status] == "COMPLETED") == :ok
        @test a_calls[] == 1
        @test b_calls[] == 1

        # Neither user became a watcher of the other's task.
        @test get_task_status(a_id; store=store)[:watcher_count] == 1
        @test get_task_status(b_id; store=store)[:watcher_count] == 1

        # The escalation the issue reports: reading and cancelling across users.
        @test get_task_status(a_id, "user-a"; store=store)[:result] == "victim-secret"
        @test_throws AuthorizationError get_task_status(a_id, "user-b"; store=store)
        @test_throws AuthorizationError cancel_task(a_id, "user-b"; store=store)
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
        end, "victim"; scope=:global, store=store)
        @test owner_id == "shared-export"

        # Case 1 — the task is live. Joining it would hand over read/cancel rights.
        @test_throws AuthorizationError submit_task("shared-export", () -> begin
            attacker_calls[] += 1
            return "noop"
        end, "attacker"; scope=:global, store=store)

        # The refused submit left no trace on the victim's task.
        @test get_task_status(owner_id; store=store)[:watcher_count] == 1
        @test_throws AuthorizationError get_task_status(owner_id, "attacker"; store=store)
        @test_throws AuthorizationError cancel_task(owner_id, "attacker"; store=store)

        notify(release)
        @test wait_for(() -> get_task_status(owner_id; store=store)[:status] == "COMPLETED") == :ok

        # Case 2 — the task is finished. Re-running the key would overwrite the
        # owner's stored result and drop them from the watcher list.
        @test_throws AuthorizationError submit_task("shared-export", () -> begin
            attacker_calls[] += 1
            return "noop"
        end, "attacker"; scope=:global, store=store)

        after = get_task_status(owner_id, "victim"; store=store)
        @test after[:status] == "COMPLETED"
        @test after[:result] == "victim-secret"
        @test after[:watcher_count] == 1
        @test attacker_calls[] == 0

        # The owner may still re-run their own finished key.
        again = submit_task("shared-export", () -> "second-run", "victim"; scope=:global, store=store)
        @test again == owner_id
        @test wait_for(() -> get_task_status(owner_id; store=store)[:result] == "second-run") == :ok
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
        end, "owner"; scope=:global, store=store)

        # Denied: the hook says no.
        @test_throws AuthorizationError submit_task("team-export", () -> "noop", "stranger"; scope=:global, store=store)
        @test seen[] == ("team-export", ["owner"], "stranger")

        # Allowed: the hook says yes, so the teammate joins as a watcher and
        # deduplicates onto the running task rather than starting a second one.
        joined = submit_task("team-export", () -> error("must not run"), "teammate"; scope=:global, store=store)
        @test joined == owner_id

        notify(release)
        @test wait_for(() -> get_task_status(owner_id; store=store)[:status] == "COMPLETED") == :ok

        status = get_task_status(owner_id, "teammate"; store=store)
        @test status[:result] == "shared-result"
        @test status[:watcher_count] == 2
        @test_throws AuthorizationError get_task_status(owner_id, "stranger"; store=store)

        # The hook is not consulted for a user who already watches the task.
        seen[] = nothing
        @test submit_task("team-export", () -> "re-run", "owner"; scope=:global, store=store) == owner_id
        @test seen[] === nothing

        # Re-running a finished key REPLACES the record, so the watcher list resets to
        # the submitter and previously-authorized sharers are evicted. Documented on
        # set_watch_authorizer! — asserted here so the behavior cannot drift silently.
        @test wait_for(() -> get_task_status(owner_id; store=store)[:result] == "re-run") == :ok
        @test get_task_status(owner_id; store=store)[:watcher_count] == 1
        @test_throws AuthorizationError get_task_status(owner_id, "teammate"; store=store)
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

        ok_id = submit_task("job", () -> "ran", "allowed"; store=store)
        @test ok_id == "allowed::job"
        @test wait_for(() -> get_task_status(ok_id; store=store)[:status] == "COMPLETED") == :ok

        @test_throws AuthorizationError submit_task("job", () -> "ran", "denied"; store=store)

        # The denied submission never reached the store.
        @test get_task_status("denied::job"; store=store)[:status] == "NOT_FOUND"

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
        zombie_status = get_task_status("zombie-running"; store=store)
        @test zombie_status[:status] == "FAILED"
        @test zombie_status[:error] == "Worker process terminated unexpectedly mid-execution."
        @test zombie_status[:completed_at] isa DateTime

        # Test active running task is untouched
        active_status = get_task_status("active-running"; store=store)
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
        task_id = submit_task("race-task", () -> "safe-result", "user"; store=store)
        @test wait_for(() -> get_task_status(task_id; store=store)[:status] == "COMPLETED") == :ok

        # Cancelling an already-completed task must return an error, not overwrite the result.
        result = cancel_task(task_id; store=store)
        @test haskey(result, :error)

        final = get_task_status(task_id; store=store)
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
        task_id = submit_task("fail-task", () -> error("boom"), "user"; store=store)
        @test wait_for(() -> get_task_status(task_id; store=store)[:status] == "FAILED"; timeout=10.0) == :ok

        status = get_task_status(task_id; store=store)
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
        end, "user"; store=store2)

        wait(started)
        cancel_task(task_id2; store=store2)
        @test wait_for(() -> get_task_status(task_id2; store=store2)[:status] == "CANCELLED") == :ok

        status2 = get_task_status(task_id2; store=store2)
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
            end, "user"; store=store)

            wait(gate)
            cancel_task(task_id; store=store)

            # Let either path finish.
            wait_for(() -> get_task_status(task_id; store=store)[:status] in ("COMPLETED", "CANCELLED"))

            final = get_task_status(task_id; store=store)
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