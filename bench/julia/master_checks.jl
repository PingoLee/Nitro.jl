# #618, the native mark ported to master: the points master adds over the tag (agent-config #82
# Idea 17), each as a probe that can fail. Every probe prints one "master_checks: ok:" line or throws.
#
#   <mark-validate> --threads=8,1 bench/julia/master_checks.jl            a to e (the validation build)
#   <mark-validate> --threads=8,2 bench/julia/master_checks.jl
#   <julia>         --threads=8,1 bench/julia/master_checks.jl abandon N  c4 and b's natural case: N
#                                  forcible abandonments of a task in a yield() loop (marked on a mark
#                                  build, unmarked on the control); run it in a process of its own
#
# The driver greps the output for "Workqueue inconsistency": master prints it (C level, not catchable
# here) when a popped task is neither runnable nor abandoned.
using Base: cancel!, CancellationRequest, CancellationToken, CancellationTokenSource, CANCEL_TOKEN
using Base.ScopedValues: with
const MARK = hasfield(Task, :sched_class)
const P = Base.Partr
const V = MARK && P.SCHED_VALIDATE
const ND = Threads.nthreads(:default)
ok(msg) = println(stderr, "master_checks: ok: ", msg)
println(stderr, "master_checks: ", VERSION, " ", Base.GIT_VERSION_INFO.commit_short,
        MARK ? (V ? " (mark, validation build)" : " (mark)") : " (no mark)", ", threads ", ND, ",",
        Threads.nthreads(:interactive), ", mode ", isempty(ARGS) ? "main" : ARGS[1])
ND >= 2 || error("master_checks: needs a :default pool of 2 or more threads")

counts() = P.sched_counts()
delta(a, b, k) = getfield(b, k) - getfield(a, k)
empty_queues() = P.f_queued() == 0 && P.r_queued() == 0
function until(f, what; timeout = 30.0)
    t0 = time()
    while !f()
        time() - t0 > timeout && error("master_checks: timed out waiting for $what")
        sleep(0.001)
    end
end

# n unmarked spinners that never yield, one per :default thread they land on; `go[] = false` ends them.
function hold(n)
    go = Threads.Atomic{Bool}(true)
    up = Threads.Atomic{Int}(0)
    tids = zeros(Int, n)
    ts = [Threads.@spawn :default begin
              tids[i] = Threads.threadid()
              Threads.atomic_add!(up, 1)
              while go[]
                  GC.safepoint()
                  ccall(:jl_cpu_pause, Cvoid, ())
              end
          end for i in 1:n]
    until(() -> up[] == n, "$n spinners to start")
    return go, tids, ts
end
release(go, ts) = (go[] = false; foreach(wait, ts))

# A marked :default spawn, as `Threads.@spawn :default fair=true f()` makes one (the keyword does not
# lower on a build without the mark, and the abandon mode runs on the control too). Inside a @sync,
# register it with `Base.@sync_add`, as the macro would.
function mspawn(f)
    t = Task(f)
    t.sticky = false
    Threads._spawn_set_thrpool(t, :default)
    MARK && Threads._spawn_set_fair(t, true)
    schedule(t)
    return t
end

function marked_cancellable(f)
    src = CancellationTokenSource()
    t = with(CANCEL_TOKEN => CancellationToken(src)) do
        mspawn(f)
    end
    return t, src
end

parked(t::Task) = istaskstarted(t) && (@atomic :monotonic t.waiting_on) !== nothing

