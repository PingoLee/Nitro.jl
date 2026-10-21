# Reusable worker package

Two projects that show how background work ships as its **own package**: routes that request
and poll a job, the job itself, and nothing that runs on its own. It builds on
[`reusable_package/`](../reusable_package/), which sets the shape: a `routes(...)` function that
returns route definitions, namespaced route names, and state passed in by the host.

| Project | Role |
|---------|------|
| [`ReportKit/`](ReportKit/) | The reusable package: `POST /reports` queues a report, `GET /reports/<id>` polls it, and the job that builds it runs on a worker queue |
| [`ReportHost/`](ReportHost/) | An application that starts the worker runtime, mounts `ReportKit` under `/api/reports` behind a bearer-token middleware, and serves |

## What the package does, and what it leaves to the host

| `ReportKit` | The host |
|-------------|----------|
| `routes(app; queue, user_of, prefix, namespace)` **returns** the two routes | Picks the prefix and registers them once, at boot |
| `register_jobs!(app)` registers its named job on the host's `App` | Calls it from `main()`, never from a module body, before serving |
| Submits to the queue it is given | Declares that queue and owns the runtime: `worker_startup(app; queues, store)`, passed to `serve(app; middleware = [workers])` |
| Asks `user_of(req)` who is making the request, and gives every task that owner | Authenticates: its token middleware resolves the user, and `user_of = getuser` reads it |

Things the package gets right that are easy to get wrong:

- **The handler only enqueues.** `POST` answers `202` with the report's id and a `status_url`
  at once, so no request waits for a report. The job runs on a queue, whose concurrency bounds how
  many threads reports can take at a time; they share the thread pool with request handlers, which
  is why the job yields (below).
- **Every task has an owner.** Submission requires one (`Owner(user)`), and the status route
  rebuilds the task id under the *caller's* identity, so a user can only ever name their own
  reports. Someone else's id gets the same `404` as one that never existed. There is no
  "admin sees everything" path to get wrong; adding one means writing `System()`, which is easy
  to find in review.
- **A named job, not a closure.** `register_job!` and `Job(name, args)` put the job's name and
  its JSON arguments in the store. A closure cannot leave the process that built it; a name and
  its arguments can, so the queue can later move to a separate consumer process
  (`External(...)` and `consume!`) without touching the package. It also means `ReportRequest`
  may only grow: add fields with defaults, never rename one, or a report queued by the previous
  version of the app stops binding.
- **Long work yields.** The job calls `checkpoint!(task_info)` as it goes, which lets the request
  handlers on its thread run and stops a cancelled report, and `update_progress!` so a poll sees
  how far along it is.
- **A failure says only that it failed.** The stored error is the exception's text, which can
  carry internal detail (a SQL statement, a file path). The status route answers a fixed message;
  the detail stays in the server's task records and logs.

## Run it

From this directory, with Julia 1.12 or newer:

```bash
julia --project=ReportKit  -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
julia --project=ReportHost -e 'using Pkg; Pkg.instantiate(); Pkg.test()'

ALICE_TOKEN=change-me BOB_TOKEN=change-me-too \
    julia --project=ReportHost -e 'using ReportHost; ReportHost.main()'
```

Then, in another shell:

```bash
curl -X POST localhost:8000/api/reports -H 'Authorization: Bearer change-me' \
     -H 'Content-Type: application/json' -d '{"title": "totals", "rows": 100000}'
# {"id":"…","status_url":"/api/reports/…"}
curl localhost:8000/api/reports/<id> -H 'Authorization: Bearer change-me'
```

The host's tokens are a fixed list from the environment, enough to give every report an owner.
A real app would put the token middleware from [`auth_package/`](../auth_package/) in front of
these routes instead, with the same `user_of = req -> getuser(req)["id"]` shape.

The store is `InMemoryWorkerStore()`, so queued and finished reports are lost on restart. A
persistent store, such as PormG's `pormg_nitro_worker(db_key = "db")`, keeps them and needs no
change to the package.

The tests use `internalrequest(app, …)` on a fresh `App` with its own worker runtime, so they bind
no port and never touch the `ReportHost.app` that `main()` serves.

## Copying it out of this repository

Both `Project.toml` files point `[sources]` at this checkout (`Nitro = {path = "../../.."}`), so
the example always runs against the code next to it, and Nitro's own test suite instantiates and
tests both projects (`test/examples_tests.jl`). In a project of your own, install Nitro from its
repository pinned to a commit, as [`reusable_package/`](../reusable_package/README.md) shows.
