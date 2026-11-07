@testitem "juliac: the trimmed-only branches, run under the JIT (#858)" tags=[:core, :security] setup=[NitroCommon] begin
using Test

# ── The branches a trimmed image takes, in CI ───────────────────────────────────────────────────
#
# Under the JIT `_trimmed()` is the constant `false`, so inference deletes every branch it guards
# and no test process runs one. The probe build (`bench/juliac/probe.jl`) does, by hand. This item
# runs them in one child, `test/.helpers/trimmed_child.jl`, with `_trimmed()` redefined to `true`
# as a `--trim` build redefines it. The sites and how each is checked are listed in
# `test/.helpers/trimmed_sites.jl`:
#   A  the trimmed result equals the JIT result on the same inputs (the session copy and change
#      check, MemoryStore's copy, the JWT claims parse, the validator's arity);
#   B  a refusal makes no dynamic call and names a type, never a value; a fallback answers what
#      its comment says.
# The child calls each function directly, never through a request: with `_trimmed()` true a
# `RouteEndpoint` `ccall`s a thunk only a `--trim` build exports (src/routeendpoint.jl).

include(joinpath(@__DIR__, ".helpers", "trimmed_sites.jl"))

child = joinpath(@__DIR__, ".helpers", "trimmed_child.jl")
cmd = `$(Base.julia_cmd()) --code-coverage=none --project=$(Base.active_project()) --startup-file=no $child`
out, err = IOBuffer(), IOBuffer()
p = run(pipeline(ignorestatus(cmd); stdout = out, stderr = err))
out, err = String(take!(out)), String(take!(err))
lines = split(out, '\n'; keepempty = false)

@test (p.exitcode, p.termsignal) == (0, 0) || (last(out, 2000), last(err, 2000))
@test "DONE" in lines || last(out, 2000)
# The redefinition reached code compiled before it: a method the child compiled under the JIT now
# takes the trimmed branch.
@test "FLIP=true" in lines || out

# The lifecycle hooks' lines (#846). The child runs a throwing hook through each phase in both
# runs, under a `NullLogger`: only the trimmed run writes the line, so each appears exactly once,
# and it names the exception's type, never its message (the sentinel).
@testset "a failed hook writes one value-free line, and only when trimmed (#846)" begin
    errlines = split(err, '\n'; keepempty = false)
    for phase in ("on_startup", "on_shutdown", "on_stopped")
        want = "Nitro: LifecycleMiddleware.$phase failed: ArgumentError"
        @test count(==(want), errlines) == 1 || last(err, 2000)
    end
    for line in errlines
        startswith(line, "Nitro: ") || continue
        @test !occursin("S3NT1NEL", line) || line
    end
end

# The request path's line (#883). The child runs the same failures before and after the flip:
# five on one route, one on a second route, and a second type on the first route twice. Each pair
# is written exactly once, and only by the trimmed run. It names the route's pattern; the target,
# which carries the sentinel, never appears (checked above, for every `Nitro: ` line).
@testset "a request failure writes one line per (type, route), and only when trimmed (#883)" begin
    errlines = split(err, '\n'; keepempty = false)
    for want in ("Nitro: a request failed: ArgumentError on route /memo/a",
                 "Nitro: a request failed: ArgumentError on route /memo/b",
                 "Nitro: a request failed: TrimSentinel on route /memo/a")
        @test count(==(want), errlines) == 1 || last(err, 2000)
    end
    # Past the cap: the final line once, and no request-path line after it.
    final = "Nitro: further request-path failures are not listed (the line limit is reached)"
    @test count(==(final), errlines) == 1 || last(err, 2000)
    i = findfirst(==(final), errlines)
    if i !== nothing
        later = filter(l -> occursin(r" (on route |with no route)", l), errlines[i+1:end])
        @test isempty(later) || later
    end
    @test "CAP_FINAL=true" in lines || out
    @test "CAP_SILENT=true" in lines || out
    @test "RESET=true" in lines || out
