# Named jobs (#514, step 2): a job registered on the App under a name, with a typed argument struct
# that crosses the store as JSON. A closure cannot leave the process that built it; a name and
# its arguments can, so a queue that runs named jobs can later move to a consumer process
# (`docs/design/workers-external-consumer.md` §2) by configuration alone.
#
# In-process, the queue item carries the arguments encoded at submit, the same text the row
# records, and the run binds them when it starts. A consumer will build the same `NamedJobRun`
# from a claimed row's `job_name`/`job_args`, so both placements go through one bind.

"""
    Job(name, args)

A named job to submit, in place of a closure, to [`submit_task`](@ref) or
[`submit_queued_task`](@ref) on an `App`:

```julia
submit_queued_task(app, "heavy", "fit-42", Job("fit_model", FitArgs(dataset_id = 42)), Owner(uid))
```

`name` must be registered on that `App` with [`register_job!`](@ref), and `args` must be an
instance of the type it was registered with. Both are checked at submit, after the queue
authorizer and before anything is written: an unknown name, an argument of another type, or a
value that does not survive JSON is an `ArgumentError`.
"""
struct Job{T}
    name::String
    args::T
end
Job(name::AbstractString, args::T) where {T} = Job{T}(String(name), args)

# A job name is stored in `nitro_task.job_name`, a VARCHAR(255) on the PormG store, so a longer
# one would register fine and then fail every submit on PostgreSQL.
const MAX_JOB_NAME_LENGTH = 255

# One registration: the argument type the stored JSON binds to, and the code that runs it.
struct JobDefinition
    name::String
    args_type::DataType
    handler::Function
end

# Per App, never process-global (#31): two Apps in one process do not share job names. It lives in
# the App's extension slot, not on the `WorkerRuntime`: an app registers its jobs in its setup
# function BEFORE `worker_startup` installs a runtime, and `uninstall!` drops the runtime's slot on
# every `terminate`, while the registrations must outlive a re-serve.
struct JobRegistry
    jobs::Dict{String, JobDefinition}
    lock::ReentrantLock
end
JobRegistry() = JobRegistry(Dict{String, JobDefinition}(), ReentrantLock())

const JOB_REGISTRY_KEY = :workers_jobs

# The App's registry, created on first use. Under the extension lock, so two first registrations
# racing cannot each install one and lose the other's job.
function _job_registry(ctx::App)
    return lock(ctx.service.extensions_lock) do
        registry = get_extension(ctx, JOB_REGISTRY_KEY, nothing)
        registry isa JobRegistry && return registry
        fresh = JobRegistry()
        set_extension!(ctx, JOB_REGISTRY_KEY, fresh)
        return fresh
    end
end

_job_definition(registry::JobRegistry, name::String) =
    lock(() -> Base.get(registry.jobs, name, nothing), registry.lock)

"""
    register_job!(handler, app::App, name, ArgsType)
    register_job!(app, name, ArgsType) do task_info, args
        …
    end

Register a named job on `app`, so that [`Job`](@ref)`(name, args)` can be submitted in place of a
closure ([#514](https://github.com/PingoLee/Nitro.jl/issues/514)). `handler(task_info, args)`
receives the run's `TaskInfo` and the arguments bound to `ArgsType`, and its return value is the
task's result, as a closure's is.

```julia
@kwdef struct FitArgs
    dataset_id::Int
    epochs::Int = 10
end

function setup_workers!(app)
    register_job!(app, "fit_model", FitArgs) do task_info, args
        fit(args.dataset_id; epochs = args.epochs, on_batch = () -> checkpoint!(task_info))
    end
end
```

**Call it at startup, from a function, never from a module body.** It writes app state, and a
module body runs only in the precompile worker. The registry belongs to `app`: another `App` in
the same process does not see these names.

**Argument types evolve additively only.** The arguments are stored as JSON and bound back to
`ArgsType` when the run starts, with the same binder as `Json{T}`. A job queued by one version of
the app may be run by the next, so the new type must still bind the old JSON: add fields **with
defaults** (`@kwdef`), and never rename, remove or retype one. Arguments that do not bind, and a
name the running process has not registered, are recorded `FAILED` (a [`JobError`](@ref) naming
the job and the type, never the argument values) and are never retried.

Refused with an `ArgumentError`: an empty `name` or one longer than 255 characters, a `name`
already registered on `app`, an
`ArgsType` that is not a concrete struct type or that holds a `Symbol` anywhere (Nitro's JSON
binder never builds one, so the job could never run), and a `handler` with no method for
`(task_info, args)`.
"""
function register_job!(handler::Function, ctx::App, name::AbstractString, ::Type{T}) where {T}
    job = String(name)
    isempty(job) && throw(ArgumentError("a job name must not be empty"))
    length(job) <= MAX_JOB_NAME_LENGTH || throw(ArgumentError(
        "a job name is at most $MAX_JOB_NAME_LENGTH characters, got $(length(job))"))
    T isa DataType && isconcretetype(T) && isstructtype(T) || throw(ArgumentError(
        "job \"$job\": the argument type must be a concrete struct type, got $T"))
    interns_client_strings(T) && throw(ArgumentError(
        "job \"$job\": $T holds a Symbol, which Nitro's JSON binder never builds; " *
        "use an @enum, or a String"))
    # In the newest world, as the run will call it (`invokelatest`), by the #86 rule in
    # `_invoke_task_callback`: a handler method defined after the caller's world was fixed exists.
    Base.invokelatest(hasmethod, handler, Tuple{TaskInfo, T}) || throw(ArgumentError(
        "job \"$job\": the handler has no method for `(task_info, args::$T)`"))
    registry = _job_registry(ctx)
    lock(registry.lock) do
        haskey(registry.jobs, job) && throw(ArgumentError(
            "job \"$job\" is already registered on this App; a job name is registered once"))
        registry.jobs[job] = JobDefinition(job, T, handler)
    end
    return nothing
