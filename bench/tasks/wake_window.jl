# A repro aimed at the lost-wakeup window (#618, agent-config #82 Idea 13, question 2).
#
# The window, as read in the tag v1.13.4 (src/scheduler.c `jl_task_get_next`, base/task.jl `wait`):
# a thread with nothing to pop spins for JULIA_THREAD_SLEEP_THRESHOLD (100 us by default), popping
# again on every turn, then stores `sleeping`, fences, calls the empty check, pops once more and
# sleeps. An enqueue inserts, fences and wakes one thread it finds `sleeping`. The fences make one
# of the two see the other, so a blind empty check can lose a wakeup only when the pop after the
# fence misses a task it can see, and only for an enqueue that lands after the thread's last pop of
# the spin and before it stores `sleeping` (inferred). The mark's R heaps are popped by stock's
# two-choice pop, which gives up after a few tries; its rings are popped by a full pass. So the R
# heaps' negative control (`rblind`) can lose a wakeup and the rings' (`blind`) cannot (inferred).
#
# The shape: the driver is the main task on the `:interactive` thread and never yields, so it never
# pops from `:default` and never sleeps. Each round it enqueues TASKS tasks on `:default` (default:
# as many as the pool has threads), waits until every one has run, waits DELAY more (a random
# delay in DELAY_NS, the aim: the end of the threads' idle spin), and starts the next round.
#   MODE=ring  a new task per slot and round, which stamps the clock and ends. Marked (MARK=1) it is
#              class F, a root that has not run: the rings, enqueued from a foreign pool.
#   MODE=wake  TASKS tasks spawned once, each looping: stamp the clock, set its ready flag, wait().
#              The driver re-enqueues each with `schedule(t)`, as `notify` does, without a lock that
#              could make the driver yield. Marked, a woken task that has run is class R: the R heaps,
#              the shape of a handler woken by I/O.
#   MARK=0     the same shapes with nothing marked (the control build has no mark at all).
# The watchdog: a task that has not run STUCK_MS (100) after its enqueue is stuck. The driver then
# notes what the build can say (the queues' depth; on the validation build, which `:default` threads
# made no pop in 20 ms, read as asleep), rescues it (`jl_wakeup_threadpool`, then a wake of every
# `:default` thread) and goes on. Events are buffered and printed at the end, so the driver does no
# I/O while it runs.
#
# Run with the negative controls on the validation build: JULIA_SCHED_NEGATIVE=blind MODE=ring,
# JULIA_SCHED_NEGATIVE=rblind MODE=wake. JULIA_THREAD_SLEEP_THRESHOLD=0 makes every idle turn go
# straight to the sleep sequence (the runtime reads it at start-up; the summary records it).
# The ring control (#618, agent-config #82 Idea 14; bench/julia/native-mark-nopass.patch, its own
# throwaway build): JULIA_SCHED_NOPASS=1 makes the ring pop give up after its samples, without the
# pass over every ring. With JULIA_SCHED_NEGATIVE=blind as well, MODE=ring has neither layer (the
# check and a pop that cannot miss); NOPASS alone leaves the check. The summary's nopass_env and
# nopass_armed record it.
#
#   julia --threads=2,1 bench/tasks/wake_window.jl
#   env: MODE ring|wake, MARK 1|0, DUR_S 300, STUCK_MS 100, DELAY_NS "lo:hi" (0:20000), TASKS, LABEL
# stdout: one summary row (TSV, with a header unless NOHEADER=1); stderr: one line per stuck task.

const MODE = get(ENV, "MODE", "wake")
MODE in ("ring", "wake") || error("MODE must be ring or wake, not $MODE")
const CAN_MARK = isdefined(Threads, :_spawn_set_fair)
const MARK = get(ENV, "MARK", CAN_MARK ? "1" : "0") == "1"
MARK && !CAN_MARK && error("MARK=1 needs a Julia built with the native mark (bench/julia/)")
const DUR_NS = round(UInt64, parse(Float64, get(ENV, "DUR_S", "300")) * 1e9)
const STUCK_NS = round(UInt64, parse(Float64, get(ENV, "STUCK_MS", "100")) * 1e6)
const DELAY_LO, DELAY_HI = let s = split(get(ENV, "DELAY_NS", "0:20000"), ':')
    parse(UInt64, s[1]), parse(UInt64, s[end])
end
DELAY_HI >= DELAY_LO || error("DELAY_NS: hi < lo")
const NDEF = Threads.nthreads(:default)
const TASKS = parse(Int, get(ENV, "TASKS", string(NDEF)))
const LABEL = get(ENV, "LABEL", "-")
Threads.threadpool() === :interactive ||
    error("the driver must run on :interactive: start with --threads=N,1 (it runs on $(Threads.threadpool()))")
