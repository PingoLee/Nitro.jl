# Session MemoryStore: every read locks one global ReentrantLock and copies the
# payload container (src/types.jl:268-301). Read cost therefore scales with the
# SESSION PAYLOAD size (keys in the session's own Dict), independent of store size.
SUITE["session"] = BenchmarkGroup()

function make_store(payload_keys::Int)
    store = Nitro.Core.Types.MemoryStore{String,Dict{String,Any}}()
    payload = Dict{String,Any}("k$i" => i for i in 1:payload_keys)
    for s in 1:1000  # realistic store population; Dict lookup itself is O(1)
        Nitro.Core.Types.set_session!(store, "sid-$s", copy(payload))
    end
    return store
end

const STORE_P5 = make_store(5)
const STORE_P500 = make_store(500)

SUITE["session"]["get_payload5"] = @benchmarkable Nitro.Core.Types.get_session(STORE_P5, "sid-500")
SUITE["session"]["get_payload500"] = @benchmarkable Nitro.Core.Types.get_session(STORE_P500, "sid-500")
SUITE["session"]["set_payload5"] = @benchmarkable Nitro.Core.Types.set_session!(STORE_P5, "sid-1", v) setup=(
    v = Dict{String,Any}("k$i" => i for i in 1:5))

# The middleware around the store (#547): a loaded session's request pays the store read above
# plus the handler's deep copy and the change check's baseline; a cookieless one, the id mint.
# The session is written with a TTL that is neither lifetime the middleware writes, so loading it
# forces no write-back.
const STORE_MW = let s = Nitro.Core.Types.MemoryStore{String,Dict{String,Any}}()
    Nitro.Core.Types.set_session!(s, "sid-mw", Dict{String,Any}("cart" => Any[1, 2, 3], "user_id" => 7); ttl = 7200)
    s
end
const SESSION_MW = Nitro.SessionMiddleware(cookie_name = "sid", store = STORE_MW).middleware(
    req -> HTTP.Response(200, "ok"))

SUITE["session"]["middleware_loaded"] = @benchmarkable SESSION_MW(r) setup=(
    r = HTTP.Request("GET", "/", ["Cookie" => "sid=sid-mw"])) evals=1
SUITE["session"]["middleware_cookieless"] = @benchmarkable SESSION_MW(r) setup=(
    r = HTTP.Request("GET", "/")) evals=1
