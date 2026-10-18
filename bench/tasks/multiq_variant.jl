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
#   D<K>  C's heaps behind one LIFO slot per `:default` thread, as Go's `runnext` and tokio's LIFO
#       slot (D3: K = 3, tokio's value; D-inf: no budget, an ablation). A task made runnable by a
#       `:default` thread (spawned or woken, not the current task re-queueing itself in `yield`)
#       goes into that thread's slot, and the task it displaces goes into C's heaps; a task made
#       runnable from another pool, or pinned to another thread, goes straight into the heaps. A
#       thread pops its own slot first, at most K times in a row (the budget stands in for Go's
#       inherited time slice, which Julia does not have); when the budget is spent, the slot's task
#       goes to the back of the heaps and the thread pops the heaps. A thread that finds the heaps
#       empty steals another thread's slot. `multiq_check_empty` sees the slots, so a thread never
#       decides to sleep while a slot is full: the C runtime re-checks it after publishing
#       `sleeping` (scheduler.c's `jl_task_get_next`), and `enq_work` wakes a thread after every
#       insert. A slot is a 128-byte struct whose task field is only ever swapped atomically.
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
# VALIDATE=1 compiles a per-thread call counter into the new code, and under C and D an assert,
# under the heap's lock, that every pop takes the (priority, sequence) minimum of its heap; under D
# also per-thread counts of slot pops, steals, budget flushes, displaced and bounced tasks. All are
# spliced in only then: the timed code is the build's plus the variant's change and nothing else.
# `multiq_watchdog` arms an `alarm()` for a validated run: a lost wakeup leaves every thread
# asleep, so the process is killed (exit status 142) instead of hanging.

const MULTIQ_VARIANT = get(ENV, "VARIANT", "A")
const _D_MATCH = match(r"^D([0-9]+|-inf)$", MULTIQ_VARIANT)
MULTIQ_VARIANT in ("A", "A0", "B", "C") || _D_MATCH !== nothing ||
    error("VARIANT must be A, A0, B, C, D<K> or D-inf, not $(MULTIQ_VARIANT)")
# D's slot budget, or nothing for every other variant.
const SLOT_BUDGET = _D_MATCH === nothing ? nothing :
                    _D_MATCH[1] == "-inf" ? typemax(Int) : parse(Int, _D_MATCH[1])
# C's heaps: C, and D behind its slots.
const MULTIQ_SEQ_HEAPS = MULTIQ_VARIANT == "C" || SLOT_BUDGET !== nothing
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
elseif MULTIQ_SEQ_HEAPS
    get(PARTR_CRC, VERSION, nothing) == Base._crc32c(read(PARTR_FILE)) ||
        error("VARIANT=$(MULTIQ_VARIANT) uses C, which was copied from the partr.jl of $(join(keys(PARTR_CRC), ", ")); ",
              "this build's ($VERSION) differs")
    # Where the builds differ: 1.13 added the `nt == 0` guard to `multiq_size` and the wake-up of a
    # sticky task's owner to `multiq_deletemin`; the nightly also restructured the retry loop.
    const _NT_GUARD = VERSION >= v"1.13-" ? :(if nt == 0; nt = UInt32(1); end) : nothing
    # Under D, C's three entry points keep their code under other names, and D's wrap them.
    const _C_INSERT = SLOT_BUDGET === nothing ? :multiq_insert : :seq_multiq_insert
    const _C_DELETEMIN = SLOT_BUDGET === nothing ? :multiq_deletemin : :seq_multiq_deletemin
    const _C_CHECK_EMPTY = SLOT_BUDGET === nothing ? :multiq_check_empty : :seq_multiq_check_empty
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

        function $_C_INSERT(task::Task, priority::UInt16)
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

        function $_C_CHECK_EMPTY()
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
        @eval Base.Partr function $_C_DELETEMIN()
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
        @eval Base.Partr function $_C_DELETEMIN()
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

