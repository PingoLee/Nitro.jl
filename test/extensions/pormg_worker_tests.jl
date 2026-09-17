@testitem "PormG worker store" tags=[:extension, :pormg, :workers] setup=[NitroCommon] begin

using Test
using Dates
using JSON
using UUIDs
using Nitro
using Nitro.Workers
using Nitro.Errors: AuthorizationError

# These tests exercise the real NitroPormGExt.PormGWorkerStore when PormG is
# available in the active test environment. The mock model below replaces only
# the database layer; store methods come from ext/NitroPormGExt.jl.

mutable struct MockTaskQuerySet
    # One table PER CONNECTION, not one table. A single-table mock cannot express #203 at
    # all: "created the table on `tasks`, then read and wrote every row on `db`" is not a
    # statement about anything unless there are two tables to tell apart, so no assertion
    # written against such a mock could have failed on code that dropped `.db(db_key)`.
    tables::Dict{String, Dict{String, Dict{String, Any}}}   # db key -> task id -> row
    db_key::Union{Nothing, String}                          # `nothing` until `.db(key)` runs
    filters::Dict{String, Any}
end

# The one place a connection is resolved. Every terminal op goes through here, so a query
# that never called `.db(key)` fails loudly instead of silently reading the default table.
function _selected_table(qs::MockTaskQuerySet)
    key = getfield(qs, :db_key)
    key === nothing && error("MockTaskQuerySet: query ran without selecting a connection -- " *
        "every task query must go through `_task_objects(store)` (`.db(store.db_key)`), " *
        "not `m.objects` directly. See #203.")
    tables = getfield(qs, :tables)
    haskey(tables, key) || error("MockTaskQuerySet: no table registered for db key '$key' -- " *
        "PormG throws `InvalidConfigurationError` for a key that was never loaded. Build the " *
        "model as `MockTaskModel(\"$key\")` if the test means to use that connection.")
    return tables[key]
end

function _filtered_rows(qs::MockTaskQuerySet)
    table = _selected_table(qs)
    filters = getfield(qs, :filters)
    rows = Dict{String, Any}[]

    for row in values(table)
        matches = true
        for (k, v) in filters
            if k == "id"
                matches = row["id"] == v
            elseif k == "run_id"
                # The run half of try_transition!'s compare — see #108. Without this branch
                # the mock would `error` on every fenced transition.
                matches = row["run_id"] == v
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
            elseif k == "watchers"
                # Exact match on the serialized document — the compare half of
                # add_watcher!'s CAS. Without this branch the filter fell through and
                # matched on `id` alone, so the CAS always appeared to win.
                matches = row["watchers"] == v
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
            # ACCUMULATE onto this object and return it, exactly as PormG's `_filter!`
            # does (`push!(q.filter, …)`; see its "Calls ACCUMULATE (ANDed)" note).
            #
            # This used to return a fresh queryset with a copied filter dict, which made
            # `base.filter(A)` and `base.filter(B)` independent. Against real PormG they
            # are not: the second call ANDs onto the first. A mock that branches where the
            # real thing accumulates turns an intersection bug into a passing test.
            filters = getfield(qs, :filters)
            for (k, v) in pairs
                filters[k] = v
            end
            return qs
        end
    elseif name === :db
        return function(db_key::String)
            # PormG's `_db!` assigns `q.connect_key` and returns the SAME object -- the
            # mutate-and-return-self shape `filter` above uses, not a fresh queryset.
            #
            # This used to be `(_db_key) -> qs`: the key was accepted and thrown away, so
            # `_task_objects(store)` was indistinguishable from `store.model.objects` and
            # deleting `.db(store.db_key)` from the ext kept this whole file green (#203).
            setfield!(qs, :db_key, db_key)
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
            _selected_table(qs)[row["id"]] = row
            return row
        end
    elseif name === :update
        return function(pairs::Pair{String,<:Any}...)
            # Return the affected-row count, matching PormG's Django-style `update`.
            # It used to return `nothing`, which would make every compare-and-set in
            # the store read as a failure — or, worse, as an untested success.
            touched = 0
            for row in _filtered_rows(qs)
                for (k, v) in pairs
                    row[k] = v
                end
                touched += 1
            end
            return touched
        end
    elseif name === :delete
        return function()
            table = _selected_table(qs)
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
    _tables::Dict{String, Dict{String, Dict{String, Any}}}
end

# Every connection this model may be queried on. A test that exercises routing names both
# (`MockTaskModel("db", "tasks")`); the no-argument form is the single connection every test
# that does not care about routing uses.
MockTaskModel(db_keys::String...) = MockTaskModel(
    Dict{String, Dict{String, Dict{String, Any}}}(
        k => Dict{String, Dict{String, Any}}() for k in (isempty(db_keys) ? ("db",) : db_keys)))

function Base.getproperty(m::MockTaskModel, name::Symbol)
    if name === :objects
        # No connection selected yet -- exactly what PormG's `model.objects` hands back.
        # `.db(key)` is what picks one.
        return MockTaskQuerySet(getfield(m, :_tables), nothing, Dict{String,Any}())
    elseif name === :_table
        # The DEFAULT connection's table: what every assertion that does not care about
        # routing means, kept as an alias rather than rewritten at ~30 call sites.
        return getfield(m, :_tables)["db"]
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
    _tables::Dict{String, Dict{String, Dict{String, Any}}}
    fail_next::Ref{Int}
    fail_ids::Set{String}
end

FlakyReadModel(db_keys::String...) = FlakyReadModel(
    Dict{String, Dict{String, Dict{String, Any}}}(
        k => Dict{String, Dict{String, Any}}() for k in (isempty(db_keys) ? ("db",) : db_keys)),
    Ref(0), Set{String}())

function Base.getproperty(m::FlakyReadModel, name::Symbol)
    if name === :objects
        return FlakyReadQuerySet(
            MockTaskQuerySet(getfield(m, :_tables), nothing, Dict{String,Any}()),
            getfield(m, :fail_next),
            getfield(m, :fail_ids),
        )
    elseif name === :_table
        return getfield(m, :_tables)["db"]
    end
    return getfield(m, name)
end

# A model that simulates another process appending a watcher in the window between our
# read and our UPDATE.
#
# Deterministic on purpose. A thread-based race would be the obvious way to test this and
# the wrong one: it passes or fails on scheduler luck, behaves differently at
# `nthreads` 1 and 2 (CI runs both), and cannot prove the retry path ran at all. Injecting
# the competing write exactly once, at exactly the vulnerable moment, forces the CAS to
# match zero rows and take its retry — the whole point of #88's fix.
struct RacingWatcherQuerySet
    inner::MockTaskQuerySet
    inject_next::Ref{Int}
    intruder::String
end

function Base.getproperty(qs::RacingWatcherQuerySet, name::Symbol)
    inner = getfield(qs, :inner)
    inject_next = getfield(qs, :inject_next)
    intruder = getfield(qs, :intruder)

    if name === :db
        return (key::String) -> RacingWatcherQuerySet(inner.db(key), inject_next, intruder)
    elseif name === :filter
        return (pairs::Pair{String,<:Any}...) ->
            RacingWatcherQuerySet(inner.filter(pairs...), inject_next, intruder)
    elseif name === :update
        return function(pairs::Pair{String,<:Any}...)
            # Only a watchers CAS is worth racing, and only once.
            is_watcher_cas = any(p -> first(p) == "watchers", pairs) &&
                             haskey(getfield(inner, :filters), "watchers")
            if is_watcher_cas && inject_next[] > 0
                inject_next[] -= 1
                # The competing write lands first, so our compare value is now stale.
                # `_selected_table`, not the raw tables dict: the intruder must land on the
                # SAME connection the store is querying, or the CAS would never see it.
                for row in values(_selected_table(inner))
                    current = JSON.parse(row["watchers"])
                    intruder in current && continue
                    row["watchers"] = JSON.json(vcat(current, intruder))
                end
            end
            return inner.update(pairs...)
        end
    end
    return getproperty(inner, name)
