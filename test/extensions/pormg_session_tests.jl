@testitem "PormG session store" tags=[:extension, :pormg] setup=[NitroCommon] begin

using Test
using Dates
using JSON
using TimeZones
using Nitro

# These tests exercise the real `NitroPormGExt.PormGSessionStore`. The mock below replaces
# only the database layer; every store method comes from `ext/NitroPormGExt.jl`.
#
# This file used to define a local `TestPormGSessionStore` REPLICA of the store and test that
# instead, which is why `cleanup_expired_sessions!` shipped with zero coverage and the replica
# drifted from the shipped code on four axes at once (#180): the filter operator, the row key
# style, the error handling, and the datetime parsing. A replica cannot catch a defect in the
# thing it is a replica of -- it can only agree with itself.

using Nitro.Types: AbstractSessionStore, SessionPayload, get_session, set_session!,
                   update_session!, rotate_session!, delete_session!, cleanup_expired_sessions!, is_expired,
                   missing_session_methods

# ── Mock PormG row ───────────────────────────────────────────────────────
#
# PormG hands back a `PormGRow`, not a `Dict`: its storage is `Dict{Symbol,Any}` and it accepts
# `row[:col]`, `row["col"]` and `row.col` alike. `PormGSessionStore` indexes with SYMBOLS
# (`result[:expires_at]`, `ext/NitroPormGExt.jl`), so the string-keyed `Dict` rows this file used
# to hand it could never have driven the shipped store at all. Both INDEXING forms are modelled so
# the mock does not quietly pin one of them; dot access is not, because nothing in the ext uses it
# and a `getproperty` overload here would have to tiptoe around this struct's own field.
struct MockRow
    _data::Dict{Symbol,Any}
end

Base.getindex(r::MockRow, k::Symbol) = getfield(r, :_data)[k]
Base.getindex(r::MockRow, k::String) = getfield(r, :_data)[Symbol(k)]
Base.haskey(r::MockRow, k::Symbol) = haskey(getfield(r, :_data), k)
Base.haskey(r::MockRow, k::String) = haskey(getfield(r, :_data), Symbol(k))
Base.get(r::MockRow, k::Symbol, default) = get(getfield(r, :_data), k, default)
Base.get(r::MockRow, k::String, default) = get(getfield(r, :_data), Symbol(k), default)

# ── Mock PormG query layer ───────────────────────────────────────────────

# Operator names PormG knows (`PormGsuffix`). Spelling one of these WITHOUT the `@` is the
# specific drift #180 is about, so the mock names it rather than lumping it in with any other
# unmodelled key.
const PORMG_OPERATOR_NAMES = Set([
    "gte", "gt", "lte", "lt", "ne", "isnull", "in", "nin",
    "contains", "icontains", "startswith", "endswith", "range",
])

# Every filter key the mock knows how to evaluate. Anything else is a query the mock is not
# actually exercising, and must say so.
const MODELLED_FILTER_KEYS = Set(["session_key", "expires_at__@lte", "expires_at__@gt"])

function _reject_filter_key(k::String)
    parts = split(k, "__")
    suffix = String(parts[end])
    if length(parts) > 1 && !startswith(suffix, "@") && suffix in PORMG_OPERATOR_NAMES
        error("MockSessionQuerySet: filter key '$k' is missing PormG's `@` operator prefix. " *
              "Real PormG throws `FilterError` here (\"requires '@' prefix\"), and " *
              "`cleanup_expired_sessions!` wraps its query in a try/catch that WARNS AND " *
              "SWALLOWS -- so against a real database this spelling makes the prune silently " *
              "never run. Use '$(join(parts[1:end-1], "__"))__@$(suffix)'.")
    end
    error("MockSessionQuerySet: unmodelled filter key '$k' -- teach the mock about it, or the " *
          "query under test is not actually being exercised.")
end

# One database: the state every queryset the owning model mints SHARES, plus the lock that makes
# sharing safe. Same shape, same reasoning and the same statement-level granularity as
# `MockDB` in `pormg_worker_tests.jl` -- read the comment there, it is the canonical one.
#
# PROPHYLACTIC HERE, and worth being honest about: this file contains no `Threads.@spawn`, no
# `@async` and no `timedwait`, so `PormGSessionStore` is only ever driven from the test task and
# the race #226 is about cannot fire. The lock is here so the invariant "the mock serializes,
# because the database it stands in for does" holds for BOTH mocks -- this one is where the
# worker mock was ported from, and the next concurrent session test would otherwise reintroduce
# a bug that has already been fixed once.
struct SessionMockDB
    # One table PER CONNECTION, not one table. A single-table mock cannot express #199 at all --
    # "created the table on `sessions`, then read and wrote every row on `db`" is not a statement
    # about anything unless there are two tables to tell apart, so no assertion written against
    # such a mock could have failed on the shipped code.
    tables::Dict{String, Dict{String, Dict{Symbol,Any}}}   # db key -> session_key -> row
    seen::Vector{Dict{String,Any}}
    lock::ReentrantLock
end

SessionMockDB(db_keys::String...) = SessionMockDB(
    Dict{String, Dict{String, Dict{Symbol,Any}}}(
        k => Dict{String, Dict{Symbol,Any}}() for k in (isempty(db_keys) ? ("db",) : db_keys)),
    Dict{String,Any}[],
    ReentrantLock())

mutable struct MockQuerySet
    mdb::SessionMockDB
    db_key::Union{Nothing,String}                          # `nothing` until `.db(key)` runs
    # Per-queryset: `model.objects` mints a fresh one per access, so a chain is confined to the
    # task that built it.
    filters::Dict{String, Any}
end

_mock_lock(qs::MockQuerySet) = getfield(qs, :mdb).lock

