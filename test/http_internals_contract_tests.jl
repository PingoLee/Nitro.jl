@testitem "HTTP internals contract" tags=[:core] setup=[NitroCommon] begin
using Test
import HTTP
import Nitro
import Sockets

# ── Canary for Nitro's coupling to HTTP.jl v2 private/undocumented surface ──────
#
# Nitro reaches into the HTTP internals asserted below from:
#   • src/core/ — `getfield(req, :context)` on the raw `HTTP.RequestContext`
#       (`request_input`, `Types.request_cache!`), and the `Stream` head/body split that
#       `_http_stream_request` reads to cap a request body (#17).
#   • `_request_context_metadata!` — reached TRANSITIVELY, which is why it is still canaried
#       below. Nitro no longer calls it directly (the wrapper that did died with #151), but
#       every `req.context[…]` read and write in `src/` now goes through HTTP's own
#       `getproperty`, which calls it. Rename it upstream and the session, CSRF, auth and
#       app-context paths all break at once.
#   • src/utilities/bodyparsers.jl — the `EmptyBody` / `BytesBody` body hierarchy.
#   • src/core/pipeline.jl — `_allowed_methods` walks the router's route tree to build a 405's
#       `Allow` header (#281): `Router.routes`, the `Node`/`Leaf`/`Variable` fields, `match`,
#       `_route_variable_matches` and `_router_request_path`.
#   • src/context.jl — `_shutdown_server`'s bounded drain: it depends on `close(::Server)`
#       releasing the listener BEFORE its unbounded quiesce loop, and escalates to
#       `HTTP.forceclose`.
#
# None of these are part of HTTP's public, SemVer-guaranteed API, so a 2.x bump
# can rename or remove them WITHOUT a breaking-version signal. The compat pin
# (`HTTP = "~2.7"`) caps that exposure to 2.7 patch releases; this testset is the
# canary — if an upgrade moves the ground, it fails HERE, loud and naming the
# missing symbol, instead of deep inside request handling.
#
# What USED to live at the bottom of this file: a source-level diff of Nitro's
# `getproperty` symbol set against HTTP's (#32/#150). It existed because Nitro
# `@eval`ed a same-signature `Base.getproperty(::HTTP.Request, ::Symbol)` that REPLACED
# HTTP's method process-wide, which obliged Nitro's version to stay a strict superset of
# HTTP's forever. #151 deleted the override, so that obligation — and the ~300 lines of
# detector that policed it — no longer exist. `Base.get(req.context, …)` now goes through
# HTTP's own method, which is what the last testset pins.

@testset "private functions still exist" begin
    @test isdefined(HTTP, :_request_context_metadata!)
    # `_buffered_stream_request` deliberately is NOT asserted here any more. Until #17 Nitro
    # delegated its whole request build to it; the body cap replaced that call with a
    # reimplementation over supported API, so the reach is gone and canarying it would pin a
    # symbol nothing uses. That is a net REDUCTION in private surface, which is the part worth
    # remembering if the delegation is ever tempting again.
end

@testset "the request-building API the body cap depends on is still supported" begin
    # These are not private reaches -- `startread` is exported, `readbytes!` is the Base IO
    # interface, and `get_request_context` is declared public. They are asserted anyway because
    # `_http_stream_request` reimplements `_buffered_stream_request` on top of them (#17), so a
    # signature change upstream breaks every request rather than one call site. A failure here
    # is a smoke test, not the structural alarm the private canaries above raise.
    # `hasmethod(f, Tuple{HTTP.Stream})` is the wrong tool twice over, and both traps are worth
    # naming because the obvious spelling fails silently in opposite directions. `HTTP.Stream` is
    # a UnionAll over `{ISCLIENT, Req}` while the server methods are defined on `Stream{false}`,
    # so `hasmethod` answers FALSE for a method that plainly exists. And `readbytes!` answers TRUE
    # for any `IO` because of Base's own fallback -- which would make the assertion vacuous, since
    # it would keep passing after HTTP dropped its method entirely. Matching on the signature and
    # filtering by defining module avoids both.
    # `Stream{false}`, not `HTTP.Stream`. The UnionAll covers `Stream{true}` too, and HTTP defines
    # BOTH -- so matching on it stays green if the fork drops only the server dispatch, which is
    # the exact method `_http_stream_request` calls. The 3-arg arity is pinned for the same reason:
    # it is the form Nitro uses.
    defines_server_stream_method(f, arity) =
        any(m -> m.sig <: Tuple{Any, HTTP.Stream{false}, Vararg{Any}} &&
                 parentmodule(m) === HTTP &&
                 m.nargs - 1 == arity,
            methods(f))

    @test :startread in names(HTTP)
    @test defines_server_stream_method(HTTP.startread, 1)
    @test defines_server_stream_method(Base.readbytes!, 3)
    @test hasmethod(HTTP.get_request_context, Tuple{HTTP.Request})

    # Control: the matcher must be capable of answering false, or none of the above means anything.
    @test !defines_server_stream_method(Base.countlines, 1)
