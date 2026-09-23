module Core

using Base: @kwdef
# HTTP.jl v2 newly exports top-level names (`Cookie`, `Form`, `Middleware`, ...) that
# collide with Nitro's. Import qualified-only and pull in just the bare names we rely on.
import HTTP
using HTTP: Router
using Sockets
using JSON
using Base
using Dates
using Reexport
using DataStructures: CircularDeque
using LRUCache: LRU
import Base.Threads: lock, nthreads
import ..has_revise_hooks, ..revise_hooks

include("errors.jl");       @reexport using .Errors
# `Res` loads BEFORE `util.jl`: `Util`'s error formatter builds responses with `Res.json`,
# and `Res` itself depends on nothing in Nitro (HTTP, MIMEs, JSON only).
include("response.jl");     @reexport using .Res
include("util.jl");         @reexport using .Util
include("types.jl");        @reexport using .Types
using .Types: snapshot, DeclaredMethodHandler
include("crypto.jl");       @reexport using .Crypto
include("cookies.jl");      @reexport using .Cookies
include("constants.jl");    @reexport using .Constants
include("environment.jl");  @reexport using .Environment
include("context.jl");      @reexport using .AppContext

function getparams end
function getquery end
function getjson end
function getform end
function getfiles end
function getpost end
function getsession end
function setsession! end
function getuser end
function getip end
function setip! end
function getpeerip end
function getcontext end

include("handlers.jl");     @reexport using .Handlers
include("routerhof.jl");    @reexport using .RouterHOF
using .RouterHOF: normalize_middleware, register_serve_lifecycle!, lifecycle_snapshot
include("reflection.jl");   @reexport using .Reflection
include("extractors.jl");   @reexport using .Extractors
include("middleware.jl");   @reexport using .Middleware
include("routing.jl");      @reexport using .Routing

export serve, terminate,
    internalrequest, staticfiles, dynamicfiles, spafiles,
    getparams, getquery, getjson, getform, getfiles, getpost,
    getsession, setsession!, getuser, getip, setip!, getpeerip, getcontext, payload

# ── Implementation ──────────────────────────────────────────────────────────────
# Split out of this file by responsibility (#32), which left it the thin
# include/export hub it had only partly become. Each file below is included INTO
# `module Core` and defines no module of its own, so every name in them is still a
# `Nitro.Core.<name>` — which is how `src/methods.jl`, `src/precompile.jl` and the
# suite reach `serve`, `internalrequest`, `setupmiddleware`, `_conn_fd` and the
# `REQUEST_*_CACHE_KEY` consts. Wrapping any of them in a submodule breaks that.
#
# They must stay BELOW the submodule includes above, and the forward-declaration
# block above must stay where it is: `src/middleware/*.jl` does
# `using ...Core: getip, getjson, getsession, …` at `include("middleware.jl")` time,
# which is before `core/request.jl` defines those bodies. The stubs are what give
# that `using` something to bind to.
include("core/request.jl")
include("core/transport.jl")
include("core/framework_middleware.jl")
include("core/pipeline.jl")
include("core/lifecycle.jl")
include("core/parambinding.jl")
include("core/registration.jl")
include("core/staticfiles.jl")

end # module Core