# The connection this query runs on. `nothing` means the store reached `m.objects` directly
# instead of routing through `_session_objects(store)`.
#
# Erroring here is not the mock inventing a rule PormG does not have -- it is the closest
# FAITHFUL model of the configuration #199 is about. PormG resolves a query's connection as
# `q.connect_key !== nothing ? q.connect_key : q.model.connect_key` and, when both are `nothing`,
# uses the sole loaded connection or throws `InvalidConfigurationError`
# (`PormG/src/querybuilder/build_helpers.jl`). The ext builds its session model with a bare
# `PormG.Models.Model("nitro_session", ...)` in `_define_session_model()` and never passes it to
# `set_models`, so `model.connect_key` IS `nothing` (`PormG/src/Models.jl`). Therefore, with a
# `db` and a `sessions` connection both loaded, every unrouted session query THROWS -- into
# `Base.get`'s and `cleanup_expired_sessions!`'s catch blocks, which swallow, and out of
# `set_session!`/`delete_session!`, which rethrow. Modelling a silent fallback instead would mean
# inventing a binding the ext does not make.
function _selected_table(qs::MockQuerySet)
    key = getfield(qs, :db_key)
    key === nothing && error("MockSessionQuerySet: query ran without selecting a connection -- " *
        "every session query must go through `_session_objects(store)` (`.db(store.db_key)`), " *
        "not `m.objects` directly. See #199.")
    tables = getfield(qs, :mdb).tables
    haskey(tables, key) || error("MockSessionQuerySet: no table registered for db key '$key' -- " *
        "PormG throws `InvalidConfigurationError` for a key that was never loaded. Build the " *
        "model as `MockModel(\"$key\")` if the test means to use that connection.")
    return tables[key]
end

# The keys of every row the accumulated filter selects. Recording the filter here rather than in
# `filter` is deliberate: this is the filter a query actually RAN with, which is what a test
# wants to assert about.
# MUST be called with the database lock held: it reads the shared table and appends to the
# shared `seen` vector. Appends exactly once per call, and every terminal op calls it exactly
# once -- `_filters_seen` carries exact-count assertions.
function _matching_keys_locked(qs::MockQuerySet)
    filters = getfield(qs, :filters)
    push!(getfield(qs, :mdb).seen, copy(filters))

    # Validate EVERY key BEFORE looking at any row. Checking inside the row loop -- which is
    # where this started -- makes the guard vanish on an empty table, and an empty table is
    # precisely the state a prune runs against once it has worked. It also lets an earlier
    # non-matching key `break` out before an unmodelled one is ever reached.
    for k in keys(filters)
        k in MODELLED_FILTER_KEYS || _reject_filter_key(k)
    end

    # AFTER the filter-key check: a misspelled filter is the more specific diagnosis, and the two
    # `@test_throws` in "the mock refuses a filter it does not model" drive `m.objects` directly.
    table = _selected_table(qs)

    matched = String[]
    for (key, row) in table
        ok = true
        for (k, v) in filters
            if k == "session_key"
                ok = row[:session_key] == v
            elseif k == "expires_at__@gt"
                # `update_session!`'s liveness condition (#318): the strict complement of the
                # `__@lte` below, so the boundary instant is expired on both sides.
                ok = row[:expires_at] > v
            else  # "expires_at__@lte"
                # PormG's `lte` is `<=`, matching `is_expired`'s inclusive boundary
                # (`src/types.jl`). Comparing instants here rather than PormG's canonical
                # UTC strings is equivalent for `<=` and keeps the mock readable.
                #
                # This also assumes the naive `DateTime` the prune passes as a filter VALUE
                # means UTC. Checked, not assumed: PormG runs a filter value through the
                # field's formatter, and `DateTimeField`'s is `format_timezone_sql`, whose
                # `::DateTime` method comments "a naive DateTime is interpreted as UTC
                # (matches Django USE_TZ default)" before canonicalising. Were it server-local
                # instead, the prune window would be off by the host's UTC offset and no
                # assertion in this file could see it.
                ok = row[:expires_at] <= v
            end
            ok || break
        end
        ok && push!(matched, key)
    end
    return matched
end

# A stored row as PormG would hand it back. `copy` so a read cannot mutate the table, and
# `expires_at` as a UTC `ZonedDateTime` because PormG canonicalises a `DateTimeField` to UTC on
# write and re-parses it on read -- on BOTH backends, not as the naive `DateTime` that went in.
# Handing back the stored value verbatim would leave `_parse_db_datetime`'s production branch
# untouched by every test that reads a session.
_as_db_row(row::Dict{Symbol,Any}) = MockRow(merge(row, Dict{Symbol,Any}(
    :expires_at => ZonedDateTime(row[:expires_at], tz"UTC"),
)))

function Base.getproperty(qs::MockQuerySet, name::Symbol)
    if name === :filter
        return function(pairs::Pair{String,<:Any}...)
            # ACCUMULATE onto this object and return it, exactly as PormG's `_filter!` does.
            # Returning a fresh queryset with a copied filter dict -- which this mock used to
            # do -- makes `base.filter(A)` and `base.filter(B)` independent, where real PormG
            # ANDs the second onto the first.
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
            setfield!(qs, :db_key, db_key)
            return qs
        end
    elseif name === :first
        return function()
            return lock(_mock_lock(qs)) do
                matched = _matching_keys_locked(qs)
                isempty(matched) ? nothing : _as_db_row(_selected_table(qs)[first(matched)])
            end
        end
    elseif name === :create
        return function(pairs::Pair{String,<:Any}...)
            row = Dict{Symbol,Any}()
            for (k, v) in pairs
                row[Symbol(k)] = v
            end
            return lock(_mock_lock(qs)) do
                _selected_table(qs)[row[:session_key]] = row
                # PormG's `.create` returns a fully-populated row that reads back canonicalised
                # like any other, so go through the same conversion rather than aliasing what
                # was stored. `_as_db_row` merges into a new Dict, so it is already a snapshot.
                _as_db_row(row)
            end
        end
    elseif name === :update
        return function(pairs::Pair{String,<:Any}...)
            # PormG refuses an unfiltered update outright (`UnsafeMutationError`), and returns
            # the affected-row count rather than `nothing`.
            isempty(getfield(qs, :filters)) &&
                error("MockSessionQuerySet: update() requires a filter -- refusing to update " *
                      "every row, as PormG does.")
            # The compare and the set in ONE lock hold -- that is what an UPDATE ... WHERE is.
            return lock(_mock_lock(qs)) do
                table = _selected_table(qs)
                touched = 0
                for key in _matching_keys_locked(qs)
                    for (k, v) in pairs
                        table[key][Symbol(k)] = v
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
                error("MockSessionQuerySet: delete() must have a filter -- pass " *
                      "allow_delete_all = true to delete every row, as PormG requires.")
            return lock(_mock_lock(qs)) do
                matched = _matching_keys_locked(qs)
                table = _selected_table(qs)
                for key in matched
                    delete!(table, key)
                end
                # PormG returns `(total, per-table breakdown)`. The mock used to return
                # `nothing`, so a store that started reading the count would have been testing
                # a fiction.
                (length(matched), Dict{String,Integer}("nitro_session" => length(matched)))
            end
        end
        return delete_fn
    else
        return getfield(qs, name)
    end
