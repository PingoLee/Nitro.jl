module NitroReviseExt

using Nitro
import Revise

function __init__()
    Nitro.register_revise_hooks!(;
        revise=() -> Revise.revise(),
        has_pending_revisions=() -> !isempty(Revise.revision_queue),
        wait_for_revision_event=() -> wait(Revise.revision_event),
    )
end

end