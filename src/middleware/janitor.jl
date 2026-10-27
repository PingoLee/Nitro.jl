module JanitorMiddleware

using Dates
using ...Types: require_fixed_period
# A tick runs work the caller supplied -- a session store's prune, `AccessLog`'s retention
# `prune` -- and a database error keeps the row in a field `showerror` leaves out. So a failed
# tick logs `loggable(e)`, never `e` (#658).
using ...Errors: loggable

# ── The one background-janitor discipline (#190) ───────────────────────────────────────────
#
# Nitro had THREE hand-rolled janitors and they had already drifted: only `FixedRateLimiter`'s
# sweep rethrew `InterruptException` (#169), while `SessionMiddleware`'s prune -- the one whose
# work is a CALLER-supplied store, i.e. a blocking SQL DELETE for `PormGSessionStore` and
# therefore far more interruptible -- was the copy still missing it. All of them also stranded
# themselves the same way (see `_janitor`). Three copies, one bug, three places to fix it.
#
# Everything below is owned HERE and nowhere else. A caller supplies its `work` and its labels;
# it does not get to re-decide the spawn, the token, the `try` placement, or the reset.
#
# ── Why `Threads.@spawn` and not `@async` ──
#
# Two independent routes to the same answer, and there is no janitor left in Nitro that
# legitimately wants a sticky task:
#
#   * The SESSION prune calls `cleanup_expired_sessions!` on a store the CALLER supplied, and for
#     `PormGSessionStore` that is a blocking SQL DELETE. Per src/Workers/api.jl, `@async` is
#     acceptable only for a task that runs no user code, so a janitor over a user store must not
#     share a thread with request handlers.
#   * The RATE LIMITER sweep (#169) runs no user code, but its store is unbounded and only that
#     sweep reaps it -- so under exactly the rotating-source-address traffic #22 exists to bound it
#     is O(total buckets) of CPU work, and `@async` would pin it for life to the thread that ran
#     `startserver`, which is also serving requests.
#
# Migration is free by the criterion in src/Workers/api.jl: nothing injects into these tasks, every
# lock involved is a `ReentrantLock` (which keys on `current_task()`, so a migrating task keeps what
# it holds), and there is no `Threads.threadid()` or task-local state anywhere in the work.
#
# `errormonitor` because NOTHING waits on these tasks: without it a throw is stored in the `Task`
# and never surfaces -- the janitor dies mute and the thing it bounds stops being reaped for the
# life of the process.
#
# ── Why `AccessLog`'s WRITER does NOT use this (#190 asked for an explicit decision) ──
#
# `AccessLog`'s writer (src/middleware/access_log.jl) is EVENT-driven, not interval-driven: it
# parks on `take!` of a `Channel`, is stopped by `close`ing that channel rather than by a stop
# token, and because closing is immediate its `on_shutdown` can bound-WAIT for the drain
# (`timedwait(..., 5.0)`) where the janitors here only signal and wake. `_janitor`'s whole contract
# is "wait `interval`, then do `work`"; generalising it to also cover a blocking-wait loop
# with a bounded shutdown would put two shapes back into the helper, which is the opposite of what
# extracting it bought. That divergence is legitimate, unlike the three copies this replaced.
#
# `AccessLog`'s optional RETENTION pruner (#159) is a different task and does use this: it is
# plain "wait, then call the app's `prune(cutoff)`", a caller-supplied and possibly blocking
# DELETE -- the session prune's shape exactly. Only the writer stays out.

