# #745 step 5: `main.jl`, plus every signature of a traced workload rooted with
# `Base.Experimental.entrypoint`.
#
#   julia bench/juliac/roots.jl <trace.jl> /tmp/realapp-roots.txt
#   ROOTS_FILE=/tmp/realapp-roots.txt ENTRY=main_roots bench/juliac/realapp/build.sh unsafe-warn
#
# ROOTS_FILE is read while the image is built; without it this is `main.jl` unchanged.
include(joinpath(@__DIR__, "main.jl"))
include(joinpath(@__DIR__, "..", "roots_loader.jl"))
haskey(ENV, "ROOTS_FILE") && load_roots(ENV["ROOTS_FILE"])
