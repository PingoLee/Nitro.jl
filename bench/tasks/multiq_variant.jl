# #618: swap the order Julia's multiqueue gives out equal-priority tasks, at runtime, before any
# task is spawned. Included first by spawn_order.jl and tasks.jl; selected by VARIANT.
#
#   A   stock, nothing changed.
#   A0  stock `multiq_sift_down` re-evaluated unchanged: the same invalidation and recompilation of
#       the scheduler as B and C, with no change of order. A control for the cost cells.
#   B   RelationalAI's fairness patch: `multiq_sift_down` swaps on `<=` instead of `<` (upstream had
#       it as c23554a and reverted it in bf53304, #35589, for its cost with equal priorities).
#   C   FIFO among equal priorities: each heap orders its slots by (priority, insertion sequence),
#       with the build's ordinary sifts. `taskheap` cannot gain a field at runtime, so C brings its
#       own heaps (`seqheap`, a per-slot sequence and a per-heap counter written under the heap's
#       lock) and redefines the three entry points the scheduler calls: `multiq_insert`,
#       `multiq_deletemin`, `multiq_check_empty` (`Base.checktaskempty` is the same function).
#       Everything else is the build's own code, line for line; the per-build differences of
#       `multiq_size` and `multiq_deletemin` are kept.
#
# A0 and B are taken from the build's own `base/partr.jl` as parsed at load time, so they cannot
# drift from it. C is a hand copy, so it refuses to load on a build whose `partr.jl` it was not
# copied from (`PARTR_CRC`).
#
# World age: the C runtime calls `trypoptask` and `checktaskempty` in the world of the task that
# is waiting. An idle thread waits in a task made before the redefinition, so in the old world: its
# startup root task on 1.12, its long-lived scheduler task (`Base.get_sched_task`) from 1.13. Left
# alone it keeps popping with the old code; under C it watches the old, empty heaps and never runs
# anything (seen: the first `:default` spawn hangs). So after the redefinition every thread of every
# pool runs one task pinned to it, which on 1.13+ also replaces that thread's scheduler task
# (`_refresh_scheduler_world`). Neither old task is resumed once the thread switches away.
#
# VALIDATE=1 compiles a per-thread call counter into the new code, and under C an assert, under the
# heap's lock, that every pop takes the (priority, sequence) minimum of its heap. Both are spliced
# in only then: the timed code is the build's plus the variant's change and nothing else.

const MULTIQ_VARIANT = get(ENV, "VARIANT", "A")
MULTIQ_VARIANT in ("A", "A0", "B", "C") || error("VARIANT must be A, A0, B or C, not $(MULTIQ_VARIANT)")
const MULTIQ_VALIDATE = get(ENV, "VALIDATE", "0") == "1"

# `Base._crc32c` of the `base/partr.jl` C was copied from.
const PARTR_CRC = Dict(v"1.12.7" => 0xe7c9e7fd, v"1.13.2" => 0xa74d567b, v"1.14.0-DEV.3725" => 0xae19d8ec)
const PARTR_FILE = joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia", "base", "partr.jl")

# One counter per thread, 64 Ints apart. Validation only.
@eval Base.Partr const variant_calls = zeros(Int, 64 * Threads.maxthreadid())
const _COUNT = MULTIQ_VALIDATE ? :(variant_calls[64 * (Threads.threadid() - 1) + 1] += 1) : nothing

# The build's own definition of `name`, parsed from its `partr.jl`.
function _partr_function(name::Symbol)
    src = Meta.parseall(read(PARTR_FILE, String); filename = PARTR_FILE)
    body = src.args[findfirst(x -> x isa Expr && x.head === :module, src.args)].args[end]   # 1.14 adds a version arg
    for (i, ex) in enumerate(body.args)
        ex isa Expr && ex.head === :function || continue
        sig = ex.args[1]
        while sig isa Expr && sig.head in (:where, :(::))
            sig = sig.args[1]
        end
        if sig isa Expr && sig.head === :call && sig.args[1] === name
            # keep the LineNumberNode before it, so stack traces still point into partr.jl
            return Expr(:block, body.args[i-1], ex)
        end
    end
    error("no function $name in $PARTR_FILE")
end

# Replace every `a < b` in `ex` with `a <= b`; return how many were replaced.
function _lt_to_le!(ex::Expr)
    n = 0
    for (i, a) in enumerate(ex.args)
        if a === :< && ex.head === :call && i == 1
            ex.args[1] = :<=
            n += 1
        elseif a isa Expr
            n += _lt_to_le!(a)
        end
    end
    return n
end

