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
#   M-f, M-l, M-h-f, M-h-l, M-none, O-f, O-l  stock's heaps untouched, plus one FIFO queue for the
#       `:default` pool. Every task has a class, F or L, fixed when it is first made runnable; F tasks
#       go to the queue's tail on every enqueue (the first one, a wake-up by `notify`, a `yield()`),
#       L tasks take stock's path: the build's own `multiq_insert`, `multiq_deletemin` and
#       `multiq_check_empty`, parsed from its partr.jl the way A0 takes `multiq_sift_down` and
#       renamed `stock_multiq_*`, over the build's own heaps and sifts. Who is F: under M (M-f, M-l)
#       the tasks the harness marks when it makes them (`spawn_marked`: spawn_order.jl marks every
#       handler and every client), under M-h only the handlers, under M-none nothing (the control
#       for the structure: every task L, the queue empty, what an unmarked program pays); under O
#       a task whose first enqueue comes from a thread of another pool, with no mark. The suffix is
#       the serve rule: `-f` pops the queue before the heaps, `-l` the heaps before the queue; M-none
#       runs `-f`, the rule that reads the queue on every pop. The class is bit 15 of
#       `Task.priority`: a new task starts at 0 and does not inherit its parent's, and an F task
#       never enters the heaps, so they keep seeing priority 0 (an F task that would have to take
#       stock's path, on an `:interactive` pool of two or more threads, has the bit cleared and is
#       counted; never in the layouts measured). The queue is a ring under one spin lock, with a
#       count read without it by the pops' fast path and by `multiq_check_empty`, which reports it,
#       so a thread does not sleep with a task queued there; `enq_work`'s wake-up follows an F insert
#       exactly as it follows a heap insert, since the insert is inside `multiq_insert`. The F pop
#       meets the sticky-retry protocol: it scans at most nthreads entries from the head, takes the
#       first one this thread may run (an unpinned task or its own), wakes the owners of those passed
#       over and leaves them in place, so an owner always reaches its own task and nobody waits behind
#       a pinned head.
#   M-t, M-t0, M-p<K>, M-h-t  M with a share between the F queue and the heaps instead of a strict
#       order. All keep M-l's heaps-first default and act only on a pop that finds the F queue
#       non-empty; with it empty the pop is M-none's (one relaxed load, then stock's pop: no clock,
#       no account). -t, a share of time: each thread keeps, in a padded 128-byte struct of its own,
#       a balance of cycles spent on F tasks minus cycles on L tasks, credited pop to pop with
#       rdtsc (the interval since its last accounted pop goes to the side of the task that pop
#       returned; none after a pop that found nothing), clamped to +-10 ms, and tries the F queue
#       first when F has had less time (balance < 0), the heaps first otherwise; the other side is
#       the fallback. -t0 is the same code with the balance never moved (always heaps first): the
#       negative control, which must behave as M-l. -p<K>, a share of pops: the F queue first on
#       every K-th successful accounted pop of a thread, the heaps first otherwise. M-h-t is -t
#       with the handlers marked only. The interval also covers what the thread ran from its own
#       sticky workqueue between two multiq pops, and the first accounted pop after a run of
#       M-none-path pops credits its (capped) interval to the side of the last accounted one.
#     M-l-r<d> and M-h-l-r<d>, the rings (2026-11-16): the F queue split into one ring per stock
#       heap (2 per thread), each an F queue of its own with its own lock. An insert takes a random
#       ring and stamps the entry with rdtsc inside the lock (kept rising within the ring); a pop,
#       after stock's comes back empty, samples d rings (racy reads of each count and head stamp)
#       and runs M's F pop (sticky-retry scan, stall check) on the one with the older head, up to
#       four samples, then one pass over every ring from a random one. A pool flag, set once at
#       the first marked insert and never cleared, is all an unmarked program reads; check_empty
#       reads every ring once it is set. No shared write per operation: no pool counter, no
#       sequence (the stamps are the clock's). M-l-r<d>o inserts into one of the inserting thread's
#       own two rings instead (a random one from a thread of another pool).
#     M-t-r<d>, M-t0-r<d>: M-t's share moved onto the rings, nothing else changed (the share acts
#       when some ring is non-empty, with the flag set). The controls of the classes run.
#     The classes (2026-11-16, agent-config #82 Idea 5): a request's children count as the
#       request's. Three classes in `Task.priority`: F (bit 15, a marked root not yet admitted), R
#       (bit 14, request work in flight) and L (no bit: stock). A task gets its class once, at its
#       first enqueue, from the task that enqueues it: one with no mark of its own whose first
#       enqueue is made by a task of class F or R is a descendant (read from the enqueuer's own
#       field, written to the new task's own field; with the flag unset nothing is read). A mark put
#       on a spawn is always a new root. A wake-up never moves a task between L and the request side.
#       All on the rings (d = 2):
#       M-il-r<d>, M-it-r<d> (-i, inherit into the queue): a descendant is F and goes to the rings, a
#         woken marked task goes back to the rings; serve rules M-l's and M-t's.
#       M-g-r<d>, M-g25-r<d>, M-g75-r<d>, M-g0-r<d>, M-h-g-r<d> (-g, groups): a descendant is R, and a
#         marked task that has started is R from then on, so the rings hold only roots that never ran.
#         R tasks go to a second set of stock heaps (`r_heaps`: the build's own insert, two-choice pop,
#         sticky retry and sifts, parsed from its partr.jl and renamed), with the class bits stripped
#         before the priority reaches a heap and R written back on the popped task. The request side
#         is the R heaps, then the rings. With the flag set a pop probes the three structures; when
#         only one side has work it pops that side and reads no clock (it records the side on its own
#         line); when both have work, M-t's time share decides, with the time of an R task credited to
#         the request side and a weight w for it (g: 1/2, g25: 1/4, g75: 3/4; g0: the balance never
#         moves, so L first, the negative control). The interval cap stays 10 ms.
#       M-gc-r<d> (#618, the `8,0` diagnostic): -g at w = 1/2 with honest accounts. -g reads the clock
#         only at a two-sided pop and credits the whole interval since the previous one to the side
#         of the last pop, which in a server is often a short one-sided L pop that followed a request
#         task's run. -gc reads the clock at every pop and credits each interval to the side of the
#         task that ran in it, when that task was popped while both sides had work. M-gc25-r<d> and
#         M-gc75-r<d> are -gc at -g's other two weights (#618, agent-config #82 Idea 8).
#     M-a<T>-r<d>: the rings with an age rule instead of a share: the heaps first unless the older
#       of the d sampled ring heads has waited more than T ms (the sweep cut first).
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
# VALIDATE=1 compiles a per-thread call counter into the new code (under M and O: the pops), and
# under M and O per-thread classification counts (F and L first enqueues, F re-enqueues, demotions,
# F and L pops, pinned entries passed over, inserts made by a thread outside the pools (`foreign`: in
# a server, Reseau's poller, adopted after this file loaded, counted in a spare slot), and tasks
# stock's heaps gave out with a class bit (`stock_bit`: an insert by unpatched code, which
# `multiq_fifo_check` refuses)), an order assert after every F pop, single-structure
# asserts and two check_empty probes (`M_NEGATIVE=blind` is the negative control), and under the shares
# per-thread counts of the time credited to each side (overall and while the heaps had work too), the
# cap's actions and the F-first choices; under C and D an assert,
# under the heap's lock, that every pop takes the (priority, sequence) minimum of its heap; under D
# also per-thread counts of slot pops, steals, budget flushes, displaced and bounced tasks; under E
# a shadow vector per bucket that every pop is checked against (the back is the newest entry, the
# front the oldest), per-thread counts of pops and periodic pops (periodic == pops ÷ K exactly, by
# construction), and two probes of `multiq_check_empty`. All are spliced in only then: the timed
# code is the build's plus the variant's change and nothing else. `multiq_watchdog` arms an
# `alarm()` for a validated run: a lost wakeup leaves every thread asleep, so the process is killed
# (exit status 142) instead of hanging.

const MULTIQ_VARIANT = get(ENV, "VARIANT", "A")
# The native mark (#618, agent-config #82 Idea 10): a Julia built from bench/julia/'s patch, whose
# `Task` has the field `sched_class` and whose scheduler is M-gc-r2 written inside Base.Partr.
# VARIANT=N marks what M-gc-r2 marks here (handlers and clients; in a server the request task),
# N-h the handlers only, N-none nothing. No runtime patch is loaded: the build's own
# `Threads._spawn_set_fair` marks, the one-time init runs at load (below), and VALIDATE reads the
# build's own counters, which only its validation build (`Base.Partr.SCHED_VALIDATE`) has. Every
# class-dependent constant below is M-gc-r2's (N, N-none) or M-h-gc-r2's (N-h). The runtime
# patch refuses to load on such a build: only A and the N variants run there.
const NATIVE_BUILD = hasfield(Task, :sched_class)
# N25 and N75 (the measurement session of the native mark): N at the request-side weights 1/4 and
# 3/4, M-gc25-r2's and M-gc75-r2's. The build reads its weight from JULIA_SCHED_FAIR_WEIGHT once, at
# the init this file runs at load, so the name sets it first; the check after that init confirms it.
const _N_WEIGHT = MULTIQ_VARIANT == "N25" ? "1/4" : MULTIQ_VARIANT == "N75" ? "3/4" : nothing
if _N_WEIGHT !== nothing
    get(ENV, "JULIA_SCHED_FAIR_WEIGHT", _N_WEIGHT) == _N_WEIGHT ||
        error("VARIANT=$(MULTIQ_VARIANT) sets JULIA_SCHED_FAIR_WEIGHT=$(_N_WEIGHT), and the environment has $(ENV["JULIA_SCHED_FAIR_WEIGHT"])")
    ENV["JULIA_SCHED_FAIR_WEIGHT"] = _N_WEIGHT
end
const MULTIQ_NATIVE = MULTIQ_VARIANT in ("N", "N-h", "N-none", "N-arm", "N25", "N75")
MULTIQ_NATIVE && !NATIVE_BUILD && error("VARIANT=$(MULTIQ_VARIANT) needs a Julia built with the native mark (bench/julia/)")
NATIVE_BUILD && !(MULTIQ_VARIANT == "A" || MULTIQ_NATIVE) &&
    error("the runtime patch refuses to load on a build with the native mark: VARIANT=$(MULTIQ_VARIANT); use A, N, N-h or N-none")
const _F_NAME = MULTIQ_VARIANT == "N-h" ? "M-h-gc-r2" : MULTIQ_NATIVE ? "M-gc-r2" : MULTIQ_VARIANT
const _D_MATCH = match(r"^D([0-9]+|-inf)$", MULTIQ_VARIANT)
const _E_MATCH = match(r"^E([0-9]+|-inf)$", MULTIQ_VARIANT)
const _F_MATCH = match(r"^(M|M-h|O)-(f|l|t|t0|p[0-9]+|il|it|g|g0|g25|g75|gc|gc25|gc75|a[0-9]+)(?:-r([0-9]+)(o?))?$|^M-none$",
                       _F_NAME)
MULTIQ_VARIANT in ("A", "A0", "B", "C") || _D_MATCH !== nothing || _E_MATCH !== nothing || _F_MATCH !== nothing ||
    error("VARIANT must be A, A0, B, C, D<K>, D-inf, E<K>, E-inf, M-f, M-l, M-t, M-t0, M-p<K>, M-h-f, M-h-l, ",
          "M-h-t, M-none, M-l-r<d>[o], M-h-l-r<d>, M-t-r<d>, M-t0-r<d>, M-il-r<d>, M-it-r<d>, M-g-r<d>, ",
          "M-g25-r<d>, M-g75-r<d>, M-g0-r<d>, M-gc-r<d>, M-gc25-r<d>, M-gc75-r<d>, M-h-g-r<d>, M-a<T>-r<d>, O-f or O-l, not $(MULTIQ_VARIANT)")
_F_MATCH === nothing || _F_MATCH[2] === nothing || _F_MATCH[2] in ("f", "l") || _F_MATCH[1] != "O" ||
    error("the shares (-t, -t0, -p<K>) are built for M and M-h, not O")
# D's slot budget, or nothing for every other variant.
const SLOT_BUDGET = _D_MATCH === nothing ? nothing :
                    _D_MATCH[1] == "-inf" ? typemax(Int) : parse(Int, _D_MATCH[1])
# E's pop budget (every K-th successful pop is periodic), or nothing for every other variant.
const PERIODIC_K = _E_MATCH === nothing ? nothing :
                   _E_MATCH[1] == "-inf" ? typemax(Int) : parse(Int, _E_MATCH[1])
