@testitem "PormG worker store" tags=[:extension, :pormg, :workers] setup=[NitroCommon] begin

using Test
using Dates
using JSON
using UUIDs
using TimeZones: ZonedDateTime, FixedTimeZone
using Nitro
using Nitro.Workers
using Nitro.Errors: AuthorizationError

# Poll until a task settles, and let a timeout report as ONE failure.
#
# The bare `@test timedwait(...) == :ok` this replaces left every following assertion about the
# terminal record running anyway -- and those are all downstream of the same cause, so one lost
# race surfaced as three or four unrelated-looking failures. CI showed exactly that on #226: a
# `timed_out` at the poll, then `persisted[:result] == nothing` immediately below it, on a
# branch that touches no worker code.
#
# Returns whether it settled, so the caller can skip precisely the assertions that are only
# meaningful once it did -- with a plain `if`, never `@test_skip`. `SKIPS_OK` in
# `test/harness_manifest.jl` is deliberately empty and `harness_tests.jl` fails on any skip,
# including the `skip=true` / `broken=true` keyword forms.
#
# This is a REPORTING fix, not the fix for #226. The race that made these polls time out was in
# the mock itself; see `MockDB`.
_settled(predicate::Function; timeout::Real = 5.0) = timedwait(predicate, timeout) === :ok

# These tests exercise the real NitroPormGExt.PormGWorkerStore when PormG is
# available in the active test environment. The mock model below replaces only
# the database layer; store methods come from ext/NitroPormGExt.jl.

# Operator names this mock DIAGNOSES SPECIFICALLY. Spelling one of these without the `@` is the
# drift #180 is about, so it gets its own message rather than being lumped in with any other
# unmodelled key. Ported from `pormg_session_tests.jl`, which grew the guard first (#208).
#
# Deliberately a subset of the real `PormGsuffix` (`PormG/src/constants.jl`), which also carries
# `istartswith`, `iendswith`, the negated `n*` family, the unaccent forms and the JSON
# predicates. Nothing is weakened by the gap: an unlisted suffix still throws, just with the
# generic "unmodelled filter key" text instead of the `@`-prefix diagnosis. Widen it when the
# ext starts using one of those.
const PORMG_OPERATOR_NAMES = Set([
    "gte", "gt", "lte", "lt", "ne", "isnull", "in", "nin",
    "contains", "icontains", "startswith", "endswith", "range",
])

# Every filter key the mock knows how to evaluate. Anything else is a query the mock is not
# actually exercising, and must say so. These are exactly the keys `ext/NitroPormGExt.jl`
# builds -- adding one here without the matching branch below is how the guard rots.
const MODELLED_FILTER_KEYS = Set([
    "id", "id__@gt", "run_id", "status", "status__@in", "queue_name",
    "completed_at__@lte", "completed_at__@isnull",
    "watchers", "id__@startswith", "watchers__@contains",
])

function _reject_filter_key(k::String)
    parts = split(k, "__")
    suffix = String(parts[end])
    if length(parts) > 1 && !startswith(suffix, "@") && suffix in PORMG_OPERATOR_NAMES
        error("MockTaskQuerySet: filter key '$k' is missing PormG's `@` operator prefix. " *
              "Real PormG throws `FilterError` here (\"requires '@' prefix\"), so against a " *
              "database this spelling matches nothing and the store's query silently does not " *
              "constrain -- the #180 defect class. Use " *
              "'$(join(parts[1:end-1], "__"))__@$(suffix)'.")
    end
    error("MockTaskQuerySet: unmodelled filter key '$k' -- teach the mock about it, or the " *
          "query under test is not actually being exercised.")
end

# One database: the state every queryset the owning model mints SHARES, plus the lock that
# makes sharing safe. A queryset is minted per `m.objects` access; the data behind it is not.
#
# The lock is not decoration, and its GRANULARITY is the whole design. `PormGWorkerStore` leaves
# its data methods unlocked on purpose: `try_transition!` and `add_watcher!` are compare-and-set
# through a single filtered `UPDATE`, correct precisely because a real database makes each
# STATEMENT atomic -- `ext/NitroPormGExt.jl` says so in as many words ("the compare and the
# write are one statement"). A mock built on bare `Dict`s offered no such guarantee, so each of
# those statements degraded into an unguarded read-modify-write and this file flaked at `-t 2`
# with a different subset of testsets failing each run (#226).
#
# So: the lock is held for the duration of ONE terminal operation and never across two. That is
# what SQLite's serialized mode gives, and it restores the atomicity the ext is written against
# WITHOUT making `read -> decide -> write` sequences atomic -- which would quietly make the
# #88 / #108 / #167 assertions vacuous, since those exist to test exactly the window between two
# statements.
#
# It is a LEAF lock: nothing is acquired while holding it and no callback runs under it. That,
# and only that, is what makes an order inversion unrepresentable -- NOT any claim about
# `store.task_lock` being held on the way in. It frequently is not: `get_task_status` and
# `get_all_tasks` reach the store through no `lock_tasks` at all, and #226 was precisely a
# lock-free polling read interleaving with a worker task that did hold it. Anyone who reads a
# "production always locks first" guarantee into this will conclude the lock below is redundant.
struct MockDB
    # One table PER CONNECTION, not one table. A single-table mock cannot express #203 at
    # all: "created the table on `tasks`, then read and wrote every row on `db`" is not a
    # statement about anything unless there are two tables to tell apart, so no assertion
    # written against such a mock could have failed on code that dropped `.db(db_key)`.
    tables::Dict{String, Dict{String, Dict{String, Any}}}   # db key -> task id -> row
    # Every filter a query actually RAN with, shared across a `.db(k).filter(a).filter(b)`
    # chain and across every queryset the owning model mints. Without it a test can only
    # check the rows that came back, never that the query carried the run-id fence, the
    # scope prefix or the status set it was supposed to (#208).
    seen::Vector{Dict{String, Any}}
    lock::ReentrantLock
end

MockDB(db_keys::String...) = MockDB(
    Dict{String, Dict{String, Dict{String, Any}}}(
        k => Dict{String, Dict{String, Any}}() for k in (isempty(db_keys) ? ("db",) : db_keys)),
    Dict{String, Any}[],
    ReentrantLock())

mutable struct MockTaskQuerySet
    mdb::MockDB
    db_key::Union{Nothing, String}                          # `nothing` until `.db(key)` runs
    # Per-queryset, and deliberately NOT under the lock: `model.objects` mints a fresh queryset
    # on every access, so an accumulating chain is confined to the task that built it.
    filters::Dict{String, Any}
    # `.values(cols...)`, or `nothing` for every column. Like PormG's `_values!`, the last call
    # wins. A projected read hands back ONLY these keys, which is what makes "the recovery scan
    # never parses `result`" observable: a row whose blob is not JSON is harmless to it (#236).
    projection::Union{Nothing, Vector{String}}
    # `.order_by("id")` and `.limit(n)`: the keyset page shape (#237). Applied by the READ ops
    # only. PormG refuses a `delete()` carrying either, and so does this mock.
    order::Union{Nothing, String}
    limit::Union{Nothing, Int}
end

MockTaskQuerySet(mdb::MockDB, db_key, filters::Dict{String, Any}) =
    MockTaskQuerySet(mdb, db_key, filters, nothing, nothing, nothing)

# The key a `Qor(...)` is recorded under in `filters`: a vector of reconstructed pairs, ANY of
# which may match. One per query -- that is all the ext builds.
const MOCK_OR_KEY = "__or__"