# ------------------------------------------------------------------------------------------------
function main_mode()
    V || error("master_checks: the main mode needs the validation build (Base.Partr.SCHED_VALIDATE)")
    # Set the flag first: one marked spawn.
    @assert fetch(mspawn(() -> 1)) == 1 && P.fair_on()

    # d. The class rule at a task's first enqueue, under master's scopes. A marked root's children
    # are R whether spawned directly, inside @sync, inside `with(CANCEL_TOKEN => …)` or as
    # `@threads` workers; an unmarked root's are unclassed; the root task's class is 0.
    @assert P.sched_class(Base.roottask) == 0x00 "the root task has class $(P.sched_class(Base.roottask))"
    function classes()
        r = Dict{Symbol,Any}()
        r[:self] = P.sched_class(current_task())
        r[:spawn] = fetch(Threads.@spawn :default P.sched_class(current_task()))
        @sync begin
            t = Threads.@spawn :default P.sched_class(current_task())
            r[:sync] = fetch(t)
        end
        tok = CancellationToken(CancellationTokenSource())
        r[:with] = with(() -> fetch(Threads.@spawn :default P.sched_class(current_task())), CANCEL_TOKEN => tok)
        for sch in (:dynamic, :greedy)
            cl = fill(0xff, 4ND)
            if sch === :dynamic
                Threads.@threads :dynamic for i in 1:4ND; cl[i] = P.sched_class(current_task()); end
            else
                Threads.@threads :greedy for i in 1:4ND; cl[i] = P.sched_class(current_task()); end
            end
            r[sch] = unique(cl)
        end
        return r
    end
    m = fetch(mspawn(classes))
    u = fetch(Threads.@spawn :default classes())
    @assert m[:self] == P.C_F && all(m[k] == P.C_R for k in (:spawn, :sync, :with)) "marked root: $m"
    @assert m[:dynamic] == [P.C_R] && m[:greedy] == [P.C_R] "marked root's @threads workers: $m"
    @assert all(u[k] == 0x00 for k in (:self, :spawn, :sync, :with)) && u[:dynamic] == [0x00] && u[:greedy] == [0x00] "unmarked root: $u"
    @assert empty_queues()
    ok("d: under a marked root, children are R directly, in @sync, in with(CANCEL_TOKEN), as @threads :dynamic/:greedy workers; under an unmarked root, all 0; root task 0")

    # e. enq_work's early return and its waiting_on check come before the insert: an abandoned task
    # and a task still registered on a wait queue insert nothing.
    ins(c) = (c.f_first, c.r_first, c.r_again, c.l_first, c.demoted)
    t = Task(() -> error("an abandoned task ran"))
    t.sticky = false
    Threads._spawn_set_thrpool(t, :default)
    Threads._spawn_set_fair(t, true)
    @atomic t._state = 0x03   # task_state_abandoned
    c0 = counts()
    @assert Base.enq_work(t) === t
    @assert ins(counts()) == ins(c0) && empty_queues() "enq_work of an abandoned task reached the insert"
    ev = Base.Event()
    w = mspawn(() -> wait(ev))
    until(() -> parked(w), "the marked task to park on the event")
    c0 = counts()
    err = try; Base.enq_work(w); nothing; catch e; e; end
    @assert err isa ConcurrencyViolationError "enq_work of a parked task did not throw: $err"
    @assert ins(counts()) == ins(c0) && empty_queues() "a parked task reached the insert"
    notify(ev); wait(w)
    @assert empty_queues()
    ok("e: an abandoned task and a task registered on a wait queue never reach the mark's insert")

    # a. The pinned task. An unstarted marked task pinned by hand to thread k, busy for 200 ms: the
    # other threads skip it, wake k and yield the OS thread; k runs it, once.
    go, tids, ts = hold(1)
    k = tids[1]
    ran = Threads.Atomic{Int}(0)
    on = Threads.Atomic{Int}(0)
    t = Task(() -> (Threads.atomic_add!(ran, 1); on[] = Threads.threadid()))
    t.sticky = false
    Threads._spawn_set_thrpool(t, :default)
    Threads._spawn_set_fair(t, true)
    @assert ccall(:jl_set_task_tid, Cint, (Any, Cint), t, k - 1) != 0
    c0 = counts()
    schedule(t)
    sleep(0.2)
    c1 = counts()
    @assert ran[] == 0 "the pinned task ran while its owner was busy"
    @assert P.f_queued() == 1 "the pinned task is not in a ring ($(P.f_queued()) queued)"
    @assert delta(c0, c1, :skips) > 0 && delta(c0, c1, :oyields) > 0 "skips $(delta(c0, c1, :skips)), oyields $(delta(c0, c1, :oyields))"
    release(go, ts)
    wait(t)
    @assert ran[] == 1 && on[] == k "ran $(ran[]) times, on thread $(on[]), owner $k"
    @assert empty_queues()
    ok("a: a pinned ring entry: skipped $(delta(c0, c1, :skips)) times, $(delta(c0, c1, :oyields)) OS-thread yields in 200 ms, then run once by its owner (thread $k)")

    # b. The stale task, injected: an abandoned task in a ring, one in an R heap and one in a stock
    # heap (inserted directly, as enq_work would refuse them). The pops return them, trypoptask
    # discards them, nothing runs, nothing aborts, the queues end empty.
    function stale_task(c)
        t = Task(() -> error("a stale task ran"))
        t.sticky = false
        Threads._spawn_set_thrpool(t, :default)
        c == 0x00 || P.set_sched_class!(t, c)
        @atomic t._state = 0x03
        return t
    end
    c0 = counts()
    for c in (P.C_F, P.C_R, 0x00)
        P.multiq_insert(stale_task(c), UInt16(0))
    end
    # Where each went, from the insert counters (an idle thread may pop them at once).
    ci = counts()
    @assert (delta(c0, ci, :f_first), delta(c0, ci, :r_first), delta(c0, ci, :l_first)) == (1, 1, 1) "the injected tasks went to rings/R/stock: $((delta(c0, ci, :f_first), delta(c0, ci, :r_first), delta(c0, ci, :l_first)))"
    until(() -> (foreach(wait, [Threads.@spawn :default nothing for _ in 1:ND]);
                 delta(c0, counts(), :stale) >= 3), "three stale pops")
    c1 = counts()
    @assert delta(c0, c1, :stale) == 3 "stale pops: $(delta(c0, c1, :stale))"
    @assert empty_queues()
    ok("b: an abandoned task in a ring, an R heap and a stock heap: 3 stale pops, discarded, nothing ran")

    # c1. A marked root cancelled while it waits in a ring (every :default thread held): it stays
    # there, starts once the threads free up, and fails at its first cancellation point.
    go, _, ts = hold(ND)
    ran = Threads.Atomic{Int}(0)
    c0 = counts()
    t, src = marked_cancellable(() -> (Threads.atomic_add!(ran, 1); Base.@cancel_check; :not_cancelled))
    sleep(0.05)
    @assert ran[] == 0 && P.f_queued() == 1 "the root is not waiting in a ring"
    cancel!(src)
    sleep(0.05)
    @assert ran[] == 0 && P.f_queued() == 1 "cancel! moved or ran the queued root"
    release(go, ts)
    until(() -> istaskdone(t), "the cancelled root to finish")
    c1 = counts()
    @assert ran[] == 1 && istaskfailed(t) && t.result isa CancellationRequest "ran $(ran[]), result $(t.result)"
    @assert delta(c0, c1, :f_first) == 1 && delta(c0, c1, :f_pops) == 1 && empty_queues()
    ok("c1: a marked root cancelled in its ring: stayed queued, ran once, failed with $(t.result)")

    # c2. Request work cancelled in flight: a marked root and its descendant, both parked in sleep();
    # the cancellation wakes both, each is re-inserted as R and runs once more, to fail.
    ran_kid = Threads.Atomic{Int}(0)
    kid_class = Ref{UInt8}(0xff)
    kidref = Ref{Task}()
    c0 = counts()
    t, src = marked_cancellable() do
        kidref[] = Threads.@spawn :default begin
            kid_class[] = P.sched_class(current_task())
            Threads.atomic_add!(ran_kid, 1)
            sleep(1000)
        end
        sleep(1000)
    end
    until(() -> parked(t) && isassigned(kidref) && parked(kidref[]), "root and kid to park")
    cancel!(src)
    until(() -> istaskdone(t) && istaskdone(kidref[]), "root and kid to finish")
    c1 = counts()
    @assert istaskfailed(t) && t.result isa CancellationRequest "root: $(t.result)"
    @assert istaskfailed(kidref[]) && kidref[].result isa CancellationRequest && ran_kid[] == 1 && kid_class[] == P.C_R
    @assert delta(c0, c1, :r_again) >= 2 "R re-inserts on wake: $(delta(c0, c1, :r_again))"
    @assert empty_queues()
    ok("c2: a marked root and its R child parked in sleep, cancelled: woken, re-inserted as R ($(delta(c0, c1, :r_again)) re-inserts), failed, each body once")

    # c3. A @sync whose marked children are cancelled, (i) parked and (ii) still in their rings.
    nk = 2ND
    ran = Threads.Atomic{Int}(0)
    t, src = marked_cancellable() do
        @sync for _ in 1:nk
            Base.@sync_add mspawn(() -> (Threads.atomic_add!(ran, 1); sleep(1000)))
        end
    end
    until(() -> ran[] == nk, "the $nk children to start")
    until(() -> parked(t), "the root to park in @sync")
    cancel!(src)
    until(() -> istaskdone(t), "the @sync root to finish")
    @assert istaskfailed(t) && ran[] == nk && empty_queues() "(i) ran $(ran[]) of $nk, root $(t.result)"
    go, _, ts = hold(ND - 1)
    ran = Threads.Atomic{Int}(0)
    spin = Threads.Atomic{Bool}(true)
    kids = Task[]
    t, src = marked_cancellable() do
        @sync begin
            for _ in 1:nk
                push!(kids, Base.@sync_add mspawn(() -> (Threads.atomic_add!(ran, 1); sleep(1000))))
            end
            while spin[]
                GC.safepoint()
            end
        end
    end
    until(() -> length(kids) == nk, "the root to spawn $nk children")
    sleep(0.05)
    @assert ran[] == 0 && P.f_queued() == nk "(ii) $(P.f_queued()) of $nk children in rings, $(ran[]) ran"
    cancel!(src)
    spin[] = false
    release(go, ts)
    until(() -> istaskdone(t) && all(istaskdone, kids), "the @sync root and its children to finish")
    @assert istaskfailed(t) && ran[] == nk && all(istaskfailed, kids) && empty_queues() "(ii) ran $(ran[]) of $nk"
    ok("c3: @sync with $nk marked children cancelled: (i) parked, (ii) still in rings; every child ran once and failed, queues empty")

    # The process's accounts: every ring insert popped, every R insert popped.
    c = counts()
    println(stderr, "master_checks: counts over the process: ", join(("$k $(getfield(c, k))" for k in
            (:f_first, :f_pops, :r_first, :r_again, :r_pops, :desc, :skips, :oyields, :stale, :demoted)), ", "))
    @assert c.f_first == c.f_pops "ring inserts $(c.f_first), ring pops $(c.f_pops)"
    @assert c.r_first + c.r_again == c.r_pops "R inserts $(c.r_first + c.r_again), R pops $(c.r_pops)"
    ok("process accounts: ring inserts = ring pops ($(c.f_first)), R inserts = R pops ($(c.r_pops))")
    println(stderr, "master_checks: all passed at threads ", ND, ",", Threads.nthreads(:interactive))