end

struct MockModel
    mdb::SessionMockDB
end

# Every connection this model may be queried on. A test that exercises routing names both
# (`MockModel("db", "sessions")`); the no-argument form is the single connection every test that
# does not care about routing uses.
MockModel(db_keys::String...) = MockModel(SessionMockDB(db_keys...))

function Base.getproperty(m::MockModel, name::Symbol)
    if name === :objects
        # No connection selected yet -- exactly what PormG's `model.objects` hands back.
        # `.db(key)` is what picks one.
        return MockQuerySet(getfield(m, :mdb), nothing, Dict{String,Any}())
    elseif name === :_table
        # The DEFAULT connection's table: what every assertion that does not care about routing
        # means, kept as an alias rather than rewritten at twenty-odd call sites. A test that DOES
        # care names its connection (`m._tables["sessions"]`) -- and the routing testsets below
        # assert `_table` stays EMPTY for a store configured elsewhere, which makes this alias an
        # assertion asset rather than a way to read the wrong table by accident.
        return getfield(m, :mdb).tables["db"]
    elseif name === :_tables
        return getfield(m, :mdb).tables
    elseif name === :_filters_seen
        return getfield(m, :mdb).seen
    else
        return getfield(m, name)
    end
end

# A model whose every query throws, for the error paths. `Base.get` and
# `cleanup_expired_sessions!` swallow; `set_session!` and `delete_session!` rethrow.
struct FailingMockModel end

function Base.getproperty(m::FailingMockModel, name::Symbol)
    if name === :objects
        return m
    elseif name === :db
        # Selecting a connection SUCCEEDS; it is the QUERY that fails. Without this branch the
        # throw would come out of `.db(...)` itself, so the four assertions below would stay green
        # even if every query under them were deleted.
        return (_db_key::String) -> m
    end
    return function(args...; kwargs...)
        error("mock persistence failure")
    end
end

# The same shape, throwing a chosen exception -- for the #254 rethrow of the query catch.
struct ThrowingMockModel
    exc::Exception
end

function Base.getproperty(m::ThrowingMockModel, name::Symbol)
    name === :objects && return m
    name === :db && return (_db_key::String) -> m
    return (args...; kwargs...) -> throw(getfield(m, :exc))
end

# A stored `session_data` whose bytes cannot even be read: the synthetic stand-in for an overflow
# or OOM raised while decoding, which cannot safely be produced for real in-process (#254, #301).
# The depth scan reads code units first, so this throws where a real overflow would have.
struct ExplodingText <: AbstractString
    exc::Exception
end
Base.ncodeunits(::ExplodingText) = 2
Base.codeunit(::ExplodingText) = UInt8
Base.codeunit(t::ExplodingText, ::Int) = throw(t.exc)
Base.isvalid(::ExplodingText, ::Int) = true
Base.iterate(t::ExplodingText, ::Int = 1) = throw(t.exc)

# ── Load the SHIPPED store from the extension ────────────────────────────

function _load_pormg_session_store_type()
    try
        @eval using PormG
    catch
        return nothing
    end

    ext = Base.get_extension(Nitro, :NitroPormGExt)
    return isnothing(ext) ? nothing : getproperty(ext, :PormGSessionStore)
end

const RealPormGSessionStore = _load_pormg_session_store_type()

# FAIL, do not skip (#128). `PormG` is a declared `[targets].test` dependency, so it is present
# under every supported way of invoking this suite. Its absence is an environment bug, not a
# configuration this file should accommodate -- and a `@test_skip` here would report as one
# `Broken` line with the run still exiting 0, silently voiding every assertion below. See the
# bootstrap guard in `test/runtests.jl` and `SKIPS_OK` in `test/harness_manifest.jl`.
if RealPormGSessionStore === nothing
    error("PormG is not available, so NitroPormGExt.PormGSessionStore cannot be loaded. " *
          "PormG is a declared `[targets].test` dependency: this is a broken test " *
          "environment, not a valid configuration, and failing here is deliberate (#128). " *
          "Run `bash scripts/worktree_setup.sh` in a worktree, unset a stale " *
          "`NITRO_TEST_REDISPATCH`, or re-provision with `Pkg.test()`.")
end

const PormGExt = Base.get_extension(Nitro, :NitroPormGExt)

# -- A stand-in PormG connection, for `pormg_nitro_session` ---------------
#
# `PormG.connection(key=k)` is just `config[k].connections` (`PormG/src/Configuration.jl`),
# `config` is a `Dict{String,PormGSettings}` and `PormGSettings` is an ABSTRACT type
# (`PormG/src/Kernel.jl`), so an entry registered under a test-only key is enough to run
# `pormg_nitro_session` end to end with nothing behind it.
#
# `FakeSessionPool <: PormG.PormGSQLite` on purpose rather than a bare struct: subtyping means
# `_ensure_session_table!` runs PormG's REAL `create_table`/`create_index` against the REAL
# session model, so this covers the bootstrap SQL too. Only `fetch` is overridden -- it is the
# one step that would touch a driver -- and the method is on our own concrete type, so it is
# more specific than PormG's `Union{PormGPostgres,PormGSQLite}` method rather than piracy.
struct FakeSessionPool <: PormG.PormGSQLite
    sql::Vector{String}
end

struct FakeSessionSettings <: PormG.PormGSettings
    connections::FakeSessionPool
end

PormG.ConnectionPool.fetch(c::FakeSessionPool, sql::String; kwargs...) =
    (push!(c.sql, sql); nothing)

