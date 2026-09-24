@testitem "Multiple Apps in one process" tags=[:core, :network] setup=[NitroCommon] begin

using Test
using HTTP
using Nitro
using Nitro.Core.Types: snapshot

# Acceptance test for the public `App` handle (#31). This file is the converted
# `instance_tests.jl`: `instance()` used to be the only way to get two independent Nitro
# apps, and it bought that by `include_string`ing the WHOLE package into a gensym module —
# a full recompile per instance, and broken on any deployment where the source tree is not
# readable at runtime. Every assertion below is the one it made, now expressed against two
# `App` values in a single loaded copy of Nitro.
#
# What this pins, beyond "it runs": the two apps must not share a router. That is the whole
# capability, and it is what the process-wide `CONTEXT[]` singleton cannot give you.

app1 = App(mod = @__MODULE__)
app2 = App(mod = @__MODULE__)

urlpatterns(app1, "",
    path("/", () -> "welcome to server #1"),
    path("/subtract/<int:a>/<int:b>", (req, a::Int, b::Int) -> Dict("answer" => a - b) |> Res.json)
)

urlpatterns(app2, "",
    path("/", () -> "welcome to server #2"),
    path("/add/<int:a>/<int:b>", (req, a::Int, b::Int) -> Dict("answer" => a + b) |> Res.json)
)

# Start both together on their own ports, exactly as the instance() version did.
port1 = get_free_port()
port2 = get_free_port()
serve(app1; port=port1, async=true, show_errors=false, show_banner=false)
serve(app2; port=port2, async=true, show_errors=false, show_banner=false)