# The loop, named rather than written inline into the `Threads.@spawn` in `_janitor`.
#
# Named for two reasons, both load-bearing. (1) The `try` placement is the whole point of #169, and
# a named function lets a test drive the loop over a deliberately-failing `work` without going
# through a constructor -- which matters because a middleware's real work closes over state (the
# rate limiter's stripes, a session store) that is closure-local and cannot be reached any other
# way. (2) It keeps `_janitor`'s `on_startup` short enough that the spawn's rationale stays next to
# the spawn.
#
# `token` is per ACTIVATION, never a shared `running` flag -- see `_janitor`. So is `wake`, which
# `on_shutdown` notifies after clearing the token. A caller that drives the loop directly and
# passes no `wake` stops it by clearing the token, and the loop sees that at its next tick.
#
# ── The park (#772) ──
#
# Between ticks the loop parks once on `wake`, which a `Timer` callback notifies after `interval`
# (concurrency §3, the retention scheduler's shape). It used to `sleep(interval)`, and that had two
# consequences. `on_shutdown` could not wake it, so a stopped janitor outlived its server by up to
# a whole interval: ten minutes for the rate limiter's default sweep, an hour for the session
# prune's. And a `sleep` is a wait on the `Timer` itself, which throws `EOFError` when the `Timer`
# is closed under it. Process exit runs every finalizer, reachable objects' included, and a
# `Timer`'s wakes its waiters exactly that way. So a janitor still parked at exit died there, on
# another thread, under `errormonitor`, which then compiled code to print the error while the
# process was being torn down. That could print a spurious `Unhandled Task ERROR` and crash the
# process in LLVM (#772). A closed callback `Timer` throws nothing: its callback task just ends,
# and the janitor stays parked on the `Event` until the process is gone.
#
# ── An interrupt (#369) ──
#
# The outer `try` ends the loop NORMALLY on an `InterruptException`, with one `@warn`, wherever it
# lands -- in the park or, through the per-tick rethrow, in `work`. It is the same decision the
# Workers retention scheduler records next to `_cleanup_scheduler_loop` (src/Workers/api.jl), and
# the reasoning there is canonical. In short: with `exit_on_sigint(false)` Julia throws SIGINT into
# whichever task parked last on thread 1. This task is `Threads.@spawn`, so under the default
# layout (since 1.12, thread 1 is the interactive thread) it never gets one. Under `-t 1` it
# can, and under `-t N,0`, where thread 1 is a default thread (#491).
# Rethrowing then only killed the janitor with an `Unhandled Task ERROR` while the server kept
# running. Swallowing and looping would re-park it as the last task on thread 1 and eat every
# later press too. Stopping frees the next press for the server, and `_janitor`'s `finally`
# still retires the activation, so a later `on_startup()` respawns it.
function _janitor_loop(work::Function, token::Ref{Bool}, interval::Period,
                       label::String, what::String; wake::Base.Event = Base.Event(true))
    seconds = Dates.toms(interval) / 1000
    try
        while token[]
            _park(wake, seconds)
            # Re-check AFTER the park: `on_shutdown` may have fired while we were parked, and this
            # is the point a stale task from a previous activation leaves for good.
            token[] || break
            # The `try` is INSIDE the `while` on purpose. Hoisting it out turns one transient
            # failure into a permanently dead janitor -- silently, since nothing waits on this
            # task -- in components whose entire job is bounding memory. That is #169.
            try
                work()
            catch e
                # Rethrow guard, per the idiom in src/utilities/misc.jl and src/types.jl: a
                # catch-all that eats `InterruptException` makes Ctrl-C during a tick a no-op.
                # It now lands in the outer handler below (#369), which stops the loop rather than
                # looping on -- before #190 only one of the three copies had this guard at all.
                e isa InterruptException && rethrow()
                @error "Nitro.$label: $what failed" exception=(loggable(e), catch_backtrace())
            end
        end
    catch e
        e isa InterruptException || rethrow()
        @warn "Nitro.$label: an interrupt (Ctrl-C) reached the $what task instead of the server. " *
              "It has stopped until the server is started again. Press Ctrl-C again to stop the server. " *
              "Outside a REPL, that press can end the process without running its shutdown hooks."
    end
    return nothing
end

# One tick's park: until the `Timer` fires or `on_shutdown` notifies. `wake` autoresets, so a
# notify that lands before the `wait` is held, not lost. The `Timer` inherits this task's pool and
# non-stickiness (#369), and it is closed on every path, so no tick leaves one behind.
function _park(wake::Base.Event, seconds::Float64)
    timer = Timer(_ -> notify(wake), seconds)
    try
        wait(wake)
    finally
        close(timer)
    end
    return nothing
end

# One activation's stop token and the `Event` its task parks on. Concrete, and the token a
# `Base.RefValue{Bool}` rather than a `Ref{Bool}`: `Ref{T}` is abstract, so the stop write in
# `on_shutdown` was a dynamic `setindex!`, which a trimmed image cannot make (#571, #719).
struct _Activation
    token :: Base.RefValue{Bool}
    wake  :: Base.Event
end

