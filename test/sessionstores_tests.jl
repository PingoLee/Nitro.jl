@testitem "Session stores" tags=[:core] setup=[NitroCommon] begin

using Test
using HTTP
using Dates
using Nitro
using Nitro.Types: AbstractSessionStore, MemoryStore, SessionPayload
using Nitro.Types: get_session, set_session!, delete_session!, cleanup_expired_sessions!

struct FailingSessionStore <: AbstractSessionStore{String, Dict{String,Any}} end

struct DeleteFailingSessionStore <: AbstractSessionStore{String, Dict{String,Any}} end

mutable struct DelegatingSessionStore <: AbstractSessionStore{String, Dict{String,Any}}
    data::Dict{String, SessionPayload{Dict{String,Any}}}
    prune_calls::Int
end

DelegatingSessionStore() = DelegatingSessionStore(Dict{String, SessionPayload{Dict{String,Any}}}(), 0)

Base.get(::FailingSessionStore, ::String, default) = default
Base.get(::DeleteFailingSessionStore, ::String, default) = default
Base.get(store::DelegatingSessionStore, key::String, default) = get(store.data, key, default)

function Nitro.Types.set_session!(::FailingSessionStore, ::String, ::Dict{String,Any}; ttl::Int=3600)
    throw(ErrorException("session write failed"))
end

function Nitro.Types.delete_session!(::FailingSessionStore, ::String)
    throw(ErrorException("session delete failed"))
end

Nitro.Types.cleanup_expired_sessions!(::FailingSessionStore) = nothing

function Nitro.Types.set_session!(::DeleteFailingSessionStore, ::String, value::Dict{String,Any}; ttl::Int=3600)
    return value
end

function Nitro.Types.delete_session!(::DeleteFailingSessionStore, ::String)
    throw(ErrorException("session delete failed"))
end

Nitro.Types.cleanup_expired_sessions!(::DeleteFailingSessionStore) = nothing

function Nitro.Types.set_session!(store::DelegatingSessionStore, session_id::String, value::Dict{String,Any}; ttl::Int=3600)
    store.data[session_id] = SessionPayload(copy(value), Dates.now(Dates.UTC) + Dates.Second(ttl))
    return value
end

function Nitro.Types.delete_session!(store::DelegatingSessionStore, session_id::String)
    delete!(store.data, session_id)
    return nothing
end

function Nitro.Types.cleanup_expired_sessions!(store::DelegatingSessionStore)
    store.prune_calls += 1
    return nothing
end

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

@testset "Cookie session helpers delegate to store interface" begin
    store = DelegatingSessionStore()

    Nitro.Core.Cookies.storesession!(store, "delegated", Dict{String,Any}("user_id" => 7); ttl=60)
    @test get_session(store, "delegated") == Dict{String,Any}("user_id" => 7)

    Nitro.Core.Cookies.prunesessions!(store)
    @test store.prune_calls == 1
end

@testset "MemoryStore fixed-TTL expiry" begin
    store = MemoryStore{String, Dict{String,Any}}()

    set_session!(store, "ttl-test", Dict{String,Any}("role" => "admin"); ttl=1)
    @test get_session(store, "ttl-test") == Dict{String,Any}("role" => "admin")

    sleep(1.1)
    @test get_session(store, "ttl-test") === nothing
end

@testset "cleanup_expired_sessions! leaves non-expired rows" begin
    store = MemoryStore{String, Dict{String,Any}}()

    set_session!(store, "active", Dict{String,Any}("a" => 1); ttl=3600)
    lock(store.lock) do
        store.data["expired1"] = SessionPayload(Dict{String,Any}("b" => 2), Dates.now(Dates.UTC) - Dates.Second(10))
        store.data["expired2"] = SessionPayload(Dict{String,Any}("c" => 3), Dates.now(Dates.UTC) - Dates.Second(5))
    end

    cleanup_expired_sessions!(store)

    @test haskey(store.data, "active")
    @test !haskey(store.data, "expired1")
    @test !haskey(store.data, "expired2")
end

@testset "MemoryStore overwrite" begin
    store = MemoryStore{String, Dict{String,Any}}()

    set_session!(store, "overwrite", Dict{String,Any}("v" => 1); ttl=3600)
    @test get_session(store, "overwrite") == Dict{String,Any}("v" => 1)

    set_session!(store, "overwrite", Dict{String,Any}("v" => 2); ttl=3600)
    @test get_session(store, "overwrite") == Dict{String,Any}("v" => 2)
end

