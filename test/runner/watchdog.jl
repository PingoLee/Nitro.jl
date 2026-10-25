# The watchdog: the parent half of a run.
#
# The parent runs no item. It starts ONE child julia that runs the whole selection in order
# (`run_items`), lets the child write straight to the parent's own stdout and stderr, and follows
# the child's progress through an events file: which item is running and since when, and whether
# the run reached its end. An item that runs past the timeout gets the child killed, and the item
# named; so does a child that dies, or exits, with an item still running.
#
# Why a parent at all: a timeout enforced from inside the process running the item cannot stop
# an item that has wedged the process -- and ReTestItems' answer, a worker it killed with
# SIGTERM, threw away the worker's coverage, so the coverage job had to run with no timeout at
# all (#84, #244). Here the child exits normally whenever it finishes, so it writes its `.cov`
# files, and the timeout still holds in every job.
#
# Why a FILE for the events rather than the child's stdout: stdout also carries whatever a
# background task prints between items, and a failing item's captured output, which can itself
# contain progress lines (a test of this runner prints a nested run's). A protocol that shares a
# stream with arbitrary text can be spoofed by it.

const EVENTS_FILE = "events"

# The child's side of the protocol: one line per event, appended and flushed at once, so the
# parent sees an item start even if the child dies inside it.
function emit_event(capture_dir::AbstractString, msg::AbstractString)
    open(joinpath(capture_dir, EVENTS_FILE), "a") do io
        println(io, msg)
    end
    return nothing
end

# Watched children exit when the parent goes away. A parent that is killed outright (SIGKILL, a
# CI cancellation) cannot clean up after itself, and a child left behind keeps whatever port its
# current item bound -- which is how a wedged run once broke the NEXT run's `:network` items
# (#84).
#
#   * Linux: `PR_SET_PDEATHSIG` has the kernel SIGKILL the child when its parent dies, whatever
#     the child's scheduler is doing.
#   * Everywhere: the parent holds the child's stdin open for the child's whole life, so EOF on
#     it means the parent is gone. This half needs a task to run, so a CPU-bound item can delay
#     it on a one-thread layout; it runs on the interactive pool when there is one.
#
# The same pipe carries the parent's one request, `flush`: flush the running item's capture
# before a kill that would discard its buffer. Linux needs it less -- the SIGQUIT the parent
# sends first makes julia flush on its way out -- but Windows has no SIGQUIT, and a capture
# lost with the process is exactly the output a hung item needs to show.
#
# Items themselves get `devnull` as stdin, as they did under ReTestItems: a test, or a process
# it starts with `run`, must never block on the watchdog's pipe.
function start_orphan_guard()
    Sys.islinux() && ccall(:prctl, Cint, (Cint, Culong, Culong, Culong, Culong), 1, 9, 0, 0, 0)
    parent = stdin
    redirect_stdin(devnull)
    guard() = begin
        try
            for line in eachline(parent)
                line == "flush" || continue
                io = CURRENT_CAPTURE[]
                io === nothing || flush(io)
            end
        catch err
            @error "test runner: reading the watchdog pipe failed; exiting" exception = err
        end
        println(stderr, "test runner: the watchdog parent went away; exiting")
        exit(3)
    end
    Threads.nthreads(:interactive) > 0 ? Threads.@spawn(:interactive, guard()) : Threads.@spawn(guard())
    return nothing
end

"""
    watch(cmd; timeout) -> Int

Run `cmd` -- a julia that ends in `run_items` -- and return the status to exit with. The child
gets `NITRO_TEST_WATCHED=1` and a private `NITRO_TEST_CAPTURE_DIR`, which holds its events file
and each item's captured output.

`timeout` seconds bound every stretch of the run, not only the items: collection before the
first item, each item, and the child's exit after the last one. A run passes only when the child
reported the end of the run and then exited 0.
"""
function watch(cmd::Cmd; timeout::Real, grace::Real = 10)
    capture_dir = mktempdir()
    events = joinpath(capture_dir, EVENTS_FILE)
    cmd = addenv(cmd, "NITRO_TEST_WATCHED" => "1", "NITRO_TEST_CAPTURE_DIR" => capture_dir)
    # What the child is doing now, and since when: (item number, description, t0). Item 0 is
    # the stretch before the first item; -1 is the exit after the last one.
    current = (0, "collection, before the first test item", time())
    status = nothing      # the child's own verdict, from its COMPLETE event
    pos = 0
    function read_events!()
        isfile(events) || return
        data = open(events) do io
            seek(io, pos)
            read(io, String)
        end
        # Only whole lines: a line still being written is read on the next pass.
        cut = findlast('\n', data)
        cut === nothing && return
        pos += ncodeunits(data[1:cut])
        for line in split(data[1:cut], '\n'; keepempty = false)
            kind, rest = (split(line, ' '; limit = 2)..., "")[1:2]
            if kind == "START"
                n, what = split(rest, ' '; limit = 2)
                current = (parse(Int, n), String(what), time())
            elseif kind == "DONE"
                current = (current[1], "the gap between test items", time())
            elseif kind == "COMPLETE"
                status = parse(Int, rest)
                current = (-1, "the child's exit, after the last test item", time())
            end
        end
    end

    p = open(pipeline(ignorestatus(cmd); stdout = stdout, stderr = stderr), "w")
    timed_out = false
    try
        while process_running(p)
            sleep(1)
            read_events!()
            if time() - current[3] > timeout
                timed_out = true
                break
            end
        end
        if timed_out
            println(stdout, "\nTIMEOUT: $(current[2]) ran for more than $(timeout) s, so the run is stopped.\n")
            flush(stdout)
            # A SIGQUIT makes julia print every task's backtrace to stderr before it dies, so a
            # wedged item says where it is parked. Windows has no SIGQUIT: ask the child to
            # flush the item's capture, give it a moment, then kill.
            if Sys.iswindows()
                try
                    write(p, "flush\n")
                    flush(p)
                catch
                end
                timedwait(() -> !process_running(p), 3.0)
            else
                kill(p, Base.SIGQUIT)
                timedwait(() -> !process_running(p), float(grace))
            end
            process_running(p) && kill(p, Base.SIGKILL)
        end
        wait(p)
    finally
        process_running(p) && kill(p, Base.SIGKILL)
    end
    read_events!()

    # Passed: the child said the run ended, and then exited normally.
    !timed_out && status !== nothing && p.exitcode == 0 && p.termsignal == 0 && return status
    if !timed_out
        println(stdout, "\nThe test child ", status === nothing ?
                "ended before the run did -- it exited, crashed or was killed during $(current[2])" :
                "reported the end of the run, then exited abnormally",
                " (exit code $(p.exitcode), signal $(p.termsignal)).")
    end
    n = current[1]
    log = joinpath(capture_dir, "$n.log")
    if n > 0 && isfile(log)
        println(stdout, "── Captured output of test item $n ──")
        write(stdout, read(log))
        println(stdout, "── End of captured output ──")
    end
    status === nothing &&
        println(stdout, "The items after it did not run. Re-run it alone, or with `--in-process`, to see more.")
    flush(stdout)
    return 1
end
