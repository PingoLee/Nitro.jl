@testitem "Workers -- consumer processes over one SQLite store (#514)" tags=[:workers, :slow, :extension, :pormg] setup=[NitroCommon] begin

# The design record's §9 end-to-end test, on a real SQLite file shared by two processes: this one
# is the web side (it submits, and runs an in-process queue), and a child started with
# `--threads=2,2` is the consumer. Every claim, renewal, hand-back and expiry crosses the process
# boundary through the database, which is what no in-process test can show.
#
# `NITRO_E2E_POSTGRES` set to a libpq conninfo (`host=… port=… dbname=…`) runs it against that
# PostgreSQL database instead, by hand: CI has no PostgreSQL (#407), and the environment then
# needs `LibPQ`, which is not a test dependency.

using Test
using Dates
using Nitro
using Nitro.Workers
using PormG
using SQLite
using Nitro.Workers: get_task_info, release_claim!, LeasePolicy, count_external_runs, _requeue_expired_tick!

include(joinpath(@__DIR__, ".helpers", "consumer_e2e_setup.jl"))

const LEASE = 2.0
dir = mktempdir()
dbspec = get(ENV, "NITRO_E2E_POSTGRES", joinpath(dir, "workers.sqlite"))
e2e_is_postgres(dbspec) && @eval using LibPQ
outdir = mkpath(joinpath(dir, "out"))
child = joinpath(@__DIR__, ".helpers", "consumer_e2e_child.jl")

store = e2e_store(dbspec)
web = e2e_setup!(App())
start!(web; store, cleanup_enabled = false, recover_zombies = false)
runtime = worker_runtime(web)
owner = Owner("u1")

submit(queue, tag; who = owner) =
    submit_queued_task(web, queue, tag, Job("hold", E2EWork(; mode = "hold", tag, outdir)), who)
marker(tag, name) = joinpath(outdir, "$tag.$name")
rec(id) = get_task_info(store, id)

# The children's logs, printed when a wait times out or a scenario's outcome is wrong. Each child
# flushes every record and logs each heartbeat tick at `@debug` (#623), so the tail shows whether
# its heartbeat ticked and how long each renewal took.
#
# The tail alone opens long after a run that went wrong early has gone (#666), so a dump first
# prints, from the start of each log, every record naming the scenario's runs (`focus!`), and which
# of their marker files exist: both are gone once the temp dir is.
logs = String[]
const FOCUS_IDS = String[]
const FOCUS_TAGS = String[]
function focus!(runs::Pair{String, String}...)
    empty!(FOCUS_IDS); empty!(FOCUS_TAGS)
    for (id, tag) in runs
        push!(FOCUS_IDS, id); push!(FOCUS_TAGS, tag)
    end
end
# A child's log as SimpleLogger records (`┌ …` to `└ …`), each other line a record of its own, so
# a record's `task_id = …` line brings its message and its time along.
function log_records(lines)
    records = Vector{String}[]
    inside = false
    for line in lines
        if inside
            push!(records[end], line)
            inside = !startswith(line, "└")
        else
            push!(records, [line])
            inside = startswith(line, "┌")
        end
    end
    return records
end
function dump_logs()
    for tag in FOCUS_TAGS
        names = sort!(filter(n -> startswith(n, "$tag."), readdir(outdir)))
        println("── markers of $tag: ", isempty(names) ? "none" : join(names, ", "))
        isfile(marker(tag, "reason")) && println("   $tag.reason = ", read(marker(tag, "reason"), String))
    end
    for log in logs
        isfile(log) || continue
        lines = readlines(log)
        # A child that died before writing leaves an empty log, which the parent already opened.
        isempty(lines) && (println("── $(basename(log)) is empty ──"); continue)
        if !isempty(FOCUS_IDS)
            named = filter(r -> any(id -> any(l -> occursin(id, l), r), FOCUS_IDS), log_records(lines))
            println("── $(basename(log)): every record naming $(join(FOCUS_IDS, ", ")) ($(length(named))) ──")
            foreach(r -> foreach(println, r), named)
        end
        # From a hang-time stack dump on, whatever its length (`info_dump`), else the last 300.
        info = findfirst(contains("Information request received"), lines)
        from = min(something(info, length(lines)), max(length(lines) - 299, 1))
        println("── $(basename(log)) (from line $from of $(length(lines))) ──")
        foreach(println, @view lines[from:end])
    end
