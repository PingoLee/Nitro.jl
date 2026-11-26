# The candidate's fourth version (#618) against its third, off the scheduler: does reading the clock only when its
# value is used change anything the account decides?
#
#   julia bench/julia/clock_read_equiv.jl [nseq]        (default 10^6 sequences; exit 0 only if every check holds)
#
# `fair_deletemin` (base/partr.jl) keeps a per-thread account (bal, stamp, last, k). v3 reads the clock at every pop
# while the flag is set; v4 reads it only when the value is used: to close the interval the previous pop opened
# (`s.k != 0`) or to open one at this pop (both sides have work now). The three update rules below are transcriptions
# of the patch text (v3: candidate-v3/0001, lines 568-590; v4: candidate-v4/attempt-clock-read-when-used.patch), pure
# functions of the state and of the pop's inputs: the three emptiness flags (lw, rr, rf), the clock value the read
# would return, and the pop's outcome. The outcome is drawn once per step and shared by the rules; each rule turns it
# into the side the pop returned through its own `rfirst`, as the function does, so a different balance shows up as
# a different side.
#
# Asserted at every step, v3 against v4: the same balance, the same choice (`rfirst`), the same `last` and `k`. The
# stamps may differ only where neither rule reads them at the next pop (a read needs `last != 0 && k != 0`).
# THE NEGATIVE CONTROL: a third rule that reads the clock only when both sides have work now (the `s.k != 0` arm
# dropped) must fail the same assertions; if it passes, the check cannot see the difference, and the run fails.
using Random

mutable struct Acct
    bal::Int
    stamp::UInt64
    last::Int
    k::Int
end
Acct() = Acct(0, UInt64(0), 0, 0)
same(a::Acct, b::Acct) = a.bal == b.bal && a.last == b.last && a.k == b.k
Base.copy(a::Acct) = Acct(a.bal, a.stamp, a.last, a.k)

# The credit, as the patch writes it (unchanged between v3 and v4).
@inline function credit!(s::Acct, now::UInt64, cap::Int, w4::Int)
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

# v3: the clock at every pop.
function upd_v3!(s::Acct, lw::Bool, rr::Bool, rf::Bool, clock::UInt64, cap::Int, w4::Int)
    now = clock
    credit!(s, now, cap, w4)
    s.stamp = now
    s.k = lw && (rr || rf) ? 1 : 0
    return true                       # the clock was read
end

# v4: the clock only when its value is used.
function upd_v4!(s::Acct, lw::Bool, rr::Bool, rf::Bool, clock::UInt64, cap::Int, w4::Int)
    both = lw && (rr || rf)
    read = s.k != 0 || both
    if read
        now = clock
        credit!(s, now, cap, w4)
        s.stamp = now
    end
    s.k = both ? 1 : 0
    return read
end

# The negative control: the clock only when both sides have work now (the `s.k != 0` arm dropped).
function upd_neg!(s::Acct, lw::Bool, rr::Bool, rf::Bool, clock::UInt64, cap::Int, w4::Int)
    both = lw && (rr || rf)
    if both
        now = clock
        credit!(s, now, cap, w4)
        s.stamp = now
    end
    s.k = both ? 1 : 0
    return both
end

# The rest of the pop, as the function has it: the choice and the side returned. `o1`/`o2`: whether the first and
# the second attempt return a task (a race can empty a queue that read non-empty, so either can fail).
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
    return rfirst, s.last
end

struct Failure
    seq::Int
    step::Int
    what::String
    trace::Vector{String}
end

