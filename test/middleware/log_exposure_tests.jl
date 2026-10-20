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

# #648: a `Res.sse` producer is application code, the same shape as a handler. It runs on its own
# task, which inherits the logger, so its record is waited for rather than read at once.
@testset "a failed Res.sse producer: the value it threw over reaches no log record (#648)" begin
    logger = Test.TestLogger(; min_level = Base.CoreLogging.Debug)
    records() = lock(() -> copy(logger.logs), logger.lock)
    failed(l) = occursin("the event producer failed", string(l.message))
    Base.CoreLogging.with_logger(logger) do
        Nitro.Res.sse(events -> needs_int(Dict("token" => "S3NT1NEL-sse")))
    end
    @test timedwait(() -> any(failed, records()), 10.0; pollint = 0.05) === :ok
    logs = records()
    @test !any(l -> leaks(rendered(l)), logs)
    record = only(filter(failed, logs))
    @test record.kwargs[:exception][1] isa Nitro.Errors.LoggedException
    @test occursin("no method matching needs_int", console_text(record))
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

# #658: the rule holds in all of `src/`, not only on a request's path and in `src/Workers` (#651). A
# background janitor runs work the APP supplied -- a custom session store's prune, `AccessLog`'s
# retention `prune(cutoff)` -- and logged whatever it threw. A database error keeps the server's
# DETAIL line in a field (the #646 shape: `Key (session_key)=(<the id>)`), which `showerror` leaves
# out and a structured sink's `show` or `dump` prints.
@testitem "background and lifecycle logs never carry the live exception (#658)" tags=[:middleware, :security] setup=[NitroCommon] begin
using Test
using Dates
using Nitro
using Nitro.Core: startup, shutdown
using Nitro.Core.Middleware.JanitorMiddleware: _janitor_loop
using Nitro.Core.AppContext: _try_cancel

# Renders like a database error: a value-free message, and the row in a field.
struct StoreBoom <: Exception
    detail::String
end
Base.showerror(io::IO, ::StoreBoom) = print(io, "StoreBoom: the prune DELETE hit a foreign key")
boom() = StoreBoom("DETAIL:  Key (session_key)=(S3NT1NEL-sid) is still referenced.")
leaks(s) = occursin("S3NT1NEL", s)

# Everything a sink could write: the message, the kwargs as `show`n, and the exception under
# `showerror` and `dump`.
function rendered(l)
    out = string(l.message, sprint(show, l.kwargs))
    ex = get(l.kwargs, :exception, nothing)
    ex isa Tuple && (ex = ex[1])
    ex isa Exception && (out *= sprint(showerror, ex) * sprint(dump, ex))
    return out
end

records(logger) = lock(() -> copy(logger.logs), logger.lock)

# The record named `message` exists and carries a `LoggedException` of the original's type name, the
# console text is kept, and no record quotes the row.
function check(logs, message)
    hits = filter(l -> occursin(message, string(l.message)), logs)
    @test !isempty(hits)
    for record in hits
        ex = record.kwargs[:exception]
        logged = ex isa Tuple ? ex[1] : ex
        @test logged isa Nitro.Errors.LoggedException
        logged isa Nitro.Errors.LoggedException || continue
        @test logged.type === :StoreBoom
        @test occursin("foreign key", logged.text)
    end
    @test !any(l -> leaks(rendered(l)), logs)
end

@testset "the live error does carry the row (positive control)" begin
    @test leaks(sprint(dump, boom()))
    @test !leaks(sprint(showerror, boom()))
end

@testset "the janitor loop: a failed tick" begin
    token = Ref(true)
    ticks = Ref(0)
    work = function ()
        ticks[] += 1
        ticks[] >= 2 && (token[] = false)
        throw(boom())
    end
    logger = Test.TestLogger(; min_level = Base.CoreLogging.Info)
    Base.CoreLogging.with_logger(logger) do
        _janitor_loop(() -> work(), token, Millisecond(1), "JanitorTest", "prune")
    end
    @test ticks[] == 2
    check(records(logger), "Nitro.JanitorTest: prune failed")
end

# A store whose prune fails the way a database DELETE does; nothing else is ever called.
struct FailingPruneStore <: Nitro.Core.Types.AbstractSessionStore{String,Dict{String,Any}}
    calls::Threads.Atomic{Int}
end
function Nitro.Core.Types.cleanup_expired_sessions!(s::FailingPruneStore)
    Threads.atomic_add!(s.calls, 1)
    throw(boom())
end

@testset "a served SessionPruner over an app's own store" begin
    store = FailingPruneStore(Threads.Atomic{Int}(0))
    pruner = SessionPruner(store; interval = Millisecond(20))
    logger = Test.TestLogger(; min_level = Base.CoreLogging.Info)
    try
        # Started under the logger, so the janitor's spawned task inherits it.
        Base.CoreLogging.with_logger(() -> startup(pruner), logger)
        @test timedwait(() -> store.calls[] >= 2, 10.0; pollint = 0.05) === :ok
    finally
        shutdown(pruner)
    end
    check(records(logger), "Nitro.SessionPruner: session prune failed")
end

