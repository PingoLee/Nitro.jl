# Nitro.jl — agent instructions

**Nitro.jl** is an SPA/API-first web framework for Julia, drawing on three traditions on purpose:
**Django** for routing and sessions (`urlpatterns`, path converters, `include_routes`), **Go** for
concurrency (every request on `Threads.@spawn`, no event loop, no cluster manager), and **Node.js /
Express** for response and middleware ergonomics (`res.json()`-style builders, a linear top-down
middleware chain, SPA history-mode fallback). The full agent ruleset —
non-negotiables, the hard-stop index, the deep-dive rule index, the skill registry, the architecture
map, and verification commands — lives in one canonical file. Read it first; do not restate its
rules here.

@.github/instructions/nitro-general.instructions.md
