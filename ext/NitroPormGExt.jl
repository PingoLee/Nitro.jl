module NitroPormGExt

using Nitro
using PormG

import Nitro.Auth: make_password, check_password, password_needs_upgrade, is_password_usable

"""
    hash_password_field(value) -> value

Hook for PormG's `normalize_field_value` on `PasswordField` with `auto_hash=true`.

- If `value` is a `String` that does not look like an already-encoded hash
  (checked via `is_password_usable`), hashes it with `make_password`.
- If `value` is already an encoded hash, passes it through unchanged.
- If `value` is not a `String` (e.g. `nothing`, numeric, etc.), passes it through
  untouched — type validation is PormG's responsibility, not Nitro's.
"""
function hash_password_field(value)
    value isa AbstractString || return value
    is_password_usable(value) && return value
    isempty(strip(value)) && return value
    return make_password(value)
end

"""
    verify_password(raw::AbstractString, encoded::AbstractString) -> Bool

Convenience wrapper around `Nitro.Auth.check_password` for use in PormG model contexts.
"""
function verify_password(raw::AbstractString, encoded::AbstractString)
    return check_password(raw, encoded)
end

"""
    needs_rehash(encoded::AbstractString; kwargs...) -> Bool

Convenience wrapper around `Nitro.Auth.password_needs_upgrade` for use in PormG model contexts.
"""
function needs_rehash(encoded::AbstractString; kwargs...)
    return password_needs_upgrade(encoded; kwargs...)
end

function __init__()
    # Register the password field hook with PormG when the normalize_field_value
    # seam is available (Phase 3 upstream dependency).
    # Until Phase 3 lands in PormG, this is a no-op skeleton.
    if isdefined(PormG, :register_field_hook)
        PormG.register_field_hook(:PasswordField, :auto_hash, hash_password_field)
    end
end

end # module NitroPormGExt
