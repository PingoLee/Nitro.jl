@testitem "Workers" tags=[:core, :workers] setup=[NitroCommon] begin

using Test
using Dates
using Suppressor
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

@testset "Sequential callbacks defined after the processor spawned still run (#86)" begin
    store = InMemoryWorkerStore()
    auth = Owner("user-a")

    try
        # Defined BEFORE the processor spawns, so it is inside the processor's frozen world.
        @eval mixed_cb() = "zero-arg (old)"

        # The FIRST sequential submit spawns the queue processor, freezing its world age.
        first_id = submit_sequential_task("wq86", "first", () -> "first", auth; store=store)
        @test wait_for(() -> get_task_status(first_id, auth; store=store)[:status] == "COMPLETED") == :ok

        # `@eval` is the whole point of this test: it defines methods at a world age LATER than
        # the processor's. A closure literal written here would not -- it is compiled with the
        # rest of this block, so it predates the processor and cannot reproduce #86. That is
        # exactly why "Sequential queues preserve order" (one shared closure in a loop) missed it.
        @eval late_one_arg(task_info) = "late one-arg"
        @eval late_zero_arg() = "late zero-arg"

        second_id = submit_sequential_task("wq86", "second", late_one_arg, auth; store=store)
        @test wait_for(() -> get_task_status(second_id, auth; store=store)[:status] == "COMPLETED") == :ok
        @test get_task_status(second_id, auth; store=store)[:result] == "late one-arg"

        third_id = submit_sequential_task("wq86", "third", late_zero_arg, auth; store=store)
        @test wait_for(() -> get_task_status(third_id, auth; store=store)[:status] == "COMPLETED") == :ok
        @test get_task_status(third_id, auth; store=store)[:result] == "late zero-arg"

        # The sharper half of #86: not just "throws for a method that exists", but SILENTLY
        # CALLS THE WRONG ARITY. `mixed_cb` has a zero-arg method from before the processor
        # spawned; the one-arg method arrives after. A world-age-frozen `applicable` cannot see
        # the newer method, falls through to the zero-arg branch, and runs the callback WITHOUT
        # its task_info -- no error, wrong behaviour. This is what Revise adding a parameter to
        # a live callback looks like.
        @eval mixed_cb(task_info) = "one-arg (new)"
        fourth_id = submit_sequential_task("wq86", "fourth", mixed_cb, auth; store=store)
        @test wait_for(() -> get_task_status(fourth_id, auth; store=store)[:status] == "COMPLETED") == :ok
        @test get_task_status(fourth_id, auth; store=store)[:result] == "one-arg (new)"
    finally
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

        # Cooperative, because cancellation IS cooperative now (#127). Nitro no longer
        # interrupts the task, so a `while true` callback would outlive the testset and spin
        # for the rest of the process.
        cancel_id = submit_task("cancel-task", task_info -> begin
            notify(started)
            while !cancel_requested(task_info)
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

@testset "watchers= grants a second identity access at submit time (#96)" begin
    store = InMemoryWorkerStore()
    try
        # The motivating case: the identity that submits is not the one that polls.
        # A browser uploads under a short-lived credential; the backend, holding a
        # different long-lived one, drives the progress bar.
        task_id = submit_task("import-42", () -> "imported", Owner("browser-client");
                              watchers=[Owner("backend-service")], store=store)

        @test wait_for(() -> get_task_status(task_id, Owner("browser-client"); store=store)[:status] == "COMPLETED") == :ok

        # The grantee can read and list...
        @test get_task_status(task_id, Owner("backend-service"); store=store)[:result] == "imported"
        @test only(get_all_tasks(Owner("backend-service"); store=store))[:id] == task_id
        # ...but ownership stays with the submitter: it is derived from the id.
        @test get_task_status(task_id, Owner("backend-service"); store=store)[:owner] == "browser-client"

        # Nobody else is admitted by the grant.
        @test_throws AuthorizationError get_task_status(task_id, Owner("stranger"); store=store)

        # Granting an identity that is already a watcher is a no-op, owner included.
        again = submit_task("solo", () -> "x", Owner("alice");
                            watchers=[Owner("alice")], store=store)
        @test get_task_status(again, Owner("alice"); store=store)[:watcher_count] == 1
    finally
        reset_store!(store)
    end
end

@testset "a :global grant is still subject to the watch authorizer (#96)" begin
    store = InMemoryWorkerStore()
    org = Dict("victim" => "A", "bob" => "A", "mallory" => "B")
    set_watch_authorizer!(store, (task_key, watchers, user_id) ->
        get(org, first(watchers), nothing) == get(org, user_id, nothing))

    try
        gid = submit_task("shared-index", () -> "secret", Owner("victim");
                          scope=:global, store=store)

        # A direct join by an out-of-org user is refused — that is #19's gate.
        @test_throws AuthorizationError submit_task("shared-index", () -> "x", Owner("mallory");
                                                   scope=:global, store=store)

        # ...so a grant must not be a way around it. For a :global task there is no owner
        # in the id, which makes the watch authorizer the entire access policy; letting an
        # admitted watcher hand access onward would be transitive expansion the app never
        # approved — and it would carry cancel rights too.
        @test_throws AuthorizationError submit_task("shared-index", () -> "x", Owner("bob");
                                                   scope=:global, watchers=[Owner("mallory")],
                                                   store=store)
        @test_throws AuthorizationError get_task_status(gid, Owner("mallory"); store=store)

        # The refused submit must not have persisted the grants that preceded the
        # refusal: a submit that raised should not have handed out any access.
        @test_throws AuthorizationError submit_task("shared-index", () -> "x", Owner("victim");
                                                   scope=:global,
                                                   watchers=[Owner("bob"), Owner("mallory")],
                                                   store=store)
        @test_throws AuthorizationError get_task_status(gid, Owner("bob"); store=store)

        # An in-org grantee the authorizer accepts still goes through.
        @test submit_task("shared-index", () -> "x", Owner("victim");
                          scope=:global, watchers=[Owner("bob")], store=store) == gid
        @test get_task_status(gid, Owner("bob"); store=store)[:id] == gid
    finally
        reset_store!(store)
    end
end

@testset "a :user grant needs no authorizer — the owner owns the task (#96)" begin
    store = InMemoryWorkerStore()
    # An authorizer that refuses everyone. It governs :global key reuse only, so it must
    # not reach a :user-scoped owner sharing their own task.
    set_watch_authorizer!(store, (task_key, watchers, user_id) -> false)

    try
        task_id = submit_task("report", () -> "mine", Owner("alice");
                              watchers=[Owner("helper")], store=store)
        @test get_task_status(task_id, Owner("helper"); store=store)[:id] == task_id
    finally
        reset_store!(store)
    end
end

@testset "watchers= grants cancel too, and does not survive a record reset (#96)" begin
    store = InMemoryWorkerStore()
    started = Base.Event()
    try
        task_id = submit_task("long-job", task_info -> begin
            notify(started)
            while !cancel_requested(task_info)
                sleep(0.01)
            end
        end, Owner("owner-a"); watchers=[Owner("helper")], store=store)
        wait(started)

        # A grantee gets the owner's rights minus ownership, and `cancel_task` gates on
        # the same list -- so the grant carries cancel. Documented, not incidental.
        @test cancel_task(task_id, Owner("helper"); store=store)[:status] == "Task cancelled"
        @test wait_for(() -> get_task_status(task_id, Owner("owner-a"); store=store)[:status] == "CANCELLED") == :ok

        # Re-running a finished key replaces the record, so its watcher list resets to
        # the resubmitter and grants must be passed again.
        again = submit_task("long-job", () -> "second", Owner("owner-a"); store=store)
        @test again == task_id
        @test wait_for(() -> get_task_status(task_id, Owner("owner-a"); store=store)[:result] == "second") == :ok
        @test_throws AuthorizationError get_task_status(task_id, Owner("helper"); store=store)
    finally
        notify(started)
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
                                  run_id=t.run_id,
                                  error="Cancelled", completed_at=Dates.now(Dates.UTC)) == true
            after = get_task_info(store, "alice::cas")
            @test after.status == CANCELLED
            @test after.error == "Cancelled"

            # Already left the `from` set: no second transition, and nothing written.
            @test try_transition!(store, "alice::cas", (PENDING, RUNNING), COMPLETED;
                                  run_id=nothing) == false
            @test get_task_info(store, "alice::cas").status == CANCELLED
            @test try_transition!(store, "no-such-task", (PENDING,), CANCELLED;
                                  run_id=nothing) == false
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

