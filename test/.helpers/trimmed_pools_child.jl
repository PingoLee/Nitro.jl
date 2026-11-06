# The child `test/extensions/pormg_pools_tests.jl` spawns for #846. Run as a script:
#
#     julia --project=<the test env> test/.helpers/trimmed_pools_child.jl
#
# A trimmed executable prints no log record (docs/design/juliac-trim.md §3.16), so
# `pormg_nitro_pools`' `on_stopped` writes one value-free line to `Core.stderr` beside its `@error`
# when a key's close throws. Under the JIT that call folds away, so this child redefines `_trimmed()`
# to `true` the way a `--trim` build's first route registration does, then runs the hook over a
# key unregistered since construction, the one failure a pool's close has.
#
# Its records go to a `NullLogger`, so what reaches stderr is the trimmed line alone, which the
# parent reads. stdout carries `CLOSED=<whether the registered key's pool closed>` and `DONE`.

import Nitro, PormG, SQLite

const T = Nitro.Core.Types

dir = mktempdir()
kept = "nitro_pools_846_kept"
gone = "nitro_pools_846_gone"
for key in (kept, gone)
    PormG.register_connection(key, joinpath(dir, "$key.sqlite"); adapter = "SQLite", env = "test")
end

# `gone` last, so it is closed first: the line must not stop the loop from closing `kept`.
mw = Nitro.pormg_nitro_pools(keys = [kept, gone])
PormG.Configuration.close_pool!(gone; drain_seconds = 0)
delete!(PormG.config, gone)

pool = PormG.Configuration.get_settings(kept).connections
conn = PormG.ConnectionPool.acquire_connection(pool)
PormG.ConnectionPool.release_connection(pool, conn)

Core.eval(T, :(_trimmed() = true))

Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
    T.stopped(mw)
end

closed = Base.lock(() -> count(!isnothing, pool.connections) == 0, pool.lock)
println("CLOSED=", closed)
println("DIR=", dir)
println("DONE")
