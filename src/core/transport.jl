# ── Transport: HTTP.jl / Reseau internals ───────────────────────────────────────
# Peer-IP resolution, the non-consuming response write path, and the stream handlers.
# Included into `module Core` by src/core.jl — not a submodule; see the hub for why.

# Size of one transfer chunk, used in both directions: the streaming response writer below, and
# the bounded request-body read in `_http_stream_request`. Peak memory for a streamed response is
# this buffer rather than the file, which is the whole point of that writer. 64 KiB is `io.Copy`'s
# default in Go's `net/http` — the tradition Nitro took its concurrency model from — and
# comfortably above a typical MTU or socket send buffer, so a chunk is not split into a
# pathological number of writes.
const _STREAM_CHUNK_BYTES = 64 * 1024

# ── HTTP.jl v2 compatibility shim ───────────────────────────────────────────────
# The HTTP private/undocumented *functions* Nitro's request layer reaches into are
# wrapped here, so an HTTP upgrade that renames one is a single-line fix instead of
# a grep hunt. Guarded by the "HTTP internals contract" canary in
# test/http_internals_contract_tests.jl.
#
# Deliberately NOT centralized here: the `HTTP.EmptyBody`/`HTTP.BytesBody` body
# *types* (dispatched on inline in bodyparsers.jl / core/transport.jl) and the `_peer_ip`
# stream-layout reach (below) — both carry their own canary coverage.
#
# Since #17 the request builder is no longer a one-line delegation to
# `HTTP._buffered_stream_request`; what is wrapped here is that function's *shape*, rebuilt
# over supported API so the body can be capped. See the docstring below.
"""
    _http_stream_request(stream, max_body_bytes) -> Nullable{HTTP.Request}

Buffer the request body into an `HTTP.Request`, refusing to exceed `max_body_bytes` (`0` means
unlimited). Returns `nothing` when the ceiling was passed, which `stream_handler` turns into a 413.

This replaces the `HTTP._buffered_stream_request` call Nitro made until #17. That function is
`startread` + `read(stream)`, and `read` on a server stream is an unbounded `append!` loop. The
fork's own 64 MiB cap (`_check_server_body_size!`) runs only on the `serve!` Request-handler
branch, and the fork's docs call stream handlers "application-managed large uploads" — so the cap
was never Nitro's, and an unauthenticated client could buffer a multi-gigabyte body into RAM
before a single middleware ran.

**The reimplementation reaches FEWER HTTP internals than the call it replaces.** `startread` is
exported, `readbytes!` is the Base IO interface, `get_request_context` and `Request` are public;
only `EmptyBody`/`BytesBody` stay private, and they were already canaried. Going through
`readbytes!` instead of hand-rolling a loop over the private `_stream_request_body_read!` is
load-bearing rather than stylistic: `readbytes!` calls `_maybe_write_continue!`, and skipping that
hangs every `Expect: 100-continue` client until its own timeout fires.
"""
# Returned instead of a `Request` when the body passed the ceiling. `drain` records whether the
# client is already sending — see `_reject_oversized_body!`, which needs it to decide between
# swallowing the remainder and leaving the socket alone.
struct _BodyRejected
    drain :: Bool
end

