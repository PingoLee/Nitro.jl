@testitem "Session stores" tags=[:core] setup=[NitroCommon] begin

using Test
using HTTP
using Dates
using Nitro
using Nitro.Types: AbstractSessionStore, MemoryStore, SessionPayload
using Nitro.Types: get_session, set_session!, update_session!, rotate_session!, delete_session!, cleanup_expired_sessions!
using Nitro.Types: missing_session_methods
using Nitro.Errors: StoreInterfaceError

struct FailingSessionStore <: AbstractSessionStore{String, Dict{String,Any}} end

struct RotateFailingSessionStore <: AbstractSessionStore{String, Dict{String,Any}} end

mutable struct DelegatingSessionStore <: AbstractSessionStore{String, Dict{String,Any}}
    data::Dict{String, SessionPayload{Dict{String,Any}}}
    prune_calls::Int
end

DelegatingSessionStore() = DelegatingSessionStore(Dict{String, SessionPayload{Dict{String,Any}}}(), 0)

Base.get(::FailingSessionStore, ::String, default) = default
Base.get(::RotateFailingSessionStore, ::String, default) = default
Base.get(store::DelegatingSessionStore, key::String, default) = get(store.data, key, default)

function Nitro.Types.set_session!(::FailingSessionStore, ::String, ::Dict{String,Any}; ttl::Int=3600)
    throw(ErrorException("session write failed"))
end

function Nitro.Types.delete_session!(::FailingSessionStore, ::String)
    throw(ErrorException("session delete failed"))
end

Nitro.Types.cleanup_expired_sessions!(::FailingSessionStore) = nothing

# The rotation's removal of the old id now happens INSIDE `rotate_session!` (#361), so a store that
# cannot remove it fails there; this used to be a `DeleteFailingSessionStore`.
function Nitro.Types.set_session!(::RotateFailingSessionStore, ::String, value::Dict{String,Any}; ttl::Int=3600)
    return value
end

function Nitro.Types.rotate_session!(::RotateFailingSessionStore, ::String, ::String, ::Dict{String,Any}; ttl::Int=3600)
    throw(ErrorException("session rotate failed"))
end

Nitro.Types.cleanup_expired_sessions!(::RotateFailingSessionStore) = nothing

function Nitro.Types.set_session!(store::DelegatingSessionStore, session_id::String, value::Dict{String,Any}; ttl::Int=3600)
    now = Dates.now(Dates.UTC)
    store.data[session_id] = SessionPayload(copy(value), now + Dates.Second(ttl), now)
    return value
end

function Nitro.Types.update_session!(store::DelegatingSessionStore, session_id::String, value::Dict{String,Any}; ttl::Int=3600)
    payload = get(store.data, session_id, nothing)
    (payload === nothing || Nitro.Types.is_expired(payload)) && return false
    store.data[session_id] = SessionPayload(copy(value), Dates.now(Dates.UTC) + Dates.Second(ttl),
                                            payload.created)
    return true
end

function Nitro.Types.rotate_session!(store::DelegatingSessionStore, old_id::String, new_id::String,
                                     value::Dict{String,Any}; ttl::Int=3600)
    payload = get(store.data, old_id, nothing)
    (payload === nothing || Nitro.Types.is_expired(payload)) && return false
    delete!(store.data, old_id)
    store.data[new_id] = SessionPayload(copy(value), Dates.now(Dates.UTC) + Dates.Second(ttl),
                                        payload.created)
    return true
end

function Nitro.Types.delete_session!(store::DelegatingSessionStore, session_id::String)
    delete!(store.data, session_id)
    return nothing
end

function Nitro.Types.cleanup_expired_sessions!(store::DelegatingSessionStore)
    store.prune_calls += 1
    return nothing
end

# Implements nothing at all -- the shape a half-finished custom backend has.
struct BareSessionStore <: AbstractSessionStore{String, Dict{String,Any}} end

# Implements cleanup, but its body raises a `MethodError` whose `.f` is
# `cleanup_expired_sessions!` itself. The old `prunesessions!` rescue matched on exactly that
# identity and silently discarded it.
struct SelfMethodErrorStore <: AbstractSessionStore{String, Dict{String,Any}} end

function Nitro.Types.cleanup_expired_sessions!(store::SelfMethodErrorStore)
    return cleanup_expired_sessions!(store, :an_unsupported_arity)