# Seed a row directly, the way a prior process would have left one behind. `expires_at` is a
# naive UTC `DateTime`, which is what `set_session!` writes.
function _seed_row!(model::MockModel, key::String, data::Dict{String,Any}, expires_at::DateTime;
                    db_key::String="db")
    model._tables[db_key][key] = Dict{Symbol,Any}(
        :session_key  => key,
        :session_data => JSON.json(data),
        :expires_at   => expires_at,
    )
    return nothing
end

@testset "PormGSessionStore interface" begin
    store = RealPormGSessionStore(model=MockModel())

    # The conformance check used to live in `pormg_worker_tests.jl`, because that was the only
    # file where the extension was actually loaded. It belongs here now. (`store isa
    # AbstractSessionStore` is not asserted beside it: `missing_session_methods` is typed
    # `::Type{<:AbstractSessionStore}`, so it could not dispatch if that were false.)
    @test isempty(missing_session_methods(RealPormGSessionStore))

    # The default connection key, mirroring `pormg_worker_tests.jl`'s `@test store.db_key == "db"`.
    # On its own this proves only that the field exists -- the routing testsets below are what
    # prove it is USED.
    @test store.db_key == "db"

    @testset "create and read" begin
        set_session!(store, "sess-1", Dict{String,Any}("user_id" => 1); ttl=3600)
        @test store.model._table["sess-1"][:expires_at] isa DateTime
        @test get_session(store, "sess-1") == Dict{String,Any}("user_id" => 1)
    end

    @testset "expires_at is one UTC clock read plus the ttl" begin
        # `isa DateTime` above says nothing about the VALUE. Without this, an ext that ignored
        # `ttl` and hardcoded an hour -- pinning every session regardless of what
        # `SessionMiddleware` was configured with -- ships green, and so does one that read the
        # system-local clock instead of UTC (invisible on a UTC CI runner, visible only to
        # deployments running behind UTC).
        s = RealPormGSessionStore(model=MockModel())
        before = Dates.now(Dates.UTC)
        set_session!(s, "ttl-check", Dict{String,Any}(); ttl=90)
        after = Dates.now(Dates.UTC)

        written = s.model._table["ttl-check"][:expires_at]
        @test before + Dates.Second(90) <= written <= after + Dates.Second(90)
    end

    @testset "overwrite" begin
        set_session!(store, "sess-1", Dict{String,Any}("user_id" => 99); ttl=3600)
        @test length(store.model._table) == 1          # updated in place, not duplicated
        @test get_session(store, "sess-1") == Dict{String,Any}("user_id" => 99)
    end

    @testset "delete" begin
        delete_session!(store, "sess-1")
        @test !haskey(store.model._table, "sess-1")
        @test get_session(store, "sess-1") === nothing
    end

    # #318: `set_session!` re-creates a missing row, so the middleware's write-back of a session a
    # concurrent logout deleted brought it back. `update_session!` must be ONE conditional UPDATE.
    @testset "update_session! updates a live row and never creates one (#318)" begin
        m = MockModel()
        s = RealPormGSessionStore(model=m)

        # Absent -- the logout already deleted it. No row appears.
        @test update_session!(s, "gone", Dict{String,Any}("user_id" => 42); ttl=3600) === false
        @test !haskey(m._table, "gone")

        # Expired -- matched by nothing, and left exactly as it was for the prune.
        stale_expiry = Dates.now(Dates.UTC) - Dates.Second(5)
        _seed_row!(m, "stale", Dict{String,Any}("user_id" => 1), stale_expiry)
        @test update_session!(s, "stale", Dict{String,Any}("user_id" => 2); ttl=3600) === false
        @test m._table["stale"][:expires_at] == stale_expiry
        @test JSON.parse(m._table["stale"][:session_data])["user_id"] == 1

        # Live -- overwritten in place, expiry moved to `ttl` from now.
        set_session!(s, "live", Dict{String,Any}("v" => 1); ttl=10)
        before = Dates.now(Dates.UTC)
        queries_before = length(m._filters_seen)
        @test update_session!(s, "live", Dict{String,Any}("v" => 2); ttl=90) === true
        after = Dates.now(Dates.UTC)

        # The liveness condition is in the SAME query as the write -- exactly one query, carrying
        # both keys -- not a read first and a write after, which would re-open the race.
        @test length(m._filters_seen) == queries_before + 1
        update_filters = m._filters_seen[end]
        @test update_filters["session_key"] == "live"
        @test haskey(update_filters, "expires_at__@gt")

        @test get_session(s, "live") == Dict{String,Any}("v" => 2)
        @test before + Dates.Second(90) <= m._table["live"][:expires_at] <= after + Dates.Second(90)
    end

    # #361: `regenerate_session!` copied a session a concurrent logout had deleted into a fresh id.
    # PormG refuses a primary key in `update()`'s SET, so the move is a guarded DELETE whose row
    # count decides, then an INSERT -- and the INSERT happens only when that DELETE removed a row.
    @testset "rotate_session! moves a live row and never creates one (#361)" begin
        m = MockModel()
        s = RealPormGSessionStore(model=m)

        # Absent -- the logout already deleted it. Nothing moves, and no new row appears.
        @test rotate_session!(s, "gone", "fresh", Dict{String,Any}("user_id" => 42); ttl=3600) === false
        @test isempty(m._table)

        # Expired -- matched by nothing, and left exactly as it was for the prune.
        stale_expiry = Dates.now(Dates.UTC) - Dates.Second(5)
        _seed_row!(m, "stale", Dict{String,Any}("user_id" => 1), stale_expiry)
        @test rotate_session!(s, "stale", "fresh", Dict{String,Any}("user_id" => 1); ttl=3600) === false
        @test !haskey(m._table, "fresh")
        @test m._table["stale"][:expires_at] == stale_expiry

        # Live -- moved: the old key is gone, the new one holds the data under a fresh expiry.
        set_session!(s, "live", Dict{String,Any}("v" => 1); ttl=10)
        queries_before = length(m._filters_seen)
        before = Dates.now(Dates.UTC)
        @test rotate_session!(s, "live", "moved", Dict{String,Any}("v" => 2); ttl=90) === true
        after = Dates.now(Dates.UTC)

        # The liveness condition is in the DELETE's own WHERE, the query whose count decides.
        # (Checked before the reads below, which record filters of their own.)
        @test length(m._filters_seen) == queries_before + 1
        delete_filters = m._filters_seen[end]
        @test delete_filters["session_key"] == "live"
        @test haskey(delete_filters, "expires_at__@gt")

        @test !haskey(m._table, "live")
        @test get_session(s, "moved") == Dict{String,Any}("v" => 2)
        @test before + Dates.Second(90) <= m._table["moved"][:expires_at] <= after + Dates.Second(90)
    end

    @testset "every query runs on the store's db_key, not the model's default (#199)" begin
        # The regression test for #199 proper. `pormg_nitro_session(db_key="sessions")` created
        # `nitro_session` on `sessions` and then read, wrote, deleted and pruned on whatever
        # connection the model resolved to -- because `PormGSessionStore` had nowhere to put the
        # key and all four sites called `m.objects` directly.
        m = MockModel("db", "sessions")
        store = RealPormGSessionStore(model=m, db_key="sessions")

        # CREATE -- `set_session!`'s insert branch.
        set_session!(store, "routed", Dict{String,Any}("user_id" => 7); ttl=3600)
        @test haskey(m._tables["sessions"], "routed")
        @test isempty(m._tables["db"])

        # READ -- `Base.get`. A DECOY under the SAME session key on the other connection, so a
        # store that reads from the wrong one hands back the decoy and this assertion NAMES the
        # defect instead of merely failing to find a row. It also keeps the read site covered
        # independently: a fix that routed the writes and missed `Base.get` still fails here.
        _seed_row!(m, "routed", Dict{String,Any}("user_id" => 999),
                   Dates.now(Dates.UTC) + Dates.Hour(1); db_key="db")
        @test get_session(store, "routed") == Dict{String,Any}("user_id" => 7)

        # UPDATE -- `set_session!`'s overwrite branch is a SEPARATE query site from its insert.
        set_session!(store, "routed", Dict{String,Any}("user_id" => 8); ttl=3600)
        @test JSON.parse(m._tables["sessions"]["routed"][:session_data])["user_id"] == 8
        @test JSON.parse(m._tables["db"]["routed"][:session_data])["user_id"] == 999
        @test length(m._tables["sessions"]) == 1   # updated in place, on the right connection

        # UPDATE-ONLY -- `update_session!` (#318) is a third write site.
        @test update_session!(store, "routed", Dict{String,Any}("user_id" => 9); ttl=3600)
        @test JSON.parse(m._tables["sessions"]["routed"][:session_data])["user_id"] == 9
        @test JSON.parse(m._tables["db"]["routed"][:session_data])["user_id"] == 999

        # DELETE.
        delete_session!(store, "routed")
        @test !haskey(m._tables["sessions"], "routed")
        @test haskey(m._tables["db"], "routed")    # the decoy survives: a different database

        # ROTATE -- `rotate_session!` (#361): its guarded DELETE and its INSERT, both routed. The
        # decoy under the old key must survive, and the new key must not appear beside it.
        set_session!(store, "rot-old", Dict{String,Any}("user_id" => 10); ttl=3600)
        _seed_row!(m, "rot-old", Dict{String,Any}("user_id" => 999),
                   Dates.now(Dates.UTC) + Dates.Hour(1); db_key="db")
        @test rotate_session!(store, "rot-old", "rot-new", Dict{String,Any}("user_id" => 10); ttl=3600)
        @test haskey(m._tables["sessions"], "rot-new") && !haskey(m._tables["sessions"], "rot-old")
        @test haskey(m._tables["db"], "rot-old") && !haskey(m._tables["db"], "rot-new")
    end

    @testset "an expired payload is refused on the read path" begin
        s = RealPormGSessionStore(model=MockModel())
        _seed_row!(s.model, "stale", Dict{String,Any}("temp" => true),
                   Dates.now(Dates.UTC) - Dates.Second(1))

        # The row is still there -- expiry is enforced on READ, independently of the prune.
        @test haskey(s.model._table, "stale")
        @test get_session(s, "stale") === nothing

        # ... and `Base.get` still hands back the payload, so the two layers stay distinguishable.
        payload = Base.get(s, "stale", nothing)
        @test payload isa SessionPayload
        @test is_expired(payload)
    end

    @testset "cleanup_expired_sessions! deletes the expired ROWS" begin
        s = RealPormGSessionStore(model=MockModel())

        set_session!(s, "active", Dict{String,Any}("a" => 1); ttl=3600)
        _seed_row!(s.model, "expired1", Dict{String,Any}("b" => 2),
                   Dates.now(Dates.UTC) - Dates.Second(10))
        _seed_row!(s.model, "expired2", Dict{String,Any}("c" => 3),
                   Dates.now(Dates.UTC) - Dates.Hour(2))

        @test cleanup_expired_sessions!(s) === nothing

        # Assert on the TABLE, not through `get_session`. `get_session` refuses an expired
        # payload on the read path whether or not the row was deleted, so the old assertions
        # (`@test get_session(store, "expired1") === nothing`) passed identically against a
        # prune that did nothing at all -- which is exactly what the drifted filter made it do.
        @test haskey(s.model._table, "active")
        @test !haskey(s.model._table, "expired1")
        @test !haskey(s.model._table, "expired2")
        @test length(s.model._table) == 1
    end

    @testset "cleanup_expired_sessions! sends PormG's inclusive `__@lte` operator" begin
        s = RealPormGSessionStore(model=MockModel())
        before = Dates.now(Dates.UTC)
        cleanup_expired_sessions!(s)
        after = Dates.now(Dates.UTC)

        @test length(s.model._filters_seen) == 1
        sent = s.model._filters_seen[1]

        # The operator name IS the boundary assertion. PormG maps `lte` to `<=`, which is the
        # inclusive comparison `is_expired` uses (`src/types.jl`); `lt` would exclude a row
        # expiring on exactly the cutoff millisecond, the drift #173 closed on the read paths.
        # Staging that millisecond against the real clock is not possible from out here -- the
        # store reads `now()` internally -- so pin the operator instead.
        @test collect(keys(sent)) == ["expires_at__@lte"]

        # One clock read, in UTC, bound as a naive `DateTime` (PormG treats that as UTC).
        # `get` rather than indexing so a wrong operator fails the assertion above and this
        # one, rather than throwing a `KeyError` out of the testset.
        cutoff = get(sent, "expires_at__@lte", nothing)
        @test cutoff isa DateTime
        @test cutoff isa DateTime && before <= cutoff <= after
    end

    @testset "cleanup_expired_sessions! prunes the store's connection only (#199)" begin
        m = MockModel("db", "sessions")
        store = RealPormGSessionStore(model=m, db_key="sessions")

        _seed_row!(m, "stale", Dict{String,Any}(), Dates.now(Dates.UTC) - Dates.Hour(1);
                   db_key="sessions")
        _seed_row!(m, "stale-elsewhere", Dict{String,Any}(), Dates.now(Dates.UTC) - Dates.Hour(1);
                   db_key="db")

        # The prune CATCHES everything and returns `nothing`, so a mock error raised inside it is
        # invisible from out here -- `=== nothing` passes either way, which is why the sibling
        # testsets above assert on the table rather than on the return. Three nets, in order of
        # what each one distinguishes:
        #   1. nothing was logged at all, i.e. the swallow never fired;
        @test_logs min_level=Base.CoreLogging.Warn cleanup_expired_sessions!(store)
        #   2. the rows on THIS connection are gone and the ones on the other are untouched;
        @test isempty(m._tables["sessions"])
        @test haskey(m._tables["db"], "stale-elsewhere")
        #   3. the filter carried the operator the sibling testset pins. NOT a proof that a query
        #      reached a table: `_matching_keys` records `seen` before it resolves the connection,
        #      so an unrouted prune records one entry and then throws. Nets 1 and 2 are what
        #      discriminate; this one pins the operator.
        @test length(m._filters_seen) == 1
        @test collect(keys(m._filters_seen[1])) == ["expires_at__@lte"]
    end

    @testset "JSON round-trip preserves data types" begin
        s = RealPormGSessionStore(model=MockModel())
        data = Dict{String,Any}(
            "user_id" => 42,
            "name" => "Alice",
            "roles" => Any["admin", "user"],
            "active" => true,
        )
        set_session!(s, "json-test", data; ttl=3600)
        result = get_session(s, "json-test")

        @test result["user_id"] == 42
        @test result["name"] == "Alice"
        @test result["active"] == true
        @test "admin" in result["roles"]
    end

    @testset "reads swallow persistence failures, writes propagate them" begin
        failing = RealPormGSessionStore(model=FailingMockModel())

        Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
            # Writes rethrow: a caller that thinks it stored a session must not be told it did.
            @test_throws "mock persistence failure" set_session!(failing, "sess-err", Dict{String,Any}("user_id" => 1); ttl=3600)
            # Not `false`: `false` means "the session is gone", and the middleware acts on it by
            # dropping the write. A database outage is not a logout.
            @test_throws "mock persistence failure" update_session!(failing, "sess-err", Dict{String,Any}("user_id" => 1); ttl=3600)
            # Same for a rotation (#361): `false` would drop the rotation as if logged out.
            @test_throws "mock persistence failure" rotate_session!(failing, "sess-err", "sess-new", Dict{String,Any}("user_id" => 1); ttl=3600)
            @test_throws "mock persistence failure" delete_session!(failing, "sess-err")

            # Reads degrade to "no session" rather than throwing out of the request path.
            @test Base.get(failing, "sess-err", :fallback) === :fallback
            @test get_session(failing, "sess-err") === nothing

            # The prune swallows too, and MUST: it runs on the background janitor in
            # `src/middleware/session_middleware.jl`, which would otherwise take a database
            # blip as a reason to stop pruning. Nothing covered this before.
            @test cleanup_expired_sessions!(failing) === nothing
        end
    end

    @testset "an undecodable session is logged without its payload (#267)" begin
        m = MockModel()
        s = RealPormGSessionStore(model=m)
        set_session!(s, "sess-bad-267", Dict{String,Any}("user_id" => 1); ttl=3600)
        # A JSON parse error quotes a window of text from just before the failure position.
        # Session payloads are named secrets, so the secret IS the unparseable token: the window
        # carries all of it. A few bytes further on, only a fragment is quoted and the assertion
        # below passes against the leaking code.
        m._table["sess-bad-267"][:session_data] = "{\"csrf\": tok_SECRET_267}"

        # Rendered through a real logger. `SimpleLogger` prints an `exception=` kwarg with `show`,
        # which includes the exception's message: the leak is what reaches the operator's log,
        # not what the record holds.
        io = IOBuffer()
        got = Base.CoreLogging.with_logger(Base.CoreLogging.SimpleLogger(io, Base.CoreLogging.Debug)) do
            Base.get(s, "sess-bad-267", :fallback)
        end
        logs = String(take!(io))

        @test got === :fallback
        @test occursin("failed to read session", logs)
        @test !occursin("SECRET", logs)
        # The session key is the credential itself, so it stays out of the line too.
        @test !occursin("sess-bad-267", logs)
    end

    @testset "session data is depth-bounded both ways (#344)" begin
        nested(k) = (v = Any[]; for _ in 2:k; v = Any[v]; end; v)   # `k` levels of arrays
        m = MockModel()
        s = RealPormGSessionStore(model=m)

        # `{"deep": [[…]]}`: the object is one level, so 511 arrays inside it is the bound.
        set_session!(s, "sess-deep", Dict{String,Any}("deep" => nested(511)); ttl=3600)
        @test get_session(s, "sess-deep") !== nothing

        # One level over is refused at the write, before a row exists -- not stored where every
        # later read would silently reset the session.
        @test_throws ArgumentError set_session!(s, "sess-deeper", Dict{String,Any}("deep" => nested(512)); ttl=3600)
        @test !haskey(m._table, "sess-deeper")
        # The update-only write a loaded session goes through (#318) is bounded the same way,
        # and leaves the live row as it was.
        before = m._table["sess-deep"][:session_data]
        @test_throws ArgumentError update_session!(s, "sess-deep", Dict{String,Any}("deep" => nested(512)); ttl=3600)
        @test m._table["sess-deep"][:session_data] == before
        # So is a rotation (#361), and it is refused BEFORE the old row is deleted -- a payload
        # too deep to store must not cost the visitor their session.
        @test_throws ArgumentError rotate_session!(s, "sess-deep", "sess-rotated", Dict{String,Any}("deep" => nested(512)); ttl=3600)
        @test m._table["sess-deep"][:session_data] == before
        @test !haskey(m._table, "sess-rotated")

        # A row stored over the bound before it existed reads as no session, through the same
        # payload-free warning as any other undecodable row.
        m._table["sess-deep"][:session_data] = JSON.json(Dict("deep" => nested(512)))
        io = IOBuffer()
        got = Base.CoreLogging.with_logger(Base.CoreLogging.SimpleLogger(io, Base.CoreLogging.Debug)) do
            Base.get(s, "sess-deep", :fallback)
        end
        @test got === :fallback
        @test occursin("does not decode", String(take!(io)))
    end

    @testset "the depth is decided before the payload is serialized (#367)" begin
        # `JSON.json` recurses once per level, so a payload deep enough to overflow it raised
        # `StackOverflowError` from INSIDE the serializer, before the #344 scan of its output ever
        # ran. A real overflow is not safe in-process (#254, #301), so a tripwire stands in for
        # it: the serializer raises the overflow on reaching it, 600 levels down, and the walk has
        # refused the payload at 513 without ever lowering it.
        struct SessionTripwire end
        JSON.lower(::SessionTripwire) = throw(StackOverflowError())
        deep = foldl((v, _) -> Any[v], 2:600; init=Any[SessionTripwire()])
        @test_throws StackOverflowError JSON.json(deep)     # what the write used to raise

        m = MockModel()
        s = RealPormGSessionStore(model=m)
        @test_throws ArgumentError set_session!(s, "sess-tripwire", Dict{String,Any}("deep" => deep); ttl=3600)
        @test !haskey(m._table, "sess-tripwire")

        set_session!(s, "sess-live", Dict{String,Any}("user_id" => 1); ttl=3600)
        before = m._table["sess-live"][:session_data]
        @test_throws ArgumentError update_session!(s, "sess-live", Dict{String,Any}("deep" => deep); ttl=3600)
        @test m._table["sess-live"][:session_data] == before
    end

    @testset "an unrecoverable error reading a session propagates (#254, #344)" begin
        # Read as "no session", an overflow would log the visitor out and keep serving from a
        # process that may be corrupted. Ordinary failures still read as no session -- the
        # FailingMockModel and #267 testsets above pin that half.
        for exc in (InterruptException(), StackOverflowError(), OutOfMemoryError())
            m = MockModel()
            s = RealPormGSessionStore(model=m)
            set_session!(s, "sess-boom", Dict{String,Any}("user_id" => 1); ttl=3600)
            m._table["sess-boom"][:session_data] = ExplodingText(exc)
            @test_throws typeof(exc) Base.get(s, "sess-boom", :fallback)

            throwing = RealPormGSessionStore(model=ThrowingMockModel(exc))
            @test_throws typeof(exc) Base.get(throwing, "sess-boom", :fallback)
        end
    end
