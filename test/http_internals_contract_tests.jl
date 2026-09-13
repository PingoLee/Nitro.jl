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
# (`HTTP = "~2.6"`) caps that exposure to 2.6 patch releases; this testset is the
# canary — if an upgrade moves the ground, it fails HERE, loud and naming the
# missing symbol, instead of deep inside request handling.
#
# This guards rename/removal of internals Nitro USES. It ALSO covers HTTP ADDING a
# new special-cased property to its own getproperty (#32) — see the testsets at the
# bottom, which diff the two symbol sets out of source rather than trusting a
# hand-kept list. That matters because Nitro's override REPLACES HTTP's method
# process-wide, so any case it omits silently falls through to `getfield` — for
# every `HTTP.Request` in the session, including ones belonging to other packages.
#
# Precisely what that coverage is, since a canary that overstates itself is the
# problem it was meant to solve: additions written as `field === :sym` or
# `field == :sym` (either operand order) are EXTRACTED and diffed. Any other
# spelling — `field in (:a, :b)`, a Dict lookup, a helper call — is not silently
# half-read; it is reported as an unrecognized form and fails, asking for a human.

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

# ── #32: the symbol-set diff ───────────────────────────────────────────────────
# Helpers live at test-item top level (not inside a `@testset`) so the self-test
# below and the real check can share them.

"""
Find a `Base.getproperty(x::<…>Request, y::Symbol)` definition anywhere in `ex`
(including inside a macro call such as Nitro's `@eval Core function …`).
Returns `(second_argument_name, body)`, or `nothing`.
"""
function _cn_find_getproperty(ex)
    found = Ref{Any}(nothing)
    function walk(e)
        found[] === nothing || return
        e isa Expr || return
        if (e.head === :function || e.head === :(=)) && length(e.args) >= 2
            sig = e.args[1]
            if sig isa Expr && sig.head === :call && length(sig.args) == 3
                f = sig.args[1]
                is_gp = f === :getproperty ||
                        (f isa Expr && f.head === :. && f.args[2] === QuoteNode(:getproperty))
                if is_gp
                    a1, a2 = sig.args[2], sig.args[3]
                    if a1 isa Expr && a1.head === :(::) && a2 isa Expr && a2.head === :(::) &&
                       a2.args[2] === :Symbol
                        t = a1.args[2]
                        tname = t isa Symbol ? String(t) :
                                (t isa Expr && t.head === :. && t.args[2] isa QuoteNode ?
                                     String(t.args[2].value) : "")
                        if tname == "Request"   # exact: `Request` and `HTTP.Request` both normalize here
                            found[] = (a2.args[1], e.args[2])
                            return
                        end
                    end
                end
            end
        end
        for a in e.args
            walk(a)
        end
    end
    walk(ex)
    return found[]
end

# A node is a "recognized guard" if it is `argname <op> :sym` (or the reverse) for
# `op ∈ (===, ==)`. Returns the Symbol, or `nothing`.
function _cn_guard_symbol(argname::Symbol, e)
    (e isa Expr && e.head === :call && length(e.args) == 3) || return nothing
    e.args[1] === :(===) || e.args[1] === :(==) || return nothing
    a, b = e.args[2], e.args[3]
    a === argname && b isa QuoteNode && b.value isa Symbol && return b.value
    b === argname && a isa QuoteNode && a.value isa Symbol && return a.value   # reversed operands
    return nothing
end

# The legitimate non-guard use: the `getfield(x, argname)` fallthrough.
function _cn_is_fallthrough(argname::Symbol, e)
    return e isa Expr && e.head === :call && length(e.args) == 3 &&
           e.args[1] === :getfield && e.args[3] === argname
end

"Every symbol `body` compares `argname` against, in a form this canary understands."
function _cn_cased_symbols(argname::Symbol, body)
    out = Set{Symbol}()
    function walk(e)
        e isa Expr || return
        sym = _cn_guard_symbol(argname, e)
        sym === nothing || push!(out, sym)
        for a in e.args
            walk(a)
        end
    end
    walk(body)
    return out
end

"""
Sub-expressions of `body` that reference `argname` in a form `_cn_cased_symbols` does NOT
understand — anything other than a recognized guard or the `getfield` fallthrough.

This is what keeps the canary from degrading silently. Extracting symbols by pattern means
an unrecognized spelling (`field in (:a, :b)`, a `Dict` lookup, a helper call) yields a
PARTIAL set, and a partial set makes `setdiff(http, nitro)` empty for exactly the property
that was added — green, and wrong. Rather than widen forever, assert that HTTP's method is
shaped the way this canary can read; an unfamiliar shape fails loudly and asks for a human.
"""
function _cn_unrecognized_uses(argname::Symbol, body)
    out = Any[]
    function walk(e)
        e isa Expr || return
        if _cn_guard_symbol(argname, e) !== nothing || _cn_is_fallthrough(argname, e)
            return   # consumed; do not descend into a recognized form
        end
        # A node that names `argname` directly, in some other shape.
        if any(a -> a === argname, e.args)
            push!(out, e)
            return
        end
        for a in e.args
            walk(a)
        end
    end
    walk(body)
    return out
