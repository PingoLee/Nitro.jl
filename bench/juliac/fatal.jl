# A start-up failure with secrets in reach (#749, #750, #752), built with `ENTRY=fatal`. In a juliac
# executable, trimmed or not, an exception that escapes `main` is printed by `jl_static_show`, which
# walks raw fields and calls no `show` method, so `SecretString`'s mask does not apply. This entry
# fails on purpose while its exception reaches a CSRF secret, a JWT keyset and a closure-captured
# key, and `fatal_check.sh` greps its `stderr` for each of them.
#
# `FAIL`, read at run time, picks where it fails:
#   serve -- inside `serve`: the outermost global middleware throws while the chain is folded,
#            with the chain in a field. Nothing in `main` catches it; Nitro's `serve` must, in a
#            trimmed and an untrimmed executable alike (#752).
#   boot  -- before `serve`, in the app's own bootstrap, inside the `@main` recipe
#            docs/src/tutorial/deployment.md gives.
#   wrapped -- the `serve` failure inside the recipe: what an app that follows the docs prints
#            when `serve` fails.
#   bare  -- the same failure as `boot` with no recipe. It leaks in a trimmed image, and is here to
#            say so: what never reaches Nitro's frames is the app's to catch.
# Anything else serves normally on PORT.
#
# Routes are registered at TOP LEVEL, as in `app.jl`, so they are values in the image.
# `FATAL_ROUTES=0`, read while the image is built, registers none: a trimmed image then exports no
# route endpoint, so `Types._trimmed()` stays `false` there (#752).
using Nitro

# Test-only sentinels. `fatal_check.sh` greps for each one; none is ever printed on purpose.
const CSRF_SECRET = "fatal-probe-csrf-secret-SENTINEL-0001"
const JWT_SECRET = "fatal-probe-jwt-secret-SENTINEL-0002"
const API_KEY = "fatal-probe-api-key-SENTINEL-0003"

const app = App()
get(ENV, "FATAL_ROUTES", "1") == "0" ||
    urlpatterns(app, "", path("/plaintext", req -> Res.send("Hello, World!"); method = "GET"))

# An application's own middleware, in the documented shape, holding a key in its closure.
keyed(key::String) = handler -> (req -> (isempty(key) ? Res.status(500) : handler(req)))

# What the failure carries: the value it was handed, the way a `MethodError` carries its arguments.
struct StartupFailed{T} <: Exception
    value::T
end

# Folded outermost (the first global layer wraps all the rest), so the chain it is handed holds
# every layer below it, secrets included.
fail_on_fold(handler) = throw(StartupFailed(handler))

const MIDDLEWARE = (
    SessionMiddleware(store = MemoryStore()),
    CSRFMiddleware(CSRF_SECRET),
    BearerAuth(Nitro.Auth.jwt_validator(JWT_SECRET)),
    keyed(API_KEY),
)

serve_app(middleware) = serve(app; host = "127.0.0.1", port = parse(Int, get(ENV, "PORT", "8080")),
                              async = false, show_banner = false, access_log = false, middleware)

# The app's own bootstrap: load config, resolve secrets, run initializers. Here it only fails.
boot() = throw(StartupFailed(MIDDLEWARE))

# The recipe from docs/src/tutorial/deployment.md: a value-free line on `Core.stderr`, then a
# non-zero exit.
function recipe(start::F)::Cint where {F}
    try
        start()
    catch e
        e isa InterruptException && rethrow()
        println(Core.stderr, "start-up failed: ", Nitro.startup_failure_text(e))
        return Cint(1)
    end
    return Cint(0)
end

function (@main)(args::Vector{String})::Cint
    mode = get(ENV, "FAIL", "")
    mode == "serve" && serve_app((fail_on_fold, MIDDLEWARE...))
    mode == "boot" && return recipe(() -> (boot(); serve_app(MIDDLEWARE)))
    mode == "wrapped" && return recipe(() -> serve_app((fail_on_fold, MIDDLEWARE...)))
    mode == "bare" && boot()
    serve_app(MIDDLEWARE)
    return Cint(0)
end
