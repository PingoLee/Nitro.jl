# Seed the #744 realapp's database: create `items` if it is missing and top it up to 20 rows, so
# `list` (ids 1–20) and `by_id` (id 1) answer what `measure.sh check` expects. The session and
# worker tables need nothing here: the app's boot creates them (`ensure_table!` in
# NitroPormGExt). Idempotent; re-running it adds rows only while there are fewer than 20.
#
#   PORMG_POSTGRES_DRIVER=Postgres julia +1.13 --project=bench/juliac/realapp bench/juliac/realapp/seed.jl
#
# It reads db/connection.yml (gitignored) exactly as `RealApp.main` does -- REALAPP_ROOT, else
# this directory; `PORMG_ENV`/`NITRO_ENV`, else "dev" -- and prints only row counts. The
# connection must allow `change_db` (to create the table) and `change_data` (to insert).
using RealApp, PormG, Nitro, Postgres

const ROWS = 20

root = get(ENV, "REALAPP_ROOT", @__DIR__)
env = something(sync_pormg_env!(), current_env())
PormG.Configuration.load_many(["db"]; root, env)
PormG.Models.set_models(RealApp.models, joinpath(root, "db"))
Item = RealApp.models.Item

outcome = PormG.Migrations.ensure_table!(Item, "db")
have = Item.objects.count()
for i in (have + 1):ROWS
    Item.objects.create("name" => "item-$i", "category" => "tools", "quantity" => i)
end
println("seed.jl: items table ", outcome, "; ", have, " rows before, ", Item.objects.count(), " after")
