@testitem "PormG worker store" tags=[:extension, :pormg] setup=[NitroCommon] begin

using Test
using Dates
using JSON
using Nitro
using Nitro.Workers
using Nitro.Errors: AuthorizationError

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
            elseif k == "id__startswith" || k == "id__@startswith"
                matches = startswith(row["id"], v)
            elseif k == "watchers__contains" || k == "watchers__@contains"
                # Substring match on the serialized JSON, like the real backend.
                matches = occursin(v, row["watchers"])
            else
                # Previously an unrecognised key fell through and left `matches` at
                # whatever the last branch set, so a filter the mock did not model
                # silently did not constrain — and any test relying on it passed
                # vacuously. Fail loudly instead.
                error("MockTaskQuerySet: unmodelled filter key '$k' — teach the mock " *
                      "about it, or the query under test is not actually being exercised")
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
    elseif name === :db
        return function(_db_key::String)
            return qs
        end
    elseif name === :list
        return function()
            return _filtered_rows(qs)
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

# A model that fails the next `fail_next[]` reads and then behaves normally.
#
# The failure has to be *transient* to be a meaningful test: `_register_or_watch!`
# reads the row, and then `set_task!` reads it again before writing. A mock that
# failed every read would make the write throw too, so the submit would abort for
# the wrong reason and the test would pass against the unpatched code. Failing
# exactly one read reproduces the real hazard — a connection blip that makes
# `get_task_info` report an existing row as absent, skipping the cross-user gate.
struct FlakyReadQuerySet
    inner::MockTaskQuerySet
    fail_next::Ref{Int}
    fail_ids::Set{String}
end

function _flaky_guard(qs::FlakyReadQuerySet)
    inner = getfield(qs, :inner)
    fail_next = getfield(qs, :fail_next)
    fail_ids = getfield(qs, :fail_ids)

    # Targeted: fail only reads filtered to a specific task id, so a test can
    # break one row's read without disturbing the writes around it.
    id = Base.get(getfield(inner, :filters), "id", nothing)
    if id !== nothing && id in fail_ids
        error("simulated database read failure for '$id'")
    end

    # Counted: fail the next N reads whatever they touch.
    if fail_next[] > 0
        fail_next[] -= 1
        error("simulated transient database read failure")
    end
    return nothing
end

function Base.getproperty(qs::FlakyReadQuerySet, name::Symbol)
    inner = getfield(qs, :inner)
    fail_next = getfield(qs, :fail_next)
    fail_ids = getfield(qs, :fail_ids)

    if name === :db
        return (key::String) -> FlakyReadQuerySet(inner.db(key), fail_next, fail_ids)
    elseif name === :filter
        return (pairs::Pair{String,<:Any}...) -> FlakyReadQuerySet(inner.filter(pairs...), fail_next, fail_ids)
    elseif name === :first
        return function()
            _flaky_guard(qs)
            return inner.first()
        end
    elseif name === :list
        return function()
            _flaky_guard(qs)
            return inner.list()
        end
    end
    return getproperty(inner, name)
end

struct FlakyReadModel
    _table::Dict{String, Dict{String, Any}}
    fail_next::Ref{Int}
    fail_ids::Set{String}
end

FlakyReadModel() = FlakyReadModel(Dict{String, Dict{String, Any}}(), Ref(0), Set{String}())

