# ── JSON values at their concrete types (#747, #748; docs/design/juliac-trim.md §3.11) ───────────
#
# A verified JWT's claims and a loaded session are `Dict{String, Any}`: their VALUES are whatever
# the token's author or the application put there, so every use of one -- a compare, a copy, a
# `string` -- dispatches on its type at run time. That is a dynamic call under the JIT and a call
# `juliac --trim` rejects. `with_json_value` is the closed dispatch over the types JSON.jl parses
# into, in the style of `with_response` (src/routeendpoint.jl) and `with_session`
# (src/core/request.jl): a static branch per type, the JIT's dynamic call kept for anything else,
# and a refusal in a trimmed image, where that call is exactly what the image cannot make.
#
# The three walks below (`_json_equal`, `_json_copy`, `_json_dicts`) recurse into containers, and
# each is ONE unspecialized method that calls itself, with its own chain of `isa` tests rather than
# `with_json_value`. Recursion that ran back through `with_json_value`'s `f` was a cycle of method
# instances the trim verifier left unresolved: the trimmed image threw where the first one did.

# The two object types: what `dicttype = Dict{String, Any}` parses into (a JWT's claims, a session
# a JSON store decoded), and JSON.jl's default.
const JSONObject = Union{Dict{String, Any}, JSON.Object{String, Any}}

"""
    with_json_value(f, v, args...)

`f(v, args...)`, with `v` at its concrete type whenever it is a type JSON.jl parses into: `String`,
`Int64`, `Float64`, `Bool`, `Nothing`, `Vector{Any}`, `Dict{String, Any}` or
`JSON.Object{String, Any}`. Each test is an `isa` on a concrete type, so each branch is a static
call.

Any other value (a `BigInt` from a huge JSON integer, a `Symbol` an application stored in a
`MemoryStore` session) takes one dynamic call under the JIT, as every value did before, and a
trimmed image refuses it with an `ArgumentError` that names only its type.
"""
function with_json_value(f::F, @nospecialize(v), args::Vararg{Any,N}) where {F,N}
    v isa String && return f(v, args...)
    v isa Int64 && return f(v, args...)
    v isa Float64 && return f(v, args...)
    v isa Bool && return f(v, args...)
    v === nothing && return f(nothing, args...)
    v isa Vector{Any} && return f(v, args...)
    v isa Dict{String, Any} && return f(v, args...)
    v isa JSON.Object{String, Any} && return f(v, args...)
    return _with_foreign_json_value(f, v, args...)
end

@noinline function _with_foreign_json_value(f::F, @nospecialize(v), args::Vararg{Any,N}) where {F,N}
    _trimmed() && throw(ArgumentError(
        "Nitro: a trimmed image reads only JSON-shaped claim and session values; got a $(nameof(typeof(v)))"))
    return f(v, args...)
end

# `with_json_value` over the scalars alone, for the walks below, which test for the containers
# themselves: a container reaching it is outside the list.
function _with_json_scalar(f::F, @nospecialize(v), args::Vararg{Any,N}) where {F,N}
    v isa String && return f(v, args...)
    v isa Int64 && return f(v, args...)
    v isa Float64 && return f(v, args...)
    v isa Bool && return f(v, args...)
    v === nothing && return f(nothing, args...)
    return _with_foreign_json_value(f, v, args...)
end

_is_json_container(@nospecialize(v)) =
    v isa Vector{Any} || v isa Dict{String, Any} || v isa JSON.Object{String, Any}
_is_json_value(@nospecialize(v)) = _is_json_container(v) ||
    v isa String || v isa Int64 || v isa Float64 || v isa Bool || v === nothing

