# Write the JSON body `stall.sh`'s `route:/hold/json_typed@<file>` variant sends (#588): the rows
# payload `suite/holds.jl` parses in `json_typed_10mb` -- `{"rows":[{"id","label","value"}…]}` at
# ROWS rows (default 250,000, ~12.1 MB). Writes `application/json` to `<path>.ct`, where
# `stall.sh` reads the body's Content-Type.
#
#   julia --project=bench bench/socket/rows_body.jl bench/results/rows-10mb.json [rows]
using JSON
path = ARGS[1]
n = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 250_000
write(path, JSON.json(Dict("rows" => [Dict("id" => i, "label" => "row-$i", "value" => i * 1.5) for i in 1:n])))
write(path * ".ct", "application/json\n")
println(filesize(path), " bytes")
