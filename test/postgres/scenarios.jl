# The scenarios `run.jl` runs, in order, against the database `NITRO_PG_CONNINFO` names. The first
# one creates the task table the rest share; each later one starts from an empty table.
#
# **How a race is staged.** A second session (`holder`, plain LibPQ) opens a transaction and
# writes the row the store is about to touch, so it holds that row's lock. The rest of its
# transaction is sent asynchronously and runs on the SERVER: sleep `HOLD_S`, record how many
# other sessions are waiting on a `Lock` against `nitro_task` (`pg_stat_activity`), then end.
# The store call under test runs meanwhile, on this task, and waits on the lock if it touches
# the row. Ending the transaction server-side is what keeps this free of Julia scheduling: a
# driver call that blocks its thread while it waits cannot also stop the holder from letting go.
#
# The recorded wait is what makes a pass mean something. "The successor row survived" is also
# what a delete that never reached the row would leave; seeing the store's statement waiting on
# the lock is what shows the race was actually run.

include(joinpath(@__DIR__, "common.jl"))

using Test
using UUIDs
using Nitro.Workers: get_task_info, replace_task!, try_delete_task!, cleanup_tasks!,
    claim_next!, renew_leases!, requeue_expired!, LeaseRenewal, LeasePolicy

const HOLD_S = 2.0
const DRAIN_CONSUMERS = 3
const DRAIN_ROWS = 200

pgconn() = LibPQ.Connection(CONNINFO)
sql(c, q, params = Any[]) = LibPQ.execute(c, q, params)
function scalar(c, q, params = Any[])
    r = sql(c, q, params)
    return LibPQ.num_rows(r) == 0 ? nothing : r[1, 1]
end
# Column `j` of every row, as a vector.
function column(c, q, params = Any[]; j::Int = 1)
    r = sql(c, q, params)
    return [r[i, j] for i in 1:LibPQ.num_rows(r)]
end

admin = pgconn()    # setup, reads, and the controls
holder = pgconn()   # the concurrent transaction

# Start a transaction on `holder` that runs `stmt` -- taking the row lock -- and then, on the
# server, sleeps `HOLD_S`, records under `label` how many sessions wait on a Lock, and commits --
# never rolls back, which would take the probe row with it. Returns the async result; `fetch` it
# once the call under test is done.
#
# It returns only once the server is running the sleep. LibPQ submits an async query from a Julia
# task, so a caller that went straight into a blocking call -- the control's synchronous
# `execute` -- would block the thread before that task ever sent it, and wait on the lock
# forever. Polling here yields to the submitting task and proves the tail is on the server.
const HOLDER_PID = scalar(holder, "SELECT pg_backend_pid()")

function hold!(label::String, stmt::String, params = Any[])
    sql(holder, "BEGIN")
    sql(holder, stmt, params)
    pending = LibPQ.async_execute(holder, """
        SELECT pg_sleep($HOLD_S);
        INSERT INTO nitro_race_probe (label, waiting)
            SELECT '$label', count(*) FROM pg_stat_activity
             WHERE wait_event_type = 'Lock' AND pid <> pg_backend_pid()
               AND datname = current_database() AND query ILIKE '%nitro_task%';
        COMMIT""")
    sleeping() = scalar(admin, "SELECT wait_event FROM pg_stat_activity WHERE pid = \$1",
                        [HOLDER_PID]) == "PgSleep"
    timedwait(sleeping, HOLD_S; pollint = 0.005) === :ok ||
        error("hold!($label): the holder's transaction never reached pg_sleep")
    return pending
end

waited(label::String) = scalar(admin, "SELECT waiting FROM nitro_race_probe WHERE label = \$1", [label])

reset_rows!() = sql(admin, "DELETE FROM nitro_task")

# A record written whole, as a submission would be.
function put_task!(store, id::String; status = PENDING, queue::String = "default", external::Bool = false,
                   created = nothing, completed = nothing)
    t = TaskInfo(id; queue_name = queue, external)
    t.status = status
    created === nothing || (t.created_at = created)
    t.completed_at = completed
    replace_task!(store, id, t)
    return t
end

ago(p) = Dates.now(Dates.UTC) - p

@info "PostgreSQL race suite" driver = PG_DRIVER server = scalar(admin, "SHOW server_version")

sql(admin, "DROP TABLE IF EXISTS nitro_task")
sql(admin, "DROP TABLE IF EXISTS nitro_race_probe")
sql(admin, "CREATE TABLE nitro_race_probe (label text PRIMARY KEY, waiting integer NOT NULL)")