PERIODIC_K === nothing || PERIODIC_K >= 2 || error("E's K must be at least 2")
# M and O: stock's heaps plus one FIFO queue for the `:default` pool. FIFO_CLASS says who goes
# there (`:mark`: the tasks the harness marks; `:origin`: a task first enqueued from another pool),
# FIFO_SERVE which a pop looks at first (`:f` the queue, `:l` the heaps; M-none runs `:f`, the rule
# that reads the queue on every pop). The marks are the harness's: M marks handlers and clients,
# M-h handlers only, M-none and O nothing.
const MULTIQ_FIFO = _F_MATCH !== nothing
const FIFO_CLASS = !MULTIQ_FIFO ? :none : startswith(MULTIQ_VARIANT, "O") ? :origin : :mark
const _F_RULE = !MULTIQ_FIFO || MULTIQ_VARIANT == "M-none" ? "" : String(_F_MATCH[2])
const FIFO_SERVE = !MULTIQ_FIFO ? :none : MULTIQ_VARIANT == "M-none" ? :f :
                   startswith(_F_RULE, "p") ? :p : startswith(_F_RULE, "a") ? :a :
                   _F_RULE == "il" ? :l : _F_RULE == "it" ? :t : _F_RULE in ("g", "g25", "g75", "gc", "gc25", "gc75") ? :g :
                   Symbol(_F_RULE)
# -gc (#618, the `8,0` diagnostic): -g with the clock read at every pop, each interval credited to
# the side of the task that ran in it, and only when that task was popped while both sides had work.
# -g reads the clock only at a two-sided pop and credits the whole interval since the previous one
# to the side of the LAST pop, so a request task's run followed by a short one-sided L pop is
# charged to L (measured: the request side credited 0.4% of the time it ran 100% of, at `8,0`).
# M-gc25-r<d> and M-gc75-r<d> (#618, agent-config #82 Idea 8): -gc at w = 1/4 and 3/4, -g's weights.
const GROUP_CLOCK = _F_RULE in ("gc", "gc25", "gc75")
# The classes (agent-config #82 Idea 5): who a descendant becomes. `:i` F (into the rings), `:g` R
# (into the R heaps); `:none` no inheritance (every variant before them).
const FIFO_INHERIT = _F_RULE in ("il", "it") ? :i : FIFO_SERVE in (:g, :g0) ? :g : :none
const FIFO_GROUP = FIFO_INHERIT === :g
# -g's weight for the request side, in quarters (w = GROUP_W4 / 4); g0 keeps the balance at 0.
const GROUP_W4 = MULTIQ_NATIVE ? (w = get(ENV, "JULIA_SCHED_FAIR_WEIGHT", "1/2");
                                  w == "1/4" ? 1 : w == "3/4" ? 3 : w == "1/2" ? 2 : error("JULIA_SCHED_FAIR_WEIGHT=$w")) :
                 _F_RULE in ("g25", "gc25") ? 1 : _F_RULE in ("g75", "gc75") ? 3 : 2
# M-a<T>: the age, in ms, past which the older sampled ring head goes before the heaps.
const AGE_MS = FIFO_SERVE === :a ? parse(Int, _F_RULE[2:end]) : 0
# The shares (run of 2026-11-16): both act only when a pop finds the F queue non-empty, and keep
# M's heaps-first default. `:t` serves the side with less time (per-thread balance, capped);
# `:t0` is its negative control, the same code with the balance never moved (so always heaps
# first, as M-l); `:p` takes the F queue first on every SHARE_K-th such pop.
const FIFO_SHARE = FIFO_SERVE in (:t, :t0, :p)
# -g's accounts are the shares' (per-thread sstate, the same clock and cap), on its own pop.
const FIFO_ACCOUNTS = FIFO_SHARE || FIFO_GROUP
const SHARE_K = FIFO_SERVE === :p ? parse(Int, _F_MATCH[2][2:end]) : 0
FIFO_SERVE !== :p || SHARE_K >= 2 || error("M-p<K> needs K >= 2")
# The rings (run of 2026-11-16, agent-config #82 Idea 4): the F queue split into one ring beside
# each of stock's heaps, each with its own lock, an insert into a random ring with a cycle-counter
# stamp, and a pop that samples RINGS_D rings and takes the older head. Built on -l only (the serve
# rule the share run left standing): M-l-r<d> and M-h-l-r<d>.
const RINGS_D = MULTIQ_FIFO && MULTIQ_VARIANT != "M-none" && _F_MATCH[3] !== nothing ? parse(Int, _F_MATCH[3]) : 0
const FIFO_RINGS = RINGS_D > 0
# M-l-r<d>o: an insert goes to one of the inserting thread's own two rings.
const RING_OWN = FIFO_RINGS && _F_MATCH[4] == "o"
FIFO_RINGS && !(FIFO_SERVE in (:l, :t, :t0, :g, :g0, :a) && _F_MATCH[1] in ("M", "M-h")) &&
    error("the rings are built for M and M-h with -l, -t, -t0, -i, -g and -a, not $(MULTIQ_VARIANT)")
RING_OWN && !(FIFO_SERVE === :l && FIFO_INHERIT === :none) && error("the own-ring insert is built for M-l-r<d>o only")
(FIFO_INHERIT !== :none || FIFO_SERVE === :a) && !FIFO_RINGS &&
    error("the classes and the age rule are built on the rings: $(MULTIQ_VARIANT)-r2")
const MARK_HANDLERS = MULTIQ_FIFO && _F_MATCH[1] in ("M", "M-h") && !(MULTIQ_VARIANT in ("N-none", "N-arm"))
const MARK_CLIENTS = MULTIQ_FIFO && _F_MATCH[1] == "M" && !(MULTIQ_VARIANT in ("N-none", "N-arm"))
# Optional, nested.jl only: every spawn marked (the cost of marking fine-grained fork-join).
const MARK_ALL = FIFO_CLASS === :mark && get(ENV, "MARK_ALL", "0") == "1"
# C's heaps: C, and D behind its slots.
const MULTIQ_SEQ_HEAPS = MULTIQ_VARIANT == "C" || SLOT_BUDGET !== nothing
const MULTIQ_VALIDATE = get(ENV, "VALIDATE", "0") == "1"
# M_NOCLOCK=1 (VALIDATE, -g only; #618, agent-config #82 Idea 8): the start-up probes of
# `multiq_check_empty` are skipped, because `_r_probe` sets the pool flag, and `multiq_noclock_check`
# then asserts that a cell in which nothing is marked left the flag unset and made no -g pop. With the
# flag unset -g's pop is stock's and reads no clock (the clock is read only in `_GROUP_POP`, reached
# with the flag set, and in the rings' insert, which takes a marked task): M-none's path.
const MULTIQ_NOCLOCK = MULTIQ_VALIDATE && get(ENV, "M_NOCLOCK", "0") == "1"
MULTIQ_NOCLOCK && !FIFO_GROUP && error("M_NOCLOCK=1 checks the -g variants only, not $(MULTIQ_VARIANT)")

# `Base._crc32c` of the `base/partr.jl` C was copied from.
# 1.13.4's partr.jl is byte-identical to 1.13.2's (and 1.13.3's): the same crc, checked when the
# entry was added.
const PARTR_CRC = Dict(v"1.12.7" => 0xe7c9e7fd, v"1.13.2" => 0xa74d567b, v"1.13.4" => 0xa74d567b,
                       v"1.14.0-DEV.3725" => 0xae19d8ec)
const PARTR_FILE = let base = joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia", "base")
    isfile(joinpath(base, "partr.jl")) ? joinpath(base, "partr.jl") : joinpath(base, "scheduler", "partr.jl")
end

# The build's partr module, the scheduler backend it runs and the label its TSV rows carry.
const PARTR = isdefined(Base, :Partr) ? Base.Partr : Base.Scheduler.Partr
# A native build without its validation (the PR candidate) has neither the switch nor the queue-depth
# probes: read them through these, which fall back to the rings' and the R heaps' own counts.
const PARTR_VALIDATE = isdefined(PARTR, :SCHED_VALIDATE) && PARTR.SCHED_VALIDATE
partr_f_queued() = isdefined(PARTR, :f_queued) ? PARTR.f_queued() :
    sum((@atomic :monotonic q.n for q in PARTR.rings[PARTR.f_tpid + 1]); init = 0)
partr_r_queued() = isdefined(PARTR, :r_queued) ? PARTR.r_queued() :
    sum((@atomic :monotonic h.ntasks for h in PARTR.r_heaps[PARTR.f_tpid + 1]); init = 0)
const MULTIQ_BACKEND = !isdefined(Base, :Scheduler) ? :partr :
    Base.Scheduler.ChosenScheduler === PARTR ? :partr :
    Symbol(lowercase(String(nameof(Base.Scheduler.ChosenScheduler))))
const MULTIQ_BUILD = Base.GIT_VERSION_INFO.commit_short *
    (isdefined(Base, :Scheduler) ? "/" * String(MULTIQ_BACKEND) : "") *
    (NATIVE_BUILD ? (PARTR_VALIDATE ? "/native-validate" : "/native") :
     isempty(Base.TAGGED_RELEASE_BANNER) ? "/local" : "")   # a source build: the control shares the official binary's commit
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

if MULTIQ_NATIVE
    const _M_NEGATIVE = MULTIQ_VALIDATE ? get(ENV, "M_NEGATIVE", "") : ""
    _M_NEGATIVE in ("", "blind", "stall", "rblind") || error("M_NEGATIVE must be blind, stall or rblind")
    MULTIQ_VALIDATE && !PARTR_VALIDATE &&
        error("VALIDATE=1 under VARIANT=$(MULTIQ_VARIANT) needs the native mark's validation build (Base.Partr.SCHED_VALIDATE = true)")
    # The build reads its negative control once, at its init.
    _M_NEGATIVE == "" || (ENV["JULIA_SCHED_NEGATIVE"] = _M_NEGATIVE)
    # The one-time init: the weight and the clock's 10 ms calibration, here at load, so it falls
    # outside every timed window (a mark would call it on the first marked spawn). It marks nothing:
    # under N-none the pool flag stays unset.
    PARTR.fair_init!()
    (@atomic PARTR.fp.w4) == GROUP_W4 || error("the build's weight is $(@atomic PARTR.fp.w4)/4, the harness's $(GROUP_W4)/4")
    const SHARE_CAP = @atomic PARTR.fp.cap
    const SHARE_CYCLES_PER_MS = SHARE_CAP / 10
    # N-arm (#618, agent-config #82 Idea 17 session 2, part E1): nothing marked, as N-none, but one
    # marked task is spawned on `:default` and finished here, at load, so the pool flag is armed for
    # the whole run: what a program that marked one task pays for its unmarked work from then on.
    if MULTIQ_VARIANT == "N-arm"
        let t = Task(() -> nothing)
            t.sticky = false
            Threads._spawn_set_thrpool(t, :default)
            Threads._spawn_set_fair(t, true)
            schedule(t)
            wait(t)
        end
        (@atomic :acquire PARTR.fl.on) || error("VARIANT=N-arm: the pool flag is not set after a marked task ran")
    end
