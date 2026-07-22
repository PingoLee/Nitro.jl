# SYNTHETIC: replica of parallel_stream_handler's per-request task pattern
# (src/core.jl:629-637 — Threads.@spawn wrapping an inner @async, two waits).
# internalrequest bypasses this layer, so it is measured standalone against a
# single-task spawn and a direct call.
SUITE["taskpattern"] = BenchmarkGroup()

@noinline _tiny_work() = length("pong")

SUITE["taskpattern"]["spawn_async_pair"] = @benchmarkable begin
    t = Threads.@spawn begin
        h = @async _tiny_work()
        wait(h)
    end
    wait(t)
end

SUITE["taskpattern"]["spawn_single"] = @benchmarkable begin
    t = Threads.@spawn _tiny_work()
    wait(t)
end

SUITE["taskpattern"]["direct_call"] = @benchmarkable _tiny_work()
