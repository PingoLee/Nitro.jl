# #618, the native mark: the delicate points of the port that the harness cells do not reach, on a
# build of this directory's patch. Every check prints one "native_checks: ok:" line or aborts.
#
#   <julia> --threads=8,1 bench/julia/native_checks.jl   the default layout (one :interactive thread)
#   <julia> --threads=8,2 bench/julia/native_checks.jl   a marked :interactive task reaches the multiqueue
#   <julia> --threads=1   bench/julia/native_checks.jl   one-thread pools: the mark means nothing
#
# On the validation build (`Base.Partr.SCHED_VALIDATE`) the counts are checked too; on the timed build
# only what needs no counter. Run it in a fresh process: the first check is the state the sysimage
# left, before anything is marked.
const P = Base.Partr
hasfield(Task, :sched_class) || error("native_checks: this julia has no native mark (Task.sched_class)")
const V = isdefined(P, :SCHED_VALIDATE) && P.SCHED_VALIDATE
# The fifth version (#618, session 10): an opt-out class (C_STOCK), a class written only on a `:default`
# task, the weight in thousandths set by `set_fair_weight!`, and no one-time init.
const V5 = isdefined(P, :C_STOCK)
# The PR candidate has no validation code: neither the switch nor the queue-depth probes. These read
# the same state from the structures themselves.
fair_on() = @atomic :acquire P.fl.on
f_queued() = isdefined(P, :f_queued) ? P.f_queued() : sum((@atomic :monotonic q.n for q in P.rings[P.f_tpid + 1]); init = 0)
r_queued() = isdefined(P, :r_queued) ? P.r_queued() : sum((@atomic :monotonic h.ntasks for h in P.r_heaps[P.f_tpid + 1]); init = 0)
ok(msg) = println(stderr, "native_checks: ok: ", msg)
const ND, NI = Threads.nthreads(:default), Threads.nthreads(:interactive)
println(stderr, "native_checks: ", VERSION, " ", Base.GIT_VERSION_INFO.commit_short, V ? " (validation build)" : "",
        ", threads ", ND, ",", NI)

# The sysimage: Partr's new structures are saved with it, so they must be empty and unsized there, as
# stock's heaps are, the flag unset, the init not run and the cap at its default.
@assert !fair_on() "the pool flag is set before anything is marked"
@assert all(isempty, P.rings) "rings sized in the image: $(length.(P.rings))"
@assert all(isempty, P.r_heaps) "R heaps sized in the image: $(length.(P.r_heaps))"
@assert isempty(P.sstates[1]) "accounts sized in the image: $(length(P.sstates[1]))"
if V5
    @assert !isdefined(P, :fair_init!) "v5 has no one-time init"
    @assert (@atomic P.fp.cap) == P.DEFAULT_CAP && (@atomic P.fp.w) == 500 "the parameters are not their defaults"
else
    @assert !(@atomic P.fp.inited) "fair_init! ran before anything called it"
    @assert (@atomic P.fp.cap) == P.DEFAULT_CAP && (@atomic P.fp.w4) == 2 "the parameters are not their defaults"
end
ok("sysimage state: flag unset, rings, R heaps and accounts unsized, init not run, cap and weight at their defaults")

# `jl_new_task` allocates without zeroing: every new task must still start unclassed, including
# tasks whose memory last held a marked task.
function fresh_classes(n)
    for _ in 1:n
        t = Task(() -> nothing)
        P.sched_class(t) == 0x00 || return false
    end
    return true
end
@assert fresh_classes(10_000)
marked = [Task(() -> nothing) for _ in 1:10_000]
foreach(t -> P.set_sched_class!(t, P.C_F), marked)
marked = nothing
GC.gc(); GC.gc()
@assert fresh_classes(100_000) "a new task started with a class: the byte is not zeroed"
ok("a new task's class is 0, also on memory freed from 10,000 marked tasks")

# Unmarked work never sets the flag.
@assert sum(fetch.([Threads.@spawn :default sum(1:10) for _ in 1:2000])) == 2000 * 55
@assert !fair_on() "the flag was set by unmarked spawns"
ok("2,000 unmarked spawns leave the flag unset")

