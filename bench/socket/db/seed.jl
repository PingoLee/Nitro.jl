# Create and fill the `world` table the #589 routes read (`world.jl`): WORLD_ROWS rows
# `(id INT PRIMARY KEY, randomnumber INT)`, ids 1..WORLD_ROWS. The table is dropped and rebuilt,
# so run it only against a throwaway database. The rows go in through PormG's model layer
# (`bulk_insert` on the model's handler), as an application would write them; only the DDL is
# raw SQL, because PormG's migrations need a models folder and this bench has a single table.
#
#   DB=postgres julia --project=bench/socket/db bench/socket/db/seed.jl
#   DB=sqlite   julia --project=bench/socket/db bench/socket/db/seed.jl
#
# The backend and the connection come from the same variables `world.jl` reads.
using PormG, DataFrames, HTTP, JSON
get(ENV, "DB", "postgres") == "sqlite" ? (@eval using SQLite) : (@eval using LibPQ)

include(joinpath(@__DIR__, "world.jl"))

settings = PormG.config[DB_KEY]
PormG.fetch(settings, "DROP TABLE IF EXISTS world")
PormG.fetch(settings, "CREATE TABLE world (id INTEGER PRIMARY KEY, randomnumber INTEGER NOT NULL)")
rows = DataFrame(id = 1:WORLD_ROWS, randomnumber = rand(1:WORLD_ROWS, WORLD_ROWS))
inserted = PormG.bulk_insert(world(), rows).count
inserted == WORLD_ROWS || error("seed: inserted $inserted rows, expected $WORLD_ROWS")
counted = world().count()
counted == WORLD_ROWS || error("seed: the table holds $counted rows, expected $WORLD_ROWS")
DB_BACKEND == "postgres" && PormG.fetch(settings, "VACUUM ANALYZE world")
@info "seed: world ready" backend = DB_BACKEND rows = counted