end

@testset "Stream keeps the head and the body separate" begin
    # The mechanism the body cap rests on: `Stream`'s constructor splits the parsed request, so
    # `message` carries the head (headers, `content_length`) with an `EmptyBody` substituted while
    # the live reader stays on `request_body`. That is what lets `_http_stream_request` read a
    # declared Content-Length and refuse an oversized upload with ZERO bytes read -- and it is
    # what keeps an `Expect: 100-continue` client from ever being told to send.
    flds = fieldnames(HTTP.Stream)
    @test :message      in flds
    @test :request_body in flds
end

@testset "Request struct still exposes the fields we read" begin
    flds = fieldnames(HTTP.Request)
    @test :proto_major    in flds
    @test :proto_minor    in flds
    @test :context        in flds
    # Read by `_http_stream_request` as the declared body length: -1 chunked, 0 none, >0 fixed.
    @test :content_length in flds
end

@testset "the route tree `_allowed_methods` walks is still shaped the same (#281)" begin
    H = HTTP.Handlers
    @test :routes in fieldnames(HTTP.Router)
    @test fieldtype(HTTP.Router{Any,Any,Any}, :routes) === H.Node
    for f in (:segment, :exact, :conditional, :wildcard, :doublestar, :methods)
        @test f in fieldnames(H.Node)
    end
    @test :method  in fieldnames(H.Leaf)
    @test :handler in fieldnames(H.Leaf)
    @test :pattern in fieldnames(H.Variable)
    @test hasmethod(H.match, Tuple{H.Node, String, Vector{SubString{String}}, Int})
    @test hasmethod(H._route_variable_matches, Tuple{Regex, SubString{String}})
    @test H._router_request_path("/a/b?x=1") == "/a/b"

    # Behavior, not only shape: a plain variable, a pattern-constrained one, and a `**`.
    r = HTTP.Router()
    h = req -> HTTP.Response(200)
    HTTP.register!(r, "GET",    "/a/{x}", h)
    HTTP.register!(r, "DELETE", "/a/{n:[0-9]+}", h)
    HTTP.register!(r, "PUT",    "/b/**", h)
    @test Nitro.Core._allowed_methods(r, "/a/7") == ["DELETE", "GET"]
    @test Nitro.Core._allowed_methods(r, "/a/z") == ["GET"]
    @test Nitro.Core._allowed_methods(r, "/b/c/d?q") == ["PUT"]
    @test isempty(Nitro.Core._allowed_methods(r, "/c"))
end