# Read a `PormG.Qor` back into the `"col__@op" => value` pairs it was built from.
#
# This couples the mock to three fields of PormG's `OperObject` (`operator`, `values`,
# `column.field`), the same three its own SQL builder reads. That is the price of a paged Owner
# listing being ONE `Qor` query rather than two legs, and the ext says why that shape is required
# (collation; see "Keyset paging" in `ext/NitroPormGExt.jl`). An unfamiliar member fails loudly
# rather than matching nothing.
function _mock_or_pairs(q)
    pairs = Pair{String, Any}[]
    for o in getfield(q, :or)
        (hasproperty(o, :operator) && hasproperty(o, :values) && hasproperty(o, :column) &&
         hasproperty(o.column, :field)) ||
            error("MockTaskQuerySet: unmodelled Qor member $(typeof(o)) -- teach the mock about it.")
        op = o.operator
        push!(pairs, (op == "=" ? String(o.column.field) : "$(o.column.field)__@$(op)") => o.values)
    end
    return pairs
end

_mock_lock(qs::MockTaskQuerySet) = getfield(qs, :mdb).lock

# The one place a connection is resolved. Every terminal op goes through here, so a query
# that never called `.db(key)` fails loudly instead of silently reading the default table.
function _selected_table(qs::MockTaskQuerySet)
    key = getfield(qs, :db_key)
    key === nothing && error("MockTaskQuerySet: query ran without selecting a connection -- " *
        "every task query must go through `_task_objects(store)` (`.db(store.db_key)`), " *
        "not `m.objects` directly. See #203.")
    tables = getfield(qs, :mdb).tables
    haskey(tables, key) || error("MockTaskQuerySet: no table registered for db key '$key' -- " *
        "PormG throws `InvalidConfigurationError` for a key that was never loaded. Build the " *
        "model as `MockTaskModel(\"$key\")` if the test means to use that connection.")
    return tables[key]
end

# The ONE place `seen` is recorded and rows are matched. MUST be called with the database lock
# held: it reads the shared table, appends to the shared `seen` vector, and hands back the LIVE
# row objects so `update` and `delete` can mutate them inside the same critical section.
#
# `seen` is appended exactly once per call and every terminal op calls this exactly once. That
# is load-bearing, not tidiness: the `_filters_seen` assertions below are exact-count and
# positional, so a second push per operation would break them.
function _filtered_rows_locked(qs::MockTaskQuerySet)
    filters = getfield(qs, :filters)

    # Validate EVERY key BEFORE looking at any row, and before resolving the connection.
    # Checking inside the row loop -- which is where this started -- makes the guard vanish on
    # an empty table, and an empty table is precisely the state a retention sweep runs against
    # once it has worked. It also let an earlier non-matching key `break` out before an
    # unmodelled one was ever reached.
    for (k, v) in filters
        if k == MOCK_OR_KEY
            for (inner, _) in v
                inner in MODELLED_FILTER_KEYS || _reject_filter_key(inner)
            end
        else
            k in MODELLED_FILTER_KEYS || _reject_filter_key(k)
        end
    end

    # Recorded AFTER validation, so `_filters_seen` holds only filters a query could actually
    # run with -- otherwise an assertion written against it alone could be satisfied by a query
    # that threw. Recorded here rather than in `filter` because accumulation means only the
    # terminal op knows the whole of it.
    push!(getfield(qs, :mdb).seen, copy(filters))

    # AFTER the filter-key check: a misspelled filter is the more specific diagnosis, and the
    # `@test_throws` in "the mock refuses what PormG refuses" drive `m.objects` directly.
    table = _selected_table(qs)
    rows = Dict{String, Any}[]

    for row in values(table)
        matches = true
        for (k, v) in filters
            matches = k == MOCK_OR_KEY ? any(((ik, iv),) -> _mock_matches(row, ik, iv), v) :
                                         _mock_matches(row, k, v)
            matches || break
        end
        matches && push!(rows, row)
    end

    return rows
end

# One filter term against one row. Shared by the ANDed terms and by each `Qor` member, so the two
# cannot evaluate the same key differently.
function _mock_matches(row::Dict{String, Any}, k::String, v)
    if k == "id"
        return row["id"] == v
    elseif k == "id__@gt"
        # The keyset cursor (#237). Julia's codepoint order is SQLite's default BINARY collation;
        # the ext never compares ids in Julia, so a collation that differs would not change what
        # this models.
        return row["id"] > v
    elseif k == "run_id"
        # The run half of try_transition!'s compare — see #108. Without this branch
        # the mock would `error` on every fenced transition.
        return row["run_id"] == v
    elseif k == "status"
        return row["status"] == v
    elseif k == "status__@in"
        return row["status"] in v
    elseif k == "queue_name"
        return row["queue_name"] == v
    elseif k == "completed_at__@lte"
        return row["completed_at"] !== nothing && row["completed_at"] <= v
    elseif k == "completed_at__@isnull"
        return (row["completed_at"] === nothing) == v
    elseif k == "watchers"
        # Exact match on the serialized document — the compare half of
        # add_watcher!'s CAS. Without this branch the filter fell through and
        # matched on `id` alone, so the CAS always appeared to win.
        return row["watchers"] == v
    elseif k == "id__@startswith"
        return startswith(row["id"], v)
    elseif k == "watchers__@contains"
        # Substring match on the serialized JSON, like the real backend.
        return occursin(v, row["watchers"])
    end
    # Unreachable: `_filtered_rows_locked` rejected every key not in `MODELLED_FILTER_KEYS`
    # before reaching here. Kept as the belt to that braces, so adding a key to the constant
    # without a branch here fails loudly.
    _reject_filter_key(k)
end

# `ORDER BY` then `LIMIT`, for the read ops. Sorting a fresh vector of live rows, never the table.
function _ordered_limited!(qs::MockTaskQuerySet, rows::Vector{Dict{String, Any}})
    order = getfield(qs, :order)
    if order !== nothing
        order == "id" || error("MockTaskQuerySet: unmodelled order_by '$order' -- teach the mock about it.")
        sort!(rows; by = r -> r["id"])
    end
    lim = getfield(qs, :limit)
    lim === nothing || length(rows) <= lim || resize!(rows, lim)
    return rows
end

# Rows handed OUT are snapshots. A live row stays readable field-by-field after the lock is
# dropped, while another thread's `update` writes it field-by-field -- a torn read inside
# `_from_db_record` that locking the table alone would not prevent.
#
# `copy` is shallow, and that is an exact snapshot ONLY because every column this mock stores is
# an immutable scalar (String, Float64, DateTime, nothing) -- `watchers` is the serialized JSON
# string, not a vector. Put a mutable value in a column and this quietly becomes an alias again.
_snapshot(row::Dict{String, Any}) = copy(row)

function _snapshot(qs::MockTaskQuerySet, row::Dict{String, Any})
    cols = getfield(qs, :projection)
    cols === nothing && return _snapshot(row)
    return Dict{String, Any}(c => row[c] for c in cols)
end

