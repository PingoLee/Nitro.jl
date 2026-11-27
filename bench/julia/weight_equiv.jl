# The candidate's fifth version (#618) against its fourth, off the scheduler: does the weight's new scale change any
# choice the account makes, and can the new interval conversion throw or overflow where `Int` is `Int32`?
#
#   julia bench/julia/weight_equiv.jl [nseq]        (default 10^6 sequences; exit 0 only if every check holds)
#
# `fair_deletemin` (base/partr.jl) keeps a per-thread account (bal, stamp, last, k). v4 keeps the weight in quarters
# (`fp.w4`, 1..3), the account and the interval as `Int`, the balance within twice the cap, and converts the interval
# before it clamps it: `d = now > s.stamp ? Int(now - s.stamp) : 0`. v5 keeps the weight in thousandths (`fp.w`,
# 1..999, 500 by default), the account, the interval and the cap as `Int64`, clamps the interval to the cap in
# `UInt64` and converts after, and rescales the balance's bound with the weight: 2·cap·(1000/4) = 500·cap. Both
# rules below are transcriptions of the patch text (v4: candidate-v4/0001 with attempt-clock-read-when-used.patch;
# v5: candidate-v5/0001), pure functions of the state and of the pop's inputs: the three emptiness flags (lw, rr,
# rf), the clock value the read would return, and the pop's outcome, which each rule turns into a side through its
# own `rfirst` (the same `pop_side!` as clock_read_equiv.jl).
#
# PROOF 1. At w = 1/4, 1/2 and 3/4 (v4: w4 = 1, 2, 3; v5: w = 250, 500, 750), at every step: the same choice
#   (`rfirst`), the same `last`, the same `k`, the same stamp, and v5's balance exactly 250 times v4's.
#   THE NEGATIVE CONTROL: v5's rule with the bound left at v4's 2·cap must fail the same assertions.
# PROOF 2. v5's update with every integer typed as a 32-bit build types it (`Int32` where the patch says `Int`,
#   `Int64` where it says `Int64`, `UInt64` where it says `UInt64`), every operation checked for overflow, fed
#   intervals from 0 to 2^63 ns (and stamps that go backwards), every weight 1..999, balances at and inside the
#   bound: no InexactError and no overflow. THE NEGATIVE CONTROL: v4's conversion in the same model must throw past
#   2^31 ns (and not below it).
using Random
using Base.Checked: checked_add, checked_sub, checked_mul

# ---------------------------------------------------------------------------------------------------------------
# Proof 1: the two rules at the box's word size (Int = Int64).

mutable struct Acct{T}
    bal::T
    stamp::UInt64
    last::Int
    k::Int
end
Acct{T}() where {T} = Acct{T}(zero(T), UInt64(0), 0, 0)

# v4's credit (candidate-v4: the weight in quarters, the bound twice the cap, the conversion before the clamp).
@inline function credit_v4!(s::Acct{Int}, now::UInt64, cap::Int, w4::Int)
    if s.last != 0 && s.k != 0
        d = now > s.stamp ? Int(now - s.stamp) : 0
        if d > cap
            d = cap
        end
        b = s.last == 1 ? s.bal + d * (4 - w4) : s.bal - d * w4
        if b > 2 * cap
            b = 2 * cap
        elseif b < -2 * cap
            b = -2 * cap
        end
        s.bal = b
    end
    return nothing
end

# v5's credit (candidate-v5: thousandths, Int64, the clamp in UInt64 before the conversion, the bound rescaled).
# `lim` is the balance's bound as a multiple of the cap: 500 in v5; the negative control passes 2 (v4's, unscaled).
@inline function credit_v5!(s::Acct{Int64}, now::UInt64, cap::Int64, w::Int64, lim::Int64)
    if s.last != 0 && s.k != 0
        du = now > s.stamp ? now - s.stamp : zero(UInt64)
        if du > cap % UInt64
            du = cap % UInt64
        end
        d = du % Int64
        b = s.last == 1 ? s.bal + d * (1000 - w) : s.bal - d * w
        bmax = lim * cap
        if b > bmax
            b = bmax
        elseif b < -bmax
            b = -bmax
        end
        s.bal = b
    end
    return nothing
