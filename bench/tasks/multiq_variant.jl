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
#   E<K>  stock's order with a bounded wait: 16 heaps, random insert and the two-choice pop exactly
#       as stock, but every K-th successful pop a thread makes is a *periodic* pop that takes the
#       OLDEST queued task of the two heaps it sampled (the one whose oldest entry is older), where
#       a normal pop takes the newest. Go's `findRunnable` takes from the global run queue every 61
#       ticks "to ensure fairness" (runtime/proc.go), tokio's `global_queue_interval` is the same
#       budget; E61 is K = 61, E-inf has no periodic pop and is the structure-cost control.
#       Each heap keeps both orders over the same entries without a heap at all: one ring deque per
#       priority, in a bucket vector sorted by priority (one bucket in practice; nothing in Base
#       sets a task priority). A normal pop is the min-priority bucket's back, a periodic pop its
#       front, an insert a push at the back with an rdtsc stamp: all O(1), no stale entries, no
#       `taken` flags, no compaction. (A newest-first heap and an oldest-first heap over shared
#       entries with lazy deletion was the first design; under a LIFO steady state every normally
#       popped task stays in the oldest-first heap as a stale entry younger than the live old ones,
#       so that heap grows without bound and retains garbage until a compaction pass. The deque
#       has no such cost, which is what the E-inf control is there to show.) Stock's order among
#       equal priorities is "the root, then newest first"; E's normal pop is newest first exactly.
#       The stamp orders the oldest entries of two heaps against each other; it is the TSC, which
#       Linux chose as the clocksource on this box (constant, nonstop), so it is comparable across
#       cores. `multiq_check_empty` reads each heap's live count. `yield()`, pinned tasks and
#       `:interactive` inserts go the stock way. The per-thread pop counter lives in a padded
#       128-byte struct; the K-th successful pop resets it.
#
# A0 and B are taken from the build's own `base/partr.jl` as parsed at load time, so they cannot
# drift from it. C and E are hand copies, so they refuse to load on a build whose `partr.jl` they
# were not copied from (`PARTR_CRC`).
#
# Builds with a selectable scheduler (JuliaLang/julia#62285 moves `Base.Partr` to
# `Base.Scheduler.Partr` beside a work-stealing backend, chosen at build time by `JULIA_SCHEDULER` and
# read back as `Base.JULIA_SCHEDULER`): every reference to the partr module goes through `PARTR`, so
# A loads on either backend and `MULTIQ_BACKEND` names the one the build runs; the variants that
# patch partr refuse a build whose backend is not partr, since there they would patch dead code. The
# TSV label of such a build is `<commit>/<backend>`, and `multiq_backend_check` confirms the backend
# from what the warm-up burst touched (rings grown, or partr heaps grown), not from the build flag.
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
# also per-thread counts of slot pops, steals, budget flushes, displaced and bounced tasks; under E
# a shadow vector per bucket that every pop is checked against (the back is the newest entry, the
# front the oldest), per-thread counts of pops and periodic pops (periodic == pops ÷ K exactly, by
# construction), and two probes of `multiq_check_empty`. All are spliced in only then: the timed
# code is the build's plus the variant's change and nothing else. `multiq_watchdog` arms an
# `alarm()` for a validated run: a lost wakeup leaves every thread asleep, so the process is killed
# (exit status 142) instead of hanging.

const MULTIQ_VARIANT = get(ENV, "VARIANT", "A")
const _D_MATCH = match(r"^D([0-9]+|-inf)$", MULTIQ_VARIANT)
const _E_MATCH = match(r"^E([0-9]+|-inf)$", MULTIQ_VARIANT)
MULTIQ_VARIANT in ("A", "A0", "B", "C") || _D_MATCH !== nothing || _E_MATCH !== nothing ||
    error("VARIANT must be A, A0, B, C, D<K>, D-inf, E<K> or E-inf, not $(MULTIQ_VARIANT)")
# D's slot budget, or nothing for every other variant.
const SLOT_BUDGET = _D_MATCH === nothing ? nothing :
                    _D_MATCH[1] == "-inf" ? typemax(Int) : parse(Int, _D_MATCH[1])
# E's pop budget (every K-th successful pop is periodic), or nothing for every other variant.
const PERIODIC_K = _E_MATCH === nothing ? nothing :
                   _E_MATCH[1] == "-inf" ? typemax(Int) : parse(Int, _E_MATCH[1])
PERIODIC_K === nothing || PERIODIC_K >= 2 || error("E's K must be at least 2")
# C's heaps: C, and D behind its slots.
const MULTIQ_SEQ_HEAPS = MULTIQ_VARIANT == "C" || SLOT_BUDGET !== nothing
const MULTIQ_VALIDATE = get(ENV, "VALIDATE", "0") == "1"

# `Base._crc32c` of the `base/partr.jl` C was copied from.
const PARTR_CRC = Dict(v"1.12.7" => 0xe7c9e7fd, v"1.13.2" => 0xa74d567b, v"1.14.0-DEV.3725" => 0xae19d8ec)
const PARTR_FILE = let base = joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia", "base")
    isfile(joinpath(base, "partr.jl")) ? joinpath(base, "partr.jl") : joinpath(base, "scheduler", "partr.jl")
end