@testset "the eager-Revise watcher: a cancel that threw" begin
    logger = Test.TestLogger(; min_level = Base.CoreLogging.Info)
    t = @async nothing
    wait(t)
    @test Base.CoreLogging.with_logger(() -> _try_cancel(_ -> throw(boom()), t), logger) === nothing
    check(records(logger), "cancelling the eager-Revise watcher's wait failed")
end

# The rule is uniform across `src/`, not limited to the sites above. Read from the parsed source, so
# a docstring or comment that quotes `exception=e` is not a site and a call split over several lines
# still is. Two rules, for every logging macro call:
#
# - an `exception` argument is `loggable(e)` or `(loggable(e), catch_backtrace())`, nothing else;
# - no argument, the message included, names a `catch` variable in scope except inside `loggable`,
#   `typeof` or `nameof`, or through a field. That catches `@warn "m" e` (logged under the key `e`),
#   `err = e`, and `"$e"`, which prints through `show`.
@testset "every exception= in src/ goes through loggable" begin
    logmacros = Symbol.(("@error", "@warn", "@info", "@debug", "@logmsg"))
    macroname(m::Symbol) = m
    macroname(m::GlobalRef) = m.name
    macroname(m::Expr) = m.head === :. ? macroname(m.args[end]) : nothing
    macroname(m::QuoteNode) = m.value
    macroname(_) = nothing
    isloggable(v) = v isa Expr && v.head === :call && v.args[1] === :loggable && length(v.args) == 2
    isbacktrace(v) = v isa Expr && v.head === :call && v.args[1] === :catch_backtrace
    safe(v) = isloggable(v) ||
              (v isa Expr && v.head === :tuple && length(v.args) == 2 &&
               isloggable(v.args[1]) && isbacktrace(v.args[2]))
    # Whether `ex` names `v` other than through `loggable`/`typeof`/`nameof` or a field access.
    names_live(ex, v) = ex === v ||
        (ex isa Expr && ex.head !== :. &&
         !(ex.head === :call && ex.args[1] in (:loggable, :typeof, :nameof)) &&
         any(a -> names_live(a, v), ex.args))
    # `@error("m"; exception = e)` puts its keywords in a `:parameters` block.
    logargs(ex) = mapreduce(a -> a isa Expr && a.head === :parameters ? a.args : Any[a], vcat,
                            ex.args[3:end]; init = Any[])

    sites = Ref(0)
    function walk(ex, file, vars, out)
        ex isa Expr || return out
        if ex.head === :try && ex.args[2] isa Symbol
            walk(ex.args[1], file, vars, out)
            walk(ex.args[3], file, [vars; ex.args[2]], out)
            foreach(a -> walk(a, file, vars, out), ex.args[4:end])
            return out
        end
        if ex.head === :macrocall && macroname(ex.args[1]) in logmacros
            at = "$(relpath(file, pkgdir(Nitro))):$(ex.args[2] isa LineNumberNode ? ex.args[2].line : 0)"
            for a in logargs(ex)
                if a isa Expr && a.head in (:(=), :kw) && a.args[1] === :exception
                    sites[] += 1
                    safe(a.args[2]) || push!(out, at)
                end
                any(v -> names_live(a, v), vars) && push!(out, at)
            end
        end
        foreach(a -> walk(a, file, vars, out), ex.args)
        return out
    end
    scan(code) = walk(Meta.parseall(code), joinpath(pkgdir(Nitro), "probe.jl"), Symbol[], String[])

    # The scan flags the forms it claims to, and passes the ones Nitro writes. A lambda binds no
    # `catch` variable, so only the `exception=` rule can flag the forms written as one.
    for code in ("try f() catch e; @error \"m\" exception=(e, catch_backtrace()) end",
                 "g = e -> @error(\"m\"; exception = e)",
                 "g = e -> @warn \"m\" exception=(loggable(e), e)",
                 "try f() catch e; @warn \"m\" e end",
                 "try f() catch e; @warn \"m\" err = e end",
                 "try f() catch e; @warn \"failed: \$e\" end",
                 "g = e -> @debug \"m\" exception=e")
        @test !isempty(scan(code))
    end
    for code in ("try f() catch e; @error \"m\" exception=(loggable(e), catch_backtrace()) end",
                 "try f() catch e; @warn(\"m\"; exception = loggable(e)) end",
                 "try f() catch e; @warn \"m\" exception_type=nameof(typeof(e)) message=e.msg end")
        @test isempty(scan(code))
    end
    sites[] = 0

    offenders = String[]
    unparsed = String[]
    for (dir, _, names) in walkdir(joinpath(pkgdir(Nitro), "src")), name in names
        endswith(name, ".jl") || continue
        file = joinpath(dir, name)
        parsed = Meta.parseall(read(file, String); filename = file)
        # `parseall` does not throw: a syntax error ends the file in an `:error` node, and the
        # walk would then pass whatever followed it unread.
        any(a -> a isa Expr && a.head in (:error, :incomplete), parsed.args) && push!(unparsed, file)
        walk(parsed, file, Symbol[], offenders)
    end
    @test isempty(unparsed)
    @test sites[] >= 40                   # the scan is seeing the sites, not a moved tree
    @test isempty(offenders)
    isempty(offenders) || @info "log calls that can carry a live exception" offenders
end

end