end

"The set of Symbols the `getproperty` in `src` special-cases, or `nothing` if it defines none."
function _cn_symbols_in_source(src::AbstractString)
    got = _cn_find_getproperty(Meta.parseall(src))
    got === nothing && return nothing
    return _cn_cased_symbols(got[1], got[2])
end

_cn_symbols_in_file(path) = _cn_symbols_in_source(read(path, String))

"Unrecognized `argname` uses in the `getproperty` defined by `src`, or `nothing` if none defined."
function _cn_unrecognized_in_source(src::AbstractString)
    got = _cn_find_getproperty(Meta.parseall(src))
    got === nothing && return nothing
    return _cn_unrecognized_uses(got[1], got[2])
end

_cn_unrecognized_in_file(path) = _cn_unrecognized_in_source(read(path, String))

"Every file under HTTP's source tree that defines a `getproperty(::Request, ::Symbol)`."
function _cn_http_getproperty_files()
    root = dirname(pathof(HTTP))
    hits = String[]
    for (dir, _, files) in walkdir(root), f in files
        endswith(f, ".jl") || continue
        path = joinpath(dir, f)
        _cn_symbols_in_file(path) === nothing || push!(hits, path)
    end
    return hits
end

const _CN_NITRO_CORE = joinpath(pkgdir(Nitro), "src", "core.jl")

@testset "the symbol-set detector itself works" begin
    # A canary that cannot fail is worse than no canary. Prove the extractor on
    # synthetic sources FIRST, so a silently-broken parser cannot make the real
    # assertion below pass vacuously.
    http_like = """
        function Base.getproperty(request::Request, field::Symbol)
            field === :context && return _meta(getfield(request, :context))
            field === :version && return VersionNumber(1, 1)
            return getfield(request, field)
        end
        """
    @test _cn_symbols_in_source(http_like) == Set([:context, :version])

    # The shape Nitro uses: nested inside a macro call, with an `||` branch.
    nitro_like = """
        function _install!()
            @eval Core function Base.getproperty(req::HTTP.Request, sym::Symbol)
                if sym === :params
                    return 1
                elseif sym === :input || sym === :data
                    return 2
                elseif sym === :context
                    return 3
                else
                    return getfield(req, sym)
                end
            end
        end
        """
    @test _cn_symbols_in_source(nitro_like) == Set([:params, :input, :data, :context])

    # THE case this issue is about: HTTP gains a property Nitro does not mirror.
    http_grown = replace(http_like,
        "field === :version" => "field === :newly_derived && return 0\n    field === :version")
    grown = _cn_symbols_in_source(http_grown)
    # Isolate the growth. Diffing against `nitro_like` would pass with or without it --
    # `nitro_like` never handles `:version`, so that setdiff is non-empty either way.
    @test setdiff(grown, _cn_symbols_in_source(http_like)) == Set([:newly_derived])

    # The other half of F1: a spelling the extractor does NOT understand must be reported
    # as unrecognized rather than yielding a quietly-partial symbol set.
    http_odd = """
        function Base.getproperty(request::Request, field::Symbol)
            field in (:context, :trailers) && return _meta(request)
            return getfield(request, field)
        end
        """
    @test isempty(_cn_symbols_in_source(http_odd))               # nothing extracted...
    @test !isempty(_cn_unrecognized_in_source(http_odd))         # ...and that is flagged

    # Both widened guard spellings are understood, including reversed operands.
    @test _cn_symbols_in_source("""
        function Base.getproperty(r::Request, f::Symbol)
            f == :a && return 1
            :b === f && return 2
            return getfield(r, f)
        end
        """) == Set([:a, :b])

    # The forms that ARE understood leave no residue.
    @test isempty(_cn_unrecognized_in_source(http_like))
    @test isempty(_cn_unrecognized_in_source(nitro_like))

    # A file with no such definition reports `nothing`, not an empty set — the two
    # mean different things, and only `nothing` should be treated as "not found".
    @test _cn_symbols_in_source("f(x) = x + 1") === nothing
end

