@testitem "Precompile workload warmth (#242)" tags=[:core, :slow] begin
using Test

# What this guards: that `src/precompile.jl` keeps covering the request shapes applications
# actually use. Before #242 every `Res.json` in the workload built a CONCRETELY-typed dict
# (`Dict("id" => id)` is a `Dict{String,Int}`), the typed extractors had no coverage at all,
# and the body parsers had none either — so a precompiled Nitro still paid 1.1–1.8s of JIT on
# the first request that returned a `Dict{String,Any}` or bound a `Query{T}`.
#
# ── Why this is a RATIO and not a timing bound ────────────────────────────────────────────
#
# An absolute bound ("under 300ms") encodes the speed of the machine that wrote it, so it
# either flakes on a slow CI runner or is set so loose it asserts nothing. Instead each shape
# is measured against `dict_int` — a shape the workload covered BEFORE #242 and still covers,
# so it reads this machine's fixed cost for "a warm first request". Both numbers move together
# when the runner is slow; the ratio does not.
#
# ── Why a subprocess per shape ────────────────────────────────────────────────────────────
#
# Time-to-first-request is the entire quantity under test, and the second shape measured in a
# process is reading a path the first one already warmed. One shape, one fresh process.
#
# ── Why the child command forces `--code-coverage=none` ───────────────────────────────────
#
# THIS LINE IS WHAT MAKES THE TEST MEAN ANYTHING IN CI, and it is not an optimization.
# `Base.julia_cmd()` reproduces the PARENT's flags, `--code-coverage` among them, and
# `.github/workflows/ci.yml` runs the suite under coverage in the job that uploads it (and in
# every job, if its `coverage:` gate is ever dropped -- the action defaults it to true,
# #244). Coverage instrumentation makes Julia discard precompiled NATIVE code, so
# an inherited flag leaves every probe cold — including the denominator. Measured, this
# worktree, only the flag changed:
#
#                   normal      --code-coverage=user
#   dict_int        0.085 s          7.64 s            <- the denominator, 90x worse
#   query_ext       0.419 s          2.39 s
#   ratio             5.0x            0.31x            <- passes a 9.0 threshold trivially
#
# So the inherited flag does not merely weaken the test, it INVERTS it: the baseline pays more
# than the shape under test, every ratio collapses toward zero, and the one place this test
# runs automatically becomes the one place it cannot fail. It would go green against the
# pre-#242 workload — precisely the regression it exists to catch. Later flags win, so the
# explicit `none` overrides the inherited value.
#
# ── Why the threshold is 8x, and why the denominator is sampled harder ───────────────────
#
# Measured on Julia 1.12 / Windows, fresh process per shape, best-of-two, against a baseline
# sampled at its floor (~0.09s):
#
#            warm (this workload)   cold (workload before #242)
#   dict_any         2.4x                    12.1x
#   query_ext        5.1x                    19.4x
#   json_ext         5.2x                    15.1x
#   formdata         0.4x                    12.5x
#   multipart        0.5x                    18.7x
#
# Worst warm case 5.2x, best cold case 12.1x. 8.0 sits between them with ~1.54x of margin on
# the flake side and ~1.51x on the false-pass side. If a future shape lands closer to the
# line, give it its own threshold rather than loosening this one for everything.
#
# The denominator gets THREE samples where the numerators get two, and that asymmetry is the
# opposite of the obvious one — it is not about being careful with the baseline for its own
# sake. `dict_int` is a ~0.09s quantity, so it has the highest RELATIVE variance of anything
# measured here: observed runs of 0.085, 0.084, 0.087 and one of 0.208. A denominator that
# samples 2.4x high drags every ratio down by the same factor, and a cold `formdata` at 12.5x
# would read as 5.2x — a false pass, on the exact regression this file exists to catch. The
# numerators are large and comparatively stable (0.455 / 0.468 warm across runs), so they need
# less. `min` throughout rather than the mean: a timing sample is noise ABOVE a floor, never
# below it, so the minimum is the least-contaminated estimate of each.
#
# ── Why it logs on every run, pass or fail (#610) ─────────────────────────────────────────
#
# A pass used to print nothing, so the MARGIN was invisible: nobody knew how close a given
# OS runs to `MAX_RATIO` until it crossed it. #610 is that crossing: `query_ext` read 9.5x
# once on macOS / 1.12 / 1 thread, with the runner at 95–99% memory, and was green on the
# next head. The item now logs one line per number, every run, all under the stable prefix
# `warmth:` (`grep 'warmth:'` over a CI job log):
#
#   warmth: start os=… julia=… threads=… mem_free=<fraction> …   <- before any measurement
#   warmth: baseline dict_int_s=…                                 <- before its @test
#   warmth: ratio shape=… ratio=… shape_s=… baseline_s=…          <- one per shape, before its @test
#   warmth: end mem_free=…                                        <- after them, even on a throw
#
# Those lines are for two things. Over a few CI runs they give the per-OS distribution of
# each ratio. With the memory fraction beside them, a red can be read against the runner's
# state, not guessed at. That data decides #610's third proposal (a per-OS limit, a third
# numerator sample, or a free-memory floor). Until then the limits and sample counts above
# stay as they are, and a ratio logged on a loaded developer box is not evidence for moving
# them.
#
# Compare the memory fraction WITHIN one OS only. On macOS `Sys.free_memory()` counts only
# pages that are completely free, not cached or inactive ones. The first CI run with this
# log read ~0.05 there on a GREEN run, against ~0.7–0.8 on Linux and Windows. So the
# 95–99% that #610 saw is the macOS runner's normal state, not a sign of trouble, and a
# free-memory floor would skip every macOS run.
#
# The values go INTO the message string, not as `key=value` logging pairs, because
# ConsoleLogger puts pairs on their own `│` lines, which a grep for the prefix would drop.
#
# They are written to `ReTestItems.DEFAULT_STDOUT[]`, not to the item's own logger, because
# the item's logger would lose them. Run non-interactively (CI, `julia test/runtests.jl`),
# ReTestItems defaults to `logs=:issues`: it redirects an item's output to a file and
# deletes that file unless the item FAILED, so a plain `@info` appears only on exactly the
# runs that already tell us the ratio. `DEFAULT_STDOUT` is the stream ReTestItems saves in
# its `__init__`, before it redirects anything. On a worker that is the worker's stdout,
# which the coordinator forwards as `Worker <pid>:  …`; in-process (`--workers 0`, the
# coverage job) it is the run's own stdout. It is an INTERNAL of ReTestItems, so the lookup
# falls back to `stdout` when it is missing. If an upgrade renames it, the lines go quiet
# on a pass again, and the test itself still asserts.
#
# ── The #551 shapes, which need limits of their own ───────────────────────────────────────
#
# #551's second workload pass covered four more shapes. Their cold cost is a smaller multiple of
# the baseline than #242's, so 8x would pass them cold. Measured on Julia 1.13.2 / Linux, same
# protocol (best of two, baseline best of three, ~0.068 s):
#
#               warm (this workload)   cold (workload before #551)
#   cookie_ext         0.85x                    5.6x
#   files_ext          0.72x                    5.35x
#   payload            0.74x                    7.7x
#   url                1.0x                     2.7x
#
# CI runs the suite at `-O0` with `--check-bounds=yes`, and the probes inherit both through
# `Base.julia_cmd()`. Under those flags (baseline ~0.04 s) cold reads 5.8–7.8x and `url` 2.4x.
#
# The first CI run (PR #708, all four Linux/Windows legs) read the warm side at 0.44–0.77x, `url`
# at 0.53–0.59x, with one exception: `cookie_ext` read 2.1x on Linux at 1 thread. Its baseline
# was unusually fast (0.030 s) and its own time unusually slow (0.063 s, against ~0.035 s on the
# other legs). The first three were set at 2.5x from one developer box, and that run left 1.19x.
# They are 3.5x now: 1.67x above the worst warm reading seen, and 1.53x below the lowest cold one
# (`files_ext`, 5.35x). Those are the same margins the 8x above was chosen for. `url` stays at
# 1.8x: ~3x above its warm readings and ~1.33x below cold. Its whole effect is ~175 ms, so there is
# no room for more on either side.
#
# Move these with the `warmth:` lines from CI, not with a red on a loaded developer box.
#
# This is a `:slow` item — it spawns one Julia process per measurement. `--skip-tags slow`
# drops it.

