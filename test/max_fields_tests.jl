# `serve(max_fields = …)` (#327): a cap on how many fields one request may carry, per source --
# query parameters, urlencoded form fields, multipart parts, and a JSON body's object keys.
#
# The byte caps bound how much a request sends, not how many keys it packs in, and every one of
# those sources becomes a string-keyed hash table; `hash(::String)` has a fixed seed, so a client
# that picks its keys can pick colliding ones. Django's `DATA_UPLOAD_MAX_NUMBER_FIELDS` and
# Express's `parameterLimit` are the precedent, and 1000 is their default.

@testitem "max_fields caps every field source (#327)" tags=[:core, :security] setup=[NitroCommon] begin
using Test
using HTTP
using JSON
using Nitro
using Nitro: App, Form, Json, JsonFragment, MultipartForm
using Base.ScopedValues: @with
using Nitro.Core.Constants: REQUEST_MAX_FIELDS, DEFAULT_MAX_FIELDS

struct Small
    a::Int
end

app = App(mod = @__MODULE__)
urlpatterns(app, "",
    path("/query", req -> string(length(getquery(req)))),
    path("/form", req -> string(length(getform(req))); method = "POST"),
    path("/form-typed", (req, f::Form{Small}) -> string(f.payload.a); method = "POST"),
    path("/json", req -> string(length(getjson(req))); method = "POST"),
    path("/json-typed", (req, j::Json{Dict{String,Int}}) -> string(length(j.payload)); method = "POST"),
    path("/multipart", req -> string(length(getpost(req))); method = "POST"),
)
app.service.max_fields[] = 3
send(r) = internalrequest(app, r)
fields(n) = join(("k$i=$i" for i in 1:n), "&")
jobject(n) = "{" * join(("\"k$i\":$i" for i in 1:n), ",") * "}"
const JSON_T = ["Content-Type" => "application/json"]
const FORM_T = ["Content-Type" => "application/x-www-form-urlencoded"]
boundary = "----nitro327fields"
multipart_body(n) = join(("--$boundary\r\nContent-Disposition: form-data; name=\"k$i\"\r\n\r\n$i\r\n" for i in 1:n)) * "--$boundary--\r\n"
const MP_T = ["Content-Type" => "multipart/form-data; boundary=$boundary"]

@testset "at the cap binds, one over is a 400" begin
    @test send(HTTP.Request("GET", "/query?" * fields(3))).status == 200
    @test send(HTTP.Request("GET", "/query?" * fields(4))).status == 400
    @test send(HTTP.Request("POST", "/form", FORM_T, fields(3))).status == 200
    @test send(HTTP.Request("POST", "/form", FORM_T, fields(4))).status == 400
    @test send(HTTP.Request("POST", "/form-typed", FORM_T, "a=1&" * fields(3))).status == 400
    @test send(HTTP.Request("POST", "/json", JSON_T, jobject(3))).status == 200
    @test send(HTTP.Request("POST", "/json", JSON_T, jobject(4))).status == 400
    @test send(HTTP.Request("POST", "/json-typed", JSON_T, jobject(3))).status == 200
    @test send(HTTP.Request("POST", "/json-typed", JSON_T, jobject(4))).status == 400
    @test send(HTTP.Request("POST", "/multipart", MP_T, multipart_body(3))).status == 200
    @test send(HTTP.Request("POST", "/multipart", MP_T, multipart_body(4))).status == 400
end

@testset "JSON keys are counted across the whole document, never inside strings" begin
    # Nested objects count too: 2 + 2 = 4 keys.
    @test send(HTTP.Request("POST", "/json", JSON_T, """{"a":{"b":1,"c":2},"d":3}""")).status == 400
    # Colons inside strings and after escaped quotes are not keys.
    @test send(HTTP.Request("POST", "/json", JSON_T, """{"a":"x:y:z","b":"q\\":r","c":"::"}""")).status == 200
    # Arrays have no keys.
    @test send(HTTP.Request("POST", "/json", JSON_T, """{"a":[1,2,3,4,5,6,7,8]}""")).status == 200
end

@testset "a JSON body is never counted as a form (#327 review)" begin
    # `payload` reads the form of every request, and `formdata` form-parsed any body holding an
    # `=`: a JSON body with ONE key whose string is ordinary HTML full of `&amp;` answered 400.
    html = "a=b" * repeat("&amp;", 10)
    body = JSON.json(Dict("html" => html))
    urlpatterns(app, "", path("/payload", req -> string(sort(collect(keys(payload(req))))); method = "POST"))
    r = send(HTTP.Request("POST", "/payload", JSON_T, body))
    @test r.status == 200
    @test Nitro.text(r) == string(["html"])          # and no junk "form" keys merged in
    @test isempty(getform(HTTP.Request("POST", "/", JSON_T, body)))
end

@testset "empty fields are not fields" begin
    @test send(HTTP.Request("GET", "/query?a=1&&b=2&&&c=3&")).status == 200
end

@testset "the 400 never names a key" begin
    logger = Test.TestLogger(min_level = Base.CoreLogging.Debug)
    Base.CoreLogging.with_logger(logger) do
        send(HTTP.Request("GET", "/query?secretkey1=1&secretkey2=2&secretkey3=3&secretkey4=4"))
    end
    @test !any(l -> occursin("secretkey", string(l.message, l.kwargs)), logger.logs)
    @test !any(l -> l.level >= Base.CoreLogging.Error, logger.logs)
    err = try
        @with REQUEST_MAX_FIELDS => 1 Nitro.Core.Util.BodyParsers._check_field_count("pw=1&tok=2", "The form body")
        nothing
    catch e
        e
    end
    @test err isa ValidationError
    @test err.msg == "The form body has more than 1 fields"
end

@testset "outside a request the default applies; 0 lifts it; responses are not capped" begin
    @test REQUEST_MAX_FIELDS[] == DEFAULT_MAX_FIELDS == 1000
    big = HTTP.Request("POST", "/", JSON_T, jobject(1001))
    @test_throws ValidationError json(big)
    @test @with(REQUEST_MAX_FIELDS => 0, length(json(big))) == 1001
    @test length(json(HTTP.Response(200, jobject(1001)))) == 1001
    @test length(json(HTTP.Response(200, jobject(1001)), Dict{String,Int})) == 1001
end

@testset "max_fields = 0 on the app means unlimited" begin
    app.service.max_fields[] = 0
    @test send(HTTP.Request("GET", "/query?" * fields(2000))).status == 200
    app.service.max_fields[] = 3
end

@testset "serve validates max_fields before starting" begin
    bad_app = App(mod = @__MODULE__)
    for bad in (-1, true, 1.5, "10", typemax(UInt64), big(2)^70)
        @test_throws ArgumentError serve(bad_app; max_fields = bad, host = HOST, port = get_free_port(),
                                         async = true, show_banner = false, access_log = nothing)
        @test !isopen(bad_app.service)
    end
end
end

@testitem "max_fields over a real socket (#327)" tags=[:core, :network] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro: App

app = App(mod = @__MODULE__)
urlpatterns(app, "", path("/q", req -> string(length(getquery(req)))))
port = get_free_port()
serve(app; host = HOST, port = port, max_fields = 3, async = true, show_banner = false, access_log = nothing)
try
    base = "http://$HOST:$port/q"
    @test HTTP.get("$base?a=1&b=2&c=3"; status_exception = false).status == 200
    @test HTTP.get("$base?a=1&b=2&c=3&d=4"; status_exception = false).status == 400
    @test app.service.max_fields[] == 3
finally
    terminate(app)
end
end