end

@testset "Session store contract is discoverable and loud" begin
    @test isempty(missing_session_methods(MemoryStore{String, Dict{String,Any}}))

    # The probe is written against the store's own `K`/`V`, not `Any`. `MemoryStore`'s
    # `set_session!` is typed `(::MemoryStore{K,V}, ::K, ::V)`, so an `Any` probe would report
    # a conforming store as broken -- the line above would then pass for the wrong reason only
    # because it is checking something that can fail here.
    missing_names = missing_session_methods(BareSessionStore)
    @test :get in missing_names
    @test :set_session! in missing_names
    @test :update_session! in missing_names
    @test :rotate_session! in missing_names
    @test :delete_session! in missing_names
    @test isempty(missing_session_methods(DelegatingSessionStore))

    # `cleanup_expired_sessions!` is optional, so it is never reported and never throws.
    @test !(:cleanup_expired_sessions! in missing_names)
    @test cleanup_expired_sessions!(BareSessionStore()) === nothing

    # `Base.get` is the one required method the declared contract used to omit entirely; a store
    # that forgets it used to fail with a bare `MethodError` raised from inside `get_session`.
    for thunk in (() -> Base.get(BareSessionStore(), "sid", nothing),
                  () -> set_session!(BareSessionStore(), "sid", Dict{String,Any}(); ttl=60),
                  () -> update_session!(BareSessionStore(), "sid", Dict{String,Any}(); ttl=60),
                  () -> rotate_session!(BareSessionStore(), "sid", "new", Dict{String,Any}(); ttl=60),
                  () -> delete_session!(BareSessionStore(), "sid"))
        err = try
            thunk()
            nothing
        catch e
            e
        end
        @test err isa StoreInterfaceError
        @test err.store_type === BareSessionStore
        @test occursin("BareSessionStore", sprint(showerror, err))
    end

    # A store with no cleanup prunes to a no-op rather than an error...
    @test Nitro.Core.Cookies.prunesessions!(BareSessionStore()) === nothing

    # ...but a genuine `MethodError` from inside a store that DOES implement cleanup now
    # propagates instead of being swallowed by an identity match on `.f`.
    @test_throws MethodError Nitro.Core.Cookies.prunesessions!(SelfMethodErrorStore())
end

@testset "Session store interface" begin
    store = MemoryStore{String, Dict{String,Any}}()

    @test store isa AbstractSessionStore

    set_session!(store, "abc", Dict{String,Any}("user_id" => 1); ttl=60)
    @test get_session(store, "abc") == Dict{String,Any}("user_id" => 1)

    delete_session!(store, "abc")
    @test get_session(store, "abc") === nothing

    lock(store.lock) do
        store.data["expired"] = SessionPayload(Dict{String,Any}("user_id" => 2), Dates.now(Dates.UTC) - Dates.Second(5), Dates.now(Dates.UTC))
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

    # The expiry is fixed at write time. Check it from the stored payload rather than an
    # immediate read of a 1 s session, which a slow first call can overrun (#305).
    t0 = Dates.now(Dates.UTC)
    set_session!(store, "ttl-test", Dict{String,Any}("role" => "admin"); ttl=1)
    t1 = Dates.now(Dates.UTC)
    @test t0 + Dates.Second(1) <= store.data["ttl-test"].expires <= t1 + Dates.Second(1)
    set_session!(store, "live", Dict{String,Any}("role" => "user"); ttl=3600)

    sleep(1.1)
    @test get_session(store, "ttl-test") === nothing
    @test get_session(store, "live") == Dict{String,Any}("role" => "user")
end

@testset "cleanup_expired_sessions! leaves non-expired rows" begin
    store = MemoryStore{String, Dict{String,Any}}()

    set_session!(store, "active", Dict{String,Any}("a" => 1); ttl=3600)
    lock(store.lock) do
        store.data["expired1"] = SessionPayload(Dict{String,Any}("b" => 2), Dates.now(Dates.UTC) - Dates.Second(10), Dates.now(Dates.UTC))
        store.data["expired2"] = SessionPayload(Dict{String,Any}("c" => 3), Dates.now(Dates.UTC) - Dates.Second(5), Dates.now(Dates.UTC))
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

