# The #782 deadline repro: does a process pay more CPU per round trip through Reseau's poller when
# read deadlines are armed on its idle sockets (N, DEADLINE_S), or re-armed per round trip as HTTP.jl
# does per request (CHURN_EVERY)? No web framework in L1, no ORM, no database. Driven by deadlines.sh,
# which starts one of these per cell and round.
#
#   W workers (Threads.@spawn), each owning one TCP connection to the echo peer (deadlines_peer.jl),
#   do 64-byte round trips back to back. Each read parks in Reseau's `pollwait!`, the path a
#   Postgres.jl statement's read takes.
#
#   N idle connections, opened by the driver's idle client and accepted here:
#     ARMING=L1  a Reseau listener; each accepted connection gets a task that arms a read deadline with
#                `TCP.set_read_deadline!` (the call HTTP.jl's internal `_set_read_deadline!` makes) and
#                parks in a 1-byte read, as an HTTP.jl connection waiting for its next request does.
#                HTTP.jl is not loaded.
#     ARMING=L2  `HTTP.listen!(...; idle_timeout = D, read_header_timeout = D)`; each idle client sends
#                one request and holds the connection, so HTTP.jl arms its idle deadline itself.
#   DEADLINE_S=0 is the off state: no deadline (L1) or both timeouts at 0 (L2).
#
#   CHURN_EVERY=k > 0 makes every k-th round trip arm and clear deadlines on the worker's OWN socket,
#   in the order HTTP.jl's keep-alive loop does per request with both timeouts set: the idle deadline
#   (now + 120 s) while the read waits, then the next request's header deadline (now + 15 s), then
#   the body's clear to 0 (`read_timeout = 0`). Three `schedule_deadlines!` per churned round trip.
#
# One measured window per process. The idle deadlines are 120 s, and a process alive through a whole
# interleaved pass would see them expire mid-pass. Per-thread CPU is read from /proc/self/task/*/stat
# at the window's two edges. Thread roles follow #782 run 3: main is tid == pid, the poller is the
# last-created thread (checked against its current syscall, which must be epoll_wait), default is
# the busiest nthreads(:default) of the rest.
#
# Never sleep through Reseau here (`IOPoll.sleep`, `timedwait`): those push a timer entry into the
# poller heap, the structure under test. `Base.sleep` is libuv's.

const ARMING = get(ENV, "ARMING", "L1")
const N = parse(Int, get(ENV, "N", "0"))
const DEADLINE_S = parse(Float64, get(ENV, "DEADLINE_S", "0"))
const W = parse(Int, get(ENV, "W", "50"))
const PEER_PORT = parse(Int, get(ENV, "PEER_PORT", "9190"))
const IDLE_PORT = parse(Int, get(ENV, "IDLE_PORT", "9191"))
const WARM_S = parse(Float64, get(ENV, "WARM_S", "5"))
const WINDOW_S = parse(Float64, get(ENV, "WINDOW_S", "6"))
const HOLD_S = parse(Float64, get(ENV, "HOLD_S", "0"))      # W=0: keep the idle side up this long, then exit
const STRACE_S = parse(Float64, get(ENV, "STRACE_S", "0"))  # >0: no window; print TICK lines for strace
const CHURN_EVERY = parse(Int, get(ENV, "CHURN_EVERY", "0"))
const LOCK_PROFILE = get(ENV, "LOCK_PROFILE", "0") == "1"   # diagnostic: count contended locks over the window
const LABEL = get(ENV, "LABEL", "-")
const MSG = 64

ARMING in ("L1", "L2") || error("ARMING=$ARMING: expected L1 or L2")
const Reseau = Base.require(Base.PkgId(Base.UUID("802f3686-a58f-41ce-bb0c-3c43c75bba36"), "Reseau"))
const TCP = Reseau.TCP
if ARMING == "L2"
    using HTTP
end

const OUT_LOCK = ReentrantLock()
say(xs...) = lock(OUT_LOCK) do
    println(stdout, xs...)
    flush(stdout)
end