end

@testset "_parse_db_datetime accepts what the drivers return" begin
    parse_dt = getproperty(PormGExt, :_parse_db_datetime)
    expected = DateTime(2026, 9, 15, 2, 42, 1)

    # A `DateTimeField` reads back as a UTC `ZonedDateTime` through PormG; SQLite and
    # PostgreSQL both normalise to that. This is the production input to the parser.
    @test parse_dt(ZonedDateTime(expected, tz"UTC")) == expected
    @test parse_dt(expected) == expected

    # The string shapes the fallback ladder exists for.
    @test parse_dt("2026-09-15T02:42:01Z") == expected
    @test parse_dt("2026-09-15T02:42:01") == expected
    @test parse_dt("2026-09-15 02:42:01") == expected
    @test parse_dt("2026-09-15 02:42:01.123") == DateTime(2026, 9, 15, 2, 42, 1, 123)
    @test parse_dt("2026-09-15T02:42:01.000+00:00") == expected
    @test parse_dt("2026-09-15T02:42:01+00:00") == expected
end

@testset "the mock refuses a query with no connection selected (#199)" begin
    # The guard that makes this file able to detect the next #199, and the reason the routing
    # testsets above are worth anything: without it an ext that dropped `.db(store.db_key)` would
    # keep every assertion in this file green, because one table cannot tell two databases apart.
    # `pormg_worker_tests.jl` models `.db` as a no-op passthrough and has exactly that hole (#203).
    # The mock alone, deliberately: these assertions are about the MOCK's guard, so wrapping a
    # store around it would only add a way for this testset to fail for an unrelated reason.
    m = MockModel("db", "sessions")

    @test_throws "without selecting a connection" m.objects.filter("session_key" => "x").first()
    @test_throws "no table registered for db key" m.objects.db("nope").filter("session_key" => "x").first()

    # ... and the routed spelling works, so this is pinned as a guard rather than as
    # "a query never works".
    @test m.objects.db("sessions").filter("session_key" => "x").first() === nothing