# The build's partr module, the scheduler backend it runs and the label its TSV rows carry.
const PARTR = isdefined(Base, :Partr) ? Base.Partr : Base.Scheduler.Partr
const MULTIQ_BACKEND = !isdefined(Base, :Scheduler) ? :partr :
    Base.Scheduler.ChosenScheduler === PARTR ? :partr :
    Symbol(lowercase(String(nameof(Base.Scheduler.ChosenScheduler))))
const MULTIQ_BUILD = Base.GIT_VERSION_INFO.commit_short *
    (isdefined(Base, :Scheduler) ? "/" * String(MULTIQ_BACKEND) : "")
MULTIQ_VARIANT == "A" || MULTIQ_BACKEND === :partr ||
    error("VARIANT=$(MULTIQ_VARIANT) patches partr, and this build's scheduler is $(MULTIQ_BACKEND)")

# One counter per thread, 64 Ints apart. Validation only.
@eval PARTR const variant_calls = zeros(Int, 64 * Threads.maxthreadid())
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

# Where the builds differ: 1.13 added the `nt == 0` guard to `multiq_size` and the wake-up of a
# sticky task's owner to `multiq_deletemin`; the nightly also restructured the retry loop and
# renamed `_unsetindex!`. Shared by C (and D over it) and E.
const _NT_GUARD = VERSION >= v"1.13-" ? :(if nt == 0; nt = UInt32(1); end) : nothing
# `_unsetindex!` became `unsetindex!` during 1.14-DEV, so this goes by the name, not the version.
const _UNSET = isdefined(Base, :unsetindex!) ? :(Base.unsetindex!) : :(Base._unsetindex!)
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
_check_partr_crc() = get(PARTR_CRC, VERSION, nothing) == Base._crc32c(read(PARTR_FILE)) ||
    error("VARIANT=$(MULTIQ_VARIANT) was copied from the partr.jl of $(join(keys(PARTR_CRC), ", ")); ",
          "this build's ($VERSION) differs")

if MULTIQ_VARIANT == "A0"
    Core.eval(PARTR, _count_calls!(_partr_function(:multiq_sift_down)))
elseif MULTIQ_VARIANT == "B"
    let f = _partr_function(:multiq_sift_down)
        n = _lt_to_le!(f)
        n == 1 || error("expected one `<` in multiq_sift_down, found $n")
        Core.eval(PARTR, _count_calls!(f))
    end
elseif MULTIQ_SEQ_HEAPS
    _check_partr_crc()
    # Under D, C's three entry points keep their code under other names, and D's wrap them.
    const _C_INSERT = SLOT_BUDGET === nothing ? :multiq_insert : :seq_multiq_insert
    const _C_DELETEMIN = SLOT_BUDGET === nothing ? :multiq_deletemin : :seq_multiq_deletemin
    const _C_CHECK_EMPTY = SLOT_BUDGET === nothing ? :multiq_check_empty : :seq_multiq_check_empty
    const _CHECK_MIN = MULTIQ_VALIDATE ? quote
        for k in Int32(2):ntasks
            seq_less(heap, Int(k), 1) && error("C popped seq $(heap.seqs[1]) before slot $k's seq $(heap.seqs[k])")
        end
    end : nothing
    @eval PARTR begin
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
    if VERSION >= v"1.14-"
        @eval PARTR function $_C_DELETEMIN()
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
        @eval PARTR function $_C_DELETEMIN()
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
    @eval PARTR begin
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