end
if MULTIQ_FIFO && !MULTIQ_NATIVE
    # M and O. Stock's three entry points are the build's own, parsed from its partr.jl the way A0
    # takes `multiq_sift_down`, renamed `stock_multiq_*`; the public names become wrappers that send
    # a class-F task to one FIFO queue for the `:default` pool and everything else down stock's path.
    function _renamed_partr_function(name::Symbol, new::Symbol)
        block = _partr_function(name)
        sig = block.args[2].args[1]
        while sig.head in (:where, :(::))
            sig = sig.args[1]
        end
        sig.args[1] === name || error("could not rename $name")
        sig.args[1] = new
        return block
    end
    for name in (:multiq_insert, :multiq_deletemin, :multiq_check_empty)
        Core.eval(PARTR, _renamed_partr_function(name, Symbol(:stock_, name)))
    end
    # VALIDATE only: stock's pop behind a check. This file never lets a class bit into stock's heaps
    # (`stock_multiq_insert` is always given a priority with the bits cleared, and it writes that
    # priority to the task), so a task they give out with a bit set was put there by the build's own
    # `multiq_insert`: a thread whose world predates the patch. `stock_bit` counts them.
    if MULTIQ_VALIDATE
        Core.eval(PARTR, _renamed_partr_function(:multiq_deletemin, :stock_multiq_deletemin_raw))
        Core.eval(PARTR, quote
            function stock_multiq_deletemin()
                task = stock_multiq_deletemin_raw()
                task === nothing || task.priority & C_BITS == 0 || (fstates[f_slot()].stock_bit += 1)
                return task
            end
        end)
    end
    # -g: the R heaps, a second set of stock heaps. The build's own `multiq_size`, `multiq_insert`,
    # `multiq_deletemin` and `multiq_check_empty`, every reference to `heaps`, `heaps_lock` and the
    # four names renamed (`r_heaps`, `r_heaps_lock`, `r_multiq_*`): stock's insert, two-choice pop,
    # sticky retry and sifts over heaps of their own.
    if FIFO_GROUP
        _R_SUBS = Dict(:heaps => :r_heaps, :heaps_lock => :r_heaps_lock, :multiq_size => :r_multiq_size,
                       :multiq_insert => :r_multiq_insert, :multiq_deletemin => :r_multiq_deletemin,
                       :multiq_check_empty => :r_multiq_check_empty)
        _rsubst(x) = x isa Symbol ? get(_R_SUBS, x, x) :
                     x isa Expr ? Expr(x.head, map(_rsubst, x.args)...) : x
        Core.eval(PARTR, :(const r_heaps = [Vector{taskheap}(undef, 0), Vector{taskheap}(undef, 0)]))
        Core.eval(PARTR, :(const r_heaps_lock = [SpinLock(), SpinLock()]))
        for name in (:multiq_size, :multiq_insert, :multiq_deletemin, :multiq_check_empty)
            Core.eval(PARTR, _rsubst(_partr_function(name)))
        end
    end
    # VALIDATE only, two negative controls. `blind` is a `multiq_check_empty` that ignores the F
    # queue (a thread could sleep with a task queued there): the second check_empty probe must fail.
    # `stall` queues an F task pinned to a thread that then never pops (`_f_stall_control`): the
    # stall check in `f_pop!` must fire.
    const _M_NEGATIVE = MULTIQ_VALIDATE ? get(ENV, "M_NEGATIVE", "") : ""
    _M_NEGATIVE in ("", "blind", "stall", "rblind") || error("M_NEGATIVE must be blind, stall or rblind")
    _fcount(field) = MULTIQ_VALIDATE ? :(fstates[f_slot()].$field += 1) : nothing
    if FIFO_SHARE || FIFO_RINGS
        # The shares' clock (and the rings' stamps): rdtsc, as E's stamps. It is only ever differenced on one thread, pop to
        # pop, but a thread can move between cores, so it needs the TSC Linux trusts as its
        # clocksource (constant, nonstop, synchronized across cores).
        let cs = "/sys/devices/system/clocksource/clocksource0/current_clocksource"
            isfile(cs) && strip(read(cs, String)) == "tsc" ||
                error("the shares time pops with rdtsc, which needs the TSC as the clocksource")
        end
        @eval PARTR @inline s_stamp() = Base.llvmcall(("""
            declare i64 @llvm.readcyclecounter()
            define i64 @s_stamp() #0 {
              %t = call i64 @llvm.readcyclecounter()
              ret i64 %t
            }
            attributes #0 = { alwaysinline }
            """, "s_stamp"), UInt64, Tuple{})
        # Cycles per millisecond, against the monotonic clock over 50 ms at load.
        const SHARE_CYCLES_PER_MS = let t0 = time_ns(), c0 = PARTR.s_stamp()
            while time_ns() - t0 < 50_000_000
            end
            c1, t1 = PARTR.s_stamp(), time_ns()
            (c1 - c0) / ((t1 - t0) / 1e6)
        end
        # The cap on the balance (and on any one interval credited): 10 ms.
        const SHARE_CAP = round(Int, 10 * SHARE_CYCLES_PER_MS)
    end
    _scount(field, by = 1) = MULTIQ_VALIDATE ? :(s.$field += $by) : nothing
    # The shares' pop, reached only when the F queue is non-empty, so both sides may have work.
    # -t and -t0 read the clock and credit the interval since this thread's last accounted pop to
    # the side of the task that pop returned (none when it returned nothing: the thread was idle);
    # -t moves the balance by it, -t0 does not (its balance stays 0, so it is always heaps first,
    # the negative control). The side tried first: -t, F when F has had less time (bal < 0), ties
    # to the heaps; -p, F on every K-th successful accounted pop. The other side is the fallback
    # when the first comes back empty. Under VALIDATE every share reads the clock, for the counts.
    _SHARE_CLOCK = FIFO_SERVE in (:t, :t0) || MULTIQ_VALIDATE
    _SHARE_POP = !FIFO_SHARE ? nothing : quote
        s = sstates[tid]
        $(_SHARE_CLOCK ? quote
            now = s_stamp()
            if s.last != 0
                d = now > s.stamp ? Int(now - s.stamp) : 0
                if d > $(SHARE_CAP)
                    d = $(SHARE_CAP)
                    $(_scount(:clips))
                end
                $(FIFO_SERVE === :t ? quote
                    b = s.last == 1 ? s.bal + d : s.bal - d
                    if b > $(SHARE_CAP)
                        b = $(SHARE_CAP)
                        $(_scount(:caps))
                    elseif b < $(-SHARE_CAP)
                        b = $(-SHARE_CAP)
                        $(_scount(:caps))
                    end
                    s.bal = b
                end : nothing)
                $(MULTIQ_VALIDATE ? quote
                    if s.last == 1
                        s.f_cyc += d
                        stock_multiq_check_empty() || (s.both_f += d)
                    else
                        s.l_cyc += d
                        stock_multiq_check_empty() || (s.both_l += d)
                    end
                end : nothing)
            end
        end : nothing)
        ffirst = $(FIFO_SERVE === :p ? :(s.k >= $(SHARE_K - 1)) : :(s.bal < 0))
        nt = Int(Threads._nthreads_in_pool(tpid))
        side = 1
        if ffirst
            task = $(FIFO_RINGS ? :(r_pop!(tid, nt)) : :(f_pop!(fq, tid, nt)))
            if task === nothing
                task = stock_multiq_deletemin()
                side = 2
            end
        else
            task = stock_multiq_deletemin()
            side = 2
            if task === nothing
                side = 1
                $(FIFO_RINGS ? :(task = r_pop!(tid, nt)) :
                  :((@atomic :monotonic fq.n) == 0 || (task = f_pop!(fq, tid, nt))))
            end
        end
        $(MULTIQ_VALIDATE ? quote
            s.acct += 1
            ffirst && (s.f_choice += 1)
            side == 2 && task !== nothing && $(_fcount(:l_pops))
        end : nothing)
        $(_SHARE_CLOCK ? quote
            s.stamp = now
            s.last = task === nothing ? 0 : side
        end : nothing)
        $(FIFO_SERVE === :p ? :(task === nothing || (s.k = ffirst ? 0 : s.k + 1)) : nothing)
    end
    # -g's pop, reached only with the pool flag set. A probe of the three structures (racy reads of
    # their counts, as stock reads its heaps): L's heaps (`lw`), the R heaps (`rr`), the rings
    # (`rf`). One side with work: pop it, no clock, and record the side (`s.last`, the thread's own
    # line) so that the next two-sided pop credits a one-sided stretch to the side that ran it. Both
    # sides: M-t's crediting (the interval since the last clock read, capped, to `s.last`'s side),
    # with weight GROUP_W4/4 for the request side (side 1): its intervals add d * (4 - W), L's
    # subtract d * W, and the request side goes first while the balance is negative; g0 never moves
    # it. The request side is the R heaps, then the rings: started work before a new root.
    _GROUP_CAP = FIFO_GROUP ? 2 * SHARE_CAP : 0
    # VALIDATE only (#618, the `8,0` diagnostic): after a stock pop that came back empty, re-probe
    # stock's heaps; non-empty means the two-choice sample missed a queued task (or another thread
    # took it in between: the count is an upper bound on the misses).
    _G_LMISS = MULTIQ_VALIDATE ? :(task === nothing && !stock_multiq_check_empty() && (lmiss = true)) : nothing
    # VALIDATE only: the pop's shape, the misses, the time actually run on each side (a clock read
    # at EVERY -g pop, credited to the side of the task the previous pop returned, and separately
    # when that pop had found both sides with work), and the queues' depth every 64th pop.
    _G_COUNT = !MULTIQ_VALIDATE ? nothing : quote
        let two = lw && (rr || rf)
            if two
                g.two += 1
            elseif rr || rf
                g.one_r += 1
            elseif lw
                g.one_l += 1
            else
                g.none += 1
            end
            if lmiss
                g.l_miss += 1
                if task === nothing
                    g.l_miss_none += 1
                elseif side == 1
                    g.l_miss_r += 1
                end
            end
            vnow = s_stamp()
            if g.vlast != 0
                dd = vnow > g.vstamp ? Int(vnow - g.vstamp) : 0
                if g.vlast == 1
                    g.run_r += dd
                    g.vtwo != 0 && (g.run_r2 += dd)
                else
                    g.run_l += dd
                    g.vtwo != 0 && (g.run_l2 += dd)
                end
            end
            g.vstamp = vnow
            g.vlast = task === nothing ? 0 : side
            g.vtwo = two ? 1 : 0
            g.k += 1
            if g.k & 63 == 0
                g.nsamp += 1
                dl = 0
                for h in heaps[f_tpid + 1]
                    dl += Int(@atomic :monotonic h.ntasks)
                end
                dq = f_queued()
                dh = r_queued()
                g.dl_sum += dl; dl > g.dl_peak && (g.dl_peak = dl)
                g.dq_sum += dq; dq > g.dq_peak && (g.dq_peak = dq)
                g.dh_sum += dh; dh > g.dh_peak && (g.dh_peak = dh)
            end
        end
    end
    # -g's credit of an interval `d` (cycles) to `s.last`'s side: the balance (g, g25, g75, gc; g0
    # never moves it) and, under VALIDATE, the time credited while both sides had work.
    _G_CREDIT = quote
        $(FIFO_SERVE === :g ? quote
            b = s.last == 1 ? s.bal + d * $(4 - GROUP_W4) : s.bal - d * $(GROUP_W4)
            if b > $(_GROUP_CAP)
                b = $(_GROUP_CAP)
                $(_scount(:caps))
            elseif b < $(-_GROUP_CAP)
                b = $(-_GROUP_CAP)
                $(_scount(:caps))
            end
            s.bal = b
        end : nothing)
        $(MULTIQ_VALIDATE ? quote
            if s.last == 1
                s.f_cyc += d
                s.both_f += d
            else
                s.l_cyc += d
                s.both_l += d
            end
        end : nothing)
    end
    _GROUP_POP = !FIFO_GROUP ? nothing : quote
        s = sstates[tid]
        $(MULTIQ_VALIDATE ? :(g = gstates[tid]; lmiss = false) : nothing)
        nt = Int(Threads._nthreads_in_pool(tpid))
        lw = !stock_multiq_check_empty()
        rr = !r_multiq_check_empty()
        rf = r_any()
        side = 0
        $(GROUP_CLOCK ? quote
            # -gc: the clock at every pop. The interval since this thread's previous pop is the run
            # of the task that pop returned (`s.last`'s side); it is credited only when that pop
            # found both sides with work (`s.k`), so a task run while the other side was empty is
            # not charged against it. The credit itself is -g's.
            now = s_stamp()
            if s.last != 0 && s.k != 0
                d = now > s.stamp ? Int(now - s.stamp) : 0
                if d > $(SHARE_CAP)
                    d = $(SHARE_CAP)
                    $(_scount(:clips))
                end
                $_G_CREDIT
            end
            s.stamp = now
            s.k = lw && (rr || rf) ? 1 : 0
        end : nothing)
        if lw && (rr || rf)
            $(GROUP_CLOCK ? nothing : quote
                now = s_stamp()
                if s.last != 0
                    d = now > s.stamp ? Int(now - s.stamp) : 0
                    if d > $(SHARE_CAP)
                        d = $(SHARE_CAP)
                        $(_scount(:clips))
                    end
                    $_G_CREDIT
                end
            end)
            rfirst = s.bal < 0
            if rfirst
                task = g_req_pop(rr, rf, tid, nt)
                side = 1
                if task === nothing
                    task = stock_multiq_deletemin()
                    side = 2
                    $_G_LMISS
                end
            else
                task = stock_multiq_deletemin()
                side = 2
                $_G_LMISS
                if task === nothing
                    task = g_req_pop(true, true, tid, nt)
                    side = 1
                end
            end
            $(MULTIQ_VALIDATE ? quote
                s.acct += 1
                rfirst && (s.f_choice += 1)
            end : nothing)
            $(GROUP_CLOCK ? nothing : :(s.stamp = now))
        elseif rr || rf
            task = g_req_pop(rr, rf, tid, nt)
            side = 1
            if task === nothing
                task = stock_multiq_deletemin()
                side = 2
                $_G_LMISS
            end
        elseif lw
            task = stock_multiq_deletemin()
            side = 2
            $_G_LMISS
        else
            task = nothing
        end
        $(MULTIQ_VALIDATE ? :(side == 2 && task !== nothing && $(_fcount(:l_pops))) : nothing)
        $_G_COUNT
        s.last = task === nothing ? 0 : side
    end
    # M-a<T>: the heaps first unless the older of the d sampled ring heads has waited past T ms.
    _AGE_POP = FIFO_SERVE !== :a ? nothing : quote
        nt = Int(Threads._nthreads_in_pool(tpid))
        i = (@atomic :monotonic fl.on) ? r_pick() : 0
        old = i != 0 && (st = r_head(frings[i]); now = s_stamp(); now > st && now - st > $(UInt64(round(Int, AGE_MS * SHARE_CYCLES_PER_MS))))
        if old
            task = r_pop!(tid, nt)
            task === nothing && (task = stock_multiq_deletemin(); $(MULTIQ_VALIDATE ? :(task === nothing || $(_fcount(:l_pops))) : nothing))
        else
            task = stock_multiq_deletemin()
            if task === nothing
                (@atomic :monotonic fl.on) && (task = r_pop!(tid, nt))
            else
                $(_fcount(:l_pops))
            end
        end
    end
    @eval PARTR begin
        # The class: bit 15 of `Task.priority`. Nothing in Base sets a priority (a new task starts at
        # 0 and does not inherit its parent's), and a task with the bit never enters the heaps, so the
        # heaps keep seeing 0. An F-bit task that would have to take stock's path (an `:interactive`
        # pool of two or more threads; never in the layouts measured) has the bit cleared there and
        # is counted as `demoted`.
        const F_BIT = 0x8000
        # The classes: R is bit 14 (request work in flight). Both bits are stripped before a
        # priority reaches a heap (the R heaps get 0); R is written back on a task the R heaps pop.
        const R_BIT = 0x4000
        const C_BITS = F_BIT | R_BIT
        const f_inherit = $(QuoteNode(FIFO_INHERIT))
        const f_group = $(FIFO_GROUP)
        const f_class = $(QuoteNode(FIFO_CLASS))
        const f_serve = $(QuoteNode(FIFO_SERVE))
        const f_tpid = Int8(Threads._sym_to_tpid(:default))

        # One per pool that has one (only `:default`). A ring of power-of-two capacity, oldest at
        # `head`, under one spin lock; `n` is published under the lock and read without it by the
        # pops' fast path and by `multiq_check_empty`. `seqs` (VALIDATE only) is each entry's
        # insertion sequence, for the order asserts. The pad keeps the next allocation off its lines.
        # A ring (the rings) keeps `seqs` always: there it holds each entry's cycle-counter stamp, which
        # the pop's sample compares, and `next` the last stamp given, so stamps rise within a ring.
        mutable struct fqueue
            const lock::SpinLock
            tasks::Vector{Task}
            seqs::Vector{UInt64}
            head::Int
            @atomic n::Int32
            next::UInt64
            pad::NTuple{12,Int}
            fqueue(stamps::Bool = $(MULTIQ_VALIDATE)) =
                new(SpinLock(), Vector{Task}(undef, 256), Vector{UInt64}(undef, stamps ? 256 : 0),
                    1, zero(Int32), zero(UInt64), ntuple(_ -> 0, 12))
        end
        const fq = fqueue()

        # The rings: one per stock heap of the pool (heap_c = 2 per thread), so 16 at 8 threads.
        # `fl.on` is the pool flag: set once, at the first marked insert, and never cleared, on a
        # line of its own. An unmarked program reads it and nothing else (a line nobody writes); a
        # program that has marked anything samples the rings as stock samples its heaps.
        const f_rings = $(FIFO_RINGS)
        const r_d = $(RINGS_D)
        mutable struct fflag
            pad0::NTuple{8,Int}
            @atomic on::Bool
            pad1::NTuple{15,Int}
        end
        const fl = fflag(ntuple(_ -> 0, 8), false, ntuple(_ -> 0, 15))
        const frings = [fqueue(true) for _ in 1:(f_rings ? 2 * Threads._nthreads_in_pool(f_tpid) : 0)]

        # VALIDATE only: per thread, 128 bytes of counts.
        mutable struct fstate
            f_first::Int    # F inserts of a task not yet started: its first enqueue
            f_again::Int    # F inserts of a started task: a wake-up or a yield
            l_first::Int    # L inserts of a task not yet started
            demoted::Int    # F-bit tasks sent down stock's path (bit cleared)
            f_pops::Int     # tasks popped from the F queue
            l_pops::Int     # tasks popped from stock's heaps
            skips::Int      # F entries passed over because they were pinned to another thread
            own::Int        # F pops that took this thread's own task from behind the head
            retries::Int    # failed F pops in a row with no pop by the head's owner (the stall check)
            seen::Int       # the head's owner's pops when that run began
            acq::Int        # F-queue lock acquisitions made by this thread (inserts and pops)
            held::Int       # of those, the ones that found the lock held (a failed trylock first)
            desc::Int       # the classes: tasks classified as descendants at their first enqueue
            r_first::Int    # -g: R-heap inserts of a task not yet started (a descendant)
            r_again::Int    # -g: R-heap inserts of a started task (a wake-up or a yield, roots too)
            r_pops::Int     # -g: tasks popped from the R heaps
            r_peak::Int     # -g: the most tasks this thread saw in the R heaps after one of its inserts
            foreign::Int    # inserts made by a thread outside the pools (a foreign thread: in a server, Reseau's poller)
            stock_bit::Int  # tasks stock's heaps gave a pop with a class bit set: an insert by stock's
                            #   own code (a thread still in the world before the patch), never this file's
            pad::NTuple{13,Int}
            fstate() = new(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, ntuple(_ -> 0, 13))
        end
        # One slot per thread that existed when this file loaded, plus one overflow slot for every
        # thread adopted later: a foreign thread that enters Julia after the patch (Reseau's poller,
        # which wakes the socket waiters of an HTTP.jl server, is one) gets a tid past the pools, and
        # an insert it makes would otherwise index past the end. Validation only, like every count
        # here; the timed code indexes nothing by tid on the insert side.
        const f_nslots = Int(Threads.maxthreadid())
        const fstates = [fstate() for _ in 1:(f_nslots + 1)]
        @inline f_slot() = (t = Int(Threads.threadid()); t <= f_nslots ? t : f_nslots + 1)

        # The shares, per thread, 128 bytes, touched only by a pop that found the F queue non-empty
        # (an unmarked program never reaches them). The timed code uses the first four fields; the
        # rest are VALIDATE counts.
        mutable struct sstate
            bal::Int        # -t: cycles spent on F tasks minus cycles on L tasks, kept in [-cap, cap]
            stamp::UInt64   # -t, -t0: the cycle counter at this thread's last accounted pop
            last::Int       # -t, -t0: the side of the task that pop returned: 0 none, 1 F, 2 L
            k::Int          # -p: successful accounted pops since the last one that tried F first
            f_cyc::Int      # cycles credited to F (VALIDATE: every share variant times its pops)
            l_cyc::Int      # cycles credited to L
            both_f::Int     # the same two, only for intervals ending at a pop that found the heaps
            both_l::Int     #   non-empty too: "while both sides have work"
            caps::Int       # credits after which the balance was clamped to the cap
            clips::Int      # intervals longer than the cap, credited as the cap
            acct::Int       # accounted pops (the F queue non-empty)
            f_choice::Int   # accounted pops that tried the F queue first
            pad::NTuple{4,Int}
            sstate() = new(0, zero(UInt64), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, ntuple(_ -> 0, 4))
        end
        const sstates = [sstate() for _ in 1:Threads.maxthreadid()]

        # -g, VALIDATE only (#618, the `8,0` diagnostic), per thread, 256 bytes: what -g's pop saw
        # and where the time went, independent of the share's own accounts (which read the clock
        # only at a pop that finds both sides with work).
        mutable struct gstate
            two::Int        # pops that found both sides with work (L heaps and R heaps or rings)
            one_r::Int      # pops that found only the request side with work
            one_l::Int      # pops that found only L with work
            none::Int       # pops that found nothing
            l_miss::Int     # stock pops that came back empty while the re-probe saw a task in L's heaps
            l_miss_r::Int   #   of those, the pop then returned a request-side task
            l_miss_none::Int #  of those, the pop returned nothing
            vstamp::UInt64  # the cycle counter at this thread's last -g pop
            vlast::Int      # the side of the task that pop returned: 0 none, 1 request, 2 L
            vtwo::Int       # 1 when that pop found both sides with work
            run_r::Int      # cycles from a pop that returned a request-side task to the next pop
            run_l::Int      # the same for an L task
            run_r2::Int     # the same two, only for intervals starting at a two-sided pop
            run_l2::Int
            k::Int          # pops seen (the depth sampler's stride)
            nsamp::Int      # depth samples taken
            dl_sum::Int     # L heaps' depth (tasks in stock's `:default` heaps), sum and peak
            dl_peak::Int
            dq_sum::Int     # the rings' depth
            dq_peak::Int
            dh_sum::Int     # the R heaps' depth
            dh_peak::Int
            pad::NTuple{10,Int}
            gstate() = new(0, 0, 0, 0, 0, 0, 0, zero(UInt64), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                           ntuple(_ -> 0, 10))
        end
        const gstates = [gstate() for _ in 1:Threads.maxthreadid()]

        @noinline function f_fail(msg::String)
            ccall(:jl_safe_printf, Cvoid, (Cstring, Cstring), "%s\n", msg)
            ccall(:abort, Cvoid, ())
        end

        # Every F-queue lock goes through here. Under VALIDATE it counts the acquisition and, with a
        # trylock first, whether the lock was found held: the contention measure of the 2026-11-16
        # rings run. Timed runs take the plain lock.
        @inline function f_lock!(q::fqueue)
            $(MULTIQ_VALIDATE ? quote
                s = fstates[f_slot()]
                s.acq += 1
                if !trylock(q.lock)
                    s.held += 1
                    lock(q.lock)
                end
            end : :(lock(q.lock)))
            return nothing
        end

        @inline f_idx(q::fqueue, k::Int) = ((q.head - 1 + k - 1) & (length(q.tasks) - 1)) + 1

        function f_grow!(q::fqueue)
            cap = length(q.tasks)
            n = Int(q.n)
            tasks = Vector{Task}(undef, 2 * cap)
            seqs = Vector{UInt64}(undef, isempty(q.seqs) ? 0 : 2 * cap)
            for k in 1:n
                i = f_idx(q, k)
                tasks[k] = q.tasks[i]
                isempty(seqs) || (seqs[k] = q.seqs[i])
            end
            q.tasks = tasks
            q.seqs = seqs
            q.head = 1
            return nothing
        end

        # At the tail, under the lock.
        @inline function f_push!(q::fqueue, task::Task)
            n = Int(q.n)
            n == length(q.tasks) && f_grow!(q)
            i = f_idx(q, n + 1)
            q.tasks[i] = task
            if !isempty(q.seqs)
                q.seqs[i] = q.next
                q.next += UInt64(1)
            end
            @atomic :monotonic q.n = Int32(n + 1)
            return nothing
        end

        # The rings' insert, at the tail under the lock: the stamp is read inside the lock and kept
        # above the ring's last one, so stamps rise strictly within a ring (the order assert holds).
        @inline function f_push_stamped!(q::fqueue, task::Task)
            n = Int(q.n)
            n == length(q.tasks) && f_grow!(q)
            i = f_idx(q, n + 1)
            q.tasks[i] = task
            st = s_stamp()
            st > q.next || (st = q.next + UInt64(1))
            q.seqs[i] = st
            q.next = st
            @atomic :monotonic q.n = Int32(n + 1)
            return nothing
        end

        # The rings' sample: the stamp of a ring's head, read without the lock (a racy hint, as
        # stock reads a heap's priority), typemax when the ring looks empty.
        @inline function r_head(q::fqueue)
            (@atomic :monotonic q.n) == 0 && return typemax(UInt64)
            st, h = q.seqs, q.head
            return 1 <= h <= length(st) ? @inbounds(st[h]) : typemax(UInt64) - UInt64(1)
        end

        # The index of the ring with the older head among r_d sampled, 0 when all looked empty.
        @inline function r_pick()
            nr = UInt32(length(frings))
            best, bst = 0, typemax(UInt64)
            for _ in 1:r_d
                i = Int(cong(nr))
                st = r_head(frings[i])
                if st < bst
                    best, bst = i, st
                end
            end
            return best
        end

        # The rings' pop: up to four samples, each followed by M's F pop on the ring it picked (the
        # sticky-retry scan and the stall check, per ring); then one pass over every ring from a
        # random one, so a task alone in a ring no sample hit is still reached. `nothing` when all
        # of that found nothing this thread may run: `jl_task_get_next` then spins on
        # `multiq_check_empty`, which reads every ring.
        function r_pop!(tid::Int, nt::Int)
            for _ in 1:4
                i = r_pick()
                i == 0 && continue
                task = f_pop!(frings[i], tid, nt)
                task === nothing || return task
            end
            nr = length(frings)
            i0 = Int(cong(UInt32(nr)))
            for j in 0:nr-1
                q = frings[(i0 - 1 + j) % nr + 1]
                (@atomic :monotonic q.n) == 0 && continue
                task = f_pop!(q, tid, nt)
                task === nothing || return task
            end
            return nothing
        end

        # F tasks queued, all queues (the harness's view; racy).
        function f_queued()
            f_rings || return Int(@atomic :monotonic fq.n)
            n = 0
            for q in frings
                n += @atomic :monotonic q.n
            end
            return n
        end

        # Some ring non-empty (racy counts, as `multiq_check_empty` reads them): the gate of M-t on
        # the rings and one leg of -g's probe. Only reached with the pool flag set.
        @inline function r_any()
            for q in frings
                (@atomic :monotonic q.n) == 0 || return true
            end
            return false
        end

        # -g: the request side's pop, the R heaps (when `rr` says they have work) and then the rings
        # (when `rf` says so). A task the R heaps pop gets its R bit back: it is out of the heap
        # and this thread's from here, and its class is what its children and its next wake read.
        @inline function g_req_pop(rr::Bool, rf::Bool, tid::Int, nt::Int)
            $(FIFO_GROUP ? quote
                if rr
                    t = r_multiq_deletemin()
                    if t !== nothing
                        t.priority |= R_BIT
                        $(_fcount(:r_pops))
                        return t
                    end
                end
            end : nothing)
            rf && return r_pop!(tid, nt)
            return nothing
        end

        # -g: tasks queued in the R heaps of the `:default` pool (racy).
        function r_queued()
            $(FIFO_GROUP ? quote
                n = 0
                for h in r_heaps[f_tpid + 1]
                    n += @atomic :monotonic h.ntasks
                end
                return n
            end : :(return 0))
        end

        # -g, VALIDATE only: remove `t` from the R heap that holds it, under that heap's lock. Every
        # priority in the R heaps is 0, so the heap's last entry can take its place.
        function r_take_back!(t::Task)
            $(FIFO_GROUP ? quote
                for h in r_heaps[f_tpid + 1]
                    lock(h.lock)
                    n = Int(h.ntasks)
                    k = findfirst(j -> h.tasks[j] === t, 1:n)
                    if k !== nothing
                        h.tasks[k] = h.tasks[n]
                        $_UNSET(h.tasks, n)
                        @atomic :monotonic h.ntasks = Int32(n - 1)
                        n == 1 && (@atomic :monotonic h.priority = typemax(UInt16))
                    end
                    unlock(h.lock)
                    k === nothing || return true
                end
            end : nothing)
            return false
        end

        # Remove `t` from whichever F queue holds it, under that queue's lock; whether it was found.
        function f_take_back!(t::Task)
            for q in (f_rings ? frings : (fq,))
                lock(q.lock)
                k = findfirst(j -> q.tasks[f_idx(q, j)] === t, 1:Int(q.n))
                k === nothing || f_remove!(q, k)
                unlock(q.lock)
                k === nothing || return true
            end
            return false
        end

        # Remove entry k (1 = the head), under the lock: the k - 1 entries ahead of it move one
        # step toward the tail, so the others keep their order.
        @inline function f_remove!(q::fqueue, k::Int)
            for j in k:-1:2
                q.tasks[f_idx(q, j)] = q.tasks[f_idx(q, j - 1)]
                isempty(q.seqs) || (q.seqs[f_idx(q, j)] = q.seqs[f_idx(q, j - 1)])
            end
            $_UNSET(q.tasks, q.head)
            q.head = (q.head & (length(q.tasks) - 1)) + 1
            @atomic :monotonic q.n = q.n - Int32(1)
            return nothing
        end

        # VALIDATE only, after a pop under the lock: the popped entry was older than the new head
        # when it was the head, and the first entries are still in insertion order.
        @inline function f_check_order(q::fqueue, popped_seq::UInt64, k::Int)
            n = Int(q.n)
            k == 1 && n > 0 && q.seqs[q.head] <= popped_seq &&
                f_fail("F: popped seq $(popped_seq) from the head, but the new head has seq $(q.seqs[q.head])")
            for j in 2:min(n, 32)
                q.seqs[f_idx(q, j)] > q.seqs[f_idx(q, j - 1)] ||
                    f_fail("F: entries $(j - 1) and $j are out of insertion order")
            end
            return nothing
        end

        # The F pop. The sticky-retry protocol: a task re-enqueued by `notify` before its own
        # thread switched out of it keeps that thread's tid until the switch, and `jl_set_task_tid`
        # fails for every other thread. So scan from the head over at most as many entries as the
        # pool has threads (one current task each, so that bounds the entries pinned to another
        # thread), take the first one this thread may run (an unpinned task or its own), wake the
        # owner of each one passed over and leave those in place. The owner always reaches its own
        # task, nobody waits behind a pinned head, and the order of the rest is unchanged.
        # `nothing` when every scanned entry is pinned elsewhere: the caller tries the heaps, and
        # `jl_task_get_next` spins on `multiq_check_empty` as it spins on stock's `@goto retry`.
        function f_pop!(q::fqueue, tid::Int, nt::Int)
            f_lock!(q)
            n = Int(q.n)
            lim = min(n, nt)
            k = 0
            local task::Task
            wake = UInt64(0)
            for j in 1:lim
                t = q.tasks[f_idx(q, j)]
                if ccall(:jl_set_task_tid, Cint, (Any, Cint), t, tid - 1) != 0
                    k = j
                    task = t
                    break
                end
                owner = ccall(:jl_get_task_tid, Int16, (Any,), t)
                if 0 <= owner < 64
                    wake |= UInt64(1) << owner
                end
                $(_fcount(:skips))
            end
            $(MULTIQ_VALIDATE ? :(hd = k == 0 && n > 0 ? q.tasks[q.head] : nothing) : nothing)
            if k > 0
                $(MULTIQ_VALIDATE ? :(popped_seq = q.seqs[f_idx(q, k)]) : nothing)
                f_remove!(q, k)
                $(MULTIQ_VALIDATE ? :(f_check_order(q, popped_seq, k)) : nothing)
            end
            unlock(q.lock)
            while wake != 0
                owner = trailing_zeros(wake)
                ccall(:jl_wakeup_thread, Cint, (Int16,), Int16(owner))
                wake &= wake - UInt64(1)
            end
            if k == 0
                $(MULTIQ_VALIDATE ? quote
                    # A stall: every scanned entry pinned to a thread that never takes it. Not
                    # every run of failed pops is one: a task that keeps yielding (a ping-pong over
                    # an unbuffered Channel) is back at the head, pinned to its own thread, each
                    # time an idle thread looks, while its owner pops it again and again (stock's
                    # retry loop spins on it the same way). So count only while the head's owner
                    # makes no pop at all: 10^6 failed pops with no pop by the owner is a stall.
                    hd === nothing && return nothing   # the queue emptied before the lock: no verdict
                    s = fstates[tid]
                    o = Int(ccall(:jl_get_task_tid, Int16, (Any,), hd)) + 1
                    progress = o >= 1 ? fstates[o].f_pops + fstates[o].l_pops : -1
                    if s.retries == 0 || progress != s.seen
                        s.retries = 1
                        s.seen = progress
                    else
                        s.retries += 1
                    end
                    if s.retries == 1_000_000
                        h = hd
                        f_fail(string("F: 10^6 pops in a row on tid ", tid, " found only entries pinned to other ",
                            "threads, and the head's owner made no pop meanwhile; ", n, " queued; the head: owner tid ", o,
                            " (pool ", o >= 1 ? ccall(:jl_threadpoolid, Int8, (Int16,), o - 1) : -1, "), task pool ",
                            ccall(:jl_get_task_threadpoolid, Int8, (Any,), h), ", sticky ", h.sticky, ", state ", h._state,
                            ", priority ", h.priority, ", started ", ccall(:jl_is_task_started, Cint, (Any,), h),
                            ", code ", typeof(h.code)))
                    end
                end : nothing)
                return nothing
            end
            $(MULTIQ_VALIDATE ? quote
                s = fstates[tid]
                s.retries = 0
                s.f_pops += 1
                k > 1 && ccall(:jl_get_task_tid, Int16, (Any,), task) == tid - 1 && (s.own += 1)
            end : nothing)
            return task
        end

        # The own-ring insert (M-l-r<d>o): one of the inserting thread's two rings, a random one
        # from a thread of another pool.
        const f_first_tid = Int(Threads.nthreads(:interactive)) + 1
        @inline function r_insert_ring()
            $(RING_OWN ? quote
                k = Threads.threadid() - f_first_tid
                if 0 <= k && 2k + 2 <= length(frings)
                    return frings[2k + Int(cong(UInt32(2)))]
                end
            end : nothing)
            return frings[cong(UInt32(length(frings)))]
        end

        function multiq_insert(task::Task, priority::UInt16)
            $(MULTIQ_VALIDATE ? :(ccall(:jl_threadpoolid, Int8, (Int16,), Threads.threadid() - 1) == Int8(-1) && $(_fcount(:foreign))) : nothing)
            $(FIFO_INHERIT === :none ? nothing : quote
                # The classes: a task with no class of its own, at its first enqueue, made by a task of
                # class F or R, is a descendant. With the flag unset nothing past the flag is read.
                if priority & C_BITS == 0 && (@atomic :monotonic fl.on) &&
                        ccall(:jl_is_task_started, Cint, (Any,), task) == 0 &&
                        current_task().priority & C_BITS != 0 &&
                        ccall(:jl_get_task_threadpoolid, Int8, (Any,), task) == f_tpid
                    priority = $(FIFO_INHERIT === :i ? :F_BIT : :R_BIT)
                    task.priority = priority
                    $(_fcount(:desc))
                end
            end)
            $(FIFO_GROUP ? quote
                # -g: an F task that has started (a root's wake or yield) is R from here on.
                if priority & F_BIT != 0 && ccall(:jl_is_task_started, Cint, (Any,), task) != 0
                    priority = (priority & ~F_BIT) | R_BIT
                end
                if priority & R_BIT != 0
                    if ccall(:jl_get_task_threadpoolid, Int8, (Any,), task) == f_tpid
                        $(MULTIQ_VALIDATE ? quote
                            ccall(:jl_is_task_started, Cint, (Any,), task) == 0 ? $(_fcount(:r_first)) : $(_fcount(:r_again))
                        end : nothing)
                        r_multiq_insert(task, priority & ~C_BITS)
                        $(MULTIQ_VALIDATE ? quote
                            let s = fstates[f_slot()], n = r_queued()
                                n > s.r_peak && (s.r_peak = n)
                            end
                        end : nothing)
                        return true
                    end
                    $(_fcount(:demoted))
                    return stock_multiq_insert(task, priority & ~C_BITS)
                end
            end : nothing)
            if priority & F_BIT != 0
                if ccall(:jl_get_task_threadpoolid, Int8, (Any,), task) == f_tpid
                    $(MULTIQ_VALIDATE ? :(ccall(:jl_is_task_started, Cint, (Any,), task) == 0 ?
                                           $(_fcount(:f_first)) : $(_fcount(:f_again))) : nothing)
                    $(FIFO_RINGS ? quote
                        (@atomic :monotonic fl.on) || (@atomic :release fl.on = true)
                        q = r_insert_ring()
                        f_lock!(q)
                        f_push_stamped!(q, task)
                        unlock(q.lock)
                    end : quote
                        f_lock!(fq)
                        f_push!(fq, task)
                        unlock(fq.lock)
                    end)
                    return true
                end
                $(_fcount(:demoted))
                return stock_multiq_insert(task, priority & ~F_BIT)
            end
            if f_class === :origin
                tpid = ccall(:jl_get_task_threadpoolid, Int8, (Any,), task)
                if tpid == f_tpid && ccall(:jl_threadpoolid, Int8, (Int16,), Threads.threadid() - 1) != tpid &&
                        ccall(:jl_is_task_started, Cint, (Any,), task) == 0 &&
                        ccall(:jl_get_task_tid, Int16, (Any,), task) == Int16(-1)
                    task.priority = priority | F_BIT
                    $(_fcount(:f_first))
                    f_lock!(fq)
                    f_push!(fq, task)
                    unlock(fq.lock)
                    return true
                end
            end
            $(MULTIQ_VALIDATE ? :(ccall(:jl_is_task_started, Cint, (Any,), task) == 0 && $(_fcount(:l_first))) : nothing)
            return stock_multiq_insert(task, priority)
        end

        function multiq_deletemin()
            tid = Threads.threadid()
            tpid = ccall(:jl_threadpoolid, Int8, (Int16,), tid - 1)
            tpid == f_tpid || return stock_multiq_deletemin()   # a foreign thread gets nothing there
            local task::Union{Nothing,Task}
            if f_serve === :f
                task = (@atomic :monotonic fq.n) == 0 ? nothing : f_pop!(fq, tid, Int(Threads._nthreads_in_pool(tpid)))
                if task === nothing
                    task = stock_multiq_deletemin()
                    $(MULTIQ_VALIDATE ? :(task === nothing || $(_fcount(:l_pops))) : nothing)
                end
            elseif f_serve === :l
                task = stock_multiq_deletemin()
                if task === nothing
                    $(FIFO_RINGS ?
                      :((@atomic :monotonic fl.on) && (task = r_pop!(tid, Int(Threads._nthreads_in_pool(tpid))))) :
                      :((@atomic :monotonic fq.n) == 0 ||
                        (task = f_pop!(fq, tid, Int(Threads._nthreads_in_pool(tpid))))))
                else
                    $(_fcount(:l_pops))
                end
            elseif f_serve === :g || f_serve === :g0
                # -g: with the flag unset, stock's pop and nothing else.
                if !(@atomic :monotonic fl.on)
                    task = stock_multiq_deletemin()
                    $(MULTIQ_VALIDATE ? :(task === nothing || $(_fcount(:l_pops))) : nothing)
                else
                    $_GROUP_POP
                end
            elseif f_serve === :a
                $_AGE_POP
            elseif $(FIFO_RINGS ? :(!((@atomic :monotonic fl.on) && r_any())) : :((@atomic :monotonic fq.n) == 0))
                # The shares with the F queue (the rings) empty: M-none's code, no clock and no account.
                task = stock_multiq_deletemin()
                $(MULTIQ_VALIDATE ? :(task === nothing || $(_fcount(:l_pops))) : nothing)
            else
                $_SHARE_POP
            end
            $(MULTIQ_VALIDATE ? :(task === nothing || $_COUNT) : nothing)
            return task
        end

        function multiq_check_empty()
            stock_multiq_check_empty() || return false
            $(_M_NEGATIVE == "blind" ? :(return true) : nothing)
            ccall(:jl_threadpoolid, Int8, (Int16,), Threads.threadid() - 1) == f_tpid || return true
            $(FIFO_RINGS ? quote
                (@atomic :acquire fl.on) || return true
                for q in frings
                    (@atomic :monotonic q.n) == 0 || return false
                end
                # -g: the R heaps too (`M_NEGATIVE=rblind` leaves them out: its probe must fail).
                $(FIFO_GROUP && _M_NEGATIVE != "rblind" ? :(r_multiq_check_empty() || return false) : nothing)
                return true
            end : :(return (@atomic :monotonic fq.n) == 0))
        end
    end