end

@testset "the mock refuses a filter it does not model" begin
    # The guard that makes this file able to detect the next #180. The pre-#180 mock had no
    # `else` branch, so an unrecognised filter deleted nothing and returned quietly.
    s = RealPormGSessionStore(model=MockModel())

    @test_throws "missing PormG's `@` operator prefix" s.model.objects.filter("expires_at__lte" => Dates.now(Dates.UTC)).delete()
    @test_throws "unmodelled filter key" s.model.objects.filter("nonsense" => 1).first()

    # And PormG's unfiltered-mutation guards -- including the one escape hatch, so the guard is
    # pinned as a guard rather than as "delete never works without a filter".
    _seed_row!(s.model, "doomed", Dict{String,Any}(), Dates.now(Dates.UTC) + Dates.Hour(1))
    @test_throws "must have a filter" s.model.objects.delete()
    @test_throws "requires a filter" s.model.objects.update("session_data" => "{}")
    @test haskey(s.model._table, "doomed")
    # `.db("db")` here and not on the two guards above: those fire before any table is touched,
    # while `allow_delete_all` deliberately gets all the way to the rows -- so this one has to be
    # driven the way the store drives it.
    @test s.model.objects.db("db").delete(allow_delete_all=true) == (1, Dict{String,Integer}("nitro_session" => 1))
    @test isempty(s.model._table)