if PERIODIC_K !== nothing
    _check_partr_crc()
    _ecount(field) = MULTIQ_VALIDATE ? :(s.$field += 1) : nothing
    # VALIDATE only: the two negative controls for the `multiq_check_empty` probes. `lengths` reads
    # a ring's capacity instead of the live count (never empty: a thread would never sleep);
    # `firstbucket` reads only the first bucket (empty while a task of another priority waits: a
    # lost wake-up).
    const _E_NEGATIVE = MULTIQ_VALIDATE ? get(ENV, "E_NEGATIVE", "") : ""
    _E_NEGATIVE in ("", "lengths", "firstbucket") || error("E_NEGATIVE must be lengths or firstbucket")
    const _E_EMPTY = _E_NEGATIVE == "lengths" ? :(length(hs[i].buckets[1].tasks) == 0) :
                     _E_NEGATIVE == "firstbucket" ? :(hs[i].buckets[1].n == 0) :
                     :((@atomic :monotonic hs[i].ntasks) == 0)
    @eval PARTR begin
        # E: one ring deque per priority. `head` is the ring index of the oldest entry; the ring's
        # capacity is a power of two, so the k-th oldest is at `e_idx(b, k)`. `shadow` is the same
        # entries in insertion order, VALIDATE only (empty otherwise).
        mutable struct ebucket
            const priority::UInt16
            tasks::Vector{Task}
            stamps::Vector{UInt64}
            head::Int
            n::Int
            const shadow::Vector{Task}
            ebucket(priority::UInt16) = new(priority, Vector{Task}(undef, 256), Vector{UInt64}(undef, 256), 1, 0, Task[])
        end

        mutable struct eheap
            const lock::SpinLock
            const buckets::Vector{ebucket}   # sorted by priority; read and written under `lock`
            @atomic ntasks::Int32            # live entries over all buckets
            @atomic priority::UInt16         # the lowest priority with a live entry, typemax if none
            @atomic oldest::UInt64           # that bucket's oldest stamp, typemax if none
            eheap() = new(SpinLock(), [ebucket(zero(UInt16))], zero(Int32), typemax(UInt16), typemax(UInt64))
        end

        const e_heaps = [Vector{eheap}(undef, 0), Vector{eheap}(undef, 0)]
        const e_heaps_lock = [SpinLock(), SpinLock()]
        const e_budget = $PERIODIC_K

        # One per thread, 128 bytes: the pop counter, then VALIDATE-only counts and the pool and
        # heap of this thread's last insert (for the probe).
        mutable struct epopstate
            count::Int      # successful pops since the last periodic one
            pops::Int       # successful pops, periodic ones included
            periodic::Int   # periodic pops
            older::Int      # periodic pops that went to the second sampled heap, whose oldest was older
            last_tp::Int
            last_heap::Int
            retries::Int    # sticky retries since the last successful pop
            fallbacks::Int  # pops that took this thread's own task at the other end, the asked-for end being pinned
            pad::NTuple{8,Int}
            epopstate() = new(0, 0, 0, 0, 0, 0, 0, 0, ntuple(_ -> 0, 8))
        end
        const e_states = [epopstate() for _ in 1:Threads.maxthreadid()]

        # The insertion stamp: rdtsc. Comparable across cores where the TSC is invariant, which is
        # the case where Linux uses it as the clocksource (checked at load, below).
        @inline e_stamp() = Base.llvmcall(("""
            declare i64 @llvm.readcyclecounter()
            define i64 @e_stamp() #0 {
              %t = call i64 @llvm.readcyclecounter()
              ret i64 %t
            }
            attributes #0 = { alwaysinline }
            """, "e_stamp"), UInt64, Tuple{})

        @inline e_idx(b::ebucket, k::Int) = ((b.head - 1 + k - 1) & (length(b.tasks) - 1)) + 1

        # VALIDATE only: an assert that fires inside the scheduler must not throw there (an
        # exception in a thread's scheduler task kills that task and the process hangs), so it
        # prints without buffering and aborts (exit status 134).
        @noinline function e_fail(msg::String)
            ccall(:jl_safe_printf, Cvoid, (Cstring, Cstring), "%s\n", msg)
            ccall(:abort, Cvoid, ())
        end

        # The bucket for `priority`, made if absent; the vector stays sorted.
        function e_bucket!(heap::eheap, priority::UInt16)
            bs = heap.buckets
            for i in 1:length(bs)
                p = bs[i].priority
                p == priority && return bs[i]
                if p > priority
                    b = ebucket(priority)
                    insert!(bs, i, b)
                    return b
                end
            end
            b = ebucket(priority)
            push!(bs, b)
            return b
        end

        # The index of the lowest-priority bucket with a live entry, 0 if none.
        @inline function e_min_index(heap::eheap)
            bs = heap.buckets
            for i in 1:length(bs)
                bs[i].n > 0 && return i
            end
            return 0
        end

        function e_grow!(b::ebucket)
            cap = length(b.tasks)
            tasks = Vector{Task}(undef, 2 * cap)
            stamps = Vector{UInt64}(undef, 2 * cap)
            for k in 1:b.n
                i = e_idx(b, k)
                tasks[k] = b.tasks[i]
                stamps[k] = b.stamps[i]
            end
            b.tasks = tasks
            b.stamps = stamps
            b.head = 1
            return nothing
        end

        @inline function e_push_back!(b::ebucket, task::Task, stamp::UInt64)
            b.n == length(b.tasks) && e_grow!(b)
            b.n += 1
            i = e_idx(b, b.n)
            b.tasks[i] = task
            b.stamps[i] = stamp
            $(MULTIQ_VALIDATE ? :(push!(b.shadow, task)) : nothing)
            return nothing
        end

        @inline e_back(b::ebucket) = b.tasks[e_idx(b, b.n)]
        @inline e_front(b::ebucket) = b.tasks[b.head]

        @inline function e_remove_back!(b::ebucket)
            i = e_idx(b, b.n)
            $(MULTIQ_VALIDATE ? :(pop!(b.shadow) === b.tasks[i] || e_fail("E: the back of the ring is not the newest entry")) : nothing)
            $_UNSET(b.tasks, i)
            b.n -= 1
            return nothing
        end

        @inline function e_remove_front!(b::ebucket)
            i = b.head
            $(MULTIQ_VALIDATE ? :(popfirst!(b.shadow) === b.tasks[i] || e_fail("E: the front of the ring is not the oldest entry")) : nothing)
            $_UNSET(b.tasks, i)
            b.head = (i & (length(b.tasks) - 1)) + 1
            b.n -= 1
            return nothing
        end

        # After a change, under the lock: publish the live count, the lowest live priority and
        # that bucket's oldest stamp (what the two-choice pop and the periodic choice read).
        @inline function e_publish!(heap::eheap, ntasks::Int32)
            @atomic :monotonic heap.ntasks = ntasks
            bi = e_min_index(heap)
            if bi == 0
                @atomic :monotonic heap.priority = typemax(UInt16)
                @atomic :monotonic heap.oldest = typemax(UInt64)
            else
                b = heap.buckets[bi]
                @atomic :monotonic heap.priority = b.priority
                @atomic :monotonic heap.oldest = b.stamps[b.head]
            end
            return nothing
        end

        # The build's `multiq_size`, over E's heaps.
        function e_multiq_size(tpid::Int8)
            nt = UInt32(Threads._nthreads_in_pool(tpid))
            $_NT_GUARD
            tp = tpid + 1
            tpheaps = e_heaps[tp]
            heap_c = UInt32(2)
            heap_p = UInt32(length(tpheaps))

            if heap_c * nt <= heap_p
                return heap_p
            end

            @lock e_heaps_lock[tp] begin
                tpheaps = e_heaps[tp]
                heap_p = UInt32(length(tpheaps))
                nt = UInt32(Threads._nthreads_in_pool(tpid))
                $_NT_GUARD
                if heap_c * nt <= heap_p
                    return heap_p
                end

                heap_p += heap_c * nt
                newheaps = Vector{eheap}(undef, heap_p)
                copyto!(newheaps, tpheaps)
                for i = (1 + length(tpheaps)):heap_p
                    newheaps[i] = eheap()
                end
                e_heaps[tp] = newheaps
            end

            return heap_p
        end

        # The build's `multiq_insert`, with a push at the back of the priority's deque where the
        # build sifts up.
        function multiq_insert(task::Task, priority::UInt16)
            tpid = ccall(:jl_get_task_threadpoolid, Int8, (Any,), task)
            @assert tpid > -1 "invalid tpid"
            heap_p = e_multiq_size(tpid)
            tp = tpid + 1

            task.priority = priority

            rn = cong(heap_p)
            tpheaps = e_heaps[tp]
            while !trylock(tpheaps[rn].lock)
                rn = cong(heap_p)
            end

            heap = tpheaps[rn]
            b = e_bucket!(heap, priority)
            e_push_back!(b, task, e_stamp())
            e_publish!(heap, heap.ntasks + Int32(1))
            $(MULTIQ_VALIDATE ? :(let s = e_states[Threads.threadid()]; s.last_tp = Int(tp); s.last_heap = Int(rn); end) : nothing)
            unlock(heap.lock)

            return true
        end

        # The build's `multiq_check_empty`, reading the live counts.
        function multiq_check_empty()
            tid = Threads.threadid()
            tp = ccall(:jl_threadpoolid, Int8, (Int16,), tid-1) + 1
            if tp == 0 # Foreign thread
                return true
            end
            hs = e_heaps[tp]
            for i = UInt32(1):length(hs)
                $_E_EMPTY || return false
            end
            return true
        end
    end

    # `multiq_deletemin`, per build: the build's two-choice loop, then the deque's back or front.
    # `periodic` is fixed before the loop from this thread's counter, so a sticky retry keeps it.
    const _E_CHOOSE = quote
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
            elseif prio1 == prio2
                if prio1 == typemax(UInt16)
                    continue
                elseif periodic && rn1 != rn2 &&
                        (@atomic :monotonic tpheaps[rn2].oldest) < (@atomic :monotonic tpheaps[rn1].oldest)
                    rn1 = rn2   # E: of the two, the heap whose oldest entry is older
                    $(_ecount(:older))
                end
            end
            if trylock(tpheaps[rn1].lock)
                if prio1 == tpheaps[rn1].priority
                    break
                end
                unlock(tpheaps[rn1].lock)
            end
        end

        @assert @isdefined(rn1) "Assertion to tell the compiler about the definedness of this variable"
        heap = tpheaps[rn1]
        bi = e_min_index(heap)
        @assert bi != 0 "E: a heap with a live priority has no live bucket"
        b = heap.buckets[bi]
        # The end this pop serves. If that entry is pinned to another thread and the OTHER end is
        # this thread's own task, take that instead (`fallbacks`). A task re-enqueued by `notify`
        # before its own thread switched out keeps that thread's tid until then; stock serves one
        # position, the root, so such a task is always reachable by its owner on the owner's next
        # pop of that heap, and the retry resolves. E serves two ends: a thread in normal mode
        # whose own task sits at a front, or in periodic mode whose own task sits at a back, could
        # never take it, and with every other end pinned to a thread in the same state all threads
        # spun (seen in a warm-up cell within seconds: 10^6 sticky retries on a front whose owner
        # was stuck on a back). Taking one's own task is what stock does in that case too (the
        # switch to the current task is a no-op), so the order is otherwise unchanged.
        front = periodic
        task = front ? e_front(b) : e_back(b)
        ok = ccall(:jl_set_task_tid, Cint, (Any, Cint), task, tid-1) != 0
        if !ok && b.n > 1
            other = front ? e_back(b) : e_front(b)
            if ccall(:jl_get_task_tid, Int16, (Any,), other) == tid - 1
                front = !front
                task = other
                ok = true
                $(_ecount(:fallbacks))
            end
        end
    end
    # VALIDATE only, on a sticky retry: a task nobody can run (pinned to a thread that never pops
    # this pool's heaps) would make every thread spin here forever; say which task after 10^6.
    const _E_STICKY = MULTIQ_VALIDATE ? quote
        s.retries += 1
        if s.retries == 1_000_000
            e_fail(string("E: 10^6 sticky retries in a row on tid ", tid, " (periodic ", periodic, "): the task at the ",
                          front ? "front" : "back", " has tid ", ccall(:jl_get_task_tid, Int16, (Any,), task),
                          ", sticky ", task.sticky, ", pool ", ccall(:jl_get_task_threadpoolid, Int8, (Any,), task),
                          ", state ", task._state, ", heap ", rn1, " of pool ", tp, " with ", heap.ntasks, " live"))
        end
    end : nothing
    # A front pop resets the counter whichever mode asked for it; a periodic pop that fell back
    # to the back leaves the counter at the budget, so the next pop is periodic again.
    const _E_POP = quote
        $(MULTIQ_VALIDATE ? :(s.retries = 0) : nothing)
        if front
            e_remove_front!(b)
            s.count = 0
            $(_ecount(:periodic))
        else
            e_remove_back!(b)
            s.count += 1
        end
        e_publish!(heap, heap.ntasks - Int32(1))
        $(_ecount(:pops))
        $_COUNT
        unlock(heap.lock)

        return task
    end
    if VERSION >= v"1.14-"
        @eval PARTR function multiq_deletemin()
            local rn1::UInt32
            local heap, task, b, front::Bool, ok::Bool   # assigned in the loop, used after it

            tid = Threads.threadid()
            tp = ccall(:jl_threadpoolid, Int8, (Int16,), tid-1) + 1
            if tp == 0 # Foreign thread
                return nothing
            end
            tpheaps = e_heaps[tp]
            s = e_states[tid]
            periodic = s.count >= e_budget - 1

            while true
                GC.safepoint()
                $_E_CHOOSE
                if !ok
                    $_E_STICKY
                    $_WAKE_OWNER
                    continue
                end
                break
            end
            $_E_POP
        end
    else
        @eval PARTR function multiq_deletemin()
            local rn1::UInt32

            tid = Threads.threadid()
            tp = ccall(:jl_threadpoolid, Int8, (Int16,), tid-1) + 1
            if tp == 0 # Foreign thread
                return nothing
            end
            tpheaps = e_heaps[tp]
            s = e_states[tid]
            periodic = s.count >= e_budget - 1

            @label retry
            GC.safepoint()
            $_E_CHOOSE
            if !ok
                $_E_STICKY
                $(VERSION >= v"1.13-" ? _WAKE_OWNER : :(unlock(heap.lock)))
                @goto retry
            end
            $_E_POP
        end
    end
    let cs = "/sys/devices/system/clocksource/clocksource0/current_clocksource"
        isfile(cs) && strip(read(cs, String)) == "tsc" ||
            error("E stamps entries with rdtsc, which is only an order across cores where the TSC is the clocksource")
    end
