# #780: does a refused request still get its 413 (or 503) when only HTTP.jl's after-response drain
# runs, without Nitro's own pre-response swallow? And how long does each refusal hold its slot?
#
# Nitro answers two refusals before the middleware chain runs, the 413 over `max_body_bytes` and the
# 503 over `max_concurrent_requests`, through `_send_rejection!` (src/core/transport.jl). With
# `drain`, that function reads and discards up to 2 MiB of the request body for at most 5 s BEFORE it
# answers (`_swallow_request_body!`, `_bound_swallow!`), so the close that follows is a FIN and not a
# reset that could cost the client its response. Since HTTP.jl 2.12 (JuliaWeb/HTTP.jl#1494), HTTP
# does the same AFTER the response: a half-close, then up to 1 MiB for 500 ms. This harness runs
# real clients against two servers built from one commit and records, per cell, what each client
# saw and how long the refusal held its slot.
#
# Roles:
#   julia --project=<tree> --threads=2,1 bench/socket/swallow.jl server
#       Nitro `serve(max_body_bytes = 1024, max_concurrent_requests = 1)` on PORT, from <tree>'s
#       own environment (it loads only Nitro and HTTP). Routes: POST /echo reads the body; GET /hold
#       keeps the single slot until RELEASE_FILE appears (a file, because every HTTP request is
#       refused while the slot is full); GET /ping. With NITRO_SWALLOW_PROBE=1 a tree carrying the
#       #780 probe prints `PROBE ...` lines to stderr; the driver points the log at a file.
#   julia --project=. --threads=2 bench/socket/swallow.jl matrix
#       Starts one server per SERVERS entry, runs every cell against each (interleaved, the server
#       order alternating per repetition), pairs every cell with its PROBE lines, writes
#       bench/results/swallow-<stamp>.tsv and prints the summary table.
#   julia --project=. --threads=2 bench/socket/swallow.jl control0
#       The harness self-check: a bare Sockets server that writes a 413 and closes with the body
#       unread, so the kernel resets the connection. Shows what each client reports for a reset.
#   julia --project=. bench/socket/swallow.jl report <tsv>
#       The summary table again, from a TSV.
#
# matrix environment (space-separated lists):
#   SERVERS="A=<tree> B=<tree>"   name=project path; the tree's Nitro is the one served
#   REFUSALS="413 503"  CLIENTS="curl curl-noexpect http raw"  SIZES="64K 1.5M 4M 32M"
#   PACES="full T1.5 T8"   full speed, or the body spread over that many seconds
#   REPS_FULL=5  REPS_PACED=3  BASE_PORT=9310  SERVER_THREADS=2,1  TIMEOUT_S=30
#   STAMP=<name>   the results' file names (default: the Unix time)
#
# Clients:
#   curl            curl's default; curl 8 sends `Expect: 100-continue` for a body over 1 MiB,
#                   and Nitro refuses those before the body is sent (drain is false already)
#   curl-noexpect   curl -H 'Expect:'; paced with --limit-rate
#   http            HTTP.request (this project's HTTP.jl), retry = false. A paced cell sends an
#                   iterable body, which HTTP.jl 2.15 frames CHUNKED whatever Content-Length header
#                   it is given, so the paced http cells are the chunked shape: refused by the
#                   incremental counter after LIMIT + 1 bytes, never by the declared-length check
#   raw             Sockets: the head, then the whole body in writes, THEN the response. A write
#                   that fails is recorded and the read is still attempted, so the outcome tells
#                   "413 readable after the write failed" from "413 lost"
#
# The #780 probe is a local patch to a scratch copy of src/core/transport.jl, never committed: it
# times `_send_rejection!` (`PROBE reject ... reject_us=`) and, for a 413, the slot from acquire to
# release in `stream_handler` (`PROBE slot ... slot_hold_us=`). A tree without it still runs; its
# hold columns are empty. Outcomes do not depend on timing; hold times do: run those behind
# bench/socket/quiet.sh.

using Sockets
using HTTP

const ROLE = isempty(ARGS) ? "matrix" : ARGS[1]
const HOST = "127.0.0.1"
const LIMIT = 1024
const CRLF = "\r\n"

# ── server ─────────────────────────────────────────────────────────────────────────────────────

ROLE == "server" && @eval using Nitro

