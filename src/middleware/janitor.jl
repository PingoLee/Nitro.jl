module JanitorMiddleware

using Dates
using ...Types: require_fixed_period

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
# ── Why `AccessLog` does NOT use this (#190 asked for an explicit decision) ──
#
# `AccessLog`'s writer (src/middleware/access_log.jl) is EVENT-driven, not interval-driven: it
# parks on `take!` of a `Channel`, is stopped by `close`ing that channel rather than by a stop
# token, and because closing is immediate its `on_shutdown` can bound-WAIT for the drain
# (`timedwait(..., 5.0)`) where the two janitors here can only signal. `_janitor`'s whole contract
# is "sleep for `interval`, then do `work`"; generalising it to also cover a blocking-wait loop
# with a bounded shutdown would put two shapes back into the helper, which is the opposite of what
# extracting it bought. That divergence is legitimate, unlike the three copies this replaced.
#
# `AccessLog`'s optional RETENTION pruner (#159) is a different task and does use this: it is
# plain "sleep, then call the app's `prune(cutoff)`", a caller-supplied and possibly blocking
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
# `token` is per ACTIVATION, never a shared `running` flag -- see `_janitor`.
function _janitor_loop(work::Function, token::Ref{Bool}, interval::Period,
                       label::String, what::String)
    while token[]
        sleep(interval)
        # Re-check AFTER the sleep: `on_shutdown` may have fired while we were parked, and this is
        # the point a stale task from a previous activation leaves for good.
        token[] || break
        # The `try` is INSIDE the `while` on purpose. Hoisting it out turns one transient failure
        # into a permanently dead janitor -- silently, since nothing waits on this task -- in
        # components whose entire job is bounding memory. That is #169.
        try
            work()
        catch e
            # Rethrow guard, per the idiom in src/utilities/misc.jl and src/types.jl: a catch-all
            # that eats `InterruptException` makes Ctrl-C during a tick a no-op. The window is
            # narrow (the `sleep` is outside the `try`), but the guard is free -- and before #190
            # only one of the three copies had it, on the wrong one of the two.
            e isa InterruptException && rethrow()
            @error "Nitro.$label: $what failed" exception=(e, catch_backtrace())
        end
    end
    return nothing
end

"""
    _janitor(work, interval, label, what, kwname) -> (on_startup, on_shutdown)

Build the `LifecycleMiddleware` hook pair for a periodic background janitor that calls `work()`
every `interval`. Internal; the constructors that wrap it are `SessionMiddleware`, `SessionPruner`,
`FixedRateLimiter`, and `AccessLog` when given a retention `prune` (#159). Note `FixedRateLimiter`, not `RateLimiter`: the `:sliding_window` strategy
owns no background task and returns a `LifecycleMiddleware` with both hooks `nothing` (#172).

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
lifecycle middleware survives a `terminate()` (#82). `on_shutdown` cannot *wait* for the task — it
is parked in `sleep(interval)`, up to a whole interval from its next check — so a restart overlaps
the old task with the new activation. With one shared `running` flag the sequence was:

    on_shutdown : running[] = false ; janitor_task[] = nothing   (old task still sleeping)
    on_startup  : running[] = true  ; isnothing(janitor_task[]) -> spawns a SECOND task
    old task    : wakes, reads running[] == true, keeps looping

i.e. one leaked task per restart, unbounded, in components whose entire job is to bound resource
use. Each activation therefore gets its own `Ref{Bool}`, which a stale task is the only observer
of, and which `on_shutdown` already set `false`.

# The `finally`, which is the half #185 was about

If anything escapes the loop, the activation `Ref`s used to stay **populated**, so the next
`on_startup()` hit its own `isnothing(active[]) || return nothing` guard and returned early. The
janitor was then gone for the life of the process while the thing it bounds kept growing. The
`finally` below retires the activation so a later `on_startup()` can respawn.

It retires the activation only when it is still **ours** (`active[] === token`). A stale task
clearing the *current* activation's `Ref`s would let the next `on_startup` spawn a second live
task — the leak above, reached from the other side.

That check-and-clear races `on_startup`, so all three transitions take one `ReentrantLock`: the
task could read `active[] === token`, be descheduled while the serve thread runs
`on_shutdown(); on_startup()`, and then wipe the *new* activation's state. The lock costs nothing —
these run once per activation, never on the request path — and it fixes a second ordering hazard
for free: a task that dies immediately blocks in the retirement until `on_startup` has finished
assigning `janitor_task[]`, so that assignment can no longer clobber the retirement.
"""
function _janitor(work::Function, interval::Period, label::String, what::String, kwname::String)
    require_fixed_period("$label: $kwname", interval)

    # One lock over all three activation transitions -- see the docstring. Not on the request path.
    activation = ReentrantLock()
    active = Ref{Union{Ref{Bool},Nothing}}(nothing)
    janitor_task = Ref{Union{Task,Nothing}}(nothing)

    # Retire the activation this task owns, so a later `on_startup()` can respawn. A no-op unless
    # the slot is still ours: `on_shutdown` may have emptied it, or a newer activation may own it.
    retire! = function (token::Ref{Bool})
        lock(activation) do
            active[] === token || return nothing
            active[] = nothing
            janitor_task[] = nothing
            return nothing
        end
    end

    on_startup = function ()
        lock(activation) do
            isnothing(active[]) || return nothing      # idempotent across restarts
            token = Ref(true)
            active[] = token
            janitor_task[] = errormonitor(Threads.@spawn try
                _janitor_loop(work, token, interval, label, what)
            finally
                retire!(token)
            end)
            return janitor_task[]
        end
    end

    # Signalling is all this can do; blocking `terminate` for up to a whole interval would be worse
    # than letting the task drain.
    on_shutdown = function ()
        lock(activation) do
            token = active[]
            isnothing(token) || (token[] = false)
            stopped = janitor_task[]
            active[] = nothing
            janitor_task[] = nothing
            return stopped
        end
    end

    return (on_startup, on_shutdown)
end

end # module JanitorMiddleware
