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
        write(joinpath("uploads", f.filename), f.data)
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

    write(joinpath("uploads", file.filename), file.data)

    return Res.json(Dict(
        "saved"        => file.filename,
        "content_type" => file.content_type,
        "size"         => length(file.data),
    ))
end

function upload_all(req, files::Files{Vector{FormFile}})
    all_files = files.payload

    for f in all_files
        write(joinpath("uploads", f.filename), f.data)
    end

    return Res.json(Dict(
        "count" => length(all_files),
        "names" => [f.filename for f in all_files],
    ))
end

end # module UploadHandlers
```

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

    # 1. Stage to disk
    task_key   = "import_$(uuid4())"
    staged_path = joinpath(STAGING_DIR, "$(task_key)_$(file.filename)")
    mkpath(dirname(staged_path))
    write(staged_path, file.data)

    # 2. Offload to a background worker
    # The worker reads from disk so the request memory is freed immediately.
    task_id = Nitro.Workers.submit_task(
        Nitro.CONTEXT[],
        "import_queue",
        task_key,
        (task) -> MyImportModule.process(staged_path),
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
path("/api/import", ImportHandlers.submit_import, method="POST"),
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