NDEF >= 2 || error("the :default pool needs 2 threads or more to reach the multiqueue")
TASKS >= 1 || error("TASKS must be at least 1")

const P = Base.Partr
const VALIDATE = isdefined(P, :SCHED_VALIDATE) && P.SCHED_VALIDATE
const NATIVE = isdefined(P, :f_queued)
const DEF_TIDS = collect(Threads.threadpooltids(:default))

# The queues of `:default`, read racily: stock's heaps, and on a mark build the rings and the R heaps.
l_queued() = sum(Int(@atomic :monotonic h.ntasks) for h in P.heaps[2]; init = 0)
f_queued() = NATIVE ? P.f_queued() : -1
r_queued() = NATIVE ? P.r_queued() : -1
# The validation build counts every pop per thread.
pops(tid) = (v = P.vs(tid); v.f_pops + v.l_pops + v.r_pops + v.gpops)

function mk(f)
    t = Task(f)
    t.sticky = false
    Threads._spawn_set_thrpool(t, :default)
    MARK && Threads._spawn_set_fair(t, true)
    return t
end

# A busy wait on the clock: the driver never yields.
@inline function spin_until(t::UInt64)
    while time_ns() < t
    end
end

# Latency histogram in microseconds, 0 to 100 ms, and an overflow bin.
const NB = 100_001
const hist = zeros(Int, NB + 1)
const lat_max = Ref(UInt64(0))
@inline function record!(d::UInt64)
    us = Int(d ÷ 1000)
    hist[min(us, NB) + 1] += 1
    d > lat_max[] && (lat_max[] = d)
end
function quantile_us(q)
    n = sum(hist); n == 0 && return -1
    k = ceil(Int, q * n); c = 0
    for (i, h) in pairs(hist)
        c += h
        c >= k && return i - 1
    end
    return NB
end

const events = String[]
const stuck = Ref(0)      # tasks rescued by the driver's wake
const late = Ref(0)       # tasks past STUCK_MS that ran before the rescue
const unrescued = Ref(0)  # tasks no wake brought back within 100 ms

# A task has been waiting STUCK_MS: what the build can say, then the rescue. `hasrun()` reads the
# task's own flag.
function on_stuck(rnd, i, enq, hasrun)
    age = (time_ns() - enq) / 1e6
    fq, rq, lq = f_queued(), r_queued(), l_queued()
    asleep = "-"
    if VALIDATE
        c0 = [pops(t) for t in DEF_TIDS]
        spin_until(time_ns() + UInt64(20_000_000))
        c1 = [pops(t) for t in DEF_TIDS]
        asleep = join((string(t) for (t, a, b) in zip(DEF_TIDS, c0, c1) if a == b), ",")
        isempty(asleep) && (asleep = "none")
    end
    if hasrun()
        late[] += 1
        push!(events, string("late\t", rnd, "\t", i, "\t", round(age; digits = 1), "\t", fq, "\t", rq, "\t", lq, "\t", asleep, "\t-\t-"))
        return
    end
    t0 = time_ns()
    ccall(:jl_wakeup_threadpool, Cvoid, (Int8,), Int8(1))
    how = "pool"
    while !hasrun() && time_ns() - t0 < 50_000_000
    end
    if !hasrun()
        how = "each"
        for t in DEF_TIDS
            ccall(:jl_wakeup_thread, Cint, (Int16,), Int16(t - 1))
        end
        while !hasrun() && time_ns() - t0 < 100_000_000
        end
    end
    if hasrun()
        stuck[] += 1
    else
        unrescued[] += 1
        how = "none"
    end
    push!(events, string("stuck\t", rnd, "\t", i, "\t", round(age; digits = 1), "\t", fq, "\t", rq, "\t", lq, "\t", asleep, "\t", how,
                         "\t", round((time_ns() - t0) / 1e3; digits = 1)))
end

next_delay() = DELAY_HI == DELAY_LO ? DELAY_LO : DELAY_LO + rand(UInt64) % (DELAY_HI - DELAY_LO + UInt64(1))

function run_ring()
    ran = [Threads.Atomic{UInt64}(0) for _ in 1:TASKS]
    enq = zeros(UInt64, TASKS)
    flagged = falses(TASKS)
    rounds = 0; enqueued = 0
    t_end = time_ns() + DUR_NS
    while time_ns() < t_end
        rounds += 1
        for i in 1:TASKS
            ran[i][] = 0
            flagged[i] = false
            r = ran[i]
            t = mk(() -> (r[] = time_ns(); nothing))
            enq[i] = time_ns()
            schedule(t)
        end
        enqueued += TASKS
        pending = TASKS
        while pending > 0
            pending = 0
            now = time_ns()
            for i in 1:TASKS
                ran[i][] != 0 && continue
                pending += 1
                if !flagged[i] && now - enq[i] > STUCK_NS
                    flagged[i] = true
                    r = ran[i]
                    on_stuck(rounds, i, enq[i], () -> r[] != 0)
                end
            end
        end
        for i in 1:TASKS
            record!(ran[i][] - enq[i])
        end
        spin_until(time_ns() + next_delay())
    end
    return rounds, enqueued
