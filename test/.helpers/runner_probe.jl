# Drives `test/runner/` against a synthetic test tree, for `test/runner_tests.jl`.
#
#   julia runner_probe.jl <dir>                         run every test file under <dir>
#   julia runner_probe.jl <dir> --watch <timeout>       the same, under the watchdog
#   julia runner_probe.jl <dir> --test-end-throws       with a TEST_END that throws
#   julia runner_probe.jl <dir> --shuffle <seed>        in the order `--shuffle <seed>` gives
#
# Loads only `Test`, never Nitro, so a probe costs a julia start-up and little else. Lives under
# `test/.helpers/` so test discovery prunes it (dot-directory).

include(joinpath(@__DIR__, "..", "runner", "NitroTestRunner.jl"))
using .NitroTestRunner

dir = abspath(ARGS[1])
if length(ARGS) >= 3 && ARGS[2] == "--watch"
    child = `$(Base.julia_cmd()) --code-coverage=none --startup-file=no $(@__FILE__) $dir`
    exit(NitroTestRunner.watch(child; timeout = parse(Float64, ARGS[3]), grace = 3))
end
test_end = "--test-end-throws" in ARGS ? :(error("TEST_END probe failure")) : nothing
items, setups = NitroTestRunner.collect_suite(NitroTestRunner.resolve_paths([dir]); root = dir)
k = findfirst(==("--shuffle"), ARGS)
k === nothing || (items = NitroTestRunner.shuffle_items(items, parse(UInt64, ARGS[k+1])))
exit(NitroTestRunner.run_items(items, setups; imports = [:Test], test_end))