end

@testset "PREMISE: the session model is BOUND to its store's connection (#202)" begin
    # This testset used to pin the opposite: `session_model().connect_key === nothing`, and an
    # unrouted query throwing `InvalidConfigurationError` because PormG refuses to guess between
    # two loaded connections. That was a faithful record of the shipped behaviour and it is what
    # #202 deliberately changes, so the expectation moves with the code rather than the code
    # being bent to keep it. The `.db(key)` routing half it guarded is unaffected and is still
    # covered by the mock testsets above.
    #
    # Why the binding has to exist: PormG's `ensure_model_transaction_scope` gates on the
    # MODEL's `connect_key` and never consults the query's `.db()` override, so while any
    # transaction is open on the calling task an unbound model throws for EVERY query --
    # swallowed by `Base.get` (a live session silently reads as absent) and rethrown by
    # `set_session!`/`delete_session!`.
    @test getproperty(PormGExt, :session_model)().connect_key == "db"
    @test getproperty(PormGExt, :session_model)("sessions").connect_key == "sessions"

    # One model per store, never a shared singleton: `connect_key` names exactly one
    # connection, so two stores on different keys sharing an object would overwrite each
    # other's binding.
    @test getproperty(PormGExt, :session_model)() !== getproperty(PormGExt, :session_model)()

    key = "nitro-test-session-tx"
    (haskey(PormG.config, key)) &&
        error("test-only PormG connection key is already registered: $key")
    conn = FakeSessionPool(String[])
    PormG.config[key] = FakeSessionSettings(conn)
    try
        bound = getproperty(PormGExt, :session_model)(key)
        unbound = getproperty(PormGExt, :session_model)(key)
        unbound.connect_key = nothing

        # `with_tx_context` is PormG's own seam onto the `ScopedValue` that `run_in_transaction`
        # sets, so the guard can be driven without a live driver. Outside a transaction the
        # guard returns immediately -- which is exactly why #202 never showed up in the suite.
        @test PormG.Configuration.ensure_model_transaction_scope(unbound) === nothing
        @test PormG.Configuration.ensure_model_transaction_scope(bound) === nothing

        PormG.with_tx_context(conn, nothing) do
            # The shipped defect, pinned: unbound + any open transaction == throw.
            @test_throws PormG.Kernel.InvalidConfigurationError PormG.Configuration.ensure_model_transaction_scope(unbound)
            # ... and the fix: a model bound to the transaction's own connection passes.
            @test PormG.Configuration.ensure_model_transaction_scope(bound) === nothing
        end
    finally
        delete!(PormG.config, key)
    end
    @test !haskey(PormG.config, key)

    # The constructor's OWN model-building branch. Every store elsewhere in this file passes
    # `model=`, and `pormg_nitro_session` builds the model itself and passes it in too, so
    # without this the `isnothing(model)` arm of `PormGSessionStore` has no coverage --
    # regressing it to `session_model()` would leave a store at `db_key="sessions"` carrying a
    # model bound to `"db"` and the suite would stay green. The constructor touches no
    # `PormG.config` entry, so no fixture is needed.
    @test RealPormGSessionStore(db_key="sessions").model.connect_key == "sessions"
    @test RealPormGSessionStore().model.connect_key == "db"
