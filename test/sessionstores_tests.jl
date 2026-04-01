@testitem "Session stores" tags=[:core] setup=[NitroCommon] begin

using Test
using HTTP
using Dates
using Nitro
using Nitro.Types: AbstractSessionStore, MemoryStore, SessionPayload
using Nitro.Types: get_session, set_session!, delete_session!, cleanup_expired_sessions!

@testset "Session store interface" begin
    store = MemoryStore{String, Dict{String,Any}}()

    @test store isa AbstractSessionStore

    set_session!(store, "abc", Dict{String,Any}("user_id" => 1); ttl=60)
    @test get_session(store, "abc") == Dict{String,Any}("user_id" => 1)

    delete_session!(store, "abc")
    @test get_session(store, "abc") === nothing

    lock(store.lock) do
        store.data["expired"] = SessionPayload(Dict{String,Any}("user_id" => 2), Dates.now(Dates.UTC) - Dates.Second(5))
    end
    cleanup_expired_sessions!(store)
    @test !haskey(store.data, "expired")
end

@testset "req.user shorthand" begin
    req = HTTP.Request("GET", "/")
    req.context[:user] = Dict{String,Any}("id" => 7)
    @test req.user["id"] == 7
end

end