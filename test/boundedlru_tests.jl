# `Util.BoundedLRU` (#850): the typed LRU behind `MemoryStore.data` and the `:lazy` mount cache.
# The recency and oversized-entry rules are LRUCache.jl 1.6's, which it replaced; the missing-key
# `delete!`, the iteration rule and the concreteness are Nitro's own contract.

@testitem "BoundedLRU: recency, and which operations refresh it" tags=[:core] setup=[NitroCommon] begin
using Test
using Nitro
const U = Nitro.Util

lru = U.BoundedLRU{String, Int}(3)
lru["a"] = 1; lru["b"] = 2; lru["c"] = 3
# Iteration runs from most to least recent.
@test collect(keys(lru)) == ["c", "b", "a"]

# `haskey`, `length` and iterating do not refresh.
@test haskey(lru, "a")
@test length(lru) == 3
collect(lru)
@test collect(keys(lru)) == ["c", "b", "a"]

# Each of these makes its key the most recent.
@test get(lru, "a", 0) == 1
@test first(keys(lru)) == "a"
@test lru["b"] == 2
@test first(keys(lru)) == "b"
@test get!(() -> error("not called on a hit"), lru, "c") == 3
@test first(keys(lru)) == "c"
@test get!(lru, "a", 99) == 1
@test first(keys(lru)) == "a"
lru["b"] = 20                                       # an overwrite refreshes too
@test collect(keys(lru)) == ["b", "a", "c"]
# A miss refreshes nothing.
@test get(lru, "zz", 0) == 0
@test collect(keys(lru)) == ["b", "a", "c"]

# Eviction takes the least recent: `c`.
lru["d"] = 4
@test collect(keys(lru)) == ["d", "b", "a"]
@test !haskey(lru, "c")
@test_throws KeyError lru["c"]
end

@testitem "BoundedLRU: the count bound and the byte bound" tags=[:core] setup=[NitroCommon] begin
using Test
using Nitro
const U = Nitro.Util

# Count: `maxsize` entries, never more, and an overwrite evicts nothing.
lru = U.BoundedLRU{Int, Int}(2)
for i in 1:10
    lru[i] = i
    @test length(lru) == min(i, 2)
end
@test sort(collect(keys(lru))) == [9, 10]
lru[10] = 100
@test sort(collect(keys(lru))) == [9, 10]
@test_throws ArgumentError U.BoundedLRU{Int, Int}(-1)

# Bytes: the total `by` stays <= maxsize, and a total EQUAL to the budget is kept.
bytes(v::Vector{UInt8}) = sizeof(v)
blru = U.BoundedLRU{String, Vector{UInt8}}(10, bytes)
blru["a"] = zeros(UInt8, 4)
blru["b"] = zeros(UInt8, 6)
@test blru.total == 10
@test sort(collect(keys(blru))) == ["a", "b"]
blru["c"] = zeros(UInt8, 3)                         # 13 > 10: `a`, the least recent, goes
@test sort(collect(keys(blru))) == ["b", "c"]
@test blru.total == 9
blru["d"] = zeros(UInt8, 9)                         # needs both out
@test collect(keys(blru)) == ["d"]
@test blru.total == 9
# Growing an entry in place evicts the others, never itself.
blru["e"] = zeros(UInt8, 1)
blru["e"] = zeros(UInt8, 8)
@test collect(keys(blru)) == ["e"]
@test blru.total == 8
delete!(blru, "e")
@test blru.total == 0
@test isempty(blru)
end

@testitem "BoundedLRU: an entry larger than the whole budget" tags=[:core] setup=[NitroCommon] begin
using Test
using Nitro
const U = Nitro.Util

bytes(v::Vector{UInt8}) = sizeof(v)
lru = U.BoundedLRU{String, Vector{UInt8}}(10, bytes)
lru["small"] = zeros(UInt8, 4)

# Not stored, and nothing evicted for it.
lru["huge"] = zeros(UInt8, 11)
@test !haskey(lru, "huge")
@test collect(keys(lru)) == ["small"]
@test lru.total == 4

# `get!` returns it, still without storing it: a `:lazy` mount serves the file and reads it again.
calls = Ref(0)
v = get!(() -> (calls[] += 1; zeros(UInt8, 11)), lru, "huge")
@test length(v) == 11
@test !haskey(lru, "huge")
get!(() -> (calls[] += 1; zeros(UInt8, 11)), lru, "huge")
@test calls[] == 2
@test collect(keys(lru)) == ["small"]

# An oversized value over a PRESENT key drops the old value rather than keep it stale.
lru["small"] = zeros(UInt8, 12)
@test !haskey(lru, "small")
@test isempty(lru)
@test lru.total == 0
end

@testitem "BoundedLRU: delete! of a missing key is a no-op" tags=[:core] setup=[NitroCommon] begin
using Test
using Nitro
const U = Nitro.Util

# LRUCache.jl threw `KeyError` here, which `MemoryStore` used to guard with a `haskey`.
lru = U.BoundedLRU{String, Int}(2)
lru["a"] = 1
@test delete!(lru, "missing") === lru
@test collect(lru) == ["a" => 1]
delete!(lru, "a")
@test delete!(lru, "a") === lru
@test isempty(lru)

# A `get!` whose function stores the same key: the stored value wins, and the list stays whole
# (the first version inserted twice, leaving an orphan node counted in `total`).
r = get!(lru, "k") do
    lru["k"] = 1
    2
end
@test r == 1
@test collect(lru) == ["k" => 1]
@test lru.total == 1

using Nitro.Types: delete_session!
store = MemoryStore(max_sessions = 2)
@test delete_session!(store, "never-stored") === nothing
end