# #318: `set_session!` upserts, so the middleware's write-back of a session a concurrent logout had
# deleted re-created it. `update_session!` is the write that refuses a row that has gone.
@testset "MemoryStore update_session! never creates a row (#318)" begin
    store = MemoryStore{String, Dict{String,Any}}()

    # Absent: nothing to update, and nothing is written.
    @test update_session!(store, "gone", Dict{String,Any}("user_id" => 42); ttl=3600) === false
    @test !haskey(store.data, "gone")

    # Expired: refused on the same `is_expired` boundary every read uses, and left as it was --
    # an expired row is the prune's to remove, not the write path's to revive.
    stale_expiry = Dates.now(Dates.UTC) - Dates.Second(5)
    lock(store.lock) do
        store.data["stale"] = SessionPayload(Dict{String,Any}("user_id" => 1), stale_expiry, stale_expiry - Dates.Hour(1))
    end
    @test update_session!(store, "stale", Dict{String,Any}("user_id" => 2); ttl=3600) === false
    @test store.data["stale"].expires == stale_expiry
    @test store.data["stale"].data == Dict{String,Any}("user_id" => 1)

    # Present: overwritten, with the expiry moved to `ttl` from now.
    set_session!(store, "live", Dict{String,Any}("v" => 1); ttl=10)
    t0 = Dates.now(Dates.UTC)
    @test update_session!(store, "live", Dict{String,Any}("v" => 2); ttl=3600) === true
    @test get_session(store, "live") == Dict{String,Any}("v" => 2)
    @test store.data["live"].expires >= t0 + Dates.Second(3600)

    # The logout interleaving at the store level: deleted between load and write-back.
    delete_session!(store, "live")
    @test update_session!(store, "live", Dict{String,Any}("v" => 3); ttl=3600) === false
    @test get_session(store, "live") === nothing
end

# #317: `MemoryStore` was an unbounded `Dict` that pruning shrank only by EXPIRED rows, so a flood
# of new sessions grew it until the process ran out of memory.
@testset "MemoryStore is bounded and evicts the least recently used session (#317)" begin
    @test MemoryStore().max_sessions == 100_000
    @test MemoryStore{String, Dict{String,Any}}().max_sessions == 100_000
    @test_throws ArgumentError MemoryStore(max_sessions = 0)
    @test_throws ArgumentError MemoryStore(max_sessions = -1)

    store = MemoryStore(max_sessions = 3)
    session(v) = Dict{String,Any}("v" => v)
    set_session!(store, "a", session(1); ttl=3600)
    set_session!(store, "b", session(2); ttl=3600)

    # Filling the store warns -- once.
    @test_logs (:warn, r"MemoryStore is full") set_session!(store, "c", session(3); ttl=3600)

    # Reading `a` makes it the most recently used, so `b` is now the one to go.
    @test get_session(store, "a") == session(1)
    @test_logs min_level=Base.CoreLogging.Warn set_session!(store, "d", session(4); ttl=3600)
    @test length(store.data) == 3
    @test get_session(store, "b") === nothing
    @test get_session(store, "a") == session(1)
    @test get_session(store, "c") == session(3)
    @test get_session(store, "d") == session(4)

    # Overwriting a key that is present evicts nothing.
    set_session!(store, "d", session(40); ttl=3600)
    @test length(store.data) == 3
    @test update_session!(store, "c", session(30); ttl=3600)
    @test sort(collect(keys(store.data))) == ["a", "c", "d"]

    # The prune still works on the LRU.
    lock(store.lock) do
        store.data["a"] = SessionPayload(session(1), Dates.now(Dates.UTC) - Dates.Second(1), Dates.now(Dates.UTC))
    end
    cleanup_expired_sessions!(store)
    @test sort(collect(keys(store.data))) == ["c", "d"]
end

