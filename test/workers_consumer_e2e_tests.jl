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
logs = String[]
function dump_logs()
    for log in logs
        isfile(log) || continue
        println("── $(basename(log)) (last 300 lines) ──")
        foreach(println, last(readlines(log), 300))
    end
end
# After a scenario's `@test`s, which keep their own evaluated output: the logs when it went wrong.
or_dump(ok::Bool) = ok || (dump_logs(); false)
function waitfor(f, what; timeout = 120)
    timedwait(f, timeout; pollint = 0.1) === :ok && return true
    @warn "timed out waiting for $what"
    dump_logs()
    return false
end
waitfile(path; kw...) = waitfor(() -> isfile(path), basename(path); kw...)
waitstatus(id, status; kw...) = waitfor(() -> rec(id).status == status, "$id to be $status"; kw...)

function start_consumer(name)
    log = joinpath(dir, "$name.log")
    push!(logs, log)
    io = open(log, "w")
    cmd = `$(Base.julia_cmd()) --code-coverage=none --threads=2,2 --startup-file=no
           --project=$(Base.active_project()) $child $dbspec $outdir $name $LEASE`
    cmd = addenv(cmd, "JULIA_DEBUG" => "Nitro")
    return run(pipeline(ignorestatus(cmd); stdout = io, stderr = io); wait = false), io
end

children = Any[]
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
        @test waitfile(marker("s3", "started.1"))
        cancel_task(s3, owner; runtime)
        @test waitfile(marker("s3", "reason"); timeout = 30)
        @test read(marker("s3", "reason"), String) == "user"
        @test rec(s3).status == CANCELLED
    end

    @testset "a lease taken back reaches the job as :lease_lost, and the run happens again" begin
        s4 = submit("requeue", "s4")
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
        @test waitstatus(s1, COMPLETED)
        @test isfile(marker("s1", "started.2"))
        @test rec(s1).result == "done-on-attempt-2"
    end

    # A SIGTERM on Windows is `TerminateProcess`: no handler and no `atexit` hook runs, so there is
    # no drain to test there. A supervised consumer there stops like a SIGKILLed one, and its
    # leases expire (the scenario above).
    Sys.iswindows() || @testset "a SIGTERM drains the consumer, which hands its run back" begin
        s5 = submit("requeue", "s5")
        @test waitfile(marker("s5", "started.1"))
        kill(pB, Base.SIGTERM)
        @test waitfor(() -> !process_running(pB), "consumer B to exit"; timeout = 60)
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
