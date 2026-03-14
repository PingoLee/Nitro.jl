@enum TaskStatus PENDING=1 RUNNING=2 COMPLETED=3 FAILED=4 CANCELLED=5

current_time_utc() = Dates.now(Dates.UTC)

mutable struct TaskInfo
    id::String
    status::TaskStatus
    progress::Float64
    result::Any
    error::Union{Nothing, String}
    created_at::DateTime
    started_at::Union{Nothing, DateTime}
    completed_at::Union{Nothing, DateTime}
    watchers::Vector{String}
    sys_task::Union{Nothing, Task}
    queue_name::Union{Nothing, String}

    function TaskInfo(id::String; queue_name::Union{Nothing, String}=nothing)
        created_at = current_time_utc()
        return new(
            id,
            PENDING,
            0.0,
            nothing,
            nothing,
            created_at,
            nothing,
            nothing,
            String[],
            nothing,
            queue_name,
        )
    end
end

@kwdef struct TaskOptions
    priority::Int = 5
    timeout::Int = 3600
    retry_on_failure::Bool = false
    max_retries::Int = 3
end

struct QueueItem
    task_key::String
    callback::Function
    options::TaskOptions
    created_at::DateTime

    function QueueItem(task_key::String, callback::Function, options::TaskOptions)
        return new(task_key, callback, options, current_time_utc())
    end
end

mutable struct SequentialQueue
    channel::Channel{QueueItem}
    running::Bool
    current_task::Union{Nothing, String}
    exec_lock::ReentrantLock
    processor_task::Union{Nothing, Task}

    function SequentialQueue(size::Int=100)
        return new(Channel{QueueItem}(size), false, nothing, ReentrantLock(), nothing)
    end
end

mutable struct CleanupScheduler
    task::Task
    stop_signal::Channel{Nothing}
end