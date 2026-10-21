"""
    AuthHost

A host application that mounts the reusable [`AuthKit`](@ref) package under `/auth` and guards
one route of its own with it. The host owns the user table and the signing key; AuthKit owns
the login flow and the token checks.
"""
module AuthHost

using HTTP
using Nitro
using AuthKit

# The module body holds only `using`s, definitions and the App const: a module body runs at
# precompile time and never again, so nothing here reads the environment or registers a route.
const app = App(mod = @__MODULE__)

"""
    Users(accounts)

The host's user table, built once at boot and only read afterwards, which is what makes the
two lookups safe to call from many request threads at once. A real app would query its
database here instead.
"""
struct Users
    by_username::Dict{String,Account}
    by_id::Dict{String,Account}
end
Users(accounts::Vector{Account}) =
    Users(Dict(a.username => a for a in accounts), Dict(a.id => a for a in accounts))

health(req::HTTP.Request) = Res.json(Dict("status" => "ok"))

# AuthKit's middleware already ran, so the handler reads what it resolved. `getuser` is the
# account as the user table holds it now, and `Claims{TokenClaims}` is the verified token,
# bound into a struct before the handler runs.
function report(req::HTTP.Request, token::Claims{TokenClaims})
    user = getuser(req)
    return Res.json(Dict("report" => "monthly totals",
                         "requested_by" => user["username"],
                         "token_subject" => token.payload.sub))
end

"""
    urls(config::AuthConfig) -> Vector{RouteDefinition}

The host's whole URL table: `/health`, AuthKit under `/auth`, and `/admin/report`, which
needs a token whose account currently has the `"admin"` role. A function rather than a
constant, so a test can mount the same table on an `App` of its own.
"""
function urls(config::AuthConfig)
    admin_only = [TokenAuth(config = config), GuardMiddleware(role_required("admin"))]
    return vcat(
        [path("/health", health; method = "GET", name = "health")],
        routes(config; prefix = "/auth"),
        [path("/admin/report", report; method = "GET", name = "admin.report",
              middleware = admin_only)],
    )
end

"""
    demo_users(; admin_password, member_password) -> Users

Two accounts to try the example with: `alice` (role `"admin"`) and `bob` (role `"member"`).
"""
demo_users(; admin_password::AbstractString, member_password::AbstractString) = Users([
    Account("1", "alice", Auth.make_password(admin_password), "admin"),
    Account("2", "bob", Auth.make_password(member_password), "member"),
])

"""
    main(; kwargs...)

Build the user table and the auth config, register the routes and serve. Reads `PORT`
(default 8000), `AUTH_JWT_SECRET` (at least 32 bytes) and the demo passwords
`ADMIN_PASSWORD` and `MEMBER_PASSWORD`; keyword arguments go to `serve` (tests pass
`async = true`).
"""
function main(; kwargs...)
    users = demo_users(admin_password = ENV["ADMIN_PASSWORD"], member_password = ENV["MEMBER_PASSWORD"])
    config = AuthConfig(secret = ENV["AUTH_JWT_SECRET"],
                        find_by_username = name -> get(users.by_username, name, nothing),
                        find_by_id = id -> get(users.by_id, id, nothing))
    urlpatterns(app, "", urls(config))
    serve(app; port = parse(Int, get(ENV, "PORT", "8000")), kwargs...)
end

end # module