@testset "router hands over STILL-ENCODED path segments" begin
    # Load-bearing for `Types.pathparams`, which owes path params their single percent-decode
    # precisely because HTTP.jl's router does not perform one (it splits `req.target` without
    # unescaping). If an HTTP.jl bump starts decoding here, `Types.pathparams` would decode a
    # second time and silently reintroduce exactly the double-decode #70 removed -- so this
    # fails loudly instead.
    r = HTTP.Router()
    seen = Ref{Any}(nothing)
    HTTP.register!(r, "GET", "/f/{name}", req -> (seen[] = HTTP.getparams(req); HTTP.Response(200)))
    r(HTTP.Request("GET", "/f/a%2Fb%20c"))
    @test seen[]["name"] == "a%2Fb%20c"

    # The mirror half of the invariant: `HTTP.queryparams` DOES decode, which is why
    # `Types.queryvars` must not.
    @test HTTP.queryparams(HTTP.URI("/s?q=100%25%20off").query)["q"] == "100% off"

    # `getparams` yields `nothing` -- not an empty Dict -- for a request that never went
    # through the router. `Types.pathparams` must pass that through untouched: `payload(req)`
    # and `merge_request_input!` branch on it, and decoding blindly over it throws.
    @test HTTP.getparams(HTTP.Request("GET", "/x")) === nothing
    @test Nitro.Types.pathparams(HTTP.Request("GET", "/x")) === nothing
    @test Nitro.getparams(HTTP.Request("GET", "/x")) === nothing
end

@testset "body type hierarchy still present" begin
    @test isdefined(HTTP, :EmptyBody)
    @test isdefined(HTTP, :BytesBody)
    @test :data in fieldnames(HTTP.BytesBody)
    # `next_index` and `closed` are what `_check_response_body_unsent` reads to decide a body
    # is spent (below). `_write_response_body!` must leave both alone.
    @test :next_index in fieldnames(HTTP.BytesBody)
    @test :closed     in fieldnames(HTTP.BytesBody)
end

@testset "reading BytesBody.data does not spend the body (HTTP 2.7 pre-send check)" begin
    # HTTP 2.7.0 (#1364) added `_check_response_body_unsent`, called from `write_response!`
    # before the response head goes out. It answers **500** for a `BytesBody`/`CallbackBody`
    # already sent or closed. Nitro's whole non-consuming write path
    # (`src/core/transport.jl::_write_response_body!`) depends on `BytesBody.data` being
    # readable without tripping that check, because `staticfiles` and every module-level
    # `const` error response hand the SAME `Response` object to the writer repeatedly.
    #
    # #1364 says only that reading `.data` directly "isn't explicitly restricted" — an absence
    # of prohibition, not a guarantee. So pin the mechanism rather than trusting the note.
    @test isdefined(HTTP, :_check_response_body_unsent)

    # Since #1364 a String or Vector{UInt8} body is stored AS-IS — `HTTP.Response(200, "x")`
    # no longer wraps it in a `BytesBody` at all, which is why `_write_response_body!` carries
    # an `AbstractString`/`AbstractVector{UInt8}` method alongside the `BytesBody` one. Pin
    # that, then build the `BytesBody` explicitly: `HTTP.servecontent` returns one for a byte
    # source, so it is still the cursor-bearing shape the static mounts hand to the writer.
    @test HTTP.Response(200, "abc").body isa AbstractString
    @test HTTP.Response(200, Vector{UInt8}("abc")).body isa AbstractVector{UInt8}

    body = HTTP.BytesBody(Vector{UInt8}("shared-body"))
    resp = HTTP.Response(200, body)
    @test resp.body isa HTTP.BytesBody
    before_index, before_closed = body.next_index, body.closed

    # Exactly what `_write_response_body!(::HTTP.Stream, ::HTTP.BytesBody)` does.
    buf = IOBuffer()
    for _ in 1:3
        isempty(body.data) || write(buf, body.data)
    end

    @test body.next_index == before_index   # cursor untouched
    @test body.closed     == before_closed  # never closed
    @test String(take!(buf)) == "shared-body"^3
    @test HTTP._check_response_body_unsent(resp) === nothing  # still sendable after 3 writes
end

