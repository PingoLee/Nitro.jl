# The database routes of #589, through PormG's model layer: `server.jl` includes this file only
# when PormG is loaded (`PRELOAD="PormG LibPQ"` or `PRELOAD="PormG SQLite"`, which `run.sh` and
# `stall.sh` set from `DB=postgres|sqlite`), so the plain bench env, which carries no PormG,
# never sees it. The env that does is `bench/socket/db/Project.toml`.
#
# TechEmpower's shapes, on a `world` table of WORLD_ROWS rows `(id, randomnumber)` written by
# `seed.jl`:
#
#   /db              one primary-key lookup by a random id, as JSON
#   /queries?n=20    n lookups, one after another in the handler (n clamped to 1..500)
#   /updates?n=20    the same n lookups, then an UPDATE per row, all in one transaction. The ids
#                    are distinct and sorted, so two concurrent transactions lock rows in the same
#                    order and cannot deadlock.
#   /db_wait?ms=200  `SELECT pg_sleep(ms / 1000)` through PormG's `fetch`: a statement that waits
#                    and does no work (#589's H2 probe). PostgreSQL only.
#
#   DB=postgres|sqlite   The backend. Default postgres.
#   DB_POOL=<n>          PormG's `pool_size` (default 32). PormG grows a pool lazily up to
#                        `pool_size * 10` connections; the Go server mirrors both numbers.
#   DB_CONNINFO_FILE     A file holding the PostgreSQL libpq conninfo (it carries the password, so
#                        it is gitignored and never printed). Default `bench/socket/db/conninfo`.
#   DB_SQLITE            The SQLite file. Default `bench/socket/db/world.sqlite`.

const DB_KEY      = "bench_world"
const DB_BACKEND  = get(ENV, "DB", "postgres")
const DB_POOL     = parse(Int, get(ENV, "DB_POOL", "32"))
const WORLD_ROWS  = 10_000
const MAX_QUERIES = 500

DB_BACKEND in ("postgres", "sqlite") || error("DB=$(DB_BACKEND): expected postgres or sqlite")

db_conninfo() = String(strip(read(get(ENV, "DB_CONNINFO_FILE", joinpath(@__DIR__, "conninfo")), String)))
db_sqlite_path() = get(ENV, "DB_SQLITE", joinpath(@__DIR__, "world.sqlite"))

# Registers the connection and returns the `world` model bound to it, the way NitroPormGExt binds
# its own models (`connect_key`, no `set_models`).
function db_connect!()
    if DB_BACKEND == "postgres"
        PormG.Configuration.register_connection(DB_KEY, db_conninfo(); pool_size = DB_POOL)
    else
        PormG.Configuration.register_connection(DB_KEY, db_sqlite_path(); adapter = "SQLite",
                                                pool_size = DB_POOL)
    end
    PormG.config[DB_KEY].change_data = true
    model = PormG.Models.Model("world",
        id           = PormG.Models.IDField(),
        randomnumber = PormG.Models.IntegerField(),
    )
    model.connect_key = DB_KEY
    return model
end

const WORLD = db_connect!()

world() = WORLD.objects.db(DB_KEY)

# What the server says about the database at startup, for the tables (#589 asks for the version,
# `max_connections` and the pool size beside every one). Never the conninfo.
function db_describe()
    if DB_BACKEND == "postgres"
        ver = PormG.fetch(PormG.config[DB_KEY], "SHOW server_version")
        mc = PormG.fetch(PormG.config[DB_KEY], "SHOW max_connections")
        @info "bench: database" backend = DB_BACKEND pool_size = DB_POOL ceiling = DB_POOL * 10 server_version = only(ver).server_version max_connections = only(mc).max_connections
    else
        @info "bench: database" backend = DB_BACKEND pool_size = DB_POOL file = basename(db_sqlite_path())
    end
end

random_id() = rand(1:WORLD_ROWS)

function write_row(io::IO, id::Integer, randomnumber::Integer)
    print(io, "{\"id\":", id, ",\"randomnumber\":", randomnumber, '}')