end

# The four sites of the error boundary (#883), each run three times before the flip and three
# after: one line per pair, by the trimmed run only, and every site still answers its 500.
@testset "the error boundary's sites each write their line once (#883)" begin
    errlines = split(err, '\n'; keepempty = false)
    for want in ("Nitro: a request failed: TrimSentinel on route /site/handler",
                 "Nitro: a request failed: TrimSentinel with no route",
                 "Nitro: a middleware returned a non-response: TrimBody on route /site/value",
                 "Nitro: refused a route handler not registered through path(): unregistered_leaf on route /site/foreign",
                 "Nitro: refused a rerouted request: different_route_middleware on route /site/old")
        @test count(==(want), errlines) == 1 || last(err, 2000)
    end
    @test "SITES_500=true" in lines || out
end

@testset "no check failed, and every listed site has its checks" begin
    for line in lines
        startswith(line, "FAIL ") || startswith(line, "NOCHECK ") || continue
        @test false || line
    end
end

passed = Set(String(first(split(line[4:end], " | "; limit = 2))) for line in lines if startswith(line, "OK "))
@testset "every A and B site reported at least one passing check" begin
    for ((file, func), kind) in TRIMMED_SITES
        kind in (:A, :B) || continue
        @test "$file:$func" in passed || "$file:$func"
    end
end
end

@testitem "juliac: every _trimmed() site in src/ and ext/ is listed (#858)" tags=[:core] begin
using Test

# The guard that keeps the list above complete. A new `_trimmed()` site fails here until it is
# listed in `test/.helpers/trimmed_sites.jl`: as A or B, which the child item then checks, or as
# exempt with the reason. The sites are found by parsing, so a comment or a docstring that names
# `_trimmed()` is not one.

include(joinpath(@__DIR__, ".helpers", "trimmed_sites.jl"))

root = dirname(@__DIR__)
found = trimmed_sites(root)

@testset "the scanner finds the sites" begin
    # A floor, so a scanner that silently finds nothing cannot pass the set comparison below.
    @test length(found) >= length(TRIMMED_SITES)
end

@testset "every site is listed" begin
    for site in found
        @test haskey(TRIMMED_SITES, (site.file, site.func)) ||
              "$(site.file):$(site.line) in $(site.func) is a `_trimmed()` site not in " *
              "test/.helpers/trimmed_sites.jl: list it as :A, :B or exempt"
    end
end

@testset "every listed function holds the sites it is listed with" begin
    counts = Dict{Tuple{String, String}, Int}()
    for s in found
        counts[(s.file, s.func)] = get(counts, (s.file, s.func), 0) + 1
    end
    for (key, n) in counts
        haskey(TRIMMED_SITES, key) || continue        # reported above
        want = get(TRIMMED_SITE_COUNTS, key, 1)
        @test n == want || "$(key[1]): $(key[2]) holds $n `_trimmed()` sites, listed with $want; " *
                           "decide how the new one is tested, then update TRIMMED_SITE_COUNTS"
    end
    @test issubset(keys(TRIMMED_SITE_COUNTS), keys(TRIMMED_SITES))
end

@testset "every listed site still exists" begin
    keys_found = Set((s.file, s.func) for s in found)
    for key in keys(TRIMMED_SITES)
        @test key in keys_found || "$(key[1]): no `_trimmed()` site in $(key[2]) any more; remove it from the list"
    end
end

@testset "every exempt entry gives its reason" begin
    for (key, kind) in TRIMMED_SITES
        kind in (:A, :B) && continue
        @test kind isa Tuple && kind[1] === :exempt && kind[2] isa String && !isempty(kind[2]) || key
    end
end