end

struct RacingWatcherModel
    _tables::Dict{String, Dict{String, Dict{String, Any}}}
    inject_next::Ref{Int}
    intruder::String
end

RacingWatcherModel(table::Dict{String, Dict{String, Any}}, inject_next::Ref{Int}, intruder::String) =
    RacingWatcherModel(
        Dict{String, Dict{String, Dict{String, Any}}}("db" => table), inject_next, intruder)

function Base.getproperty(m::RacingWatcherModel, name::Symbol)
    if name === :objects
        return RacingWatcherQuerySet(
            MockTaskQuerySet(getfield(m, :_tables), nothing, Dict{String,Any}()),
            getfield(m, :inject_next),
            getfield(m, :intruder),
        )
    elseif name === :_table
        return getfield(m, :_tables)["db"]
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

# FAIL, do not skip (#128). This branch used to be
# `@test_skip "PormG is not available, ..."`, which the Test stdlib reports as
# `Broken 1` -- one line in a 3,500-assertion summary, with the run still exiting 0.
# Everything below this point (~112 assertions across 24 testsets, the only coverage
# the SHIPPED `ext/NitroPormGExt.jl` store ever gets) silently did not run.
#
# `PormG` is a declared `[targets].test` dependency, so it is present under every
# supported way of invoking this suite. Its absence is an environment bug, not a
# configuration this file should accommodate -- see the bootstrap guard in
# `test/runtests.jl`, which refuses the run before any item starts. This assertion is
# the defence in depth behind it, for a REPL or a direct `ReTestItems.runtests` call
# that never goes through the coordinator.
if RealPormGWorkerStore === nothing
    error("PormG is not available, so NitroPormGExt.PormGWorkerStore cannot be loaded. " *
          "PormG is a declared `[targets].test` dependency: this is a broken test " *
          "environment, not a valid configuration, and failing here is deliberate (#128). " *
          "Run `bash scripts/worktree_setup.sh` in a worktree, unset a stale " *
          "`NITRO_TEST_REDISPATCH`, or re-provision with `Pkg.test()`.")