end

# The heap list the variant runs on: what nested.jl counts as "in heaps".
const MULTIQ_HEAP_LISTS = PERIODIC_K !== nothing ? PARTR.e_heaps :
                          MULTIQ_SEQ_HEAPS ? PARTR.seq_heaps : PARTR.heaps

# What nested.jl counts as "in heaps": the tasks queued in the live scheduler's structures of pool
# `tp` (1 `:interactive`, 2 `:default`), read racily. Under partr and every variant, the heaps'
# `ntasks`; under the work-stealing backend the live span of every ring (`tail - real`), the LIFO
# slots and the injection stripes, which is where a queued task sits there.
function multiq_queued(tp::Int)
    n = 0
    if MULTIQ_BACKEND === :partr
        for h in MULTIQ_HEAP_LISTS[tp]
            n += @atomic :monotonic h.ntasks
        end
    else
        WS = Base.Scheduler.ChosenScheduler
        for r in WS.Rings[tp]
            n += Int((@atomic :monotonic r.tail) - WS.real_of(@atomic :monotonic r.head))
            (@atomic :monotonic r.lifo) === nothing || (n += 1)
        end
        for s in WS.Injects[tp].stripes
            n += @atomic :monotonic s.n
        end
    end
    return n
end
MULTIQ_BACKEND in (:partr, :workstealing) ||
    error("multiq_queued knows partr and workstealing, not $(MULTIQ_BACKEND)")

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