"""
    _janitor(work, interval, label, what, kwname) -> (on_startup, on_shutdown)

Build the `LifecycleMiddleware` hook pair for a periodic background janitor that calls `work()`
every `interval`. Internal; the constructors that wrap it are `SessionMiddleware`, `SessionPruner`,
`FixedRateLimiter`, and `AccessLog` when given a retention `prune` (#159). Note
`FixedRateLimiter`, not `RateLimiter`: the `:sliding_window` strategy owns no background task and
returns a `LifecycleMiddleware` with both hooks `nothing` (#172).

- `work`     — a zero-argument function run once per tick. A throw costs one tick, not the janitor.
- `interval` — validated by `require_fixed_period` **here, at construction**, so a calendar period
               fails on the caller's own constructor call rather than killing a background task on
               its first tick.
- `label`    — the caller's user-facing name, e.g. `"SessionMiddleware"`. Used in log messages as
               `Nitro.\$label`.
- `what`     — what the tick does, e.g. `"session prune"`. Logged as `Nitro.\$label: \$what failed`.
- `kwname`   — the caller's OWN keyword name for `interval`, e.g. `"prune_interval"`. `SessionPruner`
               spells it `interval` and `SessionMiddleware` spells it `prune_interval`; an error
               naming a keyword the caller's function does not have sends them hunting.

`on_startup` returns the `Task` it spawned, or `nothing` if one was already running. `on_shutdown`
returns the `Task` it signalled, or `nothing`. `startup`/`shutdown` (src/types.jl) discard both, but
tests call the hooks directly to get task handles — that is the only way to observe that a stale
activation's task actually exits. **Keep these return values.**

# Per-activation state, and why it is not one shared flag

The hooks must be idempotent across a `serve(); terminate(); serve()` cycle, because route-owned
lifecycle middleware survives a `terminate()` (#82). `on_shutdown` wakes a parked task but does not
*wait* for it, because a task in the middle of a tick finishes its `work` first, and that can be a
caller's blocking DELETE. So a restart can overlap the old task with the new activation. With one
shared `running` flag the sequence was:

    on_shutdown : running[] = false ; janitor_task[] = nothing   (old task still in its tick)
    on_startup  : running[] = true  ; isnothing(janitor_task[]) -> spawns a SECOND task
    old task    : finishes the tick, reads running[] == true, keeps looping

i.e. one leaked task per restart, unbounded, in components whose entire job is to bound resource
use. Each activation therefore gets its own token, which a stale task is the only observer of, and
which `on_shutdown` already set `false`, and its own `Event`, so the wake reaches only that task.

# Shutdown ends a parked task at once (#772)

Before #772 the task parked in `sleep(interval)`, which nothing could wake, so it outlived
`on_shutdown` by up to a whole interval, and a process that exited in that window killed it with
an `EOFError` (see *The park* above `_janitor_loop`). Now `on_shutdown` notifies the activation's
`Event` and an idle task returns at once, so a `terminate()` leaves no janitor behind.

# The `finally`, which is the half #185 was about

If anything escapes the loop, the activation `Ref`s used to stay **populated**, so the next
`on_startup()` hit its own `isnothing(active[]) || return nothing` guard and returned early. The
janitor was then gone for the life of the process while the thing it bounds kept growing. The
`finally` below retires the activation so a later `on_startup()` can respawn.

It retires the activation only when it is still **ours** (`active[] === mine`). A stale task
clearing the *current* activation's `Ref`s would let the next `on_startup` spawn a second live
task — the leak above, reached from the other side.

That check-and-clear races `on_startup`, so all three transitions take one `ReentrantLock`: the
task could read `active[] === mine`, be descheduled while the serve thread runs
`on_shutdown(); on_startup()`, and then wipe the *new* activation's state. The lock costs nothing —
these run once per activation, never on the request path — and it fixes a second ordering hazard
for free: a task that dies immediately blocks in the retirement until `on_startup` has finished
assigning `janitor_task[]`, so that assignment can no longer clobber the retirement.
"""
function _janitor(work::Function, interval::Period, label::String, what::String, kwname::String)
    require_fixed_period("$label: $kwname", interval)

    # One lock over all three activation transitions -- see the docstring. Not on the request path.
    activation = ReentrantLock()
    active = Ref{Union{_Activation,Nothing}}(nothing)
    janitor_task = Ref{Union{Task,Nothing}}(nothing)

    # Retire the activation this task owns, so a later `on_startup()` can respawn. A no-op unless
    # the slot is still ours: `on_shutdown` may have emptied it, or a newer activation may own it.
    retire! = function (mine::_Activation)
        lock(activation) do
            active[] === mine || return nothing
            active[] = nothing
            janitor_task[] = nothing
            return nothing
        end
    end

    on_startup = function ()
        lock(activation) do
            isnothing(active[]) || return nothing      # idempotent across restarts
            mine = _Activation(Ref(true), Base.Event(true))
            active[] = mine
            janitor_task[] = errormonitor(Threads.@spawn try
                _janitor_loop(work, mine.token, interval, label, what; wake = mine.wake)
            finally
                retire!(mine)
            end)
            return janitor_task[]
        end
    end

    # Signal and wake, never wait: a tick may be in the middle of a caller's blocking `work`, a
    # session store's DELETE, and `terminate` must not sit behind it. A parked task ends at once.
    on_shutdown = function ()
        lock(activation) do
            mine = active[]
            if !isnothing(mine)
                mine.token[] = false
                notify(mine.wake)
            end
            stopped = janitor_task[]
            active[] = nothing
            janitor_task[] = nothing
            return stopped
        end
    end

    return (on_startup, on_shutdown)
end

end # module JanitorMiddleware
