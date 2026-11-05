# Shared by `scenarios.jl` and the drain children (`drain_child.jl`): the driver, the connection,
# the queue declarations and the job, so the parent and its consumer processes read them from one
# place, as an app's setup function would. Expects the environment `run.jl` built to be active.

using Dates
using LibPQ                 # always: the test's own instrument (the lock holder, the probes)
using PormG
using Nitro
using Nitro.Workers

# The driver PormG builds the store's pool with comes from `PORMG_POSTGRES_DRIVER` (PormG#788):
# LibPQ when unset. Postgres.jl is loaded only when it is the one under test.
const PG_DRIVER = lowercase(strip(get(ENV, "PORMG_POSTGRES_DRIVER", "LibPQ")))
PG_DRIVER in ("libpq", "postgres") ||
    error("PORMG_POSTGRES_DRIVER must be LibPQ or Postgres, got $(repr(PG_DRIVER))")
PG_DRIVER == "postgres" && @eval using Postgres

const CONNINFO = let c = get(ENV, "NITRO_PG_CONNINFO", "")
    isempty(c) && error("set NITRO_PG_CONNINFO to a libpq conninfo (host=… port=… user=… dbname=…)")
    c
end

const PG_DB_KEY = "nitro_pg_race"

# The store under test. A dynamic connection is read-only until writes are enabled; `change_db`
# lets `pormg_nitro_worker` create and upgrade the task table.
function pg_register!()
    haskey(PormG.config, PG_DB_KEY) && return nothing
    PormG.register_connection(PG_DB_KEY, CONNINFO; adapter = "PostgreSQL", env = "test")
    PormG.config[PG_DB_KEY].change_data = true
    PormG.config[PG_DB_KEY].change_db = true
    return nothing
end

pg_store() = (pg_register!(); Nitro.pormg_nitro_worker(db_key = PG_DB_KEY))

# The drain job: it records which consumer ran which task, one marker file per (tag, consumer),
# so a row run twice -- by two consumers, or twice by one -- shows up as a second file.
Base.@kwdef struct DrainWork
    tag::String
    outdir::String
end

function drain_job(task_info, w::DrainWork)
    path = joinpath(w.outdir, "$(w.tag).$(ENV["NITRO_PG_CONSUMER"]).$(task_info.attempt)")
    isfile(path) && error("ran twice: $path")
    write(path, string(getpid()))
    return w.tag
end

const DRAIN_QUEUE = "drain"
const DECOY_QUEUE = "decoy"           # external, declared, never consumed

function drain_setup!(app)
    declare_queues!(app, [
        DRAIN_QUEUE => External(on_lease_expiry = :fail, max_pending = nothing),
        DECOY_QUEUE => External(on_lease_expiry = :fail, max_pending = nothing),
    ])
    register_job!(drain_job, app, "drain", DrainWork)
    return app
end
