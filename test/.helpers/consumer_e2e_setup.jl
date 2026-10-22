# Shared by the two-process consumer test (`test/workers_consumer_e2e_tests.jl`) and the consumer
# child it starts (`consumer_e2e_child.jl`): the SQLite connection, the queue declarations and the
# job, so the two processes read them from one place exactly as an app's setup function would.
# Expects `Nitro`, `Nitro.Workers`, `PormG` and `SQLite` to be loaded by the includer.

const E2E_DB_KEY = "nitro_consumer_e2e"

# The shared store: one SQLite file, or a PostgreSQL database when `spec` is a libpq conninfo
# (`dbname=…`, how the test is run by hand against a real server, since CI has none). A dynamic
# connection is read-only until writes are enabled; `change_db` lets `pormg_nitro_worker` create
# the task table.
e2e_is_postgres(spec::AbstractString) = occursin("dbname=", spec)

function e2e_store(spec::AbstractString)
    PormG.register_connection(E2E_DB_KEY, spec; adapter = e2e_is_postgres(spec) ? "PostgreSQL" : "SQLite")
    PormG.config[E2E_DB_KEY].change_data = true
    PormG.config[E2E_DB_KEY].change_db = true
    return Nitro.pormg_nitro_worker(db_key = E2E_DB_KEY)
end

Base.@kwdef struct E2EWork
    mode::String
    tag::String
    outdir::String
end

# The parent polls for these marker files and reads them while the child runs. A plain `write`
# creates the file before filling it, so a poll in between read `""` (#707); a rename is atomic.
function e2e_write(path::AbstractString, value)
    write(path * ".tmp", string(value))
    mv(path * ".tmp", path; force = true)
end

e2e_mark(w::E2EWork, name::AbstractString, value = "") =
    e2e_write(joinpath(w.outdir, "$(w.tag).$name"), value)

# `hold`: report the attempt, set progress, then loop on `checkpoint!` until stopped, and record
# why. From the second attempt on it completes at once, which is what a re-queued run must do.
function e2e_job(task_info, w::E2EWork)
    e2e_mark(w, "started.$(task_info.attempt)", getpid())
    task_info.attempt >= 2 && return "done-on-attempt-$(task_info.attempt)"
    update_progress!(task_info, 40)
    try
        while true
            checkpoint!(task_info)
            sleep(0.05)
        end
    catch e
        e isa TaskCancelledError && e2e_mark(w, "reason", e.reason)
        rethrow()
    end
end

function e2e_setup!(app)
    declare_queues!(app, [
        "local",                                                   # in-process, in the web
        "requeue" => External(on_lease_expiry = :requeue),
        "fail" => External(on_lease_expiry = :fail),
        "idle" => External(on_lease_expiry = :fail),               # declared, never consumed
    ])
    register_job!(e2e_job, app, "hold", E2EWork)
    return app
end
