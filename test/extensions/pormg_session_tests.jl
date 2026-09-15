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
                   delete_session!, cleanup_expired_sessions!, is_expired,
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
const MODELLED_FILTER_KEYS = Set(["session_key", "expires_at__@lte"])

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

mutable struct MockQuerySet
    table::Dict{String, Dict{Symbol,Any}}
    filters::Dict{String, Any}
    seen::Vector{Dict{String,Any}}
end

# The keys of every row the accumulated filter selects. Recording the filter here rather than in
# `filter` is deliberate: this is the filter a query actually RAN with, which is what a test
# wants to assert about.
function _matching_keys(qs::MockQuerySet)
    table = getfield(qs, :table)
    filters = getfield(qs, :filters)
    push!(getfield(qs, :seen), copy(filters))

    # Validate EVERY key BEFORE looking at any row. Checking inside the row loop -- which is
    # where this started -- makes the guard vanish on an empty table, and an empty table is
    # precisely the state a prune runs against once it has worked. It also lets an earlier
    # non-matching key `break` out before an unmodelled one is ever reached.
    for k in keys(filters)
        k in MODELLED_FILTER_KEYS || _reject_filter_key(k)
    end

    matched = String[]
    for (key, row) in table
        ok = true
        for (k, v) in filters
            if k == "session_key"
                ok = row[:session_key] == v
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
    elseif name === :first
        return function()
            table = getfield(qs, :table)
            matched = _matching_keys(qs)
            isempty(matched) && return nothing
            return _as_db_row(table[first(matched)])
        end
    elseif name === :create
        return function(pairs::Pair{String,<:Any}...)
            row = Dict{Symbol,Any}()
            for (k, v) in pairs
                row[Symbol(k)] = v
            end
            getfield(qs, :table)[row[:session_key]] = row
            # PormG's `.create` returns a fully-populated row that reads back canonicalised like
            # any other, so go through the same conversion rather than aliasing what was stored.
            return _as_db_row(row)
        end
    elseif name === :update
        return function(pairs::Pair{String,<:Any}...)
            # PormG refuses an unfiltered update outright (`UnsafeMutationError`), and returns
            # the affected-row count rather than `nothing`.
            isempty(getfield(qs, :filters)) &&
                error("MockSessionQuerySet: update() requires a filter -- refusing to update " *
                      "every row, as PormG does.")
            table = getfield(qs, :table)
            touched = 0
            for key in _matching_keys(qs)
                for (k, v) in pairs
                    table[key][Symbol(k)] = v
                end
                touched += 1
            end
            return touched
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
            table = getfield(qs, :table)
            matched = _matching_keys(qs)
            for key in matched
                delete!(table, key)
            end
            # PormG returns `(total, per-table breakdown)`. The mock used to return `nothing`,
            # so a store that started reading the count would have been testing a fiction.
            return length(matched), Dict{String,Integer}("nitro_session" => length(matched))
        end
        return delete_fn
    else
        return getfield(qs, name)
    end
end

struct MockModel
    _table::Dict{String, Dict{Symbol,Any}}
    _filters_seen::Vector{Dict{String,Any}}
end

MockModel() = MockModel(Dict{String, Dict{Symbol,Any}}(), Dict{String,Any}[])

function Base.getproperty(m::MockModel, name::Symbol)
    if name === :objects
        return MockQuerySet(getfield(m, :_table), Dict{String,Any}(), getfield(m, :_filters_seen))
    else
        return getfield(m, name)
    end
end

# A model whose every query throws, for the error paths. `Base.get` and
# `cleanup_expired_sessions!` swallow; `set_session!` and `delete_session!` rethrow.
struct FailingMockModel end

function Base.getproperty(::FailingMockModel, name::Symbol)
    if name === :objects
        return FailingMockModel()
    end
    return function(args...; kwargs...)
        error("mock persistence failure")
    end
end

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
else

const PormGExt = Base.get_extension(Nitro, :NitroPormGExt)

# Seed a row directly, the way a prior process would have left one behind. `expires_at` is a
# naive UTC `DateTime`, which is what `set_session!` writes.
function _seed_row!(model::MockModel, key::String, data::Dict{String,Any}, expires_at::DateTime)
    model._table[key] = Dict{Symbol,Any}(
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
    @test s.model.objects.delete(allow_delete_all=true) == (1, Dict{String,Integer}("nitro_session" => 1))
    @test isempty(s.model._table)
end

end  # RealPormGSessionStore available

end
