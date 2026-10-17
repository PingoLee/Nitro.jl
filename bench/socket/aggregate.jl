# The in-memory aggregation behind `/aggregate` (#590), shared by `server.jl` and
# `suite/aggregate.jl` so the route and the kernel row run the same loop. `go/aggregate.go` is the
# same generator and the same loops in Go: compare the two files line for line before changing
# either.
#
# The data is a `Vector` of unboxed rows built once from a fixed seed with splitmix64, written out
# rather than taken from `Random` so Go can generate the identical rows: both languages aggregate
# the same numbers, and their sums agree to rounding. 100 distinct keys.
#
# The kernels are plain loops over the first `n` rows: no `@simd`, no `@turbo`, no BLAS, no
# fan-out. Without `@simd` LLVM keeps the floating-point sum in source order, as Go does, so the
# comparison is the language's plain loop.

struct AggRow
    id::Int
    key::Int
    value::Float64
end

const AGG_KEYS = 100
const AGG_SEED = 0x000000000000002a

# One splitmix64 step: the new state and its output.
@inline function splitmix64(state::UInt64)
    state += 0x9e3779b97f4a7c15
    z = state
    z = (z ⊻ (z >> 30)) * 0xbf58476d1ce4e5b9
    z = (z ⊻ (z >> 27)) * 0x94d049bb133111eb
    return state, z ⊻ (z >> 31)
end

# Row i: id = i, key = one draw mod 100, value = the next draw's top 53 bits scaled to [0, 1000).
function agg_rows(n::Int)::Vector{AggRow}
    rows = Vector{AggRow}(undef, n)
    state = AGG_SEED
    for i in 1:n
        state, a = splitmix64(state)
        state, b = splitmix64(state)
        rows[i] = AggRow(i, Int(a % UInt64(AGG_KEYS)), Float64(b >> 11) * 0x1p-53 * 1000.0)
    end
    return rows
end

function agg_sum(rows::Vector{AggRow}, n::Int)::Float64
    s = 0.0
    @inbounds for i in 1:n
        s += rows[i].value
    end
    return s
end

agg_mean(rows::Vector{AggRow}, n::Int)::Float64 = agg_sum(rows, n) / n

function agg_groupby(rows::Vector{AggRow}, n::Int)::Dict{Int, Float64}
    sums = Dict{Int, Float64}()
    @inbounds for i in 1:n
        r = rows[i]
        sums[r.key] = get(sums, r.key, 0.0) + r.value
    end
    return sums
end

# The same loops with a `yield()` every `every_ms` (#590): §5's cooperative fallback for a loop
# that must stay in the handler, as `server.jl`'s `burn_yielding` is for `/cpu`. The clock is read
# once per AGG_CHUNK rows (~180 µs of groupby, ~12 µs of sum), not per row, so the check costs
# next to nothing; the rows inside a chunk run the plain loop above. No Go twin: Go preempts.
const AGG_CHUNK = 16_384

function agg_sum_yielding(rows::Vector{AggRow}, n::Int, every_ms::Float64)::Float64
    s = 0.0
    step = round(UInt64, every_ms * 1e6)
    next = time_ns() + step
    i = 1
    @inbounds while i <= n
        stop = min(i + AGG_CHUNK - 1, n)
        for j in i:stop
            s += rows[j].value
        end
        i = stop + 1
        if time_ns() >= next
            yield()
            next = time_ns() + step
        end
    end
    return s
end

function agg_groupby_yielding(rows::Vector{AggRow}, n::Int, every_ms::Float64)::Dict{Int, Float64}
    sums = Dict{Int, Float64}()
    step = round(UInt64, every_ms * 1e6)
    next = time_ns() + step
    i = 1
    @inbounds while i <= n
        stop = min(i + AGG_CHUNK - 1, n)
        for j in i:stop
            r = rows[j]
            sums[r.key] = get(sums, r.key, 0.0) + r.value
        end
        i = stop + 1
        if time_ns() >= next
            yield()
            next = time_ns() + step
        end
    end
    return sums
end

# The response body: one number, or the 100 key => sum pairs (keys as JSON strings). `yield_ms > 0`
# runs the yielding loops (`mean` is `sum`'s, divided).
function agg_body(rows::Vector{AggRow}, n::Int, op::AbstractString, yield_ms::Float64 = 0.0)::String
    if yield_ms > 0
        op == "sum"     && return JSON.json(Dict("sum" => agg_sum_yielding(rows, n, yield_ms)))
        op == "mean"    && return JSON.json(Dict("mean" => agg_sum_yielding(rows, n, yield_ms) / n))
        op == "groupby" && return JSON.json(agg_groupby_yielding(rows, n, yield_ms))
    else
        op == "sum"     && return JSON.json(Dict("sum" => agg_sum(rows, n)))
        op == "mean"    && return JSON.json(Dict("mean" => agg_mean(rows, n)))
        op == "groupby" && return JSON.json(agg_groupby(rows, n))
    end
    throw(ArgumentError("op must be sum, mean or groupby, got $op"))
end
