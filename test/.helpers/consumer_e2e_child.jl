# The consumer process of the two-process test (`test/workers_consumer_e2e_tests.jl`): the same
# setup function as the web side, then `consume!` and nothing else, as a deployed consumer runs.
#
#   julia --threads=2,1 --project=<test env> consumer_e2e_child.jl <db spec> <outdir> <consumer id> <lease s>
using Nitro, Nitro.Workers, PormG, SQLite, Dates
include(joinpath(@__DIR__, "consumer_e2e_setup.jl"))

dbspec, outdir, consumer_id, lease = ARGS[1], ARGS[2], ARGS[3], parse(Float64, ARGS[4])
e2e_is_postgres(dbspec) && @eval using LibPQ
store = e2e_store(dbspec)
app = e2e_setup!(App())
write(joinpath(outdir, "$consumer_id.ready"), string(getpid()))
consume!(app; store, queues = ["requeue" => 2, "fail" => 1], lease, poll_interval = 0.1,
         drain_timeout = 10, consumer_id)
# Reached only when the wait returns normally; a SIGTERM exits through the `atexit` drain instead.
write(joinpath(outdir, "$consumer_id.returned"), "")