@testset "terminal writes are addressed to a run, not just a task id (#108)" begin
    store = InMemoryWorkerStore()
    try
        # Deliberately driven through the store primitives rather than through real tasks.
        # The bug is a property of the compare-and-set, and asserting it directly makes the
        # test deterministic -- no sleeps, no scheduling, nothing to flake.
        @testset "a stale run's terminal write cannot land on its successor" begin
            a = TaskInfo("alice::report")            # run A, still in flight
            a.status = RUNNING
            replace_task!(store, a.id, a)

            b = TaskInfo("alice::report")            # the resubmit: fresh PENDING record
            replace_task!(store, b.id, b)
            @test b.run_id != a.run_id

            # Verbatim the CAS `_finish_task!` issues. B's record satisfies the STATUS
            # precondition -- PENDING is in `from` -- which is exactly why the status alone
            # was never enough.
            @test try_transition!(store, a.id, (PENDING, RUNNING), COMPLETED;
                                  run_id=a.run_id, result="stale",
                                  completed_at=Dates.now(Dates.UTC)) == false

            live = get_task_info(store, a.id)
            @test live.status == PENDING             # A's write landed nowhere...
            @test live.result === nothing
            @test live.run_id == b.run_id

            # ...and B's own write still wins.
            @test try_transition!(store, b.id, (PENDING, RUNNING), COMPLETED;
                                  run_id=b.run_id, result="fresh") == true
            @test get_task_info(store, b.id).result == "fresh"
        end

        @testset "run_id = nothing is the named, unconditional bypass" begin
            c = TaskInfo("alice::bypass")
            replace_task!(store, c.id, c)
            @test try_transition!(store, c.id, (PENDING,), CANCELLED; run_id=nothing) == true
            @test get_task_info(store, c.id).status == CANCELLED
        end

        @testset "every TaskInfo is its own run" begin
            @test TaskInfo("alice::x").run_id != TaskInfo("alice::x").run_id
        end

        @testset "set_task! never writes run_id; replace_task! does" begin
            original = TaskInfo("alice::split")
            replace_task!(store, original.id, original)

            # A DIFFERENT object carrying a different run id -- the shape a stale worker
            # holds. `set_task!` must carry its state across and leave the identity alone,
            # exactly as it already does for `watchers`.
            stale = TaskInfo("alice::split")
            stale.status = RUNNING
            set_task!(store, stale.id, stale)

            stored = get_task_info(store, "alice::split")
            @test stored.run_id == original.run_id   # identity untouched
            @test stored.status == RUNNING           # state carried

            # ...and the one sanctioned way to publish a new run's identity.
            replace_task!(store, stale.id, stale)
            @test get_task_info(store, "alice::split").run_id == stale.run_id
        end

        @testset "a stale run's teardown cannot evict its successor's live handle" begin
            a = TaskInfo("alice::handles")
            a.status = RUNNING
            replace_task!(store, a.id, a)
            register_active_task!(store, a.id, @async sleep(0.01))

            b = TaskInfo("alice::handles")           # the resubmit takes over the key
            b.status = RUNNING
            replace_task!(store, b.id, b)
            b_handle = @async (sleep(30); nothing)
            register_active_task!(store, b.id, b_handle)
            register_active_task_info!(store, b.id, b)

            # Run A finally finishes. Its CAS correctly writes nothing -- but before #108
            # the teardown that follows was keyed by ID, so it deleted B's handle too.
            Nitro.Workers._finish_task!(store, a, COMPLETED; result="stale")

            @test get_active_task(store, "alice::handles") === b_handle
            @test get_task_info(store, "alice::handles").status == RUNNING

            # Why that mattered: zombie recovery decides liveness from exactly that handle,
            # so an unfenced teardown made a genuinely-running successor look dead.
            recover_zombie_tasks!(; store=store)
            @test get_task_info(store, "alice::handles").status == RUNNING
        end
    finally
        reset_store!(store)
    end