store = nothing

@testset "PostgreSQL race suite ($PG_DRIVER)" begin

# ---------------------------------------------------------------------------------------------
@testset "upgrade boot: a pre-#514 nitro_task table gains the claim and job columns" begin
    # The table as it stood before #514: no claim columns, no job columns.
    sql(admin, """
        CREATE TABLE "nitro_task" (
          "id" varchar(255) PRIMARY KEY NOT NULL,
          "run_id" varchar(36) NOT NULL DEFAULT '',
          "status" varchar(20) NOT NULL,
          "progress" float NOT NULL DEFAULT 0.0,
          "result" text NOT NULL DEFAULT '',
          "error" text NOT NULL DEFAULT '',
          "created_at" timestamptz NOT NULL,
          "started_at" timestamptz NULL,
          "completed_at" timestamptz NULL,
          "watchers" text NOT NULL DEFAULT '[]',
          "queue_name" varchar(100) NOT NULL)""")
    sql(admin, """INSERT INTO nitro_task (id, run_id, status, progress, created_at, completed_at,
                                          watchers, queue_name)
                  VALUES ('u1::old', \$1, 'COMPLETED', 1.0, now() - interval '1 day',
                          now() - interval '1 hour', '["u1"]', 'default')""", [string(uuid4())])

    # Every DDL command the boots run, logged by an event trigger, so "the second boot altered
    # nothing" is observed rather than inferred from the schema looking right.
    sql(admin, "DROP TABLE IF EXISTS nitro_ddl_log")
    sql(admin, "CREATE TABLE nitro_ddl_log (tag text NOT NULL, object text)")
    sql(admin, """
        CREATE OR REPLACE FUNCTION nitro_log_ddl() RETURNS event_trigger LANGUAGE plpgsql AS \$\$
        DECLARE r record;
        BEGIN
          FOR r IN SELECT * FROM pg_event_trigger_ddl_commands() LOOP
            INSERT INTO nitro_ddl_log VALUES (r.command_tag, r.object_identity);
          END LOOP;
        END \$\$""")
    sql(admin, "DROP EVENT TRIGGER IF EXISTS nitro_ddl_log")
    sql(admin, "CREATE EVENT TRIGGER nitro_ddl_log ON ddl_command_end EXECUTE FUNCTION nitro_log_ddl()")
    try
        global store = pg_store()

        columns = Set(String.(column(admin, """
            SELECT column_name FROM information_schema.columns
             WHERE table_schema = current_schema() AND table_name = 'nitro_task'""")))
        for c in ("external", "claimed_by", "lease_expires_at", "attempt", "job_name", "job_args")
            @test c in columns
        end
        indexes = Set(String.(column(admin, """
            SELECT indexname FROM pg_indexes
             WHERE schemaname = current_schema() AND tablename = 'nitro_task'""")))
        @test "nitro_task_claim_idx" in indexes
        @test "nitro_task_lease_idx" in indexes
        # `>= 6` because `_ensure_column!` adds one column per `ALTER TABLE` today, and the event
        # trigger logs one row per statement. A PormG change batching the six into one statement
        # would turn this red with nothing wrong; the column assertions above are the real check.
        @test scalar(admin, "SELECT count(*) FROM nitro_ddl_log WHERE tag = 'ALTER TABLE'") >= 6

        # The old row reads back with the new columns' defaults.
        old = get_task_info(store, "u1::old")
        @test old !== nothing
        if old !== nothing
            @test old.status == COMPLETED
            @test old.watchers == ["u1"]
            @test old.external == false
            @test old.attempt == 0
            @test old.claimed_by === nothing
            @test old.lease_expires_at === nothing
            @test old.job_name === nothing
        end

        # A second boot finds every column and index and changes nothing.
        sql(admin, "DELETE FROM nitro_ddl_log")
        global store = pg_store()
        altered = column(admin, "SELECT tag || ' ' || coalesce(object, '') FROM nitro_ddl_log " *
                                "WHERE tag NOT IN ('CREATE TABLE', 'CREATE INDEX')")
        @test isempty(altered)
        isempty(altered) || @info "second boot ran DDL" altered
    finally
        sql(admin, "DROP EVENT TRIGGER IF EXISTS nitro_ddl_log")
        sql(admin, "DROP TABLE IF EXISTS nitro_ddl_log")
    end
end

