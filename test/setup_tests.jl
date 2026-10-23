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
export raw_exchange, read_failed, abort_with_reset!
export allocs, Allocs
export dynamic_calls

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

# ── Raw-socket exchanges (#490) ──────────────────────────────────────

"""
    read_failed(e) -> String

The marker a raw-socket reader returns for a failed read, in place of a bare `""`. A reset is
the usual cause: a client that writes into a connection the server has already closed draws an
RST, and the RST makes `read` throw. `""` could not tell that apart from a server that closed
without a word, which is how #483 had to be reasoned out rather than read off the failure.
"""
read_failed(e) = "(read failed: $(sprint(showerror, e)))"

"""
    raw_exchange(port, parts; gap = 0.0, limit = 15.0) -> String

Write `parts` (strings or byte vectors) to a fresh raw connection, `gap` seconds apart, and
return everything the server sends back until it closes the connection. A raw socket rather
than HTTP.jl's client: no pool, no retry, and no way for the client to paper over a slow send.

The result is one of three things:

- the server closed the connection: every byte it sent;
- the read failed (typically a reset): every byte that arrived first, then `read_failed`'s
  marker. A status line followed by a reset therefore still starts with that status. These
  tests claim the server answered with a status, and a reset in that window is the client's own
  late write, not the server's doing (the decision on #490);
- no close within `limit` seconds: the bare marker `"(no close within …)"`, with no bytes in
  front, so a server that answered but never closed cannot pass a `startswith` on its status.

Reading starts before the first write, so the server's bytes are in this process as soon as
they arrive. Left in the kernel, a later reset can discard them (Windows drops unread receive
data when an RST arrives).
"""
function raw_exchange(port, parts; gap = 0.0, limit = 15.0)
    sock = Sockets.connect(Sockets.localhost, port)
    try
        seen = IOBuffer()
        reader = @async try
            while true
                chunk = readavailable(sock)
                isempty(chunk) && break        # EOF: the server closed the connection
                write(seen, chunk)
            end
            String(take!(seen))
        catch e
            String(take!(seen)) * read_failed(e)
        end
        yield()                                # let the reader park on the socket first
        for (i, part) in enumerate(parts)
            i > 1 && sleep(gap)
            try
                write(sock, part)
                flush(sock)
            catch
                break          # the server already hung up; read whatever it said first
            end
        end
        timedwait(() -> istaskdone(reader), limit; pollint = 0.05) === :ok && return fetch(reader)
        close(sock)
        timedwait(() -> istaskdone(reader), 5.0; pollint = 0.05)
        return "(no close within $(limit)s)"
    finally
        close(sock)
    end
end

# `SO_LINGER {on, 0}` makes `close` abort the connection with an RST instead of a FIN.
const SOL_SOCKET = Sys.islinux() ? Cint(1) : Cint(0xffff)
const SO_LINGER  = Sys.islinux() ? Cint(13) : Cint(0x0080)

"""
    abort_with_reset!(conn::TCPSocket)

Close `conn` with an RST instead of a FIN, for a test server standing in for a peer that resets
(#490, #504). A raw-socket reader's sensitivity check pairs it with an ordinary `close` of the
same bytes: the reader must report the two differently.

Do not read the request first on the abort path. On Windows, libuv closes a socket with a read
pending by sending a FIN first, so the client would see a clean EOF before the RST. On the clean
path, do read it: closing over unread input is itself a reset on Linux.
"""
function abort_with_reset!(conn::TCPSocket)
    fd = Base._fd(conn)
    @static if Sys.iswindows()
        # `fd` is a `WindowsRawSocket`, which converts to the `SOCKET` pointer itself.
        linger = Ref((UInt16(1), UInt16(0)))    # Winsock's `struct linger` is two u_short
        rc = ccall((:setsockopt, "Ws2_32"), stdcall, Cint,
                   (Ptr{Cvoid}, Cint, Cint, Ptr{Cvoid}, Cint),
                   fd, SOL_SOCKET, SO_LINGER, linger, sizeof(linger))
        rc == 0 || error("setsockopt(SO_LINGER) failed: $(Libc.GetLastError())")
    else
        linger = Ref((Cint(1), Cint(0)))
        rc = ccall(:setsockopt, Cint, (Cint, Cint, Cint, Ptr{Cvoid}, Cuint),
                   reinterpret(Cint, fd), SOL_SOCKET, SO_LINGER, linger, sizeof(linger))
        rc == 0 || error("setsockopt(SO_LINGER) failed: $(Libc.errno())")
    end
    close(conn)
end

# ── Allocation measurement (#511) ────────────────────────────────────

