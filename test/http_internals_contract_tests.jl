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
#   • src/utilities/bodyparsers.jl — the `EmptyBody` / `BytesBody` body hierarchy, and
#       `parse_multipart_body`, which `multipart` calls with a boundary it parsed itself (#345).
#   • src/core/pipeline.jl — `_allowed_methods` walks the router's route tree to build a 405's
#       `Allow` header (#281): `Router.routes`, the `Node`/`Leaf`/`Variable` fields, `match`,
#       `_route_variable_matches` and `_router_request_path`.
#   • src/types.jl — `NitroRouter` (#625) names the concrete router type as
#       `Router{typeof(_404), typeof(_405), typeof(middleware)}`, which depends on `Router{T,S,F}`'s
#       parameter order matching its positional constructor `Router(_404, _405, middleware)`.
#   • src/routerhof.jl — `_gethandler` resolves an exact route without upstream's `split` and
#       `Params()` (#445): `Node.exact`, `Node.segment`, `Params`, and `match` on an exhausted
#       segment list.
#   • src/core/transport.jl — `_upgrade_websocket!` (#374) runs the private
#       `WebSockets._origin_allowed_default` with a proxy-reported scheme, mirrors `upgrade`'s
#       `stream.tracked.conn isa TLS.Conn`, and classifies a refused handshake by
#       `WebSocketError.message.code`. `_write_fixed_body!` (#377, #529) streams a known-length
#       body through the public `startwrite` + `write`, and reads two `Stream` state fields.
#       `_mark_reported!` writes `stream.io_error`, the field HTTP 2.11's stream loop reads to
#       decide whether to log an error itself (JuliaWeb/HTTP.jl#1425).
#   • src/core/lifecycle.jl — refuses cleartext HTTP/2 (#375) with `listen!`'s `allow_h2c = false`.
#       Public since HTTP.jl 2.9, so no longer an internal; pinned anyway because it is the whole
#       of the refusal (it replaced an override of the private `_probe_h2_preface!`).
#   • src/response.jl — `Res._new_response` (#446) builds every `Res` and `format_response`
#       response through `HTTP.Response`'s positional FIELD constructor, skipping the keyword
#       form's header normalize-and-copy. It depends on the field order and on storing what
#       the keyword form stores for a `String`/`Vector{UInt8}` body. `_rebuild_with_headers`
#       in src/utilities/misc.jl (#447) uses the same constructor for every header-adding
#       middleware layer, carrying each field over by position.
#   • src/context.jl — `_shutdown_server`'s bounded drain: it depends on `close(::Server)`
#       releasing the listener BEFORE its unbounded quiesce loop, and escalates to
#       `HTTP.forceclose`.
#
# None of these are part of HTTP's public, SemVer-guaranteed API, so a 2.x bump
# can rename or remove them WITHOUT a breaking-version signal. The compat pin
# (`HTTP = "~2.11"`) caps that exposure to 2.11 patch releases; this testset is the
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
    # `multipart` reads the boundary itself and hands the body to `parse_multipart_body` (#345):
    # the public `parse_multipart_form` matches one exact spelling of the Content-Type. Pinned by
    # signature, since Nitro calls it with a byte vector and a `String` boundary.
    @test hasmethod(HTTP.parse_multipart_body, Tuple{Vector{UInt8}, String})
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

@testset "`NitroRouter` is still the type `Router(_404, _405, nothing)` builds (#625)" begin
    T = Nitro.Types
    @test HTTP.Router(T._nitro_404, T._nitro_405, nothing) isa T.NitroRouter
    @test isconcretetype(T.NitroRouter)
    @test T.nitro_router().middleware === nothing
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

