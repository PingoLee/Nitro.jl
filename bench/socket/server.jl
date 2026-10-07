# Socket-level throughput target (#448, #453). Unlike the rest of `bench/`, which drives the
# pipeline in-process through `internalrequest`, this serves over a real loopback socket so the
# transport layer -- the per-request spawn, the request build, the response write and HTTP.jl's
# connection loop -- is part of what is measured. `run.sh` drives it with `oha`.
#
#   MODE=nitro          Nitro `serve()` with no middleware (the default).
#   MODE=nitro_log      The same with `access_log = true`, `serve()`'s own default (#443), so the
#                       log's cost can be A/B'd against `nitro` in one interleaved run.
#   MODE=bare_spawn     HTTP.jl `listen!` + `streamhandler`, one `Threads.@spawn` per request:
#                       the shape Nitro's `parallel_stream_handler` takes, and the ceiling to
#                       compare it against.
#   MODE=bare_nospawn   The same without the spawn: the handler runs on HTTP.jl's connection task.
#
#   PORT=8080           Loopback port.
#   ACCESS_LOG=0|1      Nitro only: `serve(access_log = …)`. Default 0.
#   PROFILE=<seconds>   After WARMUP seconds, sample every thread for this long and write flat and
#                       per-thread reports under bench/results/. 0 (the default) disables it.
#   WARMUP=<seconds>    Delay before the profile window opens. Default 8.
#   PRELOAD="Pkg ..."   Load these packages before serving, so `rss.sh` can measure what one adds
#                       to the process (PRELOAD=PormG also loads NitroPormGExt). The project
#                       passed to `--project` must have them; the bench env does not.
#
# Run with `julia --project=bench -t 8 bench/socket/server.jl`. Every mode answers the same three
# routes with the same bodies, so the stacks differ only in what serves them.

using HTTP
using JSON

const MODE       = get(ENV, "MODE", "nitro")

# Only where it is used, so a `bare_*` process has no Nitro in it at all: `rss.sh` reports that
# mode as the HTTP.jl-only floor (#451), and a loaded-but-idle Nitro would be counted in it.
MODE in ("nitro", "nitro_log") && @eval using Nitro

const PORT      = parse(Int, get(ENV, "PORT", "8080"))
const ACCESS_LOG = get(ENV, "ACCESS_LOG", "0") == "1" || MODE == "nitro_log"
const PROFILE_S  = parse(Float64, get(ENV, "PROFILE", "0"))
const WARMUP_S   = parse(Float64, get(ENV, "WARMUP", "8"))

for pkg in split(get(ENV, "PRELOAD", ""))
    @eval using $(Symbol(pkg))
end

const PLAINTEXT = "Hello, World!"
json_body() = JSON.json(Dict("message" => "Hello, World!"))

function bare_handler(req::HTTP.Request)::HTTP.Response
    target = req.target
    target == "/plaintext" && return HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8"], PLAINTEXT)
    target == "/json"      && return HTTP.Response(200, ["Content-Type" => "application/json"], json_body())
    target == "/health"    && return HTTP.Response(200, "ok")
    return HTTP.Response(404)
end

function start_bare(spawn::Bool)
    inner = HTTP.streamhandler(bare_handler)
    handler = spawn ? (stream -> wait(Threads.@spawn inner(stream))) : inner
    return HTTP.listen!(handler, "127.0.0.1", PORT)
end

function start_nitro()
    app = App()
    urlpatterns(app, "",
        path("/plaintext", req -> Res.send(PLAINTEXT); method = "GET"),
        path("/json",      req -> Res.send(json_body(); content_type = "application/json"); method = "GET"),
        path("/health",    req -> Res.send("ok"); method = "GET"),
    )
    serve(app; host = "127.0.0.1", port = PORT, async = true, show_banner = false,
          access_log = ACCESS_LOG)
    return app
end

# Profile is not in Julia's system image (~13 MiB resident once loaded), so it loads only when
# profiling: `rss.sh` must not count it. The function is evaluated after the `using`, not defined
# at top level, because `Profile.@profile` needs the module when the macro expands.
PROFILE_S > 0 && @eval using Profile
PROFILE_S > 0 && @eval function profile_window()
    sleep(WARMUP_S)
    Profile.init(n = 10^7, delay = 0.001)
    Profile.clear()
    @info "bench: profiling every thread for $(PROFILE_S) s"
    Profile.@profile sleep(PROFILE_S)
    dir = joinpath(@__DIR__, "..", "results")
    mkpath(dir)
    stem = joinpath(dir, "profile-$(MODE)-$(round(Int, time()))")
    open("$stem-flat.txt", "w") do io
        Profile.print(IOContext(io, :displaysize => (10_000, 400)); format = :flat,
                      sortedby = :count, mincount = 20)
    end
    open("$stem-threads.txt", "w") do io
        Profile.print(IOContext(io, :displaysize => (10_000, 400)); format = :flat,
                      sortedby = :count, groupby = :thread, mincount = 20)
    end
    @info "bench: profile written" stem
end

handle = MODE in ("nitro", "nitro_log") ? start_nitro() :
         MODE == "bare_spawn"   ? start_bare(true) :
         MODE == "bare_nospawn" ? start_bare(false) :
         error("unknown MODE=$(MODE): expected nitro, nitro_log, bare_spawn or bare_nospawn")

@info "bench: serving" MODE PORT threads = Threads.nthreads() interactive = Threads.nthreads(:interactive)
PROFILE_S > 0 && Threads.@spawn profile_window()

# Block until killed. A `Timer` keeps an idle task parked so the process stays up and a SIGTERM
# from `run.sh` ends it cleanly.
wait(Timer(typemax(Int32)))
