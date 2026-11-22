# #618 Idea 16, part B2: the corners slim candidate s2 opens, on a validation build (SCHED_VALIDATE).
# s2 arms the pool flag when a task that will reach the multiqueue is marked, not at its first insert.
# A task that gets its class some other way, while nothing has armed the flag, takes stock's path:
#   a  a class set by hand (Base.Partr.set_sched_class!) before any marked spawn;
#   b  a task marked while sticky (fair_arm! skips it), then made non-sticky;
#   c  a task marked for :interactive (fair_arm! skips it), then moved to :default.
# One case a process (CASE=a|b|c), so the flag starts unset. Two phases, each with every :default thread
# held by a spinner while K corner tasks are scheduled, so they queue:
#   1 no marked spawn (on s2 the flag stays unset; on the mark the class itself arms it at the insert): are all K run, where did they sit (the counts: l_first is stock's insert,
#     f_first a ring's; stock_bit a classed task popped from stock's heaps), and in which order
#     (inversions against arrival: 0 is arrival order, ~0.5 random; the rings give arrival order);
#   2 the same, then one ordinary marked spawn while they are still queued (it arms the flag on s2):
#     are all K still run (none lost behind the flag), within LOST_S seconds.
# Prints one line a phase; exits non-zero if a task is lost. An assert of the validation build aborts
# the process, which the driver sees as a failure.
#   CASE=a K=200 julia --startup-file=no --threads=4,1 bench/julia/slim2_corners.jl
const P = Base.Partr
const CASE = get(ENV, "CASE", "a")
CASE in ("a", "b", "c") || error("CASE must be a, b or c")
const K = parse(Int, get(ENV, "K", "200"))
const LOST_S = parse(Float64, get(ENV, "LOST_S", "10"))
isdefined(P, :sched_counts) || error("needs a validation build (Base.Partr.sched_counts)")

const ORDER = zeros(Int, K)
const NEXT = Threads.Atomic{Int}(0)
counts() = P.sched_counts()
cget(c, k) = hasproperty(c, k) ? getproperty(c, k) : -1
flag() = (@atomic :monotonic P.fl.on)

function corner_task(i::Int)
    t = Task(() -> (ORDER[Threads.atomic_add!(NEXT, 1) + 1] = i; nothing))
    # The pool as `@spawn` sets it: a bare Task() made on the main task would sit in :interactive, a
    # one-thread pool that never reaches the multiqueue.
    # And not sticky, as `@spawn` makes it (a bare Task() is sticky).
    if CASE == "a"
        Threads._spawn_set_thrpool(t, :default)
        t.sticky = false
        P.set_sched_class!(t, P.C_F)
    elseif CASE == "b"
        Threads._spawn_set_thrpool(t, :default)
        t.sticky = true
        Threads._spawn_set_fair(t, true)
        t.sticky = false
    else
        Threads._spawn_set_thrpool(t, :interactive)
        t.sticky = false
        Threads._spawn_set_fair(t, true)
        Threads._spawn_set_thrpool(t, :default)
    end
    return t
end

function hold_all()
    hold = Threads.Atomic{Bool}(true)
    started = Threads.Atomic{Int}(0)
    k = Threads.nthreads(:default)
    spinners = [Threads.@spawn :default (Threads.atomic_add!(started, 1); while hold[]; GC.safepoint(); end) for _ in 1:k]
    while started[] < k
        yield()
    end
    return hold, spinners
end

inversions(o) = (n = length(o); n < 2 ? 0.0 : count(o[i] > o[j] for i in 1:n for j in i+1:n) / (n * (n - 1) / 2))

function phase(arm::Bool)
    fill!(ORDER, 0); NEXT[] = 0
    c0 = counts(); f0 = flag()
    hold, spinners = hold_all()
    ts = [corner_task(i) for i in 1:K]
    cls = count(t -> P.sched_class(t) != P.C_NONE, ts)
    foreach(schedule, ts)
    marked = nothing
    if arm
        marked = Threads.@spawn fair=true nothing   # an ordinary marked spawn, while the corner tasks queue
    end
    f_mid = flag()
    hold[] = false
    foreach(wait, spinners)
    t_end = time() + LOST_S
    while NEXT[] < K && time() < t_end
        sleep(0.001)
    end
    ran = NEXT[]
    marked === nothing || wait(marked)
    c1 = counts()
    d(k) = cget(c1, k) - cget(c0, k)
    println("corner\tcase=", CASE, "\tphase=", arm ? "2-armed-while-queued" : "1-no-marked-spawn",
            "\tbuild=", Base.GIT_VERSION_INFO.commit_short, "\tlayout=", Threads.nthreads(:default), ",", Threads.nthreads(:interactive),
            "\tK=", K, "\tclassed_at_schedule=", cls, "\tran=", ran, "\tlost=", K - ran,
            "\tflag_before=", f0, "\tflag_while_queued=", f_mid, "\tflag_after=", flag(),
            "\tl_first=", d(:l_first), "\tf_first=", d(:f_first), "\tr_first=", d(:r_first), "\tdemoted=", d(:demoted),
            "\tl_pops=", d(:l_pops), "\tf_pops=", d(:f_pops), "\tr_pops=", d(:r_pops), "\tstock_bit=", d(:stock_bit),
            "\tinversions=", ran == K ? round(inversions(ORDER); digits = 3) : "n/a")
    return ran == K
end

ok1 = phase(false)
ok2 = phase(true)
(ok1 && ok2) || (println(stderr, "slim2_corners: a corner task was lost (case $CASE)"); exit(1))
