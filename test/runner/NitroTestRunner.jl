# NitroTestRunner -- the suite's own `@testitem` runner (#754).
#
# It accepts the `@testitem "name" tags=[...] setup=[...] begin ... end` and
# `@testsetup module Name ... end` syntax ReTestItems defined, unchanged, and implements only
# what this suite uses:
#
#   collect.jl   parse files into items and setups; refuse anything it would not run faithfully
#   execute.jl   run items sequentially, each in a fresh module and its own `@testset`, with
#                captured output
#   watchdog.jl  the parent: one child process for the whole run, and a per-item timeout
#
# `test/runtests.jl` is the entry point and documents the CLI. This is test infrastructure: it
# depends on `Test`, `Random` and `harness_manifest.jl` only, and nothing in `src/` may load it.
#
# Deliberately NOT here:
#   * parallel items -- decided on #755: processes side by side would share ports, pkgimages
#     and the temp directory, and the allocation and warmth probes need a quiet machine. The
#     `--workers` refusal in `test/runtests.jl` records it.
#   * retries -- a retried item is a flake nobody files.
#   * a process per item -- a package load per item, and the compile-state probes measure what
#     the items before them left compiled, which is the run that was asked for.
#   * a restart after a timeout -- for the same reason: the items after a hung one would run in
#     a fresh process, which is not the run that was asked for.

module NitroTestRunner

using Test
using Random

include(joinpath(@__DIR__, "..", "harness_manifest.jl"))
using .NitroTestHarness

include("collect.jl")
include("execute.jl")
include("watchdog.jl")

end # module NitroTestRunner
