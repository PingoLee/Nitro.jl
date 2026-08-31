@testitem "HTTP internals contract" tags=[:core] setup=[NitroCommon] begin
using Test
import HTTP
import Nitro

# ── Canary for Nitro's coupling to HTTP.jl v2 private/undocumented surface ──────
#
# Nitro reaches into the HTTP internals asserted below from:
#   • src/core.jl — `_install_request_getproperty!` overrides
#       `Base.getproperty(::HTTP.Request, ::Symbol)`, mirroring HTTP's own
#       `:context` (`_request_context_metadata!`) and `:version`
#       (`proto_major`/`proto_minor`) handling; and `_buffered_stream_request`.
#   • src/utilities/bodyparsers.jl — the `EmptyBody` / `BytesBody` body hierarchy.
#   • src/context.jl — `_shutdown_server`'s bounded drain: it depends on `close(::Server)`
#       releasing the listener BEFORE its unbounded quiesce loop, and escalates to
#       `HTTP.forceclose`.
#
# None of these are part of HTTP's public, SemVer-guaranteed API, so a 2.x bump
# can rename or remove them WITHOUT a breaking-version signal. The compat pin
# (`HTTP = "~2.4"`) caps that exposure to 2.4 patch releases; this testset is the
# canary — if an upgrade moves the ground, it fails HERE, loud and naming the
# missing symbol, instead of deep inside request handling.
#
# NOTE: this guards rename/removal of internals Nitro USES. It cannot detect HTTP
# ADDING a new special-cased property to its own getproperty — if that happens,
# `_install_request_getproperty!` must be updated to mirror it (Nitro's override
# replaces HTTP's method process-wide, so any case it omits silently falls
# through to `getfield`).

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
    # through the router. `Types.pathparams` must pass that through untouched: `req.input`
    # and `merge_request_input!` branch on it, and decoding blindly over it throws.
    @test HTTP.getparams(HTTP.Request("GET", "/x")) === nothing
    @test Nitro.Types.pathparams(HTTP.Request("GET", "/x")) === nothing
    @test HTTP.Request("GET", "/x").params === nothing
end

@testset "body type hierarchy still present" begin
    @test isdefined(HTTP, :EmptyBody)
    @test isdefined(HTTP, :BytesBody)
    @test :data in fieldnames(HTTP.BytesBody)
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

@testset "`reuseaddr` is a Server knob (src/core.jl `preprocesskwargs`)" begin
    # Nitro injects `reuseaddr=false` on Windows, where SO_REUSEADDR lets a second process
    # bind a port another is actively listening on. It travels as a `listen!` kwarg and has
    # to land on this field, which `test/server_lifecycle_tests.jl` asserts against.
    @test :reuseaddr in fieldnames(HTTP.Server)
    @test fieldtype(HTTP.Server, :reuseaddr) === Bool
end

@testset "peer-IP field chain still present (src/core.jl `_peer_ip`/`_conn_fd`)" begin
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

@testset "override stays a faithful superset of HTTP's getproperty" begin
    req = HTTP.Request("GET", "/")
    # `:version` must match HTTP's own derivation from the proto fields …
    @test req.version == VersionNumber(Int(getfield(req, :proto_major)), Int(getfield(req, :proto_minor)))
    @test req.version isa VersionNumber
    # … `:context` must stay dict-like (core.jl does `Base.get(req.context, :session, nothing)`) …
    @test Base.get(req.context, :__contract_probe__, :sentinel) === :sentinel
    # … and an unknown symbol must still fall through to the real field.
    @test req.method == "GET"
end

end
