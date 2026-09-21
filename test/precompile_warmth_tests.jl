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
# `.github/workflows/ci.yml` runs `julia-actions/julia-runtest`, whose `coverage` input
# defaults to true. Coverage instrumentation makes Julia discard precompiled NATIVE code, so
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

const SHAPES = ["dict_any", "query_ext", "json_ext", "formdata", "multipart"]

probe = joinpath(@__DIR__, ".helpers", "precompile_warmth_probe.jl")
@test isfile(probe)

function measure(shape)
    cmd = `$(Base.julia_cmd()) --code-coverage=none --project=$(Base.active_project()) $probe $shape`
    parse(Float64, strip(read(cmd, String)))
end

best_of(shape, n) = minimum(measure(shape) for _ in 1:n)

baseline = best_of("dict_int", 3)
@test 0 < baseline < MAX_BASELINE_SECONDS

# Two samples per numerator, not one: ReTestItems runs with `retries=0` here, so a single
# sample makes one GC pause or one moment of CPU steal on a shared runner a hard red.
@testset "$shape stays warm" for shape in SHAPES
    ratio = best_of(shape, 2) / baseline
    @test ratio < MAX_RATIO
end

end