if SLOT_BUDGET !== nothing
    # The build's wake-up after an insert: 1.12 wakes every sleeping thread, 1.13 one of the pool's.
    const _WAKE_POOL = VERSION >= v"1.13-" ?
        :(ccall(:jl_wakeup_threadpool, Cvoid, (Int8,), slot_tpid)) :
        :(ccall(:jl_wakeup_thread, Cvoid, (Int16,), Int16(-1)))
    _vcount(field) = MULTIQ_VALIDATE ? :(s.$field += 1) : nothing
    @eval Base.Partr begin
        # One per thread, 128 bytes: the slot, then fields only its own thread writes.
        mutable struct taskslot
            @atomic task::Union{Nothing,Task}
            streak::Int        # slot pops in a row, against the budget
            pops::Int          # VALIDATE only, as are the counts below
            steals::Int        # slots this thread took from other threads
            flushes::Int       # budget spent: the slot's task sent to the heaps
            displaced::Int     # an insert pushed the slot's task to the heaps
            bounced::Int       # the slot's task was pinned to another thread: sent to the heaps
            pad::NTuple{9,Int}
            taskslot() = new(nothing, 0, 0, 0, 0, 0, 0, ntuple(_ -> 0, 9))
        end

        const slot_budget = $SLOT_BUDGET
        const slot_tpid = Int8(Threads._sym_to_tpid(:default))
        const slot_tids = collect(Threads.threadpooltids(:default))
        const slots = [taskslot() for _ in 1:Threads.maxthreadid()]

        @inline _in_slot_pool(tid::Int) = ccall(:jl_threadpoolid, Int8, (Int16,), tid - 1) == slot_tpid

        # Send a task to the heaps and wake a thread for it, as `enq_work` does after an insert.
        @noinline function slot_to_heaps(task::Task)
            seq_multiq_insert(task, task.priority)
            $_WAKE_POOL
            return nothing
        end

        function multiq_insert(task::Task, priority::UInt16)
            tid = Threads.threadid()
            if task !== current_task() && _in_slot_pool(tid) &&
                    ccall(:jl_get_task_threadpoolid, Int8, (Any,), task) == slot_tpid
                owner = ccall(:jl_get_task_tid, Int16, (Any,), task)
                if owner == -1 || owner == tid - 1
                    task.priority = priority
                    s = slots[tid]
                    old = @atomicswap s.task = task
                    old === nothing && return true
                    $(_vcount(:displaced))
                    return seq_multiq_insert(old, old.priority)
                end
            end
            return seq_multiq_insert(task, priority)
        end

        function multiq_deletemin()
            tid = Threads.threadid()
            _in_slot_pool(tid) || return seq_multiq_deletemin()
            s = slots[tid]
            if (@atomic :monotonic s.task) !== nothing
                task = @atomicswap s.task = nothing
                if task !== nothing
                    if s.streak >= slot_budget
                        $(_vcount(:flushes))
                        slot_to_heaps(task)
                    elseif ccall(:jl_set_task_tid, Cint, (Any, Cint), task, tid - 1) != 0
                        s.streak += 1
                        $(_vcount(:pops))
                        $_COUNT
                        return task
                    else
                        $(_vcount(:bounced))
                        slot_to_heaps(task)
                    end
                end
            end
            s.streak = 0
            task = seq_multiq_deletemin()
            task === nothing || return task
            # The heaps are empty: steal another thread's slot, starting after this one.
            n = length(slot_tids)
            me = something(findfirst(==(tid), slot_tids), 0)
            for k in 1:n-1
                o = slots[slot_tids[mod1(me + k, n)]]
                v = @atomic :monotonic o.task
                v === nothing && continue
                (; old, success) = @atomicreplace o.task v => nothing
                success || continue
                if ccall(:jl_set_task_tid, Cint, (Any, Cint), old, tid - 1) != 0
                    $(_vcount(:steals))
                    $_COUNT
                    return old
                end
                $(_vcount(:bounced))
                slot_to_heaps(old)
            end
            return nothing
        end

        function multiq_check_empty()
            seq_multiq_check_empty() || return false
            _in_slot_pool(Threads.threadid()) || return true
            for j in slot_tids
                (@atomic :monotonic slots[j].task) === nothing || return false
            end
            return true
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
        MULTIQ_SEQ_HEAPS ? ", partr.jl crc matches $(VERSION)" : "",
        SLOT_BUDGET === nothing ? "" : ", slot budget $(SLOT_BUDGET == typemax(Int) ? "none" : SLOT_BUDGET)")

# Calls into the new code, per thread (validation only).
multiq_variant_calls() = [Base.Partr.variant_calls[64 * (tid - 1) + 1] for tid in 1:Threads.maxthreadid()]

# End of a process: under C, nothing ever went into the build's own heaps, and C's are empty.
function multiq_variant_check()
    MULTIQ_SEQ_HEAPS || return nothing
    for tp in 1:2
        n_old = sum((h.ntasks for h in Base.Partr.heaps[tp]); init = 0)
        n_new = sum((h.ntasks for h in Base.Partr.seq_heaps[tp]); init = 0)
        n_old == 0 || error("C: $n_old tasks in the build's own heaps of pool $tp")
        n_new == 0 || error("C: $n_new tasks left in seq_heaps of pool $tp")
    end
    if SLOT_BUDGET !== nothing
        full = [tid for tid in 1:Threads.maxthreadid() if (@atomic Base.Partr.slots[tid].task) !== nothing]
        isempty(full) || error("D: tasks left in the slots of tids $full")
    end
    return nothing
end

# VALIDATE only: kill the process with SIGALRM (exit status 142) unless `multiq_watchdog(0)` comes
# within `secs` seconds. A lost wakeup leaves every thread asleep, so the watchdog needs none.
multiq_watchdog(secs::Integer) = MULTIQ_VALIDATE ? Int(ccall(:alarm, Cuint, (Cuint,), secs)) : 0

# D, VALIDATE only: per `:default` tid, the counts kept in its slot.
function multiq_slot_counts()
    SLOT_BUDGET === nothing && return nothing
    ss = Base.Partr.slots
    tids = Base.Partr.slot_tids
    return (tids = tids, pops = [ss[t].pops for t in tids], steals = [ss[t].steals for t in tids],
            flushes = [ss[t].flushes for t in tids], displaced = [ss[t].displaced for t in tids],
            bounced = [ss[t].bounced for t in tids])