if STRACE_S > 0
    # ptrace_scope = 1 lets only an ancestor attach; this process lets any of the user's own do so.
    ccall(:prctl, Cint, (Cint, Culong, Culong, Culong, Culong), 0x59616d61, typemax(Culong), 0, 0, 0) == 0 ||
        error("prctl(PR_SET_PTRACER) failed")
end

# --- per-thread CPU ------------------------------------------------------------------------------

# tid => (starttime, utime + stime), in clock ticks.
function thread_ticks()
    d = Dict{Int, Tuple{Int, Int}}()
    for t in readdir("/proc/self/task")
        s = try
            read("/proc/self/task/$t/stat", String)
        catch
            continue
        end
        f = split(s[findlast(')', s) + 2:end])
        d[parse(Int, t)] = (parse(Int, f[20]), parse(Int, f[12]) + parse(Int, f[13]))
    end
    return d
end

function find_poller(d)
    best = (typemin(Int), typemin(Int))
    for (tid, (st, _)) in d
        (st, tid) > best && (best = (st, tid))
    end
    return best[2]
end
current_syscall(tid) = try
    parse(Int, first(split(read("/proc/self/task/$tid/syscall", String))))
catch
    -1
end

# --- idle side -----------------------------------------------------------------------------------

const HELD = Threads.Atomic{Int}(0)
const CLOSED = Threads.Atomic{Int}(0)   # idle connections that ended before the run did

function deadline_ns()
    return Int64(time_ns()) + round(Int64, DEADLINE_S * 1e9)
end

function hold_l1(conn)
    buf = zeros(UInt8, 1)
    DEADLINE_S > 0 && TCP.set_read_deadline!(conn, deadline_ns())
    Threads.atomic_add!(HELD, 1)
    try
        while true
            n = readbytes!(conn, buf, 1; all = false)
            n == 0 && break                                   # the client went away
            DEADLINE_S > 0 && TCP.set_read_deadline!(conn, deadline_ns())   # A4: a byte re-arms it
        end
    catch err
        err isa TCP.DeadlineExceededError || err isa TCP.NetClosingError || rethrow()
    finally
        Threads.atomic_add!(CLOSED, 1)
        close(conn)
    end
end

function start_idle_side()
    if ARMING == "L1"
        listener = TCP.listen(TCP.loopback_addr(IDLE_PORT))
        Threads.@spawn while true
            conn = try
                TCP.accept(listener)
            catch
                break
            end
            Threads.@spawn hold_l1(conn)
        end
        return listener
    else
        handler = HTTP.streamhandler(function (req)
            Threads.atomic_add!(HELD, 1)
            return HTTP.Response(200, "ok")
        end)
        return HTTP.listen!(handler, "127.0.0.1", IDLE_PORT;
                            idle_timeout = DEADLINE_S, read_header_timeout = DEADLINE_S)
    end
end

# --- workers -------------------------------------------------------------------------------------

const PHASE_RUN = Threads.Atomic{Bool}(true)
const SLOT = 8                         # one 64-byte line per worker counter
const COUNTS = zeros(Int, SLOT * max(W, 1))
const FAULT = Threads.Atomic{Int}(0)

function worker(conn, w::Int)
    out = zeros(UInt8, MSG)
    inb = zeros(UInt8, MSG)
    me = getpid()
    seq = 0
    GC.@preserve out begin
        p = Ptr{Int64}(pointer(out))
        unsafe_store!(p, Int64(me), 1)
        unsafe_store!(p, Int64(w), 2)
    end
    i = SLOT * (w - 1) + 1
    try
        while PHASE_RUN[]
            seq += 1
            churn = CHURN_EVERY > 0 && seq % CHURN_EVERY == 0
            churn && TCP.set_read_deadline!(conn, Int64(time_ns()) + Int64(120_000_000_000))
            GC.@preserve out unsafe_store!(Ptr{Int64}(pointer(out)), Int64(seq), 3)
            write(conn, out)
            n = readbytes!(conn, inb, MSG; all = true)
            if churn
                TCP.set_read_deadline!(conn, Int64(time_ns()) + Int64(15_000_000_000))
                TCP.set_read_deadline!(conn, Int64(0))
            end
            if n != MSG || inb != out
                Threads.atomic_add!(FAULT, 1)
                say("FAULT worker=$w seq=$seq n=$n")
                break
            end
            @inbounds COUNTS[i] = seq
        end
    finally
        close(conn)
    end