# On a build with a selectable backend, confirm `MULTIQ_BACKEND` from what the burst touched: the
# work-stealing rings grow to one per thread of each pool on first use and partr's heaps grow on
# the first insert, so exactly one of the two structures is populated after it.
function multiq_backend_check()
    isdefined(Base, :Scheduler) || return nothing
    Base.JULIA_SCHEDULER === MULTIQ_BACKEND ||
        error("Base.JULIA_SCHEDULER is :$(Base.JULIA_SCHEDULER), but ChosenScheduler is $(MULTIQ_BACKEND)")
    rings = isdefined(Base.Scheduler, :Workstealing) ?
        (length(Base.Scheduler.Workstealing.Rings[1]), length(Base.Scheduler.Workstealing.Rings[2])) : (0, 0)
    heaps = (length(PARTR.heaps[1]), length(PARTR.heaps[2]))
    if MULTIQ_BACKEND === :workstealing
        rings == (Threads.nthreads(:interactive), Threads.nthreads(:default)) ||
            error("workstealing build, but the rings per pool are $rings")
        heaps == (0, 0) || error("workstealing build, but partr grew heaps $heaps")
    else
        rings == (0, 0) || error("partr build, but work-stealing rings grew: $rings")
        heaps[2] > 0 || error("partr build, but no heap in the :default pool after the warm-up")
    end
    println(stderr, "multiq_variant: backend ", MULTIQ_BACKEND, " confirmed: Base.JULIA_SCHEDULER = :",
            Base.JULIA_SCHEDULER, ", rings per pool ", rings, ", partr heaps per pool ", heaps)
    return nothing
end
multiq_backend_check()

