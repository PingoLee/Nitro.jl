# #782 run 2: what a bound `ScopedValue` scope costs PormG's per-statement reads. Not a server;
# one process, against the same database `world.jl` serves, in three parts:
#
#   1. Each `ScopedValue` read on PormG's statement path (`_tx_context[]`,
#      `transaction_connection_for`, the logger's `current_logger()`), timed in a loop with no scope
#      and inside `@with` of one unrelated key (the shape `bare_scoped` and Nitro's pipeline bind).
#   2. `world().get(...)` statements one after another on one task, alternating batches with no
#      scope and with that one key bound: the whole per-statement difference, driver included.
#   3. How many `ScopedValue` reads one `world().get(...)` makes, by key. It overwrites
#      `Base.ScopedValues.get` in this process to count them, so it runs last.
#
#   DB=postgres PG_DRIVER=Postgres julia --project=bench/socket/db bench/socket/db/scope_micro.jl
#
# PG_DRIVER=Postgres|LibPQ as in `env.sh` (default Postgres here: #782 is about that driver).
# READS (default 10^6) per timed read loop, STMTS (default 1000) statements per batch, BATCHES
# (default 8, alternating) per part 2.
const DRIVER = get(ENV, "PG_DRIVER", "Postgres")
DRIVER == "Postgres" && (ENV["PORMG_POSTGRES_DRIVER"] = "Postgres")
using PormG, HTTP, JSON
DRIVER == "Postgres" ? (@eval using Postgres) : (@eval using LibPQ)
using Base.ScopedValues: ScopedValue, @with
using Printf

include(joinpath(@__DIR__, "world.jl"))

const READS   = parse(Int, get(ENV, "READS", "1000000"))
const STMTS   = parse(Int, get(ENV, "STMTS", "1000"))
const BATCHES = parse(Int, get(ENV, "BATCHES", "8"))

mutable struct BenchScope
    const n::Int
end
const BENCH_SCOPE = ScopedValue{BenchScope}(BenchScope(0))
const BENCH_SCOPE_VALUE = BenchScope(1)

const CFG  = PormG.Configuration
const POOL = PormG.config[DB_KEY].connections

println("julia ", VERSION, ", threads ", Threads.nthreads(:default), ",", Threads.nthreads(:interactive),
        ", PormG ", pkgversion(PormG), ", driver ", DRIVER, " ", DRIVER == "Postgres" ? pkgversion(Postgres) : "",
        ", pool ", typeof(POOL))

scoped(f) = @with BENCH_SCOPE => BENCH_SCOPE_VALUE f()
# Every part runs on a task spawned from the main task, which binds nothing, so "none" is the
# empty-scope fast path a `bare_spawn` handler is on.
on_task(f) = fetch(Threads.@spawn f())

# ---- 1. single reads ----------------------------------------------------------------------------
@noinline read_tx()     = CFG._tx_context[]
@noinline read_txfor()  = CFG.transaction_connection_for(POOL)
@noinline read_logger() = Base.CoreLogging.current_logger()

function read_loop(f::F, n::Int)::Float64 where {F}
    acc = 0
    t0 = time_ns()
    for _ in 1:n
        acc += f() === nothing ? 1 : 0
    end
    dt = time_ns() - t0
    acc == -1 && println("unreachable")
    return dt / n
end

println("\n1. ns per read, min of 7 loops of $READS (median in brackets)")
@printf("   %-34s %10s %10s %8s\n", "read", "no scope", "one key", "delta")
for (name, f) in (("_tx_context[]", read_tx), ("transaction_connection_for(pool)", read_txfor),
                  ("current_logger()", read_logger))
    none = Float64[]; one = Float64[]
    for _ in 1:7
        push!(none, on_task(() -> read_loop(f, READS)))
        push!(one,  on_task(() -> scoped(() -> read_loop(f, READS))))
    end
    sort!(none); sort!(one)
    @printf("   %-34s %6.1f [%5.1f] %6.1f [%5.1f] %+8.1f\n", name, none[1], none[4], one[1], one[4], one[1] - none[1])
