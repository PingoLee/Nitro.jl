module NitroReviseExt

using Nitro
import Revise

function __init__()
    Nitro.register_revise_hooks!(;
        revise=() -> Revise.revise(),
        has_pending_revisions=() -> !isempty(Revise.revision_queue),
        wait_for_revision_event=_wait_for_revision_event,
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

end