# #318: a stored value and a request's value must never be the same object. A shallow copy
# shared nested vectors and dicts between the store and every concurrent request of a session.
@testset "MemoryStore isolates nested values from callers (#318)" begin
    store = MemoryStore{String, Dict{String,Any}}()

    # Write side: the caller keeps mutating the dict it handed over -- `regenerate_session!`
    # hands over the request's live session, and the handler carries on after it.
    live = Dict{String,Any}("cart" => [1], "prefs" => Dict{String,Any}("theme" => "dark"))
    set_session!(store, "sid", live; ttl=3600)
    push!(live["cart"], 2)
    live["prefs"]["theme"] = "light"
    @test store.data["sid"].data["cart"] == [1]
    @test store.data["sid"].data["prefs"]["theme"] == "dark"

    update_session!(store, "sid", live; ttl=3600)
    push!(live["cart"], 3)
    @test store.data["sid"].data["cart"] == [1, 2]

    # Read side: two readers of one session do not share a nested value, with each other or
    # with the store.
    a = get_session(store, "sid")
    b = get_session(store, "sid")
    push!(a["cart"], 99)
    @test b["cart"] == [1, 2]
    @test store.data["sid"].data["cart"] == [1, 2]
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
        secure=false,
    ).middleware

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
        secure=false,
    ).middleware

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
        secure=false,
    ).middleware

    handler = function(req::HTTP.Request)
        getsession(req)["user_id"] = 99
        return HTTP.Response(200, "logged in")
    end

    @test_throws "session write failed" middleware(handler)(HTTP.Request("GET", "/login"))
end

@testset "regenerate_session! fails closed on store rotate errors" begin
    store = RotateFailingSessionStore()
    req = HTTP.Request("GET", "/")
    req.context[:session_id] = "old-session-id"
    req.context[:session] = Dict{String,Any}("user_id" => 42)

    # A store FAILURE propagates; it is never read as "the session was logged out".
    @test_throws "session rotate failed" Nitro.regenerate_session!(req, store; ttl=3600)
    @test req.context[:session_id] == "old-session-id"
end

# ── #361: rotation after a concurrent logout ─────────────────────────────────
#
# `regenerate_session!` used to `set_session!(new_id, data)` and then delete the old id without
# checking it still existed, so a request that rotated after a concurrent logout copied the
# logged-out identity into a fresh id. `rotate_session!` is the atomic move that refuses a gone id.
@testset "MemoryStore rotate_session! moves a live session and never creates one (#361)" begin
    store = MemoryStore()
    set_session!(store, "old", Dict{String,Any}("user_id" => 42); ttl=3600)
    handed = Dict{String,Any}("user_id" => 42, "cart" => [1])
    @test rotate_session!(store, "old", "new", handed; ttl=60) === true
    @test get_session(store, "old") === nothing
    @test get_session(store, "new") == Dict{String,Any}("user_id" => 42, "cart" => [1])
    # The fresh expiry is `ttl` from now, not the old row's.
    @test store.data["new"].expires <= Dates.now(Dates.UTC) + Dates.Second(60)
    # A deep copy is stored: the caller keeps mutating the dict it handed over.
    push!(handed["cart"], 2)
    @test get_session(store, "new")["cart"] == [1]

    # Gone -- a concurrent logout deleted it: nothing is moved, and `new` is never created.
    @test rotate_session!(store, "gone", "fresh", Dict{String,Any}("user_id" => 42); ttl=3600) === false
    @test !haskey(store.data, "fresh")

    # Expired counts as gone, and the store is left unchanged.
    lock(store.lock) do
        store.data["stale"] = SessionPayload(Dict{String,Any}("user_id" => 7),
                                             Dates.now(Dates.UTC) - Dates.Second(1), Dates.now(Dates.UTC))
    end
    @test rotate_session!(store, "stale", "fresh", Dict{String,Any}("user_id" => 7); ttl=3600) === false
    @test !haskey(store.data, "fresh")
    @test haskey(store.data, "stale")

    # At capacity a rotation evicts nobody else: the old id goes before the new one arrives.
    full = MemoryStore(max_sessions = 2)
    set_session!(full, "a", Dict{String,Any}("v" => 1); ttl=3600)
    set_session!(full, "b", Dict{String,Any}("v" => 2); ttl=3600)
    @test rotate_session!(full, "a", "c", Dict{String,Any}("v" => 1); ttl=3600) === true
    @test get_session(full, "b") == Dict{String,Any}("v" => 2)
    @test get_session(full, "c") == Dict{String,Any}("v" => 1)
    @test length(full.data) == 2
end