function _http_stream_request(stream::HTTP.Stream, max_body_bytes::Int64)::Union{HTTP.Request, _BodyRejected}
    # Pure accessor: `_server_startread` returns `stream.message`, the parsed head that `Stream`'s
    # constructor split off from the live body reader. It reads nothing and cannot block, which is
    # what makes the declared-length check below free.
    head = HTTP.startread(stream)
    declared = Int64(head.content_length)   # -1 chunked, 0 no body, >0 fixed length

    # Declared-length fast reject, BEFORE any read. The ordering is the whole value of this branch:
    # `_maybe_write_continue!` fires from the first `readbytes!`, so refusing here means an
    # `Expect: 100-continue` client never receives its `100 Continue` and therefore never sends the
    # body. It is the one path on which an oversized upload costs neither side the bytes.
    if max_body_bytes > 0 && declared > max_body_bytes
        # `drain = false` only when the client is still waiting for permission to send: swallowing
        # would call `_maybe_write_continue!` and thereby *invite* the very body we just refused.
        expects_continue = occursin("100-continue", lowercase(HTTP.header(head, "Expect", "")))
        return _BodyRejected(!expects_continue)
    end

    body_bytes = UInt8[]
    # `EmptyBody` already reports itself fully consumed, so skipping the read does NOT make HTTP's
    # `startwrite` force `Connection: close` — which is precisely what a bodyless GET, the most
    # common request there is, must avoid.
    if !(stream.request_body isa HTTP.EmptyBody)
        # Content-Length is a client *claim*, and a chunked body declares nothing at all
        # (`content_length == -1`; `ChunkedBody` bounds only the chunk-size line, never the total).
        # So the ceiling is enforced a second time while reading. The pre-check above is an
        # optimization — THIS loop is the guarantee.
        chunk = declared > 0 ? min(declared, Int64(_STREAM_CHUNK_BYTES)) : Int64(_STREAM_CHUNK_BYTES)
        scratch = Vector{UInt8}(undef, chunk)
        # CLAMPED, and the clamp is the whole point. `declared` is an unverified client claim, so
        # hinting it directly would let one header line commit the heap: `Content-Length:` at the
        # ceiling reserves the ceiling before a single body byte arrives, and with
        # `max_body_bytes = nothing` the claim is unbounded, so `Content-Length: 1099511627776`
        # buys a 1 TiB reservation for a few hundred bytes on the wire. That is a cheaper version
        # of the exact attack this function exists to stop. Hinting one chunk keeps the win where
        # it mattered — small and medium bodies, where `append!` doubling is a real fraction of
        # request cost — while peak memory stays tied to bytes RECEIVED rather than bytes claimed.
        declared > 0 && sizehint!(body_bytes, min(declared, chunk))
        received = Int64(0)
        while true
            # `_server_readbytes!` allocates `want` bytes internally, so capping `want` keeps a
            # small fixed-length POST to one allocation of its own size rather than a full chunk,
            # and holds peak buffering at `max_body_bytes + 1` rather than a chunk beyond it.
            # `remaining + 1` -- one past the ceiling, so the loop can SEE an over-limit body
            # rather than stopping exactly at the limit and mistaking a truncation for a fit. It is
            # spelled this way rather than as `min(chunk, remaining + 1)` because `remaining + 1`
            # overflows to `typemin` when the limit is `typemax(Int64)`, which `min` would then
            # happily pick -- handing `readbytes!` a negative `nb` and 500-ing every request with a
            # body. Adding only on the branch where `remaining < chunk <= 65536` makes that
            # unrepresentable.
            remaining = max_body_bytes - received
            want = (max_body_bytes > 0 && remaining < chunk) ? remaining + one(Int64) : chunk
            n = readbytes!(stream, scratch, want)
            n == 0 && break
            received += n
            max_body_bytes > 0 && received > max_body_bytes && return _BodyRejected(true)
            append!(body_bytes, @view(scratch[1:n]))
            # A fixed-length body is complete here, so break rather than spend a second
            # `readbytes!` purely to observe the terminal 0. `FixedLengthBody.remaining` has
            # already reached 0, so `read_closed` is set and keep-alive survives.
            declared >= 0 && received >= declared && break
        end
    end

    body = isempty(body_bytes) ? HTTP.EmptyBody() : HTTP.BytesBody(body_bytes)
    return HTTP.Request(
        head.method,
        head.target;
        headers        = head.headers,
        trailers       = head.trailers,
        body           = body,
        host           = head.host,
        content_length = length(body_bytes),
        proto_major    = Int(head.proto_major),
        proto_minor    = Int(head.proto_minor),
        close          = head.close,
        context        = HTTP.get_request_context(head),
    )
end

# True once a handler has begun writing the response on the raw stream (e.g. a STREAM
# route that called `startwrite`, or a WebSocket upgrade). Used to decide whether the
# framework still needs to emit a serialized `Response`.
_response_started(stream::HTTP.Stream)::Bool = (@atomic :acquire stream.response_started)