end

# D, VALIDATE only: print the slot counts since `before` (a `multiq_slot_counts()`), and require
# slot pops on every `:default` thread and steals somewhere where `expect` says the workload has them.
function multiq_slot_check(label, before; pops_everywhere::Bool = false, steals::Bool = false, pops::Bool = false)
    SLOT_BUDGET === nothing && return nothing
    now = multiq_slot_counts()
    d(k) = getfield(now, k) .- getfield(before, k)
    println(stderr, "validate: D slots, ", label, ": pops ", d(:pops), ", steals ", d(:steals),
            ", flushes ", d(:flushes), ", displaced ", d(:displaced), ", bounced ", d(:bounced))
    pops_everywhere && (all(>(0), d(:pops)) || error("D: $label: no slot pops on some :default tid: ", d(:pops)))
    pops && (sum(d(:pops)) > 0 || error("D: $label: no slot pops"))
    steals && (sum(d(:steals)) > 0 || error("D: $label: no slot steals"))
    return nothing
end

# D, VALIDATE only, two probes.
# 1. `multiq_check_empty` sees a full slot. It is what a thread about to sleep re-checks after
#    publishing `sleeping` (scheduler.c, `jl_task_get_next`); were it blind to the slots, a task put
#    in a slot while every other thread is on its way to sleep would wait until its thread is free.
#    That race is too narrow to hit on purpose, so the check is direct: a never-scheduled task in
#    this thread's slot, no wake-up sent (so the sleeping threads cannot take it), and
#    `multiq_check_empty()` must say false.
# 2. A task left in the slot of a thread that then computes without yielding is stolen by a thread
#    that was asleep (the one `enq_work` wakes), well before the hold ends.
function _slot_probe(reps::Int = 20, hold_ms::Float64 = 200.0)
    checked = 0
    for _ in 1:reps
        sleep(0.05)   # every other thread goes back to sleep
        empty, held = fetch(Threads.@spawn :default begin
            # Spawning this task woke threads (every sleeping one on 1.12); hold this thread without
            # yielding until they have spun out and gone back to sleep.
            t0 = time_ns()
            while time_ns() - t0 < 5_000_000
                GC.safepoint()
            end
            s = Base.Partr.slots[Threads.threadid()]
            dummy = Task(() -> nothing)
            prev = @atomicswap s.task = dummy
            e = Base.Partr.multiq_check_empty()
            back = @atomicswap s.task = prev
            (e, back === dummy)
        end)
        held || continue   # a spinning thread took it: no verdict this time
        empty && error("D: multiq_check_empty() says empty while a slot holds a task")
        checked += 1
    end
    checked >= reps ÷ 2 || error("D: only $checked of $reps check_empty probes kept their task")
    before = multiq_slot_counts()
    worst = 0.0
    for _ in 1:reps
        sleep(0.05)   # every other thread goes back to sleep
        lat = fetch(Threads.@spawn :default begin
            started = Threads.Atomic{UInt64}(0)
            t0 = time_ns()
            child = Threads.@spawn :default (started[] = time_ns(); nothing)
            while time_ns() - t0 < hold_ms * 1e6
                GC.safepoint()
            end
            s = started[]
            wait(child)
            s == 0 ? Inf : (s - t0) / 1e6
        end)
        worst = max(worst, lat)
    end
    stolen = sum(multiq_slot_counts().steals .- before.steals)
    worst < hold_ms / 4 || error("D: a slot task waited $(round(worst; digits = 1)) ms behind a $(hold_ms) ms hold")
    stolen >= reps || error("D: $stolen of $reps probe tasks were stolen from a slot")
    println(stderr, "multiq_variant: slot probe passed for ", MULTIQ_VARIANT, ": multiq_check_empty() saw a ",
            "full slot ", checked, " of ", reps, " times (the rest were taken first); ", reps, " tasks left in a ",
            "busy thread's slot, ", stolen, " slot steals, the slowest started after ",
            round(worst; digits = 2), " ms of a ", hold_ms, " ms hold")
    return nothing
end

# ── single-heap order asserts (VALIDATE=1) ──────────────────────────────────────────────────
# One heap, driven by the variant's own sift functions and the per-heap steps of the variant's
# `multiq_insert` / `multiq_deletemin`, with dummy tasks that never run.

_newheap() = MULTIQ_SEQ_HEAPS ? Base.Partr.seqheap() : Base.Partr.taskheap()

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
    SLOT_BUDGET === nothing || (multiq_watchdog(60); _slot_probe(); multiq_watchdog(0))
    println(stderr, "multiq_variant: single-heap asserts passed for ", MULTIQ_VARIANT,
            ": fill/drain of 20 pops ", fd, "; steady state N = ", n, ": worst served after ", worst,
            " pops, oldest waiting ", waiting, " of ", m)
    _drain_ns(1000)
    println(stderr, "multiq_variant: single-heap drain, ns per pop (best of 3): ",
            join(("n = $n: $(round(minimum(_drain_ns(n) for _ in 1:3); digits = 1))" for n in (1000, 10_000)), ", "))
    return nothing
end
