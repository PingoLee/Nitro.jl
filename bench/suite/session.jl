# Session MemoryStore: every read locks one global ReentrantLock and copies the
# payload container (src/types.jl:129-155). Read cost therefore scales with the
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