end

# M and O: mark `t` (a task made by hand, not yet scheduled) class F. Under every other variant a
# call is an error: the harness marks only under M.
function multiq_mark!(t::Task)
    FIFO_CLASS === :mark || error("multiq_mark! under VARIANT=$(MULTIQ_VARIANT)")
    MULTIQ_NATIVE && (Threads._spawn_set_fair(t, true); return t)
    t.priority |= 0x8000
    return t
end

# A task made the way `Threads.@spawn pool f()` makes one, marked F, then scheduled.
function spawn_marked(f, pool::Symbol)
    t = Task(f)
    t.sticky = false
    Threads._spawn_set_thrpool(t, pool)
    multiq_mark!(t)
    schedule(t)
    return t
end

# The per-thread validation counts: the patch's three vectors, or the native build's one (its
# `vstate` carries every field of the three; grown to every tid here before it is read).
# The timed native build has no counters at all (they compile in only with SCHED_VALIDATE): every read
# sees zeros there, as the patch's counters read when VALIDATE is off.
const _NATIVE_COUNT_KEYS = (:f_first, :f_again, :l_first, :demoted, :f_pops, :l_pops, :skips, :own, :retries, :seen,
    :acq, :held, :desc, :r_first, :r_again, :r_pops, :r_peak, :foreign, :stock_bit, :stamps, :gpops, :two, :one_r,
    :one_l, :none, :l_miss, :l_miss_r, :l_miss_none, :vstamp, :vlast, :vtwo, :run_r, :run_l, :run_r2, :run_l2,
    :f_cyc, :l_cyc, :both_f, :both_l, :caps, :clips, :acct, :f_choice, :k, :nsamp, :dl_sum, :dl_peak, :dq_sum,
    :dq_peak, :dh_sum, :dh_peak)