# Put `_COUNT` first in the function body of a `_partr_function` block.
function _count_calls!(block::Expr)
    _COUNT === nothing || pushfirst!(block.args[2].args[2].args, _COUNT)
    return block
end

if MULTIQ_VARIANT == "A0"
    Core.eval(Base.Partr, _count_calls!(_partr_function(:multiq_sift_down)))
elseif MULTIQ_VARIANT == "B"
    let f = _partr_function(:multiq_sift_down)
        n = _lt_to_le!(f)
        n == 1 || error("expected one `<` in multiq_sift_down, found $n")
        Core.eval(Base.Partr, _count_calls!(f))
    end
elseif MULTIQ_VARIANT == "C"
    get(PARTR_CRC, VERSION, nothing) == Base._crc32c(read(PARTR_FILE)) ||
        error("VARIANT=C was copied from the partr.jl of $(join(keys(PARTR_CRC), ", ")); ",
              "this build's ($VERSION) differs")
    # Where the builds differ: 1.13 added the `nt == 0` guard to `multiq_size` and the wake-up of a
    # sticky task's owner to `multiq_deletemin`; the nightly also restructured the retry loop.
    const _NT_GUARD = VERSION >= v"1.13-" ? :(if nt == 0; nt = UInt32(1); end) : nothing
    const _CHECK_MIN = MULTIQ_VALIDATE ? quote
        for k in Int32(2):ntasks
            seq_less(heap, Int(k), 1) && error("C popped seq $(heap.seqs[1]) before slot $k's seq $(heap.seqs[k])")
        end
    end : nothing
    @eval Base.Partr begin
        mutable struct seqheap
            const lock::SpinLock
            const tasks::Vector{Task}
            const seqs::Vector{UInt64}   # C: each slot's insertion sequence
            @atomic ntasks::Int32
            @atomic priority::UInt16
            next::UInt64                 # C: the next sequence, written only under `lock`
            seqheap() = new(SpinLock(), Vector{Task}(undef, 256), Vector{UInt64}(undef, 256),
                            zero(Int32), typemax(UInt16), zero(UInt64))
        end

        const seq_heaps = [Vector{seqheap}(undef, 0), Vector{seqheap}(undef, 0)]
        const seq_heaps_lock = [SpinLock(), SpinLock()]

        # C: (priority, sequence) instead of priority alone.
        @inline function seq_less(heap::seqheap, i::Int, j::Int)
            pi, pj = heap.tasks[i].priority, heap.tasks[j].priority
            return pi < pj || (pi == pj && heap.seqs[i] < heap.seqs[j])
        end

        @inline function seq_swap!(heap::seqheap, i::Int, j::Int)
            t = heap.tasks[i]
            heap.tasks[i] = heap.tasks[j]
            heap.tasks[j] = t
            s = heap.seqs[i]
            heap.seqs[i] = heap.seqs[j]
            heap.seqs[j] = s
            return nothing
        end

        function multiq_sift_up(heap::seqheap, idx::Int32)
            while idx > Int32(1)
                parent = (idx - Int32(2)) ÷ heap_d + Int32(1)
                if seq_less(heap, Int(idx), Int(parent))
                    seq_swap!(heap, Int(parent), Int(idx))
                    idx = parent
                else
                    break
                end
            end
        end

        # C: an ordinary d-ary sift-down, one swap per level with the least child. The build's
        # loop swaps with every child less than the parent, in turn, and recurses into each: cheap
        # while equal priorities make it swap nothing, but under a strict order it walks much of the
        # heap, the cost that got `<=` reverted (single heap, no scheduler, 1.12.7: 64 µs a pop at
        # 50,000 tasks against 10 ns stock).
        function multiq_sift_down(heap::seqheap, idx::Int32)
            i = Int(idx)
            n = Int(heap.ntasks)
            while true
                first = Int(heap_d) * (i - 1) + 2
                least = i
                for child = first:min(first + Int(heap_d) - 1, n)
                    if seq_less(heap, child, least)
                        least = child
                    end
                end
                least == i && return
                seq_swap!(heap, i, least)
                i = least
            end
        end

        function seq_multiq_size(tpid::Int8)
            nt = UInt32(Threads._nthreads_in_pool(tpid))
            $_NT_GUARD
            tp = tpid + 1
            tpheaps = seq_heaps[tp]
            heap_c = UInt32(2)
            heap_p = UInt32(length(tpheaps))

            if heap_c * nt <= heap_p
                return heap_p
            end

            @lock seq_heaps_lock[tp] begin
                tpheaps = seq_heaps[tp]
                heap_p = UInt32(length(tpheaps))
                nt = UInt32(Threads._nthreads_in_pool(tpid))
                $_NT_GUARD
                if heap_c * nt <= heap_p
                    return heap_p
                end

                heap_p += heap_c * nt
                newheaps = Vector{seqheap}(undef, heap_p)
                copyto!(newheaps, tpheaps)
                for i = (1 + length(tpheaps)):heap_p
                    newheaps[i] = seqheap()
                end
                seq_heaps[tp] = newheaps
            end

            return heap_p
        end

        function multiq_insert(task::Task, priority::UInt16)
            tpid = ccall(:jl_get_task_threadpoolid, Int8, (Any,), task)
            @assert tpid > -1 "invalid tpid"
            heap_p = seq_multiq_size(tpid)
            tp = tpid + 1

            task.priority = priority

            rn = cong(heap_p)
            tpheaps = seq_heaps[tp]
            while !trylock(tpheaps[rn].lock)
                rn = cong(heap_p)
            end

            heap = tpheaps[rn]
            if heap.ntasks >= length(heap.tasks)
                resize!(heap.tasks, length(heap.tasks) * 2)
                resize!(heap.seqs, length(heap.seqs) * 2)
            end

            ntasks = heap.ntasks + Int32(1)
            @atomic :monotonic heap.ntasks = ntasks
            heap.tasks[ntasks] = task
            heap.seqs[ntasks] = heap.next
            heap.next += UInt64(1)
            multiq_sift_up(heap, ntasks)
            priority = heap.priority
            if task.priority < priority
                @atomic :monotonic heap.priority = task.priority
            end
            unlock(heap.lock)

            return true
        end

        function multiq_check_empty()
            tid = Threads.threadid()
            tp = ccall(:jl_threadpoolid, Int8, (Int16,), tid-1) + 1
            if tp == 0 # Foreign thread
                return true
            end
            for i = UInt32(1):length(seq_heaps[tp])
                if seq_heaps[tp][i].ntasks != 0
                    return false
                end
            end
            return true
        end
    end

    # `multiq_deletemin`, per build. The part after a heap is chosen is shared.
    const _POP = quote
        ntasks = heap.ntasks
        $_CHECK_MIN
        @atomic :monotonic heap.ntasks = ntasks - Int32(1)
        heap.tasks[1] = heap.tasks[ntasks]
        heap.seqs[1] = heap.seqs[ntasks]
        $(VERSION >= v"1.14-" ? :(Base.unsetindex!(heap.tasks, Int(ntasks))) :
                                :(Base._unsetindex!(heap.tasks, Int(ntasks))))
        prio1 = typemax(UInt16)
        if ntasks > 1
            multiq_sift_down(heap, Int32(1))
            prio1 = heap.tasks[1].priority
        end
        @atomic :monotonic heap.priority = prio1
        $_COUNT
        unlock(heap.lock)

        return task
    end
    const _CHOOSE = quote
        heap_p = UInt32(length(tpheaps))
        for i = UInt32(0):heap_p
            if i == heap_p
                return nothing
            end
            rn1 = cong(heap_p)
            rn2 = cong(heap_p)
            prio1 = tpheaps[rn1].priority
            prio2 = tpheaps[rn2].priority
            if prio1 > prio2
                prio1 = prio2
                rn1 = rn2
            elseif prio1 == prio2 && prio1 == typemax(UInt16)
                continue
            end
            if trylock(tpheaps[rn1].lock)
                if prio1 == tpheaps[rn1].priority
                    break
                end
                unlock(tpheaps[rn1].lock)
            end
        end

        @assert @isdefined(rn1) "Assertion to tell the compiler about the definedness of this variable"
    end
    const _WAKE_OWNER = quote
        # This task is sticky to a different thread, so we can't run it.
        # Wake that thread so it can come pick up its own work, then keep
        # looking for something we are allowed to run.
        task_tid = ccall(:jl_get_task_tid, Int16, (Any,), task)
        unlock(heap.lock)
        if task_tid != Int16(-1)
            ccall(:jl_wakeup_thread, Cint, (Int16,), task_tid)
        end
    end
    if VERSION >= v"1.14-"
        @eval Base.Partr function multiq_deletemin()
            local rn1::UInt32
            local heap, task

            tid = Threads.threadid()
            tp = ccall(:jl_threadpoolid, Int8, (Int16,), tid-1) + 1
            if tp == 0 # Foreign thread
                return nothing
            end
            tpheaps = seq_heaps[tp]

            while true
                GC.safepoint()
                $_CHOOSE

                heap = tpheaps[rn1]
                task = heap.tasks[1]
                if ccall(:jl_set_task_tid, Cint, (Any, Cint), task, tid-1) == 0
                    $_WAKE_OWNER
                    continue
                end
                break
            end
            $_POP
        end
    else
        @eval Base.Partr function multiq_deletemin()
            local rn1::UInt32

            tid = Threads.threadid()
            tp = ccall(:jl_threadpoolid, Int8, (Int16,), tid-1) + 1
            if tp == 0 # Foreign thread
                return nothing
            end
            tpheaps = seq_heaps[tp]

            @label retry
            GC.safepoint()
            $_CHOOSE

            heap = tpheaps[rn1]
            task = heap.tasks[1]
            if ccall(:jl_set_task_tid, Cint, (Any, Cint), task, tid-1) == 0
                $(VERSION >= v"1.13-" ? _WAKE_OWNER : :(unlock(heap.lock)))
                @goto retry
            end
            $_POP
        end
    end