end

# The clock only when its value is used (v4's read rule, unchanged in v5).
@inline function upd!(credit::F, s::Acct, lw::Bool, rr::Bool, rf::Bool, clock::UInt64) where {F}
    both = lw && (rr || rf)
    if s.k != 0 || both
        credit(s, clock)
        s.stamp = clock
    end
    s.k = both ? 1 : 0
    return nothing
end

# The rest of the pop (as clock_read_equiv.jl): the choice and the side returned.
function pop_side!(s::Acct, lw::Bool, rr::Bool, rf::Bool, o1::Bool, o2::Bool)
    rfirst = false
    side = 0
    got = false
    if lw && (rr || rf)
        rfirst = s.bal < 0
        if rfirst
            got, side = o1 ? (true, 1) : (o2, 2)
        else
            got, side = o1 ? (true, 2) : (o2, 1)
        end
    elseif rr || rf
        got, side = o1 ? (true, 1) : (o2, 2)
    elseif lw
        got, side = o1, 2
    end
    s.last = got ? side : 0
    return rfirst
end

struct Failure
    seq::Int
    step::Int
    what::String
    trace::Vector{String}
end

function proof1(nseq::Int, lim::Int64; seed::Int = 618)
    rng = Xoshiro(seed)
    cov = Dict{Symbol,Int}()
    bump(k) = (cov[k] = get(cov, k, 0) + 1)
    flags = zeros(Int, 8)
    npops = 0
    for q in 1:nseq
        cap = rand(rng, (1_000, 10_000_000))   # a small cap (clips and balance limits often) and the real one
        w4 = rand(rng, 1:3)
        w = Int64(250 * w4)
        bump(Symbol("w4_", w4))
        a, b = Acct{Int}(), Acct{Int64}()
        c4 = (s, now) -> credit_v4!(s, now, cap, w4)
        c5 = (s, now) -> credit_v5!(s, now, Int64(cap), w, lim)
        clock = UInt64(rand(rng, 1:10cap))
        n = rand(rng, 1:48)
        trace = String[]
        for t in 1:n
            lw, rr, rf = rand(rng, Bool), rand(rng, Bool), rand(rng, Bool)
            flags[1 + lw + 2rr + 4rf] += 1
            r = rand(rng)
            dt = r < 0.1 ? 0 : r < 0.6 ? rand(rng, 0:cap ÷ 4) : r < 0.9 ? rand(rng, 0:2cap) : rand(rng, cap:20cap)
            dt > cap && bump(:step_above_cap)
            clock += UInt64(dt)
            o1, o2 = rand(rng) < 0.85, rand(rng) < 0.5
            !o1 && !o2 && (lw || rr || rf) && bump(:empty_return)
            upd!(c4, a, lw, rr, rf, clock)
            upd!(c5, b, lw, rr, rf, clock)
            abs(a.bal) == 2cap && bump(:balance_at_limit)
            fa = pop_side!(a, lw, rr, rf, o1, o2)
            fb = pop_side!(b, lw, rr, rf, o1, o2)
            npops += 1
            push!(trace, string("step ", t, ": lw=", lw, " rr=", rr, " rf=", rf, " clock+", dt, " o=", o1, "/", o2,
                                " | v4 bal=", a.bal, " last=", a.last, " k=", a.k,
                                " | v5 bal=", b.bal, " (", b.bal / 250, " x250) last=", b.last, " k=", b.k))
            fa != fb && return Failure(q, t, "rfirst differs", trace), cov, flags, npops
            b.bal == 250 * Int64(a.bal) || return Failure(q, t, "v5's balance is not 250 times v4's", trace), cov, flags, npops
            a.last == b.last && a.k == b.k || return Failure(q, t, "last or k differs", trace), cov, flags, npops
            a.stamp == b.stamp || return Failure(q, t, "stamp differs", trace), cov, flags, npops
        end
    end
    return nothing, cov, flags, npops
end

