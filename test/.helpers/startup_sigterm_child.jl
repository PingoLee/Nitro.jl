# The child for test/serve_startup_sigterm_tests.jl (#824): a served app whose one startup hook
# compiles new methods for up to 60 s, the way a first boot sweep compiles its store's queries.
# The hook writes the thread it runs on to `<outdir>/started`; the parent sends SIGTERM once it
# has, and times the exit.
using Nitro, Sockets

const OUT = ARGS[1]

function churn()
    # Written aside and moved into place, so the parent never reads a created but empty file.
    write(joinpath(OUT, "started.tmp"), string(Threads.threadpool(Threads.threadid())))
    mv(joinpath(OUT, "started.tmp"), joinpath(OUT, "started"))
    t0 = time()
    i = 0
    while time() - t0 < 60
        i += 1
        # A large body, so most of each pass is LLVM codegen rather than lowering.
        body = [:(x = x * $(k + i) + (x >> 3) ⊻ $k) for k in 1:400]
        f = Core.eval(Main, :(function (x::Int) $(body...); x end))
        Base.invokelatest(f, i)
    end
    return nothing
end

server = Sockets.listen(Sockets.localhost, 0)
port = Int(Sockets.getsockname(server)[2])
close(server)

app = App(mod = Main)
urlpatterns(app, "", [path("/", (req) -> "ok")])
serve(app; port, show_banner = false, access_log = nothing,
      middleware = [Nitro.LifecycleMiddleware(middleware = identity, on_startup = churn)])