end

@testset "pormg_nitro_session hands its db_key to the store it returns (#199)" begin
    # #199 is two defects sharing one cause. The store half is covered above; this is the other
    # half: `pormg_nitro_session` used `db_key` to reach a connection, created the table on it,
    # and then built `PormGSessionStore(model=model)` -- dropping the argument on the floor. Every
    # mock above would happily pass a store that was simply never told which database it is on.
    key = "nitro-test-session-conn"
    # `error`, not `@test`, for the same reason as the testset above: a red assertion that then
    # clobbers and deletes a real `PormG.config` entry turns one failure into a broken process.
    haskey(PormG.config, key) && error("test-only PormG connection key is already registered: $key")
    conn = FakeSessionPool(String[])
    PormG.config[key] = FakeSessionSettings(conn)
    try
        store = pormg_nitro_session(db_key=key)

        # THE assertion. `store.db_key == "db"` here is the shipped bug.
        @test store.db_key == key

        # ... and it really is the shipped function under test: the real session model,
        # bootstrapped on the connection it was asked for.
        #
        # An identity check against `session_model()` used to stand here, back when the model
        # was a process-wide singleton. Since #202 each store gets its OWN model bound to its
        # own key -- a shared one could not carry two different `connect_key`s -- so the
        # meaningful assertion is the binding, not the object.
        @test store.model.name == "nitro_session"
        @test store.model.connect_key == key
        @test length(conn.sql) == 2
        @test any(q -> occursin("nitro_session", q), conn.sql)
        @test any(q -> occursin("nitro_session_expires_at_idx", q), conn.sql)
    finally
        # `config` is process-global and PormG falls back to `first(keys(config))` when a model is
        # unbound and exactly one connection is loaded, so a leaked entry could silently be picked
        # up by a later test item.
        delete!(PormG.config, key)
    end

    # The default is still the default, and is not a function of what ran above.
    @test !haskey(PormG.config, key)
end

# The `PasswordField` hook is latent (PormG 0.6 has no `register_field_hook`), so it is tested as
# the function it is. It used to pass any hash-shaped string through verbatim, which let a user
# pick a stored hash -- cost parameters included -- as their "password" (#311).
@testset "hash_password_field always hashes user input (#311)" begin
    hook = PormGExt.hash_password_field
    hostile = "pbkdf2_sha256\$9223372036854775807\$s\$h"
    stored = hook(hostile)
    @test stored != hostile
    @test startswith(stored, "pbkdf2_sha256\$$(Nitro.Auth.DEFAULT_PBKDF2_ITERATIONS)\$")
    @test Nitro.Auth.check_password(hostile, stored)

    # A genuine hash is hashed too: pre-hashed values take `auto_hash=false`, not this hook.
    genuine = Nitro.Auth.make_password("secret"; iterations = 1000)
    @test hook(genuine) != genuine

    # Blank and non-string values are PormG's to validate.
    @test hook("") == ""
    @test hook("   ") == "   "
    @test hook(nothing) === nothing
    @test hook(42) == 42
end

end
