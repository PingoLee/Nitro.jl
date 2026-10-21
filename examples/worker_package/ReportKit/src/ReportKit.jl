"""
    ReportKit

A reusable Nitro package that builds reports in the background: a route to request one, a
route to poll it, and the job that does the work on a worker queue. It follows the
reusable-package checklist in the *Extension Points* tutorial:

- [`routes`](@ref) **returns** route definitions and registers nothing.
- [`register_jobs!`](@ref) registers the package's job on the host's `App`, from the host's
  `main()`, never from a module body.
- The queue, the app and the way to tell who is asking all arrive as arguments. The package
  keeps no global and starts no worker of its own: the host owns `worker_startup`.
"""
module ReportKit

using HTTP
using Nitro
using Nitro.Workers: Job, Owner, TaskInfo, checkpoint!, get_task_status, register_job!,
                     scoped_task_key, submit_queued_task, update_progress!
using Random: RandomDevice

export ReportRequest, register_jobs!, routes

# The job's registered name. A named job, rather than a closure, is what lets the queue move to a
# separate consumer process later by configuration alone: a closure cannot leave the process that
# built it, a name and its JSON arguments can.
const JOB = "reportkit.build"

const MAX_ROWS = 1_000_000

"""
    ReportRequest(; title, rows = 1000)

What `POST` binds the request body to, and the job's argument. It crosses the worker store as
JSON, so it may only grow: add fields with defaults, never rename or retype one, or a report
queued by the previous version of the app no longer runs.
"""
@kwdef struct ReportRequest
    title::String
    rows::Int = 1000
end

# The work itself, run on the queue. `checkpoint!` yields, so a long report shares its thread, and
# throws if the task was cancelled; `update_progress!` is what a poll sees while it runs.
function build(task_info::TaskInfo, report::ReportRequest)
    total = 0
    step = max(1, report.rows ÷ 10)
    for row in 1:report.rows
        total += row
        if row % step == 0
            checkpoint!(task_info)
            update_progress!(task_info, 100 * row / report.rows)
        end
    end
    return Dict("title" => report.title, "rows" => report.rows, "total" => total)
end

"""
    register_jobs!(app::App)

Register ReportKit's job on `app`. Call it once, from the host's `main()` (or a test's setup),
before the first request. The registration belongs to `app`, so two apps in one process do not
share it, and registering twice on one app is an `ArgumentError`.
"""
register_jobs!(app::App) = register_job!(build, app, JOB, ReportRequest)

unauthorized() = Res.json(Dict("error" => "unauthorized"); status = 401)
not_found() = Res.json(Dict("error" => "not found"); status = 404)

# The id a client sees: random, and never the scoped task id, which embeds the user id.
new_id() = bytes2hex(rand(RandomDevice(), UInt8, 8))
is_report_id(id::AbstractString) = occursin(r"^[0-9a-f]{16}$", id)

# The caller as a task owner, or `nothing` when `user_of` found no user. Anything other than a
# string id is the host wiring `user_of` wrongly (an auth middleware that stores a dict at
# `getuser` wants `req -> getuser(req)["id"]`), so it fails loudly with a message saying that.
function request_owner(user_of::Function, req::HTTP.Request)
    user = user_of(req)
    user === nothing && return nothing
    user isa AbstractString || throw(ArgumentError(
        "ReportKit: `user_of` must return a user id String or `nothing`, got a $(typeof(user))"))
    return Owner(user)
end

# The handler only enqueues and answers at once, whatever the report costs. The job runs on a
# queue, whose concurrency bounds how many threads reports can take at a time, and its
# `checkpoint!` calls keep a long report from starving the request handlers sharing its thread.
function submit(app::App, queue::String, user_of::Function, namespace::String)
    return function (req::HTTP.Request, body::Json{ReportRequest})
        owner = request_owner(user_of, req)
        owner === nothing && return unauthorized()
        report = body.payload
        1 <= report.rows <= MAX_ROWS ||
            return Res.json(Dict("error" => "rows must be between 1 and $MAX_ROWS"); status = 400)
        id = new_id()
        submit_queued_task(app, queue, id, Job(JOB, report), owner)
        return Res.json(Dict("id" => id, "status_url" => url(app, "$namespace.status"; id));
                        status = 202)
    end
end

function status(app::App, user_of::Function)
    return function (req::HTTP.Request, id::String)
        owner = request_owner(user_of, req)
        owner === nothing && return unauthorized()
        is_report_id(id) || return not_found()
        # The task id is rebuilt under the caller's own identity, so a user can only ever name
        # their own reports. Another user's id finds nothing, and gets the same 404 as one that
        # never existed.
        task = get_task_status(app, scoped_task_key(id, owner), owner)
        task[:status] == "NOT_FOUND" && return not_found()
        # The stored error is the exception's text: internal detail, kept in the server's records
        # and logs. The client only learns that its report failed.
        message = task[:status] == "FAILED" ? "the report could not be built" : nothing
        return Res.json(Dict("id" => id, "status" => task[:status], "progress" => task[:progress],
                             "result" => task[:result], "error" => message))
    end
end

"""
    routes(app::App; queue, user_of, prefix = "/reports", namespace = "reports")
        -> Vector{RouteDefinition}

The routes this package contributes, all under `prefix`:

| Method | Path | Name | |
|--------|------|------|-|
| `POST` | `prefix` | `"<namespace>.submit"` | a [`ReportRequest`](@ref) body → `202` with `{"id", "status_url"}` |
| `GET`  | `prefix/<str:id>` | `"<namespace>.status"` | `{"id", "status", "progress", "result", "error"}`, or `404` |

- `queue`: the worker queue the job runs on. The host declares it in
  `worker_startup(app; queues = [...])`.
- `user_of(req)`: the id of the user making the request, a `String`, or `nothing` when there is
  none (a `401`). Every task belongs to a user, and only that user can read it. ReportKit does not
  authenticate anyone itself: the host puts its auth middleware in front of these routes and
  passes a function that reads what it resolved, such as `getuser`.

Returns a value and registers nothing: pass it to `urlpatterns(app, …)`.
"""
function routes(app::App; queue::String, user_of::Function, prefix::String = "/reports",
                namespace::String = "reports")
    return include_routes(prefix, [
        path("", submit(app, queue, user_of, namespace); method = "POST", name = "$namespace.submit"),
        path("/<str:id>", status(app, user_of); method = "GET", name = "$namespace.status"),
    ])
end

end # module