end

# ------------------------------------------------------------------------------------------------
# c4 and b's natural case: a task in a yield() loop (on a mark build, a marked root: R after its
# first yield) abandoned while it runs. A yield() puts it in a queue before it switches out, so an
# abandonment in that window leaves an abandoned task queued: a stale pop.
const PHASE = Ref("start")
const PENDING = Task[]
# A stall shows its state instead of hanging: the phase, the queues' depth (stock heaps of every
# pool; rings and R heaps on a mark build) and the churn tasks not done, then exit 3.
function watchdog(secs)
    Timer(secs) do _
        sh = [sum(h -> Int(@atomic :monotonic h.ntasks), P.heaps[i]; init = 0) for i in 1:length(P.heaps)]
        undone = [t for t in PENDING if !istaskdone(t)]
        println(stderr, "master_checks: WATCHDOG after $(secs) s in phase ", PHASE[], ": stock heaps per pool ", sh,
                MARK ? ", rings $(P.f_queued()), R heaps $(P.r_queued())" : "",
                ", churn tasks not done ", length(undone), " (started ", count(istaskstarted, undone), ")",
                isempty(undone) ? "" : ", first: tid $(Threads.threadid(undone[1])), sticky $(undone[1].sticky)" *
                    (MARK ? ", class $(P.sched_class(undone[1]))" : ""),
                V ? ", stale $(counts().stale)" : "")
        ccall(:_exit, Cvoid, (Cint,), 3)
    end