end

# Runs pinned to one thread, in the current world. From 1.13 a thread idles in a long-lived
# scheduler task of its own (`Base.get_sched_task`, a `OncePerThread` running `wait_forever`), which
# a finished task yields to when there is nothing else to run. One made before the redefinition
# stays in the old world for good, so replace it with one made here: the old one is suspended while
# this task runs and is never resumed. This task then finishes and yields to the new one.
function _refresh_this_thread()
    tid = Threads.threadid()
    if isdefined(Base, :get_sched_task)
        once = Base.get_sched_task
        ss = @atomic :acquire once.ss
        if tid <= length(ss) && (@atomic :acquire ss[tid]) == Base.PerStateHasrun
            xs = @atomic :monotonic once.xs
            @atomic :release xs[tid] = Task(Base.wait_forever)
        end
    end
    return tid
end

# Run one task pinned to every thread of every pool, so that each thread's idle loop moves into the
# current world: out of its startup root task (1.12) or its scheduler task (1.13+, above). Returns
# the tids that ran one.
function _refresh_scheduler_world()
    tasks, want = Task[], Int[]
    for pool in (:interactive, :default), tid in Threads.threadpooltids(pool)
        t = Task(_refresh_this_thread)
        t.sticky = true
        Threads._spawn_set_thrpool(t, pool)
        ccall(:jl_set_task_tid, Cint, (Any, Cint), t, tid - 1)
        schedule(t)
        push!(tasks, t)
        push!(want, tid)
    end
    got = fetch.(tasks)
    got == want || error("world refresh: tasks pinned to $want ran on $got")
    return got