end

total_rt() = sum(@view COUNTS[1:SLOT:end])

# --- the run -------------------------------------------------------------------------------------

function main()
    pid = getpid()
    idle = start_idle_side()
    t_before = thread_ticks()
    say("READY pid=$pid arming=$ARMING N=$N deadline_s=$DEADLINE_S W=$W threads=$(Threads.nthreads(:default)),$(Threads.nthreads(:interactive))")
    t_wait = time()
    while HELD[] < N
        time() - t_wait > 120 && (say("ERROR held $(HELD[]) of $N after 120 s"); exit(2))
        sleep(0.05)
    end
    t_held = thread_ticks()
    poller = find_poller(t_held)
    # Idle now (no worker yet): the poller must be parked in epoll_wait (232) / epoll_pwait (281).
    sc = -1
    for _ in 1:40
        sc = current_syscall(poller)
        sc in (232, 281) && break
        sleep(0.025)
    end
    setup_poller = t_held[poller][2] - get(t_before, poller, (0, 0))[2]
    setup_other = maximum((v[2] - get(t_before, tid, (0, 0))[2] for (tid, v) in t_held if tid != poller); init = 0)
    say("HELD n=$(HELD[]) poller=$poller syscall=$sc setup_poller_ticks=$setup_poller setup_other_max_ticks=$setup_other")

    if W == 0
        sleep(HOLD_S)
        say("DONE closed=$(CLOSED[])")
        return
    end
    tasks = Task[]
    for w in 1:W
        conn = TCP.connect(TCP.loopback_addr(PEER_PORT))
        push!(tasks, Threads.@spawn worker(conn, w))
    end
    sleep(WARM_S)
    if STRACE_S > 0
        say("STRACE pid=$pid poller=$poller")
        t_end = time() + STRACE_S
        while time() < t_end
            say("TICK $(time()) $(total_rt())")
            sleep(0.5)
        end
    else
        LOCK_PROFILE && Threads.lock_profiling(true)
        k0 = Threads.LOCK_CONFLICT_COUNT[]
        c0 = total_rt(); d0 = thread_ticks(); t0 = time()
        sleep(WINDOW_S)
        c1 = total_rt(); d1 = thread_ticks(); t1 = time()
        k1 = Threads.LOCK_CONFLICT_COUNT[]
        LOCK_PROFILE && (Threads.lock_profiling(false);
            say("LOCKS conflicts=$(k1 - k0) per_s=$(round(Int, (k1 - k0) / (t1 - t0))) per_rt=$(round((k1 - k0) / (c1 - c0); digits = 4))"))
        span = t1 - t0
        delta(tid) = d1[tid][2] - get(d0, tid, (0, 0))[2]
        both = [tid for tid in keys(d1) if haskey(d0, tid)]
        rest = sort!([delta(tid) for tid in both if tid != pid && tid != poller]; rev = true)
        k = Threads.nthreads(:default)
        dflt = sum(rest[1:min(k, length(rest))])
        tot = sum(delta, both)
        closed_in_window = CLOSED[]
        rt = c1 - c0
        say("RESULT\t$LABEL\t$ARMING\t$N\t$DEADLINE_S\t$W\t$k,$(Threads.nthreads(:interactive))\t$rt\t",
            round(span; digits = 3), "\t", round(rt / span; digits = 0), "\t$tot\t$dflt\t$(delta(poller))\t",
            "$(delta(pid))\t$poller\t$sc\t$closed_in_window\t$(length(both))\t", round(Int, 1000t0), "\t", round(Int, 1000t1))
    end
    PHASE_RUN[] = false
    foreach(wait, tasks)
    say("TOTAL rt=$(total_rt()) faults=$(FAULT[]) closed=$(CLOSED[])")
end

main()
exit(FAULT[] == 0 ? 0 : 1)