# Resolve the underlying Reseau `TCP.FD` (which carries `raddr`) from the server connection.
# The connection is transport-dependent: a plaintext `Reseau.TCP.Conn` exposes `:fd`
# directly, while a `Reseau.TLS.Conn` wraps the TCP connection under `:tcp` and has no `:fd`
# of its own. The earlier `conn.fd` shortcut therefore worked for HTTP but threw for *every*
# HTTPS connection, silently sending every TLS client's IP to loopback. We branch on field
# presence rather than importing Reseau (a transitive dep that must not leak into `src/`); an
# unrecognized layout raises, which `_peer_ip` turns into the structural-break alarm below.
function _conn_fd(conn)
    if hasfield(typeof(conn), :fd)        # Reseau.TCP.Conn
        return getfield(conn, :fd)
    elseif hasfield(typeof(conn), :tcp)   # Reseau.TLS.Conn wraps a TCP.Conn under :tcp
        return getfield(getfield(conn, :tcp), :fd)
    end
    error("Nitro: unrecognized Reseau connection type $(typeof(conn)) — no `:fd` or `:tcp` field")
end

# The peer address as a Julia value, in ONE canonical spelling per host. Two byte forms of
# the same IPv4 host reach here: four bytes from an AF_INET socket, and sixteen bytes in the
# `::ffff:0:0/96` block when a dual-stack AF_INET6 listener reports an IPv4 client. Without
# demoting the second, one host occupies two `getip`/`getpeerip` values — two access-log
# spellings, and a split in any application that keys off `getip` (#66). Nitro's own rate
# limiter was already immune: `_bucket_key` folds the mapped form itself via `_norm`. This
# closes the gap for everyone else.
#
# Demoting HERE, where the OS's bytes first become a Julia value, is what keeps the choice a
# *representation* decision at the transport boundary rather than a rewrite of an
# observation. `ExtractIP()` keeps its property of never touching the peer, and
# `getip == getpeerip` keeps holding when no forwarding header was read — the two things
# option (b) in #66 would have cost. It is the same rule as `_canonical`/`_norm` in
# src/middleware/extract_ip.jl, applied one layer earlier and to raw bytes rather than a
# parsed address; that copy still owns the header-derived half, and the two are deliberately
# not shared (Core must not depend upward on a middleware module for a one-line predicate).
# `test/http_internals_contract_tests.jl` asserts the two agree, which is what makes keeping
# them separate safe.
#
# The deprecated IPv4-COMPATIBLE form (`::a.b.c.d`, no `ffff`) is deliberately NOT demoted,
# matching `_norm`: it is not a reliable indicator of an IPv4 peer.
function _ipaddr_from_bytes(bytes)::IPAddr
    length(bytes) == 4 && return IPv4(bytes[1], bytes[2], bytes[3], bytes[4])
    acc = UInt128(0)
    for b in bytes
        acc = (acc << 8) | UInt128(b)
    end
    return (acc >> 32) == 0x0000_0000_0000_ffff ? IPv4(UInt32(acc & 0xffff_ffff)) : IPv6(acc)
end

# HTTP.jl v1's `Sockets.getpeername(::HTTP.Stream)` no longer works in v2 — server streams
# are not raw sockets. The peer address is reachable through the server connection that v2
# tracks on the stream (`stream.tracked.conn`, a Reseau `TCP.Conn`/`TLS.Conn`, whose backing
# `TCP.FD` carries `raddr`; see `_conn_fd`). Navigate that path defensively and fall back to
# loopback when the address is unavailable so a request is never failed merely because the
# client IP couldn't be determined — but make that fallback *loud*. Silently treating every
# client as loopback degrades IP-based controls (rate limiting keys collapse to one bucket,
# audit logs lose the source IP) and, combined with `ExtractIP(trusted_proxies=[loopback])`,
# would cause `X-Forwarded-For` to be trusted from every client. We distinguish two cases:
#   * `raddr === nothing` — a legitimate runtime condition for some connection types; warn.
#   * a thrown `getfield` — the HTTP/Reseau internal layout this reaches into has likely
#     changed; this is a structural break, so log it as an error with the exception.
# Both use `maxlog=1` so a persistent failure can't flood the log one line per request.
function _peer_ip(stream::HTTP.Stream)::IPAddr
    try
        conn = getfield(getfield(stream, :tracked), :conn)
        raddr = getfield(_conn_fd(conn), :raddr)
        if raddr === nothing
            @warn "Nitro: peer address unavailable on this connection; falling back to " *
                  "loopback. IP-based rate limiting, audit logging and trusted-proxy " *
                  "checks are degraded for affected requests." maxlog=1
            return Sockets.localhost
        end
        return _ipaddr_from_bytes(getfield(raddr, :ip))
    catch err
        @error "Nitro: could not read the peer IP from HTTP stream internals — the " *
               "HTTP.jl/Reseau stream layout `_peer_ip` reaches into may have changed. " *
               "Falling back to loopback, which SILENTLY DEGRADES IP-based rate limiting " *
               "and audit logging, and (with `trusted_proxies` set) can cause " *
               "X-Forwarded-For to be trusted from every client. Pin HTTP.jl/Reseau and " *
               "verify `_peer_ip`." exception=(err, catch_backtrace()) maxlog=1
        return Sockets.localhost
    end
