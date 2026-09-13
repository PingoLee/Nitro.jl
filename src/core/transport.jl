# ── Transport: HTTP.jl / Reseau internals ───────────────────────────────────────
# Peer-IP resolution, the non-consuming response write path, and the stream handlers.
# Included into `module Core` by src/core.jl — not a submodule; see the hub for why.

# ── HTTP.jl v2 compatibility shim ───────────────────────────────────────────────
# The HTTP private/undocumented *functions* Nitro's request layer reaches into are
# wrapped here, so an HTTP upgrade that renames one is a single-line fix instead of
# a grep hunt. Guarded by the "HTTP internals contract" canary in
# test/http_internals_contract_tests.jl.
#
# Deliberately NOT centralized here: the `HTTP.EmptyBody`/`HTTP.BytesBody` body
# *types* (dispatched on inline in bodyparsers.jl / core/transport.jl) and the `_peer_ip`
# stream-layout reach (below) — both carry their own canary coverage.
_http_stream_request(stream::HTTP.Stream)  = HTTP._buffered_stream_request(stream)

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
        ip = getfield(raddr, :ip)
        if length(ip) == 4
            return IPv4(ip[1], ip[2], ip[3], ip[4])
        else
            acc = UInt128(0)
            for b in ip
                acc = (acc << 8) | UInt128(b)
            end
            return IPv6(acc)
        end
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
# The consume-and-close-on-write of a String→`BytesBody` body is *intentional* upstream
# behavior (HTTP.jl #1272), not a bug to wait on; `Vector{UInt8}` bodies are written
# non-destructively by HTTP itself (HTTP.jl #1254). Nitro depends on neither — it writes
# the bytes here. The `BytesBody.data` field this reaches into is an HTTP internal,
# canaried in test/http_internals_contract_tests.jl; the reuse-safety it buys is covered
# behaviorally in test/middleware/authmiddleware_tests.jl. Do not route response bodies
# back through HTTP's consuming writer.
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

function stream_handler(middleware::Function)
    return function(stream::HTTP.Stream)
        ip = _peer_ip(stream)
        req = _http_stream_request(stream)
        req.context[:ip] = ip
        req.context[:stream] = stream

        result = middleware(req)

        if !_response_started(stream)
            resp = result isa HTTP.Response ? result : HTTP.Response(200)
            resp.request = req
            stream.response = resp
            _write_response_body!(stream, resp.body)
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
