@testitem "_locked: lock(f, l) specialized on f (#861)" tags=[:core] setup=[NitroCommon] begin
using Test
using Nitro
using Nitro.Core.Util: _locked

# The contract `lock(f, l)` has, which `_locked` replaces at the sites a trimmed build reports.
l = ReentrantLock()
@test _locked(() -> 42, l) === 42
@test !islocked(l)

# A throw unlocks, and the exception reaches the caller unchanged.
@test_throws ErrorException("boom") _locked(() -> error("boom"), l)
@test !islocked(l)

# Re-entered by the task that holds it, as `lock(l)` is; the outer hold survives the inner release.
lock(l)
try
    @test _locked(() -> _locked(() -> :inner, l), l) === :inner
    @test islocked(l)
finally
    unlock(l)
end
@test !islocked(l)

# A `Threads.Condition` is locked through its own lock, so `wait` inside `f` is legal.
c = Threads.Condition()
@test _locked(() -> islocked(c), c)
@test !islocked(c)
t = Threads.@spawn _locked(() -> (wait(c); :woken), c)
@test timedwait(() -> istaskstarted(t), 10.0) === :ok
# The waiter releases the lock while parked, so this cannot deadlock; repeat until it is parked.
woken = timedwait(10.0; pollint = 0.01) do
    _locked(() -> notify(c), c) > 0
end
@test woken === :ok
@test fetch(t) === :woken

# The call to `f` is static from a caller's code, which is where a trimmed build reads it. Read
# through a caller, not `code_typed(_locked, …)`: that specializes on the types it is given, so it
# would pass for `lock` too. On the 1.14 alpha1 nightly `lock(f, ::Threads.Condition)` failed this,
# being compiled for `f::Function` (JuliaLang/julia#64415 fixed it); on 1.13 both pass, since
# `lock` inlines there. `g` is kept out of line and has
# an effect, so the call stays a call: a pure `g() = 1` is folded to its value.
const CALLS = Ref(0)
@noinline g() = (CALLS[] += 1)
via_lock(l::ReentrantLock) = _locked(g, l)
via_cond(c::Threads.Condition) = _locked(g, c)
@test invokes(via_lock, (ReentrantLock,), g)
@test invokes(via_cond, (Threads.Condition,), g)
end

@testitem "The route-chain cache and the phase wait lock through _locked (#861)" tags=[:core] setup=[NitroCommon] begin
using Test
using Nitro
using Nitro.Core.Util: _locked
using Nitro.Core.Types: ChainCache, CopyOnWriteDict, RouteMiddleware, ChainKey, RouteEndpoint,
                        cache_chain!
using Nitro.Core.AppContext: Service, _await_phase_change
using Nitro.Core.RouterHOF: NO_ROUTE_CHAIN

# Pinned on the shape, not on 1.13's verdict: on 1.13 `lock(f, l)` inlines and both sites verify,
# so only the source's own call tells the two apart. On the 1.14 alpha1 nightly `lock(f, l)` left
# each one dynamic in a trimmed build: `cache_chain!` on every routed request, the phase wait on
# `serve`'s stop path. (1.14.0 ships without the `cancel` keyword, JuliaLang/julia#64651; the
# keyword body is 1.15's shape, and the pins hold on every version.)
for chain in (RouteEndpoint, typeof(NO_ROUTE_CHAIN))
    sig = (ChainCache, CopyOnWriteDict{RouteMiddleware}, Dict{String, RouteMiddleware}, ChainKey, chain)
    @test calls_to(cache_chain!, sig, _locked)
    @test !calls_to(cache_chain!, sig, lock)
end
@test calls_to(_await_phase_change, (Service, UInt64), _locked)
@test !calls_to(_await_phase_change, (Service, UInt64), lock)

# `cache_chain!` specializes on the chain, so the closure it hands `_locked` is concrete. Typed
# `::Function` it was compiled for the abstract type, and the closure's type was a `UnionAll`.
m = which(cache_chain!, (ChainCache, CopyOnWriteDict{RouteMiddleware}, Dict{String, RouteMiddleware},
                         ChainKey, RouteEndpoint))
@test Base.unwrap_unionall(m.sig).parameters[end] isa TypeVar
end
