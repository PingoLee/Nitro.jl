# The benchmark that got the fair sift-down reverted (#618, the battery's item 2): JuliaLang/julia#35589,
# `pfib(25)` at 2 threads. `pfib` below is the code as Jeff Bezanson posted it in that PR's thread
# (2020-04-28: "Try running this ... with 2 threads"), unchanged; the posted numbers were 0.18 s with
# `<` and 6.9 s with `<=` (the sift-down the revert removed).
#
# Every mode starts the work from one task spawned on `:default` and fetches it, so the modes differ only
# in their marks (on today's Julia `--threads=2` is 2,1, and the main task runs on `:interactive`):
#   PFIB_MODE=none  the root unmarked, the rest as posted (any build);
#   PFIB_MODE=root  the root spawned with the mark, the rest as posted: the intended use, the children
#                   are request work in stock's order (a build with the native mark);
#   PFIB_MODE=all   every spawn marked, the root included: every level of the fork-join in arrival order.
# Marks go through `Threads._spawn_set_fair` on a task built as `Threads.@spawn` builds it, so the file
# loads on a build without the mark (`none` never calls it).
#
# One process, one column: BenchmarkTools (from the environment given with --project) times the root's
# spawn and fetch, `evals = 1`, for BENCH_S seconds after its warm-up. Prints one TSV row:
#   round label mode layout n min_s median_s allocs memory_bytes samples maxrss_mb
# COUNT=1 instead runs pfib twice untimed with a counter on every spawn and prints
#   round label mode layout n peak_live_tasks spawned maxrss_mb
# Usage: PFIB_MODE=none LABEL=ctl ROUND=1 julia --project=<env with BenchmarkTools> --threads=2 pfib.jl

using BenchmarkTools

function pfib(n::Int)
    if n <= 1
        return n
    end
    t = Threads.@spawn pfib(n-2)
    return pfib(n-1) + fetch(t)::Int
end

function spawnm(f, mark::Bool)
    t = Task(f)
    t.sticky = false
    Threads._spawn_set_thrpool(t, :default)
    mark && Threads._spawn_set_fair(t, true)
    schedule(t)
    return t
end

# pfib with every spawn marked: the same recursion, the spawn built by hand.
function pfib_all(n::Int)
    if n <= 1
        return n
    end
    t = spawnm(() -> pfib_all(n-2), true)
    return pfib_all(n-1) + fetch(t)::Int
end

# COUNT=1: the same recursions with a live-task counter (spawned, finished) and its peak.
const LIVE = Threads.Atomic{Int}(0)
const PEAK = Threads.Atomic{Int}(0)
const SPAWNED = Threads.Atomic{Int}(0)
function spawnc(f, mark::Bool)
    Threads.atomic_add!(SPAWNED, 1)
    Threads.atomic_max!(PEAK, Threads.atomic_add!(LIVE, 1) + 1)
    return spawnm(() -> (v = f(); Threads.atomic_sub!(LIVE, 1); v), mark)
end
function pfib_c(n::Int, mark::Bool)
    if n <= 1
        return n
    end
    t = spawnc(() -> pfib_c(n-2, mark), mark)
    return pfib_c(n-1, mark) + fetch(t)::Int
end

const MODE = get(ENV, "PFIB_MODE", "none")
MODE in ("none", "root", "all") || error("PFIB_MODE must be none, root or all, not $MODE")
MODE == "none" || isdefined(Threads, :_spawn_set_fair) || error("PFIB_MODE=$MODE needs a build with the native mark")
const N = parse(Int, get(ENV, "PFIB_N", "25"))
const LABELS = (get(ENV, "ROUND", "1"), get(ENV, "LABEL", "-"), MODE,
                string(Threads.nthreads(:default), ",", Threads.nthreads(:interactive)), string(N))

root_once(n::Int) = MODE == "none" ? fetch(spawnm(() -> pfib(n), false))::Int :
                    MODE == "root" ? fetch(spawnm(() -> pfib(n), true))::Int :
                                     fetch(spawnm(() -> pfib_all(n), true))::Int
root_count(n::Int) = MODE == "none" ? fetch(spawnc(() -> pfib_c(n, false), false))::Int :
                     MODE == "root" ? fetch(spawnc(() -> pfib_c(n, false), true))::Int :
                                      fetch(spawnc(() -> pfib_c(n, true), true))::Int

maxrss_mb() = string(round(Int, Sys.maxrss() / 2^20))

if get(ENV, "COUNT", "0") == "1"
    root_count(N) == 75025 || N != 25 || error("pfib(25) != 75025")
    LIVE[] = 0; PEAK[] = 0; SPAWNED[] = 0
    root_count(N)
    println(join((LABELS..., string(PEAK[]), string(SPAWNED[]), maxrss_mb()), '\t'))
else
    root_once(N) == 75025 || N != 25 || error("pfib(25) != 75025")
    b = @benchmark root_once($N) evals = 1 seconds = parse(Float64, get(ENV, "BENCH_S", "4"))
    println(join((LABELS..., string(minimum(b.times) / 1e9), string(median(b.times) / 1e9),
                  string(b.allocs), string(b.memory), string(length(b.times)), maxrss_mb()), '\t'))
end