function run_server()
    port = parse(Int, ENV["PORT"])
    release = ENV["RELEASE_FILE"]
    Nitro.urlpatterns("",
        Nitro.path("/echo", function(req::HTTP.Request)
            return Dict("n" => length(Nitro.binary(req)))
        end, methods = ["POST"]),
        Nitro.path("/hold", function(req::HTTP.Request)
            while !isfile(release)
                sleep(0.01)
            end
            rm(release; force = true)
            return "held"
        end),
        Nitro.path("/ping", function(req::HTTP.Request)
            return "pong"
        end),
    )
    Nitro.serve(port = port, host = HOST, async = true, show_banner = false, access_log = nothing,
                max_body_bytes = LIMIT, max_concurrent_requests = 1)
    println("READY ", port, " julia ", VERSION, " HTTP ", pkgversion(HTTP), " Nitro ", pathof(Nitro))
    flush(stdout)
    while true
        sleep(3600)
    end
end

# ── clients ────────────────────────────────────────────────────────────────────────────────────

const SIZE_BYTES = Dict("64K" => 64 * 1024, "1.5M" => 3 * 512 * 1024, "4M" => 4 * 1024^2,
                        "32M" => 32 * 1024^2)
pace_secs(p::AbstractString) = p == "full" ? 0.0 : parse(Float64, p[2:end])
timeout_s() = parse(Float64, get(ENV, "TIMEOUT_S", "30"))

expected_text(refusal::Int) =
    refusal == 413 ? "Request body exceeds the configured limit" : "Server is at its limit"

struct ClientResult
    outcome :: String     # "413", "503", "413+wfail", "reset-w", "reset-r", "EOF", "timeout", ...
    status  :: Int        # 0 when no response was read
    detail  :: String
    secs    :: Float64
end

oneline(s::AbstractString) = first(replace(s, r"\s+" => " "), 160)

function classify(err)::String
    err === nothing && return "none"
    msg = lowercase(sprint(showerror, err))
    (occursin("econnreset", msg) || occursin("connection reset", msg)) && return "reset"
    (occursin("epipe", msg) || occursin("broken pipe", msg)) && return "epipe"
    (err isa EOFError || occursin("eof", msg) || occursin("end of file", msg)) && return "EOF"
    (occursin("timeout", msg) || occursin("timed out", msg)) && return "timeout"
    (occursin("closed", msg)) && return "closed"
    return "other"
end

function response_outcome(status::Int, body::AbstractString, refusal::Int)::String
    status == refusal && occursin(expected_text(refusal), body) && return string(refusal)
    return "status:$status"
end

# Frame a response by its head and Content-Length (test/max_body_bytes_tests.jl's reader).
function read_http_response(sock)
    terminator = Vector{UInt8}(CRLF * CRLF)
    head = UInt8[]
    while !(length(head) >= 4 && head[end-3:end] == terminator)
        push!(head, read(sock, UInt8))
    end
    headtext = String(head)
    m = match(r"(?im)^content-length:[ \t]*(\d+)", headtext)
    body = m === nothing ? "" : String(read(sock, parse(Int, m.captures[1])))
    status = parse(Int, split(headtext)[2])
    return status, headtext, body
end

chunk_bytes(n::Int) = clamp(n ÷ 256, 1024, 16 * 1024)

# Sleep to an absolute deadline, not for a fixed step: `sleep` rounds up to whole milliseconds, so
# 2048 fixed steps of 0.7 ms take ~4 s, not 1.5 s. Against the deadline a paced send takes its label.
pace_until(deadline::Float64) = (d = deadline - time(); d > 0.001 && sleep(d); nothing)

function client_raw(port::Int, data::Vector{UInt8}, pace::AbstractString, refusal::Int)::ClientResult
    secs = pace_secs(pace)
    t0 = time()
    sock = Sockets.connect(HOST, port)
    timed_out = Ref(false)
    watchdog = Timer(timeout_s()) do _
        timed_out[] = true
        close(sock)
    end
    werr = nothing
    ch = chunk_bytes(length(data))
    nchunks = cld(length(data), ch)
    try
        write(sock, string("POST /echo HTTP/1.1", CRLF, "Host: ", HOST, ":", port, CRLF,
                           "Content-Type: application/octet-stream", CRLF,
                           "Content-Length: ", length(data), CRLF, CRLF))
        for (k, i) in enumerate(1:ch:length(data))
            write(sock, view(data, i:min(i + ch - 1, length(data))))
            secs > 0 && pace_until(t0 + secs * k / nchunks)
        end
    catch err
        werr = err
    end
    wsecs = time() - t0
    result = try
        status, _, body = read_http_response(sock)
        out = response_outcome(status, body, refusal)
        werr === nothing || (out *= "+wfail")
        ClientResult(out, status, werr === nothing ? "" :
                     "write failed after $(round(wsecs; digits = 2)) s: $(classify(werr))",
                     time() - t0)
    catch rerr
        out = timed_out[] ? "timeout" :
              werr === nothing ? "$(classify(rerr))-r" : "$(classify(werr))-w"
        ClientResult(out, 0, oneline(string(
                         werr === nothing ? "" : "write: $(sprint(showerror, werr)) | ",
                         "read: ", sprint(showerror, rerr))), time() - t0)
    finally
        close(watchdog)
        close(sock)
    end
    return result
