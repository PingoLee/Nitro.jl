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
    # The handler WRITES to the session before returning the const. Since #317 a new session
    # that nothing writes is not saved and gets no cookie, so a read-only handler here would
    # never reach the `Set-Cookie` path this guard exists for.
    wrapped = SessionMiddleware(cookie_name="sid", max_age=3600, store=store).middleware(
        req -> (getsession(req)["seen"] = true; SHARED))

    # Two distinct new visitors (no session cookie) both get the shared 401 const back.
    respA = wrapped(HTTP.Request("GET", "/protected"))
    respB = wrapped(HTTP.Request("GET", "/protected"))

    @test respA.status == 401 && respB.status == 401
    @test respA !== SHARED && respB !== SHARED
    ca, cb = set_cookie_value(respA), set_cookie_value(respB)
    @test ca !== nothing && cb !== nothing              # each visitor gets their own session cookie
    @test ca != cb                                      # …and B does NOT receive A's session id
    @test isempty(SHARED.headers)                       # the shared const carries no Set-Cookie of its own

    # A visitor whose session is never written is handed the const itself, untouched.
    untouched = SessionMiddleware(cookie_name="sid", max_age=3600, store=store).middleware(req -> SHARED)
    @test untouched(HTTP.Request("GET", "/protected")) === SHARED
    @test isempty(SHARED.headers)
end

@testset "CSRFMiddleware does not leak a Set-Cookie onto a shared const" begin
    # CSRF issues its cookie on more paths than "safe method, no cookie": it re-issues whenever
    # the presented cookie would not verify under the current session. Every one of those paths
    # sits INSIDE the documented pipeline position of an auth middleware that returns a shared
    # `const` rejection, so each has to own the headers first.
    @test isempty(SHARED.headers)
    store = MemoryStore{String, Dict{String,Any}}()
    # The handler asks for the token (`csrf_token!`): since #431 a first visit nobody asked a
    # token for gets none, so the const would never be at risk on that path.
    wrapped = SessionMiddleware(cookie_name="sid", max_age=3600, store=store).middleware(
        CSRFMiddleware("shared-const-secret")(req -> (csrf_token!(req); SHARED)))
    # And one that does not ask: the re-issue below is unasked, minted because the session exists.
    unasked = SessionMiddleware(cookie_name="sid", max_age=3600, store=store).middleware(
        CSRFMiddleware("shared-const-secret")(req -> SHARED))

    csrf_cookie(resp) = begin
        hs = filter(h -> lowercase(h.first) == "set-cookie" && startswith(h.second, "__Host-csrf_token="),
                    resp.headers)
        isempty(hs) ? nothing : hs[1].second
    end

    respA = wrapped(HTTP.Request("GET", "/protected"))
    respB = wrapped(HTTP.Request("GET", "/protected"))

    @test respA.status == 401 && respB.status == 401
    @test respA !== SHARED && respB !== SHARED
    ta, tb = csrf_cookie(respA), csrf_cookie(respB)
    @test ta !== nothing && tb !== nothing
    @test ta != tb                                      # B does NOT receive A's CSRF token
    @test isempty(SHARED.headers)                       # nothing was written to the shared const

    # The stale-token re-issue path, which is the one this change widened.
    # Pick the `sid` header by name: the response now carries two Set-Cookie headers, and the
    # CSRF one is emitted first (the inner layer runs first on the way out).
    sid_line = only(filter(h -> lowercase(h.first) == "set-cookie" && startswith(h.second, "sid="),
                           respA.headers)).second
    sid = match(r"sid=([^;]+)", sid_line).captures[1]
    stale = HTTP.Request("GET", "/protected", ["Cookie" => "sid=$sid; __Host-csrf_token=bogus.sig"])
    respC = unasked(stale)
    @test csrf_cookie(respC) !== nothing
    @test isempty(SHARED.headers)
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
    sess = SessionMiddleware(cookie_name="sid", max_age=3600, store=store).middleware(handler)
    @test sess(HTTP.Request("GET", "/")).close == true
end

@testset "a rebuild changes the headers and nothing else (#447)" begin
    rich = rich_response()
    for out in (own_response_headers(rich), add_response_headers(rich, "X-Added" => "y"))
        for f in fieldnames(HTTP.Response)
            f in (:headers, :trailers) && continue
            @test getfield(out, f) === getfield(rich, f)
        end
        # The new response owns both header collections; the source's are untouched.
        @test out.trailers !== rich.trailers && out.trailers.entries == rich.trailers.entries
        @test out.headers !== rich.headers
        @test rich.headers.entries == ["X-Orig" => "1"]
    end
end

@testset "add_response_headers emits exactly what HTTP's normalization did (#447)" begin
    # Before #447 every call built `HTTP.Headers(vcat(resp.headers, extra))`. That is the oracle:
    # `appendheader` over everything, so adjacent duplicates fold into `a,b`, `Set-Cookie` never
    # folds, and a name that differs only in case still counts as the same name.
    oracle(resp, extra) = HTTP.Headers(vcat(resp.headers, extra)).entries
    base = HTTP.Response(200; headers = ["Vary" => "Origin", "Set-Cookie" => "a=1"], body = "x")
    cases = (
        "X-One" => "1",                                              # a single Pair (pipeline.jl, transport.jl)
        ["Set-Cookie" => "b=2", "Set-Cookie" => "c=3"],              # never folded
        ["vary" => "Cookie"],                                        # not adjacent to `Vary`: kept apart
        ["X-A" => "1", "x-a" => "2", "X-B" => "3"],                  # adjacent, case-variant: folded
        Pair{String,String}[],                                       # nothing to add
        ["X-Sub" => SubString("abc", 1, 2)],                         # non-String values
    )
    for extra in cases
        @test add_response_headers(base, extra).headers.entries == oracle(base, extra)
    end
    # The fallback keeps HTTP's general form for anything that is not typed string pairs. Its
    # oracle IS its implementation, so this proves only that an untyped vector reaches it.
    untyped = Any["X-Any" => "1"]
    @test add_response_headers(base, untyped).headers.entries == oracle(base, untyped)
    # A response whose own headers hold adjacent duplicates is folded too, as before.
    dup = HTTP.Response(200; body = "x")
    push!(dup.headers, "X-D" => "1"); push!(dup.headers, "X-D" => "2")
    @test add_response_headers(dup, "X-E" => "3").headers.entries == oracle(dup, "X-E" => "3")
end

# The pre-#447 rebuild: HTTP's keyword constructor, every field passed back in.
keyword_rebuild(resp, headers) = HTTP.Response(resp.status, resp.body; reason = resp.reason,
    headers = headers, trailers = resp.trailers, content_length = resp.content_length,
    proto_major = resp.proto_major, proto_minor = resp.proto_minor, close = resp.close,
    request = resp.request, request_url = resp.request_url, previous = resp.previous,
    redirect_count = resp.redirect_count)

function allocs_per_call(f, n)
    f()
    return @allocations(for _ in 1:n; f(); end) / n
end

@testset "a rebuild allocates less than the keyword constructor did (#447)" begin
    resp, extra = HTTP.Response(200, "x"), ["X-A" => "1", "X-B" => "2"]
    new_add() = add_response_headers(resp, extra)
    old_add() = keyword_rebuild(resp, vcat(resp.headers, extra))
    new_own() = own_response_headers(resp)
    old_own() = keyword_rebuild(resp, copy(resp.headers))
    @test allocs_per_call(new_add, 1000) + 3 <= allocs_per_call(old_add, 1000)
    @test allocs_per_call(new_own, 1000) + 2 <= allocs_per_call(old_own, 1000)
end
end