store === nothing && (global store = pg_store())   # the upgrade scenario failed before booting one

# Compile every store call a race times, before the first race. A first call's JIT can outlast the
# hold, so the call reaches the row after the holder let go and the race never happens -- the
# probe then reads 0 and the scenario goes red, which is how this was found.
#
# On rows, not an empty table: an empty table compiles only the early returns. `cleanup_tasks!`
# breaks before its page delete, `claim_next!` returns before `_claim_row!`, and
# `requeue_expired!` never reaches its fenced UPDATE.
let warm = Dict{String, LeasePolicy}("warm" => LeasePolicy(:requeue, 3))
    a = put_task!(store, "u1::warm-a"; status = COMPLETED, completed = ago(Day(10)))
    try_delete_task!(store, "u1::warm-a", (COMPLETED,); run_id = uuid4())    # fence misses
    try_delete_task!(store, "u1::warm-a", (COMPLETED,); run_id = nothing)    # deletes
    put_task!(store, "u1::warm-b"; status = COMPLETED, completed = ago(Day(10)))
    cleanup_tasks!(store, 1)                                                 # deletes a page
    put_task!(store, "u1::warm-c"; queue = "warm", external = true)
    run = claim_next!(store, "warm", "c0"; lease_seconds = 1, now = ago(Minute(10)))   # claims
    renew_leases!(store, "c0", LeaseRenewal[(id = run.id, run_id = run.run_id, progress = 0.0)];
                  lease_seconds = 1, now = ago(Minute(10)))
    requeue_expired!(store, Dates.now(Dates.UTC); policies = warm)            # requeues it
    get_task_info(store, "u1::warm-c")
    reset_rows!()
end

# ---------------------------------------------------------------------------------------------
@testset "guarded deletes re-check after a row-lock wait (#379, #398)" begin
    terminal = (COMPLETED, FAILED, CANCELLED)
    rerun_pending = """UPDATE nitro_task SET status = 'PENDING', run_id = \$1, completed_at = NULL
                        WHERE id = \$2"""
    rerun_finished = """UPDATE nitro_task SET status = 'COMPLETED', run_id = \$1, completed_at = now()
                         WHERE id = \$2"""

    @testset "try_delete_task!: a re-run committed while the delete waited survives" begin
        reset_rows!()
        put_task!(store, "u1::del"; status = COMPLETED, completed = ago(Day(10)))
        b = uuid4()
        pending = hold!("delete-vs-pending-rerun", rerun_pending, [string(b), "u1::del"])
        t = @elapsed deleted = try_delete_task!(store, "u1::del", terminal; run_id = nothing)
        fetch(pending)
        @test waited("delete-vs-pending-rerun") >= 1
        @test t >= HOLD_S / 2
        @test deleted == false
        rec = get_task_info(store, "u1::del")
        @test rec !== nothing && rec.run_id == b && rec.status == PENDING
    end

    @testset "try_delete_task!: a finished re-run fails the run fence" begin
        reset_rows!()
        a = put_task!(store, "u1::del"; status = COMPLETED, completed = ago(Day(10)))
        b = uuid4()
        finished = hold!("delete-vs-finished-rerun", rerun_finished, [string(b), "u1::del"])
        deleted = try_delete_task!(store, "u1::del", (COMPLETED,); run_id = a.run_id)
        fetch(finished)
        @test waited("delete-vs-finished-rerun") >= 1
        @test deleted == false
        rec = get_task_info(store, "u1::del")
        @test rec !== nothing && rec.run_id == b && rec.status == COMPLETED
    end

    @testset "cleanup_tasks!: the re-run survives, the eligible neighbour does not" begin
        for (label, stmt, status) in (("cleanup-vs-pending-rerun", rerun_pending, PENDING),
                                      ("cleanup-vs-finished-rerun", rerun_finished, COMPLETED))
            reset_rows!()
            put_task!(store, "u1::keep"; status = COMPLETED, completed = ago(Day(10)))
            put_task!(store, "u1::gone"; status = COMPLETED, completed = ago(Day(10)))   # control
            b = uuid4()
            rerun = hold!(label, stmt, [string(b), "u1::keep"])
            deleted = cleanup_tasks!(store, 1)
            fetch(rerun)
            @test waited(label) >= 1
            @test deleted == 1
            @test get_task_info(store, "u1::gone") === nothing
            rec = get_task_info(store, "u1::keep")
            @test rec !== nothing && rec.run_id == b && rec.status == status
        end
    end

    @testset "control: the pre-#398 `IN (SELECT …)` shape loses the re-run" begin
        # The statement PormG 0.6 rendered: the filters live in a subquery, evaluated once on the
        # old snapshot, so the outer DELETE re-checks only `id` after its wait. If this stops
        # losing the row, the harness no longer stages the race, and every pass above is vacuous.
        reset_rows!()
        put_task!(store, "u1::del"; status = COMPLETED, completed = ago(Day(10)))
        rerun = hold!("control-in-subquery", rerun_pending, [string(uuid4()), "u1::del"])
        sql(admin, """DELETE FROM nitro_task WHERE id IN (
                          SELECT id FROM nitro_task WHERE id = \$1
                             AND status IN ('COMPLETED', 'FAILED', 'CANCELLED'))""", ["u1::del"])
        fetch(rerun)
        @test waited("control-in-subquery") >= 1
        @test get_task_info(store, "u1::del") === nothing
    end