@testset "regenerate_session! does not revive a logged-out session (#361)" begin
    store = MemoryStore()
    set_session!(store, "S", Dict{String,Any}("user_id" => 42); ttl=3600)

    req = HTTP.Request("GET", "/")
    req.context[:session_id] = "S"
    req.context[:session] = Dict{String,Any}("user_id" => 42)

    delete_session!(store, "S")   # the concurrent logout, landing before the rotation

    @test Nitro.regenerate_session!(req, store; ttl=3600) === nothing
    @test req.context[:session_id] == "S"   # no new id for the middleware to hand out
    @test isempty(store.data)               # and `user_id = 42` was copied nowhere
end

# ── #362: a session's creation instant ───────────────────────────────────────
#
# `SessionMiddleware(absolute_max_age = …)` measures from `SessionPayload.created`, so a store
# that moved it on every write would let a session live forever.
@testset "MemoryStore stamps, keeps and carries a session's creation instant (#362)" begin
    store = MemoryStore()

    # Stamped on insert, from the same clock read as the expiry.
    before = Dates.now(Dates.UTC)
    set_session!(store, "s", Dict{String,Any}("v" => 1); ttl=60)
    after = Dates.now(Dates.UTC)
    stamped = store.data["s"]
    @test before <= stamped.created <= after
    @test stamped.expires == stamped.created + Dates.Second(60)

    # Kept by an update: the expiry slides, `created` does not.
    born = Dates.now(Dates.UTC) - Dates.Day(3)
    lock(store.lock) do
        store.data["old"] = SessionPayload(Dict{String,Any}("v" => 1),
                                           Dates.now(Dates.UTC) + Dates.Hour(1), born)
    end
    @test update_session!(store, "old", Dict{String,Any}("v" => 2); ttl=3600)
    @test store.data["old"].created == born
    @test store.data["old"].expires > Dates.now(Dates.UTC) + Dates.Minute(59)

    # Carried by a rotation: renaming a session does not start a new one.
    @test rotate_session!(store, "old", "renamed", Dict{String,Any}("v" => 3); ttl=3600)
    @test store.data["renamed"].created == born

    # `set_session!` stores a FRESH session, so overwriting an id restarts its clock. The
    # middleware only ever calls it for an id minted in the same request.
    set_session!(store, "renamed", Dict{String,Any}("v" => 4); ttl=3600)
    @test store.data["renamed"].created > born
end

@testset "regenerate_session! carries the clock, even for an empty session (#362)" begin
    store = MemoryStore()
    born = Dates.now(Dates.UTC) - Dates.Day(3)
    for (id, data) in (("full", Dict{String,Any}("user_id" => 1)), ("empty", Dict{String,Any}()))
        lock(store.lock) do
            store.data[id] = SessionPayload(data, Dates.now(Dates.UTC) + Dates.Hour(1), born)
        end
    end
    rotate(id, data) = (req = HTTP.Request("GET", "/"); req.context[:session_id] = id;
                        req.context[:session] = data; Nitro.regenerate_session!(req, store; ttl=3600))

    kept = rotate("full", Dict{String,Any}("user_id" => 1))
    @test store.data[kept].created == born
    # An empty one too. The logout recipe's fresh clock is `SessionMiddleware`'s to give, on the
    # session's FINAL contents: deciding here, mid-handler, let a handler that emptied, rotated and
    # then restored the identity hand a stolen session a fresh week.
    also = rotate("empty", Dict{String,Any}())
    @test store.data[also].created == born
    @test !haskey(store.data, "empty")
end

@testset "regenerate_session! on a session minted in this request (#361)" begin
    # `SessionMiddleware` marks a new visitor's id `:session_new`: it has never been stored, so
    # there is nothing for `rotate_session!` to move -- and it must not read that as a logout,
    # or a first-time visitor's login would never rotate.
    store = MemoryStore()
    req = HTTP.Request("GET", "/")
    req.context[:session_id] = "minted"
    req.context[:session_new] = true
    req.context[:session] = Dict{String,Any}("user_id" => 5)

    new_id = Nitro.regenerate_session!(req, store; ttl=3600)
    @test new_id isa String && new_id != "minted"
    @test req.context[:session_id] == new_id
    @test isempty(store.data)   # the middleware inserts it on the way out
end

@testset "getuser accessor" begin
    req = HTTP.Request("GET", "/")
    req.context[:user] = Dict{String,Any}("id" => 7)
    @test getuser(req)["id"] == 7
end

end