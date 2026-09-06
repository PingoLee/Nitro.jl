# SYNTHETIC: replica of parallel_stream_handler's per-request task pattern
# (Threads.@spawn wrapping an inner @async, two waits). That nesting was removed in
# #39 — `parallel_stream_handler` is now a single spawn — so `spawn_async_pair` is
# retained purely as the historical comparison against `spawn_single`, which is what
# the request path actually does today.
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
