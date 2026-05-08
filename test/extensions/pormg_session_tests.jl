@testitem "PormG session store" tags=[:extension, :pormg] setup=[NitroCommon] begin

using Test
using Dates
using JSON

# These tests verify the PormGSessionStore contract using a mock PormG model.
# They validate serialization, TTL, cleanup, and the store interface without
# requiring a live database connection.

# ── Mock PormG Model layer ───────────────────────────────────────────────

"""
In-memory mock that mimics PormG's Model().objects chainable API:
  .filter("key" => val) -> QuerySet
  .first() -> Dict or nothing
  .create(pairs...) -> Dict
  .update(pairs...) -> nothing
  .delete() -> nothing
"""
mutable struct MockQuerySet
    table::Dict{String, Dict{String, Any}}  # session_key => row
    filters::Dict{String, Any}
end

function Base.getproperty(qs::MockQuerySet, name::Symbol)
    if name === :filter
        return function(pairs::Pair{String,<:Any}...)
            new_filters = copy(getfield(qs, :filters))
            for (k, v) in pairs
                new_filters[k] = v
            end
            return MockQuerySet(getfield(qs, :table), new_filters)
        end
    elseif name === :first
        return function()
            table = getfield(qs, :table)
            filters = getfield(qs, :filters)
            if haskey(filters, "session_key")
                key = filters["session_key"]
                return get(table, key, nothing)
            end
            return nothing
        end
    elseif name === :create
        return function(pairs::Pair{String,<:Any}...)
            row = Dict{String,Any}()
            for (k, v) in pairs
                row[k] = v
            end
            key = row["session_key"]
            getfield(qs, :table)[key] = row
            return row
        end
    elseif name === :update
        return function(pairs::Pair{String,<:Any}...)
            table = getfield(qs, :table)
            filters = getfield(qs, :filters)
            if haskey(filters, "session_key")
                key = filters["session_key"]
                if haskey(table, key)
                    for (k, v) in pairs
                        table[key][k] = v
                    end
                end
            end
            return nothing
        end
    elseif name === :delete
        return function(; allow_delete_all::Bool=false)
            table = getfield(qs, :table)
            filters = getfield(qs, :filters)
            if haskey(filters, "session_key")
                delete!(table, filters["session_key"])
            elseif haskey(filters, "expires_at__lte")
                cutoff_str = filters["expires_at__lte"]
                to_delete = String[]
                for (k, row) in table
                    if row["expires_at"] <= cutoff_str
                        push!(to_delete, k)
                    end
                end
                for k in to_delete
                    delete!(table, k)
                end
            end
            return nothing
        end
    else
        return getfield(qs, name)
    end
end

struct MockModel
    _table::Dict{String, Dict{String, Any}}
end

MockModel() = MockModel(Dict{String, Dict{String, Any}}())

function Base.getproperty(m::MockModel, name::Symbol)
    if name === :objects
        return MockQuerySet(getfield(m, :_table), Dict{String,Any}())
    else
        return getfield(m, name)
    end
end

# ── Load the extension module to get PormGSessionStore ───────────────────

# We can't import the real extension without PormG, so we replicate the
# store locally using the same logic. This validates the contract.

using Nitro.Types: AbstractSessionStore, SessionPayload, get_session, set_session!, delete_session!, cleanup_expired_sessions!

struct TestPormGSessionStore <: AbstractSessionStore{String, Dict{String,Any}}
    model::MockModel
end

function _serialize(data::Dict{String,Any})::String
    return JSON.json(data)
end

function _deserialize(raw::AbstractString)::Dict{String,Any}
    return convert(Dict{String,Any}, JSON.parse(raw))
end

function _dt_value(dt::DateTime)::DateTime
    return dt
end

function _parse_dt(value)::DateTime
    value isa DateTime && return value
    clean = replace(string(value), "Z" => "")
    return Dates.DateTime(clean, dateformat"yyyy-mm-dd\THH:MM:SS")
end

function Base.get(store::TestPormGSessionStore, session_id::String, default)
    result = store.model.objects.filter("session_key" => session_id).first()
    if isnothing(result)
        return default
    end
    expires_at = _parse_dt(result["expires_at"])
    data = _deserialize(result["session_data"])
    return SessionPayload(data, expires_at)
end

function Nitro.Types.get_session(store::TestPormGSessionStore, session_id::String)
    payload = Base.get(store, session_id, nothing)
    if isnothing(payload)
        return nothing
    end
    if payload isa SessionPayload
        if payload.expires <= Dates.now(Dates.UTC)
            return nothing
        end
        return copy(payload.data)
    end
    return payload
end

function Nitro.Types.set_session!(store::TestPormGSessionStore, session_id::String, data::Dict{String,Any}; ttl::Int=3600)
    expires_at = Dates.now(Dates.UTC) + Dates.Second(ttl)
    serialized = _serialize(data)
    expires_value = _dt_value(expires_at)

    existing = store.model.objects.filter("session_key" => session_id).first()
    if isnothing(existing)
        store.model.objects.create(
            "session_key"  => session_id,
            "session_data" => serialized,
            "expires_at"   => expires_value,
        )
    else
        store.model.objects.filter("session_key" => session_id).update(
            "session_data" => serialized,
            "expires_at"   => expires_value,
        )
    end
    return data