@testset "regenerate_session! against MemoryStore" begin
    store = MemoryStore{String, Dict{String,Any}}()

    old_id = "old-session-id"
    session_data = Dict{String,Any}("user_id" => 42, "role" => "admin")
    set_session!(store, old_id, session_data; ttl=3600)

    req = HTTP.Request("GET", "/")
    req.context[:session_id] = old_id
    req.context[:session] = copy(session_data)

    new_id = Nitro.regenerate_session!(req, store; ttl=3600)

    # New ID is different from old
    @test new_id != old_id
    @test !isempty(new_id)

    # Old session is gone
    @test get_session(store, old_id) === nothing

    # New session has the same data
    @test get_session(store, new_id) == session_data

    # Request context updated
    @test req.context[:session_id] == new_id
end

@testset "regenerate_session! with no prior session" begin
    store = MemoryStore{String, Dict{String,Any}}()

    req = HTTP.Request("GET", "/")
    req.context[:session] = Dict{String,Any}("fresh" => true)
    # No :session_id set

    new_id = Nitro.regenerate_session!(req, store; ttl=3600)

    @test !isempty(new_id)
    @test get_session(store, new_id) == Dict{String,Any}("fresh" => true)
    @test req.context[:session_id] == new_id
end

@testset "regenerate_session! integration with SessionMiddleware" begin
    store = MemoryStore{String, Dict{String,Any}}()
    original_id = Ref{String}("")
    regenerated_id = Ref{String}("")

    middleware = SessionMiddleware(
        cookie_name="sid",
        max_age=3600,
        store=store,
        prune_probability=0.0,
        secure=false,
    )

    # 1. Login handler: creates session, then regenerates
    login_handler = function(req::HTTP.Request)
        original_id[] = req.context[:session_id]
        getsession(req)["user_id"] = 99
        regenerated_id[] = Nitro.regenerate_session!(req, store; ttl=3600)
        return HTTP.Response(200, "logged in")
    end

    login_response = middleware(login_handler)(HTTP.Request("GET", "/login"))
    cookie_header = HTTP.header(login_response, "Set-Cookie")
    @test occursin("sid=", cookie_header)

    # Extract the session ID from the cookie
    m = match(r"sid=([^;]+)", cookie_header)
    @test !isnothing(m)
    new_sid = String(m.captures[1])
    @test new_sid == regenerated_id[]
    @test new_sid != original_id[]
    @test get_session(store, original_id[]) === nothing
    @test get_session(store, new_sid) == Dict{String,Any}("user_id" => 99)

    # 2. Access session with the new ID
    protected_handler = function(req::HTTP.Request)
        session = getsession(req)
        return HTTP.Response(200, string(get(session, "user_id", "none")))
    end

    req2 = HTTP.Request("GET", "/dashboard", ["Cookie" => "sid=$new_sid"])
    response2 = middleware(protected_handler)(req2)
    @test String(response2.body) == "99"
end

@testset "SessionMiddleware auto-rotates when auth key changes" begin
    store = MemoryStore{String, Dict{String,Any}}()
    original_id = "anon-session"
    set_session!(store, original_id, Dict{String,Any}("cart" => [7]); ttl=3600)

    middleware = SessionMiddleware(
        cookie_name="sid",
        max_age=3600,
        store=store,
        prune_probability=0.0,
        secure=false,
    )

    login_handler = function(req::HTTP.Request)
        getsession(req)["user_id"] = 77
        return HTTP.Response(200, "logged in")
    end

    response = middleware(login_handler)(HTTP.Request("GET", "/login", ["Cookie" => "sid=$original_id"]))
    cookie_header = HTTP.header(response, "Set-Cookie")
    rotated_id = String(match(r"sid=([^;]+)", cookie_header).captures[1])

    @test rotated_id != original_id
    @test get_session(store, original_id) === nothing
    @test get_session(store, rotated_id) == Dict{String,Any}("cart" => [7], "user_id" => 77)
end

@testset "SessionMiddleware fails closed on store write errors" begin
    middleware = SessionMiddleware(
        cookie_name="sid",
        max_age=3600,
        store=FailingSessionStore(),
        prune_probability=0.0,
        secure=false,
    )

    handler = function(req::HTTP.Request)
        getsession(req)["user_id"] = 99
        return HTTP.Response(200, "logged in")
    end

    @test_throws "session write failed" middleware(handler)(HTTP.Request("GET", "/login"))
end

@testset "regenerate_session! fails closed on store delete errors" begin
    store = DeleteFailingSessionStore()
    req = HTTP.Request("GET", "/")
    req.context[:session_id] = "old-session-id"
    req.context[:session] = Dict{String,Any}("user_id" => 42)

    @test_throws "session delete failed" Nitro.regenerate_session!(req, store; ttl=3600)
end

@testset "req.user shorthand" begin
    req = HTTP.Request("GET", "/")
    req.context[:user] = Dict{String,Any}("id" => 7)
    @test req.user["id"] == 7
end

end