@testset "what `_gethandler`'s exact walk reads is still shaped the same (#445)" begin
    H = HTTP.Handlers
    # `src/routerhof.jl` `_exact_leaf`: walks `Node.exact` comparing `Node.segment`, then asks
    # `match` with an exhausted segment list for the end node's leaf.
    @test fieldtype(H.Node, :exact) === Vector{H.Node}
    @test fieldtype(H.Node, :segment) === Union{String, H.Variable}
    @test H.Params === Dict{String, String}
    r = HTTP.Router()
    h = req -> HTTP.Response(200)
    HTTP.register!(r, "GET", "/a/b", h)
    HTTP.register!(r, "*",   "/c", h)
    child(node, s) = only(filter(n -> n.segment == s, node.exact))
    a = child(r.routes, "a")
    b = child(a, "b")
    none = SubString{String}[]
    leaf = H.match(b, "GET", none, 1)
    @test leaf isa H.Leaf && leaf.handler === h && leaf.path == "/a/b" && isempty(leaf.variables)
    @test H.match(b, "POST", none, 1) === missing            # a method mismatch, not a miss
    @test H.match(a, "GET", none, 1) === nothing             # no leaf at all
    @test H.match(child(r.routes, "c"), "PATCH", none, 1) isa H.Leaf   # a "*" leaf takes any method
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

@testset "Res._new_response matches HTTP's keyword constructor field for field (#446)" begin
    # The field constructor is positional, so a reordered, added or retyped field would either
    # fail to construct or -- worse -- land a value in the wrong slot. Pin the layout exactly.
    @test fieldnames(HTTP.Response) == (:status, :reason, :headers, :trailers, :body,
        :content_length, :proto_major, :proto_minor, :close, :request, :request_url,
        :previous, :redirect_count)
    @test fieldtypes(HTTP.Response{String})[[1, 2, 3, 4, 6, 7, 8, 9, 13]] ==
        (Int, String, HTTP.Headers, HTTP.Headers, Int64, UInt8, UInt8, Bool, Int)

    # The keyword form is the oracle: whatever HTTP stores for these bodies, the helper must too.
    # A field HTTP starts defaulting differently (say, `content_length` for a String) fails here.
    for body in ("héllo", Vector{UInt8}("bytes"), "")
        h = HTTP.Headers(1)
        push!(h, "Content-Type" => "text/plain")
        ours = Nitro.Core.Res._new_response(201, h, body)
        theirs = HTTP.Response(201; headers = copy(h), body = body)
        @test typeof(ours) == typeof(theirs)
        for f in fieldnames(HTTP.Response)
            a, b = getfield(ours, f), getfield(theirs, f)
            if a isa HTTP.Headers
                @test a.entries == b.entries
            else
                @test isequal(a, b)
            end
        end
        # The response owns its trailers: never a collection shared with anything else.
        @test ours.trailers !== Nitro.Core.Res._new_response(201, HTTP.Headers(), body).trailers
    end
    @test_throws ArgumentError Nitro.Core.Res._new_response(-1, HTTP.Headers(), "")
end

@testset "a header name is stored, and so sent, as spelled (HTTP 2.8)" begin
    # 2.0 through 2.7 rewrote every name into `Content-Type` form on insertion, so the rate
    # limiter's `setheader(resp, "X-RateLimit-Limit" => …)` (src/middleware/rate_limiter.jl) went
    # out as `X-Ratelimit-Limit`. HTTP.jl #1377 (2.8.0) stores the name as given and HTTP/1
    # serializes it that way, which is the wire change the ~2.8 upgrade entry documents. Nitro
    # never depended on either spelling -- every header walk in src/ compares case-insensitively --
    # so this pins the observable half: a release that re-canonicalized would fail here instead of
    # silently changing what clients receive.
    resp = HTTP.Response(200)
    HTTP.setheader(resp, "X-RateLimit-Limit" => "10")
    @test first(only(resp.headers)) == "X-RateLimit-Limit"
    # Lookup stays case-insensitive in every spelling (as it was before 2.8 for any name that went
    # through HTTP's insertion API, which canonicalized it).
    @test HTTP.header(resp, "x-ratelimit-limit") == "10"
    @test HTTP.header(resp, "X-RATELIMIT-LIMIT") == "10"
    # A second set in another spelling replaces the entry rather than adding a twin -- and the
    # LATEST writer's spelling wins. That is load-bearing: `Res` applies caller headers through
    # `setheader`, so a caller's `"content-type"` rewrites Nitro's `Content-Type` on the wire.
    HTTP.setheader(resp, "x-ratelimit-limit" => "20")
    @test length(resp.headers) == 1 && HTTP.header(resp, "X-RateLimit-Limit") == "20"
    @test first(only(resp.headers)) == "x-ratelimit-limit"