function Base.getproperty(qs::MockTaskQuerySet, name::Symbol)
    if name === :filter
        return function(args...)
            pairs = Pair{String, Any}[]
            for a in args
                if a isa Pair{String}
                    push!(pairs, a)
                elseif a isa PormG.SQLTypeQor
                    haskey(getfield(qs, :filters), MOCK_OR_KEY) &&
                        error("MockTaskQuerySet: only one Qor per query is modelled.")
                    push!(pairs, MOCK_OR_KEY => _mock_or_pairs(a))
                else
                    error("MockTaskQuerySet: unmodelled filter argument $(typeof(a)).")
                end
            end
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
    elseif name === :values
        return function(cols::String...)
            # Mutate-and-return-self, like `filter` and `db`.
            setfield!(qs, :projection, collect(String, cols))
            return qs
        end
    elseif name === :order_by
        return function(col::String)
            setfield!(qs, :order, col)          # last call wins, as in PormG
            return qs
        end
    elseif name === :limit
        return function(n::Int)
            setfield!(qs, :limit, n)
            return qs
        end
    elseif name === :list
        return function()
            return lock(_mock_lock(qs)) do
                Dict{String,Any}[_snapshot(qs, r) for r in _ordered_limited!(qs, _filtered_rows_locked(qs))]
            end
        end
    elseif name === :first
        return function()
            return lock(_mock_lock(qs)) do
                rows = _ordered_limited!(qs, _filtered_rows_locked(qs))
                isempty(rows) ? nothing : _snapshot(qs, first(rows))
            end
        end
    elseif name === :create
        return function(pairs::Pair{String,<:Any}...)
            row = Dict{String,Any}()
            for (k, v) in pairs
                row[k] = v
            end
            return lock(_mock_lock(qs)) do
                _selected_table(qs)[row["id"]] = row
                # A snapshot like every other read. The ext discards this return value, so
                # nothing observes the difference -- which is exactly why this should not be the
                # one method that leaks a live row out from under the lock.
                _snapshot(row)
            end
        end
    elseif name === :update
        return function(pairs::Pair{String,<:Any}...)
            # PormG refuses an unfiltered update outright (`UnsafeMutationError`). A store bug
            # that lost its `.filter(...)` and rewrote every row used to read as a pass here.
            isempty(getfield(qs, :filters)) &&
                error("MockTaskQuerySet: update() requires a filter -- refusing to update " *
                      "every row, as PormG does.")
            # Return the affected-row count, matching PormG's Django-style `update`.
            # It used to return `nothing`, which would make every compare-and-set in
            # the store read as a failure — or, worse, as an untested success.
            # The compare (`_filtered_rows_locked`) and the set (`row[k] = v`) happen in ONE
            # lock hold, because that is what an UPDATE ... WHERE is -- and it is the premise
            # `try_transition!` and `add_watcher!` build their compare-and-set on. Holding the
            # lock any WIDER than this would be wrong: the window between a store's read and its
            # update is the thing #88 and #108 exist to test.
            return lock(_mock_lock(qs)) do
                touched = 0
                for row in _filtered_rows_locked(qs)
                    for (k, v) in pairs
                        row[k] = v
                    end
                    touched += 1
                end
                touched
            end
        end
    elseif name === :delete
        # Bound to a local instead of returned directly: Julia 1.13's parser drops the
        # parameter block of a keyword-only `return function(; kw=default)` written inside
        # a `function ... end` body, lowering it to `function kw = default` and erroring
        # with `invalid assignment location`. 1.12 parses it fine. `f = function(; …)` then
        # `return f` parses correctly on both.
        delete_fn = function(; allow_delete_all::Bool=false)
            # PormG's real guard: an unfiltered delete throws unless opted into explicitly.
            (!allow_delete_all && isempty(getfield(qs, :filters))) &&
                error("MockTaskQuerySet: delete() must have a filter -- pass " *
                      "allow_delete_all = true to delete every row, as PormG requires.")
            # PormG's `UnsafeMutationError`: a paged delete is refused, not silently widened.
            (getfield(qs, :order) !== nothing || getfield(qs, :limit) !== nothing) &&
                error("MockTaskQuerySet: delete() refuses order_by/limit, as PormG does.")
            return lock(_mock_lock(qs)) do
                table = _selected_table(qs)
                count = 0
                for row in _filtered_rows_locked(qs)
                    delete!(table, row["id"])
                    count += 1
                end
                (count, Dict{String, Integer}("nitro_task" => count))
            end
        end
        return delete_fn
    else
        return getfield(qs, name)
    end
end

# Iterating a queryset is NOT supported, and saying so beats the plausible-looking
# implementation that used to be here. That one called `_filtered_rows` per STEP: it re-ran the
# whole filter for every element and appended a fresh `seen` entry for every element, so the
# exact-count `_filters_seen` assertions would have broken the moment anything used it. Nothing
# does -- the ext's two `for row in` sites iterate the Vectors `.list()` returns, and no test
# iterates a queryset. Fail loudly rather than look supported, exactly as this file already does
# for an unmodelled filter key.
Base.iterate(::MockTaskQuerySet, args...) =
    error("MockTaskQuerySet: a queryset is not iterable -- call `.list()` and iterate that. " *
          "A per-step re-filter would also append one `_filters_seen` entry per row.")

struct MockTaskModel
    mdb::MockDB
end

# Every connection this model may be queried on. A test that exercises routing names both
# (`MockTaskModel("db", "tasks")`); the no-argument form is the single connection every test
# that does not care about routing uses.
MockTaskModel(db_keys::String...) = MockTaskModel(MockDB(db_keys...))

function Base.getproperty(m::MockTaskModel, name::Symbol)
    if name === :objects
        # No connection selected yet -- exactly what PormG's `model.objects` hands back.
        # `.db(key)` is what picks one.
        return MockTaskQuerySet(getfield(m, :mdb), nothing, Dict{String,Any}())
    elseif name === :_table
        # The DEFAULT connection's table: what every assertion that does not care about
        # routing means, kept as an alias rather than rewritten at ~30 call sites.
        #
        # LIVE, not a snapshot -- `_tables` carries identity assertions and the routing testsets
        # write rows through it directly. So a direct read through these aliases is only valid
        # once the runtime is quiesced or the task under test has reached a terminal state. That
        # holds at every existing call site; preserve it when adding one, or go through
        # `.objects` and take the lock.
        return getfield(m, :mdb).tables["db"]
    elseif name === :_tables
        return getfield(m, :mdb).tables
    elseif name === :_filters_seen
        return getfield(m, :mdb).seen
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

    # Under the database lock, for two reasons. `fail_ids` is mutated by the test task while the
    # queue processor is live (see `fail_id!` below), so the membership test races it. And the
    # counted branch is a read-decide-decrement -- "exactly one read fails" is an assertion a
    # lost update would quietly break. This is a SEPARATE hold from the `inner.first()` that
    # follows, not a nested one: the guard models a failed connection, which is its own event
    # and not part of the read it precedes.
    lock(getfield(inner, :mdb).lock) do
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
    end
    return nothing
end

function Base.getproperty(qs::FlakyReadQuerySet, name::Symbol)
    inner = getfield(qs, :inner)
    fail_next = getfield(qs, :fail_next)
    fail_ids = getfield(qs, :fail_ids)

    if name === :db
        return (key::String) -> FlakyReadQuerySet(inner.db(key), fail_next, fail_ids)
    elseif name in (:filter, :values, :order_by, :limit)
        # Every chaining builder is re-wrapped. Falling through to `inner` would hand back the bare
        # queryset, and the `.list()` after a projection or a page would bypass the guard.
        return (args...) -> FlakyReadQuerySet(getproperty(inner, name)(args...), fail_next, fail_ids)
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
    mdb::MockDB
    # Assigned directly by the test task (`flaky.fail_next[] = 1`). That is safe WITHOUT the
    # lock only because every testset doing so is sequential -- nothing is in flight at that
    # point. `fail_ids` is the opposite case and has helpers below.
    fail_next::Ref{Int}
    fail_ids::Set{String}
end

FlakyReadModel(db_keys::String...) =
    FlakyReadModel(MockDB(db_keys...), Ref(0), Set{String}())

# The test-side writers to `fail_ids`. Guarding only the READ in `_flaky_guard` would be a
# no-op: these fire either side of a `timedwait` with a queued task in flight, so the `Set` is
# genuinely mutated while the processor is testing membership in it.
fail_id!(m::FlakyReadModel, id::String) =
    lock(() -> push!(getfield(m, :fail_ids), id), getfield(m, :mdb).lock)
unfail_id!(m::FlakyReadModel, id::String) =
    lock(() -> delete!(getfield(m, :fail_ids), id), getfield(m, :mdb).lock)