_nvstates() = PARTR_VALIDATE ? (PARTR.vs(Int(Threads.maxthreadid())); PARTR.vstates[1]) :
              fill(NamedTuple{_NATIVE_COUNT_KEYS}(ntuple(_ -> 0, length(_NATIVE_COUNT_KEYS))), Int(Threads.maxthreadid()))
_fstates() = MULTIQ_NATIVE ? _nvstates() : PARTR.fstates
_sstates() = MULTIQ_NATIVE ? _nvstates() : PARTR.sstates
_gstates() = MULTIQ_NATIVE ? _nvstates() : PARTR.gstates
# The slots the patch sized at load (the native build grows them on demand: no overflow).
multiq_f_nslots() = MULTIQ_NATIVE ? Int(Threads.maxthreadid()) : PARTR.f_nslots
# A probe's dummy given a class by hand: the patch's priority bit, or the build's byte.
_set_class!(t::Task, c::Symbol) = MULTIQ_NATIVE ? PARTR.set_sched_class!(t, c === :F ? PARTR.C_F : PARTR.C_R) :
                                  (t.priority = c === :F ? PARTR.F_BIT : PARTR.R_BIT; nothing)
_ring_push!(q, t) = MULTIQ_NATIVE ? PARTR.f_push_stamped!(q, t) : PARTR.f_push!(q, t)
_new_ring() = MULTIQ_NATIVE ? PARTR.fqueue() : PARTR.fqueue(true)
_nrings() = MULTIQ_NATIVE ? length(PARTR.rings[PARTR.f_tpid + 1]) : length(PARTR.frings)

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
        MULTIQ_FIFO && tp == PARTR.f_tpid + 1 && (n += partr_f_queued() + partr_r_queued())   # M, O: the F queue (or rings), and -g's R heaps, too
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
if MULTIQ_VARIANT != "A" && !MULTIQ_NATIVE && get(ENV, "REFRESH", "1") == "1"
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
        PERIODIC_K !== nothing && !isempty(_E_NEGATIVE) ? ", NEGATIVE CONTROL $(_E_NEGATIVE)" : "",
        MULTIQ_FIFO ? ", F queue: class $(FIFO_CLASS), serve $(FIFO_SERVE)" *
                      (FIFO_RINGS ? ", $(_nrings()) rings, pop samples $(RINGS_D)" *
                                    (RING_OWN ? ", insert into the thread's own rings" : "") : "") *
                      (FIFO_INHERIT === :none ? "" : ", descendants $(FIFO_INHERIT === :i ? "F (into the rings)" : "R (into the R heaps)")") *
                      (FIFO_SERVE === :g ? ", request-side weight $(GROUP_W4)/4" : FIFO_SERVE === :g0 ? ", balance never moved (L first)" : "") *
                      (FIFO_SERVE === :a ? ", ring head first past $(AGE_MS) ms" : "") *
                      (FIFO_SERVE === :p ? " (F first every $(SHARE_K)th accounted pop)" : "") *
                      (FIFO_SERVE in (:t, :t0) ? " (cap $(round(SHARE_CAP / SHARE_CYCLES_PER_MS; digits = 2)) ms, " *
                       "$(round(SHARE_CYCLES_PER_MS / 1000; digits = 1)) MHz TSC$(FIFO_SERVE === :t0 ? ", balance frozen" : ""))" : "") *
                      ", marks " *
                      "$(MARK_HANDLERS ? "handlers" : "")$(MARK_CLIENTS ? "+clients" : "")$(MARK_ALL ? "all" : "")" *
                      "$(!MARK_HANDLERS && !MARK_ALL ? "none" : "")" : "",
        MULTIQ_FIFO && !isempty(_M_NEGATIVE) ? ", NEGATIVE CONTROL $(_M_NEGATIVE)" : "")