# The option. A started task cannot be marked.
t = Threads.@spawn 1 + 1
wait(t)
err = try; Threads._spawn_set_fair(t, true); nothing; catch e; e; end
@assert err isa ArgumentError "marking a started task did not throw"
@assert fetch(Threads.@spawn :default fair=false 2) == 2 && !fair_on()
c0 = V ? P.sched_counts() : nothing
x = 40
@assert fetch(Threads.@spawn :default fair=(x > 0) $x + 2) == 42
V5 || @assert (@atomic P.fp.inited) "the first fair=true spawn did not run the init"
V5 && V && @assert (@atomic P.vp.inited) "the first fair=true spawn did not run the validation's init"
println(stderr, "native_checks: cap ", @atomic(P.fp.cap), " clock units = 10 ms (", @atomic(P.fp.cap) / 10, " per ms), ",
        "TSC clocksource ", isdefined(P, :vp) ? @atomic(P.vp.tsc) : hasfield(typeof(P.fp), :tsc) ? @atomic(P.fp.tsc) : "-",
        ", weight ", V5 ? string(@atomic(P.fp.w), "/1000") : string(@atomic(P.fp.w4), "/4"))
if ND >= 2
    @assert fair_on() "a marked :default spawn on a pool of $ND threads did not set the flag"
    @assert length(P.rings[2]) == 2 * ND "$(length(P.rings[2])) rings for $ND threads"
    @assert length(P.sstates[1]) >= Threads.maxthreadid() "accounts not sized before the flag"
    V && (d = P.sched_counts(); @assert d.f_first - c0.f_first == 1 && d.f_pops - c0.f_pops == 1 "F counts $(d.f_first - c0.f_first), $(d.f_pops - c0.f_pops)")
    ok("fair=<expr> marks; the first marked insert sized $(length(P.rings[2])) rings and the accounts, then set the flag")
else
    # A pool of one thread: enq_work sends every task to the thread's own queue, never to the
    # multiqueue, so nothing is sized and the flag stays unset.
    @assert !fair_on() && isempty(P.rings[2]) "a one-thread :default pool reached the rings"
    ok("one-thread :default pool: the marked task ran from the thread's own queue; flag unset, nothing sized")
end

# A marked :interactive task. The class is set whatever the pool, as the patch's `multiq_mark!` sets
# its bit; the insert decides what it means. With one :interactive thread the task never reaches the
# multiqueue (enq_work), keeps F, and its :default children are R once the flag is set. With two or
# more it reaches `multiq_insert`, which sends it down stock's path with its class cleared (demoted),
# so its children are L.
function interactive_parent()
    t = Task(() -> begin
        mine = P.sched_class(current_task())
        child = Threads.@spawn :default P.sched_class(current_task())
        (mine, fetch(child))
    end)
    t.sticky = false
    Threads._spawn_set_thrpool(t, :interactive)
    Threads._spawn_set_fair(t, true)
    schedule(t)
    return fetch(t)
end
if NI >= 1 && V5
    # v5: `_spawn_set_fair` writes a class only on a `:default` task, so a marked :interactive task has
    # none at every layout, its :default child none, and nothing is demoted at the insert.
    c0 = V ? P.sched_counts() : nothing
    mine, child = interactive_parent()
    @assert mine == P.C_NONE "v5: a marked :interactive task ($NI threads) ran with class $mine"
    @assert child == P.C_NONE "v5: its :default child ran with class $child"
    V && (d = P.sched_counts(); @assert d.demoted == c0.demoted "v5: a demotion was counted")
    ok("v5: marked :interactive task ($NI threads): no class written, its :default child unclassed, nothing demoted")
elseif NI >= 1
    c0 = V ? P.sched_counts() : nothing
    mine, child = interactive_parent()
    if NI == 1
        @assert mine == P.C_F "a marked task of a one-thread :interactive pool ran with class $mine"
        want = fair_on() ? P.C_R : P.C_NONE
        @assert child == want "its :default child ran with class $child, expected $want"
        ok("marked :interactive task (1 thread): ran with F, its :default child with $(child == P.C_R ? "R" : "no class")")
    else
        @assert mine == P.C_NONE "a marked :interactive task on $NI threads was not demoted (class $mine)"
        @assert child == P.C_NONE "the demoted task's :default child ran with class $child"
        V && (d = P.sched_counts(); @assert d.demoted - c0.demoted >= 1 "the demotion was not counted")
        ok("marked :interactive task ($NI threads): demoted to stock's path, class cleared, its child unclassed")
    end
end