function Base.getproperty(m::FlakyReadModel, name::Symbol)
    if name === :objects
        return FlakyReadQuerySet(
            MockTaskQuerySet(getfield(m, :mdb), nothing, Dict{String,Any}()),
            getfield(m, :fail_next),
            getfield(m, :fail_ids),
        )
    elseif name === :_table
        return getfield(m, :mdb).tables["db"]
    elseif name === :_tables
        return getfield(m, :mdb).tables
    elseif name === :_filters_seen
        return getfield(m, :mdb).seen
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
        return (args...) -> RacingWatcherQuerySet(inner.filter(args...), inject_next, intruder)
    elseif name === :update
        return function(pairs::Pair{String,<:Any}...)
            # Only a watchers CAS is worth racing, and only once.
            is_watcher_cas = any(p -> first(p) == "watchers", pairs) &&
                             haskey(getfield(inner, :filters), "watchers")
            # Under the lock: this is the ONE other place a row is written, so leaving it out
            # would make "rows are only touched under the lock" false the day it lands, however
            # single-threaded this particular testset is.
            #
            # A SEPARATE hold from the `inner.update` below, deliberately. The intruder's write
            # is a different statement that lands FIRST -- that is the whole point -- and fusing
            # the two would make the CAS see its own injection and never take its retry.
            if is_watcher_cas
                lock(getfield(inner, :mdb).lock) do
                    # Read, decide and decrement in ONE hold -- the same read-modify-write
                    # `_flaky_guard` locks `fail_next` for. Testing the counter outside the hold
                    # and decrementing inside it would let two injections both pass the test and
                    # drive it to -1.
                    #
                    # Nested rather than an early `return`: inside a `do` block a `return` exits
                    # the closure, not `update`, so `inner.update` below still runs -- but that
                    # is exactly the Julia footgun a later rewrite of `lock(l) do ... end` into
                    # `lock(l); try ... finally unlock(l) end` would silently invert, skipping
                    # the CAS on every retry. Six lines nest for free; do not trade them back.
                    if inject_next[] > 0
                        inject_next[] -= 1
                        # The competing write lands first, so our compare value is now stale.
                        # `_selected_table`, not the raw tables dict: the intruder must land on
                        # the SAME connection the store is querying, or the CAS would never
                        # see it.
                        for row in values(_selected_table(inner))
                            current = JSON.parse(row["watchers"])
                            intruder in current && continue
                            row["watchers"] = JSON.json(vcat(current, intruder))
                        end
                    end
                end
            end
            return inner.update(pairs...)
        end
    end
    return getproperty(inner, name)
end

struct RacingWatcherModel
    mdb::MockDB
    inject_next::Ref{Int}
    intruder::String
end

RacingWatcherModel(table::Dict{String, Dict{String, Any}}, inject_next::Ref{Int}, intruder::String) =
    RacingWatcherModel(
        MockDB(Dict{String, Dict{String, Dict{String, Any}}}("db" => table),
               Dict{String, Any}[], ReentrantLock()),
        inject_next, intruder)

function Base.getproperty(m::RacingWatcherModel, name::Symbol)
    if name === :objects
        return RacingWatcherQuerySet(
            MockTaskQuerySet(getfield(m, :mdb), nothing, Dict{String,Any}()),
            getfield(m, :inject_next),
            getfield(m, :intruder),
        )
    elseif name === :_table
        return getfield(m, :mdb).tables["db"]
    elseif name === :_tables
        return getfield(m, :mdb).tables
    elseif name === :_filters_seen
        return getfield(m, :mdb).seen
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

# -- A stand-in PormG connection, for `pormg_nitro_worker` and the #202 guard ------
#
# Mirrors `FakeSessionPool` in `pormg_session_tests.jl`; see the rationale there.
# `PormG.connection(key=k)` is just `config[k].connections`, `config` is a
# `Dict{String,PormGSettings}` and `PormGSettings` is an ABSTRACT type, so an entry under a
# test-only key is enough. Subtyping `PormG.PormGSQLite` rather than using a bare struct means
# the REAL `create_table`/`create_index` run against the REAL task model; only `fetch` is
# overridden, and on our own concrete type, so it is more specific than PormG's method rather
# than piracy.
struct FakeTaskPool <: PormG.PormGSQLite
    sql::Vector{String}
end

struct FakeTaskSettings <: PormG.PormGSettings
    connections::FakeTaskPool
end

PormG.ConnectionPool.fetch(c::FakeTaskPool, sql::String; kwargs...) =
    (push!(c.sql, sql); nothing)

