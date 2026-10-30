# `pormg_nitro_pools` (#161): PormG pools close at `terminate`, in the post-drain `on_stopped`
# phase, on real SQLite files. "Closed" is observed the way `close_pool!` leaves a pool: every
# slot's handle taken out (`nothing`). `pool_stats(pool).size` would not show it, since the slot
# count stays.
@testitem "PormG pools close after terminate (#161)" tags=[:extension, :pormg, :network] setup=[NitroCommon] begin

using Test
using HTTP
using Nitro
using PormG
using SQLite
import Nitro: App, path

const CP = PormG.ConnectionPool
pool(key) = PormG.Configuration.get_settings(key).connections
open_handles(key) = Base.lock(() -> count(!isnothing, pool(key).connections), pool(key).lock)
# Open a handle, the way a query does, and return it to the pool.
function touch!(key)
    p = pool(key)
    conn = CP.acquire_connection(p)
    CP.release_connection(p, conn)
    return nothing
end

keys_ = ["nitro_pools_161_a", "nitro_pools_161_b"]
for key in keys_
    PormG.register_connection(key, joinpath(mktempdir(), "$key.sqlite"); adapter = "SQLite", env = "test")
end
try
    @testset "both pools are closed after terminate, and reopen on the next query" begin
        foreach(touch!, keys_)
        @test all(k -> open_handles(k) > 0, keys_)

        ctx = App()
        Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
            path("/q", (req::HTTP.Request) -> (touch!(keys_[1]); Res.send("ok")))
        ])
        port = get_free_port()
        try
            Nitro.Core.serve(ctx; middleware = [pormg_nitro_pools(keys = keys_)], host = HOST,
                             port = port, async = true, show_banner = false, show_errors = false,
                             access_log = nothing)
            @test timedwait(() -> Base.isopen(ctx.service), 10.0) === :ok
            @test HTTP.get("http://$HOST:$port/q"; retry = false).status == 200
            # Still open while serving: the hook is post-drain, not at startup or per request.
            @test open_handles(keys_[1]) > 0

            Nitro.Core.terminate(ctx)
            @test all(k -> open_handles(k) == 0, keys_)

            # A closed pool is not a dead one: the next query reopens it, so a re-serve needs nothing.
            touch!(keys_[1])
            @test open_handles(keys_[1]) > 0
            Nitro.Core.serve(ctx; middleware = [pormg_nitro_pools(keys = keys_)], host = HOST,
                             port = get_free_port(), async = true, show_banner = false,
                             show_errors = false, access_log = nothing)
            @test timedwait(() -> Base.isopen(ctx.service), 10.0) === :ok
            Nitro.Core.terminate(ctx)
            @test open_handles(keys_[1]) == 0
        finally
            # Never leave a listener up for the items after this one.
            Base.isopen(ctx.service) && Nitro.Core.terminate(ctx)
        end
    end

    @testset "a key unregistered after construction does not keep the others open" begin
        # The key form of `close_pool!` looks the key up first, and throws for one that is gone.
        # Listed LAST, so it is closed FIRST: a single loop with no per-key `try` would stop on it.
        gone = "nitro_pools_161_gone"
        PormG.register_connection(gone, joinpath(mktempdir(), "$gone.sqlite"); adapter = "SQLite", env = "test")
        mw = try
            pormg_nitro_pools(keys = [keys_..., gone])
        finally
            PormG.Configuration.close_pool!(gone; drain_seconds = 0)
            delete!(PormG.config, gone)
        end
        foreach(touch!, keys_)
        logger = Test.TestLogger(min_level = Base.CoreLogging.Warn)
        Base.CoreLogging.with_logger(mw.on_stopped, logger)
        @test all(k -> open_handles(k) == 0, keys_)
        failed = filter(r -> occursin("could not close the pool", r.message), logger.logs)
        @test length(failed) == 1
        @test only(failed).kwargs[:key] == gone
    end

    @testset "the hook is on_stopped, nothing else" begin
        mw = pormg_nitro_pools(keys = keys_)
        @test mw isa Nitro.Core.Types.LifecycleMiddleware
        @test mw.on_startup === nothing
        @test mw.on_shutdown === nothing
        @test mw.on_stopped isa Function
        # Passthrough: the request function hands the request on untouched.
        @test mw.middleware(req -> :handled)(HTTP.Request("GET", "/")) === :handled
        # The caller's vector is copied, so mutating it afterwards changes nothing.
        ks = copy(keys_)
        mw2 = pormg_nitro_pools(keys = ks)
        push!(ks, "nitro_pools_161_never_loaded")
        foreach(touch!, keys_)
        mw2.on_stopped()            # would throw on the pushed key if it had been captured
        @test all(k -> open_handles(k) == 0, keys_)
    end

    @testset "construction refuses what it cannot close" begin
        err = try pormg_nitro_pools(keys = ["nitro_pools_161_missing"]); nothing catch e; e end
        @test err isa ArgumentError
        @test occursin("nitro_pools_161_missing", err.msg)
        @test_throws ArgumentError pormg_nitro_pools(keys = String[])
        @test_throws ArgumentError pormg_nitro_pools(keys = keys_, drain_seconds = -1)
        @test_throws ArgumentError pormg_nitro_pools(keys = keys_, drain_seconds = Inf)
        # `keys` is required: no "every loaded key" default.
        @test_throws UndefKeywordError pormg_nitro_pools()
        # Any string type is accepted and copied to `String`.
        @test pormg_nitro_pools(keys = SubString.(keys_, 1)) isa Nitro.Core.Types.LifecycleMiddleware
    end
finally
    # An unbound model falls back to the sole loaded connection, so a leaked key could be picked
    # up by a later item (`pormg_session_tests.jl` does the same).
    for key in keys_
        PormG.Configuration.close_pool!(key; drain_seconds = 0)
        delete!(PormG.config, key)
    end
end

end
