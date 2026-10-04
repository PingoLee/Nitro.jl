@testsetup module NitroCommon

using Test
using HTTP
using HTTP.WebSockets
using Nitro
using Dates
using JSON
using UUIDs
using Sockets
using Suppressor

import Nitro: PACKAGE_DIR, App, Nullable, HOFRouter
import Nitro: GET, POST, PUT, DELETE, PATCH, STREAM, WEBSOCKET

export HOST
export values_present, value_absent, value_count, has_property
export get_free_port
export jwtkey

# ── Constants ────────────────────────────────────────────────────────

const HOST = "127.0.0.1"

"""
    jwtkey(label)

`label` padded with `'.'` to the 32 bytes an HS256 key must have (#321), so a test can still
name its keys `"s1"`, `"s2"` and read them apart. Distinct labels stay distinct keys; a label
of 32 bytes or more is returned unchanged.
"""
jwtkey(label::AbstractString) = rpad(label, Nitro.Auth.MIN_JWT_SECRET_BYTES, '.')

# There is deliberately NO shared `PORT`/`localhost` here. A fixed port shared by every
# `:network` item is what made an orphaned server from a *previous* run answer the next
# run's requests out of its own stale router — a failure that presents as an unrelated
# assertion error in whichever item happened to run at the time. Every item that binds a
# socket calls `get_free_port()` and builds its own `localhost` from it.

# ── Test helpers (from test_utils.jl) ────────────────────────────────

"""
    values_present(dict, key, values)

Asserts that the passed dictionary both safely contains the specified key,
and all the passed values are found in that collection.
Collection may contain additional values.
"""
function values_present(dict, key, values)
    return haskey(dict, key) && all(x -> x in dict[key], values)
end

"""
    value_count(dict, key, value)
Returns occurence count of value in collection specified by key
"""
function value_count(dict, key, value)
    if !haskey(dict, key)
        return 0
    end
    return count(x -> x == value, dict[key])
end

"""
    value_absent(dict, key, value)

Tests that specified value is not found in the collection referenced
by the key on the dict, or that key's value in Dict is missing.
"""
function value_absent(dict, key, value)
    if !haskey(dict, key)
        return true
    end
    return !any(x -> x == value, dict[key])
end

"""
    has_property(object, propertyName)

Test that generated OpenAPI schema object defintion has the specified property.
Safely check that `properties` key exists on dictionary first
"""
function has_property(object::Dict, propertyName::String)
    return haskey(object, "properties") && haskey(object["properties"], propertyName)
end

const _CLAIMED_PORTS = Set{Int}()
const _CLAIMED_PORTS_LOCK = ReentrantLock()

"""
    get_free_port() -> Int

Ask the OS for an unused TCP port by briefly binding to port 0, reading the assignment,
and releasing it.

The bind-0/close/rebind window is a TOCTOU race that cannot be closed from here — the
caller re-binds later, and anything may take the port in between. What *can* be closed is
the self-collision: two probes issued before either has been bound can be handed the same
port (`instance_tests.jl` asks for two in a row). So every port handed out is remembered
and never handed out twice within this process.
"""
function get_free_port()
    lock(_CLAIMED_PORTS_LOCK) do
        for _ in 1:50
            server = Sockets.listen(Sockets.localhost, 0)
            port = Int(getsockname(server)[2])
            close(server)
            if port ∉ _CLAIMED_PORTS
                push!(_CLAIMED_PORTS, port)
                return port
            end
        end
        error("get_free_port: no unclaimed ephemeral port after 50 attempts")
    end
end

end # module NitroCommon

# A Ctrl-C test needs a REAL SIGINT, and only a child process can take one without taking the
# test runner down with it. This is the one parent every such item uses: the #369 item at the
# top of test/workers_tests.jl and the #372 item in test/revise_test.jl. Those files own what
# their children assert; this module owns how a child is launched, pressed and judged (#473).
#
# The parent presses only once the child prints its cue: a handshake has no window to miss
# (#414). `settle` is how long after the cue the press comes, and it is what makes those items
# sensitive at all. The tasks under test re-park AFTER the child's main task, which takes a
# moment; pressed within milliseconds of the cue, main is still the last task to park on
# thread 1 and catches the press, even against the unpatched code (checked for #369). A real
# Ctrl-C comes long after `serve` parks. `settle` is a lower bound only, never a window: the
# children wait with no deadline, so a slow runner makes an item slower, not red.
#
# A child that never says its cue, or never exits once pressed, is stopped at `deadline` and
# reported as `timed_out`. That is a red assertion, never a hung CI leg. The deadline includes
# the child's startup; a cold pkgimage cache is warmed earlier in a full run by the other
# children spawned with the same flags, so only a lone filtered run on a cold depot is near it.
# `--code-coverage=none` for the reason test/bodyparser_tests.jl gives: an inherited coverage
# flag costs the child its pkgimages.
@testsetup module CtrlCChild

export SIGINT_PROBE, ctrl_c_child, report