end

"""
    JobError

Why a named job's run was recorded `FAILED` before its handler ran
([#514](https://github.com/PingoLee/Nitro.jl/issues/514)): its name is not registered in the
process that ran it (`reason = :unknown`), or its stored arguments do not bind to the registered
type (`reason = :unbound`). Never retried: every retry would bind the same text against the same
registry. The message names the job and the type, never the arguments, which are application data.
"""
struct JobError <: Exception
    job::String
    args_type::Union{Nothing, DataType}
    reason::Symbol
end

function Base.showerror(io::IO, e::JobError)
    if e.reason === :unknown
        print(io, "JobError: job \"", e.job, "\" is not registered in this process. ",
                  "It was submitted by code that registers it; run a version of the app that does")
    else
        print(io, "JobError: the arguments of job \"", e.job, "\" do not bind to ", e.args_type,
                  ". An argument type may only gain fields with defaults; renaming, removing or ",
                  "retyping a field breaks every run already queued")
    end
end

# The submit side: the arguments as the JSON text the run will bind, after checking that they bind
# back to the REGISTERED type. "Round-trip" means exactly that -- serializes through the store's
# write path (and its depth bound, #344), and binds back -- not that the bound value `==` the
# original: `==` on a mutable field, or a `Dict`'s iteration order, would refuse sound values.
function _encode_job(registry::JobRegistry, job::Job)::String
    def = _job_definition(registry, job.name)
    def === nothing && throw(ArgumentError(
        "job \"$(job.name)\" is not registered on this App; register it with " *
        "`register_job!(app, \"$(job.name)\", ArgsType)` in the app's startup code"))
    job.args isa def.args_type || throw(ArgumentError(
        "job \"$(job.name)\" takes $(def.args_type) arguments, got a $(typeof(job.args))"))
    json = nothing
    try
        encoded = _json_for_storage(job.args)
        json_bind(def.args_type, encoded)
        json = encoded
    catch e
        is_unrecoverable(e) && rethrow()
    end
    # Thrown after the `catch` has closed, so the cause is not on the exception stack: a JSON.jl
    # parse error quotes the text it was given, which is the application's data.
    json === nothing && throw(ArgumentError(
        "job \"$(job.name)\": the $(def.args_type) arguments do not round-trip through JSON. They " *
        "must serialize within the $(MAX_JSON_DEPTH)-level depth limit and bind back to $(def.args_type)"))
    return json
end

# The run side: what a named submission executes. A `Function`, so it travels through the queue
# item, `timeout_call` and `_invoke_task_callback` exactly as a closure does. The name is resolved
# when the run STARTS, against the registry of the App it was submitted on: that is the lookup a
# consumer process makes for a row another process wrote.
struct NamedJobRun <: Function
    registry::JobRegistry
    name::String
    args_json::String
end

function (run::NamedJobRun)(task_info::TaskInfo)
    def = _job_definition(run.registry, run.name)
    def === nothing && throw(JobError(run.name, nothing, :unknown))
    args = _bind_job_args(def, run.args_json)
    return Base.invokelatest(def.handler, task_info, args)
end

# A stored `(job_name, job_args)` pair as a run on `ctx`'s registry, with no submit-side check:
# the arguments came from a row, so they bind or fail when the run starts. This is what a consumer
# process does with a claimed row (step 3), and how the tests stage a row an older deploy wrote.
_job_run(ctx::App, name::AbstractString, args_json::AbstractString) =
    NamedJobRun(_job_registry(ctx), String(name), String(args_json))

function _bind_job_args(def::JobDefinition, json::String)
    bound = nothing
    ok = false
    try
        bound = json_bind(def.args_type, json)
        ok = true
    catch e
        is_unrecoverable(e) && rethrow()
    end
    # After the `catch`, for the same reason as `_encode_job`, and without the cause: its message
    # would quote the stored arguments into the task's `error`.
    ok || throw(JobError(def.name, def.args_type, :unbound))
    return bound
end

# What a submit body runs, resolved by `_prepare_run` once the authorizer has allowed the submit:
# `(callback, job_name, job_args)`. A closure records no job; a named job is encoded here, which
# is where a job that does not round-trip is refused.
struct _ClosureRun
    callback::Function
end
struct _PendingJob{T}
    registry::JobRegistry
    job::Job{T}
end

_prepare_run(work::_ClosureRun) = (work.callback, nothing, nothing)
function _prepare_run(work::_PendingJob)
    job_args = _encode_job(work.registry, work.job)
    return (NamedJobRun(work.registry, work.job.name, job_args), work.job.name, job_args)
end

@noinline _throw_job_needs_app(f::String) = throw(ArgumentError(
    "a Job is submitted through its App, whose registry knows the name: `$f(app, …, Job(…), owner)`"))
