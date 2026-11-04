# Included into `Util`, and not exported: an internal type behind `MemoryStore.data` and the `:lazy`
# static-mount cache (#850). It replaced LRUCache.jl's `LRU`, whose `by` and `finalizer` fields
# were `Any` and called on every insert -- one dynamic call per write under the JIT, a
# `MethodError` in a `juliac --trim` image (docs/design/juliac-trim.md §3.11).

# One entry, linked into the recency list.
mutable struct LRUNode{K, V}
    key::K
    value::V
    size::Int
    prev::LRUNode{K, V}
    next::LRUNode{K, V}

    LRUNode{K, V}(key::K, value::V, size::Int) where {K, V} = new{K, V}(key, value, size)

    # The sentinel: its key and value are never read.
    function LRUNode{K, V}() where {K, V}
        n = new{K, V}()
        n.prev = n
        n.next = n
        return n
    end
end

"""
    BoundedLRU{K, V}(maxsize::Int)
    BoundedLRU{K, V}(maxsize::Int, by)

A least-recently-used map whose entries' total `by(value)` never exceeds `maxsize`. `by` defaults
to counting entries (`_count_one`); the static-mount cache passes a byte measure. `by` is a type
parameter, so every call to it is static, and must return an `Int`.

The contract, which is Nitro's to keep now that the type is:

- **Recency.** `get(lru, k, default)` on a hit, `lru[k]`, `get!` on a hit and `lru[k] = v` make `k`
  the most recently used; a new key enters as the most recent. `haskey`, `length` and iteration
  leave the order alone. This is LRUCache.jl 1.6's behaviour, kept on purpose: it decides which
  session a full `MemoryStore` drops.
- **Eviction** runs from the least recent end while the total exceeds `maxsize`, so a total equal
  to the budget is kept. It never evicts the entry just written.
- **An entry larger than the whole budget is not stored,** and nothing is evicted for it: `get!`
  still returns it (a `:lazy` mount serves an oversized file and reads it again next time, leaving
  the cache as it was), and `lru[k] = v` over a present `k` removes the old entry, since keeping a
  stale value under `k` would be wrong. Also LRUCache.jl 1.6's behaviour; changing it would change
  what a `:lazy` mount holds.
- **`delete!` of a missing key is a no-op,** as for `Dict`.
- **Iteration** runs from most to least recent, and **any mutation invalidates it** -- a recency
  move included, since a hit relinks a node. The iterator checks, and throws a
  `ConcurrencyViolationError` rather than skip or repeat an entry. To delete while sweeping,
  collect the keys first.
- **No lock of its own.** Each owner holds exactly one: `MemoryStore` already locks every compound
  operation, so an internal lock would have been a second lock with an overlapping duty. A shared
  `BoundedLRU` must only be touched under its owner's lock; [`get_locked!`](@ref) is the
  read-through protocol for an owner that computes a missing value outside it. This is the split
  Go's `groupcache/lru` and `hashicorp/golang-lru`'s `simplelru` make: an unsynchronized core, and
  the lock where the compound operations are.

`show` prints the type, the length and the bound, never an entry: a `MemoryStore`'s values are
sessions.
"""
mutable struct BoundedLRU{K, V, F} <: AbstractDict{K, V}
    dict::Dict{K, LRUNode{K, V}}
    # The sentinel of a circular list: `head.next` is the most recent entry, `head.prev` the least.
    # A sentinel rather than `Nullable` ends keeps every link one concrete type.
    head::LRUNode{K, V}
    total::Int
    const maxsize::Int
    const by::F
    # Bumped by every change to the list or the map; what the iterator checks.
    stamp::Int

    function BoundedLRU{K, V}(maxsize::Int, by::F) where {K, V, F}
        maxsize >= 0 || throw(ArgumentError("BoundedLRU: maxsize must be >= 0, got $maxsize"))
        return new{K, V, F}(Dict{K, LRUNode{K, V}}(), LRUNode{K, V}(), 0, maxsize, by, 0)
    end
end

"""
The count bound's `by`: every entry weighs 1. A named function rather than `_ -> 1`, so the
`MemoryStore` field can name its type.
"""
_count_one(_) = 1

BoundedLRU{K, V}(maxsize::Int) where {K, V} = BoundedLRU{K, V}(maxsize, _count_one)

function Base.show(io::IO, lru::BoundedLRU{K, V}) where {K, V}
    print(io, "BoundedLRU{", K, ", ", V, "}(length = ", length(lru), ", maxsize = ", lru.maxsize, ")")
    return nothing
end
Base.show(io::IO, ::MIME"text/plain", lru::BoundedLRU) = show(io, lru)

Base.length(lru::BoundedLRU) = length(lru.dict)
Base.isempty(lru::BoundedLRU) = isempty(lru.dict)
Base.haskey(lru::BoundedLRU, key) = haskey(lru.dict, key)

# ── The list ─────────────────────────────────────────────────────────────────

function _unlink!(n::LRUNode)
    n.prev.next = n.next
    n.next.prev = n.prev
    return n
end

function _push_front!(lru::BoundedLRU{K, V}, n::LRUNode{K, V}) where {K, V}
    h = lru.head
    n.prev = h
    n.next = h.next
    h.next.prev = n
    h.next = n
    return n