@testset "no HTTP-special-cased property is missing from Nitro's override" begin
    # `_install_request_getproperty!` REPLACES HTTP's method (same signature), so this
    # must stay a strict superset. Both sides are read out of source: HTTP's own method
    # is no longer reachable through the method table once Nitro has loaded.
    # The premise: Nitro's override has REPLACED HTTP's method. A bare count of 1 would also
    # hold if the install never ran and HTTP's own method were the only one -- in which case
    # everything below would still pass while the piracy was not installed at all.
    gp_methods = methods(Base.getproperty, (HTTP.Request, Symbol))
    @test length(gp_methods) == 1
    @test only(gp_methods).module === Nitro.Core

    http_files = _cn_http_getproperty_files()
    # Exactly one definition site. Zero means HTTP restructured and this canary has gone
    # blind; more than one means the superset question has more than one answer.
    @test length(http_files) == 1
    # `if`, NOT `|| return`: a bare `return` inside a `@testset` returns from the enclosing
    # FUNCTION -- the whole `@testitem` body -- so every later testset in this file would be
    # silently skipped rather than just this tail. Still red either way, but a skipped
    # testset is invisible in the summary.
    if length(http_files) == 1

    # HTTP's method must be written in a shape this canary can read -- see
    # `_cn_unrecognized_uses`. If it is not, the extracted set is partial and the subset
    # assertion below would pass for exactly the property that was added.
    unrecognized = _cn_unrecognized_in_file(only(http_files))
    @test isempty(unrecognized)
    isempty(unrecognized) || @error """
        HTTP.jl's `getproperty(::Request, ::Symbol)` now uses a form this canary cannot read:
        $(unrecognized)
        The symbol set it extracts is therefore PARTIAL, and the subset check below would pass
        even if Nitro's override were missing a case. Teach `_cn_guard_symbol` the new form (or
        widen `_cn_is_fallthrough`), then re-check `_install_request_getproperty!` by hand.
        """

    http_syms = _cn_symbols_in_file(only(http_files))
    nitro_syms = _cn_symbols_in_file(_CN_NITRO_CORE)

    # The same residue check on NITRO's side, and the direction is why it matters: a
    # partial `nitro_syms` only ever makes the setdiff redder (safe), but an OVER-collected
    # one -- a future `_install_request_getproperty!` refactor introducing a comprehension
    # or closure binding also named `sym` -- grows the set and can mask exactly the HTTP
    # addition this canary hunts. `src/core.jl` is the file that actually gets edited.
    @test isempty(_cn_unrecognized_in_file(_CN_NITRO_CORE))

    # Neither side may come back empty: that is what a broken parser looks like, and it
    # would make the subset assertion below vacuously true.
    @test !isnothing(http_syms) && !isempty(http_syms)
    @test !isnothing(nitro_syms) && !isempty(nitro_syms)

    missing_cases = sort!(collect(setdiff(http_syms, nitro_syms)))
    @test isempty(missing_cases)
    isempty(missing_cases) || @error """
        HTTP.jl special-cases $(missing_cases) in its own `getproperty(::Request, ::Symbol)`,
        and Nitro's override does not mirror them. Because that override REPLACES HTTP's
        method for the whole process, those properties now fall through to `getfield` for
        every HTTP.Request in the session. Add the branch(es) to
        `_install_request_getproperty!` in src/core.jl.
        """

    # Sanity-check the extraction against what the override is documented to add, so a
    # parser that returned a plausible-but-wrong set does not pass quietly.
    @test issubset(Set([:context, :version]), http_syms)
    @test issubset(Set([:params, :query, :json, :form, :input, :data, :files, :post,
                        :session, :user, :ip]), nitro_syms)
    end
end

@testset "the detector works against HTTP's REAL source, not just synthetic ones" begin
    # The self-test above proves the extractor on sources this file wrote. This proves it on
    # the source that actually ships, by growing HTTP's own method two ways and checking each
    # is caught. Without this, a shape difference between the synthetic fixtures and the real
    # file would leave the canary passing on fixtures and blind in production.
    http_files = _cn_http_getproperty_files()
    @test length(http_files) == 1
    orig = read(only(http_files), String)   # read-only; nothing is written back to the depot

    @test sort(collect(_cn_symbols_in_source(orig))) == [:context, :version]
    @test isempty(_cn_unrecognized_in_source(orig))

    # The mutations are anchored on a literal from HTTP's current formatting. If HTTP
    # reformats, `replace` becomes a no-op and BOTH mutation tests would pass vacuously --
    # so assert the anchor bit first. A failure here means re-anchor, not a real regression.
    # `:context`, not `:version`: the `field === :version &&` line appears TWICE in
    # http_core.jl -- once for Request and once for Response -- so `replace(…; count=1)`
    # would hit Request only by textual luck. Assert uniqueness so a reformat of Request's
    # method cannot leave the mutation silently landing on Response's.
    anchor = "    field === :context &&"
    @test count(anchor, orig) == 1

    # (a) HTTP grows a property using the `==` spelling: must be EXTRACTED, so the
    #     subset check downstream reports it as missing from Nitro's override.
    grown_eq = replace(orig, anchor => "    field == :trailers && return 0
" * anchor; count=1)
    @test grown_eq != orig                                    # the anchor actually bit
    @test :trailers in _cn_symbols_in_source(grown_eq)

    # (b) HTTP grows a property in a form this canary cannot read: must be FLAGGED as
    #     unrecognized, rather than silently yielding a partial set that still passes.
    grown_odd = replace(orig, anchor => "    field in (:trailers, :raw) && return 0
" * anchor; count=1)
    @test grown_odd != orig
    @test !isempty(_cn_unrecognized_in_source(grown_odd))
end

end