end

function Nitro.Types.delete_session!(store::TestPormGSessionStore, session_id::String)
    store.model.objects.filter("session_key" => session_id).delete()
    return nothing
end

function Nitro.Types.cleanup_expired_sessions!(store::TestPormGSessionStore)
    now_value = _dt_value(Dates.now(Dates.UTC))
    store.model.objects.filter("expires_at__lte" => now_value).delete()
    return nothing
end

struct FailingMockModel end

function Base.getproperty(::FailingMockModel, name::Symbol)
    if name === :objects
        return FailingMockModel()
    elseif name === :filter || name === :first || name === :create || name === :update || name === :delete
        return function(args...; kwargs...)
            throw(ErrorException("mock persistence failure"))
        end
    end
    return getfield(FailingMockModel(), name)
end

struct FailingTestPormGSessionStore <: AbstractSessionStore{String, Dict{String,Any}}
    model::FailingMockModel
end

Base.get(store::FailingTestPormGSessionStore, session_id::String, default) = default

function Nitro.Types.set_session!(store::FailingTestPormGSessionStore, session_id::String, data::Dict{String,Any}; ttl::Int=3600)
    expires_at = Dates.now(Dates.UTC) + Dates.Second(ttl)
    serialized = _serialize(data)
    existing = store.model.objects.filter("session_key" => session_id).first()
    if isnothing(existing)
        store.model.objects.create(
            "session_key"  => session_id,
            "session_data" => serialized,
            "expires_at"   => expires_at,
        )
    end
    return data
end

function Nitro.Types.delete_session!(store::FailingTestPormGSessionStore, session_id::String)
    store.model.objects.filter("session_key" => session_id).delete()
    return nothing
end

# ── Tests ────────────────────────────────────────────────────────────────

@testset "PormGSessionStore interface" begin
    store = TestPormGSessionStore(MockModel())

    @test store isa AbstractSessionStore

    @testset "create and read" begin
        set_session!(store, "sess-1", Dict{String,Any}("user_id" => 1); ttl=3600)
        @test store.model._table["sess-1"]["expires_at"] isa DateTime
        result = get_session(store, "sess-1")
        @test result == Dict{String,Any}("user_id" => 1)
    end

    @testset "overwrite" begin
        set_session!(store, "sess-1", Dict{String,Any}("user_id" => 99); ttl=3600)
        result = get_session(store, "sess-1")
        @test result == Dict{String,Any}("user_id" => 99)
    end

    @testset "delete" begin
        delete_session!(store, "sess-1")
        @test get_session(store, "sess-1") === nothing
    end

    @testset "fixed-TTL expiry" begin
        set_session!(store, "short-lived", Dict{String,Any}("temp" => true); ttl=1)
        @test get_session(store, "short-lived") == Dict{String,Any}("temp" => true)

        sleep(1.1)
        @test get_session(store, "short-lived") === nothing
    end

    @testset "cleanup_expired_sessions! deletes only expired" begin
        store2 = TestPormGSessionStore(MockModel())

        set_session!(store2, "active", Dict{String,Any}("a" => 1); ttl=3600)

        # Manually insert expired rows via the mock table
        expired_time = _dt_value(Dates.now(Dates.UTC) - Dates.Second(10))
        store2.model._table["expired1"] = Dict{String,Any}(
            "session_key" => "expired1",
            "session_data" => _serialize(Dict{String,Any}("b" => 2)),
            "expires_at" => expired_time,
        )
        store2.model._table["expired2"] = Dict{String,Any}(
            "session_key" => "expired2",
            "session_data" => _serialize(Dict{String,Any}("c" => 3)),
            "expires_at" => expired_time,
        )

        cleanup_expired_sessions!(store2)

        @test get_session(store2, "active") == Dict{String,Any}("a" => 1)
        @test get_session(store2, "expired1") === nothing
        @test get_session(store2, "expired2") === nothing
    end

    @testset "JSON round-trip preserves data types" begin
        store3 = TestPormGSessionStore(MockModel())

        data = Dict{String,Any}(
            "user_id" => 42,
            "name" => "Alice",
            "roles" => Any["admin", "user"],
            "active" => true,
        )
        set_session!(store3, "json-test", data; ttl=3600)
        result = get_session(store3, "json-test")

        @test result["user_id"] == 42
        @test result["name"] == "Alice"
        @test result["active"] == true
        @test "admin" in result["roles"]
    end

    @testset "persistence failures propagate" begin
        failing_store = FailingTestPormGSessionStore(FailingMockModel())
        @test_throws "mock persistence failure" set_session!(failing_store, "sess-err", Dict{String,Any}("user_id" => 1); ttl=3600)
        @test_throws "mock persistence failure" delete_session!(failing_store, "sess-err")
    end
end

end