"""
    _json_equal(cmp, a, b) -> Bool

`cmp(a, b)` for `cmp` either `==` or `isequal`, with the answer Base gives, but static when both
are JSON values. Base's array and dict methods compare their elements with `cmp` too, which is a
dynamic call per element when the elements are `Any`; here containers recurse, in Base's own order:
same length, then element by element (an array) or key by key, every key of `a` present in `b` (a
dict). A container never equals a value that is not one of its own kind, which is Base's answer
too. Two scalars go to `cmp`, which Base resolves for every pair of the listed types.

A value outside the list, on either side, is compared by `cmp` itself: one dynamic call under the
JIT, refused in a trimmed image.
"""
function _json_equal(cmp::C, @nospecialize(a), @nospecialize(b))::Bool where {C}
    (_is_json_value(a) && _is_json_value(b)) || return _foreign_equal(cmp, a, b)
    if a isa Vector{Any}
        b isa Vector{Any} || return false
        length(a) == length(b) || return false
        for i in eachindex(a, b)
            _json_equal(cmp, a[i], b[i]) || return false
        end
        return true
    elseif a isa Dict{String, Any} || a isa JSON.Object{String, Any}
        (b isa Dict{String, Any} || b isa JSON.Object{String, Any}) || return false
        length(a) == length(b) || return false
        for (key, value) in a
            other = get(b, key, _AbsentKey())
            other isa _AbsentKey && return false
            _json_equal(cmp, other, value) || return false
        end
        return true
    elseif _is_json_container(b)
        return false
    end
    return _with_json_scalar(_json_equal_scalar, a, cmp, b)
end

# A sentinel no JSON value can be, for a key missing from `b` (Base uses a private one the same way).
struct _AbsentKey end

_json_equal_scalar(a, cmp::C, @nospecialize(b)) where {C} = _with_json_scalar(_json_equal_scalars, b, cmp, a)
_json_equal_scalars(b, cmp::C, a) where {C} = cmp(a, b)::Bool

@noinline function _foreign_equal(cmp::C, @nospecialize(a), @nospecialize(b))::Bool where {C}
    _trimmed() && throw(ArgumentError(
        "Nitro: a trimmed image compares only JSON-shaped session values; got a " *
        "$(nameof(typeof(_is_json_value(a) ? b : a)))"))
    return cmp(a, b)::Bool
end

"""
    _json_copy(v)

A deep copy of a JSON value: containers are rebuilt at their own type with their values copied,
and scalars, all immutable, are returned as they are. Unlike `deepcopy` it keeps no identity
table, so two keys that shared one mutable value get a copy each, and a container that holds
itself recurses without end. Neither can come out of a JSON parse. It is what a trimmed image
copies a session with, where `deepcopy` of an `Any` value is a dynamic call; the JIT keeps
`deepcopy` (src/middleware/session_middleware.jl). A value outside the list is `deepcopy`d under
the JIT and refused in a trimmed image.
"""
function _json_copy(@nospecialize(v))
    if v isa Vector{Any}
        copied = Vector{Any}(undef, length(v))
        for i in eachindex(v)
            copied[i] = _json_copy(v[i])
        end
        return copied
    elseif v isa Dict{String, Any}
        dict = Dict{String, Any}()
        sizehint!(dict, length(v))
        for (key, value) in v
            dict[key] = _json_copy(value)
        end
        return dict
    elseif v isa JSON.Object{String, Any}
        object = JSON.Object{String, Any}()
        for (key, value) in v
            object[key] = _json_copy(value)
        end
        return object
    elseif _is_json_value(v)
        return v
    end
    return _foreign_copy(v)
end

@noinline function _foreign_copy(@nospecialize(v))
    _trimmed() && throw(ArgumentError(
        "Nitro: a trimmed image copies only JSON-shaped session values; got a $(nameof(typeof(v)))"))
    return deepcopy(v)
end

"""
    _json_dicts(v)

`v`, parsed with JSON.jl's default object type, with every `JSON.Object{String, Any}` in it
rebuilt as a `Dict{String, Any}`: what the same text parses to under `dicttype = Dict{String, Any}`.
A trimmed image reads a JWT's claims this way (src/Auth/jwt.jl), because JSON.jl's parse under a
non-default `dicttype` goes through calls `juliac --trim` rejects, where its default one does not
(#747, docs/design/juliac-trim.md §3.11). A later duplicate key wins, as it does in that parse.
Anything else is returned as it is.
"""
function _json_dicts(@nospecialize(v))
    if v isa Vector{Any}
        converted = Vector{Any}(undef, length(v))
        for i in eachindex(v)
            converted[i] = _json_dicts(v[i])
        end
        return converted
    elseif v isa JSON.Object{String, Any} || v isa Dict{String, Any}
        dict = Dict{String, Any}()
        sizehint!(dict, length(v))
        for (key, value) in v
            dict[key] = _json_dicts(value)
        end
        return dict
    end
    return v
end