end

# ---------------------------------------------------------------------------------------------
@testset "claim_next! skips a locked head row (SKIP LOCKED)" begin
    reset_rows!()
    t0 = ago(Minute(5))
    for (i, id) in enumerate(("u1::q1", "u1::q2", "u1::q3"))
        put_task!(store, id; queue = "q", external = true, created = t0 + Second(i))
    end
    # Released on the server after `HOLD_S`, so a claim that wrongly waited fails the assertions
    # below instead of hanging the run.
    head = hold!("skip-locked", "SELECT id FROM nitro_task WHERE id = \$1 FOR UPDATE", ["u1::q1"])
    # No timing bound: a claim that waited on the head instead of skipping it would take the head
    # once the holder let go (the holder leaves `q1` PENDING), and the probe below would see it
    # waiting -- both are asserted, and neither depends on how fast the runner is.
    run = claim_next!(store, "q", "c1"; lease_seconds = 30)
    @test run !== nothing && run.id == "u1::q2"

    # Control: the same read without SKIP LOCKED queues on the head.
    sql(admin, "SET lock_timeout = '300ms'")
    err = try
        sql(admin, """SELECT id FROM nitro_task
                       WHERE queue_name = 'q' AND external AND status = 'PENDING'
                       ORDER BY created_at, id LIMIT 1 FOR UPDATE""")
        nothing
    catch e
        e
    end
    sql(admin, "RESET lock_timeout")
    @test err !== nothing && occursin("lock timeout", sprint(showerror, err))

    fetch(head)
    # Nobody waited on the head while it was held: the claim skipped it, and the control had
    # given up by then.
    @test waited("skip-locked") == 0
    @test claim_next!(store, "q", "c1"; lease_seconds = 30).id == "u1::q1"
end

# ---------------------------------------------------------------------------------------------
@testset "renew_leases! against requeue_expired!, both orders" begin
    policies = Dict{String, LeasePolicy}("q" => LeasePolicy(:requeue, 3))
    # A run whose lease ran out long ago: claimed in the past, for one second.
    function expired_run!(id)
        put_task!(store, id; queue = "q", external = true)
        return claim_next!(store, "q", "c1"; lease_seconds = 1, now = ago(Minute(10)))
    end

    @testset "the renewal commits while the requeue waits: the run stays the consumer's" begin
        reset_rows!()
        run = expired_run!("u1::r")
        # The statement `renew_leases!` issues, held open.
        renew = hold!("requeue-vs-renew", """
            UPDATE nitro_task SET lease_expires_at = now() + interval '1 hour'
             WHERE id = \$1 AND run_id = \$2 AND status = 'RUNNING' AND claimed_by = 'c1'""",
            [run.id, string(run.run_id)])
        tally = requeue_expired!(store, Dates.now(Dates.UTC); policies)
        fetch(renew)
        @test waited("requeue-vs-renew") >= 1
        @test tally.lost_race == 1
        @test tally.requeued == 0
        rec = get_task_info(store, "u1::r")
        @test rec !== nothing && rec.status == RUNNING && rec.run_id == run.run_id &&
              rec.claimed_by == "c1"
    end

    @testset "the requeue lands first: the late renewal matches nothing" begin
        reset_rows!()
        run = expired_run!("u1::r")
        tally = requeue_expired!(store, Dates.now(Dates.UTC); policies)
        @test tally.requeued == 1
        renewed = renew_leases!(store, "c1", LeaseRenewal[(id = run.id, run_id = run.run_id, progress = 0.5)];
                                lease_seconds = 30)
        @test isempty(renewed)
        rec = get_task_info(store, "u1::r")
        @test rec !== nothing && rec.status == PENDING && rec.run_id != run.run_id &&
              rec.claimed_by === nothing
    end