const MAX_RATIO = 8.0

# The denominator is warm on every workload this test can see, so a slow one means the
# measurement itself is untrustworthy — a loaded runner, or the `dict_int` block deleted from
# the workload. Without this, a cold denominator silently rescues every ratio above: that is
# the same failure the coverage flag caused, reachable by a second route.
#
# Honest limitation, because this is the weakest assertion in the file: a cold `dict_int` is
# ~1.0s and this ceiling is 1.0s, so the guard only just separates the two. It is a coarse
# sanity check on the measurement, not a tight bound, and the ratio is the real protection.
const MAX_BASELINE_SECONDS = 1.0

const SHAPES = ["dict_any" => MAX_RATIO, "query_ext" => MAX_RATIO, "json_ext" => MAX_RATIO,
                "formdata" => MAX_RATIO, "multipart" => MAX_RATIO,
                "cookie_ext" => 3.5, "files_ext" => 3.5, "payload" => 3.5, "url" => 1.8]

probe = joinpath(@__DIR__, ".helpers", "precompile_warmth_probe.jl")
@test isfile(probe)

function measure(shape)
    cmd = `$(Base.julia_cmd()) --code-coverage=none --project=$(Base.active_project()) $probe $shape`
    parse(Float64, strip(read(cmd, String)))
