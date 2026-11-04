"""
    _locked(f, l)

`lock(f, l)`, specialized on `f`: take `l`, run `f()` and return its value, and release `l` on the
way out, also when `f` throws. A `ReentrantLock` is re-entered as by `lock(l)`. A
`Threads.Condition` is locked through its own lock, as `lock(f, c)` does.

Use it where `lock(f, l) do … end` sits on a path `juliac --trim` must verify (#861). On Julia
1.14 `lock` takes a `cancel` keyword (`base/lock.jl`), so `lock(f, l)` on a `ReentrantLock` runs
through its keyword body, `#lock#…(cancel, lock, f, l)`. That call resolves only when the frame
that makes it knows `f`'s concrete type, and `lock(f, c::GenericCondition) = lock(f, c.lock)`
does not: it only passes `f` on, so it is compiled for `f::Function`. The trim verifier then stops
at the call, and a trimmed image fails there with a `MethodError`. On 1.13 `lock(f, l)` has no
keyword and inlines whole.

Cancellation is unchanged on both versions. The positional `lock(l)` here is `lock(l; cancel =
DEFAULT_CANCEL)` on 1.14, the default `lock(f, l)` itself passes, and plain `lock(l)` on 1.13.

Not a replacement for `lock(f, l)` in general: only the sites a trimmed build reports go through it.
"""
@inline function _locked(f::F, l::Base.AbstractLock) where {F}
    lock(l)
    try
        return f()
    finally
        unlock(l)
    end
end

@inline _locked(f::F, c::Base.GenericCondition) where {F} = _locked(f, c.lock)
