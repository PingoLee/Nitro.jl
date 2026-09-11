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

function format_error(error)
    unwrapped = _unwrap_exception(error)
    io = IOBuffer()
    showerror(io, unwrapped)
    return String(take!(io))
end

function _invoke_task_callback(callback::Function, task_info::TaskInfo)
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

    task = @async begin
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
        @atomic task_info.cancel_requested = true

        # The docs used to note that a timed-out task can go on mutating external state "with
        # nothing to tell the operator". This is that signal, and it is now the only one.
        @warn "Worker task timed out. Its callback was NOT stopped and keeps a thread until it                returns; poll `cancel_requested(task_info)` in the callback to make the deadline                effective." task_id=task_info.id timeout=timeout

        throw(TaskTimeoutError(timeout))
    end

    if isready(error_channel)
        throw(take!(error_channel))
    end

    return take!(result_channel)
end