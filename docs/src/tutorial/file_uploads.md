# File Uploads

Nitro.jl supports `multipart/form-data` file uploads, including **multiple files** in a single request. This is useful when users need to upload `.xlsx`, `.dbf`, `.csv`, or any other file types.

Just like Django separates **views** (logic) from **urls** (routing), in Nitro you define your
handler functions in a dedicated file and wire them up in a routes file. This keeps large
applications organized and testable.

## FormFile

Every uploaded file is represented as a [`FormFile`](@ref) with four fields:

| Field          | Type             | Description                                      |
|----------------|------------------|--------------------------------------------------|
| `name`         | `String`         | The form field name                              |
| `filename`     | `String`         | The original filename sent by the client         |
| `content_type` | `String`         | MIME type (e.g. `"application/octet-stream"`)    |
| `data`         | `Vector{UInt8}`  | Raw file bytes                                   |

!!! warning "Never trust `filename` — sanitize before writing to disk"
    `FormFile.filename` is attacker-controlled. Writing it directly —
    `write(joinpath("uploads", f.filename), f.data)` — is a **path-traversal**
    vulnerability: a client can send `../../etc/cron.d/evil` or an absolute path
    and escape your upload directory. Always reduce the filename to a bare,
    validated basename first. The examples below use this helper:

    ```julia
    # Strip any directory components and reject empty / dot names.
    function safe_filename(name::AbstractString)
        base = basename(name)                       # drops ".." / "/" path parts
        (isempty(base) || base in (".", "..")) && return string("upload_", rand(UInt32))
        return base
    end
    ```

    For stronger guarantees, generate your own name (e.g. a UUID) and keep the
    original only as metadata, as the worker example near the end does.

## Project structure

For a module that handles file uploads the recommended layout is:

```
src/
├── Handlers/
│   └── UploadHandlers.jl   # handler functions (the "views")
└── Routes.jl               # urlpatterns (the "urls")
```

## Handlers (the "views")

Define your handler functions in `src/Handlers/UploadHandlers.jl`.
Each function receives the request and typed extractor parameters — Nitro injects values automatically.

### Low-level: `multipart(req.request)`

Use `multipart` when you need to inspect every field before deciding what to do:

```julia
# src/Handlers/UploadHandlers.jl
module UploadHandlers

using Nitro

export upload_mixed

function upload_mixed(req)
    parts = multipart(req.request)

    # Text field
    description = get(parts, "description", "")  # => String

    # Single file field
    doc = get(parts, "document", nothing)         # => FormFile or nothing
    isnothing(doc) && return Res.status(400, "document field is required")

    # Multiple files under the same field name
    attachments = get(parts, "attachments", FormFile[])
    attachments = attachments isa FormFile ? [attachments] : attachments

    for f in attachments
        write(joinpath("uploads", safe_filename(f.filename)), f.data)
    end

    return Res.json(Dict(
        "description" => description,
        "document"    => doc.filename,
        "attached"    => length(attachments),
    ))
end

end # module UploadHandlers
```

### Using the `Files` extractor

For structured handlers, declare `Files{T}` parameters. Nitro parses the multipart body
and injects values automatically — no manual parsing needed.

**Single file** — parameter name must match the form field name:

```julia
# src/Handlers/UploadHandlers.jl
module UploadHandlers

using Nitro

export upload_single, upload_all

function upload_single(req, document::Files{FormFile})
    file = document.payload

    write(joinpath("uploads", safe_filename(file.filename)), file.data)

    return Res.json(Dict(
        "saved"        => file.filename,
        "content_type" => file.content_type,
        "size"         => length(file.data),
    ))
end

function upload_all(req, files::Files{Vector{FormFile}})
    all_files = files.payload

    for f in all_files
        write(joinpath("uploads", safe_filename(f.filename)), f.data)
    end

    return Res.json(Dict(
        "count" => length(all_files),
        "names" => [f.filename for f in all_files],
    ))
end

end # module UploadHandlers
```

### Using the `MultipartForm` extractor (text fields **and** files)

`Files{T}` only extracts files. When a request mixes **typed text fields and files** in the
same `multipart/form-data` body — the common "metadata + upload" case — declare a
`MultipartForm{T}` parameter. Nitro parses the body once and binds every field of `T` by
its type, with validation and automatic `400` responses on bad input.

