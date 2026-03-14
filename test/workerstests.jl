module WorkersTests

using Test
using Dates
using Nitro
using Nitro.Workers

function wait_for(predicate::Function; timeout::Real=5.0)
    return timedwait(predicate, timeout)
end

@testset "Immediate task execution and deduplication" begin
    store = InMemoryWorkerStore()
    calls = Ref(0)

    try
        task_id = submit_task("immediate-task", () -> begin
            calls[] += 1
            return "done"
        end, "user-a"; store=store)

        duplicate_id = submit_task("immediate-task", () -> begin
            calls[] += 100
            return "duplicate"
        end, "user-b"; store=store)

        @test task_id == "immediate-task"
        @test duplicate_id == task_id
        @test wait_for(() -> get_task_status(task_id; store=store)[:status] == "COMPLETED") == :ok

        status = get_task_status(task_id; store=store)
        @test status[:result] == "done"
        @test status[:watcher_count] == 2
        @test calls[] == 1
    finally
        reset_store!(store)
    end
end

@testset "Sequential queues preserve order" begin
    store = InMemoryWorkerStore()
    observed = String[]

    try
        for index in 1:3
            submit_sequential_task("reports", "queued-$(index)", task_info -> begin
                push!(observed, task_info.id)
                sleep(0.05)
                return task_info.id
            end, "user"; store=store)
        end

        @test wait_for(() -> all(get_task_status("queued-$(index)"; store=store)[:status] == "COMPLETED" for index in 1:3)) == :ok
        @test observed == ["queued-1", "queued-2", "queued-3"]

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
        submit_task("retry-task", () -> begin
            attempts[] += 1
            if attempts[] < 3
                error("retry me")
            end
            return "ok"
        end, "user"; options=TaskOptions(retry_on_failure=true, max_retries=2), store=store)

        @test wait_for(() -> get_task_status("retry-task"; store=store)[:status] == "COMPLETED"; timeout=10.0) == :ok
        @test attempts[] == 3

        submit_task("cancel-task", task_info -> begin
            notify(started)
            while true
                sleep(0.01)
            end
            return task_info.id
        end, "user"; store=store)

        wait(started)
        cancel_result = cancel_task("cancel-task"; store=store)
        @test cancel_result[:status] == "Task cancelled"
        @test wait_for(() -> get_task_status("cancel-task"; store=store)[:status] == "CANCELLED") == :ok

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

        submit_task(ctx_one, "ctx-task", () -> "ctx-one", "user")
        @test wait_for(() -> get_task_status(ctx_one, "ctx-task")[:status] == "COMPLETED") == :ok
        @test get_task_status(ctx_one, "ctx-task")[:result] == "ctx-one"
        @test get_task_status(ctx_two, "ctx-task")[:status] == "NOT_FOUND"
    finally
        uninstall!(ctx_one)
        uninstall!(ctx_two)
        reset_store!(store)
    end
end

end