println(stderr, "multiq_variant: VARIANT=", MULTIQ_VARIANT, MULTIQ_VALIDATE ? " (VALIDATE)" : "",
        MULTIQ_SEQ_HEAPS || PERIODIC_K !== nothing ? ", partr.jl crc matches $(VERSION)" : "",
        SLOT_BUDGET === nothing ? "" : ", slot budget $(SLOT_BUDGET == typemax(Int) ? "none" : SLOT_BUDGET)",
        PERIODIC_K === nothing ? "" : ", periodic pop every $(PERIODIC_K == typemax(Int) ? "never" : PERIODIC_K)",
        PERIODIC_K !== nothing && !isempty(_E_NEGATIVE) ? ", NEGATIVE CONTROL $(_E_NEGATIVE)" : "")

# Calls into the new code, per thread (validation only).
multiq_variant_calls() = [PARTR.variant_calls[64 * (tid - 1) + 1] for tid in 1:Threads.maxthreadid()]

# End of a process: under C and E, nothing ever went into the build's own heaps, and the
# variant's are empty (under E: every live count 0 and every bucket's ring and shadow empty).
function multiq_variant_check()
    MULTIQ_SEQ_HEAPS || PERIODIC_K !== nothing || return nothing
    for tp in 1:2
        n_old = sum((h.ntasks for h in PARTR.heaps[tp]); init = 0)
        n_new = sum((h.ntasks for h in MULTIQ_HEAP_LISTS[tp]); init = 0)
        n_old == 0 || error("$MULTIQ_VARIANT: $n_old tasks in the build's own heaps of pool $tp")
        n_new == 0 || error("$MULTIQ_VARIANT: $n_new tasks left in the variant's heaps of pool $tp")
    end
    if SLOT_BUDGET !== nothing
        full = [tid for tid in 1:Threads.maxthreadid() if (@atomic PARTR.slots[tid].task) !== nothing]
        isempty(full) || error("D: tasks left in the slots of tids $full")
    end
    if PERIODIC_K !== nothing
        for tp in 1:2, h in PARTR.e_heaps[tp], b in h.buckets
            b.n == 0 || error("E: bucket $(b.priority) of a pool-$tp heap holds $(b.n) entries at exit")
            isempty(b.shadow) || error("E: bucket $(b.priority) of a pool-$tp heap has $(length(b.shadow)) shadow entries at exit")
            h.priority == typemax(UInt16) || error("E: a pool-$tp heap publishes priority $(h.priority) while empty")
        end
    end
    return nothing
end

# VALIDATE only: kill the process with SIGALRM (exit status 142) unless `multiq_watchdog(0)` comes
# within `secs` seconds. A lost wakeup leaves every thread asleep, so the watchdog needs none.
multiq_watchdog(secs::Integer) = MULTIQ_VALIDATE ? Int(ccall(:alarm, Cuint, (Cuint,), secs)) : 0

# D, VALIDATE only: per `:default` tid, the counts kept in its slot.
function multiq_slot_counts()
    SLOT_BUDGET === nothing && return nothing
    ss = PARTR.slots
    tids = PARTR.slot_tids
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
            s = PARTR.slots[Threads.threadid()]
            dummy = Task(() -> nothing)
            prev = @atomicswap s.task = dummy
            e = PARTR.multiq_check_empty()
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

# E, VALIDATE only: per tid, the counts kept in its pop state.
function multiq_budget_counts()
    PERIODIC_K === nothing && return nothing
    es = PARTR.e_states
    tids = 1:Threads.maxthreadid()
    return (tids = tids, pops = [es[t].pops for t in tids], periodic = [es[t].periodic for t in tids],
            older = [es[t].older for t in tids], fallbacks = [es[t].fallbacks for t in tids])
end

# E, VALIDATE only: print the pop counts since `before` (a `multiq_budget_counts()`) and check
# the budget: per tid, periodic pops equal pops ÷ K to within one (the counter is mid-cycle at
# either end of the window), none at all under E-inf, and under E<K> some on every `:default` tid
# when `everywhere` says the workload keeps every thread popping, else some somewhere.
function multiq_budget_check(label, before; everywhere::Bool = false)
    PERIODIC_K === nothing && return nothing
    now = multiq_budget_counts()
    d(k) = getfield(now, k) .- getfield(before, k)
    pops, periodic, older, fb = d(:pops), d(:periodic), d(:older), d(:fallbacks)
    tids = Threads.threadpooltids(:default)
    println(stderr, "validate: E pops, ", label, ": pops ", pops, ", periodic ", periodic, ", older ", older,
            ", fallbacks ", fb)
    if PERIODIC_K == typemax(Int)
        # Under E-inf a front is taken only as a fallback from a pinned back, and counts as one.
        all(periodic .== fb) || error("E-inf: $label: periodic pops ", periodic, " beyond the fallbacks ", fb)
    else
        # A fallback moves one pop to the other end: a front taken in normal mode adds a periodic
        # pop and restarts the cycle, a back taken in periodic mode delays one.
        for t in now.tids
            (pops[t] - fb[t]) ÷ PERIODIC_K - 1 <= periodic[t] <= pops[t] ÷ PERIODIC_K + 1 + fb[t] ||
                error("E: $label: tid $t made $(periodic[t]) periodic pops of $(pops[t]) with $(fb[t]) fallbacks, K = $PERIODIC_K")
        end
        if everywhere
            all(t -> periodic[t] > 0, tids) || error("E: $label: no periodic pops on some :default tid: ", periodic[tids])
        else
            sum(periodic[tids]) > 0 || error("E: $label: no periodic pops on any :default tid")
        end
    end
    return nothing
end

