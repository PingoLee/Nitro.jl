# One consumer process of the concurrent-drain scenario (`scenarios.jl`), started by the parent as
#
#   julia --threads=2,2 --project=<env run.jl built> drain_child.jl <outdir>
#
# with `NITRO_PG_CONSUMER` naming it. It marks itself ready, waits for the parent's `go` file --
# the barrier that releases every consumer at once -- then runs `consume!` until the queue is empty.
include(joinpath(@__DIR__, "common.jl"))

const OUTDIR = ARGS[1]
const ME = ENV["NITRO_PG_CONSUMER"]

store = pg_store()
app = drain_setup!(App())

# Atomic, so the parent never reads a half-written marker.
write(joinpath(OUTDIR, "$ME.ready.tmp"), string(getpid()))
mv(joinpath(OUTDIR, "$ME.ready.tmp"), joinpath(OUTDIR, "$ME.ready"); force = true)

deadline = time() + 300
while !isfile(joinpath(OUTDIR, "go"))
    time() > deadline && error("$ME: no go signal within 300 s")
    sleep(0.01)
end

reason = consume!(app; store, queues = [DRAIN_QUEUE => 2], lease = 30, poll_interval = 0.05,
                  consumer_id = ME, exit_when_idle = true)
write(joinpath(OUTDIR, "$ME.returned"), string(reason))
