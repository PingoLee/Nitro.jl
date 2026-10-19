# #613: a log record carries what the console prints, never the live exception. ConsoleLogger renders
# an exception with `showerror`, which prints a `MethodError`'s arguments and a `TypeError`'s value as
# types; a sink that `show`s the record (a JSON or structured logger) printed the objects themselves.
#
# HTTP.jl (2.9) already masks `Authorization`, `Proxy-Authorization`, `Cookie` and `Set-Cookie`
# when it renders a request, and its compact `show` prints no headers at all, so a sentinel there
# proves nothing: it is absent with or without the fix. What `show` does print is the request
# TARGET, query string included, and every other value a handler throws over in full -- a parsed
# body, a token. Those carry the sentinels below.

@testitem "a callback or handler that throws over the request never logs its credentials (#613)" tags=[:middleware, :security] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro: App, BearerAuth, GuardMiddleware
using Nitro.Core: startup, shutdown, AccessLog

query_sentinel = "S3NT1NEL-query"
body_sentinel = "S3NT1NEL-body"
ua_sentinel = "S3NT1NEL-ua"
leaks(s) = occursin("S3NT1NEL", s)

# Only an `Int` will do: called with the request, or with the access records, it raises a
# `MethodError` whose arguments are exactly what must not reach the log.
needs_int(::Int) = 1

credentialed(path = "/h") = HTTP.Request("GET", "$path?api_key=$query_sentinel",
    ["Authorization" => "Bearer S3NT1NEL-auth", "Cookie" => "sid=S3NT1NEL-cookie",
     "User-Agent" => ua_sentinel])

# Everything a log sink could render: the message, every kwarg as `show` prints it, and the
# `exception` kwarg the way ConsoleLogger prints it.
function rendered(l)
    out = string(l.message, sprint(show, l.kwargs))
    ex = get(l.kwargs, :exception, nothing)
    ex isa Tuple && (out *= sprint(showerror, ex[1], ex[2]))
    ex isa Exception && (out *= sprint(showerror, ex))
    return out
end

# What the console showed is still there: the type, and the method that did not match.
console_text(l) = (ex = l.kwargs[:exception]; sprint(showerror, ex isa Tuple ? ex[1] : ex))

struct Tagged{T} <: Exception end
Base.showerror(io::IO, ::Tagged) = print(io, "Tagged")
struct Unprintable <: Exception end
Base.showerror(io::IO, ::Unprintable) = error("no")

app = App(mod = @__MODULE__)
urlpatterns(app, "",
    path("/h", req -> needs_int(req)),
    path("/typed", req -> (x -> x::Int)(req)),
    path("/body", req -> needs_int(getjson(req)); method = "POST"),
    path("/ok", req -> "ok"),
)

# (label, request, middleware, the text the console line must still carry)
cases = (
    ("a handler", credentialed("/h"), [], "no method matching needs_int"),
    ("a handler's typeassert (TypeError.got)", credentialed("/typed"), [], "TypeError"),
    ("a handler, over the parsed body", HTTP.Request("POST", "/body", ["Content-Type" => "application/json"],
                                                     "{\"password\":\"$body_sentinel\"}"),
     [], "no method matching needs_int(::JSON.Object"),
    ("an `unauthorized` factory", HTTP.Request("GET", "/ok?api_key=$query_sentinel"),
     [BearerAuth(t -> nothing; unauthorized = (req, reason) -> needs_int(req))],
     "no method matching needs_int"),
    ("a guard", credentialed("/ok"), [GuardMiddleware(req -> needs_int(req))],
     "no method matching needs_int"),
)

@testset "$label: the request reaches no log record" for (label, req, m, console) in cases
    logs, r = Test.collect_test_logs(; min_level = Base.CoreLogging.Debug) do
        internalrequest(app, req; middleware = m)
    end
    @test r.status == 500
    @test !any(l -> leaks(rendered(l)), logs)
    errors = [l for l in logs if l.level >= Base.CoreLogging.Error]
    @test length(errors) == 1
    @test occursin(console, console_text(only(errors)))
    @test only(errors).kwargs[:exception][1] isa Nitro.Errors.LoggedException
end

# The structured `AccessLog`'s hooks and sink, and the console line's `access_log_skip`. Their
# warnings come from the request task, or from the writer task, which inherits the logger.
function access_logs(f)
    logger = Test.TestLogger(; min_level = Base.CoreLogging.Debug)
    Base.CoreLogging.with_logger(f, logger)
    return logger.logs
end

hook_cases = (
    ("AccessLog skip", sink -> AccessLog(sink; skip = (req, resp) -> needs_int(req)), "skip hook errored"),
    ("AccessLog annotate", sink -> AccessLog(sink; annotate = req -> needs_int(req)), "annotate hook errored"),
    ("AccessLog sink", _ -> AccessLog(recs -> needs_int(recs)), "sink failed"),
)

@testset "$label: the request reaches no log record" for (label, mk, message) in hook_cases
    lf = mk(recs -> nothing)
    logs = access_logs() do
        startup(lf)
        @test lf.middleware(req -> HTTP.Response(200, "ok"))(credentialed("/ok")).status == 200
        shutdown(lf)                                    # drains the buffer, waits for the writer
    end
    warned = [l for l in logs if occursin(message, string(l.message))]
    @test length(warned) == 1
    @test !any(l -> leaks(rendered(l)), logs)
    @test occursin("no method matching needs_int", console_text(only(warned)))
end

@testset "access_log_skip (the console line): the request reaches no log record" begin
    mw = Nitro.Core.AccessLogMiddleware(skip = (req, resp) -> needs_int(req))
    logs = access_logs() do
        mw(_req -> HTTP.Response(200))(credentialed("/ok"))
    end
    warned = [l for l in logs if occursin("access_log_skip hook errored", string(l.message))]
    @test length(warned) == 1
    @test !any(l -> leaks(rendered(l)), logs)
    @test occursin("no method matching needs_int", console_text(only(warned)))
end

@testset "loggable: the type's name and the showerror text, nothing else" begin
    e = try needs_int(credentialed()) catch e; e end
    le = Nitro.Errors.loggable(e)
    @test le.type === :MethodError
    @test le.text == sprint(showerror, e; context = :limit => true)
    @test sprint(show, le) == le.text
    @test sprint(showerror, le) == le.text
    @test !leaks(sprint(show, le))
    @test leaks(sprint(show, e))                        # the original does render it
    @test Nitro.Errors.loggable(le) === le              # idempotent

    # A type parameter can carry a value; only the name is kept.
    @test Nitro.Errors.loggable(Tagged{Symbol(query_sentinel)}()).type === :Tagged

    # An exception whose `showerror` throws is still logged, by type.
    @test occursin("Unprintable", Nitro.Errors.loggable(Unprintable()).text)
end

end