end

function run_wake()
    ran = [Threads.Atomic{UInt64}(0) for _ in 1:TASKS]
    ready = [Threads.Atomic{Int}(0) for _ in 1:TASKS]
    stop = Threads.Atomic{Bool}(false)
    tasks = Task[]
    for i in 1:TASKS
        r, rd = ran[i], ready[i]
        t = mk() do
            while true
                r[] = time_ns()
                stop[] && break
                rd[] = 1
                wait()
            end
        end
        push!(tasks, t)
        schedule(t)
    end
    enq = zeros(UInt64, TASKS)
    flagged = falses(TASKS)
    # The first run of each: every task has started and parked once (class R from here on).
    t0 = time_ns()
    while any(rd -> rd[] == 0, ready)
        time_ns() - t0 > 10_000_000_000 && error("wake: the tasks did not all start in 10 s")
    end
    rounds = 0; enqueued = 0
    t_end = time_ns() + DUR_NS
    while time_ns() < t_end
        rounds += 1
        spin_until(time_ns() + next_delay())
        for i in 1:TASKS
            ready[i][] = 0
            flagged[i] = false
            enq[i] = time_ns()
            schedule(tasks[i])
        end
        enqueued += TASKS
        pending = TASKS
        while pending > 0
            pending = 0
            now = time_ns()
            for i in 1:TASKS
                ready[i][] == 1 && continue
                pending += 1
                if !flagged[i] && now - enq[i] > STUCK_NS
                    flagged[i] = true
                    r, e = ran[i], enq[i]
                    on_stuck(rounds, i, e, () -> r[] > e)
                end
            end
        end
        for i in 1:TASKS
            record!(ran[i][] - enq[i])
        end
    end
    stop[] = true
    for i in 1:TASKS
        schedule(tasks[i])
    end
    foreach(wait, tasks)
    return rounds, enqueued
end

rounds, enqueued = MODE == "ring" ? run_ring() : run_wake()

neg = VALIDATE ? string(isdefined(P, :vp) ? (@atomic P.vp.neg) : (@atomic P.fp.neg)) : "-"
# The ring control (#618 Idea 14, bench/julia/native-mark-nopass.patch): only its build has the field.
nopass = VALIDATE && hasfield(typeof(P.fp), :nopass) ? string(getfield(P.fp, :nopass, :sequentially_consistent)) : "-"
c = VALIDATE ? P.sched_counts() : nothing
cnt(k) = c === nothing ? "-" : string(getfield(c, k))
commit = Base.GIT_VERSION_INFO.commit_short
cols = ["label", "commit", "validate", "mode", "mark", "neg_env", "neg_armed", "threshold", "layout", "tasks", "delay_ns",
        "dur_s", "rounds", "enqueued", "stuck", "late", "unrescued", "lat_p50_us", "lat_p99_us", "lat_p999_us", "lat_max_us",
        "f_first", "r_first", "r_again", "f_pops", "r_pops", "l_pops", "gpops", "nopass_env", "nopass_armed"]
vals = [LABEL, commit, string(VALIDATE), MODE, MARK ? "1" : "0", get(ENV, "JULIA_SCHED_NEGATIVE", "-"), neg,
        get(ENV, "JULIA_THREAD_SLEEP_THRESHOLD", "default"),
        string(Threads.nthreads(:default), ",", Threads.nthreads(:interactive)), string(TASKS), string(DELAY_LO, ":", DELAY_HI),
        string(DUR_NS / 1e9), string(rounds), string(enqueued), string(stuck[]), string(late[]), string(unrescued[]),
        string(quantile_us(0.5)), string(quantile_us(0.99)), string(quantile_us(0.999)), string(round(lat_max[] / 1e3; digits = 1)),
        cnt(:f_first), cnt(:r_first), cnt(:r_again), cnt(:f_pops), cnt(:r_pops), cnt(:l_pops), cnt(:gpops),
        get(ENV, "JULIA_SCHED_NOPASS", "-"), nopass]
get(ENV, "NOHEADER", "0") == "1" || println(join(cols, '\t'))
println(join(vals, '\t'))
for e in events
    println(stderr, LABEL, '\t', e)
end
