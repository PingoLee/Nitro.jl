"""
    ReportHost

A host application that mounts the reusable [`ReportKit`](@ref) package under
`/api/reports`. The host owns everything that runs: the worker runtime and its queue, the
store, and the authentication that decides whose report is whose.
"""
module ReportHost

using HTTP
using Nitro
using Nitro.Workers: InMemoryWorkerStore
using ReportKit

# The module body holds only `using`s, definitions and the App const: a module body runs at
# precompile time and never again, so nothing here reads the environment, registers a job or
# starts a worker.
const app = App(mod = @__MODULE__)

const QUEUE = "reports"

"""
    token_auth(tokens::Vector{Pair{SecretString,String}})

`BearerAuth` over a fixed list of API tokens, each mapped to the user id it signs in as, which is
what `getuser(req)` then returns. Enough to give every report an owner; a real app would put the
token middleware from `examples/auth_package` here instead. That one stores a dict at `getuser`,
so `urls` would pass `user_of = req -> getuser(req)["id"]` with it. `==` on a `SecretString` is
constant-time, so a wrong token does not leak how much of it matched.
"""
function token_auth(tokens::Vector{Pair{SecretString,String}})
    any(isempty(reveal(secret)) for (secret, _) in tokens) &&
        throw(ArgumentError("token_auth: a token must not be empty"))
    return BearerAuth() do token
        for (secret, user) in tokens
            secret == token && return user
        end
        return nothing
    end
end

health(req::HTTP.Request) = Res.json(Dict("status" => "ok"))

"""
    urls(tokens) -> Vector{RouteDefinition}

The host's whole URL table: `/health`, and ReportKit under `/api/reports` behind
[`token_auth`](@ref). ReportKit learns who is asking through `user_of = getuser`, which reads what
the token middleware resolved. A function rather than a constant, so a test can mount the same
table on an `App` of its own.
"""
function urls(app::App, tokens::Vector{Pair{SecretString,String}})
    reports = ReportKit.routes(app; queue = QUEUE, user_of = getuser, prefix = "/reports")
    return vcat(
        [path("/health", health; method = "GET", name = "health")],
        include_routes("/api", reports; middleware = [token_auth(tokens)]),
    )
end

"""
    main(; kwargs...)

Register ReportKit's job, start the worker runtime, register the routes and serve. Reads
`PORT` (default 8000) and the demo tokens `ALICE_TOKEN` and `BOB_TOKEN`; keyword arguments go
to `serve` (tests pass `async = true`).
"""
function main(; kwargs...)
    tokens = [SecretString(ENV["ALICE_TOKEN"]) => "alice", SecretString(ENV["BOB_TOKEN"]) => "bob"]
    ReportKit.register_jobs!(app)
    # Built once and passed to `serve`: it installs the runtime now and starts the queue's
    # processor when the server starts. An in-memory store loses its tasks on restart; a
    # persistent one, such as PormG's `pormg_nitro_worker(db_key = "db")`, keeps them.
    workers = worker_startup(app; queues = [QUEUE], store = InMemoryWorkerStore())
    urlpatterns(app, "", urls(app, tokens))
    serve(app; port = parse(Int, get(ENV, "PORT", "8000")), middleware = [workers], kwargs...)
end

end # module
