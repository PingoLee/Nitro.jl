# Nitro Proposal: Typed Mixed Multipart Extraction

## Context

Nitro already supports multipart uploads through two useful APIs:

- `multipart(req)` for low-level access to all multipart parts
- `Files{FormFile}` and `Files{Vector{FormFile}}` for typed file extraction

That works well for:

- text-only multipart inspection
- file-only route parameters

The gap appears in real enterprise handlers that need **both**:

- typed file extraction
- typed multipart text fields in the same request

The BI import endpoint in `/home/pingo03/app/bi_server_nitro` is a concrete example.
It needs:

- `ibge_id::Int`
- `user_id::String`
- `files::Vector{FormFile}`

Today the handler must mix two extraction styles:

```julia
function submit_data_import(req, files::Files{Vector{FormFile}})
    parts = multipart(req)
    ibge_id = parse(Int, parts["ibge_id"])
    user_id = parts["user_id"]
    uploaded = files.payload
end
```

This is workable, but it has some drawbacks:

- two extraction mechanisms in one handler
- manual normalization of text values
- multipart text values may surface as `String` or `SubString{String}`
- no single typed contract for validation
- repeated boilerplate in apps that stage uploads to workers

## Proposal

Add a **typed mixed multipart extractor** that binds both text fields and file fields into one declared payload.

Suggested names:

- `MultipartForm{T}`
- `Multipart{T}`

`MultipartForm{T}` is clearer and avoids confusion with the existing `multipart(req)` function.

## Proposed API

### Option A: Typed multipart struct extraction

```julia
struct ImportUpload
    ibge_id::Int
    user_id::String
    files::Vector{FormFile}
end

function submit_data_import(req, payload::MultipartForm{ImportUpload})
    data = payload.payload

    @assert data.ibge_id == 172100
    @assert !isempty(data.user_id)
    @assert !isempty(data.files)

    for file in data.files
        write(joinpath("tmp", file.filename), file.data)
    end

    return Res.json(Dict("count" => length(data.files)))
end
```

### Option B: Typed field extractors for multipart text

If Nitro wants a smaller first step, add typed text-field extraction that works against multipart bodies too:

```julia
function submit_data_import(
    req,
    ibge_id::Form{Int},
    user_id::Form{String},
    files::Files{Vector{FormFile}},
)
    municipality = ibge_id.payload
    user = user_id.payload
    uploaded = files.payload
end
```

This would be an improvement, but it still splits the request across multiple extractors.
For the BI and worker-offload use case, Option A is the better long-term API.

## Extraction Rules

For `MultipartForm{T}`:

1. Parse the request body once via the existing multipart parser.
2. For every field in `T`:
   - if field type is `FormFile`, bind a single uploaded file by field name
   - if field type is `Vector{FormFile}`, bind all uploaded files under that field name
   - otherwise treat it as a text field and parse using Nitro's existing conversion rules
3. Validate using the existing `validate(::T)` and extractor-local validators.

## Suggested Type Mapping

| Struct Field Type | Multipart Value Rule |
|---|---|
| `String` | single text field |
| `Int`, `Bool`, `Float64`, etc. | parse from single text field |
| `Union{T, Nothing}` | optional text field |
| `Vector{String}` | repeated text fields |
| `FormFile` | single uploaded file |
| `Vector{FormFile}` | repeated uploaded files |

## Example: BI Import Route

Current handler shape in BI:

```julia
function submit_data_import(req, files::Files{Vector{FormFile}})
    parts = multipart(req)
    ibge_id = get(parts, "ibge_id", nothing)
    user_id = get(parts, "user_id", nothing)
    uploaded = files.payload
    # stage and queue
end
```

Proposed handler shape:

```julia
struct SinanImportRequest
    ibge_id::Int
    user_id::String
    files::Vector{FormFile}
end

function submit_data_import(req, payload::MultipartForm{SinanImportRequest})
    data = payload.payload
    task_id = queue_import(data.ibge_id, data.user_id, data.files)
    return Res.json(Dict("task_id" => task_id))
end
```

This is materially simpler for application code.

## Validation Behavior

`MultipartForm{T}` should integrate with existing Nitro extractor validation:

```julia
function Nitro.validate(payload::SinanImportRequest)
    return payload.ibge_id > 0 && !isempty(payload.user_id) && !isempty(payload.files)
end
```

Field-level failures should produce a `ValidationError` with useful messages such as:

- missing text field `ibge_id`
- failed parse for `ibge_id::Int`
- missing file field `files`
- expected repeated file field for `files::Vector{FormFile}`

## Implementation Sketch

The feature can be built on top of the current multipart parser and extractor system.

Suggested additions:

### 1. New extractor type

```julia
@extractor MultipartForm
```

### 2. New extraction method

```julia
function extract(param::Param{MultipartForm{T}}, request::LazyRequest) :: MultipartForm{T} where {T}
    parsed = multipartbody(request)
    instance = build_multipart_struct(T, parsed)
    valid_instance = try_validate(param, instance)
    return MultipartForm(valid_instance)
end
```

### 3. Multipart struct builder

This helper would inspect field types and bind values according to the rules above.

## Possible Intermediate Step

If Nitro wants to stage the work incrementally:

### Phase 1

- normalize multipart text values to `String` consistently
- keep `Files{...}` as-is
- document the mixed handler pattern more explicitly

### Phase 2

- add `MultipartForm{T}`

That still improves app ergonomics immediately while keeping the full typed extractor as the target.

## Additional Related Improvements

### 1. Consistent text value normalization

`multipart(req)` should preferably return `String` for text values, not `SubString{String}`.

That reduces handler surprises and avoids method mismatches in app code.

### 2. Optional staged-file helper

For worker-offload systems, Nitro could also expose a helper such as:

```julia
stage_files(files::Vector{FormFile}; root="tmp/uploads")
```

or a new staged type:

```julia
struct StagedFile
    name::String
    filename::String
    content_type::String
    staged_path::String
    size_bytes::Int
end
```

This is separate from the typed mixed extractor, but often needed right after it.

## Why This Matters

For small demos, current multipart support is sufficient.

For larger applications, especially ones that:

- accept metadata and files together
- queue background jobs
- stage uploads to disk
- validate request contracts strictly

the current split between `Files{...}` and `multipart(req)` creates repeated glue code.

`MultipartForm{T}` would make Nitro handlers feel more uniform with the rest of the extractor system and reduce one of the remaining friction points in real file-upload workflows.

## Recommendation

Recommended path for Nitro.jl:

1. Normalize multipart text values to `String`
2. Add a typed `MultipartForm{T}` extractor for mixed text-plus-file payloads
3. Update the upload tutorial with one enterprise-grade example using worker offload

That would cover the real-world BI import case cleanly without breaking the existing lower-level multipart API.