end

best_of(shape, n) = minimum(measure(shape) for _ in 1:n)

# See "Why it logs on every run" above for why this is not the item's own logger.
rti = isdefined(Main, :ReTestItems) ? getfield(Main, :ReTestItems) : nothing
warmth_io = rti isa Module && isdefined(rti, :DEFAULT_STDOUT) && isassigned(rti.DEFAULT_STDOUT) ?
    rti.DEFAULT_STDOUT[] : stdout
function warmth(msg)
    Base.CoreLogging.with_logger(Base.CoreLogging.ConsoleLogger(warmth_io)) do
        @info "warmth: $msg"
    end
    flush(warmth_io)
end

fmt(x) = string(round(x; digits = 3))
function memory()
    free, total = Sys.free_memory(), Sys.total_memory()   # one reading, so the line is consistent
    "mem_free=$(fmt(free / total)) mem_free_gib=$(fmt(free / 2^30)) mem_total_gib=$(fmt(total / 2^30))"
end

warmth("start os=$(Sys.KERNEL) arch=$(Sys.ARCH) julia=$VERSION threads=$(Threads.nthreads()) $(memory())")
try
    baseline = best_of("dict_int", 3)
    warmth("baseline dict_int_s=$(fmt(baseline)) limit_s=$MAX_BASELINE_SECONDS")
    @test 0 < baseline < MAX_BASELINE_SECONDS

    # Two samples per numerator, not one: ReTestItems runs with `retries=0` here, so a single
    # sample makes one GC pause or one moment of CPU steal on a shared runner a hard red.
    @testset "$shape stays warm" for (shape, limit) in SHAPES
        shape_s = best_of(shape, 2)
        ratio = shape_s / baseline
        warmth("ratio shape=$shape ratio=$(round(ratio; digits = 2)) shape_s=$(fmt(shape_s)) " *
               "baseline_s=$(fmt(baseline)) limit=$limit")
        @test ratio < limit
    end
finally
    warmth("end $(memory())")
end

end