"""
    Allocs

What `allocs` measured: `count` allocations and `bytes` allocated **per call**, each the
minimum over `runs` runs of `calls` calls. Its `show` names the Julia version and the
`--check-bounds` setting as well, because both move these numbers (#481, #505): a red should say
where it was measured, not leave that to be asked.
"""
struct Allocs
    count::Float64
    bytes::Float64
    runs::Int
    calls::Int
end

function Base.show(io::IO, m::Allocs)
    cb = ("auto", "yes", "no")[Base.JLOptions().check_bounds + 1]
    print(io, "Allocs(count = ", m.count, ", bytes = ", m.bytes, "; min of ", m.runs, " runs × ",
          m.calls, " calls; Julia ", VERSION, ", check-bounds=", cb, ")")
end

"""
    allocs(f; runs = 5, calls = 1) -> Allocs

The allocations, and bytes, of one call to `f()`. Every allocation assertion in the suite measures
through this, so they all follow the same rules:

- **`f` is warmed first**, so compiling it is never charged to it.
- **Both counters are measured**, so a test can bound either and a red reports both.
- **The minimum over `runs` runs**, each of `calls` calls. Both counters are process-wide: another
  task allocating mid-measurement is charged to `f`, and only ever adds. The minimum discards it.
  `calls > 1` averages over a loop, for claims finer than one allocation (`+ 0.5`).

`f` runs `1 + 2 * runs * calls` times in all — the warm-up, then one loop per counter in each
run — which a caller feeding it a fresh input per call has to provide for.

**Write the assertion so a red shows both sides.** `@test` prints the evaluated operands of a
comparison but not where they came from, so bind the measurements in a `@testset let`, which prints
each binding under the failure:

```julia
@testset let seed = allocs(() -> seed_once(req); calls = 1000),
             reference = allocs(() -> bind_once(req); calls = 1000)
    @test seed.count <= reference.count + 0.5
end
```

Bound at the target, not at the measured value: the JWT path is held under 50 allocations
against a measured 41, so a Julia release that moves a few does not fail CI. Prefer a bound on
what the code under test owns over a difference of totals against a reference: a reference's own
total can depend on its compilation state (#505). Give a sensitivity claim a
positive control in the same test — a variant that does the wasteful thing on purpose and must
break the bound. Measure under the suite's own flags: `Pkg.test` forces `--check-bounds=yes`, so a
standalone script's numbers are not evidence about the suite.
"""
function allocs(f::F; runs::Int = 5, calls::Int = 1) where {F}
    f()
    count = bytes = typemax(Int)
    for _ in 1:runs
        # `donotdelete`: a call the compiler could prove effect-free would otherwise be removed,
        # and measure 0 without measuring anything.
        count = min(count, @allocations(for _ in 1:calls; Base.donotdelete(f()); end))
        bytes = min(bytes, @allocated(for _ in 1:calls; Base.donotdelete(f()); end))
    end
    return Allocs(count / calls, bytes / calls, runs, calls)
end

# ── Inference (trim) ─────────────────────────────────────────────────

"""
    dynamic_calls(f, types) -> Vector{String}

The calls in the optimized code of `f` on `types` that dispatch at runtime: every `:call`
statement whose callee is not a builtin. A call inference resolved is an `:invoke`, or inlined,
so what is left is what `juliac --trim` reports as an unresolved call, and what the JIT pays a
dynamic dispatch for (docs/design/juliac-trim.md). An empty result is the pin.

It sees only `f`'s own body after inlining. A dynamic call inside a callee that was not inlined
shows up in that callee, so pin the function that owns the value.
"""
function dynamic_calls(f, types)
    found = String[]
    for (ci, _) in code_typed(f, types; optimize = true), st in ci.code
        st isa Expr && st.head === :call || continue
        g = st.args[1]
        callee = g isa GlobalRef ? getglobal(g.mod, g.name) : g isa QuoteNode ? g.value : g
        callee isa Core.Builtin || push!(found, sprint(show, st))
    end
    return found
end

end # module NitroCommon