try
    @testset "unique apps" begin
        r = internalrequest(app1, HTTP.Request("GET", "/"))
        @test r.status == 200
        @test text(r) == "welcome to server #1"

        r = internalrequest(app2, HTTP.Request("GET", "/"))
        @test r.status == 200
        @test text(r) == "welcome to server #2"
    end

    @testset "add and subtract endpoints" begin
        r = internalrequest(app1, HTTP.Request("GET", "/subtract/10/5"))
        @test r.status == 200
        @test json(r)["answer"] == 5

        r = internalrequest(app2, HTTP.Request("GET", "/add/10/5"))
        @test r.status == 200
        @test json(r)["answer"] == 15

        r = internalrequest(app1, HTTP.Request("GET", "/subtract/5/10"))
        @test r.status == 200
        @test json(r)["answer"] == -5

        r = internalrequest(app2, HTTP.Request("GET", "/add/-10/-5"))
        @test r.status == 200
        @test json(r)["answer"] == -15
    end

    @testset "route tables do not leak between apps" begin
        # The instance() version never asserted this, because separate modules made it true
        # by construction. With one loaded Nitro it is a real claim about `App`, so pin it:
        # each app 404s the other's route.
        @test internalrequest(app1, HTTP.Request("GET", "/add/1/2")).status == 404
        @test internalrequest(app2, HTTP.Request("GET", "/subtract/1/2")).status == 404
    end

    @testset "neither app touched the global singleton" begin
        # The point of the handle: no global mutation.
        #
        # Asserted on a route UNIQUE to this item, not on "/". ReTestItems runs items in
        # alphabetical file order, not `TEST_FILES` order, and `extractor_tests.jl` registers
        # `path("/", …)` on the global context without resetting — so a "/" assertion here is
        # green only because `app_tests` sorts first, and would flip on a rename.
        @test internalrequest(HTTP.Request("GET", "/subtract/1/2")).status == 404
        @test internalrequest(HTTP.Request("GET", "/add/1/2")).status == 404
    end

    @testset "an App does not leak secrets when displayed" begin
        # `App` is public now, so it reaches REPL auto-display and interpolated log lines. Its
        # `service` holds the cookie config, whose `secret_key` is the FIRST positional field —
        # so the default field-walking `show` prints it verbatim. (That is not hypothetical: it
        # is what `@show Nitro.CONTEXT[]` did before this type had a `show`.)
        #
        # The assertion has to name the literal secret. `!occursin("secret_key", …)` does NOT
        # discriminate — Julia's default `show` prints field VALUES, not names, so that form
        # passes with the override deleted. Verified before rewriting it.
        cookie_key = "SUPERSECRET_COOKIE_KEY_9f2a_012345"
        secret = "SUPERSECRET_CANARY_9f2a"
        leaky = App(mod = @__MODULE__)
        configcookies(leaky; secret_key = cookie_key)
        # A route middleware closing over a raw secret -- the shape an app's own auth layer has.
        canary_mw = let s = secret
            handle -> (req -> (length(s); handle(req)))
        end
        urlpatterns(leaky, "", path("/canary", req -> "ok"; middleware = [canary_mw]))

        shown = sprint(show, leaky)
        @test occursin("App(", shown)
        @test !occursin(secret, shown)
        @test !occursin(cookie_key, shown)
        @test !occursin("Service", shown)

        default_shown = sprint(io -> invoke(Base.show, Tuple{IO,Any}, io, leaky))
        # The default path really would have leaked the middleware's capture, so the override is
        # load-bearing. This used to be proven with the COOKIE key, which no longer leaks even
        # there: since #307 the key is held as a `SecretString`, so the default field-walking
        # `show` prints it masked. Hence two canaries, asserted both ways.
        @test occursin(secret, default_shown)
        @test !occursin(cookie_key, default_shown)
    end
    @testset "every (app, …) forward reaches the app, not the global" begin
        # The forwards are one-liners, which is exactly why they need this: a typo swapping
        # `app` for `CONTEXT[]` compiles, passes every other test, and silently operates on
        # the wrong app. Each assertion below distinguishes the two.

        # `url` — resolves a named route from THIS app's table.
        urlpatterns(app1, "", path("/named/<int:id>", (req, id::Int) -> "ok", name = "named"))
        @test url(app1, "named"; id = 7) == "/named/7"
        # The global has no such name, so the singleton form must fail rather than agree.
        @test_throws ArgumentError url("named"; id = 7)

        # `getexternalurl` — reads this app's listener, and app1 IS serving.
        @test getexternalurl(app1) == "http://$HOST:$port1"
        @test getexternalurl(app2) == "http://$HOST:$port2"

        # `configcookies` / `get_cookie` / `set_cookie!` — the cookie config must be per-app.
        configcookies(app1; secret_key = "app1-secret-000000000000000000000")
        configcookies(app2; secret_key = "app2-secret-111111111111111111111")
        @test app1.service.cookies[].secret_key != app2.service.cookies[].secret_key

        res = Nitro.Response(200, [], "")
        set_cookie!(app1, res, "sid", "payload-app1")
        raw = join([v for (k, v) in res.headers if lowercase(k) == "set-cookie"], ";")
        @test !occursin("payload-app1", raw)          # encrypted under app1's key

        req = Nitro.Request("GET", "/", ["Cookie" => split(raw, ';')[1]])
        @test get_cookie(app1, req, "sid") == "payload-app1"
        # app2 has a different key, so it must not be able to read app1's cookie. Since #309 a
        # token that does not open under the key reads as ABSENT -- the default, `nothing` --
        # rather than raising, so this asserts the value. It still discriminates a swap to
        # `CONTEXT[]`: the global has no key, so it would hand back the raw token, not `nothing`.
        @test get_cookie(app2, req, "sid") === nothing

        # `router` — the HOF route builder; protocol is `router(app, prefix)(path)(method)`.
        #
        # Asserting on the returned STRING would not discriminate: with no middleware the
        # composed route is prefix+path regardless of which app you pass. What the app
        # actually owns is the route-level middleware registration, so assert that.
        mw = handle -> (req -> handle(req))
        hof_route = router(app1, "/hof"; middleware = [mw])("/only-app1")("GET")
        key = Nitro.Core.RouterHOF.genkey("GET", hof_route)
        @test haskey(snapshot(app1.service.custommiddleware), key)
        @test !haskey(snapshot(Nitro.CONTEXT[].service.custommiddleware), key)

        # `staticfiles` / `spafiles` / `dynamicfiles` — mount into THIS app's router.
        mountdir = mktempdir()
        write(joinpath(mountdir, "index.html"), "<p>app1 only</p>")
        staticfiles(app1, mountdir, "app1-assets")
        @test internalrequest(app1, HTTP.Request("GET", "/app1-assets/index.html")).status == 200
        # app2 never mounted it, and neither did the global.
        @test internalrequest(app2, HTTP.Request("GET", "/app1-assets/index.html")).status == 404
        @test internalrequest(HTTP.Request("GET", "/app1-assets/index.html")).status == 404

        dynamicfiles(app2, mountdir, "dyn")
        @test internalrequest(app2, HTTP.Request("GET", "/dyn/index.html")).status == 200
        @test internalrequest(app1, HTTP.Request("GET", "/dyn/index.html")).status == 404

        spa = mktempdir()
        write(joinpath(spa, "index.html"), "<p>spa</p>")
        spafiles(app2, spa, "spa")
        @test internalrequest(app2, HTTP.Request("GET", "/spa/index.html")).status == 200

        # `worker_startup` returns LIFECYCLE MIDDLEWARE for the `serve(middleware = [...])`
        # list -- it does not install a store by itself; `Workers.start!` does that. Both are
        # asserted, because the distinction is exactly what the UPGRADING caveat turns on:
        # an app with no store installed falls back to the process-wide default.
        @test Nitro.Workers.worker_store(app1) === nothing
        lm = worker_startup(app1; queues = String[], cleanup_enabled = false, recover_zombies = false)
        @test lm isa Nitro.Core.Types.LifecycleMiddleware

        # Firing the hook is what `serve(middleware = [...])` does; the return type alone is
        # `LifecycleMiddleware` whichever app the closure captured, so it proves nothing.
        lm.on_startup()
        @test Nitro.Workers.worker_store(app1) !== nothing
        @test Nitro.Workers.worker_store(Nitro.CONTEXT[]) === nothing
        @test Nitro.Workers.worker_store(app2) === nothing
        lm.on_shutdown()
    end
finally
    terminate(app1)
    terminate(app2)
end

end