# E, VALIDATE only, two probes of `multiq_check_empty`, the check a thread about to sleep makes
# after publishing `sleeping` (scheduler.c, `jl_task_get_next`).
# 1. Every heap drained: it must say empty (`E_NEGATIVE=lengths` fails it: a thread that never
#    sleeps). First, because under that control no thread sleeps and the second probe's dummy is
#    taken before the check runs.
# 2. A task in a heap, no wake-up sent, in bucket 0 and in a bucket the insert has to make: it
#    must say non-empty (`E_NEGATIVE=firstbucket` fails the second: a lost wake-up). The dummy is
#    taken back out through the same bucket, under the heap's lock.
function _e_probe(reps::Int = 20)
    P = PARTR
    seen_empty = false
    for _ in 1:reps
        sleep(0.05)
        seen_empty = fetch(Threads.@spawn :default P.multiq_check_empty())
        seen_empty && break
    end
    seen_empty || error("E: multiq_check_empty() said non-empty $reps times with every heap drained")
    println(stderr, "multiq_variant: E probe 1: multiq_check_empty() says empty with the heaps drained")
    for prio in (0x0000, 0x0007)
        checked = 0
        for _ in 1:reps
            sleep(0.05)   # every other thread goes back to sleep
            empty, got = fetch(Threads.@spawn :default begin
                t0 = time_ns()   # hold without yielding until the threads this spawn woke are asleep again
                while time_ns() - t0 < 5_000_000
                    GC.safepoint()
                end
                dummy = Task(() -> nothing)
                Threads._spawn_set_thrpool(dummy, :default)
                P.multiq_insert(dummy, prio)
                e = P.multiq_check_empty()
                s = P.e_states[Threads.threadid()]
                heap = P.e_heaps[s.last_tp][s.last_heap]
                lock(heap.lock)
                b = P.e_bucket!(heap, prio)
                back = b.n > 0 && P.e_back(b) === dummy
                if back
                    P.e_remove_back!(b)
                    P.e_publish!(heap, heap.ntasks - Int32(1))
                end
                unlock(heap.lock)
                (e, back)
            end)
            got || continue   # a spinning thread popped it (and ran a no-op): no verdict this time
            empty && error("E: multiq_check_empty() says empty while a heap holds a task of priority $prio")
            checked += 1
        end
        checked >= reps ÷ 2 || error("E: only $checked of $reps check_empty probes kept their task (priority $prio)")
        println(stderr, "multiq_variant: E probe 2 (priority ", prio, "): multiq_check_empty() saw a queued task ",
                checked, " of ", reps, " times (the rest were taken first)")
    end
    return nothing
end

# ── single-heap order asserts (VALIDATE=1) ──────────────────────────────────────────────────
# One heap, driven by the variant's own sift functions and the per-heap steps of the variant's
# `multiq_insert` / `multiq_deletemin`, with dummy tasks that never run.

_newheap() = MULTIQ_SEQ_HEAPS ? PARTR.seqheap() : PARTR.taskheap()

function _push!(h, t::Task)
    if h.ntasks >= length(h.tasks)
        resize!(h.tasks, 2 * length(h.tasks))
        h isa PARTR.taskheap || resize!(h.seqs, 2 * length(h.seqs))
    end
    n = h.ntasks + Int32(1)
    @atomic h.ntasks = n
    h.tasks[n] = t
    if !(h isa PARTR.taskheap)
        h.seqs[n] = h.next
        h.next += UInt64(1)
    end
    PARTR.multiq_sift_up(h, n)
end

function _pop!(h)
    t = h.tasks[1]
    n = h.ntasks
    @atomic h.ntasks = n - Int32(1)
    h.tasks[1] = h.tasks[n]
    h isa PARTR.taskheap || (h.seqs[1] = h.seqs[n])
    isdefined(Base, :unsetindex!) ? Base.unsetindex!(h.tasks, Int(n)) : Base._unsetindex!(h.tasks, Int(n))
    n > 1 && PARTR.multiq_sift_down(h, Int32(1))
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

# ── E's single-heap asserts: one `eheap` driven by E's own bucket operations ─────────────────

_e_newheap() = PARTR.eheap()

function _e_push!(h, t::Task, prio::UInt16 = 0x0000)
    t.priority = prio
    b = PARTR.e_bucket!(h, prio)
    PARTR.e_push_back!(b, t, PARTR.e_stamp())
    PARTR.e_publish!(h, h.ntasks + Int32(1))
end

# A normal pop (the newest of the lowest live priority) or a periodic one (the oldest of it).
function _e_pop!(h, periodic::Bool)
    b = h.buckets[PARTR.e_min_index(h)]
    t = periodic ? PARTR.e_front(b) : PARTR.e_back(b)
    periodic ? PARTR.e_remove_front!(b) : PARTR.e_remove_back!(b)
    PARTR.e_publish!(h, h.ntasks - Int32(1))
    return t
end

# Fill N, then drain one way: the pop order, as insertion indices.
function _e_fill_drain(n::Int, periodic::Bool)
    h, ids = _e_newheap(), IdDict{Task,Int}()
    foreach(i -> _e_push!(h, _dummy(ids, i)), 1:n)
    return [ids[_e_pop!(h, periodic)] for _ in 1:n]
end