# Calls into the new code, per thread (validation only).
# Only the threads that existed when this file loaded have a counter (a foreign thread adopted later, such as
# Reseau's poller in a server, never reaches the counted code: the pops return first on a foreign thread).
_patch_calls() = [PARTR.variant_calls[64 * (tid - 1) + 1] for tid in 1:(length(PARTR.variant_calls) ÷ 64)]
# The native build counts the pops its new code made per thread: through the group pop (flag set)
# and stock's pop behind the flag (flag unset).
multiq_variant_calls() = !MULTIQ_NATIVE ? _patch_calls() : [v.gpops + v.l_pops for v in _nvstates()]

# End of a process: under C and E, nothing ever went into the build's own heaps, and the
# variant's are empty (under E: every live count 0 and every bucket's ring and shadow empty).
function multiq_variant_check()
    if MULTIQ_FIFO
        # M and O: stock's heaps and the F queue empty, and no F task ever sent down stock's path.
        for tp in 1:2
            n = sum((h.ntasks for h in PARTR.heaps[tp]); init = 0)
            n == 0 || error("$MULTIQ_VARIANT: $n tasks left in the heaps of pool $tp")
        end
        q = partr_f_queued()
        q == 0 || error("$MULTIQ_VARIANT: $q tasks left in the F queue")
        r = partr_r_queued()
        r == 0 || error("$MULTIQ_VARIANT: $r tasks left in the R heaps")
        if MULTIQ_VALIDATE
            c = multiq_fifo_counts()
            c.demoted == 0 || error("$MULTIQ_VARIANT: $(c.demoted) F tasks were sent down stock's path")
            println(stderr, "validate: F counts over the process: ", join(("$k $(getfield(c, k))" for k in _F_FIELDS), ", "))
        end
        return nothing
    end
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

# Fill N, then time the drain: ns per pop, on one heap with no scheduler and no contention. The
# tasks' priorities are all 0 (`:equal`, the only case Base produces), or distinct: `:increasing`
# gives task i the priority i - 1, an arrival sequence; `:random` a distinct random permutation of
# the same values (a fixed LCG, so every run drains the same heap). N must stay below
# typemax(UInt16) for the distinct cases.
function _drain_ns(n::Int, prio::Symbol = :equal)
    n < typemax(UInt16) || error("_drain_ns: n = $n does not fit a UInt16 priority")
    h, ids = _newheap(), IdDict{Task,Int}()
    prios = prio === :equal ? zeros(UInt16, n) : UInt16.(0:n - 1)
    if prio === :random
        state = UInt64(0x9e3779b97f4a7c15)
        for i in n:-1:2   # Fisher–Yates
            state = state * 0x5851f42d4c957f2d + 1
            j = Int((state >> 33) % i) + 1
            prios[i], prios[j] = prios[j], prios[i]
        end
    end
    for i in 1:n
        t = _dummy(ids, i)
        t.priority = prios[i]
        _push!(h, t)
    end
    t0 = time_ns()
    for _ in 1:n
        _pop!(h)
    end
    return (time_ns() - t0) / n
end

