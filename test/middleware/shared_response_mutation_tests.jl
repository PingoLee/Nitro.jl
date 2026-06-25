@testitem "Shared response not mutated by header-adding middleware" tags=[:middleware, :security] setup=[NitroCommon] begin
using HTTP
using Nitro
using Nitro.Core.Types: MemoryStore

# A module-level `const` response shared across requests — the endorsed Nitro pattern
# (e.g. auth_middleware.jl's `INVALID_HEADER`). Header-adding middleware must NOT mutate
# it in place: doing so accumulates headers on the shared object and leaks per-request
# headers (echoed Origin, `Set-Cookie`) to every other request that returns it. It is
# also an unsynchronized data race under Nitro's multithreaded serve.
# See docs/design/response-body-lifecycle.md and `own_response_headers`.
const SHARED = HTTP.Response(401, "shared-const-body")

count_header(resp, name) = count(h -> lowercase(h.first) == lowercase(name), resp.headers)
set_cookie_value(resp) = begin
    hs = filter(h -> lowercase(h.first) == "set-cookie", resp.headers)
    isempty(hs) ? nothing : hs[1].second
end

@testset "CORS does not accumulate headers on a shared const" begin
    @test isempty(SHARED.headers)                       # baseline: the const owns no headers
    wrapped = Cors(allowed_origins=["https://app.example.com"], allow_credentials=true)(req -> SHARED)

    # Returning the same const through CORS on three requests must not pile headers onto it.
    for _ in 1:3
        resp = wrapped(HTTP.Request("GET", "/"))
        @test resp.status == 401
        @test resp !== SHARED                           # a fresh response was returned
        @test count_header(resp, "Access-Control-Allow-Origin") == 1   # no accumulation
        @test count_header(resp, "Access-Control-Allow-Methods") == 1
    end
    @test isempty(SHARED.headers)                       # the shared const was never mutated
end

@testset "SessionMiddleware does not leak a Set-Cookie onto a shared const" begin
    @test isempty(SHARED.headers)
    store = MemoryStore{String, Dict{String,Any}}()
    wrapped = SessionMiddleware(cookie_name="sid", max_age=3600, store=store, prune_probability=0.0)(req -> SHARED)

    # Two distinct new visitors (no session cookie) both get the shared 401 const back.
    respA = wrapped(HTTP.Request("GET", "/protected"))
    respB = wrapped(HTTP.Request("GET", "/protected"))

    @test respA.status == 401 && respB.status == 401
    @test respA !== SHARED && respB !== SHARED
    ca, cb = set_cookie_value(respA), set_cookie_value(respB)
    @test ca !== nothing && cb !== nothing              # each visitor gets their own session cookie
    @test ca != cb                                      # …and B does NOT receive A's session id
    @test isempty(SHARED.headers)                       # the shared const carries no Set-Cookie of its own
end
end

@testitem "Header-adding middleware preserves non-header response fields" tags=[:middleware] setup=[NitroCommon] begin
using HTTP
using Nitro
using Nitro.Core: own_response_headers, add_response_headers
using Nitro.Core.Types: MemoryStore

# `own_response_headers`/`add_response_headers` rebuild the response so they can own a
# fresh `headers` vector. The rebuild must carry every *other* `HTTP.Response` field
# across — the two-arg `HTTP.Response(status, headers, body)` form would reset `reason`,
# `trailers`, the HTTP version, and `close` to their defaults. The server reads
# `close`/version to decide connection teardown (http_server_streams.jl), so a handler
# returning `HTTP.Response(...; close=true)` losing it through the middleware chain is a
# real behaviour regression — not cosmetic.
rich_response() = HTTP.Response(207;
    body        = "rich-body",
    reason      = "Multi-Status",
    headers     = ["X-Orig" => "1"],
    trailers    = ["X-Trailer" => "t"],
    proto_major = 1, proto_minor = 0,           # non-default version (HTTP/1.0)
    close       = true,                          # the field with real server impact
)

has_header(hs, name) = any(h -> lowercase(h.first) == lowercase(name), hs)

assert_fields_preserved(r) = begin
    @test r.status == 207
    @test r.reason == "Multi-Status"
    @test r.close == true
    @test (r.proto_major, r.proto_minor) == (1, 0)
    @test has_header(r.trailers, "X-Trailer")
end

@testset "own_response_headers preserves non-header fields and shares the body" begin
    rich = rich_response()
    out  = own_response_headers(rich)
    @test out !== rich                                  # a fresh response object
    @test out.body === rich.body                        # …but the body is shared by reference
    @test out.headers !== rich.headers                  # …with its own headers vector
    assert_fields_preserved(out)
    @test has_header(out.headers, "X-Orig")
end

@testset "add_response_headers preserves non-header fields and appends" begin
    rich = rich_response()
    out  = add_response_headers(rich, ["X-Added" => "y"])
    @test out !== rich
    @test out.body === rich.body
    assert_fields_preserved(out)
    @test has_header(out.headers, "X-Orig")             # original header kept
    @test has_header(out.headers, "X-Added")            # …and the extra one appended
    @test isempty(filter(h -> lowercase(h.first) == "x-added", rich.headers))  # source untouched
end

@testset "close=true survives the real middleware chain" begin
    handler = req -> rich_response()

    # CORS routes through add_response_headers; SessionMiddleware through own_response_headers.
    cors = Cors(allowed_origins=["https://app.example.com"])(handler)
    @test cors(HTTP.Request("GET", "/")).close == true

    store = MemoryStore{String, Dict{String,Any}}()
    sess = SessionMiddleware(cookie_name="sid", max_age=3600, store=store, prune_probability=0.0)(handler)
    @test sess(HTTP.Request("GET", "/")).close == true
end
end