end

@testset "reading BytesBody.data does not spend the body (HTTP 2.7 pre-send check)" begin
    # HTTP 2.7.0 (#1364) added `_check_response_body_unsent`, called from `write_response!`
    # before the response head goes out. It answers **500** for a `BytesBody`/`CallbackBody`
    # already sent or closed. Nitro's whole non-consuming write path
    # (`src/core/transport.jl::_write_response_body!`) depends on `BytesBody.data` being
    # readable without tripping that check, because a shared `BytesBody` response — every
    # `HTTP.servecontent` response behind `staticfiles` and `Res.file` is one — hands the SAME
    # object to the writer repeatedly.
    #
    # Since HTTP 2.8.0 the `BytesBody` docstring documents this: `data` is "the public `data`
    # field", which a read-only consumer "may borrow … without advancing the cursor". (Before
    # 2.8, #1364 said only that it "isn't explicitly restricted".) But `BytesBody` is not
    # declared `public`, so a docstring is all the guarantee there is — pin the mechanism rather
    # than trusting the prose.
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
    # `servecontent` writes the name as `ETag`, and since HTTP 2.8 that is what every static, SPA
    # and `Res.file` response sends (2.7 canonicalized it to `Etag`). Pinned by raw name, since the
    # lookup above cannot tell the two apart.
    @test "ETag" in first.(collect(plain.headers))

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

@testset "swallow-deadline surface (src/core/transport.jl `_bound_swallow!`)" begin
    # #298: before swallowing a refused request's body, `_bound_swallow!` arms a read deadline on
    # the connection through this internal setter, and reads these fields to reach it and to skip
    # HTTP/2. A rename would not fail loudly: the setter's `try` tolerates a failure, so the
    # swallow would quietly lose its time bound. (This section used to pin the header-deadline
    # clear too, `_clear_header_deadline!` (#316), which HTTP.jl 2.9 made unnecessary: JuliaWeb/HTTP.jl#1382.)
    @test :h2_conn in fieldnames(HTTP.Stream)
    @test :tracked in fieldnames(HTTP.Stream)
    # `tracked.conn` is read directly by `_bound_swallow!` and by the WebSocket TLS check. It used
    # to be pinned by the peer-IP field-chain canary, which #410 retired along with the walk.
    @test isdefined(HTTP, :_ServerConn)
    @test :conn in fieldnames(HTTP._ServerConn)
    @test isdefined(HTTP, :_set_read_deadline!)
    @test hasmethod(HTTP._set_read_deadline!, Tuple{HTTP.TCP.Conn, Int64})
    @test hasmethod(HTTP._set_read_deadline!, Tuple{HTTP.TLS.Conn, Int64})
end

@testset "h2c refusal surface (src/core/lifecycle.jl `preprocesskwargs`, `allow_h2c`)" begin
    # #375: Nitro keeps HTTP/2 off its plaintext listeners with HTTP.jl's `allow_h2c = false`
    # (HTTP.jl #1388, 2.9). Before 2.9 there was no switch and Nitro overrode the private preface
    # probe. This is documented API now, but it is also the whole of the refusal, so a release
    # that dropped the keyword from `listen!` (a `MethodError` at every `serve`, loud) or stopped
    # storing it on the `Server` (quiet) is pinned here; test/h2c_tests.jl is the behavioral net.
    # The method `serve` calls: `HTTP.listen!(listener, host, port; kwargs...)`. The others are
    # forwarding wrappers that take `kwargs...`.
    @test hasmethod(HTTP.listen!, Tuple{Function, String, Int}, (:allow_h2c,))
    @test fieldtype(HTTP.Server, :allow_h2c) === Bool
end

