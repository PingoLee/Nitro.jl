# What does one `@with` cost when its key shares a HAMT slot with a key already bound? (#633)
#
# `@with` inserts into a `PersistentDict` (a HAMT) keyed by `objectid(key)`, and a `ScopedValue` is
# a mutable struct, so it hashes by address: where a key lands next to the keys bound around it
# differs from one process to the next. The #444 bound in `test/appcontext_tests.jl` compared the
# seed layer's insert with a reference insert under a SEPARATE key, so on Julia 1.13, where Test
# binds its testset stack in ScopedValues, the two sides could sit in different slots and the test
# read 9 or 13 allocations against 6 in some processes. The test now binds the reference under the
# seed layer's own key; this script is the measurement behind that change.
#
# It measures four bindings, each as the minimum over 5 rounds of 1000 calls, allocations per call:
# the seed layer; the reference under the seed's key (`REQUEST_SCOPE`); the old reference under a
# key of its own; and two keys, the shape #444 removed. First with nothing bound, then inside a
# key forced into `REQUEST_SCOPE`'s level-0 slot (`objectid & 0x1f`), beside one that collides with
# neither, as Test's keys sit on 1.13.
#
#   julia --check-bounds=yes --startup-file=no --project=. bench/scope/collide.jl
#
# Measured 2026-10-19 (PR #643), 1.12.7 and 1.13.2 identical:
#   nothing bound:                         seed=5  ref(same key)=5   old ref=5  two keys=10
#   bound key colliding with REQUEST_SCOPE: seed=13 ref(same key)=13  old ref=6  two keys=18
using Nitro, HTTP
using Base.ScopedValues: ScopedValue, @with
using Nitro.Core: _app_context_seed
using Nitro.Core.Constants: REQUEST_SCOPE, RequestScope
app = App(mod = @__MODULE__)
const REF_VALUE = RequestScope(nothing, Ref{Int64}(0))
const OLD_SCOPE = ScopedValue{RequestScope}(RequestScope(nothing, Ref{Int64}(0)))
reference(req::HTTP.Request) = @with REQUEST_SCOPE => REF_VALUE nothing
old_reference(req::HTTP.Request) = @with OLD_SCOPE => REF_VALUE nothing
const SECOND_SCOPE = ScopedValue{RequestScope}(REF_VALUE)
two_keys(req::HTTP.Request) = @with REQUEST_SCOPE => REF_VALUE SECOND_SCOPE => REF_VALUE nothing
function per_call(f)
    reqs = [HTTP.Request("GET", "/") for _ in 1:10_001]
    foreach(r -> r.context[Nitro.Core.REQUEST_CONTEXT_KEY] = nothing, reqs)
    i = Ref(0); g = () -> f(reqs[i[] += 1]); g()
    minimum(@allocations(for _ in 1:1000; Base.donotdelete(g()); end) for _ in 1:5) / 1000
end
seed_layer = _app_context_seed(app)((req::HTTP.Request) -> nothing)
slot(k) = objectid(k) & 0x1f
measure(label) = println(rpad(label, 40), " seed=", per_call(seed_layer), " ref(same key)=", per_call(reference),
                         " old ref=", per_call(old_reference), " two keys=", per_call(two_keys))
measure("julia $VERSION, nothing bound:")
# A bound key in REQUEST_SCOPE's level-0 slot, and one elsewhere, as Test's keys sit on 1.13.
hit  = first(k for k in (ScopedValue{Int}(0) for _ in 1:10_000) if slot(k) == slot(REQUEST_SCOPE))
miss = first(k for k in (ScopedValue{Int}(0) for _ in 1:10_000) if slot(k) ∉ (slot(REQUEST_SCOPE), slot(OLD_SCOPE)))
@with hit => 1 miss => 2 measure("bound key colliding with REQUEST_SCOPE:")