@testitem "BoundedLRU: iteration under the prune's pattern" tags=[:core] setup=[NitroCommon] begin
using Test
using Nitro
const U = Nitro.Util

lru = U.BoundedLRU{Int, Int}(10)
for i in 1:6
    lru[i] = i
end
# Collect, then delete: what `cleanup_expired_sessions!` does.
odd = [k for (k, v) in lru if isodd(v)]
for k in odd
    delete!(lru, k)
end
@test collect(keys(lru)) == [6, 4, 2]

# Mutating mid-iteration is refused, not silently skipped -- a recency move included.
@test_throws ConcurrencyViolationError (for (k, _) in lru; delete!(lru, k); end)
@test_throws ConcurrencyViolationError (for (k, _) in lru; get(lru, 2, 0); end)
@test_throws ConcurrencyViolationError (for (k, _) in lru; lru[100 + k] = k; end)
end

@testitem "BoundedLRU: get_locked! under a cold-key stampede" tags=[:core] setup=[NitroCommon] begin
using Test
using Nitro
const U = Nitro.Util

bytes(v::Vector{UInt8}) = sizeof(v)
lru = U.BoundedLRU{String, Vector{UInt8}}(1 << 20, bytes)
lk = ReentrantLock()
expected = Vector{UInt8}("the same file, read by every task that missed")
reads = Threads.Atomic{Int}(0)
gate = Base.Event()
function slowread()
    Threads.atomic_add!(reads, 1)
    wait(gate)                     # every task misses before any of them inserts
    return copy(expected)          # a fresh vector per read, like `read(path)`
end

n = 16
tasks = [Threads.@spawn U.get_locked!(slowread, lru, "/f", lk) for _ in 1:n]
# Let the tasks reach the gate (a task that arrives late hits the cache instead: still correct).
deadline = time() + 10
while reads[] < min(n, 4) && time() < deadline
    yield()
end
notify(gate)
results = fetch.(tasks)

@test reads[] >= 1
@test all(==(expected), results)                    # identical bytes for every caller
# The first insert wins and later finishers adopt it: one cached object, which everyone returns.
@test length(lru) == 1
cached = lru["/f"]
@test all(r -> r === cached, results)
# A hit after the stampede does not read.
before = reads[]
@test U.get_locked!(slowread, lru, "/f", lk) === cached
@test reads[] == before
end

@testitem "BoundedLRU: concrete types and static calls (both instantiations)" tags=[:core] setup=[NitroCommon] begin
using Test
using Nitro
using Dates
const U = Nitro.Util
const P = Nitro.Types.SessionPayload{Dict{String, Any}}
const C = Nitro.Core.CachedBody

S = fieldtype(MemoryStore{String, Dict{String, Any}}, :data)
M = fieldtype(Nitro.Core.MountCache, :lru)
@test S === U.BoundedLRU{String, P, typeof(U._count_one)}
@test M === U.BoundedLRU{String, C, typeof(Nitro.Core._body_bytes)}
# No abstract field: the trim verifier needs every call on them static (#748).
for T in (S, M, U.LRUNode{String, P}, U.LRUNode{String, C})
    @test all(isconcretetype, fieldtypes(T))
end

mkP = () -> P(Dict{String, Any}(), now(UTC), now(UTC))
mkC = () -> C(UInt8[], nothing, nothing)
for (L, V, mk) in ((S, P, mkP), (M, C, mkC))
    sigs = (
        (get,               (L, String, V)),
        (get,               (L, String, Nothing)),
        (getindex,          (L, String)),
        (get!,              (typeof(mk), L, String)),
        (setindex!,         (L, V, String)),
        (delete!,           (L, String)),
        (U.get_locked!,     (typeof(mk), L, String, ReentrantLock)),
        (U._insert!,        (L, String, V, Int)),
        (U._evict!,         (L,)),
        (iterate,           (L,)),
    )
    for (f, types) in sigs
        rts = Base.return_types(f, types)
        @test length(rts) == 1
        rt = only(rts)
        # `get(lru, k, nothing)` and `iterate` are small unions with `Nothing` by design.
        @test isconcretetype(rt) || rt == Union{Nothing, V} ||
              (f === iterate && rt == Union{Nothing, Tuple{Pair{String, V}, Tuple{U.LRUNode{String, V}, Int}}})
        @test isempty(dynamic_calls(f, types))
        @test isempty(kwcalls(f, types))
    end
end

# The callers that own the values: `MemoryStore`'s writes, and the mount's read-through.
St = MemoryStore{String, Dict{String, Any}}
@test isempty(dynamic_calls(Nitro.Types.delete_session!, (St, String)))
@test isempty(dynamic_calls(Nitro.Types.cleanup_expired_sessions!, (St,)))
@test only(Base.return_types(Nitro.Core._mount_cache, (Nitro.Core.MountPolicy,))) ==
      Union{Nothing, Nitro.Core.MountCache}
end

@testitem "BoundedLRU: show never prints an entry" tags=[:core] setup=[NitroCommon] begin
using Test
using Nitro

# A `MemoryStore`'s values are sessions: printing the store, or its `data`, must not print them.
using Nitro.Types: set_session!
store = MemoryStore(max_sessions = 4)
set_session!(store, "sid-SENTINEL-KEY", Dict{String, Any}("token" => "SENTINEL-VALUE"))
for s in (repr(store), repr(store.data), sprint(show, MIME"text/plain"(), store.data),
          sprint(show, MIME"text/plain"(), store))
    @test !occursin("SENTINEL", s)
end
@test occursin("(length = 1, maxsize = 4)", repr(store.data))
end