@testset "streamed FIXED body (src/core/transport.jl `_write_fixed_body!`)" begin
    # #377 wrote a known-length streaming body through three HTTP.jl internals, because HTTP/1.1
    # buffered a FIXED stream response whole until `closewrite`. HTTP.jl 2.9 streams it after an
    # explicit `startwrite` (JuliaWeb/HTTP.jl#1389), so #529 moved onto that: `startwrite` and
    # `write` are public, and pinned here only for that. What no signature can pin is the BEHAVIOR —
    # that `startwrite` makes a FIXED body past 4 KiB go out as it is written; that is
    # test/streaming_write_tests.jl's job, the only check that sees WHEN bytes reach the wire.
    @test Base.ispublic(HTTP, :startwrite)
    # Still read directly, by `_holds_fixed_head`. `ignore_writes` marks a bodyless response (HEAD,
    # 1xx, 204, 304); `head_committed` still false after `startwrite` is how Nitro tells HTTP chose FIXED
    # framing and is holding the head. It is also logged when a body fails, and is what makes HTTP's
    # error path close the connection after the head instead of appending a raw 500.
    # `response_started` is read by `_response_started` in src/core/transport.jl.
    @test fieldtype(HTTP.Stream, :ignore_writes) === Bool
    for f in (:head_committed, :response_started)
        @test fieldtype(HTTP.Stream, f) === Bool
    end
end

@testset "Nitro's bodyless-status rule is HTTP's (src/core/transport.jl `_status_allows_body`, #671)" begin
    # `stream_handler` must skip the drain for exactly the responses whose writes HTTP's
    # `startwrite` discards (`ignore_writes`): drain one of those and an open-ended body pins the
    # request, connection and producer tasks (#160). Nitro cannot read `ignore_writes` at the point
    # it decides — `startwrite` has not run, and running it early would change framing on every
    # response — so it restates HTTP's rule. This holds the restatement to the original: if a `~`
    # bump ever widens HTTP's set, a bodyless status would be drained again with nothing failing,
    # and this is what fails instead. The method half (`HEAD`) is test/sse_tests.jl's to cover.
    @test isdefined(HTTP, :_body_allowed_for_status)
    # Past 100..599 too: `Res.sse(; status::Int)` takes any `Int`, and both rules answer there.
    @test all(s -> Nitro.Core._status_allows_body(s) == HTTP._body_allowed_for_status(s), 0:999)
end

@testset "reported-error surface (src/core/transport.jl `_mark_reported!`)" begin
    # Nitro WRITES `stream.io_error` for an error it has already logged, so HTTP.jl 2.11's stream loop
    # neither logs it again -- with the live exception and the query string -- nor overrides its status
    # (JuliaWeb/HTTP.jl#1425). `Any`, because Nitro stores whatever it caught. The behavior HTTP keys
    # on it is pinned on a live listener in the last item of this file.
    @test fieldtype(HTTP.Stream, :io_error) === Any
end

@testset "WebSocket Origin policy surface (src/core/transport.jl `_upgrade_websocket!`)" begin
    # #374: Nitro passes `upgrade` a `check_origin` that runs HTTP's own same-origin rule with the
    # scheme a trusted proxy reported, instead of the transport's. It calls the PRIVATE default
    # rule (through `_http_origin_allowed_default`), reads `stream.tracked.conn isa TLS.Conn` as
    # HTTP does, and recognizes a refused handshake by `WebSocketError`'s close code. A rename
    # here would 500 every upgrade; a change in the rule's meaning would silently re-open or
    # re-close the #374 case — which is what the truth table pins.
    WS = HTTP.WebSockets
    @test isdefined(WS, :_origin_allowed_default)
    @test hasmethod(WS._origin_allowed_default, Tuple{HTTP.Request, Bool})
    @test :check_origin in Base.kwarg_decl(only(methods(WS.upgrade, Tuple{Function, HTTP.Stream})))
    @test fieldnames(WS.WebSocketError) == (:message,)
    @test fieldtype(WS.WebSocketError, :message) === WS.CloseFrameBody
    @test :code in fieldnames(WS.CloseFrameBody)
    @test isdefined(HTTP.TLS, :Conn)

    req(origin) = HTTP.Request("GET", "/ws",
        origin === nothing ? ["Host" => "app.example.com"] :
                             ["Host" => "app.example.com", "Origin" => origin])
    allowed(origin, secure) = Nitro.Core._http_origin_allowed_default(req(origin), secure)
    @test allowed("https://app.example.com", true)        # behind TLS, told the scheme: allowed
    @test !allowed("https://app.example.com", false)      # the #374 refusal itself
    @test allowed("http://app.example.com", false)
    @test !allowed("http://app.example.com", true)        # scheme still matters once known
    @test !allowed("https://evil.example", true)          # cross-site: never
    @test !allowed("https://app.example.com:8443", true)  # port is part of the origin
    @test allowed(nothing, false)                         # no Origin: not a browser, allowed
    @test !allowed("null", true)