end

# Custom stream adapter (replaces `HTTP.streamhandler`, which unconditionally writes the
# handler's returned `Response`). Nitro's STREAM/WebSocket handlers take over the raw
# stream and write the response themselves, so we only emit the serialized `Response` when
# the handler hasn't already started one. The HTTP.jl v2 server loop closes the read/write
# sides and turns any thrown exception into a 500 after this returns.
# Write a response body to the stream WITHOUT consuming it. HTTP.jl v2's
# `_write_response_body_to_stream!` advances the `BytesBody` read cursor, which corrupts
# any Response object that is reused across requests — a common pattern in handler code
# (e.g. module-level `const` error responses). Reading `BytesBody.data` directly is
# cursor-independent, so a shared response can be written any number of times.
#
# Upstream has moved on this, in both directions, which is exactly why Nitro does not depend
# on it. The consume-and-close-on-write of a String→`BytesBody` body was declared *intentional*
# in HTTP.jl #1272 — and then reversed by HTTP.jl #1364 (2.7.0), which stores String bodies
# as-is, "exactly like `Vector{UInt8}` bodies"; `Vector{UInt8}` was already non-destructive
# (HTTP.jl #1254). Nitro depends on neither state of that question — it writes the bytes here,
# so the reuse guarantee is ours and does not move when upstream's does.
#
# 2.7.0 also added `_check_response_body_unsent`, which runs in `write_response!` before the
# head is written and answers 500 for a `BytesBody`/`CallbackBody` that is already sent or
# closed. Reading `.data` never advances `next_index` nor sets `closed`, so a shared response
# is never seen as spent — pinned behaviorally in test/http_internals_contract_tests.jl,
# because #1364's note that reading `.data` directly "isn't explicitly restricted" is an
# absence of prohibition rather than a guarantee.
#
# The `BytesBody.data` field this reaches into is an HTTP internal, canaried in
# test/http_internals_contract_tests.jl; the reuse-safety it buys is covered behaviorally in
# test/middleware/authmiddleware_tests.jl. Do not route response bodies back through HTTP's
# consuming writer.
_write_response_body!(stream::HTTP.Stream, ::HTTP.EmptyBody) = nothing
_write_response_body!(stream::HTTP.Stream, ::Nothing) = nothing
function _write_response_body!(stream::HTTP.Stream, body::HTTP.BytesBody)
    isempty(body.data) || write(stream, body.data)
    return nothing
end
function _write_response_body!(stream::HTTP.Stream, body::Union{AbstractVector{UInt8}, AbstractString})
    isempty(body) || write(stream, body)
    return nothing
end