@testitem "NitroCommon: allocs measures one call, and a red names both sides (#511)" tags=[:core] setup=[NitroCommon] begin
    using Test

    # The positive control: a call that allocates on purpose must show up, at both counters.
    # `sink` keeps the vector from being optimised away.
    sink = Ref{Any}(nothing)
    waste = allocs(() -> (sink[] = Vector{UInt8}(undef, 4096); nothing))
    @test waste.count >= 1
    @test waste.bytes >= 4096

    # And one that allocates nothing reads exactly 0, so a `== 0` claim can pass.
    v = [1, 2, 3]
    @test allocs(() -> (v[1] += 1; nothing)).bytes == 0
    @test allocs(() -> (v[1] += 1; nothing); calls = 100).count == 0

    # `calls` divides: 100 calls of one 4 KiB vector are one vector per call, not 100.
    per = allocs(() -> (sink[] = Vector{UInt8}(undef, 4096); nothing); calls = 100)
    # The count is exact everywhere; the bytes are not on Windows, where one 4 KiB vector read
    # 4167 B in one run and 4183 B in another. One vector's worth, not a hundred, is the claim.
    @test per.count == waste.count
    @test 4096 <= per.bytes < 2 * 4096

    # What a red prints: the Julia version and the check-bounds flag the numbers came from.
    shown = sprint(show, waste)
    @test occursin("Julia $(VERSION)", shown)
    @test occursin("check-bounds=", shown)
    @test occursin("min of 5 runs × 1 calls", shown)
end

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
# v1.13.0 and not on release-1.12; once no CI lane runs an unfixed Julia, the retry below is
# dead code.
#
# So every child prints its SIGINT disposition before its cue, and a child whose SIGINT is
# ignored is killed unpressed and replaced. The retry is gated on that PROOF, never on a
# timeout: a press that some task swallows still times out, and still goes red.
#
# The disposition is the first word of `struct sigaction`, which is the handler on macOS and
# on glibc alike; `1` is `SIG_IGN` on both. Children run the probe FIRST, before they load
# Nitro, on purpose: probed later, a `SIG_IGN` that Nitro itself caused would be retried away
# instead of failing the item.
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
    attempts >= 1 || throw(ArgumentError("attempts must be >= 1, got $attempts"))
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

# An in-memory store that says other processes can read it: every claim-capable backend an
# external queue's consumer could share (#514). Forwards the whole contract, the claim capability
# included, so the web side and a consumer run exactly as they would over a database, without
# one. In-process, both sides can share one `SharedStore`.
@testsetup module SharedClaimStore

using Nitro
using Nitro.Workers: AbstractWorkerStore, InMemoryWorkerStore
const _W = Nitro.Workers

export SharedStore

struct SharedStore <: AbstractWorkerStore
    inner::InMemoryWorkerStore
    # Run before every `claim_next!` with the queue name; a test sets it to make a claim throw.
    claim_hook::Base.RefValue{Any}
    # Run before every `get_task_info` with the id, and before every `requeue_expired!`: a test
    # sets them to make one read throw, or to see when adjudication runs. Called through
    # `invokelatest`: the consumer's loops start before the test defines the hook it then sets.
    read_hook::Base.RefValue{Any}
    requeue_hook::Base.RefValue{Any}
    # Run inside every `renew_leases!` with the runs, after the lease's start time is read and
    # before it is written, as PormG's renewal does: a test sleeps in it to make a renewal return
    # after the lease it wrote has run out (#623).
    renew_hook::Base.RefValue{Any}
    # Run after every `claim_next!` that claimed a run, with the run: the row is written, its
    # lease stamped from the clock read when the call began, and the call has not returned, as a
    # first PormG claim still committing and compiling its way out (#666). A test sleeps in it.
    claimed_hook::Base.RefValue{Any}
    # Run inside every `count_external_runs`, before it reads: a test sleeps in it to hold a
    # submit between its bound's count and its write (#711).
    count_hook::Base.RefValue{Any}
end
SharedStore() = SharedStore(InMemoryWorkerStore(), Ref{Any}(nothing), Ref{Any}(nothing), Ref{Any}(nothing),
                            Ref{Any}(nothing), Ref{Any}(nothing), Ref{Any}(nothing))

# Each forward with the contract's own arity: a varargs forward can be ambiguous with the
# generated fixed-arity fallbacks on `AbstractWorkerStore`.
for (f, n) in ((:set_task!, 2), (:replace_task!, 2), (:add_watcher!, 2),
               (:try_transition!, 3), (:delete_task!, 1), (:try_delete_task!, 2), (:cleanup_tasks!, 1),
               (:get_all_tasks, 1), (:get_queue_authorizer, 0), (:set_queue_authorizer!, 1),
               (:get_watch_authorizer, 0), (:set_watch_authorizer!, 1), (:get_error_redactor, 0),
               (:set_error_redactor!, 1), (:release_claim!, 2), (:clear_records!, 0),
               (:list_running_task_refs, 0))
    args = [Symbol("a", i) for i in 1:n]
    @eval _W.$f(s::SharedStore, $(args...); kw...) = _W.$f(s.inner, $(args...); kw...)
end
_W.task_locks(s::SharedStore) = _W.task_locks(s.inner)
function _W.count_external_runs(s::SharedStore, statuses; kw...)
    hook = s.count_hook[]
    hook === nothing || Base.invokelatest(hook)
    return _W.count_external_runs(s.inner, statuses; kw...)
