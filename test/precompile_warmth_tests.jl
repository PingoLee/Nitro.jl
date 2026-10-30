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
# ── Why the baseline is read twice, and the larger read divides (#766) ────────────────────
#
# The floor itself moves, though. #766 is a run on a developer box whose `dict_int` read 0.048 s
# against 0.080–0.088 s in eleven others on the same box: `multipart` took its usual time and
# still read 1.37x against 1.2. A
# minimum guards the denominator from above only, and `MAX_BASELINE_SECONDS` below is from above
# too. Nothing guarded it from below, and one fast read became the denominator of every ratio in
# the run, the tightest limits (`multipart` 1.2, `url` 1.8) first. (The `url` reds on ubuntu at
# 1 thread from 2026-10-29 on look like this and are not: their baseline sat inside its usual
# 0.021–0.038 s there, and `url`'s own time had moved. That is #710, below.)
#
# So `dict_int` is read before the shapes and again after them, best of three each time, and
# the LARGER of the two minima divides. One fast read at either end can no longer set every
# ratio; both would have to be fast, and then the runner really was fast. When the two agree,
# the ratios the `warmth:` lines have recorded do not move. A floor was the other option, and
# it needs a number no host gives: CI's `dict_int` is not a developer box's, and "1 s is cold"
# works as a ceiling on every host while no "too fast" does.
#
# The price is on the other side, and it is the side the paragraph above calls dangerous: a
# denominator read HIGH pulls every ratio down. One slow block, at either end, now sets the
# denominator where before only the single block could. Say the runner slows late in a run,
# `before` 0.040 s and `after` 0.055 s, and `multipart` regresses to 0.060 s: it reads 1.09
# against 1.2 and passes, where `before` alone would have read 1.5. That trade was taken on
# purpose (#766): fast reads have caused false reds, while a false pass from a slow block has
# not been observed, though it would be silent if it happened. Both reads go on the `warmth:`
# line, so a run where they disagree is
# visible either way, and if they are seen to disagree by much, a guard on `after / before`
# with the ceiling's meaning, "the measurement is untrustworthy", is the next step.
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
#   warmth: baseline_before dict_int_s=… caller_s=…              <- the first read, as it lands
#   warmth: baseline dict_int_s=… caller_s=… limit_s=… dict_int_before_s=… dict_int_after_s=…
#                                                          <- after both reads, before its @test
#   warmth: ratio shape=… ratio=… shape_s=… baseline_s=… limit=… caller_s=…
#                                                                 <- one per shape, before its @test
#   warmth: end mem_free=…                                        <- after them, even on a throw
#
# Those lines are for two things. Over a few CI runs they give the per-OS distribution of
# each ratio. With the memory fraction beside them, a red can be read against the runner's
# state, not guessed at. A ratio logged on a loaded developer box is not evidence for moving a
# limit or a sample count; these lines are.
#
# They settled #610's third proposal (a per-OS limit, a third numerator sample, or a
# free-memory floor) as NONE of the three. The leg it went red on, macOS at Julia 1.12, left the
# CI matrix with the 1.13 floor (#526). No red since these lines exist was a numerator outlier
# that a third sample would have absorbed: #736 was the probe's caller (CI), #766 a fast
# denominator (a developer box), and #710's `url` a step that holds on every sample of a run
# (CI). `MAX_RATIO` stays global, because #508 was a real regression caught at a tight limit.
#
# What #610's data did show is the leg running closest to the line: ubuntu at 1 thread reads
# `json_ext` at up to ~7.4x against 8.0. That is not noise. Its `dict_int` is systematically
# lower there (0.021–0.038 s against 0.047–0.076 s on the other legs), while `json_ext` takes
# about the same time everywhere. It is #710's to settle, with the `caller_s` field below.
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
# They are written to the test runner's `report_io()`, not to the item's own logger, because
# the item's logger would lose them. The runner (`test/runner/`) redirects an item's output to
# a capture file and deletes that file unless the item FAILED, so a plain `@info` appears only
# on exactly the runs that already tell us the ratio. `report_io()` is the stdout the runner
# saved before it redirected anything; in a watched run the parent forwards it to the job log.
# Outside the runner the lookup falls back to `stdout`, and the test itself still asserts.
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
# ── `multipart`'s own limit, and why the probe captures through `let` (#736) ────────────────
#
# From #720 on, the `multipart` and `files_ext` probes read ~0.10–0.12 s instead of ~0.02 s, but
# the multipart parse was never cold. Both probe closures referred to non-const globals, so
# compiling the closure inferred `internalrequest` over the ABSTRACT `HTTP.Request`. The typed
# pipeline (#572) made that inference walk every layer, 1.7 ms before and 75–140 ms after. The two
# shapes were measuring their caller. The probe now captures through `let`, which the other
# shapes' literals already amounted to. That caller cost is no longer measured here; it is #737.
# `multipart` read 1.6–3.9x through all of it, under the general 8x. Julia 1.13.2, CI's flags:
#
#               warm (`let` capture)   abstract caller (#736)            cold (before #242)
#   multipart   0.23–0.26x local       1.62–1.83x local, 1.88–3.86x CI   18.7x (1.12, above)
#
# CI has no warm `multipart` reading yet. `formdata`, the same ~0.015 s request, reads 0.24–0.52x
# there, so 1.2 is ~2.3x above that proxy and ~1.57x below the lowest CI #736 reading (1.35x below
# the local one). The false-pass margin is thinner than the 1.53x above because of the
# denominator: #735 moved `dict_int` from 0.034 s to 0.065 s on a local trace, so every ratio
# reads low until it is faster again. `files_ext` shares the path and keeps its 3.5. What 1.2
# catches is the multipart path losing ~60 ms or more of its precompile coverage, or the probe
# going back to an untyped capture.
#
# Move these with the `warmth:` lines from CI, not with a red on a loaded developer box.
#
# ── The probe's caller, timed apart (#710) ────────────────────────────────────────────────
#
# Every shape's first request starts by compiling the probe's own thunk, `go` in the probe: a
# fresh closure that builds the request and calls `internalrequest`. That compile is the same
# work for every shape, ~7–9 ms at CI's flags, and it sits inside every number above,
# denominator included. Once, locally, it was not the same SIZE:
#
#   `cookie_ext`, CI's flags: 0.060 s against 0.024 s, on every child for a stretch of one
#   session. `--trace-compile` put all of the excess in compiling the thunk (44 ms against
#   8.6 ms for `dict_int`'s), while the shape's own compiles, its `FormattedLeaf` and the
#   `get_cookie` keyword call, were normal. The same probe read 0.024 s later in the session,
#   with nothing changed but the pkgimages other processes had since written to the depot.
#
# A step of the same size has turned the coverage leg red on every run since 2026-10-29:
#
#   `url`, ubuntu at 1 thread, from 2026-10-29 21:46 on: 0.053–0.061 s against 0.014–0.023 s
#   before it and on every other leg, with no `src/` change between the two readings and the
#   baseline unmoved. The test env had moved to HTTP 2.13.3 / URIs 1.7.3. The same step
#   appeared twice on 2026-10-28 with the older versions.
#
# So the probe compiles `go` before the request and prints the two times, and the CI lines
# settled it: the step is the thunk. In both `url` reds on ubuntu at 1 thread, `caller_s` was
# 0.045–0.046 s against the baseline's 0.009 s, and the request itself, `url()` included, took
# 7–8 ms. `multipart` went red the same way on windows at 1 thread, with `formdata` and
# `files_ext` beside it under their limits: `caller_s` 0.057–0.059 s against 0.013 s, and
# ~6 ms of request. The thunks have the baseline's types and the probe's setup logs no
# invalidations, so the extra compile is the depot's pkgimage state, not a path an
# application pays. It reproduced locally and went away with no source change.
#
# ── Every shape is charged the baseline's caller (#710) ───────────────────────────────────
#
# A shape's ratio is `(shape_s - caller_s + baseline caller_s) / baseline_s`: its own request,
# plus the thunk compile the baseline paid. Where the two thunk compiles are the same size,
# which is nearly always, the ratio is the old sum's, so the limits keep their calibration. A thunk-compile step no longer reaches the ratio. A cold shape still does,
# because its compiles are in the request half (`internalrequest` is inferred only as far as
# `setupmiddleware(...)`, typed `::Function`; see the probe).
#
# Dividing own time by own time was the other option, and it is wrong for this test.
# Subtracting a constant from both sides inflates every ratio above 1. On the 306 shape
# readings the CI legs logged on 2026-10-30, `json_ext` would read up to 9.6x and `query_ext`
# 8.1x against 8. The charged form reads them at 6.7x and 5.7x. Wherever a shape's caller is
# within 3 ms of the baseline's, the charged form is within 0.07 of the sum. All four sum
# reds that day read 0.4–0.9x charged.
# `ratio_sum` on the `warmth:` line keeps the old quantity visible, and `caller_s` keeps a
# thunk step visible, even though neither can fail the test any more.
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
                "formdata" => MAX_RATIO, "multipart" => 1.2,
                "cookie_ext" => 3.5, "files_ext" => 3.5, "payload" => 3.5, "url" => 1.8]