@testset "public static-serving API (src/core/staticfiles.jl, src/response.jl)" begin
    # `servecontent` builds Nitro's file responses: it owns ETag/Last-Modified, the whole
    # precondition table (If-None-Match/-Modified-Since/-Match/-Unmodified-Since/-Range),
    # 304/412/416, and byte ranges. `body_read!`/`body_closed` drive the streaming write path.
    #
    # These are DECLARED PUBLIC by HTTP.jl (`Expr(:public, …)` in HTTP.jl), unlike everything
    # above — so they carry a SemVer promise and this testset is a smoke check, not a canary.
    # It is here so a bump that moves them fails in the same place as the internals.
    for sym in (:servecontent, :servefile, :fileserver, :AbstractBody, :CallbackBody,
                :body_read!, :body_close!, :body_closed)
        @test isdefined(HTTP, sym)
    end

    # `Res.adopt_stream_io!` sets `owns_io` so a streamed body releases the file handle when it is
    # drained -- the job HTTP's own `servefile` does through a private `_finalize_servefile_source!`.
    # It is written with `hasfield` so it does not name the private body type, which means a rename
    # upstream would make it degrade SILENTLY into an unbounded descriptor leak rather than fail.
    # This is the assertion that makes that loud instead.
    let io = IOBuffer(Vector{UInt8}("streamed"))
        streamed = HTTP.servecontent(HTTP.Request("GET", "/x"), io; name = "x.bin")
        @test streamed.body isa HTTP.AbstractBody
        @test !(streamed.body isa HTTP.BytesBody)          # a cursor, not a buffer
        @test hasfield(typeof(streamed.body), :owns_io)
        @test streamed.body.owns_io === false              # servecontent does NOT claim it
        Nitro.Res.adopt_stream_io!(streamed, io)
        @test streamed.body.owns_io === true               # ... and we do
    end

    # The OTHER branch, which is the one that leaks if it is wrong. A 304/412/416 carries no body
    # at all, so nothing will ever drain it and the handle has to be closed directly -- on the
    # cheapest request a client can make, and the one a warm client makes constantly.
    #
    # This asserts `!isopen(io)`, which is the only thing that fails if `else close(io)` is
    # deleted. Asserting `status == 304` (as the mount-level tests do) passes either way.
    let path = joinpath(mktempdir(), "x.bin")
        write(path, "some streamable bytes")
        tag = "\"pinned\""
        io  = open(path, "r")
        resp = HTTP.servecontent(HTTP.Request("GET", "/x", ["If-None-Match" => tag]), io;
                                 name = "x.bin", etag = tag)
        @test resp.status == 304
        @test isopen(io)                                   # servecontent leaves it to the caller
        Nitro.Res.adopt_stream_io!(resp, io)
        @test !isopen(io)                                  # <-- the branch under test

        # And the streamed counterpart: the handle stays open until the body is drained, then
        # `body_close!` releases it because `owns_io` was adopted.
        io2 = open(path, "r")
        full = HTTP.servecontent(HTTP.Request("GET", "/x"), io2; name = "x.bin", etag = tag)
        Nitro.Res.adopt_stream_io!(full, io2)
        @test isopen(io2)
        buf = Vector{UInt8}(undef, 4096)
        while !HTTP.body_closed(full.body)
            HTTP.body_read!(full.body, buf) == 0 && break
        end
        HTTP.body_close!(full.body)
        @test !isopen(io2)
    end

    # The two outcomes the mount handler relies on, end to end.
    src = Vector{UInt8}("hello")
    etag = "\"v1\""
    plain = HTTP.servecontent(HTTP.Request("GET", "/x"), src; name="x.txt", etag=etag)
    @test plain.status == 200
    @test HTTP.header(plain, "ETag") == etag

    cond = HTTP.servecontent(HTTP.Request("GET", "/x", ["If-None-Match" => etag]), src;
                             name="x.txt", etag=etag)
    @test cond.status == 304
    @test isempty(HTTP.header(cond, "Content-Length"))  # `_not_modified_headers` strips it
end