```julia
struct ImportUpload
    user_id  :: String
    ibge_id  :: Int                       # text field, parsed to Int
    dry_run  :: Union{Nothing, Bool}      # optional — `nothing` when absent
    tags     :: Vector{String}            # repeated text fields
    files    :: Vector{FormFile}          # all files under the "files" field
end

# Optional: a validator runs automatically; returning `false` → 400
Nitro.validate(u::ImportUpload) = u.ibge_id > 0 && !isempty(u.user_id)

function upload_mixed(req, upload::MultipartForm{ImportUpload})
    data = upload.payload                 # fully typed ImportUpload

    for f in data.files
        write(joinpath("uploads", safe_filename(f.filename)), f.data)
    end

    return Res.json(Dict(
        "user_id" => data.user_id,
        "ibge_id" => data.ibge_id,
        "dry_run" => data.dry_run,
        "files"   => [f.filename for f in data.files],
    ))
end
```

Field binding rules:

| Field type in `T`           | Bound from                                        |
|-----------------------------|---------------------------------------------------|
| `String`                    | single text field (matched by field name)         |
| `Int`, `Float64`, `Bool`, … | single text field, parsed                          |
| `Vector{String}`            | all text fields sent under that name              |
| `FormFile`                  | single uploaded file                              |
| `Vector{FormFile}`          | all uploaded files under that name                |
| `Union{X, Nothing}`         | optional — binds to `nothing` when the field is absent |

`T` only needs to be constructible from its fields in declaration order, so a plain `struct`
or a `@kwdef struct` both work. With a `@kwdef struct`, a field's default is used when that
field is absent from the body (a `Union{…, Nothing}` field still binds to `nothing` when
absent, which takes precedence over a default). A missing required field, an unparseable
value, or a failing `validate(::T)` all raise a `ValidationError`, which Nitro turns into a
`400` response.

## Routes (the "urls")

Wire everything up in `src/Routes.jl`. Handlers are just regular functions referenced by name:

```julia
# src/Routes.jl
module Routes

using Nitro
using ..UploadHandlers

export urlpatterns

function urlpatterns(config)
    return [
        path("/api/upload",          UploadHandlers.upload_mixed,  method="POST"),
        path("/api/upload/single",   UploadHandlers.upload_single, method="POST"),
        path("/api/upload/multiple", UploadHandlers.upload_all,    method="POST"),
    ]
end

end # module Routes
```

## Best Practices for Large Systems (e.g. BI/Enterprise)

If your system processes very large files (e.g. 100MB+ `.dbf` or `.xlsx` files) or requires
complex validation/import steps, **never process the file directly in the request handler.**
This blocks the thread and causes client timeouts.

Instead, follow this **Stage & Work** pattern:

1. **Stage** — write the file bytes to a temporary directory and get a path.
2. **Submit** — enqueue a background `Nitro.Workers` task with that path.
3. **Notify** — return a `task_id` immediately so the client can poll for status.

**Handler** (`src/Handlers/ImportHandlers.jl`):

```julia
module ImportHandlers

using Nitro
using UUIDs

export submit_import

const STAGING_DIR = "data/tmp"

function submit_import(req, upload::Files{FormFile})
    file = upload.payload

    # Scope the task to its owner. `req.user` is `nothing` unless auth middleware
    # ran, so check before reaching into it — the route below carries
    # `login_required()`, which is what makes the Principal branch the real one.
    user_id = req.user === nothing ? "anonymous" : something(req.user.id, "anonymous")

    # 1. Stage to disk — the UUID task_key is the real identity; the original
    #    filename is sanitized to a bare basename so it can't traverse paths.
    task_key   = "import_$(uuid4())"
    staged_path = joinpath(STAGING_DIR, "$(task_key)_$(safe_filename(file.filename))")
    mkpath(dirname(staged_path))
    write(staged_path, file.data)

    # 2. Offload to a background worker
    # The worker reads from disk so the request memory is freed immediately.
    # Returns the STORED id ("<user_id>::import_<uuid>"), not task_key — stage the
    # file under task_key, but hand the client back what the submit returned.
    task_id = Nitro.Workers.submit_sequential_task(
        Nitro.CONTEXT[],
        "import_queue",
        task_key,
        (task) -> MyImportModule.process(staged_path),
        user_id,
    )

    # 3. Return immediately
    return Res.json(Dict(
        "status"    => "queued",
        "task_id"   => task_id,
        "check_url" => "/api/worker/status/$task_id",
    ))
end

end # module ImportHandlers
```

**Routes** (`src/Routes.jl`):

```julia
path("/api/import", ImportHandlers.submit_import, method="POST",
     middleware=[GuardMiddleware(login_required())]),
```

## Sending multipart requests (client side)

Use `HTTP.jl` to build multipart requests from the client:

```julia
using HTTP

body = HTTP.Form(Dict(
    "file1" => open("data.dbf"),
    "file2" => HTTP.Multipart("sheet.xlsx", open("sheet.xlsx"),
                    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
    "description" => "My data files",
))

HTTP.post("http://localhost:8080/api/upload", [], body)
```

## API Reference

```@docs
FormFile
multipart
Files
```