# One run of `nseq` sequences, rule `upd_b!` against v3. Returns (the first failure or nothing, coverage counters).
function run(upd_b!::F, nseq::Int; seed::Int = 618) where {F}
    rng = Xoshiro(seed)
    cov = Dict{Symbol,Int}()
    bump(k) = (cov[k] = get(cov, k, 0) + 1)
    flags = zeros(Int, 8)
    for q in 1:nseq
        cap = rand(rng, (1_000, 10_000_000))           # a small cap (clips and balance limits often) and the real one
        w4 = rand(rng, 1:3)
        bump(Symbol("w4_", w4))
        a, b = Acct(), Acct()
        clock = UInt64(rand(rng, 1:10cap))
        n = rand(rng, 1:48)
        trace = String[]
        for t in 1:n
            # flags: each side non-empty with probability 1/2 at every pop (both sides: 3/8)
            lw, rr, rf = rand(rng, Bool), rand(rng, Bool), rand(rng, Bool)
            flags[1 + lw + 2rr + 4rf] += 1
            # the clock: no step, a small step, a step around the cap, or one far above it
            r = rand(rng)
            dt = r < 0.1 ? 0 : r < 0.6 ? rand(rng, 0:cap ÷ 4) : r < 0.9 ? rand(rng, 0:2cap) : rand(rng, cap:20cap)
            dt > cap && bump(:step_above_cap)
            clock += UInt64(dt)
            o1, o2 = rand(rng) < 0.85, rand(rng) < 0.5
            !o1 && !o2 && (lw || rr || rf) && bump(:empty_return)
            ra = upd_v3!(a, lw, rr, rf, clock, cap, w4)
            rb = upd_b!(b, lw, rr, rf, clock, cap, w4)
            ra && !rb && bump(:read_skipped)
            abs(a.bal) == 2cap && bump(:balance_at_limit)
            fa = pop_side!(a, lw, rr, rf, o1, o2)
            fb = pop_side!(b, lw, rr, rf, o1, o2)
            push!(trace, string("step ", t, ": lw=", lw, " rr=", rr, " rf=", rf, " clock+", dt, " o=", o1, "/", o2,
                                " | v3 bal=", a.bal, " last=", a.last, " k=", a.k, " stamp=", a.stamp,
                                " | other bal=", b.bal, " last=", b.last, " k=", b.k, " stamp=", b.stamp,
                                " read=", rb))
            fa[1] != fb[1] && return Failure(q, t, "rfirst differs", trace), cov, flags
            same(a, b) || return Failure(q, t, "balance, last or k differs", trace), cov, flags
            # a stamp may differ only where the next pop will not read it
            if a.stamp != b.stamp && a.last != 0 && a.k != 0
                return Failure(q, t, "stamps differ where the next pop reads them", trace), cov, flags
            end
            a.stamp != b.stamp && bump(:stamp_differs_unread)
        end
    end
    return nothing, cov, flags
end

function main(nseq::Int)
    t0 = time()
    f4, cov, flags = run(upd_v4!, nseq)
    println("v3 against v4, ", nseq, " sequences (", round(time() - t0; digits = 1), " s)")
    println("  flag combinations (lw + 2rr + 4rf => count): ", join(("$(i - 1)=>$(flags[i])" for i in 1:8), ", "))
    for k in sort(collect(keys(cov)))
        println("  ", rpad(k, 22), cov[k])
    end
    ok = true
    if f4 === nothing
        println("  EQUAL at every step: balance, rfirst, last and k; stamps differ only where unread")
    else
        ok = false
        println("  DIFFER: sequence ", f4.seq, ", step ", f4.step, ": ", f4.what)
        foreach(l -> println("    ", l), f4.trace)
    end
    for k in (:empty_return, :step_above_cap, :read_skipped, :balance_at_limit, :w4_1, :w4_2, :w4_3)
        get(cov, k, 0) > 0 || (ok = false; println("  COVERAGE MISSING: ", k))
    end
    all(>(0), flags) || (ok = false; println("  COVERAGE MISSING: a flag combination"))
    fn, _, _ = run(upd_neg!, nseq)
    if fn === nothing
        ok = false
        println("negative control (read only when both sides have work now): PASSED, so the check cannot see the difference")
    else
        println("negative control (read only when both sides have work now): fails as it must, at sequence ", fn.seq,
                ", step ", fn.step, ": ", fn.what)
        foreach(l -> println("    ", l), fn.trace[max(1, end - 3):end])
    end
    println(ok ? "RESULT: v4's update is v3's on every step" : "RESULT: FAILED")
    return ok
end

exit(main(isempty(ARGS) ? 10^6 : parse(Int, ARGS[1])) ? 0 : 1)