@testset "bounded-shutdown surface (src/context.jl `_shutdown_server`)" begin
    # `terminate(timeout=…)` runs `close(server)` on its own task and escalates to
    # `HTTP.forceclose`. `forceclose` is HTTP *public* API declared via `public`, not
    # `export` — so `test/reexports_tests.jl` would not notice its removal, and a rename
    # here would not fail loudly: it would silently reinstate the unbounded hang this
    # canary exists to prevent.
    @test isdefined(HTTP, :forceclose)
    @test hasmethod(HTTP.forceclose, Tuple{HTTP.Server})
    @test hasmethod(close,  Tuple{HTTP.Server})
    @test hasmethod(isopen, Tuple{HTTP.Server})

    # The whole design rests on `close` releasing the LISTENER before the (unbounded)
    # connection drain, so the timeout only ever escalates connection teardown and never
    # delays freeing the port. These two are the halves of that contract.
    @test isdefined(HTTP, :_close_listener!)
    @test isdefined(HTTP, :_close_idle_conns!)
end

@testset "`reuseaddr` is a Server knob (src/core/lifecycle.jl `preprocesskwargs`)" begin
    # Nitro injects `reuseaddr=false` on Windows, where SO_REUSEADDR lets a second process
    # bind a port another is actively listening on. It travels as a `listen!` kwarg and has
    # to land on this field, which `test/server_lifecycle_tests.jl` asserts against.
    @test :reuseaddr in fieldnames(HTTP.Server)
    @test fieldtype(HTTP.Server, :reuseaddr) === Bool
end

@testset "peer-IP field chain still present (src/core/transport.jl `_peer_ip`/`_conn_fd`)" begin
    # `_peer_ip` reaches `stream.tracked.conn.fd.raddr` for TCP and
    # `stream.tracked.conn.tcp.fd.raddr` for TLS. A silent rename anywhere on this
    # chain would send every client's IP to loopback (collapsing rate-limit buckets,
    # blanking audit logs, and — with trusted_proxies — trusting X-Forwarded-For from
    # everyone). Canary the whole chain so a layout change fails HERE, by name.
    @test :tracked in fieldnames(HTTP.Stream)
    @test isdefined(HTTP, :_ServerConn)
    @test :conn in fieldnames(HTTP._ServerConn)

    conn_t = fieldtype(HTTP._ServerConn, :conn)          # Union{TCP.Conn, TLS.Conn}
    conn_variants = conn_t isa Union ? Base.uniontypes(conn_t) : [conn_t]
    tcp = filter(T -> occursin("TCP", string(T)), conn_variants)
    tls = filter(T -> occursin("TLS", string(T)), conn_variants)
    @test !isempty(tcp)   # plaintext transport present
    @test !isempty(tls)   # TLS transport present (the case `_conn_fd` must special-case)

    # TCP.Conn exposes `:fd`; TLS.Conn wraps the TCP connection under `:tcp`.
    tcp_conn = first(tcp)
    @test :fd in fieldnames(tcp_conn)
    @test :raddr in fieldnames(fieldtype(tcp_conn, :fd))
    tls_conn = first(tls)
    @test :tcp in fieldnames(tls_conn)
    @test :fd in fieldnames(fieldtype(tls_conn, :tcp))
end

# Stub connections for the behavioral `_conn_fd` test below. Defined at test-item top
# level because `struct` is illegal inside a `@testset` local scope. They mirror the
# Reseau layouts: TCP exposes `:fd`; TLS wraps the TCP conn under `:tcp`.
struct _FakeTCP; fd; end
struct _FakeTLS; tcp; end
struct _FakeUnknown; whatever; end

@testset "_conn_fd resolves both transports and raises on the unknown layout" begin
    # Behavioral coverage for the actual branching in `_conn_fd` (the canary above only
    # asserts the field *names* exist). This is what the TLS bug fix turned on: a TCP
    # conn exposes `:fd` directly, a TLS conn wraps the TCP conn under `:tcp`, and an
    # unrecognized shape must RAISE — that raise is what `_peer_ip` converts into its
    # loud structural-break alarm instead of silently resolving every client to loopback.
    @test Nitro.Core._conn_fd(_FakeTCP(:tcp_fd)) === :tcp_fd            # TCP → conn.fd
    @test Nitro.Core._conn_fd(_FakeTLS(_FakeTCP(:tls_fd))) === :tls_fd  # TLS → conn.tcp.fd
    @test_throws ErrorException Nitro.Core._conn_fd(_FakeUnknown(1))    # structural break raises
end

