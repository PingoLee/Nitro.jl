"""
    _locked(f, l)

`lock(f, l)`, specialized on `f`: take `l`, run `f()` and return its value, and release `l` on the
way out, also when `f` throws. A `ReentrantLock` is re-entered as by `lock(l)`. A
`Threads.Condition` is locked through its own lock, as `lock(f, c)` does.

Use it where `lock(f, l) do … end` sits on a path `juliac --trim` must verify (#861). On a Julia
with the task-cancellation work, `lock` takes a `cancel` keyword (`base/lock.jl`), so `lock(f, l)`
on a `ReentrantLock` runs through its keyword body, `#lock#…(cancel, lock, f, l)`. That call
resolves only when the frame that makes it knows `f`'s concrete type, and the 1.14 alpha1
nightly's `lock(f, c::GenericCondition) = lock(f, c.lock)` did not: it only passed `f` on, so it
was compiled for `f::Function`. The trim verifier then stops at the call, and a trimmed image fails
there with a `MethodError`. On 1.13 `lock(f, l)` has no keyword and inlines whole.

Which Julia that is moved after #861 was measured: JuliaLang/julia#64415 (2026-10-29, in the
1.14 alpha2 nightly) made that Base method `lock(f::F, c::GenericCondition) where {F}`, and
JuliaLang/julia#64651 (2026-11-05) reverted the cancellation work from the 1.14 branch to 1.15.
So 1.14.0 ships no `cancel` keyword, and the keyword body is 1.15's shape; `_locked` is correct on
every version, and stays where the trimmed builds of #861 put it.

Cancellation is unchanged on every version. The positional `lock(l)` here is `lock(l; cancel =
DEFAULT_CANCEL)` where the keyword exists, the default `lock(f, l)` itself passes, and plain
`lock(l)` elsewhere.

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