# ---------------------------------------------------------------------------------------------------------------
# Proof 2: the 32-bit model. `I` is what the patch's `Int` is on a 32-bit build. Every operation is checked: an
# overflow throws OverflowError, a conversion that does not fit throws InexactError (as the real one would).

mutable struct Acct32
    bal::Int64     # v5: Int64 on every platform
    stamp::UInt64
    last::Int32    # `Int`
    k::Int32       # `Int`
end

# v5's credit, 32-bit typed, every operation checked. `cap` and `w` are Int64 (the fields' declared type).
function credit_v5_32!(s::Acct32, now::UInt64, cap::Int64, w::Int64)
    if s.last != Int32(0) && s.k != Int32(0)
        du = now > s.stamp ? checked_sub(now, s.stamp) : zero(UInt64)
        capu = UInt64(cap)                            # checked: cap > 0
        if du > capu
            du = capu
        end
        d = Int64(du)                                 # checked: throws if du does not fit
        b = s.last == Int32(1) ? checked_add(s.bal, checked_mul(d, checked_sub(Int64(1000), w))) :
                                 checked_sub(s.bal, checked_mul(d, w))
        bmax = checked_mul(Int64(Int32(500)), cap)    # the literal 500 is an `Int` (Int32), promoted
        if b > bmax
            b = bmax
        elseif b < checked_sub(Int64(0), bmax)
            b = checked_sub(Int64(0), bmax)
        end
        s.bal = b
    end
    return nothing
end

# v4's conversion, 32-bit typed: `Int(now - s.stamp)` where `Int` is Int32.
v4_conv_32(now::UInt64, stamp::UInt64) = now > stamp ? Int32(now - stamp) : Int32(0)

function proof2(nrand::Int; seed::Int = 6180)
    rng = Xoshiro(seed)
    cap = Int64(10_000_000)
    bmax = 500cap
    edges = UInt64[0, 1, 2, cap - 1, cap, cap + 1, 2cap, typemax(Int32) - 1, typemax(Int32), UInt64(typemax(Int32)) + 1,
                   typemax(UInt32), UInt64(typemax(UInt32)) + 1, UInt64(2)^40, UInt64(2)^62, typemax(Int64) - 1,
                   typemax(Int64), UInt64(2)^63]
    stamps = UInt64[0, 1, cap, typemax(Int32), UInt64(2)^62, typemax(Int64), UInt64(2)^63, typemax(UInt64) - UInt64(2)^63]
    bals = Int64[-bmax, -bmax + 1, -1, 0, 1, bmax - 1, bmax]
    n = 0
    # every edge interval, forwards and backwards from every stamp, every weight 1..999, both sides, balances at
    # and inside the bound
    for st in stamps, dt in edges, back in (false, true), w in Int64(1):Int64(999), last in Int32(1):Int32(2), b0 in bals
        now = back ? (st >= dt ? st - dt : UInt64(0)) : (st <= typemax(UInt64) - dt ? st + dt : typemax(UInt64))
        s = Acct32(b0, st, last, Int32(1))
        try
            credit_v5_32!(s, now, cap, w)
        catch e
            return (string("v5 threw ", typeof(e), " at stamp ", st, ", interval ", back ? "-" : "+", dt, ", w ", w,
                           ", last ", last, ", bal ", b0)), n
        end
        abs(s.bal) <= bmax || return ("v5's balance left its bound: ", s.bal), n
        n += 1
    end
    # random intervals, log-uniform over 0..2^63, random stamps, random weights and balances
    for _ in 1:nrand
        st = rand(rng, UInt64)
        e = rand(rng, 0:63)
        dt = e == 0 ? UInt64(0) : rand(rng, (UInt64(1) << (e - 1)):((UInt64(1) << e) - UInt64(1)))   # 2^63 is an edge
        back = rand(rng, Bool)
        now = back ? (st >= dt ? st - dt : UInt64(0)) : (st <= typemax(UInt64) - dt ? st + dt : typemax(UInt64))
        w = rand(rng, Int64(1):Int64(999))
        s = Acct32(rand(rng, -bmax:bmax), st, rand(rng, Int32(1):Int32(2)), Int32(1))
        try
            credit_v5_32!(s, now, cap, w)
        catch e
            return (string("v5 threw ", typeof(e), " at stamp ", st, ", interval ", back ? "-" : "+", dt, ", w ", w)), n
        end
        abs(s.bal) <= bmax || return ("v5's balance left its bound: ", s.bal), n
        n += 1
    end
    return nothing, n
