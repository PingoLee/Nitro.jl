@testitem "PormG worker store" tags=[:extension, :pormg] setup=[NitroCommon] begin

using Test
using Dates
using JSON
using Nitro
using Nitro.Workers

# These tests exercise the real NitroPormGExt.PormGWorkerStore when PormG is
# available in the active test environment. The mock model below replaces only
# the database layer; store methods come from ext/NitroPormGExt.jl.

mutable struct MockTaskQuerySet
    table::Dict{String, Dict{String, Any}}
    filters::Dict{String, Any}
end

function _filtered_rows(qs::MockTaskQuerySet)
    table = getfield(qs, :table)
    filters = getfield(qs, :filters)
    rows = Dict{String, Any}[]

    for row in values(table)
        matches = true
        for (k, v) in filters
            if k == "id"
                matches = row["id"] == v
            elseif k == "status"
                matches = row["status"] == v
            elseif k == "status__@in"
                matches = row["status"] in v
            elseif k == "queue_name"
                matches = row["queue_name"] == v
            elseif k == "completed_at__lte" || k == "completed_at__@lte"
                matches = row["completed_at"] !== nothing && row["completed_at"] <= v
            elseif k == "completed_at__gt" || k == "completed_at__@gt"
                matches = row["completed_at"] !== nothing && row["completed_at"] > v
            elseif k == "completed_at__@isnull"
                matches = (row["completed_at"] === nothing) == v
            end
            matches || break
        end
        matches && push!(rows, row)
    end

    return rows
end

function Base.getproperty(qs::MockTaskQuerySet, name::Symbol)
    if name === :filter
        return function(pairs::Pair{String,<:Any}...)
            new_filters = copy(getfield(qs, :filters))
            for (k, v) in pairs
                new_filters[k] = v
            end
            return MockTaskQuerySet(getfield(qs, :table), new_filters)
        end
    elseif name === :first
        return function()
            rows = _filtered_rows(qs)
            return isempty(rows) ? nothing : first(rows)
        end
    elseif name === :create
        return function(pairs::Pair{String,<:Any}...)
            row = Dict{String,Any}()
            for (k, v) in pairs
                row[k] = v
            end
            getfield(qs, :table)[row["id"]] = row
            return row
        end
    elseif name === :update
        return function(pairs::Pair{String,<:Any}...)
            for row in _filtered_rows(qs)
                for (k, v) in pairs
                    row[k] = v
                end
            end
            return nothing
        end
    elseif name === :delete
        return function()
            table = getfield(qs, :table)
            count = 0
            for row in _filtered_rows(qs)
                delete!(table, row["id"])
                count += 1
            end
            return count, Dict{String, Integer}("nitro_task" => count)
        end
    else
        return getfield(qs, name)
    end
end

Base.iterate(qs::MockTaskQuerySet) = iterate(_filtered_rows(qs))
Base.iterate(qs::MockTaskQuerySet, state) = iterate(_filtered_rows(qs), state)

struct MockTaskModel
    _table::Dict{String, Dict{String, Any}}
end

MockTaskModel() = MockTaskModel(Dict{String, Dict{String, Any}}())

function Base.getproperty(m::MockTaskModel, name::Symbol)
    if name === :objects
        return MockTaskQuerySet(getfield(m, :_table), Dict{String,Any}())
    end
    return getfield(m, name)
end

function _load_pormg_worker_store_type()
    try
        @eval using PormG
    catch
        return nothing
    end

    ext = Base.get_extension(Nitro, :NitroPormGExt)
    return isnothing(ext) ? nothing : getproperty(ext, :PormGWorkerStore)
end

const RealPormGWorkerStore = _load_pormg_worker_store_type()

if RealPormGWorkerStore === nothing
    @test_skip "PormG is not available, so NitroPormGExt.PormGWorkerStore cannot be loaded"