# Random pushes, normal pops and periodic pops against a plain vector in insertion order, which
# a normal pop takes the end of and a periodic pop the start of; also grows past the ring's
# initial capacity. Returns the number of mismatches (0) and the number of pops made.
function _e_interleaved(n::Int)
    h, ids = _e_newheap(), IdDict{Task,Int}()
    ref = Int[]
    pushed, pops, bad = 0, 0, 0
    state = UInt64(0x9e3779b97f4a7c15)
    while pops < n
        state = state * 0x5851f42d4c957f2d + 1
        r = (state >> 33) % 5
        if pushed < n && (isempty(ref) || r < 3)
            pushed += 1
            _e_push!(h, _dummy(ids, pushed))
            push!(ref, pushed)
        elseif r == 3
            pops += 1
            ids[_e_pop!(h, true)] == popfirst!(ref) || (bad += 1)
        else
            pops += 1
            ids[_e_pop!(h, false)] == pop!(ref) || (bad += 1)
        end
        length(ref) == h.ntasks || (bad += 1)
    end
    return bad, pops
end

# Keep N in the heap, pop one and push one M times, with every K-th pop periodic: the most pops
# any served task waited, and the most any task still in the heap has waited.
function _e_steady(n::Int, m::Int, k::Int)
    h, born = _e_newheap(), IdDict{Task,Int}()
    foreach(i -> _e_push!(h, _dummy(born, 0)), 1:n)
    worst = 0
    for step in 1:m
        t = _e_pop!(h, k != typemax(Int) && step % k == 0)
        worst = max(worst, step - born[t])
        delete!(born, t)
        _e_push!(h, _dummy(born, step))
    end
    return worst, maximum(m .- values(born))
end

# Priorities: a lower priority comes first in both orders, whatever its age.
function _e_priorities()
    h, ids = _e_newheap(), IdDict{Task,Int}()
    for (i, p) in enumerate((0x0003, 0x0000, 0x0005, 0x0000, 0x0003))
        _e_push!(h, _dummy(ids, i), p)
    end
    length(h.buckets) == 3 || error("E: $(length(h.buckets)) buckets for priorities 0, 3, 5")
    h.priority == 0x0000 || error("E: published priority $(h.priority), expected 0")
    newest = [ids[_e_pop!(h, false)] for _ in 1:5]
    for (i, p) in enumerate((0x0003, 0x0000, 0x0005, 0x0000, 0x0003))
        _e_push!(h, _dummy(ids, i), p)
    end
    oldest = [ids[_e_pop!(h, true)] for _ in 1:5]
    h.priority == typemax(UInt16) || error("E: published priority $(h.priority) while empty")
    return newest, oldest
end

# Fill N, then time a drain by normal pops: ns per pop, on one heap with no scheduler.
function _e_drain_ns(n::Int)
    h, ids = _e_newheap(), IdDict{Task,Int}()
    foreach(i -> _e_push!(h, _dummy(ids, i)), 1:n)
    t0 = time_ns()
    for _ in 1:n
        _e_pop!(h, false)
    end
    return (time_ns() - t0) / n
end

function _e_unit_asserts()
    n, m = 30, 3000
    newest, oldest = _e_fill_drain(20, false), _e_fill_drain(20, true)
    newest == collect(20:-1:1) || error("E: a drain by normal pops gave $newest")
    oldest == collect(1:20) || error("E: a drain by periodic pops gave $oldest")
    bad, pops = _e_interleaved(2000)
    bad == 0 || error("E: $bad of $pops interleaved pops disagreed with the reference deque")
    worst, waiting = _e_steady(n, m, PERIODIC_K)
    if PERIODIC_K == typemax(Int)
        waiting == m || error("E-inf: in steady state the oldest has waited $waiting of $m pops, expected all")
    else
        worst <= n * PERIODIC_K || error("E: steady state served a task after $worst pops, N × K = $(n * PERIODIC_K)")
        waiting <= n * PERIODIC_K || error("E: steady state oldest waiting $waiting pops, N × K = $(n * PERIODIC_K)")
    end
    pn, po = _e_priorities()
    pn == [4, 2, 5, 1, 3] || error("E: normal pops over priorities (3,0,5,0,3) gave $pn")
    po == [2, 4, 1, 5, 3] || error("E: periodic pops over priorities (3,0,5,0,3) gave $po")
    multiq_watchdog(60); _e_probe(); multiq_watchdog(0)
    println(stderr, "multiq_variant: single-heap asserts passed for ", MULTIQ_VARIANT,
            ": normal pops drain 20 as ", newest, ", periodic pops as ", oldest, "; ", pops,
            " interleaved pops match the reference deque; steady state N = ", n, ", K = ",
            PERIODIC_K == typemax(Int) ? "inf" : PERIODIC_K, ": worst served after ", worst,
            " pops, oldest waiting ", waiting, " of ", m, "; priorities (3,0,5,0,3): newest-first ",
            pn, ", oldest-first ", po)
    _e_drain_ns(1000)
    println(stderr, "multiq_variant: single-heap drain by normal pops, ns per pop (best of 3): ",
            join(("n = $n: $(round(minimum(_e_drain_ns(n) for _ in 1:3); digits = 1))" for n in (1000, 10_000)), ", "))
    return nothing
end

function multiq_unit_asserts()
    PERIODIC_K === nothing || return _e_unit_asserts()
    if MULTIQ_BACKEND !== :partr
        println(stderr, "multiq_variant: single-heap asserts skipped: the build's scheduler is ", MULTIQ_BACKEND)
        return nothing
    end
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