end

function db_body()::String
    row = world().get("id" => random_id())
    io = IOBuffer()
    write_row(io, row.id, row.randomnumber)
    return String(take!(io))
end

# `n` from the query string, TechEmpower's way: missing or not a number is 1, and it is clamped
# to 1..MAX_QUERIES.
function query_count(s)::Int
    n = s === nothing ? nothing : tryparse(Int, s)
    return n === nothing ? 1 : clamp(n, 1, MAX_QUERIES)
end

function queries_body(n::Int)::String
    io = IOBuffer()
    write(io, '[')
    for i in 1:n
        row = world().get("id" => random_id())
        i > 1 && write(io, ',')
        write_row(io, row.id, row.randomnumber)
    end
    write(io, ']')
    return String(take!(io))
end

function distinct_ids(n::Int)::Vector{Int}
    ids = Set{Int}()
    while length(ids) < n
        push!(ids, random_id())
    end
    return sort!(collect(ids))
end

function updates_body(n::Int)::String
    ids = distinct_ids(n)
    fresh = rand(1:WORLD_ROWS, n)
    PormG.run_in_transaction(DB_KEY) do
        for id in ids
            world().get("id" => id)
        end
        for (id, r) in zip(ids, fresh)
            world().filter("id" => id).update("randomnumber" => r)
        end
    end
    io = IOBuffer()
    write(io, '[')
    for (i, (id, r)) in enumerate(zip(ids, fresh))
        i > 1 && write(io, ',')
        write_row(io, id, r)
    end
    write(io, ']')
    return String(take!(io))
end

# `ms` clamped to 1..10_000; `nothing` when it is not a number.
function wait_ms(s)::Union{Nothing, Int}
    ms = s === nothing ? nothing : tryparse(Int, s)
    return ms === nothing ? nothing : clamp(ms, 1, 10_000)
end

function db_wait_body(ms::Int)::String
    PormG.fetch(PormG.config[DB_KEY], string("SELECT pg_sleep(", ms / 1000, ")"))
    return string("{\"ms\":", ms, '}')
end

# The routes as (status, body) from a path and a query lookup, shared by the Nitro and bare modes
# so both run the same calls. `nothing` when `path` is not a database route.
function db_dispatch(path::AbstractString, q)::Union{Nothing, Tuple{Int, String}}
    path == "/db"      && return (200, db_body())
    path == "/queries" && return (200, queries_body(query_count(q("n"))))
    path == "/updates" && return (200, updates_body(query_count(q("n"))))
    if path == "/db_wait"
        DB_BACKEND == "postgres" || return (400, "db_wait needs DB=postgres")
        ms = wait_ms(q("ms"))
        ms === nothing && return (400, "bad ms")
        return (200, db_wait_body(ms))
    end
    return nothing
end

# Nitro: one route per path, the query through `getquery`, as an app reads it.
function db_routes!(app)
    handler_for(p) = function (req)
        query = Nitro.getquery(req)
        status, body = db_dispatch(p, k -> get(query, k, nothing))::Tuple{Int, String}
        return status == 200 ? Res.send(body; content_type = "application/json") :
                               Res.send(body; status = status)
    end
    urlpatterns(app, "", (path(p, handler_for(p); method = "GET") for p in ("/db", "/queries", "/updates", "/db_wait"))...)
    return app
end

# bare_*: the same dispatch from the raw target.
function db_bare(target::AbstractString)::Union{Nothing, HTTP.Response}
    uri = HTTP.URIs.URI(target)
    p = uri.path
    p in ("/db", "/queries", "/updates", "/db_wait") || return nothing
    query = HTTP.URIs.queryparams(uri)
    status, body = db_dispatch(p, k -> get(query, k, nothing))::Tuple{Int, String}
    return status == 200 ? HTTP.Response(200, ["Content-Type" => "application/json"], body) :
                           HTTP.Response(status, body)
end

db_describe()