else
    @testset "PormGWorkerStore interface and persistence" begin
        store = RealPormGWorkerStore(model=MockTaskModel())

        @test store isa AbstractWorkerStore

        @testset "create and read task" begin
            info = TaskInfo("task-1"; queue_name="reports")
            push!(info.watchers, "user-x")
            set_task!(store, "task-1", info)

            @test store.model._table["task-1"]["started_at"] === nothing
            @test store.model._table["task-1"]["completed_at"] === nothing

            retrieved = get_task_info(store, "task-1")
            @test retrieved !== nothing
            @test retrieved.id == "task-1"
            @test retrieved.status == PENDING
            @test retrieved.queue_name == "reports"
            @test "user-x" in retrieved.watchers
            @test retrieved.started_at === nothing
            @test retrieved.completed_at === nothing
        end

        @testset "update task progress" begin
            retrieved = get_task_info(store, "task-1")
            retrieved.status = RUNNING
            retrieved.progress = 50.0
            retrieved.started_at = Dates.now(Dates.UTC)
            set_task!(store, "task-1", retrieved)

            updated = get_task_info(store, "task-1")
            @test updated.status == RUNNING
            @test updated.progress == 50.0
            @test updated.started_at isa DateTime
        end

        @testset "active task handle cache is decoupled" begin
            mock_task = @async sleep(0.01)
            register_active_task!(store, "task-1", mock_task)

            @test get_active_task(store, "task-1") === mock_task
            @test !haskey(store.model._table["task-1"], "sys_task")

            deregister_active_task!(store, "task-1")
            @test get_active_task(store, "task-1") === nothing
            wait(mock_task)
        end

        @testset "cleanup deletes only completed tasks older than retain days" begin
            store2 = RealPormGWorkerStore(model=MockTaskModel())

            info1 = TaskInfo("task-active")
            info1.status = RUNNING
            set_task!(store2, "task-active", info1)

            info2 = TaskInfo("task-recent")
            info2.status = COMPLETED
            info2.completed_at = Dates.now(Dates.UTC) - Dates.Day(2)
            set_task!(store2, "task-recent", info2)

            info3 = TaskInfo("task-expired")
            info3.status = COMPLETED
            info3.completed_at = Dates.now(Dates.UTC) - Dates.Day(10)
            set_task!(store2, "task-expired", info3)

            @test cleanup_tasks!(store2, 7) == 1

            @test get_task_info(store2, "task-active") !== nothing
            @test get_task_info(store2, "task-recent") !== nothing
            @test get_task_info(store2, "task-expired") === nothing
            @test cleanup_tasks!(store2, 7) == 0
        end

        @testset "get_all_tasks lists with user watchers constraint" begin
            store3 = RealPormGWorkerStore(model=MockTaskModel())

            info_a = TaskInfo("task-a")
            push!(info_a.watchers, "user-a")
            set_task!(store3, "task-a", info_a)

            info_b = TaskInfo("task-b")
            push!(info_b.watchers, "user-b")
            set_task!(store3, "task-b", info_b)

            tasks_a = get_all_tasks(store3, nothing, "user-a")
            @test length(tasks_a) == 1
            @test tasks_a[1].id == "task-a"

            tasks_b = get_all_tasks(store3, nothing, "user-b")
            @test length(tasks_b) == 1
            @test tasks_b[1].id == "task-b"

            @test length(get_all_tasks(store3)) == 2
        end

        @testset "get_all_tasks filters by queue_name in the DB query" begin
            # Regression: get_queue_status used to fetch ALL pending tasks and filter
            # in Julia, causing an O(total_pending) scan. Now the queue_name is pushed
            # to the query so only the relevant rows are returned.
            store4 = RealPormGWorkerStore(model=MockTaskModel())

            for i in 1:3
                t = TaskInfo("reports-$(i)"; queue_name="reports")
                t.status = PENDING
                set_task!(store4, t.id, t)
            end
            for i in 1:2
                t = TaskInfo("invoices-$(i)"; queue_name="invoices")
                t.status = PENDING
                set_task!(store4, t.id, t)
            end

            reports = get_all_tasks(store4, PENDING, nothing, "reports")
            @test length(reports) == 3
            @test all(t.queue_name == "reports" for t in reports)

            invoices = get_all_tasks(store4, PENDING, nothing, "invoices")
            @test length(invoices) == 2
            @test all(t.queue_name == "invoices" for t in invoices)

            @test length(get_all_tasks(store4, PENDING)) == 5
        end

        @testset "_from_db_record raises on unknown status string" begin
            # Regression: previously an unrecognised status string would silently leave
            # task.status at its constructor default (PENDING), masking schema drift.
            ext = Base.get_extension(Nitro, :NitroPormGExt)
            from_db = getproperty(ext, :_from_db_record)

            good_row = Dict{String,Any}(
                "id" => "t1", "status" => "COMPLETED", "progress" => 100.0,
                "result" => "", "error" => "", "created_at" => Dates.now(Dates.UTC),
                "started_at" => nothing, "completed_at" => nothing,
                "watchers" => "[]", "queue_name" => "",
            )
            @test from_db(good_row).status == COMPLETED

            bad_row = merge(good_row, Dict{String,Any}("id" => "t2", "status" => "RETRYING"))
            @test_throws ErrorException from_db(bad_row)
        end

        @testset "lock_tasks provides mutual exclusion for PormGWorkerStore" begin
            # Regression: lock_tasks was a no-op for PormGWorkerStore, leaving
            # _register_or_watch! and cancel_task unprotected against concurrent writers.
            store5 = RealPormGWorkerStore(model=MockTaskModel())

            counter = Ref(0)
            n = 20
            tasks = map(1:n) do _
                Threads.@spawn lock_tasks(store5) do
                    v = counter[]
                    sleep(0.001)
                    counter[] = v + 1
                end
            end
            foreach(wait, tasks)

            @test counter[] == n
        end
    end
end

end