# v5's opt-out: under a marked root, `fair=false` gives a task that takes stock's path once (counted),
# with no class from then on, as its own child; a plain spawn beside it is still the root's R work.
if V5
    c0 = V ? P.sched_counts() : nothing
    r = fetch(Threads.@spawn fair=true begin
        o = Threads.@spawn fair=false (P.sched_class(current_task()),
                                       fetch(Threads.@spawn P.sched_class(current_task())))
        p = Threads.@spawn P.sched_class(current_task())
        (fetch(o)..., fetch(p))
    end)
    want_o = ND >= 2 ? P.C_NONE : P.C_STOCK
    @assert r[1] == want_o && r[2] == P.C_NONE "v5: the opted-out task ran with $(r[1]), its child with $(r[2])"
    @assert r[3] == (ND >= 2 ? P.C_R : P.C_NONE) "v5: the plain sibling ran with $(r[3])"
    V && ND >= 2 && (d = P.sched_counts(); @assert d.opt_out - c0.opt_out == 1 "v5: opt_out counted $(d.opt_out - c0.opt_out)")
    ok("v5: fair=false under a marked root: the task ran with $(Int(r[1])), its child with 0, the plain sibling with $(Int(r[3]))")
end

# A sticky marked task never reaches the multiqueue: the mark changes nothing about where it runs.
# (v5: a hand-built task starts in its creator's pool, and a class is written only on a `:default` task; the
# main task is on `:interactive` when that pool has a thread, so there the mark writes nothing.)
st = Task(() -> (Threads.threadid(), P.sched_class(current_task())))
st_default = ccall(:jl_get_task_threadpoolid, Int8, (Any,), st) == P.f_tpid
Threads._spawn_set_fair(st, true)
schedule(st)
tid, cls = fetch(st)
want_st = V5 && !st_default ? P.C_NONE : P.C_F
@assert tid == Threads.threadid() && cls == want_st "a sticky marked task ran on tid $tid with class $cls, expected $want_st"
ok("a sticky marked task ran on its own thread (tid $tid) from its queue, class $(Int(cls))" *
   (V5 && !st_default ? " (v5: built in a pool other than :default, so the mark wrote nothing)" : " kept"))

# No queue keeps a task alive: a ring slot and an R-heap slot are unset when popped.
function weak_tasks()
    root = Threads.@spawn :default fair=true begin
        kid = Threads.@spawn :default (P.sched_class(current_task()), 7)
        (P.sched_class(current_task()), fetch(kid), WeakRef(kid))
    end
    rc, (kc, _), wk = fetch(root)
    return rc, kc, WeakRef(root), wk
end
if ND >= 2
    rc, kc, wr, wk = weak_tasks()
    @assert rc == P.C_F && kc == P.C_R "root ran with $rc, its child with $kc"
    # Every thread runs something else first, so no thread still points at either task as the last
    # one it ran.
    for _ in 1:4
        foreach(wait, [Threads.@spawn :default sum(1:10) for _ in 1:64])
        GC.gc(true)
    end
    # On master (1.15-DEV) a task the main task fetched stays reachable after GC on the control too,
    # through something outside Partr (not identified), so reachability alone cannot convict a
    # slot: look in every ring slot and R-heap slot, assigned or not past the live count.
    in_slot(t) = t !== nothing &&
        (any(q -> any(i -> isassigned(q.tasks, i) && q.tasks[i] === t, eachindex(q.tasks)), P.rings[P.f_tpid + 1]) ||
         any(h -> any(i -> isassigned(h.tasks, i) && h.tasks[i] === t, eachindex(h.tasks)), P.r_heaps[P.f_tpid + 1]))
    r, k = wr.value, wk.value
    @assert !in_slot(r) "a finished root is still held by a ring or R-heap slot"
    @assert !in_slot(k) "a finished descendant is still held by a ring or R-heap slot"
    VERSION < v"1.15-" && @assert r === nothing "a finished root is still reachable"
    VERSION < v"1.15-" && @assert k === nothing "a finished descendant is still reachable"
    r = k = nothing
    @assert f_queued() == 0 && r_queued() == 0
    ok("a finished root (from a ring) and its descendant (from an R heap): no slot holds them; collected: root " *
       string(wr.value === nothing) * ", descendant " * string(wk.value === nothing))
end

V && println(stderr, "native_checks: counts over the process: ",
             join(("$k $(getfield(P.sched_counts(), k))" for k in (:f_first, :desc, :r_first, :r_again, :demoted,
                                                                      :f_pops, :r_pops, :foreign, :stock_bit, :stamps, :gpops)), ", "))
println(stderr, "native_checks: all passed at threads ", ND, ",", NI)