end

@testset "a refused handshake is told apart from a session error (#374)" begin
    WS = HTTP.WebSockets
    err(code) = WS.WebSocketError(WS.CloseFrameBody(code, ""))
    status = Nitro.Core._ws_refusal_status
    @test status(err(1002), false, true)  == 403    # our Origin check refused
    @test status(err(1002), false, false) == 400    # HTTP refused a malformed handshake
    @test status(err(1002), true, false)  === nothing  # a peer protocol error mid-session
    @test status(err(1011), false, false) === nothing  # e.g. an upgrade attempted over HTTP/2
    @test status(ErrorException("x"), false, true) === nothing
    @test status(InterruptException(), false, true) === nothing
end

@testset "the peer IP comes from HTTP's public `peeraddr` (#410)" begin
    # `_peer_ip` used to walk the private `stream.tracked.conn.{fd,tcp.fd}.raddr` chain, and
    # this testset canaried every link of it. Since #410 it calls `HTTP.peeraddr`, HTTP's
    # supported API for the client address (TCP and TLS, HTTP/1 and HTTP/2). The canary is now
    # that the API is still there AND still declared public — a future HTTP dropping either
    # fails HERE, by name, instead of sending every client down `_peer_ip`'s fallback.
    @test isdefined(HTTP, :peeraddr)
    @test Base.ispublic(HTTP, :peeraddr)
    @test hasmethod(HTTP.peeraddr, Tuple{HTTP.Stream})
end

@testset "disconnect probe surface (src/core/transport.jl `_peer_gone`, #466)" begin
    # `cancel_reason(req)` asks the kernel whether the client left, through Reseau internals that
    # no HTTP.jl release covers: hence the direct `Reseau = "~1.6"` pin. A rename here would not
    # fail loudly at every request, only when a handler polls, so each link is pinned by name.
    # test/request_cancellation_tests.jl is the behavioral net (FIN, RST, still connected).
    R = Nitro.Core.Reseau
    @test HTTP.TCP === R.TCP                      # the Reseau HTTP's conns come from is the one pinned
    @test fieldtype(HTTP.Stream, :write_closed) === Bool
    @test R.TCP.Conn <: fieldtype(HTTP._ServerConn, :conn)
    fd = fieldtype(R.TCP.Conn, :fd)
    @test fieldtype(fd, :pfd) === R.IOPoll.FD
    @test hasmethod(R.IOPoll._with_fd_ref, Tuple{Function, R.IOPoll.FD})
    @test R.IOPoll.NetClosingError <: Exception
    @test R.SocketOps.MSG_PEEK isa Cint
    @test hasmethod(R.SocketOps.recv_from!,
                    Tuple{fieldtype(R.IOPoll.FD, :sysfd), Ptr{UInt8}, Csize_t, Cint})
    @test hasmethod(R.SocketOps.last_error, Tuple{})
end

# Stand-ins for what `HTTP.peeraddr` returns — Reseau's `SocketAddrV4`/`SocketAddrV6`, whose
# `ip` field is an octet tuple. Defined at test-item top level because `struct` is illegal
# inside a `@testset` local scope.
struct _FakeAddr4;   ip::NTuple{4, UInt8};  port::UInt16; end
struct _FakeAddr6;   ip::NTuple{16, UInt8}; port::UInt16; end
struct _FakeAddrOdd; ip::String;            port::UInt16; end

