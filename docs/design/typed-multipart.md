# Design: Typed Mixed Multipart Extraction (`MultipartForm{T}`)

> **Status:** design record. Moved here from `.github/skills/` — it is a proposal, not a repeatable
> workflow, so it belongs with the other design records rather than in the skill registry. `Files{…}`
> and `MultipartForm{T}` both exist in `src/extractors.jl` today; this document is the rationale for
> the shape they took and the open questions that remain.

## Context

Nitro already supports multipart uploads through:

- `multipart(req)` for low-level access to all multipart parts
- `Files{FormFile}` and `Files{Vector{FormFile}}` for typed file extraction

The gap is handlers that need **both** typed file extraction and typed multipart text fields in the same request.

Today many handlers mix two styles:

```julia
function submit_import(req, files::Files{Vector{FormFile}})
    parts = multipart(req)
    user_id = parts["user_id"]
    uploaded = files.payload
end
```

Drawbacks: dual extraction, manual normalization, `String` vs `SubString{String}` surprises, no single typed validation contract.

## Proposal

Add a **typed mixed multipart extractor** binding text and file fields into one payload.

Suggested name: **`MultipartForm{T}`** (clearer than `Multipart{T}`, which collides with `multipart(req)`).

## Proposed API

```julia
struct ImportUpload
    user_id::String
    category::String
    files::Vector{FormFile}
end

function submit_import(req, payload::MultipartForm{ImportUpload})
    data = payload.payload
    # validate, stage files, queue worker, return Res.json(...)
end
```

Smaller intermediate step: extend `Form{T}` text extractors for multipart text fields alongside `Files{...}`, but Option A (`MultipartForm{T}`) is the better long-term API for worker-offload uploads.

## Extraction Rules

For `MultipartForm{T}`:

1. Parse the body once via the existing multipart parser.
2. Per field type:
   - `FormFile` → single file by field name
   - `Vector{FormFile}` → all files under that name
   - otherwise → text field with existing conversion rules
3. Validate via `validate(::T)` and extractor-local validators.

| Field type | Rule |
|------------|------|
| `String`, numeric types | single text field |
| `Union{T,Nothing}` | optional text field |
| `Vector{String}` | repeated text fields |
| `FormFile` / `Vector{FormFile}` | file fields |

## Implementation Sketch

1. `@extractor MultipartForm`
2. `extract(param::Param{MultipartForm{T}}, request::LazyRequest)`
3. `build_multipart_struct(T, parsed)` inspecting field types

Integrate `ValidationError` for missing fields, parse failures, and missing file fields.

## Phased Rollout

1. Normalize multipart text values to `String` consistently in `multipart(req)`
2. Add `MultipartForm{T}`
3. Update `docs/src/tutorial/file_uploads.md` with one enterprise example (metadata + files + worker queue)

## Related (optional)

- `stage_files(files::Vector{FormFile}; root=...)` helper for worker offload
- Do not break existing `multipart(req)` or `Files{...}` APIs

## Nitro.jl Constraints

When implementing, follow `nitro-core.instructions.md`:

- Core extractor logic stays in `src/` without `PormG`
- Handlers in app code use `Res.json` / `Res.status`
- Add tests under `test/` for validation failures and mixed payloads

## Recommendation

1. Normalize multipart text to `String`
2. Ship `MultipartForm{T}`
3. Document worker-offload pattern in tutorials