# Write a STREAMING body — the one case where consuming IS the contract (#41).
#
# Everything above exists so a `Response` can be written repeatedly: `staticfiles` and every
# module-level `const` error response hand the same object to the writer again and again, and
# reading `BytesBody.data` leaves the cursor alone so they can. This method is the deliberate
# opposite. An `HTTP.AbstractBody` that is not a `BytesBody` — `_SeekableResponseBody` from
# `HTTP.servecontent(req, ::IO)`, or a `CallbackBody` — is a *cursor over a source*, not a buffer.
# Reading it is the only way to send it, and a second send would produce a truncated body.
#
# That is not a violation of nitro-core §4; it is why §4 is phrased about SHARED responses. A
# streamed body cannot be shared, so the rule it protects does not apply — and the rule it *does*
# obey is HTTP 2.7's `_check_response_body_unsent`, which refuses to resend a spent body with a
# 500 rather than silently truncating. Never cache a response built this way.
#
# `body_read!` / `body_closed` / `body_close!` are HTTP.jl **public** API (declared through
# `Expr(:public, …)`), unlike the `BytesBody.data` field above — so this method depends on a
# supported interface rather than on a layout canary.
#
# ── The loop terminates on the SHORT READ, never on `body_closed` (#160) ──
#
# This used to read `while !HTTP.body_closed(body)`, and that pre-check silently dropped the whole
# body whenever a producer finished before the drain began. "Closed" and "drained" are different
# states: for `HTTP.SSEStream` — whose buffer is a `Base.BufferStream` — `close` flips `isopen`
# immediately while the written bytes are still queued, so the pre-check saw a closed body with
# 22 bytes pending and never entered the loop. Nothing errored; the client just received an empty
# event stream. `Res.sse`'s producer closes the stream to *end the response*, so for SSE that is
# not an edge case, it is the common path whenever the producer outruns the socket.
#
# Three independent sources say the short read is the terminator, which is what makes this a fix
# rather than a preference:
#
#   1. `body_read!`'s own docstring — "Returns `0` on EOF".
#   2. Every concrete implementation returns 0 once exhausted: `_SeekableResponseBody` and
#      `CallbackBody` both open with `body_closed(body) && return 0`, and `SSEStream` with
#      `eof(buf) && return 0` — which blocks until a byte arrives or the stream closes AND drains.
#   3. HTTP.jl's own `_write_response_body_to_stream!` is this exact loop, with no pre-check.
#
# The bug was latent rather than visible because `SSEStream` is the only body Nitro serves that can
# hold bytes *after* reporting itself closed — its buffer is a `Base.BufferStream`, where `isopen`
# flips on `close` while `eof` stays false until the queue drains. The others never reach the
# pre-check in that state: `_SeekableResponseBody` and `CallbackBody` open `body_read!` with
# `body_closed(body) && return 0`, so the two conditions agree, and `FixedLengthBody`/`EOFBody`
# report 0 on exhaustion without ever setting `closed` at all — for which the short read is strictly
# the more correct terminator. (`BytesBody`/`EmptyBody` are excluded by dispatch.)
#
# Do NOT reintroduce the pre-check, and do not add HTTP's companion `body_closed` →
# `ArgumentError("body is closed")` guard either: a closed-with-pending `SSEStream` is legitimate,
# and that throw would reject exactly the case this comment exists to protect. Regression: the
# fast-producer testset in test/sse_tests.jl, which writes and closes before `serve` ever drains.
function _write_response_body!(stream::HTTP.Stream, body::HTTP.AbstractBody)
    buffer = Vector{UInt8}(undef, _STREAM_CHUNK_BYTES)
    try
        while true
            n = HTTP.body_read!(body, buffer)
            n == 0 && break
            # A view, not a copy: `body_read!` fills a prefix of the buffer and reports how much.
            write(stream, @view(buffer[1:n]))
        end
    finally
        # `finally`, not a trailing call: `write` throwing on a client disconnect is the EXPECTED
        # event on a large download, not an exceptional one, and without this the file handle
        # would leak on exactly the requests most likely to be interrupted. HTTP.jl does not
        # rescue it for us — `_write_all_response!` closes bodies only on its own request-handler
        # path, and Nitro serves through `HTTP.listen!` with its own `stream_handler`.
        #
        # Releases the underlying handle when the body owns it. Idempotent, and a no-op for a body
        # that already closed itself on the final short read.
        HTTP.body_close!(body)
    end
    return nothing
end

