@enum TaskStatus PENDING=1 RUNNING=2 COMPLETED=3 FAILED=4 CANCELLED=5

current_time_utc() = Dates.now(Dates.UTC)

"""
    DEFAULT_QUEUE_NAME

Queue name that [`submit_task`](@ref) authorizes against. Unqueued tasks do not
run through a `SequentialQueue`, but they are still submissions, so they are
still subject to the store's queue authorizer — under this name, following the
default-queue convention every comparable queue uses (Sidekiq `default`, River
`QueueDefault`).

A `TaskInfo.queue_name` stays `nothing` for these tasks: that field records the
*sequential* queue a task belongs to, and an unqueued task belongs to none.
"""
const DEFAULT_QUEUE_NAME = "default"

"""
    TASK_KEY_DELIMITER

Separator between the owner and the caller-supplied key in a `:user`-scoped task
id. `user_id` may not contain it; see [`scoped_task_key`](@ref).
"""
const TASK_KEY_DELIMITER = "::"

# Sentinel for "this field was not supplied", where `nothing` is itself a legal value.
# `try_transition!` needs it for `result`: a task that completes with `nothing` is not the
# same as one whose transition should leave the stored result alone.
struct _Unsupplied end
const UNSUPPLIED = _Unsupplied()

"""
    TaskAuthority

Who is asking, and with what rights. Read and manage APIs dispatch on this instead
of accepting an optional `user_id` whose *absence* meant "skip the ownership check"
— the shape that made the unsafe call the shorter one
([#48](https://github.com/PingoLee/Nitro.jl/issues/48)).

Two implementations: [`Owner`](@ref), a validated task identity, and [`System`](@ref),
the explicit bypass.
"""
abstract type TaskAuthority end

# One definition of a legal owner, shared by `Owner` and by `scoped_task_key`, so the
# rules that make `(user, key) -> id` injective cannot drift apart.
function _validate_owner_id(uid::String)
    isempty(uid) && throw(ArgumentError(
        "an owner id must not be empty: \"\" used to mean \"skip the ownership check\", " *
        "which is exactly the bypass this type exists to remove — use System() to be explicit"))
    if occursin(TASK_KEY_DELIMITER, uid) || endswith(uid, ":")
        throw(ArgumentError(
            "user_id '$uid' must not contain '$TASK_KEY_DELIMITER' or end in ':': that would " *
            "make the owner half of a :user-scoped task id ambiguous"))
    end
    return uid
end

"""
    Owner(user_id) <: TaskAuthority

A validated task identity. It acts wherever an identity appears — submitting, granting,
reading, cancelling — so an identity that can be *granted* access is always one that can
later be constructed to *use* that access.

Rejects the three shapes that would break the id invariant proved by
[`scoped_task_key`](@ref): an empty id, one containing `$(TASK_KEY_DELIMITER)`, and one
ending in `:`. Rejecting the empty id is what lets [`owner_of`](@ref) be trusted —
`owner_of(id) == u` is equivalent to `startswith(id, u * "$(TASK_KEY_DELIMITER)")` only
because `Owner("")` cannot exist.
"""
struct Owner <: TaskAuthority
    user_id::String

    Owner(user_id::AbstractString) = new(_validate_owner_id(String(user_id)))
end

"""
    System() <: TaskAuthority

The explicit authorization bypass: every read or action it accompanies is unscoped.

It is deliberately something you have to name. The previous bypass was an *omitted*
argument, so the unsafe call was also the shortest one, and a call site that had simply
forgotten to scope was indistinguishable from one that meant not to. Passing `System()`
is greppable in review and in a security audit; forgetting an argument is not.
"""
struct System <: TaskAuthority end

"""
    owner_of(task_id) -> Union{Nothing, String}

The owner half of a `:user`-scoped task id, or `nothing` when the id has none.

[`scoped_task_key`](@ref) builds `"<user_id>$(TASK_KEY_DELIMITER)<task_key>"`, and its
three rules — an owner may not contain `$(TASK_KEY_DELIMITER)`, may not end in `:`, and
a `:global` key may not contain `$(TASK_KEY_DELIMITER)` at all — make that mapping
injective. So the **first** `$(TASK_KEY_DELIMITER)` is always the delimiter and
everything before it is the owner, even when the key itself contains more of them.

A `:global` id is stored verbatim and therefore has no owner half. For those tasks
`watchers` remains the whole gate, exactly as before.
"""
function owner_of(task_id::AbstractString)
    id = String(task_id)
    range = findfirst(TASK_KEY_DELIMITER, id)
    range === nothing && return nothing   # :global, or a pre-#19 unscoped id
    first(range) == 1 && return nothing   # "::key" — an empty owner half is not an identity
    return id[1:prevind(id, first(range))]
end

mutable struct TaskInfo
    id::String
    status::TaskStatus
    @atomic progress::Float64
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

# Authority comes from the id; `watchers` is a list of ADDITIONAL grants layered on top
# of it. For a `:global` id `owner_of` is `nothing`, so the first disjunct is always
# false and `watchers` remains the whole gate there — unchanged from before.
_is_authorized(::System, ::TaskInfo) = true

function _is_authorized(authority::Owner, task_info::TaskInfo)
    owner = owner_of(task_info.id)
    owner !== nothing && owner == authority.user_id && return true
    return authority.user_id in task_info.watchers
end

# Split on the authority rather than branched inside one method, so `System` never
# reaches an `authority.user_id` field access.
_authorize_task!(::System, ::TaskInfo, ::AbstractString) = nothing

function _authorize_task!(authority::Owner, task_info::TaskInfo, action::AbstractString)
    _is_authorized(authority, task_info) && return nothing
    throw(AuthorizationError(
        "User '$(authority.user_id)' is not authorized to $action task '$(task_info.id)'"))
end

"""
    update_progress!(task_info::TaskInfo, value::Real)

Atomically set a task's progress (0–100 scale) and return the task.

Call this from task callbacks instead of assigning `task_info.progress`
directly. The field is atomic, so a plain assignment raises
`ConcurrencyViolationError`; routing writes through this function keeps progress
updates race-free with the status readers that poll a running task.
"""
function update_progress!(task_info::TaskInfo, value::Real)
    @atomic task_info.progress = Float64(value)
    return task_info
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