# Included into `Util` before `BodyParsers`, so both `BodyParsers` and the modules above `Util`
# (`Reflection`, `Extractors`) can use one memo implementation (#498). It sat in `Reflection` at
# first, which `BodyParsers` cannot import: `Reflection` is included later and depends on it.

"""
    TypeMemo()

A per-type memo of a `Bool` answer about a type, for the binding checks that run on every request
but depend only on the type and the method table (#493). `hasmethod` with keyword names is a
method-table search, ~1 µs a call -- three times the parse of a small JSON body -- and
`struct_builder`, `multipart_struct_builder` and `json_bind` asked it per request. `json(req, T)`'s
walk for a `Symbol` anywhere in `T` (`interns_client_strings`) is memoized the same way (#498).

Read without a lock: the answers live in a `MemoSnapshot` that is never mutated once published,
and a miss publishes a copy with one more entry. Two tasks missing at once both publish and one
entry is lost, which only costs a recompute -- the answer is a pure function of the type and the
world. The snapshot is one pointer on purpose: an `@atomic` field holding the `(world, dict)` pair
inline is 16 bytes, which x86 loads with a locked `cmpxchg16b`, so every read took the cache line
exclusively and the memo slowed down with every thread reading it.

Keyed on the world counter, because the answer is a question about the method table: any method
definition (Revise adding a keyword constructor, an `@eval`) drops every entry, so a memoized
answer is never staler than an uncached `hasmethod` would be. Each memo is emptied in
`__init__`: the precompile workload fills it in another process, whose world counter means
nothing in this one.
"""
mutable struct MemoSnapshot
    const world::UInt
    const known::IdDict{Type, Bool}
end

mutable struct TypeMemo
    @atomic snapshot::MemoSnapshot
    TypeMemo() = new(MemoSnapshot(zero(UInt), IdDict{Type, Bool}()))
end

reset!(memo::TypeMemo) = (@atomic :release memo.snapshot = MemoSnapshot(zero(UInt), IdDict{Type, Bool}()))

function memoized(f::F, memo::TypeMemo, ::Type{T}) :: Bool where {F, T}
    world = Base.get_world_counter()
    snapshot = @atomic :acquire memo.snapshot
    if snapshot.world == world
        hit = get(snapshot.known, T, nothing)
        hit === nothing || return hit
    end
    answer = f(T) :: Bool
    known = snapshot.world == world ? copy(snapshot.known) : IdDict{Type, Bool}()
    known[T] = answer
    @atomic :release memo.snapshot = MemoSnapshot(world, known)
    return answer
end