@testset "a comment, a docstring or a quote is not a site; a function body is" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "src"))
        write(joinpath(dir, "src", "sample.jl"), """
            # `_trimmed()` in a comment
            \"\"\"
                described()

            The docstring mentions `_trimmed()` too.
            \"\"\"
            described() = nothing
            redefine() = Core.eval(@__MODULE__, :(_trimmed() = true))
            function refusing(@nospecialize(x))
                _trimmed() && throw(ArgumentError("refused"))
                return x
            end
            @noinline branching(x) = Types._trimmed() ? 1 : x
            Base.show(io::IO, ::Int8) = _trimmed() || print(io)
            """)
        sites = trimmed_sites(dir)
        @test [(s.func, s.line) for s in sites] == [("refusing", 10), ("branching", 13), ("Base.show", 14)]
        @test all(s -> s.file == "src/sample.jl", sites)
    end
end
end

@testitem "juliac: every site that writes a trimmed build's own failure line is listed (#846)" tags=[:core] begin
using Test

# A trimmed executable prints no log record (docs/design/juliac-trim.md §3.16), so the failures
# Nitro catches and logs write one value-free line of their own beside the `@error`, through
# `_trimmed_failure` or `_trimmed_note` (src/routeendpoint.jl). Under the JIT those calls fold
# away, so nothing in a test process would notice one going missing. This pins where they are.

include(joinpath(@__DIR__, ".helpers", "trimmed_sites.jl"))

root = dirname(@__DIR__)
found = Dict{Tuple{Symbol, String, String}, Int}()
for callee in (:_trimmed_failure, :_trimmed_note, :_trimmed_request_failure, :_request_failure_line),
        s in trimmed_sites(root; callee)
    key = (callee, s.file, s.func)
    found[key] = get(found, key, 0) + 1
end

@testset "every call is listed, with its count" begin
    for (key, n) in found
        @test get(TRIMMED_FAILURE_SITES, key, 0) == n ||
              "$(key[2]): $(key[3]) holds $n call(s) to $(key[1]); list it in TRIMMED_FAILURE_SITES"
    end
end

@testset "every listed site still writes its line" begin
    for (key, n) in TRIMMED_FAILURE_SITES
        @test get(found, key, 0) == n ||
              "$(key[2]): $(key[3]) no longer holds $n call(s) to $(key[1]): a trimmed build goes " *
              "silent there; restore the call, or remove the entry on purpose"
    end
end
end

@testitem "juliac: the route a request failure is named by, through a real pipeline (#883)" tags=[:core] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
import Nitro: App, path

# The trimmed child drives the boundary sites with a hand-set `:route` or a hand-built stash, since
# it cannot run a request with `_trimmed()` true. This pins, under the JIT, that a real pipeline
# writes what `_failure_route` reads at each position the error boundary can be reached from: the
# registered pattern (the router's `{id}` spelling), never the target, and nothing before `compose`
# or on a miss.
const T = Nitro.Core.Types
seen = Dict{String, Any}()
record(key) = handle -> function (req::HTTP.Request)
    seen[key * " before"] = T._failure_route(req)
    res = handle(req)
    seen[key * " after"] = T._failure_route(req)
    return res
end
item(req::HTTP.Request, id::Int) = (seen["handler"] = T._failure_route(req); Res.send("ok"))

app = App()
urlpatterns(app, "", path("/items/<int:id>", item; middleware = [record("route")]))

r = internalrequest(app, HTTP.Request("GET", "/items/7?q=S3NT1NEL"); middleware = [record("global")])
@test r.status == 200
@test seen["handler"] == "/items/{id}"          # the terminal's `:route`, as a handler failure sees it
@test seen["route before"] == "/items/{id}"     # the stash, before the terminal ran
@test seen["route after"] == "/items/{id}"
@test seen["global before"] === nothing         # a global layer, before `compose`
@test seen["global after"] == "/items/{id}"

empty!(seen)
r = internalrequest(app, HTTP.Request("GET", "/S3NT1NEL"); middleware = [record("global")])
@test r.status == 404
@test seen["global before"] === nothing
@test seen["global after"] === nothing          # a miss: no route, and never the target
end
