# THROWAWAY -- #473 evidence loop, never to be merged. Named `zz_` so it runs last, under the
# same memory pressure the three CI failures saw. It always fails, on purpose: under
# `logs = :issues` a failure is the only way its counts reach the CI log.
@testitem "REPRO #473 -- SIGINT disposition race and Ctrl-C child loop" tags=[:core, :slow] setup=[CtrlCChild] begin
using Test

if !Sys.iswindows()

# (a) Race rate: bare Julia processes, 8 at a time for load, each printing its disposition.
probe_cmd = `$(Base.julia_cmd()) --code-coverage=none --startup-file=no -e $SIGINT_PROBE`
dispositions = asyncmap(1:200; ntasks=8) do _
    out = read(ignorestatus(probe_cmd), String)
    m = match(r"SIGINT_DISPOSITION=(\d+)", out)
    m === nothing ? -1 : parse(Int, m[1]) == 1 ? 1 : 0
end
bare = (; runs=length(dispositions), ignored=count(==(1), dispositions),
        unreadable=count(==(-1), dispositions))

# (b) The real children, attempts=1 so an ignored SIGINT is seen raw instead of replaced.
const WORKERS_CHILD = SIGINT_PROBE * raw"""
Base.exit_on_sigint(false)
using Nitro, Nitro.Workers
rt = WorkerRuntime(InMemoryWorkerStore())
s = start_cleanup_scheduler(; interval_hours=24, runtime=rt)
timedwait(() -> !isempty(s.wake.notify.waitq), 10.0)
got = try
    println("READY"); flush(stdout)
    notify(s.wake)
    wait(s.task)
    :main_never_saw_it
catch e
    e isa InterruptException ? :main_interrupted :
    e isa TaskFailedException ? :main_never_saw_it :
    rethrow()
end
println("RESULT main=", got, " scheduler_failed=", istaskfailed(s.task))
"""

const WATCHER_CHILD = SIGINT_PROBE * raw"""
Base.exit_on_sigint(false)
using Nitro
const TERMINAL_STANDIN = Timer(3600)
revisions = Channel{Nothing}(Inf)
Nitro.register_revise_hooks!(;
    revise = () -> (println("REVISED"); flush(stdout)),
    has_pending_revisions = () -> false,
    wait_for_revision_event = () -> take!(revisions),
)
svc = Nitro.Core.start_revise_service()
timedwait(() -> !isempty(revisions.cond_take.waitq), 10.0)
put!(revisions, nothing)
got = try
    wait(svc.task)
    :main_never_saw_it
catch e
    e isa InterruptException ? :main_interrupted :
    e isa TaskFailedException ? :main_never_saw_it :
    rethrow()
end
println("RESULT main=", got, " watcher_failed=", istaskfailed(svc.task))
"""

const SERVE_CHILD = SIGINT_PROBE * raw"""
Base.exit_on_sigint(false)
using Nitro, Sockets
const TERMINAL_STANDIN = Timer(3600)
revisions = Channel{Nothing}(Inf)
Nitro.register_revise_hooks!(;
    revise = () -> (println("REVISED"); flush(stdout)),
    has_pending_revisions = () -> false,
    wait_for_revision_event = () -> take!(revisions),
)
port, probe = listenany(ip"127.0.0.1", 20000); close(probe)
app = App(mod = @__MODULE__)
urlpatterns(app, "", path("/", () -> Res.send("ok"), method = "GET"))
Threads.@spawn :default (sleep(3); put!(revisions, nothing))
serve(app; host = "127.0.0.1", port = Int(port), show_banner = false, access_log = nothing,
      revise = :eager)
println("RESULT serve_returned")
"""

configs = [
    ("workers 1,1", WORKERS_CHILD, "1,1", "READY",   "RESULT main=main_interrupted scheduler_failed=false"),
    ("workers 1,0", WORKERS_CHILD, "1,0", "READY",   "RESULT main=main_never_saw_it scheduler_failed=false"),
    ("watcher 1,1", WATCHER_CHILD, "1,1", "REVISED", "RESULT main=main_interrupted watcher_failed=false"),
    ("watcher 1,0", WATCHER_CHILD, "1,0", "REVISED", "RESULT main=main_never_saw_it watcher_failed=false"),
    ("serve 1,1",   SERVE_CHILD,   "1,1", "REVISED", "RESULT serve_returned"),
]

tally = Dict{String,Dict{Symbol,Int}}()
falsifiers = String[]   # a timeout with SIGINT NOT ignored: the hypothesis does not explain it
for (label, child, threads, cue, expected) in configs, i in 1:10
    r = ctrl_c_child(child, threads; cue, attempts=1)
    outcome = r.sigint_ignored ? :ignored :
              r.timed_out ? :timeout :
              contains(r.out, expected) ? :ok : :wrong
    t = get!(() -> Dict{Symbol,Int}(), tally, label)
    t[outcome] = get(t, outcome, 0) + 1
    if outcome in (:timeout, :wrong)
        report(r)
        outcome === :timeout && push!(falsifiers, "$label run $i")
    end
end

lines = ["bare probe: $(bare.runs) runs, $(bare.ignored) SIG_IGN, $(bare.unreadable) unreadable"]
for (label, _, _, _, _) in configs
    push!(lines, "$label: " * join(sort!(["$k=$v" for (k, v) in tally[label]]), " "))
end
evidence = join(lines, " | ")
println("EVIDENCE ", evidence)
@test isempty(falsifiers)
@test "EVIDENCE: $evidence" == "deliberate failure so the counts reach the log"

end

end