end

function client_curl(port::Int, file::String, n::Int, pace::AbstractString, refusal::Int,
                     expect::Bool)::ClientResult
    out_body = tempname()
    args = ["-sS", "-o", out_body, "-w", "%{http_code}", "--max-time", string(round(Int, timeout_s())),
            "-X", "POST", "--data-binary", "@$file", "-H", "Content-Type: application/octet-stream"]
    expect || push!(args, "-H", "Expect:")
    secs = pace_secs(pace)
    secs > 0 && push!(args, "--limit-rate", string(max(1, round(Int, n / secs))))
    push!(args, "http://$HOST:$port/echo")
    out = IOBuffer(); err = IOBuffer()
    t0 = time()
    p = run(pipeline(ignorestatus(`curl $args`), stdout = out, stderr = err))
    secs_taken = time() - t0
    code = tryparse(Int, String(take!(out)))
    code === nothing && (code = 0)
    body = isfile(out_body) ? read(out_body, String) : ""
    rm(out_body; force = true)
    stderr_text = oneline(String(take!(err)))
    e = p.exitcode
    outcome = e == 0 ? response_outcome(code, body, refusal) :
              e == 55 ? "send-fail" :     # curl: failed sending data to the peer
              e == 56 ? "recv-fail" :     # curl: failure receiving network data
              e == 52 ? "EOF" :           # curl: empty reply from server
              e == 28 ? "timeout" : "curl$e"
    return ClientResult(outcome, code, e == 0 ? "" : "curl exit $e: $stderr_text", secs_taken)
end

function client_http(port::Int, data::Vector{UInt8}, pace::AbstractString, refusal::Int)::ClientResult
    secs = pace_secs(pace)
    headers = ["Content-Type" => "application/octet-stream"]
    t0 = time()
    body = if secs > 0
        ch = chunk_bytes(length(data))
        nchunks = cld(length(data), ch)
        push!(headers, "Content-Length" => string(length(data)))
        (begin
            pace_until(t0 + secs * (k - 1) / nchunks)
            data[i:min(i + ch - 1, length(data))]
        end for (k, i) in enumerate(1:ch:length(data)))
    else
        data
    end
    try
        r = HTTP.request("POST", "http://$HOST:$port/echo", headers, body;
                         retry = false, status_exception = false,
                         request_timeout = timeout_s())
        return ClientResult(response_outcome(Int(r.status), String(r.body), refusal), Int(r.status),
                            "", time() - t0)
    catch err
        return ClientResult(classify(err), 0, oneline(sprint(showerror, err)), time() - t0)
    end
end

# ── servers under test ─────────────────────────────────────────────────────────────────────────

mutable struct Server
    name    :: String
    tree    :: String
    port    :: Int
    log     :: String
    release :: String
    proc    :: Base.Process
    seen    :: Int        # PROBE lines already paired
    probed  :: Bool       # the tree carries the #780 probe
end