end

@testset "a cancel that lands before the body starts is not overwritten (#142)" begin
    @testset "the start write is a claim, so it cannot undo a cancellation" begin
        store = InMemoryWorkerStore()
        try
            t = TaskInfo("alice::early")
            replace_task!(store, t.id, t)

            @test try_transition!(store, t.id, (PENDING,), CANCELLED;
                                  run_id=t.run_id, error="Cancelled") == true

            # THE property. Starting used to be an unconditional `set_task!`, so this write
            # landed regardless and put the record back to RUNNING -- after which
            # `_complete_task!`'s own CAS succeeded and reported COMPLETED for a task whose
            # caller had been told "Task cancelled".
            @test try_transition!(store, t.id, (PENDING,), RUNNING;
                                  run_id=t.run_id,
                                  started_at=Dates.now(Dates.UTC)) == false
            @test get_task_info(store, t.id).status == CANCELLED
            @test get_task_info(store, t.id).started_at === nothing
        finally
            reset_store!(store)
        end
    end

    @testset "a claimed cancel is never followed by COMPLETED" begin
        store = InMemoryWorkerStore()
        try
            # Cancel IMMEDIATELY after submit, without waiting for the callback to start --
            # the window every other cancel test in this file deliberately closes by first
            # waiting on an Event notified from *inside* the callback.
            id = submit_task("race", () -> "done", Owner("u"); store=store)
            @test cancel_task(id, Owner("u"); store=store)[:status] == "Task cancelled"

            # A NEGATIVE, time-bounded assertion, and that direction is the point: a slow
            # machine still times out, so this cannot flake into a false failure -- it can
            # only fail if the status actually leaves CANCELLED, which is the bug. Asserting
            # `wait_for(status == "CANCELLED")` instead would be useless here, since
            # `timedwait` evaluates its predicate once up front and the record is already
            # CANCELLED at that instant; the overwrite lands later.
            @test timedwait(() -> get_task_status(id, Owner("u"); store=store)[:status] !=
                                  "CANCELLED", 2.0) == :timed_out
            @test get_task_status(id, Owner("u"); store=store)[:status] == "CANCELLED"
        finally
            reset_store!(store)
        end
    end

    @testset "a queued item cancelled before it is dequeued never runs its callback" begin
        store = InMemoryWorkerStore()
        ran = Threads.Atomic{Bool}(false)
        try
            t = TaskInfo("alice::queued"; queue_name="reports")
            replace_task!(store, t.id, t)
            @test try_transition!(store, t.id, (PENDING,), CANCELLED;
                                  run_id=t.run_id, error="Cancelled") == true

            # Driven synchronously on purpose: the sequential processor calls exactly this,
            # so the assertion is about the function rather than about scheduling.
            item = Nitro.Workers.QueueItem(t.id, () -> (ran[] = true; "done"), TaskOptions())
            Nitro.Workers._execute_queued_task(store, item)

            @test ran[] == false
            @test get_task_info(store, t.id).status == CANCELLED
        finally
            reset_store!(store)
        end
    end