# Release a STREAMING response body, whether or not it was ever written.
#
# `_write_response_body!` closes what it drains, but it only runs when a body is actually written.
# Three paths produce a streaming body and never drain it: a handler that already called
# `startwrite` (`_response_started`), a `HEAD` — which `stream_handler` now skips outright (#160) —
# and any middleware that replaces or discards the response after it was built. Each of those leaks
# an open file descriptor, and `HEAD` is one of the *cheap* requests a warm client makes constantly.
#
# A `304` is NOT on that list, and the wording here used to say it was. HTTP suppresses its body at
# the socket (`ignore_writes`), but the drain still ran and still consumed the cursor to completion,
# so the handle was released by `_write_response_body!`'s own `finally` rather than by this net. The
# distinction matters now that `HEAD` genuinely does skip the drain: for `HEAD` this net is the
# owner, not the backstop.
#
# **This is where every comparable framework puts it: on the response lifecycle, not on the write.**
# Go's `serveFile` uses `defer f.Close()` in the handler, so it runs on every return path; Express's
# `send` registers `onFinished(res, cleanup)` plus an `error` handler, so the stream is destroyed on
# completion *or* client abort; Django's `FileResponse` relies on the WSGI server calling
# `response.close()`. Nitro's equivalent hook is this handler's `finally`.
#
# `BytesBody` and `EmptyBody` are excluded by dispatch, and that exclusion is load-bearing: they are
# buffers rather than cursors, and `body_close!` on one sets `closed`, which makes HTTP 2.7's
# `_check_response_body_unsent` answer **500** the next time a SHARED response is sent. Closing them
# here would break exactly the reuse pattern nitro-core §4 exists to protect.
_release_response_body!(::HTTP.BytesBody) = nothing
_release_response_body!(::HTTP.EmptyBody) = nothing
_release_response_body!(body::HTTP.AbstractBody) = (HTTP.body_close!(body); nothing)
_release_response_body!(_) = nothing

# How much of a refused body to read and discard before closing, so the client can actually
# receive its 413.
#
# Closing a socket that still holds unread received data sends a **RST**, and an RST discards
# whatever is sitting in the send buffer — including the 413 we just wrote. The client then sees a
# connection reset instead of a status code, which is strictly worse than no limit at all: it
# cannot tell "too large" from "server crashed". Reading the remainder first lets the close be an
# orderly FIN.
#
# This is Tomcat's `maxSwallowSize`, and 2 MiB is its default. nginx spells the same idea
# `lingering_close`; Go's `net/http` drains on close for the same reason. The budget is what keeps
# it a courtesy rather than a second denial-of-service vector — past it, a client sending gigabytes
# has already declared its intent, and eating an RST is the correct outcome for it.
const _MAX_SWALLOW_BYTES = 2 * 1024 * 1024

function _swallow_request_body!(stream::HTTP.Stream, budget::Int)
    scratch = Vector{UInt8}(undef, min(budget, _STREAM_CHUNK_BYTES))
    spent = 0
    try
        while spent < budget
            n = readbytes!(stream, scratch, min(length(scratch), budget - spent))
            n == 0 && break
            spent += n
        end
    catch err
        # A client that disconnects while being swallowed is the expected case on this path, not an
        # exceptional one — it is already being refused. Never let it mask the 413. An interrupt is
        # not that: the janitor discipline in src/middleware/janitor.jl (#190) makes rethrowing it
        # a house rule, and this runs on a request task where a Ctrl-C must still land.
        err isa InterruptException && rethrow()
    end
    return nothing
end

