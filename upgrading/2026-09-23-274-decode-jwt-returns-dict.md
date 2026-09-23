## `decode_jwt` — claims are a `Dict{String, Any}`, not a `JSON.Object`

- **Version**: Unreleased
- **Nitro ref**: [#274](https://github.com/PingoLee/Nitro.jl/issues/274) ; `src/Auth/jwt.jl`
- **Recorded**: 2026-09-23
- **Severity**: **breaking (and partly SILENT)**. `Symbol` and property access on decoded
  claims now throw, and `Symbol` lookups through `get`/`haskey` stop finding the claim
  without any error. Which tokens verify is unchanged.

### What changed

`decode_jwt` parsed the claims segment with an untyped `JSON.parse`, so the claims came back
as a `JSON.Object{String, Any}`: an ordered dictionary that also answers `Symbol` keys and
property access. That abstract parse also made every claim read on the `jwt_validator`
request path dispatch dynamically. The claims segment now parses into a concrete
`Dict{String, Any}`, at **every nesting level**:

| Read | Before (`JSON.Object`) | After (`Dict{String, Any}`) |
|---|---|---|
| `claims["sub"]`, `get(claims, "sub", nothing)` | works | works, unchanged |
| `claims[:sub]` | works | `KeyError` |
| `haskey(claims, :sub)`, `get(claims, :sub, d)` | finds the claim | `false` / `d` — **silently** |
| `claims.sub` | works | `FieldError` (a `Dict` has no field `sub`) |
| `keys(claims)`, iteration, `JSON.json(claims)` | token order | unordered |
| a nested object, `claims["ctx"]` | `JSON.Object` | `Dict{String, Any}` — the same three rows apply one level down |
| `claims == other_dict` | by content | by content, unchanged |

This reaches `jwt_validator` users too, but only one level down. The `Principal` it returns
already held a `Dict{String, Any}`, so `principal["sub"]` is unchanged. A **nested** claim
object read through it, `principal["ctx"]` or `getuser(req)["ctx"]`, is now a `Dict` where it
used to be a `JSON.Object`. The `Principal` now holds the parsed dictionary itself rather than
a copy.

The same is true of a `Principal` you build yourself: `Principal(decode_jwt(t, keyset))` now
**shares** the dictionary `decode_jwt` returned. It used to get its own copy. Mutating the claims
afterwards (`claims["role"] = "admin"`) now changes what the `Principal` reports. Build it from
`copy(claims)` if you go on editing the dictionary.

`Symbol` lookups that return a default instead of throwing are the row to worry about: they
do not fail, they stop finding the claim.

### How to find the calls to migrate

```bash
# Direct callers -- the only place the top-level container is observable.
rg -n 'decode_jwt\(' <app>/src
# Symbol-keyed and dot access on claims, at any level. Over-matches on purpose:
# `principal.id` / `.kid` / `.claims` / `.source` are real `Principal` fields and stay.
rg -n '(claims|principal|getuser\([^)]*\))(\[[^]]*\])*(\[:|\.[a-z_]+\b($|[^(]))' <app>/src
rg -n '(haskey|get)\([^,]*(claims|principal)[^,]*, *:' <app>/src
# Code that depends on claim order, e.g. serializing claims and comparing the string.
rg -n 'JSON\.json\([^)]*claims|keys\([^)]*claims' <app>/src
```

These patterns only catch the conventional names. Claims bound to some other variable, such as
`user = getuser(req)` followed later by `user["ctx"][:tenant]`, need the first command's list
of `decode_jwt` call sites and a read of what each result flows into.

### Migrate your app

```julia
# ✗ before — Symbol and property access only JSON.Object supported
claims = decode_jwt(token, keyset)
user_id = claims[:sub]
tenant  = claims.ctx.tenant
admin   = get(claims, :admin, false)      # now silently `false`

# ✓ after — string keys, at every level
claims = decode_jwt(token, keyset)
user_id = claims["sub"]
tenant  = claims["ctx"]["tenant"]
admin   = get(claims, "admin", false)
```

Claim order carries no meaning: a JSON object is an unordered collection (RFC 8259 §1). Compare
parsed values, not serialized strings.
