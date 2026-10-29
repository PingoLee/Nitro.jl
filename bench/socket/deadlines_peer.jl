# The two helper processes of the #782 deadline repro (deadlines.jl, driven by deadlines.sh). Their
# CPU is not part of the measurement; they run on CPUs of their own.
#
#   julia deadlines_peer.jl echo <port>
#     Echoes every 64-byte message back on the connection it came on. When a connection ends it prints
#     `CONN <pid> <worker> <messages>`, the first two read from the connection's first message, so the
#     driver can check the echo count against the process's own count of round trips.
#
#   julia deadlines_peer.jl idle <L1|L2> <port> <n> [rearm_s]
#     Opens n connections to the process under test and holds them. L2 sends one HTTP request on each
#     and reads its response first (SILENT=1 skips the request), so HTTP.jl arms its idle deadline.
#     With rearm_s > 0 each connection sends one byte (L1) or one request (L2) every rearm_s.
#     Prints `HELD <n>`, then `CLOSED <i> <seconds since its last send> <epoch>` for each connection
#     the server closes. PROBE=1 is the timeout probe: it waits at most PROBE_CAP_S (12) seconds and
#     prints `OPEN <i>` for each connection still open at the cap, then exits; `DATA <i> <seconds>`
#     marks the first bytes the server sent unasked (HTTP.jl's 408).
#
# Never Base.sleep inside the echo path; the echo tasks only park in Reseau reads.

const Reseau = Base.require(Base.PkgId(Base.UUID("802f3686-a58f-41ce-bb0c-3c43c75bba36"), "Reseau"))
const TCP = Reseau.TCP
const MSG = 64
const OUT_LOCK = ReentrantLock()
say(xs...) = lock(OUT_LOCK) do
    println(stdout, xs...)
    flush(stdout)
end

function echo_conn(conn)
    buf = zeros(UInt8, MSG)
    n_msgs = 0
    pid = -1
    w = -1
    try
        while true
            n = readbytes!(conn, buf, MSG; all = true)
            n == 0 && break
            n == MSG || (say("PARTIAL $pid $w $n"); break)
            if n_msgs == 0
                GC.@preserve buf begin
                    p = Ptr{Int64}(pointer(buf))
                    pid = unsafe_load(p, 1)
                    w = unsafe_load(p, 2)
                end
            end
            write(conn, buf)
            n_msgs += 1
        end
    catch err
        say("ERROR $pid $w $(typeof(err))")
    finally
        close(conn)
        say("CONN $pid $w $n_msgs")
    end
end

function echo(port)
    listener = TCP.listen(TCP.loopback_addr(port); backlog = 1024)
    say("READY echo port=$port threads=$(Threads.nthreads())")
    while true
        conn = TCP.accept(listener)
        Threads.@spawn echo_conn(conn)
    end
end

const REQUEST = Vector{UInt8}("GET / HTTP/1.1\r\nHost: bench\r\n\r\n")

# Read one response to REQUEST (the process answers 200 "ok" with a Content-Length of 2).
function read_response(conn, buf)
    acc = UInt8[]
    while true
        n = readbytes!(conn, buf, length(buf); all = false)
        n == 0 && return false
        append!(acc, @view buf[1:n])
        s = String(copy(acc))
        occursin("\r\n\r\nok", s) && return true
    end
end

function idle(arming, port, n, rearm_s)
    probe = get(ENV, "PROBE", "0") == "1"
    silent = get(ENV, "SILENT", "0") == "1"
    cap = parse(Float64, get(ENV, "PROBE_CAP_S", "12"))
    conns = TCP.Conn[]
    last_send = zeros(Float64, n)
    buf = zeros(UInt8, 4096)
    for i in 1:n
        conn = TCP.connect(TCP.loopback_addr(port))
        push!(conns, conn)
        last_send[i] = time()
        if arming == "L2" && !silent
            write(conn, REQUEST)
            read_response(conn, buf) || error("connection $i closed before its response")
            last_send[i] = time()
        end
    end
    done = Threads.Atomic{Int}(0)
    open_flags = fill(true, n)
    for i in 1:n
        conn = conns[i]
        if rearm_s > 0
            Threads.@spawn try
                while open_flags[i]
                    sleep(rearm_s)
                    if arming == "L1"
                        write(conn, UInt8[0x2e])
                    else
                        write(conn, REQUEST)
                    end
                    last_send[i] = time()
                end
            catch
            end
        end
        Threads.@spawn begin
            b = zeros(UInt8, 4096)
            try
                first_data = true
                while true
                    k = readbytes!(conn, b, length(b); all = false)
                    k == 0 && break      # L2 responses to re-arming requests are read and dropped here
                    # A probe's silent L2 connection gets HTTP.jl's 408 at the header deadline, and
                    # its close only after HTTP.jl's drain: report both.
                    probe && first_data && say("DATA $i ", round(time() - last_send[i]; digits = 2))
                    first_data = false
                end
            catch
            end
            open_flags[i] = false
            say("CLOSED $i ", round(time() - last_send[i]; digits = 2), " ", round(time(); digits = 3))
            Threads.atomic_add!(done, 1)
        end
    end
    say("HELD $n")
    if probe
        t_end = time() + cap
        while time() < t_end && done[] < n
            sleep(0.05)
        end
        for i in 1:n
            open_flags[i] && say("OPEN $i")
        end
        exit(0)
    end
    while true
        sleep(3600)
    end
end

role = ARGS[1]
if role == "echo"
    echo(parse(Int, ARGS[2]))
elseif role == "idle"
    idle(ARGS[2], parse(Int, ARGS[3]), parse(Int, ARGS[4]), length(ARGS) >= 5 ? parse(Float64, ARGS[5]) : 0.0)
else
    error("role $role: expected echo or idle")
end
