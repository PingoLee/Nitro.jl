# #618, the candidate's second version: the checks of its fixes that need a running build. Each mode
# prints one "v2_checks: ok:" line and exits 0, or prints "v2_checks: FAIL:" and exits 1. Correctness
# runs, never timed.
#
#   <julia> --threads=72 v2_checks.jl wake64 busy    a marked root pinned by hand to a :default thread
#   <julia> --threads=72 v2_checks.jl wake64 sleep   with an id above 64 must run once, on its owner:
#   <julia> --threads=72 v2_checks.jl wake64 ring    `busy`, its owner busy for 200 ms when it is
#                                                    queued; `sleep`, its owner asleep. Neither can
#                                                    test the ring pop's wake: `schedule` (enq_work)
#                                                    wakes a pinned task's owner itself (#58689).
#                                                    `ring` puts the task in a ring with
#                                                    `Partr.multiq_insert`, as enq_work does but
#                                                    without its wake (the case of an owner that
#                                                    went back to sleep), and wakes one other
#                                                    :default thread: that thread passes the task
#                                                    over, and only its wake can reach the owner.
#   <julia> --threads=4  v2_checks.jl init2          two tasks mark at once, in a fresh process: both
#                                                    return, with the parameters set
const P = Base.Partr
hasfield(Task, :sched_class) || error("v2_checks: this julia has no native mark (Task.sched_class)")
ok(msg) = (println(stderr, "v2_checks: ok: ", msg); flush(stderr))
function fail(msg)
    println(stderr, "v2_checks: FAIL: ", msg); flush(stderr)
    ccall(:_exit, Cvoid, (Cint,), 1)   # a task may be stuck in a ring: do not wait for it at exit
end
println(stderr, "v2_checks: ", VERSION, " ", Base.GIT_VERSION_INFO.commit_short, ", threads ",
        Threads.nthreads(:default), ",", Threads.nthreads(:interactive), ", ", join(ARGS, " "))

function marked_task(f)
    t = Task(f)
    t.sticky = false
    Threads._spawn_set_thrpool(t, :default)
    Threads._spawn_set_fair(t, true)
    return t
end
function wait_for(f, secs)
    t0 = time()
    while !f()
        time() - t0 > secs && return false
        sleep(0.001)
    end
    return true
end

function wake64(form)
    tids = Threads.threadpooltids(:default)
    k = last(tids)
    k > 65 || error("v2_checks: needs a :default thread with an id above 64 (got $k): run at --threads=72")
    # The flag set and the rings sized: one marked task first.
    fetch(Threads.@spawn :default fair=true 1) == 1 || error("the first marked task")
    go = Threads.Atomic{Bool}(true)
    spinner = nothing
    if form == "busy"
        up = Threads.Atomic{Bool}(false)
        spinner = Task(() -> begin
            up[] = true
            t0 = time_ns()
            while time_ns() - t0 < 200_000_000
                GC.safepoint()
            end
        end)
        spinner.sticky = true
        ccall(:jl_set_task_tid, Cint, (Any, Cint), spinner, k - 1) == 1 || error("could not pin the spinner")
        schedule(spinner)
        wait_for(() -> up[], 10) || error("the spinner did not start")
    else
        sleep(1.0)   # every idle thread goes to sleep, the owner included
    end
    ran = Threads.Atomic{Int}(0)
    on = Threads.Atomic{Int}(0)
    t = marked_task(() -> (Threads.atomic_add!(ran, 1); on[] = Threads.threadid()))
    ccall(:jl_set_task_tid, Cint, (Any, Cint), t, k - 1) == 1 || error("could not pin the marked task")
    t0 = time()
    if form == "ring"
        P.multiq_insert(t, t.priority)
        ccall(:jl_wakeup_thread, Cint, (Int16,), Int16(first(tids) - 1))
    else
        schedule(t)
    end
    done = wait_for(() -> istaskdone(t), 10)
    dt = time() - t0
    done || fail("wake64 $form: the marked task pinned to thread $k did not run in 10 s (ran $(ran[]))")
    spinner === nothing || wait(spinner)
    ran[] == 1 && on[] == k || fail("wake64 $form: ran $(ran[]) times, on thread $(on[]), owner $k")
    ok("wake64 $form: a marked root pinned to thread $k ($(form == "busy" ? "busy 200 ms" : form == "sleep" ? "asleep" : "asleep, queued without enq_work's wake, thread $(first(tids)) woken")) ran once, on its owner, $(round(1000dt; digits = 1)) ms after it was queued")
end

function init2()
    (@atomic P.fp.inited) && error("v2_checks: init2 needs a fresh process (the parameters are already set)")
    start = Threads.Atomic{Bool}(false)
    ready = Threads.Atomic{Int}(0)
    ts = [Threads.@spawn :default begin
              Threads.atomic_add!(ready, 1)
              while !start[]
                  GC.safepoint()
              end
              t0 = time_ns()
              Threads._spawn_set_fair(Task(() -> nothing), true)
              (time_ns() - t0) / 1e6
          end for _ in 1:2]
    wait_for(() -> ready[] == 2, 10) || error("the two tasks did not start")
    start[] = true
    ms = fetch.(ts)
    inited, cap, w4 = (@atomic P.fp.inited), (@atomic P.fp.cap), (@atomic P.fp.w4)
    inited && cap > 0 && w4 == 2 || fail("init2: inited $inited, cap $cap, w4 $w4")
    ok("init2: two tasks marked at once, both returned (after $(round(ms[1]; digits = 2)) and $(round(ms[2]; digits = 2)) ms), inited, cap $cap, weight $w4/4")
end

mode = get(ARGS, 1, "")
if mode == "wake64"
    wake64(get(ARGS, 2, "sleep"))
elseif mode == "init2"
    init2()
else
    error("v2_checks: the mode is wake64 busy|sleep or init2")
end