function start_server(name::String, tree::String, port::Int, outdir::String, stamp::String)::Server
    log = joinpath(outdir, "swallow-$stamp-$name.log")
    release = tempname()
    env = copy(ENV)
    env["PORT"] = string(port)
    env["RELEASE_FILE"] = release
    env["NITRO_SWALLOW_PROBE"] = "1"
    julia = joinpath(Sys.BINDIR, "julia")
    threads = get(ENV, "SERVER_THREADS", "2,1")
    cmd = setenv(`$julia --project=$tree --threads=$threads $(@__FILE__) server`, env)
    # ONE handle for both streams: two opens of the same path each write from offset 0 and
    # overwrite each other.
    logio = open(log, "w")
    proc = run(pipeline(cmd, stdout = logio, stderr = logio), wait = false)
    close(logio)   # the child holds its own descriptors
    # Ready means THIS child said so, from THIS tree: a `/ping` alone would also be answered by a
    # leftover server from an earlier run still bound to the port.
    deadline = time() + 300
    want = joinpath(tree, "src", "Nitro.jl")
    while true
        process_exited(proc) && error("server $name exited at start; see $log")
        time() > deadline && error("server $name not ready after 300 s; see $log")
        ready = filter(l -> startswith(l, "READY"), readlines(log))
        if !isempty(ready)
            endswith(ready[1], want) || error("server $name loaded $(ready[1]), not $want")
            break
        end
        sleep(0.5)
    end
    probed = occursin("PROBE #780", read(joinpath(tree, "src", "core", "transport.jl"), String))
    s = Server(name, tree, port, log, release, proc, 0, probed)
    # Warm the 413 path once, so no cell's hold time carries its compilation. The 503 path is
    # warmed by `fill_slot!`'s first `/ping`.
    client_raw(port, fill(UInt8('a'), 64 * 1024), "full", 413)
    s.probed && take_probes!(s, 2; wait_s = 5.0)
    return s
end

stop_server(s::Server) = (kill(s.proc); sleep(0.5); process_exited(s.proc) || kill(s.proc, Base.SIGKILL))

probe_lines(s::Server) = filter(l -> startswith(l, "PROBE"), readlines(s.log))

# Wait for `want` new PROBE lines, and pair them with the cell that caused them.
function take_probes!(s::Server, want::Int; wait_s::Float64 = 12.0)::Vector{String}
    deadline = time() + wait_s
    lines = probe_lines(s)
    while length(lines) - s.seen < want && time() < deadline
        sleep(0.05)
        lines = probe_lines(s)
    end
    new = lines[s.seen+1:end]
    s.seen = length(lines)
    return new
end

probe_value(lines, key) = begin
    for l in lines
        m = match(Regex("$key=(\\d+)"), l)
        m === nothing || return parse(Int, m.captures[1]) / 1000   # ms
    end
    NaN
end

function raw_get(port::Int, target::String)
    sock = Sockets.connect(HOST, port)
    write(sock, string("GET ", target, " HTTP/1.1", CRLF, "Host: ", HOST, ":", port, CRLF, CRLF))
    return sock
end

# The status of one GET, read with a timeout, its socket always closed: a socket left to the GC
# can be finalized after the server's side has timed out, and the RST that answers it would land
# in whatever cell is running.
function raw_status(port::Int, target::String; timeout::Float64 = 10.0)::Int
    sock = raw_get(port, target)
    t = Timer(timeout) do _; close(sock) end
    try
        status, _, _ = read_http_response(sock)
        return status
    catch
        return 0
    finally
        close(t); close(sock)
    end
end

# Fill the single slot with /hold, and prove it: /ping must now be refused 503. A stale release
# file would let every later /hold return at once, so it is removed before each attempt.
function fill_slot!(s::Server)
    for _ in 1:20
        rm(s.release; force = true)
        holder = raw_get(s.port, "/hold")
        sleep(0.3)
        status = raw_status(s.port, "/ping")
        status == 503 && s.probed && take_probes!(s, 1; wait_s = 2.0)   # the /ping refusal's line
        status == 503 && return holder
        release_slot!(s, holder)                  # not held yet; let it go and retry
    end
    error("could not fill the slot on $(s.name)")
end

# Let /hold return, read its answer, then wait until the slot is free again: the holder's response
# is on the wire a moment before its `finally` gives the slot back, and the next cell's fill must
# not race that.
function release_slot!(s::Server, holder)
    touch(s.release)
    t = Timer(10) do _; close(holder) end
    try read_http_response(holder) catch end
    close(t); close(holder)
    rm(s.release; force = true)
    deadline = time() + 5
    while raw_status(s.port, "/ping") != 200 && time() < deadline
        sleep(0.02)
    end
end

# ── matrix ─────────────────────────────────────────────────────────────────────────────────────

envlist(key, default) = split(get(ENV, key, default))

