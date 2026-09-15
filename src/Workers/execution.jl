function _unwrap_exception(error)
    if error isa TaskFailedException
        return _unwrap_exception(error.task.exception)
    end

    if error isa CapturedException
        return _unwrap_exception(error.ex)
    end

    if error isa CompositeException && !isempty(error.exceptions)
        return _unwrap_exception(first(error.exceptions))
    end

    return error
end

"""
    format_error(error) -> String

Render an exception the way a failed task reports it, unwrapping the task/captured/composite
wrappers first.

This is the plain rendering utility and is unbounded on purpose — it is exported, and capping it
would change what every existing caller gets back. What gets *stored* goes through
`_store_error_text` instead, which redacts and truncates.
"""
function format_error(error)
    unwrapped = _unwrap_exception(error)
    io = IOBuffer()
    showerror(io, unwrapped)
    return String(take!(io))
end

"""
    MAX_STORED_ERROR_CHARS

The cap on a failed task's stored `error` text.

Counted in **characters**, not bytes, so truncation can never split a multi-byte codepoint and
leave invalid UTF-8 in the store. The value is a judgement call rather than a derived limit: long
enough for a stack-free `showerror` of any ordinary exception, short enough that a runaway message
cannot dominate the row. Spring Batch pins the analogous `exitDescription` at 2500 via its column
width; nothing here is that principled, so the number is stated rather than inferred.
"""
const MAX_STORED_ERROR_CHARS = 2048

function _truncate_error(text::AbstractString)
    total = length(text)
    total <= MAX_STORED_ERROR_CHARS && return String(text)

    # The marker counts against the cap rather than being appended past it. Appending after
    # truncating makes `MAX_STORED_ERROR_CHARS` not actually the cap -- the stored string comes out
    # at `MAX + length(marker)` -- which makes the constant's own docstring untrue and forces every
    # test to assert a slack bound instead of the exact, knowable one.
    marker = string(" …[truncated, ", total, " chars total]")
    keep = MAX_STORED_ERROR_CHARS - length(marker)
    keep <= 0 && return String(first(text, MAX_STORED_ERROR_CHARS))
    return string(first(text, keep), marker)
end

"""
    _store_error_text(store, error) -> String

What a failed task actually writes to its `error` field: `format_error`, then the store's
redaction hook, then the length cap.

The order is load-bearing. The hook is handed the **full** rendering so it can decide about the
whole message rather than a prefix, and the cap runs afterwards so a redactor cannot exceed it.

A task reaching here has already failed; a redactor that throws, or that returns something other
than a string, must not lose the failure on top of that. Both are caught and the stored value
degrades to the exception type, which is the most that is knowably safe.

**The log line carries only the redactor failure's TYPE, never the failure itself.** That is not
over-caution: a redactor that inspects the text it was handed — `parse`, `JSON.parse`, an
`@assert` with an interpolated message — raises an exception whose own message quotes `rendered`,
so logging `exception=` would republish, on the error channel, exactly the content the redactor
exists to suppress. It is the same "exceptions quote their input" mechanism this whole function is
here to contain, arriving one level up.
"""
function _store_error_text(store::AbstractWorkerStore, error)
    unwrapped = _unwrap_exception(error)
    rendered = format_error(unwrapped)

    redactor = get_error_redactor(store)
    isnothing(redactor) && return _truncate_error(rendered)

    fallback = string(nameof(typeof(unwrapped)))

    redacted = try
        Base.invokelatest(redactor, unwrapped, rendered)
    catch redactor_error
        # Deliberately NOT `exception=redactor_error`: its message may quote the text it was
        # handed, which is the content the redactor was installed to keep out of everything.
        @error "Worker error redactor threw; storing the exception type only. The redactor failure is not logged, because its message may quote the text it was given." redactor_error_type=typeof(redactor_error) store_type=typeof(store)
        return fallback
    end

    if !(redacted isa AbstractString)
        # A Julia function falls off its end into whatever the last expression returned, so a
        # redactor can silently hand back `nothing` or a number. Stringifying that would store
        # `"nothing"` -- a poisoned field rather than an honest degradation.
        @error "Worker error redactor returned a non-string; storing the exception type only." returned_type=typeof(redacted) store_type=typeof(store)
        return fallback
    end

    return _truncate_error(redacted)
end