@testset "_peer_ip converts what peeraddr returns, and survives what it cannot" begin
    peer(lookup) = Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
        Nitro.Core._peer_ip(lookup, :stream)
    end
    mapped = (0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00, 0xff,0xff, 203,0,113,7)
    real6  = (0x20,0x01, 0x0d,0xb8, 0,0,0,0, 0,0,0,0, 0,0,0,0x01)

    @test peer(_ -> _FakeAddr4((203, 0, 113, 7), 0x1234)) === Sockets.IPv4("203.0.113.7")
    # `peeraddr` keeps a dual-stack listener's `::ffff:` form; `_ipaddr_from_bytes` still
    # demotes it, so #66's one-spelling-per-host holds through the new source.
    @test peer(_ -> _FakeAddr6(mapped, 0x1234)) === Sockets.IPv4("203.0.113.7")
    @test peer(_ -> _FakeAddr6(UInt8.(real6), 0x1234)) === Sockets.IPv6("2001:db8::1")

    # The three ways to come back without an address must never fail the request — and must
    # FAIL CLOSED (#404). The fallback was loopback, which `trusted_proxies = [ip"127.0.0.1"]`
    # trusts; the unspecified address is something no connection has and no policy trusts.
    fallback = Nitro.Core._UNKNOWN_PEER
    @test fallback === Sockets.IPv4("0.0.0.0")
    @test peer(_ -> nothing) === fallback                         # no live connection
    @test peer(_ -> throw(ArgumentError("client stream"))) === fallback  # API changed under us
    @test peer(_ -> _FakeAddrOdd("x", 0x1234)) === fallback        # an address shape we don't know
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
    # type are load-bearing for Nitro, and `HTTP = "~2.11"` is a deliberately tight pin, so they are
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

@testitem "A served request's peer is the real socket peer (#410)" tags=[:core, :network] setup=[NitroCommon] begin
    using Test
    using HTTP
    using Nitro
    import Sockets

    # The unit tests above drive `_peer_ip` through a stand-in lookup. This one goes through a
    # real socket, so it pins that `HTTP.peeraddr` actually yields an address on a stream
    # `serve` hands Nitro — the case where its `nothing` would send every client down the
    # fallback without any unit test noticing.
    app = App(mod = @__MODULE__)
    urlpatterns(app, "",
        path("/peer", req -> begin
            addr = HTTP.peeraddr(req.context[:stream])
            string(addr === nothing ? "none" : "some", " ", getpeerip(req))
        end),
    )
    port = get_free_port()
    serve(app; host = HOST, port = port, async = true, show_errors = false, show_banner = false)
    try
        r = HTTP.get("http://$HOST:$port/peer")
        @test r.status == 200
        @test String(r.body) == "some 127.0.0.1"
    finally
        terminate(app)
    end
end

@testitem "The rebuilt request owns its headers and adopts its trailers (#533)" tags=[:core, :network] setup=[NitroCommon] begin
using Test
import HTTP
import Nitro
import Sockets

# `_http_stream_request` rebuilds the head HTTP.jl parsed into the `Request` the pipeline sees.
# The HEADERS must be a separate vector: HTTP.jl reads the head after the pipeline has run (the
# WebSocket handshake's Origin check among others), so a middleware rewriting `req`'s headers in
# place must not reach it (#374). The TRAILERS are adopted: nothing reads the head's copy once the
# body is read, so copying them cost two allocations per request for no isolation.

# HTTP's half of the contract: `copyheaders = false` stores the given `Headers` as-is.
h = HTTP.Headers(["A" => "1"])
t = HTTP.Headers()
adopted = HTTP.Request("GET", "/"; headers = h, trailers = t, copyheaders = false)
@test adopted.headers === h
@test adopted.trailers === t
@test HTTP.Request("GET", "/"; headers = h, trailers = t).headers !== h

