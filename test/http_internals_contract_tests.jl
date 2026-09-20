@testitem "HTTP internals contract" tags=[:core] setup=[NitroCommon] begin
using Test
import HTTP
import Nitro

# ── Canary for Nitro's coupling to HTTP.jl v2 private/undocumented surface ──────
#
# Nitro reaches into the HTTP internals asserted below from:
#   • src/core/ — `_buffered_stream_request`, and `getfield(req, :context)` on the raw
#       `HTTP.RequestContext` (`request_input`, `Types.request_cache!`).
#   • `_request_context_metadata!` — reached TRANSITIVELY, which is why it is still canaried
#       below. Nitro no longer calls it directly (the wrapper that did died with #151), but
#       every `req.context[…]` read and write in `src/` now goes through HTTP's own
#       `getproperty`, which calls it. Rename it upstream and the session, CSRF, auth and
#       app-context paths all break at once.
#   • src/utilities/bodyparsers.jl — the `EmptyBody` / `BytesBody` body hierarchy.
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
    @test isdefined(HTTP, :_buffered_stream_request)
end

@testset "Request struct still exposes the fields we read" begin
    flds = fieldnames(HTTP.Request)
    @test :proto_major in flds
    @test :proto_minor in flds
    @test :context     in flds
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

end