end

# REFRESH=0 skips it, only to show what goes wrong without it.
if MULTIQ_VARIANT != "A" && get(ENV, "REFRESH", "1") == "1"
    _refresh_scheduler_world()
end
# Compile the (re)defined scheduler before anything is measured.
_burst() = foreach(wait, [Threads.@spawn sum(1:100) for _ in 1:200])
foreach(wait, [Threads.@spawn :interactive _burst() for _ in 1:8])
foreach(wait, [Threads.@spawn :default _burst() for _ in 1:8])

println(stderr, "multiq_variant: VARIANT=", MULTIQ_VARIANT, MULTIQ_VALIDATE ? " (VALIDATE)" : "",
        MULTIQ_VARIANT == "C" ? ", partr.jl crc matches $(VERSION)" : "")

# Calls into the new code, per thread (validation only).
multiq_variant_calls() = [Base.Partr.variant_calls[64 * (tid - 1) + 1] for tid in 1:Threads.maxthreadid()]

# End of a process: under C, nothing ever went into the build's own heaps, and C's are empty.
function multiq_variant_check()
    MULTIQ_VARIANT == "C" || return nothing
    for tp in 1:2
        n_old = sum((h.ntasks for h in Base.Partr.heaps[tp]); init = 0)
        n_new = sum((h.ntasks for h in Base.Partr.seq_heaps[tp]); init = 0)
        n_old == 0 || error("C: $n_old tasks in the build's own heaps of pool $tp")
        n_new == 0 || error("C: $n_new tasks left in seq_heaps of pool $tp")
    end
    return nothing
end

# ── single-heap order asserts (VALIDATE=1) ──────────────────────────────────────────────────
# One heap, driven by the variant's own sift functions and the per-heap steps of the variant's
# `multiq_insert` / `multiq_deletemin`, with dummy tasks that never run.

_newheap() = MULTIQ_VARIANT == "C" ? Base.Partr.seqheap() : Base.Partr.taskheap()