end
_W._visible_across_processes(::SharedStore) = true
function _W.get_task_info(s::SharedStore, id; kw...)
    hook = s.read_hook[]
    hook === nothing || Base.invokelatest(hook, id)
    return _W.get_task_info(s.inner, id; kw...)
end
function _W.requeue_expired!(s::SharedStore, now; kw...)
    hook = s.requeue_hook[]
    hook === nothing || Base.invokelatest(hook)
    return _W.requeue_expired!(s.inner, now; kw...)
end
function _W.renew_leases!(s::SharedStore, consumer, runs; now = _W.current_time_utc(), kw...)
    hook = s.renew_hook[]
    hook === nothing || Base.invokelatest(hook, runs)
    return _W.renew_leases!(s.inner, consumer, runs; now, kw...)
end
function _W.claim_next!(s::SharedStore, queue::String, consumer::String; kw...)
    hook = s.claim_hook[]
    hook === nothing || hook(queue)
    run = _W.claim_next!(s.inner, queue, consumer; kw...)
    claimed = s.claimed_hook[]
    run === nothing || claimed === nothing || Base.invokelatest(claimed, run)
    return run
end

end # module SharedClaimStore

# ── The example tree's rot guard (test/examples_tests.jl) ──
#
# An example only stays right if something runs it. Each item in test/examples_tests.jl runs one
# example in a copy of it, so instantiating writes no Manifest.toml into the checkout. The copy's
# `[sources]` point Nitro at this checkout by an absolute path; the relative paths between an
# example's own projects hold inside the copy.
#
# One child per example, in its host project's environment, which resolves the example's other
# projects and Nitro through those sources: one resolve and one precompile, and every project's
# tests `include`d rather than run through `Pkg.test`, whose sandboxes would each resolve and
# precompile again and could outrun the suite's per-item ceiling. The trade: a package project's
# own `[targets]` are not resolved standalone, as the README's per-project `Pkg.test()` does.
# The child's `JULIA_LOAD_PATH` is pinned so this test environment cannot leak into what it
# resolves; `@stdlib` is what supplies `Test`.
@testsetup module ExampleHarness
using Test
using Nitro
using Pkg: TOML

export copy_example, run_child

"""
    copy_example(name, projects) -> String

Copy `examples/<name>` to a temporary directory, drop any Manifest.toml a local run left, and
point each project's Nitro source at this checkout. Returns the copy's path.
"""
function copy_example(name::String, projects)
    checkout = pkgdir(Nitro)
    example = joinpath(mktempdir(), name)
    cp(joinpath(checkout, "examples", name), example)
    for project in projects
        dir = joinpath(example, project)
        rm(joinpath(dir, "Manifest.toml"); force = true)
        file = joinpath(dir, "Project.toml")
        p = TOML.parsefile(file)
        @test p["sources"]["Nitro"] == Dict("path" => "../../..")   # the example tracks its checkout
        p["sources"]["Nitro"] = Dict("path" => checkout)
        open(io -> TOML.print(io, p), file, "w")
    end
    return example
end

"""
    run_child(root, script; timeout = 540) -> Bool

Run `script` in a fresh Julia whose project is `root`, and print its log when it fails. The
default timeout sits below the suite's 600 s per-item ceiling, so a hung child is killed and its
log printed here rather than the whole item being cut off with nothing to read.
"""
function run_child(root::String, script::String; timeout::Real = 540)
    logfile = joinpath(mktempdir(), "child.log")
    cmd = addenv(Cmd(`$(Base.julia_cmd()) --project=$root -e $script`; dir = root),
                 "JULIA_LOAD_PATH" => join(["@", "@stdlib"], Sys.iswindows() ? ';' : ':'),
                 "JULIA_PROJECT" => nothing)
    proc = open(logfile, "w") do log
        run(pipeline(cmd; stdout = log, stderr = log); wait = false)
    end
    if timedwait(() -> process_exited(proc), timeout) === :timed_out
        kill(proc)
        wait(proc)
    end
    ok = success(proc)
    ok || println(read(logfile, String))
    return ok
end
end # module ExampleHarness

@testitem "NitroCommon: dynamic_calls finds a runtime dispatch and only that" tags=[:core] setup=[NitroCommon] begin
    using Test
    untyped(r::Ref{Any}) = r[] + 1                  # `Ref{Any}` is abstract: `getindex` and `+` dispatch
    typed(r::Base.RefValue{Any}) = (r[]::Int) + 1   # concrete field, asserted value: both resolve
    @test length(dynamic_calls(untyped, (Ref{Any},))) == 2
    @test isempty(dynamic_calls(typed, (Base.RefValue{Any},)))
end