# The P microbench (#618, variant P: `Task.priority` as an arrival sequence): the single-heap drain
# on the build's own `taskheap`, driven by its own `multiq_sift_up`/`multiq_sift_down`, 1,000 and
# 10,000 tasks, with equal priorities, with distinct increasing ones and with distinct random ones;
# ns per pop, best of 3 after one warm-up. Prints the six numbers and returns them as a named tuple
# of (n = 1000, n = 10,000) pairs, or `nothing` when the build's heap is not what is running
# (another variant's heaps, or the work-stealing backend). The pop order is also checked: with
# distinct increasing priorities a drain of 20 must come out as 1:20 (a min-heap on priority).
function priority_drain_bench()
    MULTIQ_VARIANT in ("A", "A0") && MULTIQ_BACKEND === :partr || return nothing
    h, ids = _newheap(), IdDict{Task,Int}()
    for i in 1:20
        t = _dummy(ids, i)
        t.priority = UInt16(i - 1)
        _push!(h, t)
    end
    order = [ids[_pop!(h)] for _ in 1:20]
    order == collect(1:20) || error("priority_drain_bench: distinct increasing priorities drained as $order")
    foreach(p -> _drain_ns(1000, p), (:equal, :increasing, :random))
    best(n, p) = round(minimum(_drain_ns(n, p) for _ in 1:3); digits = 1)
    r = (equal = (best(1000, :equal), best(10_000, :equal)),
         increasing = (best(1000, :increasing), best(10_000, :increasing)),
         random = (best(1000, :random), best(10_000, :random)))
    println(stderr, "prio bench: stock taskheap drain, ns per pop (best of 3), n = 1,000 / 10,000: equal ",
            r.equal[1], " / ", r.equal[2], "; distinct increasing ", r.increasing[1], " / ", r.increasing[2],
            "; distinct random ", r.random[1], " / ", r.random[2])
    return r
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

# M and O, VALIDATE only: the counts summed over threads.
const _F_FIELDS = (:f_first, :f_again, :l_first, :demoted, :f_pops, :l_pops, :skips, :own, :acq, :held,
                   :desc, :r_first, :r_again, :r_pops, :foreign, :stock_bit)
function multiq_fifo_counts()
    MULTIQ_FIFO || return nothing
    fs = _fstates()
    return NamedTuple{_F_FIELDS}(Tuple(sum(getfield(s, k) for s in fs) for k in _F_FIELDS))
end

# M and O, VALIDATE only: print the counts since `before` and check the classification: exactly
# `f_first` tasks went to the F queue on their first enqueue (not checked when `nothing`), nothing was demoted, every F insert
# was popped and the queue is empty (the cell or workload has ended, so nothing is runnable).
#
# The classes: `f_first` is the roots; `desc` the descendants expected (not checked when
# `nothing`). Under -i a descendant is an F first insert too (f_first + desc of them); under -g it
# is an R first insert, no started task enters a ring, and every R insert was popped from the R
# heaps, which are empty. The R heaps' peak depth (per thread, after its own inserts) is printed.
function multiq_fifo_check(label, before; f_first::Union{Int,Nothing}, desc::Union{Int,Nothing} = 0)
    MULTIQ_FIFO || return nothing
    now = multiq_fifo_counts()
    d = NamedTuple{_F_FIELDS}(Tuple(getfield(now, k) - getfield(before, k) for k in _F_FIELDS))
    println(stderr, "validate: F counts, ", label, ": ", join(("$k $(getfield(d, k))" for k in _F_FIELDS), ", "),
            FIFO_GROUP ? ", R heaps peak $(maximum(s.r_peak for s in _fstates()))" : "")
    q = partr_f_queued()
    if FIFO_INHERIT === :none
        d.desc == 0 || error("$MULTIQ_VARIANT: $label: $(d.desc) descendants without inheritance")
    else
        desc === nothing || d.desc == desc || error("$MULTIQ_VARIANT: $label: $(d.desc) descendants, expected $desc")
    end
    if FIFO_INHERIT === :i
        f_first === nothing || desc === nothing || d.f_first == f_first + desc ||
            error("$MULTIQ_VARIANT: $label: $(d.f_first) F first inserts, expected $f_first roots + $desc descendants")
    else
        f_first === nothing || d.f_first == f_first || error("$MULTIQ_VARIANT: $label: $(d.f_first) tasks classified F at their first enqueue, expected $f_first")
    end
    if FIFO_GROUP
        d.f_again == 0 || error("$MULTIQ_VARIANT: $label: $(d.f_again) started tasks went into a ring")
        d.r_first == d.desc || error("$MULTIQ_VARIANT: $label: $(d.r_first) R first inserts for $(d.desc) descendants")
        r = partr_r_queued()
        r == 0 || error("$MULTIQ_VARIANT: $label: $r tasks left in the R heaps")
        d.r_pops == d.r_first + d.r_again ||
            error("$MULTIQ_VARIANT: $label: $(d.r_pops) R pops for $(d.r_first + d.r_again) R inserts")
        foreach(s -> s.r_peak = 0, _fstates())
    end
    d.demoted == 0 || error("$MULTIQ_VARIANT: $label: $(d.demoted) F tasks sent down stock's path")
    d.stock_bit == 0 || error("$MULTIQ_VARIANT: $label: stock's heaps gave out $(d.stock_bit) tasks with a class bit (an insert by the unpatched code)")
    q == 0 || error("$MULTIQ_VARIANT: $label: $q tasks left in the F queue")
    d.f_pops == d.f_first + d.f_again ||
        error("$MULTIQ_VARIANT: $label: $(d.f_pops) F pops for $(d.f_first + d.f_again) F inserts")
    return d
end

# M and O, VALIDATE only: per thread, the F-queue lock acquisitions and how many of them found the
# lock held (`f_lock!`), since `before` (a `multiq_lock_counts()`), and the F operations (inserts
# and successful pops, from the `multiq_fifo_check` difference `d`) per request of the cell.
function multiq_lock_counts()
    MULTIQ_FIFO && MULTIQ_VALIDATE || return nothing
    return [(s.acq, s.held) for s in _fstates()]
end
function multiq_lock_check(label, before, d, requests::Int)
    MULTIQ_FIFO && MULTIQ_VALIDATE || return nothing
    now = multiq_lock_counts()
    parts = String[]
    for tid in eachindex(now)
        a, h = now[tid][1] - before[tid][1], now[tid][2] - before[tid][2]
        a == 0 || push!(parts, "tid $tid $a ($(round(100 * h / a; digits = 1))% held)")
    end
    ops = d.f_first + d.f_again + d.f_pops
    println(stderr, "validate: F lock, ", label, ": ", ops, " F operations for ", requests, " requests (",
            requests == 0 ? "-" : round(ops / requests; digits = 2), " per request), ", d.acq, " acquisitions, ",
            d.acq == 0 ? "-" : round(100 * d.held / d.acq; digits = 1), "% found it held; per tid: ",
            isempty(parts) ? "none" : join(parts, ", "))
    return nothing
end

# The shares, VALIDATE only: per-thread counts (a copy of every `:default` thread's sstate fields).
const _S_FIELDS = (:f_cyc, :l_cyc, :both_f, :both_l, :caps, :clips, :acct, :f_choice)
# -g's run counters (a clock read at every -g pop, VALIDATE only), read beside the credited time so
# the harness reports credited against run (#618, agent-config #82 Idea 8), as `/mq` does in a server.
const _GR_FIELDS = (:run_r, :run_l, :run_r2, :run_l2)
multiq_run_counts() = !(FIFO_GROUP && MULTIQ_VALIDATE) ? nothing :
    Dict(tid => NamedTuple{_GR_FIELDS}(Tuple(getfield(_gstates()[tid], k) for k in _GR_FIELDS))
         for tid in Threads.threadpooltids(:default))
function multiq_share_counts()
    FIFO_ACCOUNTS && MULTIQ_VALIDATE || return nothing
    s = Dict(tid => NamedTuple{_S_FIELDS}(Tuple(getfield(_sstates()[tid], k) for k in _S_FIELDS))
             for tid in Threads.threadpooltids(:default))
    FIFO_GROUP || return s
    g = multiq_run_counts()
    return Dict(tid => merge(s[tid], g[tid]) for tid in keys(s))
end

# The shares, VALIDATE only: print, per `:default` thread, the pops by side, the time credited to
# each side (and its F share, overall and while both sides had work), the cap's and the clip's
# actions, since `before`. With `half = true` (the mixed cell under -t) every thread's F share
# while both had work must be 40-60%, over at least 50 ms of such time.
#
# Under -g the "F" side is the request side (the R heaps and the rings: pops F counts both), and
# `half` checks the weight's band instead: GROUP_W4/4 of the time +-10 points (g0: not checked).
function multiq_share_check(label, before, fbefore; half::Bool = false)
    FIFO_ACCOUNTS && MULTIQ_VALIDATE || return nothing
    lo, hi = FIFO_GROUP ? (25 * GROUP_W4 - 10, 25 * GROUP_W4 + 10) : (40, 60)
    now = multiq_share_counts()
    ms(c) = round(c / SHARE_CYCLES_PER_MS; digits = 1)
    pct(a, b) = a + b == 0 ? NaN : round(100 * a / (a + b); digits = 1)
    bad = String[]
    sums = zeros(Int, 8)   # -g: credited R, L (while both had work); run R, L; run from two-sided R, L; F pops, L pops
    println(stderr, "validate: share counts, ", label, " (", MULTIQ_VARIANT, ", cap ", ms(SHARE_CAP), " ms):")
    for tid in Threads.threadpooltids(:default)
        d = NamedTuple{_S_FIELDS}(Tuple(getfield(now[tid], k) - getfield(before[tid], k) for k in _S_FIELDS))
        fs, f0 = _fstates()[tid], fbefore[tid]
        fp, lp = fs.f_pops + fs.r_pops - f0[1], fs.l_pops - f0[2]
        both = pct(d.both_f, d.both_l)
        println(stderr, "validate:   tid ", tid, ": pops F ", fp, " L ", lp, ", accounted ", d.acct, " (F tried first ",
                d.f_choice, "), time F ", ms(d.f_cyc), " ms L ", ms(d.l_cyc), " ms (F ", pct(d.f_cyc, d.l_cyc),
                "%), while both had work F ", ms(d.both_f), " ms L ", ms(d.both_l), " ms (F ", both, "%), cap ",
                d.caps, ", clipped intervals ", d.clips)
        if FIFO_GROUP
            gr = NamedTuple{_GR_FIELDS}(Tuple(getfield(now[tid], k) - getfield(before[tid], k) for k in _GR_FIELDS))
            println(stderr, "validate:   tid ", tid, ": run R ", ms(gr.run_r), " ms L ", ms(gr.run_l), " ms (R ",
                    pct(gr.run_r, gr.run_l), "%), run from two-sided pops R ", ms(gr.run_r2), " ms L ", ms(gr.run_l2),
                    " ms (R ", pct(gr.run_r2, gr.run_l2), "%)")
            sums .+= (d.both_f, d.both_l, gr.run_r, gr.run_l, gr.run_r2, gr.run_l2, fp, lp)
        end
        if half
            (d.both_f + d.both_l) / SHARE_CYCLES_PER_MS >= 50 ||
                push!(bad, "tid $tid: only $(ms(d.both_f + d.both_l)) ms with both sides busy")
            lo <= both <= hi || push!(bad, "tid $tid: F's share while both had work is $both%")
        end
    end
    # One machine-readable line per cell for `aggregate_fifo.jl <dir> credit`: ms, and the R parts.
    FIFO_GROUP && println(stderr, "validate: credit-run, ", label, " (", MULTIQ_VARIANT, "): threads=",
                          Threads.nthreads(:default), ",", Threads.nthreads(:interactive), " credited_r_ms=",
                          ms(sums[1]), " credited_l_ms=", ms(sums[2]), " credited_r_pct=", pct(sums[1], sums[2]),
                          " run_r_ms=", ms(sums[3]), " run_l_ms=", ms(sums[4]), " run_r_pct=", pct(sums[3], sums[4]),
                          " run2_r_ms=", ms(sums[5]), " run2_l_ms=", ms(sums[6]), " run2_r_pct=", pct(sums[5], sums[6]),
                          " pops_r=", sums[7], " pops_l=", sums[8])
    isempty(bad) || error("$MULTIQ_VARIANT: $label: the time share is not $lo-$hi% on every :default thread: ",
                          join(bad, "; "))
    return nothing
end
# -g, VALIDATE only (#618, the `8,0` diagnostic): per `:default` thread, the gstate counts, the
# share's accounts (`_S_FIELDS`) and the pops by structure (R heaps, rings, L heaps), as one flat
# NamedTuple per thread; the caller differences two calls.
const _G_FIELDS = (:two, :one_r, :one_l, :none, :l_miss, :l_miss_r, :l_miss_none, :run_r, :run_l,
                   :run_r2, :run_l2, :nsamp, :dl_sum, :dl_peak, :dq_sum, :dq_peak, :dh_sum, :dh_peak)