end
# After a scenario's `@test`s, which keep their own evaluated output: the logs when it went wrong.
or_dump(ok::Bool) = ok || (dump_logs(); false)
function waitfor(f, what; timeout = 120, before_dump = () -> nothing)
    timedwait(f, timeout; pollint = 0.1) === :ok && return true
    @warn "timed out waiting for $what"
    before_dump()
    dump_logs()
    return false
end
# A hung child's stacks, at the hang rather than at the signal that began it (#677): SIGUSR1 on
# Linux, SIGINFO on macOS and the BSDs, makes Julia print every thread's backtrace and go on
# running. Probed on 1.12.7 and 1.13.2 with an `atexit` hook hung after a SIGTERM: a second
# SIGTERM ends the process with no dump, and SIGQUIT prints nothing.
function info_dump(p, log)
    process_running(p) || return nothing
    before = filesize(log)
    kill(p, Sys.isbsd() ? 29 : 10)
    timedwait(() -> filesize(log) > before && occursin("Profile collected", read(log, String)), 15; pollint = 0.2)
    return nothing
end
# Whether a child logged that `consume!` waits outside the scheduler (#677), which only a debug
# record shows: the park and a `wait` look the same from outside.
parked_off_scheduler(log) =
    any(r -> any(contains("consumer parks"), r) && any(contains("off_scheduler = true"), r),
        log_records(readlines(log)))
waitfile(path; kw...) = waitfor(() -> isfile(path), basename(path); kw...)
waitstatus(id, status; kw...) = waitfor(() -> rec(id).status == status, "$id to be $status"; kw...)

function start_consumer(name; mode = "")
    log = joinpath(dir, "$name.log")
    push!(logs, log)
    io = open(log, "w")
    cmd = `$(Base.julia_cmd()) --code-coverage=none --threads=2,2 --startup-file=no
           --project=$(Base.active_project()) $child $dbspec $outdir $name $LEASE $(isempty(mode) ? String[] : [mode])`
    cmd = addenv(cmd, "JULIA_DEBUG" => "Nitro")
    return run(pipeline(ignorestatus(cmd); stdout = io, stderr = io); wait = false), io
end