# Answer 413 for a body that passed `max_body_bytes`, and close the connection.
#
# Built fresh on every rejection rather than hoisted to a module-level `const`, which is otherwise
# Nitro's endorsed pattern for a fixed error response (nitro-core §4). The difference is that this
# response is assigned to `stream.response`, and HTTP writes to that object IN PLACE on the way
# out — `startwrite` sets `.close` when the request body was not fully consumed (which is exactly
# our case) and back-fills `.content_length`, `_server_closeread` sets `.close` again, and
# `_serve_h1_conn!`'s error path calls `removeheader(stream.response.headers, …)`. A shared `const`
# would take all of that concurrently, across every rejecting connection. A rejection is rare by
# construction, so the allocation costs nothing worth saving.
#
# Note it is NOT the `Connection: close` header that does this: `_write_server_stream_head!` copies
# the headers vector before calling `setheader` on it. That was this comment's original claim and
# it was wrong about HTTP 2.7.1 — the conclusion survived the correction, the reason did not.
#
# The connection always closes, even when the swallow above consumed the whole body and keep-alive
# would technically survive. `_serve_h1_conn!` checks `_response_wants_close` and returns, so the
# undrained remainder of an abusive body can never be mistaken for the next request on the
# connection — and a client that just sent an oversized body has nothing to gain from being handed
# the same socket to retry on. `close = true` is set explicitly rather than left to HTTP's
# `startwrite`, which would infer it from the unconsumed body: that inference is a private
# implementation detail, while `_response_wants_close` honours the flag as public behavior.
function _reject_oversized_body!(stream::HTTP.Stream, limit::Int64, drain::Bool)
    # The only server-side signal that a request was refused: the rejection returns before the
    # middleware chain, so there is no access-log line and no handler. Tomcat, nginx and Django all
    # record a rejected oversize body.
    #
    # Split in two on purpose. `maxlog` is a **process-lifetime** budget, not a rate limit — past
    # it the site is silent for the life of the process — so a single `maxlog=N` warning is a
    # first-sighting alarm and nothing more. Worse, at any N an unauthenticated client can spend N
    # cheap requests to buy permanent silence for every later rejection. So the warning fires once
    # to say the server is refusing bodies at all, and the per-request detail goes to `@debug`,
    # which is compiled out by default and can be switched on by whoever is actually investigating.
    # An unbounded `@warn` is not an option here: this path is reachable pre-auth, which would make
    # the body cap a log-flood amplifier.
    #
    # The method and the declared length are safe to record — HTTP validates the method as an RFC
    # 7230 token at parse time, so it cannot carry CR/LF. The target is deliberately NOT logged:
    # access logging redacts query strings by default and a rejected request is no exception.
    @warn("Refusing request bodies over max_body_bytes with 413 (detail at debug level)",
          limit = limit, maxlog = 1)
    @debug("Request body exceeds max_body_bytes; refused with 413",
           method = stream.message.method,
           declared_content_length = stream.message.content_length,
           limit = limit)
    # BEFORE the write, not after: swallowing calls `_maybe_write_continue!`, which would try to
    # emit a `100 Continue` interim *after* the final response had already gone out. Draining first
    # keeps the two in legal order, and in every reachable combination the continue is either a
    # no-op (no `Expect` header, or already sent during the read) or skipped entirely (`drain`
    # is false precisely when the client is still waiting for it).
    drain && _swallow_request_body!(stream, _MAX_SWALLOW_BYTES)

    resp = HTTP.Response(413, "Request body exceeds the configured limit of $(limit) bytes")
    resp.close = true
    stream.response = resp
    _write_response_body!(stream, resp.body)
    return nothing
end

# A `HEAD` response carries the `Content-Length` the same `GET` would (RFC 9110 §9.3.2) (#146).
#
# HTTP.jl frames the two differently. For a `GET` it picks `FIXED` mode and `setheader`s
# `Content-Length` from `response.content_length` — which is why `Res.json`/`send`/`html`/`status`
# can leave the header out. For a `HEAD` it picks `NONE` mode, which only ever *removes* a header
# the status forbids and never synthesizes one, so every builder that leaves the header to HTTP.jl
# lost it on `HEAD`. Adding it here, once, from the same `content_length` field the `GET` path
# reads keeps the two equal by construction — for every builder, raw return and hand-built
# `HTTP.Response` alike — where a per-builder header would only ever cover `Res`.
#
# Skipped when there is nothing honest to say: an unknown length (`-1` — a streamed or SSE body,
# which a `GET` would send chunked), a header the response already set (`Res.file`, static files),
# and statuses that carry no representation — 1xx and 204 must not send the header, and a 304's
# empty body says nothing about the size of the representation it stands in for.
#
# A new response, never a mutated one: `resp` may be a shared `const` (nitro-core §4).
function _with_head_content_length(resp::HTTP.Response)::HTTP.Response
    status = resp.status
    (resp.content_length < 0 || status < 200 || status == 204 || status == 304) && return resp
    HTTP.hasheader(resp, "Content-Length") && return resp
    return add_response_headers(resp, "Content-Length" => string(resp.content_length))
end

