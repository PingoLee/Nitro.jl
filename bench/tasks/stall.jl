# The stall repro of the JuliaLang/julia#62285 measurement (#618, the comment of 2026-10-22, PR #716):
# hold every other `:default` thread with a task that never yields, spawn n tasks, release, twelve
# times. On #62285's head (84961e79ff) some holders never started although threads were parked
# (work-stealing build 3 of 3 runs, partr build 2 of 3); 1.13.2 passed 3 of 3. A run ends three
# ways: twelve `ok` lines; the `stuck` error below (a holder queued with idle threads for 5 s);
# or no progress at all, which only an outer timeout ends (stall.sh). The code below is the script
# as posted there, unchanged.
# julia -t 8 stall.jl
function once(n)
    hold = Threads.Atomic{Bool}(true); started = Threads.Atomic{Int}(0)
    k = Threads.nthreads(:default) - 1
    holders = [Threads.@spawn (Threads.atomic_add!(started, 1); while hold[]; GC.safepoint(); end) for _ in 1:k]
    t0 = time()
    while started[] < k
        yield()
        time() - t0 > 5 && error("stuck: $(started[]) of $k holder tasks started, $(k - started[]) queued with idle threads")
    end
    done = Threads.Atomic{Int}(0)
    ts = [Threads.@spawn Threads.atomic_add!(done, 1) for _ in 1:n]
    hold[] = false
    foreach(wait, ts); foreach(wait, holders)
end
for n in (10_000, 100_000), rep in 1:6
    once(n); println("n=$n rep=$rep ok")
end
