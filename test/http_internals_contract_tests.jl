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

@testset "body type hierarchy still present" begin
    @test isdefined(HTTP, :EmptyBody)
    @test isdefined(HTTP, :BytesBody)
    @test :data in fieldnames(HTTP.BytesBody)
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