function stream_handler(middleware::Function; max_body_bytes::Int64 = DEFAULT_MAX_BODY_BYTES)
    return function(stream::HTTP.Stream)
        ip = _peer_ip(stream)
        req = _http_stream_request(stream, max_body_bytes)
        # Short-circuits BEFORE the middleware chain, so an oversized request produces no access-log
        # line, no CORS headers and no custom error formatting. That is the correct trade: the
        # alternative is handing middleware a truncated body, which is strictly worse than handing
        # it nothing.
        req isa _BodyRejected && return _reject_oversized_body!(stream, max_body_bytes, req.drain)
        req.context[:ip] = ip
        req.context[:stream] = stream

        result = middleware(req)
        produced = result isa HTTP.Response ? result : nothing

        try
            if !_response_started(stream)
                resp = produced === nothing ? HTTP.Response(200) : produced
                stream.message.method == "HEAD" && (resp = _with_head_content_length(resp))
                resp.request = req
                stream.response = resp
                # `HEAD` gets the head and no body, so there is nothing to drain — and draining it
                # anyway is not merely wasted work, it can pin the process (#160). HTTP's
                # `startwrite` sets `ignore_writes` for a bodyless response and `_server_write`
                # then returns without touching the socket, so for an open-ended body — an
                # `HTTP.SSEStream` whose producer is still running — this loop consumes events
                # forever. Because it never touches the socket, `terminate`'s force-close cannot
                # unblock it either: the request task, the connection task (`parallel_stream_handler`
                # waits on it) and the producer task are all pinned for the life of the process.
                # One `curl -I` against a route registered for HEAD is enough.
                #
                # Skipping the drain is equivalent for every buffered body — those writes were
                # already being discarded — and the `finally` below still releases a streaming one,
                # which is what lets an SSE producer notice and unwind. The response head is
                # unaffected: the server loop's `closewrite` calls `startwrite` regardless.
                #
                # Deliberately narrow: `HEAD` only, keyed on the request method. Status-based
                # suppression (204/304) is the same class of hazard, but `Res.sse` cannot produce
                # those statuses. The response head a `HEAD` gets is `_with_head_content_length`'s
                # business, above (#146).
                #
                # `stream.message.method`, NOT `req.method`. They are equal at entry and are two
                # different mutable objects: `_http_stream_request` builds a fresh `Request` from
                # `head.method`, while HTTP's own suppression keys on `stream.message`. A
                # middleware that rewrites the method — an app mapping `HEAD` onto its `GET`
                # handlers, or an `X-HTTP-Method-Override` layer — would otherwise desynchronize
                # the two: rewriting `HEAD → GET` reinstates the drain HTTP is still ignoring, and
                # the pin this guard exists to remove comes back. Reading the value HTTP itself
                # branches on makes that unrepresentable. `_reject_oversized_body!` above already
                # reads it the same way.
                stream.message.method == "HEAD" || _write_response_body!(stream, resp.body)
            end
        finally
            # Idempotent, and a no-op for the buffered bodies that are the overwhelming majority.
            # `_write_response_body!` has usually already done this — releasing as soon as the body
            # is drained keeps descriptor pressure down — so this is the net, not the owner.
            produced === nothing || _release_response_body!(produced.body)
        end
        return nothing
    end
end

# One `Threads.@spawn` per request, and nothing else (#39). This used to spawn the
# task and then, inside it, `@async handle_stream(stream)` followed by `wait(handle)`
# — a second Task allocation, a scheduler enqueue/dequeue, and a second condition
# variable, all so the parent could block doing nothing until the child finished.
# The inner task never ran concurrently with its parent, so it bought no
# concurrency; exception propagation is identical either way because both `wait`s
# rethrow. HTTP.jl already spawns per *connection*; this spawn is what moves each
# *request* off that connection task, which is the Go-style model Nitro wants
# (nitro-core §2). Do not reintroduce the inner `@async`.
#
# One genuine semantic difference, since "pure overhead" undersells it: `@async`
# creates a **sticky** task, pinned to the thread that created it, while
# `Threads.@spawn` creates a migratable one. A handler may therefore now move
# between threads at a yield point mid-request. Nothing in Nitro depends on
# thread affinity — `src/` calls `Threads.threadid()` nowhere and uses no
# task-local storage — and migratable is the correct model here. But an *app*
# using the `threadid()`-as-index pattern (`buffers[Threads.threadid()]`) was
# already unsound under `@async` and is now visibly so.
function parallel_stream_handler(handle_stream::Function)
    function(stream::HTTP.Stream)
        task = Threads.@spawn handle_stream(stream)
        wait(task)
    end
end
