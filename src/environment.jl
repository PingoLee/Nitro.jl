module Environment
## Nitro's resolved runtime environment (#55).
##
## The environment is a property of the OS PROCESS, not of an application instance: a single
## Julia process cannot be `prod` and `test` at once the way it can host two `App`s.
## That is why resolution lives here as a free function rather than on `App`, and why
## #55 lands independently of the app-as-an-object question (#31/#37). Phoenix draws the same
## line with `Mix.env()`.

using ..Types: Nullable

export current_env

"""
The environments Nitro recognises.

Closed on purpose, and stricter than the field: Rails, ASP.NET Core, Spring, Laravel and Genie
all accept arbitrary names. The trade is a deliberate one for a pre-publish framework —
*widening* this tuple later is purely additive, while tightening an open set would be breaking,
so this is the reversible direction. The value it buys is catching the `NITRO_ENV=prodution`
class of typo, which is the single most cited footgun of Express's unvalidated `NODE_ENV`.
"""
const NITRO_ENVS = ("dev", "prod", "test")

# An env var set to "" (or whitespace) counts as UNSET, not as an invalid value.
# `export NITRO_ENV=$SOME_UNSET_VAR` is one of the most common shell accidents there is, and
# `get(ENV, …, nothing)` hands back `""` rather than `nothing` for it. Treating that as a typo
# would make a stray empty assignment fatal at every `serve()`.
_present(v::Nullable{String})::Nullable{String} =
    v === nothing || isempty(strip(v)) ? nothing : String(strip(v))

function _invalid(var::String, value::String, extra::String)
    allowed = join(map(repr, NITRO_ENVS[1:end-1]), ", ") * ", or " * repr(NITRO_ENVS[end])
    hint = lowercase(value) in NITRO_ENVS ? " (did you mean $(repr(lowercase(value)))?)" : ""
    return ArgumentError("Invalid `$var` value $(repr(value)). Expected one of $allowed$hint.$extra")
end

# PURE — takes the two raw values rather than reading `ENV`, so the whole precedence table and
# every error message are unit-testable without mutating the process environment. `current_env`
# and `_explicit_env` are the only callers that touch `ENV`.
#
# `nothing` when NEITHER variable is set: the environment someone actually chose, as opposed to
# the `"dev"` Nitro falls back to. The PormG bridge needs that distinction (#331) -- publishing
# the fallback as if it were a choice outranks a choice someone DID make, `default_env:` in
# connection.yml.
function _resolve_explicit(nitro::Nullable{String}, genie::Nullable{String})::Nullable{String}
    n = _present(nitro)
    if n !== nothing
        n in NITRO_ENVS || throw(_invalid("NITRO_ENV", n, ""))
        return n
    end

    g = _present(genie)
    if g !== nothing
        # `GENIE_ENV` is another framework's variable and Genie permits names Nitro does not
        # (`staging` is legal Genie). Still an error rather than a silent fallback: falling
        # through to "dev" is the PERMISSIVE direction, and a `staging` box quietly running as
        # `dev` is exactly the failure #55 exists to prevent. But the message points at
        # `NITRO_ENV` — the fix that does not break the caller's Genie half.
        g in NITRO_ENVS || throw(_invalid("GENIE_ENV", g,
            " Nitro reads `GENIE_ENV` only as a fallback; set `NITRO_ENV` to override it."))
        return g
    end

    return nothing
end

_resolve_env(nitro::Nullable{String}, genie::Nullable{String})::String =
    something(_resolve_explicit(nitro, genie), "dev")

# The environment set in `NITRO_ENV`/`GENIE_ENV`, or `nothing` when neither is. Validates exactly
# as `current_env` does. Internal: the only consumer is the PormG bridge (`sync_pormg_env!`).
_explicit_env()::Nullable{String} =
    _resolve_explicit(get(ENV, "NITRO_ENV", nothing), get(ENV, "GENIE_ENV", nothing))

"""
    current_env() -> String

Nitro's resolved environment: one of `"dev"`, `"prod"`, or `"test"`.

Resolved fresh on every call, from `NITRO_ENV`, then `GENIE_ENV` (a Genie-migration fallback),
then `"dev"`. Empty or whitespace-only values count as unset. An unrecognised value throws an
`ArgumentError` instead of being silently accepted — `NITRO_ENV=prodution` is a typo, not an
environment.

Deliberately **not** memoised: there is no cached value to go stale, `withenv` keeps working in
tests, and there is no reset API to get wrong. It is never on the request hot path — `serve()`
calls it once at startup, and `NitroPormGExt` once at load.

# Bridging to PormG

With `PormG` loaded, an environment set in `NITRO_ENV` or `GENIE_ENV` is published to
`ENV["PORMG_ENV"]` as a **default** (see `sync_pormg_env!`), so
`PormG.Configuration.load_many([...])` needs no `env=`. A pre-set `PORMG_ENV` and an explicit
`env=` both still win. The `"dev"` fallback is **not** published: with neither variable set,
PormG resolves its own environment, so `default_env:` in `connection.yml` still decides.

# This function REPORTS; it must never GATE

Use it for the startup banner, for choosing which config file to load, for log verbosity. Do
**not** use it to decide whether to render error details, relax a security check, or expose a
debug route. See the note at `src/errors.jl` on `ValidationError`: Django's `DEBUG` and
Express's `NODE_ENV` are the cautionary precedent — a process-wide flag is the thing that is on
in production once. `isdev()`/`isprod()`/`istest()` are deliberately **not** shipped for the
same reason; their only contribution would be to make that gating ergonomic.

```julia
julia> current_env()
"dev"

julia> withenv("NITRO_ENV" => "prod") do; current_env(); end
"prod"
```
"""
current_env()::String =
    _resolve_env(get(ENV, "NITRO_ENV", nothing), get(ENV, "GENIE_ENV", nothing))

end