@testset "_ipaddr_from_bytes gives one canonical spelling per host (#66)" begin
    # The socket peer reaches Nitro as raw bytes, and ONE IPv4 host can arrive in two
    # shapes: four bytes from an AF_INET socket, or sixteen in the `::ffff:0:0/96` block
    # when a dual-stack AF_INET6 listener reports an IPv4 client. #66 decided that the
    # demotion happens HERE, at the transport boundary, rather than in `ExtractIP` — which
    # is what makes it apply to a pipeline with no `ExtractIP` installed at all, and what
    # keeps `getip == getpeerip` holding when no forwarding header was read.
    v4       = UInt8[203, 0, 113, 7]
    mapped   = UInt8[0,0,0,0, 0,0,0,0, 0,0, 0xff,0xff, 203, 0, 113, 7]   # ::ffff:203.0.113.7
    loopback = UInt8[0,0,0,0, 0,0,0,0, 0,0, 0xff,0xff, 127, 0,   0, 1]   # ::ffff:127.0.0.1
    real_v6  = UInt8[0x20,0x01, 0x0d,0xb8, 0,0,0,0, 0,0,0,0, 0,0,0,0x01] # 2001:db8::1
    compat   = UInt8[0,0,0,0, 0,0,0,0, 0,0,0,0, 203, 0, 113, 7]          # ::203.0.113.7

    # Four bytes: unchanged, and still the common case.
    @test Nitro.Core._ipaddr_from_bytes(v4) === Sockets.IPv4("203.0.113.7")

    # Sixteen mapped bytes: demoted. This is the assertion #66 turns on — against the
    # unpatched code it returns IPv6("::ffff:203.0.113.7") and fails.
    got = Nitro.Core._ipaddr_from_bytes(mapped)
    @test got isa Sockets.IPv4
    @test got === Sockets.IPv4("203.0.113.7")

    # The loopback spelling matters on its own: `trusted_proxies=[ip"127.0.0.1"]` is the
    # single most common proxy configuration there is.
    @test Nitro.Core._ipaddr_from_bytes(loopback) === Sockets.IPv4("127.0.0.1")

    # A genuine IPv6 address is untouched.
    v6 = Nitro.Core._ipaddr_from_bytes(real_v6)
    @test v6 isa Sockets.IPv6
    @test v6 === Sockets.IPv6("2001:db8::1")

    # The deprecated IPv4-COMPATIBLE form (`::a.b.c.d`, no `ffff`) is deliberately NOT
    # demoted — it is not a reliable indicator of an IPv4 peer. `_norm` in
    # src/middleware/extract_ip.jl refuses it for the same reason; the two must stay in step.
    compat_addr = Nitro.Core._ipaddr_from_bytes(compat)
    @test compat_addr isa Sockets.IPv6
    @test compat_addr === Sockets.IPv6("::203.0.113.7")

    # DRIFT GUARD. #66 deliberately did NOT share one helper between this function and
    # `_canonical`/`_norm` in src/middleware/extract_ip.jl: Core must not depend upward on a
    # middleware module for a one-line predicate. The price of that decision is two copies of
    # the `::ffff:0:0/96` rule, and the only thing keeping them honest is this assertion.
    # Without it, widening one copy leaves the whole suite green while a direct dual-stack
    # client and the same host via X-Forwarded-For diverge again — #66, silently reopened.
    canonical = Nitro.Middleware.ExtractIPMiddleware._canonical
    for b in (v4, mapped, loopback, real_v6, compat)
        acc = foldl((a, x) -> (a << 8) | UInt128(x), b; init = UInt128(0))
        parsed = length(b) == 4 ? Sockets.IPv4(b...) : Sockets.IPv6(acc)
        @test Nitro.Core._ipaddr_from_bytes(b) === canonical(parsed)
    end
end