const _G_POPS = (:r_pops, :f_pops, :l_pops)
function multiq_group_counts()
    FIFO_GROUP && MULTIQ_VALIDATE || return nothing
    P = PARTR
    keys = (_G_FIELDS..., _S_FIELDS..., _G_POPS...)
    return Dict(tid => NamedTuple{keys}((Tuple(getfield(_gstates()[tid], k) for k in _G_FIELDS)...,
                                         Tuple(getfield(_sstates()[tid], k) for k in _S_FIELDS)...,
                                         Tuple(getfield(_fstates()[tid], k) for k in _G_POPS)...))
                for tid in Threads.threadpooltids(:default))
end
# The peaks are not differenced (a running maximum); reset them after a read.
multiq_group_reset_peaks!() = FIFO_GROUP && MULTIQ_VALIDATE &&
    foreach(g -> (g.dl_peak = 0; g.dq_peak = 0; g.dh_peak = 0), _gstates())

share_fifo_pops() = !(FIFO_ACCOUNTS && MULTIQ_VALIDATE) ? nothing : Dict(tid => (_fstates()[tid].f_pops + _fstates()[tid].r_pops, _fstates()[tid].l_pops)
                         for tid in Threads.threadpooltids(:default))

# M and O, VALIDATE only, two probes of `multiq_check_empty` (as E's):
# 1. Everything drained: it must say empty.
# 2. An F task queued and no wake-up sent: it must say non-empty (`M_NEGATIVE=blind` fails it: a
#    thread could sleep with a task in the F queue). The dummy is taken back out under the lock.
function _f_probe(reps::Int = 20)
    P = PARTR
    seen_empty = false
    for _ in 1:reps
        sleep(0.05)
        seen_empty = fetch(Threads.@spawn :default P.multiq_check_empty())
        seen_empty && break
    end
    seen_empty || error("F: multiq_check_empty() said non-empty $reps times with everything drained")
    println(stderr, "multiq_variant: F probe 1: multiq_check_empty() says empty with everything drained")
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
            _set_class!(dummy, :F)
            P.multiq_insert(dummy, dummy.priority)
            e = P.multiq_check_empty()
            (e, P.f_take_back!(dummy))
        end)
        got || continue   # a spinning thread popped it (and ran a no-op): no verdict this time
        empty && error("F: multiq_check_empty() says empty while the F queue holds a task")
        checked += 1
    end
    checked >= reps ÷ 2 || error("F: only $checked of $reps check_empty probes kept their task")
    println(stderr, "multiq_variant: F probe 2: multiq_check_empty() saw a queued F task ", checked, " of ", reps,
            " times (the rest were taken first)")
    return nothing
end

# -g, VALIDATE only: the R heaps' probe of `multiq_check_empty`. An R task queued and no wake-up
# sent: it must say non-empty (`M_NEGATIVE=rblind`, a check blind to the R heaps, fails it). The
# dummy is taken back out under its heap's lock. Then the R heaps are stock's size: 2 per thread.
function _r_probe(reps::Int = 20)
    P = PARTR
    @atomic :release P.fl.on = true
    checked = 0
    for _ in 1:reps
        sleep(0.05)
        empty, got = fetch(Threads.@spawn :default begin
            t0 = time_ns()
            while time_ns() - t0 < 5_000_000
                GC.safepoint()
            end
            dummy = Task(() -> nothing)
            Threads._spawn_set_thrpool(dummy, :default)
            _set_class!(dummy, :R)
            P.multiq_insert(dummy, dummy.priority)
            e = P.multiq_check_empty()
            (e, P.r_take_back!(dummy))
        end)
        got || continue
        empty && error("R: multiq_check_empty() says empty while the R heaps hold a task")
        checked += 1
    end
    checked >= reps ÷ 2 || error("R: only $checked of $reps check_empty probes kept their task")
    nh = length(P.r_heaps[P.f_tpid + 1])
    nh == 2 * Threads.nthreads(:default) || error("R: $nh R heaps for $(Threads.nthreads(:default)) threads")
    P.r_queued() == 0 || error("R: $(P.r_queued()) tasks left in the R heaps after the probe")
    println(stderr, "multiq_variant: R probe: multiq_check_empty() saw a queued R task ", checked, " of ", reps,
            " times (the rest were taken first); ", nh, " R heaps")
    return nothing
end

# M and O, VALIDATE only, `M_NEGATIVE=stall`: the negative control of the stall check in `f_pop!`.
# An F task that its owner never takes: a dummy pinned to this thread, which then computes without
# yielding, so it never pops (neither its own task nor anything else) while the `:default` threads,
# woken by a burst of plain spawns, find only that entry and fail every pop. The check must abort
# the process (exit 134) with "made no pop meanwhile" well before the hold ends; returning is the
# failure.
function _f_stall_control(hold_s::Float64 = 60.0)
    P = PARTR
    dummy = Task(() -> nothing)
    dummy.sticky = false
    Threads._spawn_set_thrpool(dummy, :default)
    ccall(:jl_set_task_tid, Cint, (Any, Cint), dummy, Threads.threadid() - 1) == 1 ||
        error("F stall control: could not pin the dummy")
    _set_class!(dummy, :F)
    P.multiq_insert(dummy, dummy.priority)
    println(stderr, "multiq_variant: F stall control: a task pinned to tid ", Threads.threadid(),
                    ", which now holds its thread for ", hold_s, " s without popping")
    for _ in 1:Threads.nthreads(:default)
        Threads.@spawn :default nothing   # wakes the :default threads; they find only the pinned entry
    end
    t0 = time()
    while time() - t0 < hold_s
        GC.safepoint()
    end
    error("F stall control: the stall check did not fire in $hold_s s")
end

# M and O, VALIDATE only: the F queue's own order, on a queue of its own with dummy tasks that
# never run (`f_pop!` pins each popped dummy to the tid it is given; they are never scheduled).
function _f_unit_asserts()
    P = PARTR
    nt = Threads.nthreads(:default)
    # Pops are made as a `:default` tid would make them (`f_pop!` takes the tid); at most
    # nthreads(:default) - 1 entries can be pinned to the others.
    me, other = Threads.threadpooltids(:default)[1:2]
    newq() = P.fqueue()
    function push(q, ids, i)
        t = Task(() -> nothing)
        ids[t] = i
        lock(q.lock); _ring_push!(q, t); unlock(q.lock)
        return t
    end
    pop(q, ids, tid = me) = (t = P.f_pop!(q, tid, nt); t === nothing ? 0 : ids[t])
    # Fill and drain, across ring growth (capacity 256).
    q, ids = newq(), IdDict{Task,Int}()
    foreach(i -> push(q, ids, i), 1:600)
    fd = [pop(q, ids) for _ in 1:600]
    @assert fd == collect(1:600) "F: fill/drain popped out of order"
    @assert q.n == 0 "F: $(q.n) left after the drain"
    # Random interleaved pushes and pops against a reference vector.
    q, ids = newq(), IdDict{Task,Int}()
    ref, popped, pushed = Int[], Int[], 0
    state = UInt64(0x9e3779b97f4a7c15)
    while length(popped) < 2000
        state = state * 0x5851f42d4c957f2d + 1
        if pushed < 2000 && (q.n == 0 || (state >> 33) % 3 != 0)
            pushed += 1
            push(q, ids, pushed)
            push!(ref, pushed)
        else
            push!(popped, pop(q, ids))
            @assert popped[end] == popfirst!(ref) "F: interleaved pop $(popped[end]) out of order"
        end
    end
    # A head pinned to another thread: passed over without holding the rest, left at the head, and
    # taken by its owner.
    q, ids = newq(), IdDict{Task,Int}()
    pinned = push(q, ids, 1)
    ccall(:jl_set_task_tid, Cint, (Any, Cint), pinned, other - 1) == 1 || error("F: could not pin the dummy")
    foreach(i -> push(q, ids, i), 2:5)
    got = [pop(q, ids) for _ in 1:4]
    @assert got == [2, 3, 4, 5] "F: with a pinned head this thread popped $got"
    @assert q.n == 1 && q.tasks[q.head] === pinned "F: the pinned entry left the head"
    @assert pop(q, ids) == 0 "F: this thread took a task pinned to tid $other"
    @assert pop(q, ids, other) == 1 "F: the owner could not take its own task"
    # Every scanned entry pinned elsewhere, the owner's task behind them: the owner still gets it.
    q, ids = newq(), IdDict{Task,Int}()
    others = [t for t in Threads.threadpooltids(:default) if t != me]
    for (i, o) in enumerate(others)
        t = push(q, ids, i)
        ccall(:jl_set_task_tid, Cint, (Any, Cint), t, o - 1)
    end
    mine = push(q, ids, 100)
    ccall(:jl_set_task_tid, Cint, (Any, Cint), mine, me - 1)
    @assert pop(q, ids) == 100 "F: the owner's task behind $(length(others)) pinned entries was not reached"
    if FIFO_RINGS
        # A ring: stamped fill/drain across growth comes out in order, its stamps rising strictly.
        q, ids = _new_ring(), IdDict{Task,Int}()
        for i in 1:600
            t = Task(() -> nothing)
            ids[t] = i
            lock(q.lock); P.f_push_stamped!(q, t); unlock(q.lock)
        end
        sts = [q.seqs[P.f_idx(q, k)] for k in 1:600]
        @assert all(diff(sts) .> 0) "rings: stamps within a ring do not rise"
        rd = [pop(q, ids) for _ in 1:600]
        @assert rd == collect(1:600) "rings: a ring's stamped fill/drain popped out of order"
        MULTIQ_NATIVE && PARTR.rings_size(PARTR.f_tpid)   # the native build sizes them at the first marked insert
        @assert _nrings() == 2 * nt "rings: $(_nrings()) rings for $nt threads"
    end
    # The L heap is the build's: A's fill/drain order.
    lfd = _fill_drain(20)
    @assert lfd == [1; 20:-1:2] "F: the stock heap's fill/drain popped $lfd"
    println(stderr, "multiq_variant: single-structure asserts passed for ", MULTIQ_VARIANT,
            ": F queue fill/drain of 600 in order, 2,000 interleaved in order, a pinned head passed over ",
            "and taken by its owner, the owner's task found behind ", length(others), " pinned entries; ",
            "stock heap fill/drain ", lfd,
            FIFO_RINGS ? "; a ring's stamped fill/drain of 600 in order, $(_nrings()) rings" : "")
    # The native build counts every clock read of its timed code, the stamps of the standalone rings
    # above included: the no-clock check counts from here.
    MULTIQ_NATIVE && (_NOCLOCK_STAMPS0[] = sum(v -> v.stamps, _gstates()))
    _M_NEGATIVE == "stall" && _f_stall_control()
    if MULTIQ_NOCLOCK
        # `_r_probe` sets the pool flag, which is what M_NOCLOCK must see unset.
        println(stderr, "multiq_variant: M_NOCLOCK=1: the check_empty probes skipped, so the pool flag stays as the program leaves it")
    else
        multiq_watchdog(60)
        _f_probe()
        FIFO_GROUP && _r_probe()
        multiq_watchdog(0)
    end
    return nothing
end

# M_NOCLOCK=1, -g only (#618, agent-config #82 Idea 8): a cell in which nothing is marked must leave
# the pool flag unset and make no -g pop, so no -g clock read happened in it: the pop was stock's.
const _NOCLOCK_STAMPS0 = Ref(0)   # native: the clock reads the unit asserts' own rings made
function multiq_noclock_check(label)
    MULTIQ_NOCLOCK || return nothing
    P = PARTR
    on = @atomic :acquire P.fl.on
    pops = sum(g -> g.two + g.one_r + g.one_l + g.none, _gstates())
    acct = sum(s -> s.acct, _sstates())
    stamps = MULTIQ_NATIVE ? sum(v -> v.stamps, _gstates()) - _NOCLOCK_STAMPS0[] : sum(g -> g.vstamp != 0 ? 1 : 0, _gstates())
    (on || pops != 0 || acct != 0 || stamps != 0) &&
        error("$MULTIQ_VARIANT: $label: with nothing marked the pool flag is $(on ? "set" : "unset"), ",
              pops, " -g pops, ", acct, " accounted pops, ", stamps, MULTIQ_NATIVE ? " clock reads by the timed code" : " threads with a -g clock read")
    println(stderr, "validate: no clock, ", label, " (", MULTIQ_VARIANT, "): pool flag unset, 0 -g pops, ",
            "0 accounted pops, no thread read the -g clock")
    return nothing
end

function multiq_unit_asserts()
    MULTIQ_FIFO && return _f_unit_asserts()
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
