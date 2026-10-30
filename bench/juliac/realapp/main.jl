# The #744 realapp's entry: the JuliaC entry file, and the JIT baseline when run as a script
# (`julia +1.13 --project=bench/juliac/realapp bench/juliac/realapp/main.jl`). Everything the app
# needs at run time comes from ENV (PORT, API_SECRET_KEY, JWT_SECRET, PORMG_POSTGRES_DRIVER) and
# db/connection.yml (gitignored): nothing secret is read while the image is built.
using RealApp

function (@main)(args::Vector{String})::Cint
    RealApp.main(; host = "127.0.0.1", async = false)
    return Cint(0)
end