# The kernel's count of TCP resets sent, machine-wide (`Tcp: OutRsts` in /proc/net/snmp). On
# loopback both ends are this machine, so a cell's delta counts the resets either side sent: a
# server close with the body unread shows here even when the client still got its response, which
# is the case Linux forgives and Windows does not (control0). Another process resetting connections
# during a cell inflates it; read it alongside the raw client's `+wfail`.
function tcp_out_rsts()::Int
    lines = readlines("/proc/net/snmp")
    i = findfirst(l -> startswith(l, "Tcp:"), lines)
    names, vals = split(lines[i]), split(lines[i+1])
    return parse(Int, vals[findfirst(==("OutRsts"), names)])
end

const TSV_HEADER = join(["server", "refusal", "client", "size", "pace", "rep", "outcome", "status",
                         "client_s", "slot_hold_ms", "reject_ms", "probes", "rsts", "detail"], '\t')

function run_cell(s::Server, refusal::Int, client::AbstractString, size::AbstractString,
                  pace::AbstractString, data::Vector{UInt8}, file::String)
    holder = refusal == 503 ? fill_slot!(s) : nothing
    take_probes!(s, 0; wait_s = 0.0)
    rsts0 = tcp_out_rsts()
    r = try
        client == "raw"           ? client_raw(s.port, data, pace, refusal) :
        client == "http"          ? client_http(s.port, data, pace, refusal) :
        client == "curl"          ? client_curl(s.port, file, length(data), pace, refusal, true) :
        client == "curl-noexpect" ? client_curl(s.port, file, length(data), pace, refusal, false) :
        error("unknown client $client")
    catch err
        # A failure of the harness itself is one cell's row, not the end of the run.
        ClientResult("harness", 0, oneline(sprint(showerror, err)), 0.0)
    end
    # The server's close can come up to HTTP's 500 ms drain after the client is done, so the
    # reset count is read once that has passed. The probes are taken BEFORE /hold is released:
    # the release waits for the slot with /ping, whose refusals print lines of their own.
    # 413: `reject` + `slot`; 503: `reject` (it holds no slot).
    sleep(0.8)
    rsts = tcp_out_rsts() - rsts0
    probes = s.probed ? take_probes!(s, refusal == 413 ? 2 : 1) : String[]
    holder === nothing || release_slot!(s, holder)
    return r, probes, rsts
end

function matrix()
    servers_spec = envlist("SERVERS", "main=$(dirname(dirname(@__DIR__)))")
    refusals = parse.(Int, envlist("REFUSALS", "413 503"))
    clients = envlist("CLIENTS", "curl curl-noexpect http raw")
    sizes = envlist("SIZES", "64K 1.5M 4M 32M")
    paces = envlist("PACES", "full T1.5 T8")
    reps_full = parse(Int, get(ENV, "REPS_FULL", "5"))
    reps_paced = parse(Int, get(ENV, "REPS_PACED", "3"))
    base_port = parse(Int, get(ENV, "BASE_PORT", "9310"))
    outdir = joinpath(dirname(dirname(@__DIR__)), "bench", "results")
    mkpath(outdir)
    stamp = get(ENV, "STAMP", string(round(Int, time())))
    tsv = joinpath(outdir, "swallow-$stamp.tsv")

    files = Dict{String,String}()
    datas = Dict{String,Vector{UInt8}}()
    for sz in sizes
        datas[sz] = fill(UInt8('a'), SIZE_BYTES[sz])
        files[sz] = tempname()
        write(files[sz], datas[sz])
    end

    servers = Server[]
    println("TSV ", tsv)
    open(tsv, "w") do io
        println(io, TSV_HEADER)
        try
            # Inside the `try`, so a server that fails to start does not leave the others running.
            for (i, spec) in enumerate(servers_spec)
                name, tree = split(spec, '='; limit = 2)
                push!(servers, start_server(String(name), String(tree), base_port + i - 1, outdir, stamp))
                println("server ", name, " ready on ", base_port + i - 1, ": ",
                        first(filter(l -> startswith(l, "READY"), readlines(servers[end].log))))
            end
            for refusal in refusals, client in clients, sz in sizes, pace in paces
                reps = pace == "full" ? reps_full : reps_paced
                for rep in 1:reps
                    order = isodd(rep) ? servers : reverse(servers)
                    for s in order
                        r, probes, rsts = run_cell(s, refusal, client, sz, pace, datas[sz], files[sz])
                        hold = probe_value(probes, "slot_hold_us")
                        rej = probe_value(probes, "reject_us")
                        row = [s.name, string(refusal), client, sz, pace, string(rep), r.outcome,
                               string(r.status), string(round(r.secs; digits = 3)),
                               isnan(hold) ? "" : string(round(hold; digits = 2)),
                               isnan(rej) ? "" : string(round(rej; digits = 2)),
                               string(length(probes)), string(rsts), r.detail]
                        println(io, join(row, '\t')); flush(io)
                        println("CELL ", join(row[[1:11; 13]], ' '),
                                !s.probed || length(probes) == (refusal == 413 ? 2 : 1) ? "" :
                                " PROBES=$(length(probes))")
                        flush(stdout)
                    end
                end
            end
        finally
            foreach(stop_server, servers)
            foreach(f -> rm(f; force = true), values(files))
        end
    end
    report(tsv)
    println("DONE ", tsv)