end

@testset "cancellation is cooperative, never injected (#127)" begin
    @testset "cancel_task sets the run's token, and the callback observes it" begin
        store = InMemoryWorkerStore()
        entered = Base.Event()
        saw_token = Threads.Atomic{Bool}(false)
        ran_finally = Threads.Atomic{Bool}(false)
        try
            id = submit_task("cooperative", task_info -> begin
                notify(entered)
                try
                    while !cancel_requested(task_info)
                        sleep(0.01)
                    end
                    saw_token[] = true
                    return "stopped"
                finally
                    # Under the old model this ran because the injected exception unwound
                    # the callback. Now it runs only because the callback RETURNS -- which
                    # is the whole behavioural change apps have to absorb.
                    ran_finally[] = true
                end
            end, Owner("u"); store=store)

            wait(entered)
            @test cancel_requested(get_task_info(store, id)) == false
            @test cancel_task(id, Owner("u"); store=store)[:status] == "Task cancelled"

            @test wait_for(() -> saw_token[]) == :ok
            @test wait_for(() -> ran_finally[]) == :ok
            @test get_task_status(id, Owner("u"); store=store)[:status] == "CANCELLED"
        finally
            reset_store!(store)
        end
    end

    @testset "an uncooperative callback is not stopped, and cancel does not block on it" begin
        store = InMemoryWorkerStore()
        entered = Base.Event()
        release = Base.Event()
        returned = Threads.Atomic{Bool}(false)
        try
            id = submit_task("uncooperative", () -> begin
                notify(entered)
                wait(release)               # never polls the token
                returned[] = true
                return "finished anyway"
            end, Owner("u"); store=store)

            wait(entered)
            # Returns immediately: the terminal state is recorded by the CAS, and there is
            # nothing to wait for. This is the contract the docs claimed and the interrupt
            # never actually delivered.
            @test cancel_task(id, Owner("u"); store=store)[:status] == "Task cancelled"
            @test get_task_status(id, Owner("u"); store=store)[:status] == "CANCELLED"
            @test returned[] == false       # still running, as documented

            notify(release)
            @test wait_for(() -> returned[]) == :ok
            # It ran to completion -- and still must not overwrite the cancellation.
            @test wait_for(() -> get_task_status(id, Owner("u"); store=store)[:status] ==
                                 "CANCELLED") == :ok
        finally
            notify(release)
            reset_store!(store)
        end
    end

    @testset "a timeout sets the token, records FAILED, and is never retried" begin
        store = InMemoryWorkerStore()
        entries = Threads.Atomic{Int}(0)
        try
            # retry_on_failure is ON on purpose: a timeout must still be terminal on the
            # first attempt. Retrying would put a second copy of the callback beside the
            # first, since nothing can stop the one that timed out.
            id = @suppress_err submit_task("slow", () -> begin
                Threads.atomic_add!(entries, 1)
                sleep(2.0)                  # outruns the deadline, ignores the token
                return "too late"
            end, Owner("u");
            options=TaskOptions(timeout=1, retry_on_failure=true, max_retries=2), store=store)

            @test wait_for(() -> get_task_status(id, Owner("u"); store=store)[:status] ==
                                 "FAILED"; timeout=10.0) == :ok
            status = get_task_status(id, Owner("u"); store=store)
            @test occursin("Timeout of 1s exceeded", status[:error])
            @test entries[] == 1
        finally
            reset_store!(store)
        end
    end

    @testset "nothing in Workers injects an exception into a task" begin
        # A source assertion, because the property is "no site in this module does this"
        # rather than "this function behaves thus" -- and reintroducing the injection is
        # the specific regression that would make worker bodies unsafe to migrate again.
        for file in ("api.jl", "execution.jl", "queue.jl")
            src = read(joinpath(pkgdir(Nitro), "src", "Workers", file), String)
            # Comments are stripped first: the sites that were removed are DESCRIBED in
            # comments right where they used to be, and a guard that cannot tell an
            # explanation from a call would fail on its own documentation.
            code = join((line for line in eachsplit(src, "
")
                         if !startswith(strip(line), "#")), "
")
            @test !occursin("error=true", code)
            @test !occursin("error = true", code)
        end
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
            while !cancel_requested(task_info); sleep(0.01); end
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