else
    @testset "PormGWorkerStore interface and persistence" begin
        store = RealPormGWorkerStore(model=MockTaskModel())
        rt_store = WorkerRuntime(store)

        @test store isa AbstractWorkerStore
        @test store.db_key == "db"

        # The shipped persistent backend satisfies the whole contract. This is the check a
        # third-party store (#9's Redis backend, say) runs in its own suite, and it is the only
        # thing standing between "PormG forgot a method" and an opaque `MethodError` raised while
        # serving a live task -- which is exactly how the missing `shutdown!` went unnoticed.
        @test isempty(missing_store_methods(RealPormGWorkerStore))

        # The session half of the same contract used to be checked here, because this was the
        # only file that loaded the extension -- `pormg_session_tests.jl` exercised a local
        # replica rather than the shipped type. Since #180 it drives the shipped
        # `PormGSessionStore` and owns that assertion.

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

        @testset "active task handle cache belongs to the runtime, not the store (#167)" begin
            # It used to be a `PormGWorkerStore` field with no `InMemoryWorkerStore` counterpart,
            # which is how #166 came to treat the two backends' live-object handling as
            # equivalent when it was not. The store must now contribute no method at all.
            for gone in (get_active_task, get_active_task_info,
                         Nitro.Workers.register_active_task!,
                         Nitro.Workers.deregister_active_task!,
                         Nitro.Workers.register_active_task_info!,
                         Nitro.Workers.deregister_active_task_info!)
                @test !hasmethod(gone, Tuple{RealPormGWorkerStore, String})
            end
            @test !hasmethod(shutdown!, Tuple{RealPormGWorkerStore})

            mock_task = @async sleep(0.01)
            Nitro.Workers.register_active_task!(rt_store, "task-1", mock_task)

            @test get_active_task(rt_store, "task-1") === mock_task
            # A live `Task` can never reach the row, because no field on this store holds one.
            @test !haskey(store.model._table["task-1"], "sys_task")

            Nitro.Workers.deregister_active_task!(rt_store, "task-1")
            @test get_active_task(rt_store, "task-1") === nothing
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

        @testset "watcher and status writes survive a concurrent writer (#88)" begin
            store_cas = RealPormGWorkerStore(model=MockTaskModel())

            base = TaskInfo("alice::job")
            push!(base.watchers, "alice")
            replace_task!(store_cas, base.id, base)

            @testset "set_task! does not carry a stale watcher list" begin
                add_watcher!(store_cas, "alice::job", "bob")

                # The #88 mechanism, exactly: another process appended "bob" since this
                # one last read the row, and now this one saves a state transition. It
                # used to rewrite every column, dropping "bob". A transition happens on
                # every start/progress/finish, so this was the dominant loss path —
                # far more frequent than two appends racing each other.
                stale = TaskInfo("alice::job")
                push!(stale.watchers, "alice")
                stale.status = COMPLETED
                set_task!(store_cas, "alice::job", stale)

                persisted = get_task_info(store_cas, "alice::job")
                @test persisted.status == COMPLETED       # the state DID land
                @test "bob" in persisted.watchers         # ...and the grant survived it
            end

            @testset "replace_task! is the one call that may reset watchers" begin
                fresh = TaskInfo("alice::job")
                push!(fresh.watchers, "carol")
                replace_task!(store_cas, "alice::job", fresh)
                @test get_task_info(store_cas, "alice::job").watchers == ["carol"]
            end

            @testset "add_watcher! retries rather than clobbering a racing append" begin
                # Deterministic rather than threaded: a racing mock injects a competing
                # watcher between our read and our UPDATE, so the CAS predicate matches
                # zero rows and the retry loop is forced. This behaves identically at
                # nthreads 1 and 2, unlike a spawn-based race.
                table = Dict{String, Dict{String, Any}}()
                racer = RacingWatcherModel(table, Ref(1), "intruder")
                store_race = RealPormGWorkerStore(model=racer)

                t = TaskInfo("alice::raced")
                push!(t.watchers, "alice")
                replace_task!(store_race, t.id, t)

                @test add_watcher!(store_race, "alice::raced", "bob") == true

                got = get_task_info(store_race, "alice::raced").watchers
                # Both survive: the retry re-read the value the racer left behind and
                # appended to *that*, instead of overwriting an append it never saw.
                @test "intruder" in got
                @test "bob" in got
                @test "alice" in got
            end

            @testset "try_transition! fires only from the expected status" begin
                store_t = RealPormGWorkerStore(model=MockTaskModel())
                rt_store_t = WorkerRuntime(store_t)
                t = TaskInfo("alice::cas")
                replace_task!(store_t, t.id, t)

                @test try_transition!(store_t, "alice::cas", (PENDING, RUNNING), CANCELLED;
                                      run_id=t.run_id, error="Cancelled") == true
                @test get_task_info(store_t, "alice::cas").status == CANCELLED
                # A task that finished elsewhere cannot be re-transitioned, and the
                # failed attempt writes nothing.
                @test try_transition!(store_t, "alice::cas", (PENDING, RUNNING), COMPLETED;
                                      run_id=nothing) == false
                @test get_task_info(store_t, "alice::cas").status == CANCELLED
                @test try_transition!(store_t, "absent", (PENDING,), CANCELLED;
                                      run_id=nothing) == false
            end
        end

        @testset "a stale run's terminal write cannot land on its successor (#108)" begin
            # Store parity for the probe in `test/workers_tests.jl`. The fence lives in a WHERE
            # clause here rather than in a Julia comparison, so it has to be exercised against
            # the query builder -- a backend that dropped the term would pass every in-memory
            # test in the suite and still reintroduce #108 for its own users.
            store_r = RealPormGWorkerStore(model=MockTaskModel())
            rt_store_r = WorkerRuntime(store_r)

            a = TaskInfo("alice::report")
            a.status = RUNNING
            replace_task!(store_r, a.id, a)

            b = TaskInfo("alice::report")
            replace_task!(store_r, b.id, b)
            @test b.run_id != a.run_id

            @test try_transition!(store_r, a.id, (PENDING, RUNNING), COMPLETED;
                                  run_id=a.run_id, result="stale") == false
            persisted = get_task_info(store_r, a.id)
            @test persisted.status == PENDING
            @test persisted.result === nothing
            @test persisted.run_id == b.run_id

            @test try_transition!(store_r, b.id, (PENDING, RUNNING), COMPLETED;
                                  run_id=b.run_id, result="fresh") == true
            @test get_task_info(store_r, b.id).result == "fresh"
        end

        @testset "replace_task! publishes a new run id; set_task! leaves it alone (#108)" begin
            store_s = RealPormGWorkerStore(model=MockTaskModel())
            rt_store_s = WorkerRuntime(store_s)

            original = TaskInfo("alice::split")
            replace_task!(store_s, original.id, original)

            stale = TaskInfo("alice::split")
            stale.status = RUNNING
            set_task!(store_s, stale.id, stale)

            stored = get_task_info(store_s, "alice::split")
            @test stored.run_id == original.run_id
            @test stored.status == RUNNING

            replace_task!(store_s, stale.id, stale)
            @test get_task_info(store_s, "alice::split").run_id == stale.run_id
        end

        @testset "cancel_task mirrors the claim onto the live record (#127 follow-up)" begin
            # The discriminating test for this, and it only discriminates HERE. The in-memory
            # store's CAS mutates the very object its registry holds, so an in-memory version
            # of this passes whether or not the mirror exists. `PormGWorkerStore` writes the
            # ROW while `get_task_info` prefers the live `active_task_infos` object -- so once
            # `cancel_task` stopped deregistering that object (#127), a cancelled task kept
            # reporting RUNNING here until its callback returned.
            store_m = RealPormGWorkerStore(model=MockTaskModel())
            rt_store_m = WorkerRuntime(store_m)

            live = TaskInfo("alice::job")
            push!(live.watchers, "alice")
            live.status = RUNNING
            replace_task!(store_m, live.id, live)
            Nitro.Workers.register_active_task_info!(rt_store_m, live.id, live)

            @test cancel_task("alice::job", Owner("alice"); runtime=rt_store_m)[:status] ==
                  "Task cancelled"

            # The live object -- still registered, because the callback has not returned.
            @test get_active_task_info(rt_store_m, "alice::job") === live
            @test live.status == CANCELLED
            @test cancel_requested(live)

            # ...so every read path agrees with the row instead of contradicting it.
            @test get_task_info(store_m, "alice::job").status == CANCELLED
            @test get_task_info(store_m, "alice::job").status == CANCELLED
            @test get_task_status("alice::job", Owner("alice"); runtime=rt_store_m)[:status] ==
                  "CANCELLED"

            # And the consequence that made it more than cosmetic: a stale RUNNING record
            # made `_register_or_watch!` treat a re-submit as a join, silently never re-running.
            @test haskey(cancel_task("alice::job", Owner("alice"); runtime=rt_store_m), :error)
        end

        @testset "a completing task cannot overwrite a cancellation from elsewhere (#88)" begin
            store_x = RealPormGWorkerStore(model=MockTaskModel())
            rt_store_x = WorkerRuntime(store_x)

            live = TaskInfo("alice::job")
            push!(live.watchers, "alice")
            live.status = RUNNING
            replace_task!(store_x, live.id, live)
            # This process is running the task, so `get_task_info` serves THIS object.
            Nitro.Workers.register_active_task_info!(rt_store_x, live.id, live)

            # Another process cancels: it writes the row and never touches our live object.
            @test try_transition!(store_x, "alice::job", (PENDING, RUNNING), CANCELLED;
                                  run_id=live.run_id, error="Cancelled") == true

            # Our callback now returns normally. The old guard read `get_task_info`, which
            # handed back our own live object still saying RUNNING, so the cancellation was
            # invisible and the completion overwrote it: the canceller was told "cancelled"
            # while the row said COMPLETED and served the result.
            Nitro.Workers._complete_task!(rt_store_x, live, "the-result")

            persisted = get_task_info(store_x, "alice::job")
            @test persisted.status == CANCELLED
            @test persisted.result != "the-result"
        end

        @testset "a failing task cannot overwrite a cancellation from elsewhere (#88)" begin
            store_f = RealPormGWorkerStore(model=MockTaskModel())
            rt_store_f = WorkerRuntime(store_f)

            live = TaskInfo("alice::flaky")
            push!(live.watchers, "alice")
            live.status = RUNNING
            replace_task!(store_f, live.id, live)
            Nitro.Workers.register_active_task_info!(rt_store_f, live.id, live)

            try_transition!(store_f, "alice::flaky", (PENDING, RUNNING), CANCELLED;
                            run_id=live.run_id, error="Cancelled")
            # `_fail_task!` had no cancellation guard at all, not even the ineffective one.
            Nitro.Workers._fail_task!(rt_store_f, live, "boom")

            persisted = get_task_info(store_f, "alice::flaky")
            @test persisted.status == CANCELLED
            @test persisted.error == "Cancelled"
        end

        @testset "zombie recovery cannot clobber a result claimed elsewhere (#88)" begin
            store_z = RealPormGWorkerStore(model=MockTaskModel())
            rt_store_z = WorkerRuntime(store_z)

            t = TaskInfo("alice::job")
            push!(t.watchers, "alice")
            t.status = RUNNING
            replace_task!(store_z, t.id, t)

            # `get_active_task` is process-local, so this node sees another node's
            # genuinely-running task as a zombie. Meanwhile that node finishes it.
            @test try_transition!(store_z, "alice::job", (PENDING, RUNNING), COMPLETED;
                                  run_id=t.run_id,
                                  result="real-result", progress=100.0) == true

            # The sweep now claims rather than saves a stale decision, so it writes
            # nothing: it used to overwrite both the status AND the result column.
            @test recover_zombie_tasks!(; runtime=rt_store_z) == 0
            persisted = get_task_info(store_z, "alice::job")
            @test persisted.status == COMPLETED
            @test persisted.result == "real-result"
        end

        @testset "a cross-process grantee still sees live progress (#96)" begin
            store_p = RealPormGWorkerStore(model=MockTaskModel())
            rt_store_p = WorkerRuntime(store_p)

            live = TaskInfo("alice::upload")
            push!(live.watchers, "alice")
            live.status = RUNNING
            replace_task!(store_p, live.id, live)
            Nitro.Workers.register_active_task_info!(rt_store_p, live.id, live)

            add_watcher!(store_p, "alice::upload", "backend-service")
            empty!(live.watchers)
            push!(live.watchers, "alice")        # force the live copy stale again
            update_progress!(live, 73)           # ...and let it run on

            # The grantee is authorized by the durable row, but must be *served* the live
            # record — otherwise the backend driving the progress bar, which is the whole
            # motivating case, reads a bar frozen at whatever was last flushed.
            granted = get_task_status("alice::upload", Owner("backend-service"); runtime=rt_store_p)
            @test granted[:progress] == 73.0
            @test granted[:progress] == get_task_status("alice::upload", Owner("alice"); runtime=rt_store_p)[:progress]
        end

        @testset "a failed task keeps the progress it reached (#88)" begin
            store_pr = RealPormGWorkerStore(model=MockTaskModel())
            rt_store_pr = WorkerRuntime(store_pr)

            t = TaskInfo("alice::flaky")
            push!(t.watchers, "alice")
            t.status = RUNNING
            replace_task!(store_pr, t.id, t)
            Nitro.Workers.register_active_task_info!(rt_store_pr, t.id, t)
            update_progress!(t, 47)

            Nitro.Workers._fail_task!(rt_store_pr, t, "boom")

            # A serializing store writes only the columns it is given, so omitting
            # progress would reset "got to 47% then died" to zero here while the
            # in-memory store kept it.
            @test get_task_info(store_pr, "alice::flaky").progress == 47.0
        end

        @testset "a grant made elsewhere is honoured despite a stale live record (#96)" begin
            store_s = RealPormGWorkerStore(model=MockTaskModel())
            rt_store_s = WorkerRuntime(store_s)

            live = TaskInfo("alice::upload")
            push!(live.watchers, "alice")
            live.status = RUNNING
            replace_task!(store_s, live.id, live)
            Nitro.Workers.register_active_task_info!(rt_store_s, live.id, live)

            # Another process grants access. It writes the row; our live object, which
            # `get_task_info` serves, knows nothing about it. This is #96's own motivating
            # deployment: submitted on one node, polled from another.
            @test add_watcher!(store_s, "alice::upload", "backend-service") == true
            empty!(live.watchers)
            push!(live.watchers, "alice")          # force the live copy stale

            # Listing reads the row and admits the grantee...
            @test only(get_all_tasks(store_s, Owner("backend-service"))).id == "alice::upload"
            # ...and so must the point reads, or the grant works or not by which node answered.
            @test get_task_status("alice::upload", Owner("backend-service"); runtime=rt_store_s)[:id] == "alice::upload"
            # A genuine stranger is still refused after the durable re-check.
            @test_throws AuthorizationError get_task_status("alice::upload", Owner("stranger"); runtime=rt_store_s)
        end

        @testset "watchers= grants persist through the store (#96)" begin
            store_grant = RealPormGWorkerStore(model=MockTaskModel())
            rt_store_grant = WorkerRuntime(store_grant)

            task_id = submit_task("import-42", () -> "imported", Owner("browser-client");
                                  watchers=[Owner("backend-service")], runtime=rt_store_grant)
            @test timedwait(() -> get_task_status(task_id, Owner("browser-client"); runtime=rt_store_grant)[:status] == "COMPLETED", 5.0) == :ok

            # The grant has to survive serialization and round-trip back out of the store.
            # (This is a #96 test, not a #88 regression test: within one process the saved
            # object already carries both watchers, so it would pass against the unpatched
            # `set_task!` too. The non-vacuous #88 cases are above and in workers_tests.jl.)
            @test get_task_status(task_id, Owner("backend-service"); runtime=rt_store_grant)[:result] == "imported"
            @test only(get_all_tasks(store_grant, Owner("backend-service"))).id == task_id
            @test_throws AuthorizationError get_task_status(task_id, Owner("stranger"); runtime=rt_store_grant)
        end

        @testset "add_watcher! reaches a running task's live info" begin
            store_live = RealPormGWorkerStore(model=MockTaskModel())
            rt_store_live = WorkerRuntime(store_live)

            running = TaskInfo("alice::live")
            push!(running.watchers, "alice")
            running.status = RUNNING
            replace_task!(store_live, running.id, running)
            # get_task_info serves this object for an active task, so a grant written
            # only to the row would stay invisible until the task terminated.
            Nitro.Workers.register_active_task_info!(rt_store_live, running.id, running)

            @test add_watcher!(store_live, "alice::live", "bob") == true
            @test "bob" in get_task_info(store_live, "alice::live").watchers
            @test get_task_status("alice::live", Owner("bob"); runtime=rt_store_live)[:id] == "alice::live"
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
            rt_store5 = WorkerRuntime(store5)

            info = TaskInfo("task-live"; queue_name="reports")
            info.status = RUNNING
            update_progress!(info, 0.0)
            set_task!(store5, info.id, info)  # DB row stuck at 0.0

            live = TaskInfo("task-live"; queue_name="reports")
            live.status = RUNNING
            update_progress!(live, 73.0)
            Nitro.Workers.register_active_task_info!(rt_store5, live.id, live)

            listed = only(get_all_tasks(rt_store5, System(); status=RUNNING))
            @test listed.progress == 73.0

            # The overlay is the RUNTIME's, so the raw store listing still reports the row --
            # which is what makes run-start and zombie recovery able to read durable state.
            @test only(get_all_tasks(store5, System(); status=RUNNING)).progress == 0.0

            # After the task terminates the cache entry is gone and the DB value wins.
            Nitro.Workers.deregister_active_task_info!(rt_store5, live.id)
            @test only(get_all_tasks(rt_store5, System(); status=RUNNING)).progress == 0.0
        end

        @testset "_from_db_record raises on unknown status string" begin
            # Regression: previously an unrecognised status string would silently leave
            # task.status at its constructor default (PENDING), masking schema drift.
            ext = Base.get_extension(Nitro, :NitroPormGExt)
            from_db = getproperty(ext, :_from_db_record)

            good_row = Dict{String,Any}(
                "id" => "t1", "run_id" => string(UUIDs.uuid4()),
                "status" => "COMPLETED", "progress" => 100.0,
                "result" => "", "error" => "", "created_at" => Dates.now(Dates.UTC),
                "started_at" => nothing, "completed_at" => nothing,
                "watchers" => "[]", "queue_name" => "",
            )
            @test from_db(good_row).status == COMPLETED

            bad_row = merge(good_row, Dict{String,Any}("id" => "t2", "status" => "RETRYING"))
            @test_throws ErrorException from_db(bad_row)
        end

        @testset "_from_db_record reads run_id back, and refuses a pre-#108 row" begin
            ext = Base.get_extension(Nitro, :NitroPormGExt)
            from_db = getproperty(ext, :_from_db_record)

            run_id = UUIDs.uuid4()
            row = Dict{String,Any}(
                "id" => "t1", "run_id" => string(run_id),
                "status" => "RUNNING", "progress" => 0.0,
                "result" => "", "error" => "", "created_at" => Dates.now(Dates.UTC),
                "started_at" => nothing, "completed_at" => nothing,
                "watchers" => "[]", "queue_name" => "",
            )

            # The load-bearing assertion. `TaskInfo(id)` mints a fresh run_id in its
            # constructor, so a deserializer that forgot to overwrite it would pass every
            # other test in this file while making it impossible for any worker to finish
            # its own task -- every fence would compare against an id nothing holds (#108).
            @test from_db(row).run_id == run_id

            # A table that predates the column fails loudly and names the fix, rather than
            # silently keeping the invented run_id.
            legacy = delete!(copy(row), "run_id")
            @test_throws ErrorException from_db(legacy)
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
            rt_store_e2e = WorkerRuntime(store_e2e)
            release = Base.Event()
            attacker_calls = Ref(0)

            try
                owner_id = submit_task("shared-export", () -> begin
                    wait(release)
                    return "victim-secret"
                end, Owner("victim"); scope=:global, runtime=rt_store_e2e)
                @test owner_id == "shared-export"

                @test_throws AuthorizationError submit_task("shared-export", () -> begin
                    attacker_calls[] += 1
                    return "attacker-data"
                end, Owner("attacker"); scope=:global, runtime=rt_store_e2e)

                notify(release)
                @test timedwait(() -> get_task_status(owner_id, Owner("victim"); runtime=rt_store_e2e)[:status] == "COMPLETED", 5.0) == :ok

                # Terminal state: replacing the row would destroy the owner's result.
                @test_throws AuthorizationError submit_task("shared-export", () -> begin
                    attacker_calls[] += 1
                    return "attacker-data"
                end, Owner("attacker"); scope=:global, runtime=rt_store_e2e)

                persisted = get_task_status(owner_id, Owner("victim"); runtime=rt_store_e2e)
                @test persisted[:result] == "victim-secret"
                @test persisted[:watcher_count] == 1
                @test attacker_calls[] == 0

                # user scope keeps the two users on separate rows entirely
                a = submit_task("report", () -> "a", Owner("user-a"); runtime=rt_store_e2e)
                b = submit_task("report", () -> "b", Owner("user-b"); runtime=rt_store_e2e)
                @test a == "user-a::report"
                @test b == "user-b::report"
                @test_throws AuthorizationError get_task_status(a, Owner("user-b"); runtime=rt_store_e2e)
            finally
                notify(release)
                reset_runtime!(rt_store_e2e)
            end
        end

        @testset "stored error text is bounded and redactable in the TEXT column (#140)" begin
            # The persistent store is the whole reason #140 matters: `error` is a TEXT column that
            # outlives the process, so this asserts against the raw stored row rather than the
            # `get_task_status` view.
            sentinel = "tok-91fe3c"
            store_err = RealPormGWorkerStore(model=MockTaskModel())
            rt_store_err = WorkerRuntime(store_err)
            owner = Owner("user-err")

            try
                @test get_error_redactor(store_err) === nothing

                long_tail = repeat("x", MAX_STORED_ERROR_CHARS * 2)
                capped_id = submit_task("capped", () -> throw(ArgumentError(long_tail)), owner; runtime=rt_store_err)
                @test timedwait(() -> get_task_status(capped_id, owner; runtime=rt_store_err)[:status] == "FAILED", 5.0) == :ok

                column = store_err.model._table[capped_id]["error"]
                @test length(column) <= MAX_STORED_ERROR_CHARS + 64
                @test isvalid(column)
                @test occursin("truncated", column)

                set_error_redactor!(store_err, (exc, rendered) -> string(nameof(typeof(exc))))
                redacted_id = submit_task("redacted", () -> throw(ArgumentError("bad token: $(sentinel)")), owner; runtime=rt_store_err)
                @test timedwait(() -> get_task_status(redacted_id, owner; runtime=rt_store_err)[:status] == "FAILED", 5.0) == :ok

                # POSITIVE first: the sentinel really is in the raw rendering, so the negative
                # assertion below is not passing for the wrong reason.
                @test occursin(sentinel, format_error(ArgumentError("bad token: $(sentinel)")))
                # NEGATIVE: and it never reaches the column.
                @test store_err.model._table[redacted_id]["error"] == "ArgumentError"
                @test !occursin(sentinel, store_err.model._table[redacted_id]["error"])
            finally
                reset_runtime!(rt_store_err)
            end
        end

        @testset "the runtime tears a persistent backend down (#29, #167)" begin
            store_td = RealPormGWorkerStore(model=MockTaskModel())
            rt_store_td = WorkerRuntime(store_td)
            owner = Owner("user-td")

            try
                # `shutdown!` used to have a no-op fallback on AbstractWorkerStore and this
                # backend never overrode it, so `uninstall!` left the cleanup scheduler issuing
                # DELETEs against nitro_task and the queue processors blocking on `take!` after
                # the app had stopped -- another set leaked on every bootstrap/teardown cycle.
                # #166 made the method required; #167 removed the ability to own the resources
                # at all, so there is no longer anything for this backend to implement.
                @test !hasmethod(shutdown!, Tuple{RealPormGWorkerStore})

                task_id = submit_sequential_task("td-queue", "one", () -> "done", owner; runtime=rt_store_td)
                @test timedwait(() -> get_task_status(task_id, owner; runtime=rt_store_td)[:status] == "COMPLETED", 5.0) == :ok

                scheduler = start_cleanup_scheduler(; interval_hours=1, retain_days=7, runtime=rt_store_td)
                @test get_cleanup_scheduler(rt_store_td)[] === scheduler

                channel = get_sequential_queues(rt_store_td)["td-queue"].channel
                @test isopen(channel)

                # Stand in for a run still in flight. A FINISHED run deregisters itself, so the
                # caches are empty by then -- registering directly is both deterministic and the
                # exact state a mid-flight shutdown finds. It parks rather than polling the
                # token, so it is the case the drain cannot win: the wait expires.
                #
                # It used to be `current_task()`, which no longer stands in for anything:
                # `_snapshot_runs` skips the caller's own run on purpose (#176), so registering
                # the test's own task would exercise the re-entrancy guard instead of the drain.
                #
                # The record is written RUNNING, not left at the constructor's PENDING. That is
                # what makes the zombie-sweep assertion below mean anything: the sweep only reads
                # rows whose stored status is RUNNING, so a PENDING stand-in would come back `0`
                # whether or not the handle survived, and prove nothing.
                in_flight_info = TaskInfo("in-flight")
                in_flight_info.status = RUNNING
                replace_task!(store_td, in_flight_info.id, in_flight_info)

                release_td = Base.Event()
                in_flight_handle = Threads.@spawn wait(release_td)
                Nitro.Workers.register_active_task!(rt_store_td, "in-flight", in_flight_handle)
                Nitro.Workers.register_active_task_info!(rt_store_td, "in-flight", in_flight_info)
                @test !isempty(rt_store_td.active_tasks)
                @test !isempty(rt_store_td.active_task_infos)
                @test get_task_info(store_td, "in-flight").status == RUNNING

                # Teardown DRAINS now (#176). This testset asserted `isempty(active_tasks)` back
                # when `shutdown!` released unconditionally; that assertion encoded the contract
                # #176 changed, so it moves with the contract rather than the fix bending around
                # it.
                drained = shutdown!(rt_store_td; drain_timeout=0.2)

                @test get_cleanup_scheduler(rt_store_td)[] === nothing
                @test istaskdone(scheduler.task)
                @test !isopen(channel)
                @test isempty(get_sequential_queues(rt_store_td))

                # The run outlived the wait, so its handle STAYS -- on this backend exactly as in
                # memory. That is the whole of #176: `recover_zombie_tasks!` reads liveness from
                # this handle and nothing else, so dropping it is what used to make a genuinely
                # running task look dead and get marked FAILED on the next start. The sweep is
                # the assertion that matters, because it is the thing that used to do the damage.
                @test drained == false
                @test get_active_task(rt_store_td, "in-flight") === in_flight_handle
                @test recover_zombie_tasks!(; runtime=rt_store_td) == 0
                @test get_task_info(store_td, "in-flight").status == RUNNING

                # Release the stand-in. (A *real* run clears its own handle through
                # `_finish_task!`; this one has no run behind it, so asserting that here would
                # only be asserting the test's own cleanup. The in-memory suite covers it with a
                # genuine submission.)
                notify(release_td)
                wait(in_flight_handle)

                # `active_task_infos` must SURVIVE, which is the opposite of what "finish the
                # teardown" suggests: `cancel_task` resolves the live TaskInfo through
                # `get_active_task_info`, so clearing it would make a run that outlives a
                # teardown uncancellable. This used to be a rule each backend had to obey
                # separately -- and in-memory obeyed it only by accident, aliasing a registry
                # `shutdown!` happened not to empty. It is one line in one function now.
                @test haskey(rt_store_td.active_task_infos, "in-flight")
                @test get_active_task_info(rt_store_td, "in-flight") isa TaskInfo

                # The durable rows survive: they outlive the process by design, and that is the
                # whole reason to use this store rather than the in-memory one.
                @test haskey(store_td.model._table, task_id)

                # ...and `reset_runtime!` is no longer a complete no-op on a persistent store. It
                # runs the teardown while still declining to delete the durable rows, which would
                # be a destructive delete of live data rather than a reset.
                second = submit_sequential_task("td-queue", "two", () -> "again", owner; runtime=rt_store_td)
                @test timedwait(() -> get_task_status(second, owner; runtime=rt_store_td)[:status] == "COMPLETED", 5.0) == :ok
                reset_runtime!(rt_store_td)
                @test isempty(get_sequential_queues(rt_store_td))
                @test isempty(rt_store_td.active_tasks)
                @test haskey(store_td.model._table, second)
            finally
                reset_runtime!(rt_store_td)
            end
        end

        @testset "one transient read failure denies the key instead of granting it (#19)" begin
            # Regression: get_task_info used to log a failed read and return `nothing`,
            # which _register_or_watch! reads as "no such task" — so a single connection
            # blip skipped the cross-user gate and let the caller take over the row.
            flaky = FlakyReadModel()
            store_fail = RealPormGWorkerStore(model=flaky)
            rt_store_fail = WorkerRuntime(store_fail)

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
                "shared-export", () -> "attacker-data", Owner("attacker"); scope=:global, runtime=rt_store_fail)

            # The victim's row survived intact and is still theirs.
            flaky.fail_next[] = 0
            persisted = get_task_status("shared-export", Owner("victim"); runtime=rt_store_fail)
            @test persisted[:result] == "victim-secret"
            @test persisted[:watcher_count] == 1
            @test_throws AuthorizationError get_task_status("shared-export", Owner("attacker"); runtime=rt_store_fail)
        end

        @testset "a failed read of one queued item does not kill the processor (#19)" begin
            # Regression on the rethrow above: _execute_queued_task reads task
            # metadata BEFORE registering the active-info cache entry, so that read
            # hits the DB. An escaping exception unwound the processor's `while true`
            # loop, leaving the queue undrained and every item behind it stranded.
            flaky = FlakyReadModel()
            store_q = RealPormGWorkerStore(model=flaky)
            rt_store_q = WorkerRuntime(store_q)
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
                first_id = submit_sequential_task("qfail", "k1", run_step, Owner("u"); runtime=rt_store_q)
                second_id = submit_sequential_task("qfail", "k2", run_step, Owner("u"); runtime=rt_store_q)
                @test first_id == "u::k1"
                @test second_id == "u::k2"

                # Break only k2's read, then let k1 finish so the processor picks k2 up.
                push!(flaky.fail_ids, second_id)
                notify(gate)

                @test timedwait(() -> get_task_status(first_id, Owner("u"); runtime=rt_store_q)[:status] == "COMPLETED", 5.0) == :ok

                # k2 is dropped, but the processor must still be alive and draining.
                queue = get_sequential_queues(rt_store_q)["qfail"]
                @test queue.processor_task !== nothing
                @test !istaskdone(queue.processor_task)

                delete!(flaky.fail_ids, second_id)
                third_id = submit_sequential_task("qfail", "k3", run_step, Owner("u"); runtime=rt_store_q)
                @test timedwait(() -> get_task_status(third_id, Owner("u"); runtime=rt_store_q)[:status] == "COMPLETED", 5.0) == :ok
                @test get_task_status(third_id, Owner("u"); runtime=rt_store_q)[:result] == "ran-u::k3"
            finally
                notify(gate)
                reset_runtime!(rt_store_q)
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

        @testset "a re-run does not inherit its predecessor's live TaskInfo (#167)" begin
            # A record can be terminal while its RUN is still executing, because
            # cancellation is cooperative (#127): `cancel_task` claims CANCELLED and the
            # callback keeps going until it returns. Re-running the key in that window used
            # to hand the NEW run the PREVIOUS run's `TaskInfo`, because this store's
            # `get_task_info` preferred the live cache and `replace_task!` never refreshed
            # it. The new run's `try_transition!` then failed its own #108 run fence and the
            # task sat PENDING forever with nothing left to drain it.
            store_rr = RealPormGWorkerStore(model=MockTaskModel())
            rt_store_rr = WorkerRuntime(store_rr)
            owner = Owner("user-rr")
            gate = Base.Event()

            try
                # Deliberately does NOT poll `cancel_requested`: we need the run to outlive
                # the terminal write on its own record.
                first_id = submit_task("rerun", _ -> (wait(gate); "first"), owner; runtime=rt_store_rr)
                @test timedwait(() -> get_task_status(first_id, owner; runtime=rt_store_rr)[:status] == "RUNNING", 5.0) == :ok

                cancel_task(first_id, owner; runtime=rt_store_rr)
                @test get_task_status(first_id, owner; runtime=rt_store_rr)[:status] == "CANCELLED"
                # The predecessor is still executing, so its live entry is still published.
                @test get_active_task_info(rt_store_rr, first_id) !== nothing

                second_id = submit_task("rerun", _ -> "second", owner; runtime=rt_store_rr)
                @test second_id == first_id   # same key, same scoped id, new run

                @test timedwait(() -> get_task_status(second_id, owner; runtime=rt_store_rr)[:status] == "COMPLETED", 5.0) == :ok
                @test get_task_status(second_id, owner; runtime=rt_store_rr)[:result] == "second"
            finally
                notify(gate)
                reset_runtime!(rt_store_rr)
            end
        end

        @testset "the run-handle caches behave identically on both backends (#167)" begin
            # #166 hit a real cancellation regression by treating `PormGWorkerStore`'s
            # `active_task_infos` and `InMemoryWorkerStore`'s registry-aliased
            # `get_active_task_info` as equivalent. They were not, and nothing asserted it --
            # the live-object tests existed for PormG only and had no in-memory twin. They are
            # one mechanism now, so this body runs unchanged over both.
            for (label, backend) in (("in-memory", InMemoryWorkerStore()),
                                     ("pormg", RealPormGWorkerStore(model=MockTaskModel())))
                rt = WorkerRuntime(backend)
                owner = Owner("user-parity")

                try
                    # -- register / get / deregister round-trip
                    handle = @async sleep(0.01)
                    info = TaskInfo("alice::parity")
                    Nitro.Workers.register_active_task!(rt, info.id, handle)
                    Nitro.Workers.register_active_task_info!(rt, info.id, info)
                    @test get_active_task(rt, info.id) === handle
                    @test get_active_task_info(rt, info.id) === info

                    # -- a reader sees the LIVE object, so fresh progress needs no round-trip
                    replace_task!(backend, info.id, info)
                    update_progress!(info, 61.0)
                    @test get_task_info(rt, info.id).progress == 61.0

                    # -- ...while the store read stays DURABLE. On the in-memory backend the
                    #    record IS the live object, so both answers agree there by identity
                    #    rather than by an overlay; on PormG the row is still at 0.0.
                    durable = get_task_info(backend, info.id)
                    @test durable !== nothing
                    @test (label == "in-memory") == (durable === info)

                    # -- the listing overlay reaches the live value on both
                    listed = only(t for t in get_all_tasks(rt, System()) if t.id == info.id)
                    @test listed.progress == 61.0

                    # -- a grant written while the task runs reaches the live watcher list
                    @test add_watcher!(rt, info.id, "grantee")
                    @test "grantee" in get_active_task_info(rt, info.id).watchers

                    # -- `_deregister_run!` is RUN-fenced: a stale run cannot evict its
                    #    successor's handles (#108). `successor` replaces the slot, then the
                    #    predecessor's late teardown must be a no-op.
                    successor = TaskInfo("alice::parity")
                    @test successor.run_id != info.run_id
                    Nitro.Workers.register_active_task_info!(rt, successor.id, successor)
                    Nitro.Workers._deregister_run!(rt, info)
                    @test get_active_task(rt, info.id) === handle
                    @test get_active_task_info(rt, info.id) === successor

                    # ...and the successor's own teardown does release them.
                    Nitro.Workers._deregister_run!(rt, successor)
                    @test get_active_task(rt, info.id) === nothing
                    @test get_active_task_info(rt, info.id) === nothing

                    wait(handle)
                finally
                    reset_runtime!(rt)
                end
            end
        end

        @testset "lock_tasks provides mutual exclusion for PormGWorkerStore" begin
            # Regression: lock_tasks was a no-op for PormGWorkerStore, leaving
            # _register_or_watch! and cancel_task unprotected against concurrent writers.
            store5 = RealPormGWorkerStore(model=MockTaskModel())
            rt_store5 = WorkerRuntime(store5)

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

        @testset "teardown abandons a queued item identically on both backends (#182, #183)" begin
            # workers §6: parity is ASSERTED, not inferred. `_abandon_queued_item!` adds no store
            # method, so the in-memory and serializing backends "obviously" agree -- which is the
            # exact reasoning that produced #166's cancellation regression. The discriminating
            # half is here: PormG goes through its column mapping and a filtered update, so the
            # `(PENDING,)` from-set and the `run_id` WHERE term have to be expressed as real query
            # terms rather than as an in-memory field check. `MockTaskModel` errors loudly on an
            # unmodelled filter key, so a regression in either term fails here. (It is a Dict, not
            # SQL -- this does not exercise column types or PormG's UTC canonicalization.)
            store_ab = RealPormGWorkerStore(model=MockTaskModel())
            rt_ab = WorkerRuntime(store_ab)

            record = TaskInfo("alice::queued-at-teardown"; queue_name="reports")
            push!(record.watchers, "alice")
            replace_task!(store_ab, record.id, record)
            item = Nitro.Workers.QueueItem(record.id, record.run_id,
                                           task_info -> "never", TaskOptions())

            before = Nitro.Workers.current_time_utc()
            @test Nitro.Workers._abandon_queued_item!(rt_ab, item) == true

            persisted = get_task_info(store_ab, record.id)
            @test persisted.status == CANCELLED
            # The #183 string, read back out of the stored record rather than off a live object.
            @test persisted.error == "Cancelled by worker shutdown"
            # Bounded, not merely non-`nothing`: exact equality is not available, but a window is,
            # and "it is set to something" would pass on a stamp carried over from another write.
            @test persisted.completed_at !== nothing
            @test before <= persisted.completed_at <= Nitro.Workers.current_time_utc()

            # Idempotent through the DB CAS too -- `shutdown!` and the processor's `draining`
            # branch can both reach one item.
            @test Nitro.Workers._abandon_queued_item!(rt_ab, item) == false

            # And run-fenced through the DB's WHERE term: a key re-run while the item sat buffered
            # belongs to its successor, and cancelling by id would kill a run about to start.
            fenced = TaskInfo("alice::fenced-at-teardown"; queue_name="reports")
            push!(fenced.watchers, "alice")
            replace_task!(store_ab, fenced.id, fenced)
            stale = Nitro.Workers.QueueItem(fenced.id, fenced.run_id,
                                            task_info -> "never", TaskOptions())

            successor = TaskInfo("alice::fenced-at-teardown"; queue_name="reports")
            push!(successor.watchers, "alice")
            replace_task!(store_ab, successor.id, successor)

            @test Nitro.Workers._abandon_queued_item!(rt_ab, stale) == false
            still_live = get_task_info(store_ab, fenced.id)
            @test still_live.status == PENDING
            @test still_live.run_id == successor.run_id
        end

        @testset "run-start is fenced on the carried run identity on both backends (#191)" begin
            # workers §6: parity is ASSERTED, not inferred. The fix adds no store method, so the
            # two backends "obviously" agree -- the exact reasoning that produced #166's
            # cancellation regression. The body runs unchanged over both, so a divergence fails
            # rather than hiding behind "it looked equivalent".
            #
            # What makes PormG the discriminating half here is precisely one thing:
            # `get_task_info(store, ·)` returns a FRESH object built by `_from_db_record`, so the
            # `run_id` both checks below compare is one that survived a serialize/deserialize
            # round trip rather than being read off the very object the in-memory registry
            # aliases. That is what #191's checklist says to verify rather than assume. Break
            # `_from_db_record`'s `run_id` and the SURVIVING item fails its own check here,
            # pormg-only.
            #
            # It deliberately does NOT claim to exercise the `run_id` WHERE term in
            # `try_transition!`: after the fix a stale item returns before reaching the CAS, so
            # that term is covered by the #108/#182 testsets above, not by this one.
            for (label, backend) in (("in-memory", InMemoryWorkerStore()),
                                     ("pormg", RealPormGWorkerStore(model=MockTaskModel())))
                rt_fence = WorkerRuntime(backend)
                owner = Owner("alice")
                ran = String[]
                stale_cb = task_info -> (push!(ran, "STALE"); "stale")
                live_cb = task_info -> (push!(ran, "LIVE"); "live")
                # Named per backend, so a one-sided failure says WHICH one broke. The whole
                # point of a parity body is that the two halves can disagree.
                @testset "$label" begin
                    try
                        key = scoped_task_key("run-fence", owner)

                        predecessor_run = Nitro.Workers._register_or_watch!(rt_fence, key, owner; queue_name="reports")
                        stale = Nitro.Workers.QueueItem(key, predecessor_run, stale_cb, TaskOptions())
                        @test cancel_task(key, owner; runtime=rt_fence)[:status] == "Task cancelled"

                        successor_run = Nitro.Workers._register_or_watch!(rt_fence, key, owner; queue_name="reports")
                        @test successor_run != predecessor_run
                        surviving = Nitro.Workers.QueueItem(key, successor_run, live_cb, TaskOptions())

                        # The record the stale item reads back belongs to the successor. On PormG
                        # that is a fresh object built by `_from_db_record`; on the in-memory store
                        # it is the registry's own. Either way the item must decline.
                        @test Nitro.Workers._execute_queued_task(rt_fence, stale) === nothing
                        @test ran == String[]

                        pending = get_task_info(backend, key)
                        @test pending.status == PENDING
                        @test pending.run_id == successor_run
                        @test pending.started_at === nothing
                        @test get_active_task_info(rt_fence, key) === nothing

                        # The surviving run still starts and completes, so the fence does not strand
                        # the key on either backend.
                        Nitro.Workers._execute_queued_task(rt_fence, surviving)
                        @test ran == ["LIVE"]
                        done = get_task_info(backend, key)
                        @test done.status == COMPLETED
                        @test done.result == "live"
                        @test done.run_id == successor_run

                        # The async path carries the identity the same way, and on PormG reads it
                        # back through the same `_from_db_record` round trip.
                        async_key = scoped_task_key("run-fence-async", owner)
                        async_ran = Threads.Atomic{Bool}(false)
                        async_predecessor = Nitro.Workers._register_or_watch!(rt_fence, async_key, owner)
                        cancel_task(async_key, owner; runtime=rt_fence)
                        async_successor = Nitro.Workers._register_or_watch!(rt_fence, async_key, owner)
                        wait(Nitro.Workers._execute_task_async(rt_fence, async_key,
                                                               task_info -> (async_ran[] = true; "stale"),
                                                               TaskOptions(), async_predecessor))
                        @test async_ran[] == false
                        async_record = get_task_info(backend, async_key)
                        @test async_record.status == PENDING
                        @test async_record.run_id == async_successor
                    finally
                        reset_runtime!(rt_fence)
                    end
                end
            end
        end

        @testset "register_run! refuses a foreign live run on both backends (#198)" begin
            # workers §6: parity is ASSERTED. The caches are runtime-owned, so the CAS is one
            # shared body rather than two store methods -- which is exactly the "obviously
            # equivalent" reasoning the rule warns about. What PormG discriminates: every
            # `TaskInfo` the runtime sees is a FRESH deserialization, so the `run_id` the CAS
            # compares has survived a round trip rather than being read off the object the
            # in-memory registry aliases. Same body as `workers_tests.jl`'s #198 group, over both.
            for (label, backend) in (("in-memory", InMemoryWorkerStore()),
                                     ("pormg", RealPormGWorkerStore(model=MockTaskModel())))
                rt_cas = WorkerRuntime(backend)
                owner = Owner("alice")
                handles = Task[]
                ran = Threads.Atomic{Bool}(false)
                never = task_info -> (ran[] = true; "never")
                @testset "$label" begin
                    try
                        # The issue's interleaving: P read its record (T0), a cancel and a
                        # re-submit minted S which registered and claimed RUNNING (T1), and
                        # only then does P publish (T2).
                        key = scoped_task_key("cas", owner)
                        predecessor_run = Nitro.Workers._register_or_watch!(rt_cas, key, owner; queue_name="reports")
                        p_info = get_task_info(backend, key)
                        @test p_info.run_id == predecessor_run
                        @test cancel_task(key, owner; runtime=rt_cas)[:status] == "Task cancelled"

                        successor_run = Nitro.Workers._register_or_watch!(rt_cas, key, owner; queue_name="reports")
                        s_info = get_task_info(backend, key)
                        @test s_info.run_id == successor_run
                        s_handle = @async sleep(0.05)
                        push!(handles, s_handle)
                        @test register_run!(rt_cas, key, s_info, s_handle) == true
                        @test try_transition!(backend, key, (PENDING,), RUNNING; run_id=successor_run) == true

                        p_handle = @async nothing
                        push!(handles, p_handle)
                        @test register_run!(rt_cas, key, p_info, p_handle) == false
                        @test register_run!(rt_cas, key, s_info, s_handle) == true
                        Nitro.Workers._deregister_run!(rt_cas, p_info)

                        @test get_active_task(rt_cas, key) === s_handle
                        @test get_active_task_info(rt_cas, key) === s_info
                        @test recover_zombie_tasks!(; runtime=rt_cas) == 0
                        @test get_task_info(backend, key).status == RUNNING
                        @test cancel_task(key, owner; runtime=rt_cas)[:status] == "Task cancelled"
                        @test cancel_reason(s_info) == :user
                        @test cancel_reason(p_info) == :none

                        # A foreign run in the slot at claim time is declined on both paths.
                        # On PormG the record read inside the claim is a fresh object; the
                        # CAS compares its `run_id` against the foreign info's.
                        key2 = scoped_task_key("cas-claim", owner)
                        run2 = Nitro.Workers._register_or_watch!(rt_cas, key2, owner; queue_name="reports")
                        foreign = TaskInfo(key2)
                        Nitro.Workers.register_active_task_info!(rt_cas, key2, foreign)
                        item = Nitro.Workers.QueueItem(key2, run2, never, TaskOptions())
                        @test (@test_logs (:warn, r"foreign run") Nitro.Workers._execute_queued_task(rt_cas, item)) === nothing
                        @test_logs (:warn, r"foreign run") wait(Nitro.Workers._execute_task_async(rt_cas, key2, never, TaskOptions(), run2))
                        @test ran[] == false
                        pending = get_task_info(backend, key2)
                        @test pending.status == PENDING
                        @test pending.run_id == run2
                        @test get_active_task_info(rt_cas, key2) === foreign
                        @test get_active_task(rt_cas, key2) === nothing
                    finally
                        foreach(wait, handles)
                        reset_runtime!(rt_cas)
                    end
                end
            end
        end

        @testset "a user's cancel records \"Cancelled by user\" in the row (#183)" begin
            # The other half of the parity claim: `cancel_task`'s durable write now renders the
            # `:user` message, and `PormGWorkerStore` writes it to a column while preferring the
            # live object on read. Both have to agree, or the in-memory backend passes and the
            # persistent one reports a different string to an operator reading the table.
            store_u = RealPormGWorkerStore(model=MockTaskModel())
            rt_u = WorkerRuntime(store_u)

            live = TaskInfo("alice::cancelled-by-a-person")
            push!(live.watchers, "alice")
            live.status = RUNNING
            replace_task!(store_u, live.id, live)
            Nitro.Workers.register_active_task_info!(rt_u, live.id, live)

            @test cancel_task(live.id, Owner("alice"); runtime=rt_u)[:status] == "Task cancelled"

            @test cancel_reason(live) === :user
            @test live.error == "Cancelled by user"                       # the live mirror
            @test get_task_info(store_u, live.id).error == "Cancelled by user"   # the row
        end

        @testset "every task query runs on the store's db_key, not a default (#203)" begin
            # Until #203 the mock modelled `.db(key)` as a passthrough that discarded the key,
            # so `_task_objects(store)` and `store.model.objects` were the same thing and
            # deleting the routing call from the ext kept all 43 testsets in this file green.
            # `PormGWorkerStore`'s routing was pinned by nothing.
            #
            # Two tables and a DECOY: the wrong-connection read finds a row under the same id
            # on `db` and hands it back, so a routing regression names itself instead of just
            # reporting "missing".
            m = MockTaskModel("db", "tasks")
            store_r = RealPormGWorkerStore(model=m, db_key="tasks")

            @test store_r.db_key == "tasks"

            decoy = Dict{String,Any}(
                "id" => "alice::routed", "run_id" => "decoy-run", "status" => "COMPLETED",
                "progress" => 100.0, "result" => "\"decoy\"", "error" => "",
                "created_at" => now(UTC), "started_at" => nothing, "completed_at" => nothing,
                "watchers" => JSON.json(["mallory"]), "queue_name" => "decoy",
            )
            m._tables["db"]["alice::routed"] = decoy

            # create
            info = TaskInfo("alice::routed"; queue_name="reports")
            push!(info.watchers, "alice")
            replace_task!(store_r, info.id, info)
            @test haskey(m._tables["tasks"], "alice::routed")
            @test m._tables["db"]["alice::routed"] === decoy          # untouched
            @test m._tables["db"]["alice::routed"]["queue_name"] == "decoy"

            # read -- the decoy is what a dropped `.db` would return
            fetched = get_task_info(store_r, "alice::routed")
            @test fetched.queue_name == "reports"
            @test fetched.queue_name != "decoy"

            # update
            info.status = RUNNING
            set_task!(store_r, info.id, info)
            @test m._tables["tasks"]["alice::routed"]["status"] == "RUNNING"
            @test m._tables["db"]["alice::routed"]["status"] == "COMPLETED"

            # watcher CAS
            add_watcher!(store_r, "alice::routed", "bob")
            @test occursin("bob", m._tables["tasks"]["alice::routed"]["watchers"])
            @test !occursin("bob", m._tables["db"]["alice::routed"]["watchers"])

            # fenced transition
            @test try_transition!(store_r, "alice::routed", (PENDING, RUNNING), COMPLETED;
                                  run_id=info.run_id)
            @test m._tables["tasks"]["alice::routed"]["status"] == "COMPLETED"
            # The decoy started life COMPLETED, so its status proves nothing here -- its
            # run_id does: the fenced write never reached this connection.
            @test m._tables["db"]["alice::routed"]["run_id"] == "decoy-run"

            # list
            listed = get_all_tasks(store_r, Owner("alice"))
            @test length(listed) == 1
            @test first(listed).queue_name == "reports"

            # delete
            delete_task!(store_r, "alice::routed")
            @test !haskey(m._tables["tasks"], "alice::routed")
            @test m._tables["db"]["alice::routed"] === decoy          # still untouched
        end

        @testset "cleanup_tasks! prunes the store's connection only (#203)" begin
            m = MockTaskModel("db", "tasks")
            store_c = RealPormGWorkerStore(model=m, db_key="tasks")

            old = now(UTC) - Day(30)
            for tbl in ("db", "tasks")
                m._tables[tbl]["stale"] = Dict{String,Any}(
                    "id" => "stale", "run_id" => "", "status" => "COMPLETED",
                    "progress" => 100.0, "result" => "", "error" => "",
                    "created_at" => old, "started_at" => old, "completed_at" => old,
                    "watchers" => "[]", "queue_name" => "default",
                )
            end

            @test cleanup_tasks!(store_c, 1) == 1
            @test !haskey(m._tables["tasks"], "stale")
            @test haskey(m._tables["db"], "stale")    # the other connection is not ours to prune
        end

        @testset "the mock refuses a query with no connection selected (#203)" begin
            # A meta-test on the guard itself. Without it the assertions above are theatre:
            # they would pass just as well against a mock that ignored `.db` entirely, which
            # is precisely the state this file was in before #203.
            m = MockTaskModel("db", "tasks")

            @test_throws "without selecting a connection" m.objects.filter("id" => "x").first()
            @test_throws "without selecting a connection" m.objects.filter("id" => "x").list()
            @test_throws "no table registered for db key" m.objects.db("nope").filter("id" => "x").first()

            # ...and the routed form works, so the guard is not simply refusing everything.
            @test m.objects.db("tasks").filter("id" => "x").first() === nothing
        end
    end
end

end