end

# ── report ─────────────────────────────────────────────────────────────────────────────────────

function median_of(xs::Vector{Float64})
    isempty(xs) && return NaN
    v = sort(xs); n = length(v)
    return isodd(n) ? v[(n + 1) ÷ 2] : (v[n ÷ 2] + v[n ÷ 2 + 1]) / 2
end

fmt_ms(x) = isnan(x) ? "–" : x < 10 ? string(round(x; digits = 2)) : string(round(Int, x))

function report(tsv::AbstractString)
    rows = [split(l, '\t') for l in readlines(tsv)[2:end]]
    servers = unique(r[1] for r in rows)
    keys_ = unique((r[2], r[3], r[4], r[5]) for r in rows)
    print("| refusal | client | size | pace |")
    for s in servers
        print(" $s outcome | $s hold ms (med/max) |")
    end
    println()
    println("|", repeat("---|", 4 + 2 * length(servers)))
    for k in keys_
        print("| ", join(k, " | "), " |")
        for s in servers
            sel = [r for r in rows if r[1] == s && (r[2], r[3], r[4], r[5]) == k]
            counts = Dict{String,Int}()
            for r in sel
                counts[r[7]] = get(counts, r[7], 0) + 1
            end
            out = join(["$o ×$c" for (o, c) in sort(collect(counts); by = last, rev = true)], ", ")
            # How many of the repetitions ended in a TCP reset from either side (`rsts` > 0).
            nrst = count(r -> parse(Int, r[13]) > 0, sel)
            out *= " · RST $nrst/$(length(sel))"
            # The slot for a 413; for a 503 (no slot) the time the refusal held its task.
            col = k[1] == "413" ? 10 : 11
            vals = Float64[parse(Float64, r[col]) for r in sel if !isempty(r[col])]
            print(" ", out, " | ", fmt_ms(median_of(vals)), " / ",
                  fmt_ms(isempty(vals) ? NaN : maximum(vals)), " |")
        end
        println()
    end
end

# ── control 0 ──────────────────────────────────────────────────────────────────────────────────

# A server that answers 413 on the head and closes with the body unread: the kernel resets the
# connection. What each client reports here is what a reset looks like to it.
function control0()
    port = parse(Int, get(ENV, "BASE_PORT", "9310")) + 50
    listener = listen(IPv4(HOST), port)
    @async while isopen(listener)
        sock = try accept(listener) catch; break end
        @async try
            head = UInt8[]
            while !(length(head) >= 4 && head[end-3:end] == Vector{UInt8}(CRLF * CRLF))
                push!(head, read(sock, UInt8))
            end
            body = expected_text(413)
            write(sock, string("HTTP/1.1 413 Payload Too Large", CRLF, "Content-Length: ",
                               sizeof(body), CRLF, "Connection: close", CRLF, CRLF, body))
            close(sock)
        catch
        end
    end
    sizes = envlist("SIZES", "64K 4M 32M")
    for sz in sizes
        data = fill(UInt8('a'), SIZE_BYTES[sz])
        file = tempname(); write(file, data)
        for client in envlist("CLIENTS", "curl-noexpect http raw"), rep in 1:3
            r = client == "raw"  ? client_raw(port, data, "full", 413) :
                client == "http" ? client_http(port, data, "full", 413) :
                client_curl(port, file, length(data), "full", 413, client == "curl")
            println("CONTROL0 ", client, " ", sz, " rep ", rep, ": ", r.outcome, "  ", r.detail)
        end
        rm(file; force = true)
    end
    close(listener)
end

if ROLE == "server"
    run_server()
elseif ROLE == "matrix"
    matrix()
elseif ROLE == "control0"
    control0()
elseif ROLE == "report"
    report(ARGS[2])
else
    error("unknown role $(ROLE): server | matrix | control0 | report <tsv>")
end
