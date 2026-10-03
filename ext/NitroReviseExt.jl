module NitroReviseExt

using Nitro
import Revise

function __init__()
    Nitro.register_revise_hooks!(;
        revise=() -> Revise.revise(),
        has_pending_revisions=() -> !isempty(Revise.revision_queue),
        wait_for_revision_event=_wait_for_revision_event,
        cancel_revision_wait=_cancel_revision_wait,
    )
end

# `wait`, then `reset` -- the order Revise's own `entr` uses. Up to at least 3.14.2,
# `Revise.revision_event` is a `Base.Event()` WITHOUT autoreset, and only `entr` ever resets it, so
# after the first save every `wait` returned at once and the `revise=:eager` watcher spun -- one
# save, ~165 revisions and 330 log lines in 3 s on 3.13.2 (#372). `[compat]` still admits those
# versions. Later ones autoreset, where this `reset` is redundant but harmless. On every version a
# notify that lands between the two is cleared, and that loses no work: the `revise()` that follows
# drains the whole queue, that file included.
function _wait_for_revision_event()
    wait(Revise.revision_event)
    reset(Revise.revision_event)
    return nothing
end

# Wake `task` out of `_wait_for_revision_event` without notifying `Revise.revision_event` (#427).
#
# Notifying would be the obvious way, and it is wrong: from 3.14.5 the event autoresets, so a
# notify wakes ONE waiter, which may be `entr` or a newer watcher rather than `task`. Before that
# fix, `terminate` only set the watcher's flag. The watcher stayed queued on the event, and after
# a restart it was first in line, so it took the next save and exited without revising it.
#
# This throws `ReviseWaitCancelled` into `task` instead. It relies on two Base internals, checked
# against Julia 1.12.7 (`base/task.jl`, `base/condition.jl`, `base/lock.jl`):
#
#   * `Base.Event` parks its waiters on `event.notify`, a `GenericCondition`, and `notify(event)`
#     takes that condition's lock before it dequeues one. Under the same lock, then,
#     `task.queue === waitq` means `task` is parked HERE, and no `notify` can wake it while we
#     hold the lock. Without that check, `schedule` could land on a task that is running
#     `revise()`, which is the interrupt injection #127 forbids. One waker does not take the
#     lock: a SIGINT thrown into the parked task (`julia -t 1`, when it parked last on thread 1).
#     Until its `catch` dequeues it, the check still passes, so a `close` at that same instant
#     could schedule a task that is already running. Base's own `notify` has the same window,
#     and it needs a Ctrl-C and a `terminate` racing within microseconds, so it is left as is.
#   * `schedule(task, exc; error = true)` removes `task` from its queue itself, and
#     `wait(::GenericCondition)` relocks in its `finally`, so the `wait(::Event)` frame unwinds
#     normally and the exception surfaces from `_wait_for_revision_event`.
#
# Returns whether `task` was parked here. `false` is not a failure: the caller retries until the
# watcher either parks or sees its flag and exits.
function _cancel_revision_wait(task::Task)
    cond = Revise.revision_event.notify
    lock(cond)
    try
        task.queue === cond.waitq || return false
        schedule(task, Nitro.ReviseWaitCancelled(); error = true)
        return true
    finally
        unlock(cond)
    end
end

end
