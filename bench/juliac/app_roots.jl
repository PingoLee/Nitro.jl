# #745 step 3: `app.jl`, plus every signature of a traced workload rooted with
# `Base.Experimental.entrypoint`.
#
#   julia bench/juliac/roots.jl <trace.jl> /tmp/app-roots.txt
#   ROOTS_FILE=/tmp/app-roots.txt ENTRY=app_roots bench/juliac/build.sh unsafe-warn
#
# ROOTS_FILE is read while the image is built; without it this is `app.jl` unchanged.
include(joinpath(@__DIR__, "app.jl"))
include(joinpath(@__DIR__, "roots_loader.jl"))
haskey(ENV, "ROOTS_FILE") && load_roots(ENV["ROOTS_FILE"])