end

# ---------------------------------------------------------------------------------------------
@testset "concurrent drain: $DRAIN_CONSUMERS consumer processes, every row claimed once" begin
    reset_rows!()
    outdir = mktempdir()
    app = drain_setup!(App())
    start!(app; store, cleanup_enabled = false, recover_zombies = false)
    procs = Base.Process[]
    log_ios = IOStream[]
    try
        owner = Owner("u1")
        for i in 1:DRAIN_ROWS
            submit_queued_task(app, DRAIN_QUEUE, "t$i", Job("drain", DrainWork(; tag = "t$i", outdir)), owner)
        end
        # Decoys: an external row on a queue nobody consumes, and a row on the drained queue
        # that is not external -- neither may be touched.
        submit_queued_task(app, DECOY_QUEUE, "decoy-ext", Job("drain", DrainWork(; tag = "decoy-ext", outdir)), owner)
        put_task!(store, "u1::decoy-local"; queue = DRAIN_QUEUE, external = false)

        child = joinpath(@__DIR__, "drain_child.jl")
        names = ["c$k" for k in 1:DRAIN_CONSUMERS]
        logs = Dict(n => joinpath(outdir, "$n.log") for n in names)
        for n in names
            cmd = `$(Base.julia_cmd()) --threads=2,2 --startup-file=no --project=$PG_ENV $child $outdir`
            # One handle for both streams: two opens of one path keep two write offsets and
            # overwrite each other.
            io = open(logs[n], "w")
            push!(log_ios, io)
            push!(procs, run(pipeline(ignorestatus(addenv(cmd, "NITRO_PG_CONSUMER" => n));
                                      stdout = io, stderr = io); wait = false))
        end
        dump_logs() = for n in names
            println("---- $n ----")
            isfile(logs[n]) && print(read(logs[n], String))
        end

        # Release them together once every one is ready to claim, so they really race.
        ready = timedwait(() -> all(n -> isfile(joinpath(outdir, "$n.ready")), names) ||
                                any(!process_running, procs), 900.0; pollint = 0.2)
        all_ready = ready === :ok && all(n -> isfile(joinpath(outdir, "$n.ready")), names)
        @test all_ready
        touch(joinpath(outdir, "go"))
        done = timedwait(() -> !any(process_running, procs), 600.0; pollint = 0.2)
        @test done === :ok
        @test all(p -> p.exitcode == 0, procs)
        foreach(flush, log_ios)
        (all_ready && done === :ok && all(p -> p.exitcode == 0, procs)) || dump_logs()

        drained = """FROM nitro_task WHERE queue_name = \$1 AND external"""
        @test scalar(admin, "SELECT count(*) $drained", [DRAIN_QUEUE]) == DRAIN_ROWS
        @test column(admin, "SELECT DISTINCT status $drained", [DRAIN_QUEUE]) == ["COMPLETED"]
        @test column(admin, "SELECT DISTINCT attempt $drained", [DRAIN_QUEUE]) == [1]

        # Each submission ran exactly once: one marker per tag, whichever consumer took it.
        markers = filter(f -> startswith(f, "t") && count(==('.'), f) == 2, readdir(outdir))
        per_tag = Dict{String, Int}()
        for f in markers
            tag = first(split(f, '.'))
            per_tag[tag] = get(per_tag, tag, 0) + 1
        end
        @test length(per_tag) == DRAIN_ROWS
        @test all(==(1), values(per_tag))
        split_by = Dict(n => count(f -> split(f, '.')[2] == n, markers) for n in names)
        @info "drain split (printed, not asserted)" split_by

        for id in ("u1::decoy-ext", "u1::decoy-local")
            rec = get_task_info(store, id)
            @test rec !== nothing && rec.status == PENDING && rec.attempt == 0 &&
                  rec.claimed_by === nothing
        end
        @test !any(f -> startswith(f, "decoy"), readdir(outdir))
    finally
        # Whatever went wrong above, no consumer outlives the scenario.
        for p in procs
            process_running(p) && kill(p)
            timedwait(() -> !process_running(p), 30.0)
        end
        foreach(close, log_ios)
        shutdown!(worker_runtime(app))
    end
end

end # testset
