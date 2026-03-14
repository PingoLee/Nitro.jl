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
    if applicable(callback, task_info)
        return Base.invokelatest(callback, task_info)
    end

    if applicable(callback)
        return Base.invokelatest(callback)
    end

    throw(MethodError(callback, (task_info,)))
end

function timeout_call(callback::Function; timeout::Int=3600)
    if timeout <= 0
        return callback()
    end

    result_channel = Channel{Any}(1)
    error_channel = Channel{Any}(1)

    task = @async begin
        try
            put!(result_channel, callback())
        catch error
            put!(error_channel, error)
        end
    end

    wait_result = timedwait(() -> isready(result_channel) || isready(error_channel), timeout)
    if wait_result == :timed_out
        try
            schedule(task, InterruptException(), error=true)
        catch
        end
        throw(ErrorException("Timeout of $(timeout)s exceeded"))
    end

    if isready(error_channel)
        throw(take!(error_channel))
    end

    return take!(result_channel)
end