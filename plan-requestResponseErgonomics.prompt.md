# Plan: Request/Response Ergonomics Refactor

This plan standardizes and enhances how developers interact with HTTP requests and responses in Nitro.jl. We will implement unified input accessors, improve caching for parsed bodies, and clean up the existing request extensions to provide a "Genie-like" but more structured experience.

## Phase 1: HTTP.Request Property Extensions & Caching
1. Implement a caching helper function in [src/core.jl](src/core.jl) that uses `req.context` to store and retrieve parsed bodies (JSON, form) to avoid re-reading the IO stream.
2. Add `req.json` property: Returns parsed JSON body (cached on first call, returns `nothing` if body is empty or malformed).
3. Add `req.form` property: Returns parsed HTML Form data (cached on first call, returns empty `Dict` if body is empty or not form-encoded).
4. Add `req.query` property: Shorthand for `HTTP.queryparams(req)` (no caching needed—query string is always in memory).
5. Add `req.input` (or `req.data`) property: A unified `Dict` merging `params`, `query`, `form`, and `json` in that priority order (highest to lowest).

**Implementation Notes**:
- Do not rely on `Content-Type` headers to decide whether to parse. Always attempt parsing and cache the result.
- Empty bodies should return `nothing` for `req.json` and an empty `Dict{}` for `req.form`.
- Malformed JSON should return `nothing` (graceful degradation) rather than throwing during property access.
- `req.input` merging: paths > form > json > query (path parameters have highest priority).

## Phase 2: LazyRequest & Utilities Alignment
1. Refactor [src/types.jl](src/types.jl) to ensure `LazyRequest` and `HTTP.Request` extensions use the same underlying parsing logic from [src/utilities/bodyparsers.jl](src/utilities/bodyparsers.jl).
2. Ensure [src/utilities/bodyparsers.jl](src/utilities/bodyparsers.jl) handles empty or malformed bodies gracefully (return `nothing` or empty `Dict{}`).
3. Document the intended use of `LazyRequest`:
   - **Old (still valid)**: Used internally by Extractors (`Path`, `Query`, `Json`, etc.) in [src/extractors.jl](src/extractors.jl).
   - **New (preferred for handlers)**: Use `HTTP.Request` properties (`req.json`, `req.form`, `req.input`) for direct body access.
   - **Recommendation**: Handlers should prefer `HTTP.Request` properties; app-level code can wrap `HTTP.Request` in `LazyRequest` if extractors are preferred for validation.

## Phase 3: Response (Res) Enhancements
1. Add `Res.file(path; ...)` helper to [src/response.jl](src/response.jl) for easy file downloads (setting `Content-Disposition`, etc.).
2. Add `Res.redirect(url; status=302)` helper.

## Verification
1. Create `test/ergonomics_tests.jl` to verify:
    - **Caching**: Multiple calls to `req.json` or `req.input` don't re-read the body or fail.
    - **Merging**: `req.input` correctly merges sources with priority (paths > form > json > query).
    - **Path params**: `req.params` (URL path parameters) are correctly merged into `req.input`.
    - **Empty bodies**: `req.json` returns `nothing` and `req.form` returns `{}` for empty bodies.
    - **Malformed input**: `req.json` returns `nothing` for malformed JSON; `req.form` returns `{}` for non-form bodies.
    - **Thread safety**: Verify that concurrent handler requests don't cause cache collisions (though `req.context` is per-request, so this should be safe).
    - **Large payloads**: Verify caching doesn't cause memory bloat for large request bodies.
2. Run full test suite: `julia --project -e 'using Pkg; Pkg.test()'`

## Decisions
- **Caching**: Store parsed results in `req.context` (a `Dict{Symbol, Any}` already on `HTTP.Request`) to ensure they live for the request lifecycle.
- **Merge Priority**: Paths > Form > JSON > Query. (Path parameters are highest priority, query string is lowest.)
- **Return Type**: `req.input` returns a `Dict{String, Any}` to merge diverse data types.
- **Empty Body Behavior**:
  - `req.json` on empty body → `nothing`
  - `req.form` on empty body → `Dict{String, String}()` (empty dict, not `nothing`)
  - `req.json` on malformed JSON → `nothing` (graceful, no exception)
- **Content-Type Agnostic**: Do not check `Content-Type` headers. Always attempt parsing; let the caller decide based on the result.

## Further Considerations
1. Should `req.input` be a property `req.input` or a function `req.input()`? 
   *Recommendation*: Keep it as a property `req.input` for consistency with `req.params`.
