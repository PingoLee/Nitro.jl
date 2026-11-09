# The #813 probe: does `pormg_nitro_pools` put a trim wall on `terminate`'s path?
#
#   PROJECT=bench/juliac/pools ENTRY=pools POOLS=1 OUT=bench/juliac/out/pools1 bench/juliac/build.sh unsafe-warn
#   PROJECT=bench/juliac/pools ENTRY=pools POOLS=0 OUT=bench/juliac/out/pools0 bench/juliac/build.sh unsafe-warn
#
# `pormg_nitro_pools` closes each key's pool from its `on_stopped` hook through
# `PormG.Configuration.close_pool!(key)`, and PormG reaches its pool module there through
# `getfield(parentmodule(@__MODULE__), :ConnectionPool)`, a lookup #813 expected the verifier not to
# type. (It does: the lookup's effects are total, so it folds. The wall was the pool's own type: at
# PormG 0.9.0 `config` held an abstract `PormGSettings`, so `.connections` was an `Any`. Since PormG
# #1622 `config` holds `Settings`, whose `connections` is still an open union, and PormG reaches the
# pool through `ConnectionPool.with_pool`'s closed dispatch.) The two
# builds differ only in `POOLS`, which is read at top level (build time under juliac, as `app.jl`
# reads its knobs): with it, `serve` gets `(pormg_nitro_pools(keys = ["db"]),)`; without it, `()`.
# The rows the first build has and the second does not are what the pools layer costs.
#
# At run time `main` does everything PormG needs, so nothing about the database is in the image:
#   1. registers key "db" on a SQLite file in a fresh temporary directory;
#   2. `ping("db")`, then one lease through the pool narrowed to its concrete type, so the pool has
#      a live slot to close if the image can open one (the string form of `close_pool!` returns
#      early on a pool that was never built). On PormG 0.9.0 (5531c68c) neither could in a trimmed
#      image (`ping` returned `false`; the lease missed in `_is_offline`). At 2d461c3a `ping` is
#      `true`, so a slot is live; the lease still misses, at `release_connection`. The direct
#      `close_pool!` in step 5 is what shows a miss on the close path;
#   3. `serve(app; async = true, middleware)`, one `internalrequest`, then `terminate(app)`;
#   4. counts the live slots again. A missed call inside `on_stopped` is caught there and logged
#      with `@error`, and a trimmed executable prints no `@error` records, so the slots, read as a
#      plain field and never through `ConnectionPool`, are what says whether the close ran. They
#      say only that the slots were emptied: PormG's `_close_pool_slots!` takes the handles out
#      under its lock before anything after it can fail (PormG #1697 fails there, at 2d461c3a);
#   5. calls `close_pool!("db")` itself, with nothing catching it but the probe.
# Every step prints one `step` line to `Core.stdout` (a trimmed executable's `Base.stdout` is
# stale); an exception is printed by its type name only. The exit code is the step that failed
# (0 if none did; the lease is not fatal).
# Run as a script it is the JIT check that the same steps pass.
using Nitro, PormG, SQLite
const HTTP = Nitro.Core.HTTP

const POOLS = get(ENV, "POOLS", "1") == "1"

const app = App()
urlpatterns(app, "", path("/plaintext", req -> Res.send("Hello, World!"); method = "GET"))

say(step::String, detail::String) = (println(Core.stdout, "step\t", step, "\t", detail); nothing)
# An exception by its type name only, and for a `MethodError` the type of the function it missed,
# through `Core.println` (static show; nothing secret is in this process). `@nospecialize`: `e` is
# an `Any`, and a call specialized on its run-time type is a miss of its own in a trimmed image.
@noinline function failed(step::String, @nospecialize(e))
    say(step, string("threw ", nameof(typeof(e))))
    e isa MethodError && Core.println("  missed: ", typeof(e.f))
    return nothing
end

const CP = PormG.ConnectionPool

# The key's pool, narrowed to its concrete type before anything touches it: `Settings.connections`
# is an open union, and a call that takes it from there untyped is a dynamic call in a trimmed image.
# The probe narrows only for its own reads, so the path under test keeps PormG's own types.
function sqlite_pool()
    pool = PormG.Configuration.config["db"].connections
    return pool isa CP.SQLiteConnectionPool ? pool : nothing
end

# Slots holding a handle; `nothing` is an empty slot. A plain field read on the concrete pool.
function live_slots()::Int
    pool = sqlite_pool()
    pool === nothing && return -1
    n = 0
    for c in pool.connections
        c === nothing || (n += 1)
    end
    return n
end

function (@main)(args::Vector{String})::Cint
    say("pools", POOLS ? "(pormg_nitro_pools(keys = [\"db\"]),)" : "()")
    file = joinpath(mktempdir(), "pools.sqlite")
    try
        PormG.Configuration.register_connection("db", file; adapter = "SQLite", env = "dev")
        say("register", "ok")
    catch e
        failed("register", e); return Cint(1)
    end
    # PormG's own health check first, then a lease through the narrowed pool, so a slot is live
    # whichever of the two a trimmed image can run.
    try
        say("ping", string(PormG.Configuration.ping("db")))
    catch e
        failed("ping", e)
    end
    try
        pool = sqlite_pool()
        pool === nothing && (say("lease", "no SQLite pool"); return Cint(2))
        conn = CP.acquire_connection(pool; mode = :read)
        CP.release_connection(pool, conn)
        say("lease", "ok")
        say("slots_before", string(live_slots()))
    catch e
        failed("lease", e)   # not fatal: `terminate` and `close_pool!` below run on the built pool
    end
    try
        middleware = POOLS ? (pormg_nitro_pools(keys = ["db"]),) : ()
        serve(app; host = "127.0.0.1", port = parse(Int, get(ENV, "PORT", "18813")), async = true,
              show_banner = false, access_log = false, middleware)
        say("serve", "ok")
    catch e
        failed("serve", e); return Cint(3)
    end
    try
        res = internalrequest(app, HTTP.Request("GET", "/plaintext"))
        say("request", string(res.status))
    catch e
        failed("request", e); return Cint(4)
    end
    try
        terminate(app)
        say("terminate", "ok")
        say("slots_after", string(live_slots()))
    catch e
        failed("terminate", e); return Cint(5)
    end
    # The key form once more, directly: what `on_stopped` called, with nothing catching it.
    rc = Cint(0)
    try
        PormG.Configuration.close_pool!("db"; drain_seconds = 0)
        say("close_pool_direct", "ok")
    catch e
        failed("close_pool_direct", e); rc = Cint(6)
    end
    say("slots_end", string(live_slots()))
    return rc
end