# ── A child that can never take the press (#473) ──
#
# Julia 1.12 on macOS can start a process whose SIGINT is ignored for its whole life. On kqueue
# platforms the signal-listener thread sets `SIG_IGN` on every signal it watches, SIGINT
# included (`src/signals-unix.c`), and that write races the main thread installing the real
# SIGINT handler. When the listener writes last, every press is dropped before any delivery
# logic runs: no `InterruptException`, nothing on stderr, nothing on stdout. Load widens the
# race. It cost #473 three silent 120 s timeouts on a memory-starved macOS runner, on changes
# that never touched the code under test. Fixed upstream in JuliaLang/julia#62471, which is in
# 1.13 and not in 1.12.7; once no CI lane runs an unfixed Julia, the retry below is dead code.
#
# So every child prints its SIGINT disposition before its cue, and a child whose SIGINT is
# ignored is killed unpressed and replaced. The retry is gated on that PROOF, never on a
# timeout: a press that some task swallows still times out, and still goes red.
#
# The disposition is the first word of `struct sigaction`, which is the handler on macOS and
# on glibc alike; `1` is `SIG_IGN` on both.
const SIGINT_PROBE = raw"""
let act = zeros(UInt8, 256)
    ccall(:sigaction, Cint, (Cint, Ptr{Cvoid}, Ptr{UInt8}), Base.SIGINT, C_NULL, act) == 0 ||
        error("sigaction failed")
    println("SIGINT_DISPOSITION=", reinterpret(UInt, act[1:sizeof(UInt)])[1]); flush(stdout)
end
"""

const SIG_IGN = UInt(1)

"""
    ctrl_c_child(child, threads; cue, settle=2, deadline=120, dump_grace=15, attempts=3)

Run the Julia source `child` at `--threads=threads`, press Ctrl-C (SIGINT) `settle` seconds
after it prints the line `cue`, and return what happened. `child` must print `SIGINT_PROBE`'s
line before its cue.

At `deadline` the child gets a SIGQUIT first: Julia answers it by printing every live task's
backtrace to stderr, so a wedged child says where it is parked. `dump_grace` seconds later it
gets a SIGKILL.

A child whose SIGINT is ignored (see `SIGINT_PROBE`) is killed unpressed and replaced, up to
`attempts` runs in all. `sigint_ignored` in the result means every run was such a child.
"""
function ctrl_c_child(child::String, threads::String; cue::String, settle::Real=2,
                      deadline::Real=120, dump_grace::Real=15, attempts::Int=3)
    for attempt in 1:attempts
        r = _run_child(child, threads, cue, settle, deadline, dump_grace)
        (r.sigint_ignored && attempt < attempts) || return merge(r, (; attempts=attempt))
        @info "Ctrl-C child started with SIGINT ignored (JuliaLang/julia#62471); replacing it" attempt threads
    end
end

function _run_child(child, threads, cue, settle, deadline, dump_grace)
    cmd = `$(Base.julia_cmd()) --code-coverage=none --threads=$threads --project=$(Base.active_project()) --startup-file=no -e $child`
    err = IOBuffer()
    p = open(pipeline(ignorestatus(cmd); stderr=err), "r")
    timed_out = Threads.Atomic{Bool}(false)
    watchdog = Timer(deadline) do _
        timed_out[] = true
        kill(p, Base.SIGQUIT)
    end
    killer = Timer(deadline + dump_grace) do _
        kill(p, Base.SIGKILL)
    end
    disposition = nothing
    pressed = false
    try
        # Lines until the cue, not just the first: stray stdout ahead of it must not cost the press.
        seen = String[]
        for line in eachline(p)
            push!(seen, line)
            m = match(r"^SIGINT_DISPOSITION=(\d+)$", line)
            if m !== nothing
                disposition = parse(UInt, m[1])
                disposition == SIG_IGN || continue
                kill(p, Base.SIGKILL)   # it could never take the press; don't wait out the deadline
                break
            end
            line == cue || continue
            disposition === nothing &&
                error("the child printed its cue before its SIGINT disposition; prepend SIGINT_PROBE")
            sleep(settle)
            kill(p, Base.SIGINT)
            pressed = true
            break
        end
        out = join(seen, '\n') * '\n' * read(p, String)
        wait(p)
        return (; exitcode=p.exitcode, termsignal=p.termsignal, out=out, err=String(take!(err)),
                timed_out=timed_out[], pressed=pressed, sigint_disposition=disposition,
                sigint_ignored=disposition == SIG_IGN)
    finally
        close(watchdog)
        close(killer)
        process_running(p) && kill(p, Base.SIGKILL)   # never leave a child parked forever
    end
end

"""
    report(r)

Print a child's whole stdout and stderr unless it ran cleanly. A timed-out child's stderr
carries its SIGQUIT task dump. Under the suite's non-interactive `logs = :issues`, ReTestItems
shows an item's output only when the item fails, so this costs a green run nothing.
"""
function report(r)
    clean = !r.timed_out && r.exitcode == 0 && r.termsignal == 0 && occursin("RESULT", r.out)
    clean && return nothing
    println("── Ctrl-C child: timed_out=", r.timed_out, " exitcode=", r.exitcode,
            " termsignal=", r.termsignal, " pressed=", r.pressed,
            " sigint_disposition=", r.sigint_disposition, " attempts=", r.attempts)
    println("── stdout ──\n", r.out)
    println("── stderr ──\n", r.err)
    println("── end of Ctrl-C child ──")
    return nothing
end

end # module CtrlCChild