end

# The negative control of proof 2: v4's conversion throws past 2^31 - 1 ns, and not at or below it.
function proof2_negative()
    below = UInt64[0, 1, 10_000_000, typemax(Int32) - 1, typemax(Int32)]
    above = UInt64[UInt64(typemax(Int32)) + 1, typemax(UInt32), UInt64(2)^40, UInt64(2)^63]
    for d in below
        try
            v4_conv_32(UInt64(1) + d, UInt64(1))
        catch e
            return string("v4's conversion threw at ", d, " ns, at or below 2^31 - 1")
        end
    end
    first_throw = nothing
    for d in above
        try
            v4_conv_32(UInt64(1) + d, UInt64(1))
            return string("v4's conversion did not throw at ", d, " ns")
        catch e
            e isa InexactError || return string("v4's conversion threw ", typeof(e), ", not InexactError")
            first_throw === nothing && (first_throw = d)
        end
    end
    return first_throw
end

function main(nseq::Int)
    ok = true
    t0 = time()
    f, cov, flags, npops = proof1(nseq, Int64(500))
    println("PROOF 1: v4 against v5, ", nseq, " sequences, ", npops, " pops (", round(time() - t0; digits = 1), " s)")
    println("  flag combinations (lw + 2rr + 4rf => count): ", join(("$(i - 1)=>$(flags[i])" for i in 1:8), ", "))
    for k in sort(collect(keys(cov)))
        println("  ", rpad(k, 22), cov[k])
    end
    if f === nothing
        println("  EQUAL at every step: rfirst, last, k and stamp; v5's balance is 250 times v4's")
    else
        ok = false
        println("  DIFFER: sequence ", f.seq, ", step ", f.step, ": ", f.what)
        foreach(l -> println("    ", l), f.trace)
    end
    for k in (:empty_return, :step_above_cap, :balance_at_limit, :w4_1, :w4_2, :w4_3)
        get(cov, k, 0) > 0 || (ok = false; println("  COVERAGE MISSING: ", k))
    end
    all(>(0), flags) || (ok = false; println("  COVERAGE MISSING: a flag combination"))
    fn, _, _, _ = proof1(nseq, Int64(2))
    if fn === nothing
        ok = false
        println("  negative control (v5's rule, the bound left at 2 cap): PASSED, so the check cannot see the bound")
    else
        println("  negative control (v5's rule, the bound left at 2 cap): fails as it must, at sequence ", fn.seq,
                ", step ", fn.step, ": ", fn.what)
        foreach(l -> println("    ", l), fn.trace[max(1, end - 2):end])
    end
    t0 = time()
    f2, n2 = proof2(10 * nseq)
    println("PROOF 2: v5's update, 32-bit typed, checked arithmetic, ", n2, " updates (", round(time() - t0; digits = 1), " s)")
    if f2 === nothing
        println("  no InexactError and no overflow, intervals 0..2^63 ns forwards and backwards, every weight 1..999")
    else
        ok = false
        println("  FAILED: ", f2)
    end
    neg = proof2_negative()
    if neg isa UInt64
        println("  negative control (v4's `Int(now - s.stamp)` with Int = Int32): throws InexactError past 2^31 - 1 ns ",
                "(first above: ", neg, " ns), not at or below it")
    else
        ok = false
        println("  negative control FAILED: ", neg)
    end
    println(ok ? "RESULT: v5's account is v4's x 250 on every step, and its 32-bit model neither throws nor overflows" :
                 "RESULT: FAILED")
    return ok
end

exit(main(isempty(ARGS) ? 10^6 : parse(Int, ARGS[1])) ? 0 : 1)