function _push!(h, t::Task)
    if h.ntasks >= length(h.tasks)
        resize!(h.tasks, 2 * length(h.tasks))
        h isa Base.Partr.taskheap || resize!(h.seqs, 2 * length(h.seqs))
    end
    n = h.ntasks + Int32(1)
    @atomic h.ntasks = n
    h.tasks[n] = t
    if !(h isa Base.Partr.taskheap)
        h.seqs[n] = h.next
        h.next += UInt64(1)
    end
    Base.Partr.multiq_sift_up(h, n)
end

function _pop!(h)
    t = h.tasks[1]
    n = h.ntasks
    @atomic h.ntasks = n - Int32(1)
    h.tasks[1] = h.tasks[n]
    h isa Base.Partr.taskheap || (h.seqs[1] = h.seqs[n])
    VERSION >= v"1.14-" ? Base.unsetindex!(h.tasks, Int(n)) : Base._unsetindex!(h.tasks, Int(n))
    n > 1 && Base.Partr.multiq_sift_down(h, Int32(1))
    return t
end

function _dummy(ids::IdDict{Task,Int}, i::Int)
    t = Task(() -> nothing)
    t.priority = 0
    ids[t] = i
    return t
end

# Fill N, then drain: the pop order, as insertion indices.
function _fill_drain(n::Int)
    h, ids = _newheap(), IdDict{Task,Int}()
    foreach(i -> _push!(h, _dummy(ids, i)), 1:n)
    return [ids[_pop!(h)] for _ in 1:n]
end

# Keep N in the heap, pop one and push one M times: the most pops any served task waited, and the
# most any task still in the heap has waited.
function _steady(n::Int, m::Int)
    h, born = _newheap(), IdDict{Task,Int}()
    foreach(i -> _push!(h, _dummy(born, 0)), 1:n)
    worst = 0
    for step in 1:m
        t = _pop!(h)
        worst = max(worst, step - born[t])
        delete!(born, t)
        _push!(h, _dummy(born, step))
    end
    return worst, maximum(m .- values(born))
end

# Random interleaved pushes and pops: the pop order, as insertion indices.
function _interleaved(n::Int)
    h, ids = _newheap(), IdDict{Task,Int}()
    pushed, popped = 0, Int[]
    state = UInt64(0x9e3779b97f4a7c15)
    while length(popped) < n
        state = state * 0x5851f42d4c957f2d + 1
        if pushed < n && (h.ntasks == 0 || (state >> 33) % 3 != 0)
            pushed += 1
            _push!(h, _dummy(ids, pushed))
        else
            push!(popped, ids[_pop!(h)])
        end
    end
    return popped
end

# Fill N, then time the drain: ns per pop, on one heap with no scheduler and no contention.
function _drain_ns(n::Int)
    h, ids = _newheap(), IdDict{Task,Int}()
    foreach(i -> _push!(h, _dummy(ids, i)), 1:n)
    t0 = time_ns()
    for _ in 1:n
        _pop!(h)
    end
    return (time_ns() - t0) / n
end

function multiq_unit_asserts()
    n, m = 30, 3000
    fd, (worst, waiting), il = _fill_drain(20), _steady(n, m), _interleaved(2000)
    if MULTIQ_VARIANT in ("A", "A0")
        # LIFO below the root: the root, then newest first; the oldest never comes out in steady state.
        @assert fd == [1; 20:-1:2] "A: fill/drain popped $fd"
        @assert waiting == m "A: in steady state the oldest has waited $waiting of $m pops"
    elseif MULTIQ_VARIANT == "B"
        # Not FIFO, but in steady state every task comes out within N pops.
        @assert fd != [1; 20:-1:2] && fd != collect(1:20) "B: fill/drain popped $fd"
        @assert worst <= n && waiting < n "B: steady state worst $worst, oldest waiting $waiting, N = $n"
    else
        # FIFO: insertion order exactly, whatever the interleaving.
        @assert fd == collect(1:20) "C: fill/drain popped $fd"
        @assert il == collect(1:2000) "C: interleaved pops out of order"
        @assert worst == n && waiting < n "C: steady state worst $worst, oldest waiting $waiting, N = $n"
    end
    println(stderr, "multiq_variant: single-heap asserts passed for ", MULTIQ_VARIANT,
            ": fill/drain of 20 pops ", fd, "; steady state N = ", n, ": worst served after ", worst,
            " pops, oldest waiting ", waiting, " of ", m)
    _drain_ns(1000)
    println(stderr, "multiq_variant: single-heap drain, ns per pop (best of 3): ",
            join(("n = $n: $(round(minimum(_drain_ns(n) for _ in 1:3); digits = 1))" for n in (1000, 10_000)), ", "))
    return nothing
end