end

# ---- 2. statements ------------------------------------------------------------------------------
function stmt_batch(n::Int)::Float64
    t0 = time_ns()
    for _ in 1:n
        world().get("id" => random_id())
    end
    return (time_ns() - t0) / n / 1000
end

on_task(() -> stmt_batch(200)); on_task(() -> scoped(() -> stmt_batch(200)))   # warm both
println("\n2. µs per `world().get` statement, one task, $STMTS per batch, batches alternating ABBA")
none = Float64[]; one = Float64[]
for b in 1:BATCHES
    for which in (isodd(b) ? (:none, :one) : (:one, :none))   # ABBA: none, one, one, none, ...
        us = which === :none ? on_task(() -> stmt_batch(STMTS)) : on_task(() -> scoped(() -> stmt_batch(STMTS)))
        push!(which === :none ? none : one, us)
    end
end
med(v) = (s = sort(v); n = length(s); isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)
@printf("   no scope: median %.1f [%.1f–%.1f]\n", med(none), minimum(none), maximum(none))
@printf("   one key:  median %.1f [%.1f–%.1f]\n", med(one), minimum(one), maximum(one))
@printf("   delta (one key - no scope): %+.1f µs per statement (medians)\n", med(one) - med(none))
println("   batches, no scope: ", join((@sprintf("%.1f", x) for x in none), " "))
println("   batches, one key:  ", join((@sprintf("%.1f", x) for x in one), " "))

# ---- 3. reads per statement ---------------------------------------------------------------------
# `get` is the one read path in Base: `getindex` and the logger's `current_logstate` both call it.
# Overwritten with a counter in front of Julia's own body (1.13), copied unchanged.
const COUNTING = Threads.Atomic{Bool}(false)
const COUNT_LOCK = Threads.SpinLock()
const COUNTS = Dict{Any, Int}()   # typeof(val) => reads
function count_read(@nospecialize(val))
    COUNTING[] || return nothing
    lock(COUNT_LOCK)
    try
        COUNTS[typeof(val)] = get(COUNTS, typeof(val), 0) + 1
    finally
        unlock(COUNT_LOCK)
    end
    return nothing
end
@eval Base.ScopedValues function get(val::AbstractScopedValue{T}) where {T}
    $count_read(val)
    scope = Core.current_scope()::Union{Scope, Nothing}
    if scope === nothing
        !hasdefault(val) && return nothing
        return Some{T}(getdefault(val))
    end
    scope = scope::Scope
    if hasdefault(val)
        return Some{T}(Base.get(Base.Fix1(getdefault, val), scope.values, val)::T)
    else
        v = Base.KeyValue.get(scope.values, val)
        v === nothing && return nothing
        return Some{T}(only(v)::T)
    end
    return nothing
end

function count_reads(n::Int, bound::Bool)
    on_task(() -> bound ? scoped(() -> stmt_batch(5)) : stmt_batch(5))   # compile the counted path
    empty!(COUNTS)
    COUNTING[] = true
    on_task(() -> bound ? scoped(() -> stmt_batch(n)) : stmt_batch(n))
    COUNTING[] = false
    return copy(COUNTS)
end
# The counter must see both read sites the statement path uses, or its totals mean nothing.
empty!(COUNTS); COUNTING[] = true; read_tx(); Base.CoreLogging.current_logger(); COUNTING[] = false
self_check = sum(values(COUNTS); init = 0)
println("\n3. ScopedValue reads per `world().get` statement, by value type (100 statements; counter self-check: $self_check of 2)")
for bound in (false, true)
    c = count_reads(100, bound)
    total = sum(values(c); init = 0)
    println("   ", bound ? "one key bound" : "no scope     ", ": ", total / 100, " per statement")
    for (k, v) in sort!(collect(c); by = last, rev = true)
        @printf("     %-60s %6.2f\n", string(k), v / 100)
    end
end