function _invoke_task_callback(callback::Function, task_info::TaskInfo)
    # Mark this task as belonging to this run, so a `shutdown!` the callback itself triggers does
    # not wait for the run doing the triggering. See `CURRENT_RUN_KEY` (`types.jl`) for why the
    # marker is needed and an identity check on `current_task()` is not enough.
    #
    # Restored on the way out, not merely overwritten on the way in. With `TaskOptions(timeout=0)`
    # the callback runs directly on the long-lived SEQUENTIAL QUEUE PROCESSOR, which would then
    # carry a finished run's id between items -- and an entry wrongly skipped from a drain's
    # snapshot is never token-set, never waited for, and has its handle released: #176 itself,
    # silently. Nothing reaches that today (the only reader runs after this function has rewritten
    # the marker), so this makes the guarantee structural instead of incidental.
    storage = task_local_storage()
    previous = Base.get(storage, CURRENT_RUN_KEY, nothing)
    storage[CURRENT_RUN_KEY] = task_info.run_id
    try

        # The arity probe must run in the SAME world age as the call (#86). `invokelatest` is
        # world-age-agnostic; bare `applicable` is not -- it answers in the world age of its
        # caller. The sequential queue processor is a long-lived `Threads.@spawn`ed task created
        # by the FIRST `submit_sequential_task` (`queue.jl`), so it carries that world age for its
        # entire life. A callback whose method is first defined afterwards -- a REPL session, a
        # `@testitem` body, Revise redefining a handler -- was invisible to both bare checks. The
        # function then either threw `MethodError` for a method that exists, or silently picked
        # the WRONG arity: a callback that gained a `task_info` parameter after the processor
        # spawned still matched the older zero-arg method and was called without its `task_info`.
        if Base.invokelatest(applicable, callback, task_info)
            return Base.invokelatest(callback, task_info)
        end

        if Base.invokelatest(applicable, callback)
            return Base.invokelatest(callback)
        end

        throw(MethodError(callback, (task_info,)))
    finally
        if previous === nothing
            delete!(storage, CURRENT_RUN_KEY)
        else
            storage[CURRENT_RUN_KEY] = previous
        end
    end
end

"""
    timeout_call(callback, task_info; timeout=3600) -> Any

Run `callback` under a deadline and return its value, or throw [`TaskTimeoutError`](@ref).

`task_info` is taken rather than closed over so the deadline can reach the callback: on expiry
this sets the run's cancellation token, which a cooperative callback polls with
[`cancel_requested`](@ref). Taking it here also keeps the world-age probe in
`_invoke_task_callback` at a single call site.

**The deadline bounds the WAIT, not the work.** Nothing stops a Julia task, so a callback that
does not poll the token runs to completion regardless — holding a thread the whole time. That is
the same contract as Java's `Future.get(timeout)` and Go's `context.WithTimeout`, which likewise
accept a leaked goroutine rather than an unsafe kill. Nitro used to also throw an
`InterruptException` into the task, which was unusable for the CPU-bound callbacks this exists to
bound and fatal once worker bodies migrate between threads
([#127](https://github.com/PingoLee/Nitro.jl/issues/127)).
"""
function timeout_call(callback::Function, task_info::TaskInfo; timeout::Int=3600)
    if timeout <= 0
        return _invoke_task_callback(callback, task_info)
    end

    result_channel = Channel{Any}(1)
    error_channel = Channel{Any}(1)

    # `Threads.@spawn`, not `@async` (#30). Under `@async` this child was pinned to the
    # monitoring task's own thread, so a CPU-bound callback -- precisely what a deadline exists
    # to bound -- starved the `timedwait` below and the timeout mostly never fired at all. It
    # fires now. The flip side is that an abandoned callback occupies a `:default`-pool slot,
    # the same pool serving HTTP, until it returns; see the `@warn` on the timeout path.
    task = Threads.@spawn begin
        try
            put!(result_channel, _invoke_task_callback(callback, task_info))
        catch error
            put!(error_channel, error)
        end
    end

    wait_result = timedwait(() -> isready(result_channel) || isready(error_channel), timeout)
    if wait_result == :timed_out
        # Ask, because we cannot tell. The task above keeps running until the callback
        # returns; this is the only thing that can make it stop, and only if it polls.
        _request_cancel!(task_info, :timeout)

        # The docs used to note that a timed-out task can go on mutating external state "with
        # nothing to tell the operator". This is that signal, and it is now the only one.
        @warn "Worker task timed out. Its callback was NOT stopped and keeps a thread " *
              "until it returns; poll `cancel_requested(task_info)` in the callback to " *
              "make the deadline effective." task_id=task_info.id timeout=timeout

        throw(TaskTimeoutError(timeout))
    end

    if isready(error_channel)
        throw(take!(error_channel))
    end

    return take!(result_channel)
end