end

function _touch!(lru::BoundedLRU{K, V}, n::LRUNode{K, V}) where {K, V}
    lru.stamp += 1
    lru.head.next === n && return n
    _unlink!(n)
    return _push_front!(lru, n)
end

function _evict!(lru::BoundedLRU)
    while lru.total > lru.maxsize
        tail = lru.head.prev
        _unlink!(tail)
        delete!(lru.dict, tail.key)
        lru.total -= tail.size
    end
    return nothing
end

# The insert both `setindex!` and `get!` use, with `key` known to be absent.
function _insert!(lru::BoundedLRU{K, V}, key::K, value::V, size::Int) where {K, V}
    size > lru.maxsize && return nothing          # oversized: not stored, nothing evicted
    lru.stamp += 1
    n = LRUNode{K, V}(key, value, size)
    lru.dict[key] = n
    _push_front!(lru, n)
    lru.total += size
    _evict!(lru)
    return nothing
end

_measure(lru::BoundedLRU{K, V}, value::V) where {K, V} = lru.by(value)::Int

# ── Reads ────────────────────────────────────────────────────────────────────

function Base.get(lru::BoundedLRU{K, V}, key, default) where {K, V}
    n = get(lru.dict, key, nothing)
    n === nothing && return default
    _touch!(lru, n)
    return n.value
end

function Base.getindex(lru::BoundedLRU{K, V}, key) where {K, V}
    n = get(lru.dict, key, nothing)
    n === nothing && throw(KeyError(key))
    _touch!(lru, n)
    return n.value
end

# ── Writes ───────────────────────────────────────────────────────────────────

function Base.setindex!(lru::BoundedLRU{K, V}, value, key) where {K, V}
    k = convert(K, key)::K
    v = convert(V, value)::V
    s = _measure(lru, v)
    n = get(lru.dict, k, nothing)
    if n === nothing
        _insert!(lru, k, v, s)
    elseif s > lru.maxsize
        # An oversized value over a present key: the old value goes, the new one is not stored.
        lru.stamp += 1
        _unlink!(n)
        delete!(lru.dict, k)
        lru.total -= n.size
    else
        n.value = v
        lru.total += s - n.size
        n.size = s
        _touch!(lru, n)
        _evict!(lru)
    end
    return lru
end

function Base.get!(f::Base.Callable, lru::BoundedLRU{K, V}, key) where {K, V}
    n = get(lru.dict, key, nothing)
    if n !== nothing
        _touch!(lru, n)
        return n.value
    end
    k = convert(K, key)::K
    v = convert(V, f())::V
    s = _measure(lru, v)
    # `f` may have stored `key` itself; `_insert!` assumes it absent, so look again (as `Dict` does).
    n = get(lru.dict, k, nothing)
    if n !== nothing
        _touch!(lru, n)
        return n.value
    end
    _insert!(lru, k, v, s)
    return v
end

Base.get!(lru::BoundedLRU, key, default) = get!(() -> default, lru, key)

function Base.delete!(lru::BoundedLRU, key)
    n = get(lru.dict, key, nothing)
    n === nothing && return lru
    lru.stamp += 1
    _unlink!(n)
    delete!(lru.dict, key)
    lru.total -= n.size
    return lru
end

function Base.empty!(lru::BoundedLRU)
    lru.stamp += 1
    empty!(lru.dict)
    h = lru.head
    h.prev = h
    h.next = h
    lru.total = 0
    return lru
end

# ── Iteration ────────────────────────────────────────────────────────────────

function Base.iterate(lru::BoundedLRU{K, V}, state::Tuple{LRUNode{K, V}, Int} = (lru.head.next, lru.stamp)) where {K, V}
    n, stamp = state
    stamp == lru.stamp ||
        throw(ConcurrencyViolationError("BoundedLRU modified during iteration; collect the keys first"))
    n === lru.head && return nothing
    return (n.key => n.value), (n.next, stamp)
end

# ── The read-through protocol for a shared cache ─────────────────────────────

"""
    get_locked!(f, lru::BoundedLRU, key, lk::Base.AbstractLock)

`get!(f, lru, key)` for an `lru` shared between tasks and guarded by `lk`, with `f` run **outside**
the lock: a probe under `lk`, then `f()` unlocked, then under `lk` again either the value another
task inserted meanwhile (refreshed and returned) or this one inserted. So the **first insert
wins**, and every caller returns the cached value. A cold-key stampede runs `f` once per task
that missed before the first insert -- a file read twice, for the `:lazy` mount -- which is the
price of never holding the lock across I/O. An oversized value is returned and not stored.
"""
function get_locked!(f, lru::BoundedLRU{K, V}, key, lk::Base.AbstractLock) where {K, V}
    lock(lk)
    try
        n = get(lru.dict, key, nothing)
        if n !== nothing
            _touch!(lru, n)
            return n.value
        end
    finally
        unlock(lk)
    end
    k = convert(K, key)::K
    v = convert(V, f())::V
    s = _measure(lru, v)
    lock(lk)
    try
        n = get(lru.dict, k, nothing)
        if n !== nothing
            _touch!(lru, n)
            return n.value
        end
        _insert!(lru, k, v, s)
    finally
        unlock(lk)
    end
    return v
end