const SEEN = Channel{Any}(1)
function handler(stream::HTTP.Stream)
    head = HTTP.startread(stream)
    req = Nitro.Core._http_stream_request(stream, Int64(1 << 20))
    HTTP.setheader(req, "Origin" => "https://rewritten.example")
    put!(SEEN, (; owns = req.headers !== head.headers,
                  head_origin = HTTP.header(head, "Origin", ""),
                  same_text = HTTP.header(req, "X-Probe", "") == HTTP.header(head, "X-Probe", ""),
                  adopts = req.trailers === head.trailers))
    HTTP.setstatus(stream, 204)
    HTTP.startwrite(stream)
    return nothing
end

port = get_free_port()
server = HTTP.listen!(handler, HOST, port)
try
    sock = Sockets.connect(HOST, port)
    try
        write(sock, "POST /x HTTP/1.1\r\nHost: x\r\nOrigin: https://app.example\r\nX-Probe: p\r\n" *
                    "Content-Length: 2\r\n\r\nhi")
        # Timed, so a handler that throws fails this item instead of hanging it.
        timedwait(() -> isready(SEEN), 30.0; pollint = 0.01) === :ok || error("the handler reported nothing in 30 s")
        seen = take!(SEEN)
        @test seen.owns
        @test seen.head_origin == "https://app.example"   # the rewrite stayed on `req`
        @test seen.same_text
        @test seen.adopts
    finally
        close(sock)
    end
finally
    close(server)
end
end

@testitem "HTTP logs a stream handler's error unless it is `stream.io_error` (HTTP 2.11)" tags=[:core, :network] setup=[NitroCommon] begin
using Test
import HTTP
import Sockets
const Logging = Base.CoreLogging

# Since HTTP.jl 2.11 (JuliaWeb/HTTP.jl#1425) the stream loop logs every error a stream handler
# throws at `@error`, with the live exception and `request.target` -- the query string included --
# except the one it recorded itself as `stream.io_error`, which it treats as the peer's. Nitro's
# `_mark_reported!` (src/core/transport.jl) relies on exactly that: it records an error Nitro has
# already logged there, so HTTP derives the status and logs nothing. This pins HTTP's half on a raw
# listener, with no Nitro in the path: if HTTP stops keying on identity, or keys on another field,
# the unmarked cases below still log and the marked ones start to.
#
# The status is the other half. Unmarked, 2.11 answers every handler error 500; marked, it derives
# the status from the type, as every error got through 2.9 -- which is what keeps a `ParseError` a
# 400 under Nitro (`parallel_stream_handler`'s comment, #316).
function handler(stream::HTTP.Stream)
    HTTP.startread(stream)
    target = stream.message.target
    err = occursin("kind=parse", target) ? HTTP.ParseError("bad input") : ErrorException("handler failed")
    occursin("marked=1", target) && (stream.io_error = err)
    throw(err)
end

logger = Test.TestLogger(min_level = Logging.Warn)
port = get_free_port()
server = Logging.with_logger(() -> HTTP.listen!(handler, HOST, port), logger)
http_records() = lock(() -> filter(r -> r._module === HTTP, copy(logger.logs)), logger.lock)
try
    for (marked, kind, status, logs) in ((false, "error", 500, true), (true, "error", 500, false),
                                         (false, "parse", 500, true), (true, "parse", 400, false))
        lock(() -> empty!(logger.logs), logger.lock)
        sock = Sockets.connect(HOST, port)
        try
            write(sock, "GET /x?token=Q5ECRET&kind=$kind&marked=$(Int(marked)) HTTP/1.1\r\nHost: x\r\n\r\n")
            reader = @async String(read(sock))
            @test timedwait(() -> istaskdone(reader), 10.0) === :ok
            @test startswith(fetch(reader), "HTTP/1.1 $status")
        finally
            close(sock)
        end
        # HTTP logs before it answers, so by now a record that will exist does.
        if logs
            record = only(http_records())
            @test record.message == "server handler error"
            # Why Nitro must not let an unreported error through: the target is logged whole.
            @test occursin("Q5ECRET", string(record.kwargs[:target]))
        else
            @test isempty(http_records())
        end
    end
finally
    close(server)
end
end