function Base.getproperty(m::FlakyReadModel, name::Symbol)
    if name === :objects
        return FlakyReadQuerySet(
            MockTaskQuerySet(getfield(m, :_table), Dict{String,Any}()),
            getfield(m, :fail_next),
            getfield(m, :fail_ids),
        )
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
        @test store.db_key == "db"

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
            update_progress!(retrieved, 50.0)
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

            tasks_a = get_all_tasks(store3, Owner("user-a"))
            @test length(tasks_a) == 1
            @test tasks_a[1].id == "task-a"

            tasks_b = get_all_tasks(store3, Owner("user-b"))
            @test length(tasks_b) == 1
            @test tasks_b[1].id == "task-b"

            @test length(get_all_tasks(store3, System())) == 2
        end

        @testset "the narrowed query still returns owned AND granted tasks" begin
            # `_authority_rows` narrows with two SQL filters — an id prefix for owned
            # tasks and a watchers substring for granted ones. Both are supersets on
            # purpose: the Julia predicate afterwards can discard an extra row, but it
            # cannot recover one the query dropped. So the risk being covered here is
            # a row going MISSING, not an extra one slipping through.
            store_narrow = RealPormGWorkerStore(model=MockTaskModel())

            # Owned: reachable only by the id prefix (its watcher entry is wiped).
            owned = TaskInfo("alice::mine")
            set_task!(store_narrow, owned.id, owned)

            # Granted: a :global id, so there is no prefix to match — reachable only
            # through the watchers filter.
            granted = TaskInfo("shared-global")
            push!(granted.watchers, "alice")
            set_task!(store_narrow, granted.id, granted)

            # Someone else's, matching neither filter.
            other = TaskInfo("bob::theirs")
            push!(other.watchers, "bob")
            set_task!(store_narrow, other.id, other)

            ids = Set(t.id for t in get_all_tasks(store_narrow, Owner("alice")))
            @test ids == Set(["alice::mine", "shared-global"])

            # A prefix that is not delimiter-terminated must not match: "ali" is not
            # an owner of "alice::mine", and `owner_of` would never say it was.
            @test isempty(get_all_tasks(store_narrow, Owner("ali")))

            # The watchers filter matches the JSON-quoted id, so a longer name that
            # merely starts with the same characters cannot collide.
            bobby = TaskInfo("global-bobby")
            push!(bobby.watchers, "bobby")
            set_task!(store_narrow, bobby.id, bobby)
            @test isempty(get_all_tasks(store_narrow, Owner("bob")) |>
                          ts -> filter(t -> t.id == "global-bobby", ts))

            @test length(get_all_tasks(store_narrow, System())) == 4
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

            reports = get_all_tasks(store4, System(); status=PENDING, queue_name="reports")
            @test length(reports) == 3
            @test all(t.queue_name == "reports" for t in reports)

            invoices = get_all_tasks(store4, System(); status=PENDING, queue_name="invoices")
            @test length(invoices) == 2
            @test all(t.queue_name == "invoices" for t in invoices)

            @test length(get_all_tasks(store4, System(); status=PENDING)) == 5
        end

        @testset "get_all_tasks overlays live progress for active tasks" begin
            # A RUNNING task only flushes to the DB at start and on completion, so its
            # stored progress is stale. get_all_tasks must overlay the in-memory info
            # so the list endpoint reports the same live progress as get_task_status.
            store5 = RealPormGWorkerStore(model=MockTaskModel())

            info = TaskInfo("task-live"; queue_name="reports")
            info.status = RUNNING
            update_progress!(info, 0.0)
            set_task!(store5, info.id, info)  # DB row stuck at 0.0

            live = TaskInfo("task-live"; queue_name="reports")
            live.status = RUNNING
            update_progress!(live, 73.0)
            register_active_task_info!(store5, live.id, live)

            listed = only(get_all_tasks(store5, System(); status=RUNNING))
            @test listed.progress == 73.0

            # After the task terminates the cache entry is gone and the DB value wins.
            deregister_active_task_info!(store5, live.id)
            @test only(get_all_tasks(store5, System(); status=RUNNING)).progress == 0.0
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

        @testset "watch authorizer round-trips through the store (#19)" begin
            store6 = RealPormGWorkerStore(model=MockTaskModel())

            # Absent by default; the denial that follows from that is exercised
            # end-to-end in the testset below, not here.
            @test get_watch_authorizer(store6) === nothing

            hook = (task_key, watchers, user_id) -> user_id in watchers
            @test set_watch_authorizer!(store6, hook) === hook
            @test get_watch_authorizer(store6) === hook

            # Independent of the queue authorizer slot.
            queue_hook = (queue_name, user_id) -> true
            set_queue_authorizer!(store6, queue_hook)
            @test get_watch_authorizer(store6) === hook
            @test get_queue_authorizer(store6) === queue_hook

            @test set_watch_authorizer!(store6, nothing) === nothing
            @test get_watch_authorizer(store6) === nothing
        end

        @testset "the cross-user gate holds end-to-end on PormGWorkerStore (#19)" begin
            # The accessor test above only proves the hook slot round-trips. This runs
            # the real submit path against the persistent store, which is where the
            # gate actually has to hold.
            store_e2e = RealPormGWorkerStore(model=MockTaskModel())
            release = Base.Event()
            attacker_calls = Ref(0)

            try
                owner_id = submit_task("shared-export", () -> begin
                    wait(release)
                    return "victim-secret"
                end, Owner("victim"); scope=:global, store=store_e2e)
                @test owner_id == "shared-export"

                @test_throws AuthorizationError submit_task("shared-export", () -> begin
                    attacker_calls[] += 1
                    return "attacker-data"
                end, Owner("attacker"); scope=:global, store=store_e2e)

                notify(release)
                @test timedwait(() -> get_task_status(owner_id, Owner("victim"); store=store_e2e)[:status] == "COMPLETED", 5.0) == :ok

                # Terminal state: replacing the row would destroy the owner's result.
                @test_throws AuthorizationError submit_task("shared-export", () -> begin
                    attacker_calls[] += 1
                    return "attacker-data"
                end, Owner("attacker"); scope=:global, store=store_e2e)

                persisted = get_task_status(owner_id, Owner("victim"); store=store_e2e)
                @test persisted[:result] == "victim-secret"
                @test persisted[:watcher_count] == 1
                @test attacker_calls[] == 0

                # user scope keeps the two users on separate rows entirely
                a = submit_task("report", () -> "a", Owner("user-a"); store=store_e2e)
                b = submit_task("report", () -> "b", Owner("user-b"); store=store_e2e)
                @test a == "user-a::report"
                @test b == "user-b::report"
                @test_throws AuthorizationError get_task_status(a, Owner("user-b"); store=store_e2e)
            finally
                notify(release)
                reset_store!(store_e2e)
            end
        end

        @testset "one transient read failure denies the key instead of granting it (#19)" begin
            # Regression: get_task_info used to log a failed read and return `nothing`,
            # which _register_or_watch! reads as "no such task" — so a single connection
            # blip skipped the cross-user gate and let the caller take over the row.
            flaky = FlakyReadModel()
            store_fail = RealPormGWorkerStore(model=flaky)

            victim = TaskInfo("shared-export")
            victim.status = COMPLETED
            victim.result = "victim-secret"
            victim.completed_at = Dates.now(Dates.UTC)
            push!(victim.watchers, "victim")
            set_task!(store_fail, "shared-export", victim)

            # A failed read must surface, not masquerade as an absent row.
            flaky.fail_next[] = 1
            @test_throws ErrorException get_task_info(store_fail, "shared-export")

            # Exactly one read fails: the one _register_or_watch! makes. set_task!'s
            # own probe then succeeds, which is what made this reachable.
            flaky.fail_next[] = 1
            @test_throws ErrorException submit_task(
                "shared-export", () -> "attacker-data", Owner("attacker"); scope=:global, store=store_fail)

            # The victim's row survived intact and is still theirs.
            flaky.fail_next[] = 0
            persisted = get_task_status("shared-export", Owner("victim"); store=store_fail)
            @test persisted[:result] == "victim-secret"
            @test persisted[:watcher_count] == 1
            @test_throws AuthorizationError get_task_status("shared-export", Owner("attacker"); store=store_fail)
        end

        @testset "a failed read of one queued item does not kill the processor (#19)" begin
            # Regression on the rethrow above: _execute_queued_task reads task
            # metadata BEFORE registering the active-info cache entry, so that read
            # hits the DB. An escaping exception unwound the processor's `while true`
            # loop, leaving the queue undrained and every item behind it stranded.
            flaky = FlakyReadModel()
            store_q = RealPormGWorkerStore(model=flaky)
            gate = Base.Event()

            # One callback shared by all three submits, defined before the processor
            # is spawned. `_invoke_task_callback` gates on `applicable`, which is
            # world-age sensitive, so a closure first defined after the processor
            # task started is invisible to it — unrelated to what this test asserts.
            run_step = task_info -> begin
                endswith(task_info.id, "k1") && wait(gate)
                return "ran-" * task_info.id
            end

            try
                first_id = submit_sequential_task("qfail", "k1", run_step, Owner("u"); store=store_q)
                second_id = submit_sequential_task("qfail", "k2", run_step, Owner("u"); store=store_q)
                @test first_id == "u::k1"
                @test second_id == "u::k2"

                # Break only k2's read, then let k1 finish so the processor picks k2 up.
                push!(flaky.fail_ids, second_id)
                notify(gate)

                @test timedwait(() -> get_task_status(first_id, Owner("u"); store=store_q)[:status] == "COMPLETED", 5.0) == :ok

                # k2 is dropped, but the processor must still be alive and draining.
                queue = get_sequential_queues(store_q)["qfail"]
                @test queue.processor_task !== nothing
                @test !istaskdone(queue.processor_task)

                delete!(flaky.fail_ids, second_id)
                third_id = submit_sequential_task("qfail", "k3", run_step, Owner("u"); store=store_q)
                @test timedwait(() -> get_task_status(third_id, Owner("u"); store=store_q)[:status] == "COMPLETED", 5.0) == :ok
                @test get_task_status(third_id, Owner("u"); store=store_q)[:result] == "ran-u::k3"
            finally
                notify(gate)
                reset_store!(store_q)
            end
        end

        @testset "user-scoped ids round-trip through the DB record (#19)" begin
            # Scoped ids embed the owner and contain the delimiter; both halves must
            # survive serialization unchanged. (The VARCHAR(100)->(255) widening is not
            # covered here: MockTaskModel is a bare Dict and enforces no column length.)
            store7 = RealPormGWorkerStore(model=MockTaskModel())

            scoped = scoped_task_key("export_report_42", Owner("user-a"))
            @test scoped == "user-a::export_report_42"

            info = TaskInfo(scoped; queue_name="reports")
            push!(info.watchers, "user-a")
            set_task!(store7, scoped, info)

            retrieved = get_task_info(store7, scoped)
            @test retrieved !== nothing
            @test retrieved.id == scoped
            @test retrieved.watchers == ["user-a"]

            # The other user's same-key task is a distinct row.
            other = scoped_task_key("export_report_42", Owner("user-b"))
            other_info = TaskInfo(other; queue_name="reports")
            push!(other_info.watchers, "user-b")
            set_task!(store7, other, other_info)

            @test length(get_all_tasks(store7, System())) == 2
            @test only(get_all_tasks(store7, Owner("user-a"))).id == scoped
            @test only(get_all_tasks(store7, Owner("user-b"))).id == other
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