@testset "HTTP owns getproperty(::Request, ::Symbol), and Nitro does not (#151)" begin
    # Nitro used to `@eval` a SAME-SIGNATURE `Base.getproperty(::HTTP.Request, ::Symbol)`
    # from `Core.__init__`, which REPLACED HTTP's own method for the whole process. #151
    # deleted it. This testset is the regression guard for that deletion: it pins that the
    # surviving method is HTTP's, and that the DX sugar it used to add is really gone.
    gp = only(methods(Base.getproperty, (HTTP.Request, Symbol)))
    @test gp.module !== Nitro.Core
    @test parentmodule(gp.module) === HTTP || gp.module === HTTP

    req = HTTP.Request("GET", "/")
    # `:version` is HTTP's own derivation from the proto fields …
    @test req.version == VersionNumber(Int(getfield(req, :proto_major)), Int(getfield(req, :proto_minor)))
    @test req.version isa VersionNumber
    # … `:context` is dict-like (core/request.jl does `Base.get(req.context, :session, nothing)`) …
    @test Base.get(req.context, :__contract_probe__, :sentinel) === :sentinel
    # … and an unknown symbol falls through to the real field.
    @test req.method == "GET"

    # The shorthands are gone: every one now raises rather than silently resolving.
    for sym in (:params, :query, :json, :form, :input, :data, :files, :post, :session, :user, :ip)
        @test_throws FieldError getproperty(req, sym)
    end
end

@testset "HTTP's SSE body contract, which Res.sse is built on (#160)" begin
    # `Res.sse` hands the transport an `HTTP.SSEStream` and nothing else. Three properties of that
    # type are load-bearing for Nitro, and `HTTP = "~2.7"` is a deliberately tight pin, so they are
    # pinned here next to the rest of the HTTP contract.

    # 1. It is an `AbstractBody`, so it dispatches to the STREAMING method of
    #    `_write_response_body!` (src/core/transport.jl) rather than a buffered one.
    @test HTTP.SSEStream <: HTTP.AbstractBody

    events = HTTP.SSEStream()
    try
        @test applicable(HTTP.body_read!, events, UInt8[])
        @test applicable(HTTP.body_closed, events)
        @test applicable(HTTP.body_close!, events)

        # 2. CLOSED and DRAINED are different states, and that is exactly why the write path
        #    terminates on the short read instead of pre-checking `body_closed`. If this ever
        #    became "closed implies empty", the comment in `_write_response_body!` would be
        #    describing a hazard that no longer exists -- and the fast-producer testset in
        #    test/sse_tests.jl is the behavioral half of this guard.
        write(events, HTTP.SSEEvent("pending"))
        close(events)
        @test HTTP.body_closed(events)
        buffer = Vector{UInt8}(undef, 1024)
        n = HTTP.body_read!(events, buffer)
        @test n > 0
        @test String(@view buffer[1:n]) == "data: pending\n\n"
        # ... and only now does it report EOF, which is the loop's terminator.
        @test HTTP.body_read!(events, buffer) == 0
    finally
        HTTP.body_close!(events)
    end

    # 3. `sse_stream` declares an unknown length, which is what makes HTTP choose chunked framing.
    resp = HTTP.sse_stream(200)
    try
        @test resp.body isa HTTP.SSEStream
        @test resp.content_length == -1
        @test !HTTP.hasheader(resp, "Content-Length")
        @test HTTP.header(resp, "Content-Type") == "text/event-stream"
    finally
        HTTP.body_close!(resp.body)
    end

    # The injection rejections Nitro relies on instead of its own deleted framer. A bare CR is a
    # valid SSE line terminator, so accepting one in a single-line field lets one event forge
    # additional fields -- the hole `format_sse_message` had.
    @test_throws ArgumentError HTTP.SSEEvent("d"; event = "a\rb")
    @test_throws ArgumentError HTTP.SSEEvent("d"; event = "a\nb")
    @test_throws ArgumentError HTTP.SSEEvent("d"; id = "a\rb")
    @test_throws ArgumentError HTTP.SSEEvent("d"; id = "a\nb")
    @test_throws ArgumentError HTTP.SSEEvent("d"; id = "a\0b")
    # `data` may legitimately span lines; every break becomes its own `data:` line rather than a
    # smuggled field.
    @test HTTP.SSEEvent("a\rb").data == "a\rb"
end

end