children = Any[]
s5_id = Ref{Any}(nothing)     # the run s5 hands back, for the one-shot consumer
try
    @testset "the submitter count matches ids literally on a real database" begin
        # `@startswith` is a LIKE: an id holding `_`, `%` or `\` must match only itself.
        for uid in ("a_b", "a%b", "a\\b")
            submit("idle", "k", who = Owner(uid))
        end
        for uid in ("a_b", "a%b", "a\\b")
            @test count_external_runs(store, [PENDING]; submitter = uid) == 1
        end
        @test count_external_runs(store, [PENDING]; submitter = "aXb") == 0
        @test count_external_runs(store, [PENDING]; submitter = "a") == 0
    end

    # An in-process run of the web, RUNNING with no lease: what a consumer must never touch.
    gate = Base.Event()
    local_id = submit_queued_task(web, "local", "in-web", _ -> (wait(gate); :local), owner)
    @test waitstatus(local_id, RUNNING)

    s1 = submit("requeue", "s1")
    s2 = submit("fail", "s2")
    pA, ioA = start_consumer("A")
    push!(children, (pA, ioA))

    @testset "a consumer process claims, runs and renews" begin
        focus!(s1 => "s1", s2 => "s2")
        @test waitfile(joinpath(outdir, "A.ready"))
        @test waitfile(marker("s1", "started.1"))
        @test waitfile(marker("s2", "started.1"))
        @test rec(s1).claimed_by == "A"
        # Progress goes to the database with the heartbeat's renewal, not only to the object.
        @test waitfor(() -> rec(s1).progress == 40.0, "s1's progress"; timeout = 20)
        # Waited for, not read once: the first renewal can be slower than the 2 s lease (#623),
        # so the lease it writes may have lapsed by the time it lands. The next one renews it.
        @test waitfor(() -> rec(s1).lease_expires_at > now(UTC), "s1's lease to be live"; timeout = 20)
        or_dump(rec(s1).progress == 40.0 && rec(s1).lease_expires_at > now(UTC))
    end

    @testset "a user cancel reaches the consumer's job as :user" begin
        s3 = submit("requeue", "s3")
        focus!(s3 => "s3")
        @test waitfile(marker("s3", "started.1"))
        cancel_task(s3, owner; runtime)
        @test waitfile(marker("s3", "reason"); timeout = 30)
        @test read(marker("s3", "reason"), String) == "user"
        @test rec(s3).status == CANCELLED
    end

    @testset "a lease taken back reaches the job as :lease_lost, and the run happens again" begin
        s4 = submit("requeue", "s4")
        focus!(s4 => "s4")
        @test waitfile(marker("s4", "started.1"))
        # Taken back from outside, under a fresh run of the same submission.
        @test release_claim!(store, s4, rec(s4).run_id; policy = LeasePolicy(:requeue))
        @test waitfile(marker("s4", "reason"); timeout = 30)
        @test read(marker("s4", "reason"), String) == "lease_lost"
        @test waitstatus(s4, COMPLETED)
        @test isfile(marker("s4", "started.2"))
    end

    @testset "the web's in-process run is left alone by the consumer" begin
        # Many heartbeats have adjudicated expired leases by now; none touched this row.
        @test rec(local_id).status == RUNNING
        notify(gate)
        @test waitstatus(local_id, COMPLETED)
    end

    @testset "a consumer killed mid-run: its leases expire, and each queue's policy decides" begin
        focus!(s1 => "s1", s2 => "s2")
        kill(pA, Base.SIGKILL)
        wait(pA)
        @test rec(s1).status == RUNNING && rec(s2).status == RUNNING     # nothing knows yet
        sleep(LEASE + 1)
        tally = _requeue_expired_tick!(runtime)
        @test tally.requeued == 1 && tally.failed == 1
        @test rec(s1).status == PENDING && rec(s1).attempt == 1          # :requeue
        @test rec(s2).status == FAILED                                   # :fail
        @test occursin("on_lease_expiry = :fail", rec(s2).error)
        or_dump(tally.requeued == 1 && tally.failed == 1 && rec(s1).status == PENDING)
    end

    pB, ioB = start_consumer("B")
    push!(children, (pB, ioB))

    @testset "the next consumer runs the re-queued run" begin
        focus!(s1 => "s1")
        @test waitstatus(s1, COMPLETED)
        @test isfile(marker("s1", "started.2"))
        @test rec(s1).result == "done-on-attempt-2"
    end

    # A SIGTERM on Windows is `TerminateProcess`: no handler and no `atexit` hook runs, so there is
    # no drain to test there. A supervised consumer there stops like a SIGKILLed one, and its
    # leases expire (the scenario above).
    Sys.iswindows() || @testset "a SIGTERM drains the consumer, which hands its run back" begin
        s5 = submit("requeue", "s5")
        s5_id[] = s5
        focus!(s5 => "s5")
        @test waitfile(marker("s5", "started.1"))
        # Thread 1 waits outside the scheduler, where a SIGTERM holds nothing the drain needs
        # (#677): a signal caught inside a libuv callback there hung the drain.
        @test waitfor(() -> parked_off_scheduler(joinpath(dir, "B.log")), "consumer B to park")
        kill(pB, Base.SIGTERM)
        @test waitfor(() -> !process_running(pB), "consumer B to exit"; timeout = 60,
                      before_dump = () -> info_dump(pB, joinpath(dir, "B.log")))
        @test read(marker("s5", "reason"), String) == "shutdown"
        r5 = rec(s5)
        @test r5.status == PENDING
        @test r5.claimed_by === nothing
        @test r5.attempt == 1
        flush(ioB)
        blog = read(joinpath(dir, "B.log"), String)
        @test occursin("consumer stopped", blog)
        # A drain that timed out also exits and also writes that line, with the run still going
        # (#623): only the count tells it from a drain that handed the run back.
        @test occursin(r"runs_still_renewed = 0\b", blog)
        # The heartbeat never ran on thread 1, where the SIGTERM ran the drain (#636). A heartbeat
        # there was hijacked mid-renewal holding the store's write lock, or mid-compile, and this
        # scenario then hung or left the run claimed.
        beat_threads = [m[1] for m in eachmatch(r"\bthread = (\d+)", blog)]
        @test !isempty(beat_threads) && all(==("2"), beat_threads)
        or_dump(r5.status == PENDING && r5.claimed_by === nothing && occursin(r"runs_still_renewed = 0\b", blog))
        # It left through the `atexit` drain, never back through `consume!`'s wait.
        @test !isfile(joinpath(outdir, "B.returned"))
    end

    # `consume!` waits with thread 1 outside the scheduler (#677), so a stop must reach it from
    # another thread: here the recycle that ends a one-shot consumer, which then returns normally.
    @testset "a one-shot consumer runs the handed-back run and returns" begin
        s5 = s5_id[]
        s5 === nothing || focus!(s5 => "s5")
        pC, ioC = start_consumer("C"; mode = "oneshot")
        push!(children, (pC, ioC))
        @test waitfor(() -> !process_running(pC), "the one-shot consumer to return"; timeout = 60,
                      before_dump = () -> info_dump(pC, joinpath(dir, "C.log")))
        @test pC.exitcode == 0
        # The park outside the scheduler engaged, everywhere but Windows, and the stop reached it.
        @test parked_off_scheduler(joinpath(dir, "C.log")) == !Sys.iswindows()
        # s5's run when the SIGTERM scenario handed it back, else nothing to claim.
        expected = s5 === nothing ? "idle" : "max_runs"
        @test isfile(joinpath(outdir, "C.returned")) &&
              read(joinpath(outdir, "C.returned"), String) == expected
        if s5 !== nothing
            @test rec(s5).status == COMPLETED
            @test rec(s5).result == "done-on-attempt-2"
        end
    end

    # A REPL's Ctrl-C is an `InterruptException` delivered to thread 1's task, which the park
    # holds outside the scheduler (#677). It must still arrive there, and drain.
    Sys.iswindows() || @testset "an interrupt reaches the parked consumer, which drains" begin
        focus!()
        pD, ioD = start_consumer("D"; mode = "interrupt")
        push!(children, (pD, ioD))
        dlog = joinpath(dir, "D.log")
        # Signalled once it is in the park, which it logs as it enters.
        @test waitfor(() -> parked_off_scheduler(dlog), "consumer D to park outside the scheduler")
        kill(pD, Base.SIGINT)
        @test waitfor(() -> !process_running(pD), "consumer D to exit"; timeout = 60,
                      before_dump = () -> info_dump(pD, dlog))
        flush(ioD)
        txt = read(dlog, String)
        @test occursin("consumer stopped", txt)
        @test occursin("InterruptException", txt)
        @test pD.exitcode != 0
        @test !isfile(joinpath(outdir, "D.returned"))
    end

    @testset "a consumer with one interactive thread refuses to start" begin
        # The heartbeat would share thread 1 with the main task, and a SIGTERM runs the drain on
        # top of whatever thread 1 is doing (#636). With none, it would share the jobs' threads.
        out = IOBuffer()
        cmd = `$(Base.julia_cmd()) --code-coverage=none --threads=1,1 --startup-file=no
               --project=$(Base.active_project()) $child $dbspec $outdir refused $LEASE`
        p = run(pipeline(ignorestatus(cmd); stdout = out, stderr = out); wait = false)
        @test waitfor(() -> !process_running(p), "the refused consumer to exit")
        process_running(p) && kill(p, Base.SIGKILL)
        wait(p)
        @test p.exitcode != 0
        @test occursin("julia -t k,2", String(take!(out)))
        @test !isfile(joinpath(outdir, "refused.returned"))
    end

    @testset "the web process was unaffected throughout" begin
        id = submit_queued_task(web, "local", "after", _ -> :ok, owner)
        @test waitstatus(id, COMPLETED; timeout = 10)
    end
finally
    for (p, io) in children
        process_running(p) && kill(p, Base.SIGKILL)
        close(io)
    end
    uninstall!(web; drain_timeout = 0)
end

end
