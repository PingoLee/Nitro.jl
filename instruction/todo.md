# Nitro.jl Points to Consider (TODOs)

These items require further thought and refinement in the workflow instructions before or during implementation.

- [x] **Optionality of PormG.jl**: ✅ Resolved — PormG.jl is now a `[weakdeps]` loaded via Julia package extension (`ext/NitroPormGExt.jl`). Nitro works standalone; PormG auto-loads only when the user does `using Nitro, PormG`. See `new.md` Step 2.
- [x] **Default Async Model (`@spawn` vs `@async`)**: ✅ Resolved — Default is `Threads.@spawn` for ALL handlers (Go-like goroutines, NOT Node.js event loop). Each request is dispatched to an available thread. No `threaded=true` opt-in needed. Julia with `-t auto` uses all cores natively — no PM2/cluster needed for performance. See `new.md` "Go-Inspired Concurrency Model" section.
- [x] **Restore the Subtraction Phase**: ✅ Resolved — Added "Step 0: Subtraction" to `new.md` as a prerequisite. Documents stripping cron, metrics, repeattasks, and autodoc from the core, with a note about the separate workers package.
- [x] **Preserve Context Comments**: ✅ Resolved — All `[Comentário: ...]` annotations converted to permanent `> [!NOTE]` blockquotes in `new.md` (Goals #5 and Step 5: Graceful Shutdown).