probe = joinpath(@__DIR__, ".helpers", "precompile_warmth_probe.jl")
@test isfile(probe)

# One sample: the first request's `total`, and the share of it that compiled the probe's own
# thunk, `caller` (see "The probe's caller, timed apart" above).
function measure(shape)
    cmd = `$(Base.julia_cmd()) --code-coverage=none --project=$(Base.active_project()) $probe $shape`
    total, caller = parse.(Float64, split(read(cmd, String)))
    (; total, caller)
end

# The sample with the smallest total, kept whole so its split is logged with it.
best_of(shape, n) = argmin(s -> s.total, [measure(shape) for _ in 1:n])

# See "Why it logs on every run" above for why this is not the item's own logger.
runner = isdefined(Main, :NitroTestRunner) ? getfield(Main, :NitroTestRunner) : nothing
warmth_io = runner isa Module && isdefined(runner, :report_io) ? runner.report_io() : stdout
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
    # The baseline is read on both sides of the shapes and the LARGER read divides (#766; see
    # "Why the baseline is read twice" above), so every shape is timed before any ratio exists.
    # Two samples per numerator, not one: the test runner never retries an item, so a single
    # sample makes one GC pause or one moment of CPU steal on a shared runner a hard red.
    before = best_of("dict_int", 3)
    # Logged at once, so a run the watchdog stops part-way still says what the first read was.
    warmth("baseline_before dict_int_s=$(fmt(before.total)) caller_s=$(fmt(before.caller))")
    # A probe that fails (a crash, or its body check catching a broken parser) is kept and
    # thrown inside its own shape's testset below: it reds that shape, and the others still
    # run and log.
    samples = map(SHAPES) do (shape, _)
        try
            best_of(shape, 2)
        catch e
            e isa InterruptException && rethrow()
            CapturedException(e, catch_backtrace())
        end
    end
    after = best_of("dict_int", 3)
    base = before.total >= after.total ? before : after
    baseline = base.total
    warmth("baseline dict_int_s=$(fmt(baseline)) caller_s=$(fmt(base.caller)) " *
           "limit_s=$MAX_BASELINE_SECONDS " *
           "dict_int_before_s=$(fmt(before.total)) dict_int_after_s=$(fmt(after.total))")
    @test 0 < baseline < MAX_BASELINE_SECONDS

    @testset "$shape stays warm" for ((shape, limit), s) in zip(SHAPES, samples)
        s isa CapturedException && throw(s)
        # Charged the baseline's thunk compile, not its own (see "Every shape is charged the
        # baseline's caller" above).
        ratio = (s.total - s.caller + base.caller) / baseline
        warmth("ratio shape=$shape ratio=$(round(ratio; digits = 2)) shape_s=$(fmt(s.total)) " *
               "baseline_s=$(fmt(baseline)) limit=$limit caller_s=$(fmt(s.caller)) " *
               "ratio_sum=$(round(s.total / baseline; digits = 2))")
        @test ratio < limit
    end
finally
    warmth("end $(memory())")
end

end