end

function abandon_mode(n)
    wd = watchdog(parse(Float64, get(ENV, "MASTER_CHECKS_WATCHDOG", "60")))
    c0 = V ? counts() : nothing
    committed = 0
    for i in 1:n
        PHASE[] = "victim $i"
        spins = Threads.Atomic{Int}(0)
        victim = mspawn(() -> (while true; Threads.atomic_add!(spins, 1); yield(); end))
        until(() -> spins[] > 10, "victim $i to spin")
        rescue() = (t = Task(() -> (while true; wait(); end)); t.sticky = false; t)
        while !Base.unsafe_abandon!(victim, rescue())
            yield()
        end
        committed += 1
        get(ENV, "MASTER_CHECKS_PROGRESS", "") == "1" && println(stderr, "master_checks: abandoned victim ", i)
        @assert istaskdone(victim) && victim.state === :abandoned "victim $i: $(victim.state)"
    end
    for r in 1:8
        PHASE[] = "churn round $r"
        empty!(PENDING)
        append!(PENDING, [Threads.@spawn :default nothing for _ in 1:4ND])
        foreach(wait, PENDING)
    end
    PHASE[] = "after churn"
    if MARK
        @assert empty_queues() "queues not empty after the abandonments: $(P.f_queued()), $(P.r_queued())"
    end
    stale = V ? delta(c0, counts(), :stale) : -1
    close(wd)
    ok("c4: $committed of $n abandonments committed, each victim :abandoned" *
       (MARK ? ", queues empty" : "") * (V ? ", stale pops $stale" : ""))
end

if isempty(ARGS)
    main_mode()
elseif ARGS[1] == "abandon"
    abandon_mode(parse(Int, ARGS[2]))
else
    error("master_checks: unknown mode $(ARGS[1])")
end