# The extension module itself, for the private `task_model` accessor the #202 guard drives.
const PormGExt = Base.get_extension(Nitro, :NitroPormGExt)

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

            # ...and the sweep got there by ASKING for that, not by the rows happening to
            # line up. Checking only the survivors cannot tell a correct three-part
            # predicate from a `delete` that lost one of its legs and was rescued by the
            # fixture (#208).
            pruned = filter(f -> haskey(f, "completed_at__@lte"), store2.model._filters_seen)
            @test !isempty(pruned)
            @test all(f -> haskey(f, "status__@in"), pruned)
            @test all(f -> haskey(f, "completed_at__@isnull") && f["completed_at__@isnull"] == false,
                      pruned)
            # Stringified, as `cleanup_tasks!` builds them -- and terminal statuses only,
            # which is the leg that keeps a RUNNING row with an old `completed_at` alive.
            @test all(f -> Set(f["status__@in"]) ==
                           Set(string.((COMPLETED, FAILED, CANCELLED))), pruned)
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

            # The narrowing query carried both legs, with the exact spellings the docstring
            # on `_authority_rows` promises: the `::`-terminated id prefix, and the
            # JSON-QUOTED watcher id. Row assertions alone cannot see either -- `"bob"`
            # unquoted would still return the right rows here and match `["bobby"]` in
            # production (#208).
            seen3 = store3.model._filters_seen
            @test any(f -> Base.get(f, "id__@startswith", nothing) == "user-a::", seen3)
            @test any(f -> Base.get(f, "watchers__@contains", nothing) == "\"user-a\"", seen3)
            # `System()` narrows nothing: its leg is a bare `.list()`.
            @test any(isempty, seen3)
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

                # The fence and the status precondition rode the SAME filter -- the whole
                # point of #108 is that they are one statement, not a read then a write.
                # A row assertion cannot distinguish that from a `run_id` term dropped
                # against a single-run fixture (#208).
                fenced = filter(f -> haskey(f, "run_id"), store_t.model._filters_seen)
                @test !isempty(fenced)
                @test all(f -> haskey(f, "status__@in") && haskey(f, "id"), fenced)
                @test all(f -> f["run_id"] == string(t.run_id), fenced)
                # `run_id=nothing` is the named opt-out: it omits the term rather than
                # filtering on a missing value.
                @test any(f -> haskey(f, "status__@in") && !haskey(f, "run_id"),
                          store_t.model._filters_seen)
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

        @testset "zombie recovery reads a projection, so a malformed blob cannot blind it (#236)" begin
            m = MockTaskModel()
            store_b = RealPormGWorkerStore(model=m)
            rt_b = WorkerRuntime(store_b)

            for id in ("alice::good", "alice::bad")
                t = TaskInfo(id)
                push!(t.watchers, "alice")
                t.status = RUNNING
                replace_task!(store_b, id, t)
            end
            bad_run = get_task_info(store_b, "alice::bad").run_id
            # Corrupt both blobs the full deserializer parses, behind the store's back -- the
            # way an app-side write or a hand edit would leave them. Direct table access is safe
            # here: nothing is in flight.
            m._table["alice::bad"]["result"] = "{not json"
            m._table["alice::bad"]["watchers"] = "also not json"

            # The listing parses every row. It used to swallow the one that failed into an EMPTY
            # result, so a sweep built on it saw no candidates at all -- the good zombie stranded
            # alongside the bad one. It now drops only that row (#267), and the sweep below still
            # does not depend on it: a skipped row is a zombie the listing cannot see.
            listed = @test_logs (:warn, r"does not decode") match_mode=:any get_all_tasks(store_b, System(); status=RUNNING)
            @test [t.id for t in listed] == ["alice::good"]

            refs = list_running_task_refs(store_b)
            @test refs isa Vector{RunningTaskRef}
            @test sort([r.id for r in refs]) == ["alice::bad", "alice::good"]
            @test only(filter(r -> r.id == "alice::bad", refs)).run_id == bad_run

            @test recover_zombie_tasks!(; runtime=rt_b) == 2
            @test m._table["alice::good"]["status"] == "FAILED"
            @test m._table["alice::bad"]["status"] == "FAILED"
        end

        @testset "a RUNNING row whose run_id does not parse is skipped, not guessed at (#236)" begin
            m = MockTaskModel()
            store_u = RealPormGWorkerStore(model=m)
            t = TaskInfo("alice::unfenceable")
            t.status = RUNNING
            replace_task!(store_u, t.id, t)
            m._table[t.id]["run_id"] = "not-a-uuid"

            refs = @test_logs (:warn, r"run_id does not parse") list_running_task_refs(store_u)
            @test isempty(refs)

            # An unreadable start time is not a reason to skip -- the row can still be fenced --
            # and certainly not a reason to fail the scan, which would stop the sweep there on
            # every boot. It reads as unstamped.
            t2 = TaskInfo("alice::garbled-start")
            t2.status = RUNNING
            replace_task!(store_u, t2.id, t2)
            m._table[t2.id]["started_at"] = "not a timestamp"
            refs = @test_logs (:warn, r"run_id does not parse") (:warn, r"started_at does not parse") match_mode=:any list_running_task_refs(store_u)
            @test only(refs).id == t2.id
            @test only(refs).started_at === nothing
        end

        @testset "a failed recovery read is logged and costs the sweep, not the boot (#236)" begin
            flaky = FlakyReadModel()
            store_f = RealPormGWorkerStore(model=flaky)
            rt_f = WorkerRuntime(store_f)
            t = TaskInfo("alice::stranded")
            t.status = RUNNING
            replace_task!(store_f, t.id, t)

            flaky.fail_next[] = 1
            # The listing used to swallow this into "no candidates", indistinguishable from a
            # clean sweep. It now surfaces as an @error, and startup still carries on.
            recovered = @test_logs (:warn, r"failed to list running tasks") (:error, r"zombie recovery could not read") match_mode=:any recover_zombie_tasks!(; runtime=rt_f)
            @test recovered == 0
            @test flaky._table[t.id]["status"] == "RUNNING"

            # The failure was transient, so the next sweep recovers it.
            @test recover_zombie_tasks!(; runtime=rt_f) == 1
        end

        # Walk a paged listing to the end, the way the public docstring tells an app to.
        function _walk_pages(fetch::Function, limit::Int)
            ids, pages, after = String[], Vector{String}[], nothing
            while true
                page = [t.id for t in fetch(after, limit)]
                push!(pages, page)
                append!(ids, page)
                (isempty(page) || length(page) < limit) && return ids, pages
                after = last(page)
            end
        end

        @testset "a paged Owner listing is the complete union, in id order (#237)" begin
            m = MockTaskModel()
            store_o = RealPormGWorkerStore(model=m)
            # Interleaved by id so that owned-only, watched-only and both-legs rows alternate:
            # '-' < ':' < '~' in codepoint order. A per-leg LIMIT merged in Julia is the shape
            # #237 warned about, and it drops rows exactly when the two legs interleave like this.
            rows = [
                ("a-global",  String["alice"]),          # watched only (a :global key)
                ("alice::1",  String["alice"]),          # both legs
                ("alice::2",  String[]),                 # owned only (grant list lost)
                ("alice~w",   String["carol", "alice"]), # watched only
                # FETCHED but not authorized: its one watcher serializes to `["x\",\"alice"]`,
                # which contains `"alice"`, so the SQL superset matches and the gate drops it.
                # A page it lands on must be topped up from past the cursor, not returned short --
                # a short page reads as the end, and would hide everything after it.
                ("b-decoy",   String["x\",\"alice"]),
                ("bob::1",    String["bob"]),            # neither: must never appear
                ("c-global",  String["alice"]),          # watched only
            ]
            for (id, watchers) in rows
                t = TaskInfo(id)
                append!(t.watchers, watchers)
                replace_task!(store_o, id, t)
            end
            expected = ["a-global", "alice::1", "alice::2", "alice~w", "c-global"]

            unpaged = [t.id for t in get_all_tasks(store_o, Owner("alice"))]
            @test sort(unpaged) == expected

            for limit in (1, 2, 3, 10)
                ids, pages = _walk_pages((after, n) -> get_all_tasks(store_o, Owner("alice"); after, limit=n), limit)
                @test ids == expected
                @test all(p -> length(p) <= limit, pages)
            end

            # ONE query per page, carrying the union as a Qor and the cursor as `id > after`, not
            # the unpaged path's two legs.
            empty!(m._filters_seen)
            get_all_tasks(store_o, Owner("alice"); after="alice::1", limit=2)
            @test length(m._filters_seen) == 1
            @test haskey(only(m._filters_seen), MOCK_OR_KEY)
            @test only(m._filters_seen)["id__@gt"] == "alice::1"
        end

        @testset "a paged System listing round-trips with its filters (#237)" begin
            store_s = RealPormGWorkerStore(model=MockTaskModel())
            for i in 1:7
                t = TaskInfo("sys::$i")
                t.status = isodd(i) ? RUNNING : PENDING
                replace_task!(store_s, t.id, t)
            end
            ids, _ = _walk_pages((after, n) -> get_all_tasks(store_s, System(); status=RUNNING, after, limit=n), 2)
            @test ids == ["sys::1", "sys::3", "sys::5", "sys::7"]
            @test_throws ArgumentError get_all_tasks(store_s, System(); limit=0)
        end

        @testset "a page the recovery scan skips a row from is topped up, not cut short (#237)" begin
            m = MockTaskModel()
            store_k = RealPormGWorkerStore(model=m)
            for i in 1:4
                t = TaskInfo("k::$i")
                t.status = RUNNING
                replace_task!(store_k, t.id, t)
            end
            m._table["k::2"]["run_id"] = "not-a-uuid"

            # A short page means "nothing left", so the skipped row has to be made up from past
            # the cursor. Otherwise the sweep would stop at k::3 and strand k::4.
            page = @test_logs (:warn, r"run_id does not parse") list_running_task_refs(store_k; limit=2)
            @test [r.id for r in page] == ["k::1", "k::3"]
            rest = list_running_task_refs(store_k; after="k::3", limit=2)
            @test [r.id for r in rest] == ["k::4"]
        end

        # Everything `f` logged, rendered by a real logger. `SimpleLogger` prints an `exception=`
        # kwarg with `show`, which includes the exception's message string. A leak assertion has
        # to read the RENDERED text, because what reaches the operator's log is the defect, not
        # what the record holds.
        function _rendered_logs(f::Function)
            io = IOBuffer()
            value = Base.CoreLogging.with_logger(f, Base.CoreLogging.SimpleLogger(io, Base.CoreLogging.Debug))
            return String(take!(io)), value
        end

        @testset "one undecodable row is skipped, not the whole listing (#267)" begin
            m = MockTaskModel()
            store_d = RealPormGWorkerStore(model=m)
            for id in ("alice::1", "alice::2", "alice::3", "alice::4")
                t = TaskInfo(id)
                push!(t.watchers, "alice")
                replace_task!(store_d, id, t)
            end
            # A JSON parse error quotes a window of text from just before the failure position, so
            # the secret IS the unparseable token: the window then carries all of it. Placed a few
            # bytes further on, only a fragment is quoted and the assertion below passes against
            # the leaking code -- that is how this test was first written.
            m._table["alice::2"]["result"] = "{\"token\": sk_SECRET_267}"
            # A bad watcher blob on a row alice owns. Ownership alone would authorize her, so
            # this pins the skip, not the gate.
            m._table["alice::4"]["watchers"] = "not json"
            # A row the gate genuinely cannot decide: bob owns it, and its truncated watcher blob
            # still CONTAINS `"alice"`, so alice's SQL superset fetches it. With no parseable
            # watcher list it must be dropped before the gate, never waved through it.
            t_bob = TaskInfo("bob::grant")
            push!(t_bob.watchers, "bob")
            replace_task!(store_d, t_bob.id, t_bob)
            m._table["bob::grant"]["watchers"] = "[\"bob\", \"alice\""

            for authority in (System(), Owner("alice"))
                logs, listed = _rendered_logs(() -> get_all_tasks(store_d, authority))
                @test sort([t.id for t in listed]) == ["alice::1", "alice::3"]
                @test occursin("does not decode", logs)
                @test occursin("alice::2", logs)
                @test !occursin("SECRET", logs)
            end

            # A paged walk crosses the bad rows rather than stopping at them: a skipped row is
            # made up from past the cursor, so no page comes back short before the end.
            for limit in (1, 2, 10)
                logs, (ids, _) = _rendered_logs(() -> _walk_pages((after, n) -> get_all_tasks(store_d, System(); after, limit=n), limit))
                @test ids == ["alice::1", "alice::3"]
                @test !occursin("SECRET", logs)
            end

            # A single-row read has nothing to skip to, so it still throws, and its warning is
            # held to the same rule. So is the exception itself: `get_task_info` rethrows, and a
            # request handler's error logger (`src/utilities/misc.jl`) prints the message in full.
            # The value-free error must also not carry JSON.jl's original as its cause on the
            # exception stack, which an uncaught task failure prints.
            thrown, stack_depth = nothing, 0
            logs, _ = _rendered_logs() do
                try
                    get_task_info(store_d, "alice::2")
                catch e
                    thrown, stack_depth = e, length(Base.current_exceptions())
                end
            end
            @test thrown isa ErrorException
            @test occursin("alice::2", thrown.msg) && occursin("`result`", thrown.msg)
            @test !occursin("SECRET", sprint(showerror, thrown))
            @test stack_depth == 1
            @test occursin("alice::2", logs)
            @test !occursin("SECRET", logs)

            # Same for the watcher blob, which is parsed and then shaped.
            _, thrown_w = _rendered_logs(() -> try get_task_info(store_d, "alice::4") catch e; e end)
            @test thrown_w isa ErrorException && occursin("`watchers`", thrown_w.msg)
        end

        @testset "an unpaged listing rethrows a failed read instead of reporting none (#267)" begin
            flaky = FlakyReadModel()
            store_f = RealPormGWorkerStore(model=flaky)
            t = TaskInfo("alice::kept")
            push!(t.watchers, "alice")
            replace_task!(store_f, t.id, t)

            # An empty listing means "no tasks". A read that failed must not say that.
            for authority in (System(), Owner("alice"))
                flaky.fail_next[] = 1
                logs, _ = _rendered_logs() do
                    @test_throws "simulated transient database read failure" get_all_tasks(store_f, authority)
                end
                @test occursin("failed to list tasks", logs)
                # The failure was transient, so the next listing is whole.
                @test [x.id for x in get_all_tasks(store_f, authority)] == ["alice::kept"]
            end
        end

        @testset "schema drift still fails a listing loudly, not row by row (#267)" begin
            m = MockTaskModel()
            store_old = RealPormGWorkerStore(model=m)
            t = TaskInfo("alice::old")
            push!(t.watchers, "alice")
            replace_task!(store_old, t.id, t)
            # A table missing the column is table-wide. Skipping every row over it would
            # rebuild the empty listing #267 removed, one warning per row.
            delete!(m._table["alice::old"], "run_id")
            _rendered_logs() do
                @test_throws r"predates #108" get_all_tasks(store_old, System())
                @test_throws r"predates #108" get_all_tasks(store_old, System(); limit=10)
            end
        end

        @testset "recovery walks the backlog in batches and spares a live run (#237)" begin
            m = MockTaskModel()
            store_r = RealPormGWorkerStore(model=m)
            rt_r = WorkerRuntime(store_r)
            for i in 1:5
                t = TaskInfo("z::$i")
                t.status = RUNNING
                replace_task!(store_r, t.id, t)
            end
            live = @async sleep(0.05)
            Nitro.Workers.register_active_task!(rt_r, "z::3", live)
            try
                empty!(m._filters_seen)
                @test recover_zombie_tasks!(; runtime=rt_r, batch_size=2) == 4
                @test m._table["z::3"]["status"] == "RUNNING"
                @test all(m._table["z::$i"]["status"] == "FAILED" for i in (1, 2, 4, 5))
                # Paged: the scan ran more than once, and every read after the first carried a cursor.
                scans = filter(f -> Base.get(f, "status", nothing) == "RUNNING", m._filters_seen)
                @test length(scans) == 3
                @test !haskey(first(scans), "id__@gt")
                @test all(haskey(f, "id__@gt") for f in scans[2:end])
            finally
                wait(live)
                reset_runtime!(rt_r)
            end
        end

        @testset "zombie_min_age adjudicates only claims old enough to be dead (#239)" begin
            for (label, backend) in (("in-memory", InMemoryWorkerStore()),
                                     ("pormg", RealPormGWorkerStore(model=MockTaskModel())))
                @testset "$label" begin
                    now_utc = Dates.now(Dates.UTC)
                    for (id, started) in (("age::old", now_utc - Hour(3)),
                                          ("age::young", now_utc - Minute(1)),
                                          ("age::unstamped", nothing))
                        t = TaskInfo(id)
                        t.status = RUNNING
                        t.started_at = started
                        replace_task!(backend, id, t)
                    end
                    status_of(id) = get_task_info(backend, id).status

                    # Through `start!`, so the keyword is plumbed and not merely accepted. Only
                    # the old claim, and the one nothing shows is recent, are adjudicated: a node
                    # booting beside a peer's hour-long run no longer declares it dead.
                    app = Nitro.Core.App()
                    rt = start!(app; store=backend, zombie_min_age=Hour(1), cleanup_enabled=false)
                    try
                        @test status_of("age::old") == FAILED
                        @test status_of("age::unstamped") == FAILED
                        @test status_of("age::young") == RUNNING

                        # The default bounds nothing, exactly as before #239.
                        @test recover_zombie_tasks!(; runtime=rt) == 1
                        @test status_of("age::young") == FAILED
                    finally
                        reset_runtime!(rt)
                    end
                end
            end

            # A claim's age is only as honest as the timestamp it is read from. PostgreSQL hands
            # back a `ZonedDateTime` in the SESSION's zone, and the parser used to copy its
            # wall-clock fields and drop the offset -- so under `PGTZ=America/Sao_Paulo` every
            # `started_at` read three hours OLDER than it was, and a peer's minute-old claim cleared
            # a two-hour bound. Exactly the false positive `zombie_min_age` exists to prevent.
            brt = FixedTimeZone("BRT", -3 * 3600)
            parse_db = getproperty(PormGExt, :_parse_db_datetime)
            @test parse_db(ZonedDateTime(DateTime(2026, 1, 1, 13, 0, 0), brt; from_utc=true)) ==
                  DateTime(2026, 1, 1, 13, 0, 0)

            m = MockTaskModel()
            store_tz = RealPormGWorkerStore(model=m)
            t = TaskInfo("tz::young")
            t.status = RUNNING
            replace_task!(store_tz, t.id, t)
            just_now = Dates.now(Dates.UTC) - Minute(1)
            m._table[t.id]["started_at"] = ZonedDateTime(just_now, brt; from_utc=true)
            rt_tz = WorkerRuntime(store_tz)
            @test recover_zombie_tasks!(; runtime=rt_tz, zombie_min_age=Hour(2)) == 0
            @test m._table[t.id]["status"] == "RUNNING"

            @test_throws ArgumentError recover_zombie_tasks!(; runtime=WorkerRuntime(InMemoryWorkerStore()),
                                                              zombie_min_age=Hour(-1))
            # Refused where the middleware is built, not later from the startup hook.
            @test_throws ArgumentError Nitro.Workers.startup(Nitro.Core.App(); zombie_min_age=Minute(-5))
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
                ok = _settled(() -> get_task_status(owner_id, Owner("victim"); runtime=rt_store_e2e)[:status] == "COMPLETED")
                @test ok

                # Everything below is about the TERMINAL record, so it is all downstream of the
                # poll above. This is the exact cascade CI reported on #226.
                if ok
                    # Terminal state: replacing the row would destroy the owner's result.
                    @test_throws AuthorizationError submit_task("shared-export", () -> begin
                        attacker_calls[] += 1
                        return "attacker-data"
                    end, Owner("attacker"); scope=:global, runtime=rt_store_e2e)

                    persisted = get_task_status(owner_id, Owner("victim"); runtime=rt_store_e2e)
                    @test persisted[:result] == "victim-secret"
                    @test persisted[:watcher_count] == 1
                    @test attacker_calls[] == 0
                end

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
                capped_ok = _settled(() -> get_task_status(capped_id, owner; runtime=rt_store_err)[:status] == "FAILED")
                @test capped_ok

                # The row exists either way -- `_register_or_watch!` writes it synchronously
                # inside `submit_task` -- so a timeout here does not raise, it just leaves
                # `error` empty and fails all three assertions below for one reason (#226).
                if capped_ok
                    column = store_err.model._table[capped_id]["error"]
                    @test length(column) <= MAX_STORED_ERROR_CHARS + 64
                    @test isvalid(column)
                    @test occursin("truncated", column)
                end

                set_error_redactor!(store_err, (exc, rendered) -> string(nameof(typeof(exc))))
                redacted_id = submit_task("redacted", () -> throw(ArgumentError("bad token: $(sentinel)")), owner; runtime=rt_store_err)
                redacted_ok = _settled(() -> get_task_status(redacted_id, owner; runtime=rt_store_err)[:status] == "FAILED")
                @test redacted_ok

                # POSITIVE first: the sentinel really is in the raw rendering, so the negative
                # assertion below is not passing for the wrong reason. This one is about
                # `format_error` alone, so it is NOT downstream of the poll and stays outside
                # the guard -- a timeout must not silently take the positive control with it.
                @test occursin(sentinel, format_error(ArgumentError("bad token: $(sentinel)")))
                # NEGATIVE: and it never reaches the column.
                if redacted_ok
                    @test store_err.model._table[redacted_id]["error"] == "ArgumentError"
                    @test !occursin(sentinel, store_err.model._table[redacted_id]["error"])
                end
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
                fail_id!(flaky, second_id)
                notify(gate)

                @test timedwait(() -> get_task_status(first_id, Owner("u"); runtime=rt_store_q)[:status] == "COMPLETED", 5.0) == :ok

                # k2 is dropped, but the processor must still be alive and draining.
                queue = get_sequential_queues(rt_store_q)["qfail"]
                @test queue.processor_task !== nothing
                @test !istaskdone(queue.processor_task)

                unfail_id!(flaky, second_id)
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

        @testset "the mock database is serialized, so concurrent queries cannot lose a write (#226)" begin
            # The guard for #226. `PormGWorkerStore` leaves its data methods unlocked because a
            # real database makes each statement atomic; this mock is what stands in for that
            # database in every testset above, and it used to offer no such guarantee. At `-t 2`
            # the worker task and the polling loop genuinely interleaved inside it, and a
            # different subset of this file failed on each run.
            #
            # The assertions are chosen to be TRUE and cheap at one thread and only VIOLABLE at
            # two. Be precise about that: at `-t 1` Julia's tasks are cooperative and none of
            # `create`/`first`/`update` yields, so the racers run strictly serially and this
            # testset is UNFALSIFIABLE there rather than merely passing. CI runs both legs; the
            # `-t 2` leg is the one holding this. `seen` gains one entry per filtering op, so
            # the total is `ntasks * nops * 2` whatever the interleaving; the id set and the
            # final statuses are likewise interleaving-independent. Against the unlocked mock at
            # `-t 2` the `seen` vector either threw `ConcurrencyViolationError` on a concurrent
            # resize or came back short, and the table lost rows to a concurrent rehash.
            #
            # Deliberately NOT asserted: the ORDER of `seen`, which rows a concurrent `.list()`
            # returned, or anything about timing. None of those is a property the lock
            # guarantees, so each would be the next flake rather than a regression guard.
            #
            # Driven against `MockTaskModel` directly, not through a store, so a failure names
            # the mock rather than the ext.
            ntasks, nops = 4, 40
            expected_ids = Set("t$t-op$i" for t in 1:ntasks for i in 1:nops)

            for _ in 1:8
                m = MockTaskModel()
                barrier = Base.Event()
                racers = map(1:ntasks) do t
                    Threads.@spawn begin
                        wait(barrier)   # maximise the overlap rather than hope for it
                        for i in 1:nops
                            id = "t$t-op$i"
                            m.objects.db("db").create(
                                "id" => id, "run_id" => "run-$t", "status" => "PENDING",
                                "progress" => 0.0, "result" => "", "error" => "",
                                "created_at" => nothing, "started_at" => nothing,
                                "completed_at" => nothing, "watchers" => "[]",
                                "queue_name" => "default")
                            m.objects.db("db").filter("id" => id).first()
                            m.objects.db("db").filter("id" => id).update("status" => "RUNNING")
                        end
                    end
                end
                notify(barrier)
                foreach(wait, racers)

                # `create` records no filter; `first` and `update` record exactly one each.
                @test length(m._filters_seen) == ntasks * nops * 2
                @test Set(keys(m._table)) == expected_ids
                # Every row was updated by the one task that owns it, so a lost write shows.
                @test all(r -> r["status"] == "RUNNING", values(m._table))
            end
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

            # update
            info.status = RUNNING
            set_task!(store_r, info.id, info)
            @test m._tables["tasks"]["alice::routed"]["status"] == "RUNNING"
            @test m._tables["db"]["alice::routed"]["status"] == "COMPLETED"

            # watcher CAS -- assert the CAS itself won, or a `false` return that still left
            # "bob" on the row would read as a pass.
            @test add_watcher!(store_r, "alice::routed", "bob") == true
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

            # The routed sweep still carried all three legs. `cleanup_tasks!` swallows its
            # own exceptions (`@warn` + `return 0`), so a mock complaint here would surface
            # only as a wrong count -- the recorded filter is what says the predicate was
            # right rather than merely survivable (#208).
            @test any(f -> haskey(f, "completed_at__@lte") && haskey(f, "status__@in") &&
                           haskey(f, "completed_at__@isnull"), m._filters_seen)
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

        @testset "the mock refuses what PormG refuses (#208)" begin
            # The guard that makes this file able to detect the next #180. Driven through
            # `m.objects` directly, never through a store method: `cleanup_tasks!` and
            # `get_task_info` wrap their queries in `try`/`catch` blocks that WARN AND
            # SWALLOW, so a store-level call would hide exactly the complaint under test.
            m = MockTaskModel()

            # 1. `@`-less operator spellings. PormG accepts only the `@` form; the mock used
            #    to treat the bare one as an alias, so a store change that dropped an `@`
            #    stayed green here and matched nothing against a database.
            @test_throws "missing PormG's `@` operator prefix" m.objects.db("db").filter(
                "completed_at__lte" => now(UTC)).list()
            @test_throws "missing PormG's `@` operator prefix" m.objects.db("db").filter(
                "id__startswith" => "alice::").list()
            @test_throws "missing PormG's `@` operator prefix" m.objects.db("db").filter(
                "watchers__contains" => "\"alice\"").list()
            @test_throws "unmodelled filter key" m.objects.db("db").filter("nonsense" => 1).first()

            # 2. The check runs on an EMPTY table. Inside the row loop -- where it started --
            #    the guard vanishes exactly when the sweep has been working.
            @test isempty(m._tables["db"])

            # ...and it does not short-circuit past a later bad key when an earlier one
            # would not have matched.
            @test_throws "unmodelled filter key" m.objects.db("db").filter(
                "id" => "no-such-row", "nonsense" => 1).list()

            # 3. Unfiltered mutation. PormG refuses both; `delete` has one named hatch.
            m._tables["db"]["doomed"] = Dict{String,Any}(
                "id" => "doomed", "run_id" => "", "status" => "COMPLETED",
                "progress" => 100.0, "result" => "", "error" => "",
                "created_at" => now(UTC), "started_at" => nothing, "completed_at" => now(UTC),
                "watchers" => "[]", "queue_name" => "default",
            )
            @test_throws "requires a filter" m.objects.db("db").update("status" => "FAILED")
            @test_throws "must have a filter" m.objects.db("db").delete()
            @test m._tables["db"]["doomed"]["status"] == "COMPLETED"   # nothing was written

            # The hatch, so the guard is pinned as a guard rather than as "delete never
            # works without a filter".
            @test m.objects.db("db").delete(allow_delete_all=true) ==
                  (1, Dict{String,Integer}("nitro_task" => 1))
            @test isempty(m._tables["db"])

            # 4. Filter recording is shared across a chain and across querysets.
            m2 = MockTaskModel()
            m2.objects.db("db").filter("id" => "a").filter("status" => "PENDING").list()
            m2.objects.db("db").filter("queue_name" => "reports").list()
            @test length(m2._filters_seen) == 2
            @test m2._filters_seen[1] == Dict{String,Any}("id" => "a", "status" => "PENDING")
            @test m2._filters_seen[2] == Dict{String,Any}("queue_name" => "reports")
            # A copy, not the live dict: a later `.filter` on the same queryset must not
            # rewrite what an earlier query was recorded as having run with.
            qs = m2.objects.db("db").filter("id" => "b")
            qs.list()
            qs.filter("status" => "RUNNING").list()
            @test m2._filters_seen[3] == Dict{String,Any}("id" => "b")
        end

        @testset "the task model is BOUND to its store's connection (#202)" begin
            # `_define_task_model()` used to build a bare `PormG.Models.Model` that never went
            # through `set_models`, so `connect_key` was `nothing`. PormG's
            # `ensure_model_transaction_scope` gates on the MODEL's key and never consults the
            # query's `.db()` override, so while any transaction was open on the calling task
            # EVERY `nitro_task` query threw `InvalidConfigurationError` -- `submit_task` inside
            # an app's own `run_in_transaction` block, for instance.
            #
            # Mirrors the session-side guard in `pormg_session_tests.jl`; the two stores had the
            # identical gap and #202 closes both.
            @test getproperty(PormGExt, :task_model)().connect_key == "db"
            @test getproperty(PormGExt, :task_model)("tasks").connect_key == "tasks"

            # One model per store, never a shared singleton -- `connect_key` names exactly one
            # connection, so two stores on different keys could not share an object.
            @test getproperty(PormGExt, :task_model)() !== getproperty(PormGExt, :task_model)()

            key = "nitro-test-task-tx"
            haskey(PormG.config, key) &&
                error("test-only PormG connection key is already registered: $key")
            conn = FakeTaskPool(String[])
            PormG.config[key] = FakeTaskSettings(conn)
            try
                bound = getproperty(PormGExt, :task_model)(key)
                unbound = getproperty(PormGExt, :task_model)(key)
                unbound.connect_key = nothing

                # Outside a transaction the guard returns immediately for both -- which is
                # precisely why this defect never showed up in the suite.
                @test PormG.Configuration.ensure_model_transaction_scope(unbound) === nothing
                @test PormG.Configuration.ensure_model_transaction_scope(bound) === nothing

                # `with_tx_context` is PormG's own seam onto the `ScopedValue` that
                # `run_in_transaction` sets, so the guard runs without a live driver.
                PormG.with_tx_context(conn, nothing) do
                    @test_throws PormG.Kernel.InvalidConfigurationError PormG.Configuration.ensure_model_transaction_scope(unbound)
                    @test PormG.Configuration.ensure_model_transaction_scope(bound) === nothing
                end

                # And the factory hands the store a model bound to the key it was asked for.
                store_b = pormg_nitro_worker(db_key=key)
                @test store_b.db_key == key
                @test store_b.model.connect_key == key
            finally
                delete!(PormG.config, key)
            end
            @test !haskey(PormG.config, key)

            # The constructor's OWN model-building branch. Every other store in this file
            # passes `model=`, and both factories build the model themselves and pass it in
            # too, so without this the `isnothing(model)` arm of `PormGWorkerStore` has no
            # coverage at all -- regressing it to `task_model()` would leave a store at
            # `db_key="tasks"` carrying a model bound to `"db"` and the suite would stay green.
            # Neither constructor touches `PormG.config`, so no fixture is needed.
            @test RealPormGWorkerStore(db_key="tasks").model.connect_key == "tasks"
            @test RealPormGWorkerStore().model.connect_key == "db"
        end

        @testset "a run does not inherit the submitter's PormG transaction (#209)" begin
            # The store-side half of the scope detach. `test/workers_tests.jl` proves the
            # mechanism against a plain `ScopedValue`; this proves it against the actual value
            # the hazard is about -- PormG's `_tx_context`, reached through its own public
            # `with_tx_context` seam, so no live driver is needed.
            #
            # Before #209 the spawned run inherited this context, so `_claim_run!`'s durable
            # read and the run-start CAS -- both BEFORE any callback code -- resolved onto the
            # submitter's transaction connection, and kept writing on it after the block
            # committed and returned it to the pool.
            store_tx = RealPormGWorkerStore(model=MockTaskModel())
            rt_tx = WorkerRuntime(store_tx)
            conn = FakeTaskPool(String[])
            seen = Channel{Tuple{Bool, Int}}(1)
            try
                PormG.with_tx_context(conn, nothing) do
                    # The submitter really is inside a transaction...
                    @test PormG.Configuration.in_transaction_context() == true
                    @test PormG.Configuration.current_transaction_depth() == 1

                    submit_task("tx-scope", () -> begin
                        put!(seen, (PormG.Configuration.in_transaction_context(),
                                    PormG.Configuration.current_transaction_depth()))
                        return "done"
                    end, Owner("user-tx"); runtime=rt_tx)
                end

                @test timedwait(() -> isready(seen), 5.0) == :ok
                in_tx, depth = take!(seen)
                # ...and the run it spawned is not.
                @test in_tx == false
                @test depth == 0
            finally
                reset_runtime!(rt_tx)
            end
        end
    end
end

end
