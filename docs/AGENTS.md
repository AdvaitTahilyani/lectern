# Rules for implementation agents (Lectern)

Several agents are building Lectern **in parallel**, each owning one module. Follow these rules exactly.

1. **Repo:** `/Users/advaittahilyani/Lectern`. The contracts are in `Packages/LecternKit/Sources/LecternCore/` (Models, Transcription, LLM, Services, Intelligence, Formatting). Read ALL of them first. **Do not modify LecternCore, Package.swift, project.yml, or any directory you don't own**, unless your brief explicitly allows it. If you need a contract change, work around it inside your module and describe the change you'd want in your final report.
2. **Read** `docs/DESIGN.md` (UX intent) and the research in `docs/research/` relevant to you.
3. **Build in your own scratch path** so parallel builds don't block each other:
   `swift build --package-path Packages/LecternKit --scratch-path /Users/advaittahilyani/Lectern/.build-<yourname> --target <YourTarget>`
   Tests: `swift test --package-path Packages/LecternKit --scratch-path … --filter <YourTestTarget>` (this compiles every target incl. MLX the first time — slow; do it sparingly). Xcode app builds: `Scripts/build.sh DD-<yourname>`.
4. Swift 6 language mode, strict concurrency. Prefer actors / `Sendable` value types; `@unchecked Sendable` only with a comment explaining the synchronization. macOS 26+ APIs are fine (machine is macOS 27, Xcode 27, Swift 6.4).
5. Code quality bar: production-grade, small focused files, doc comments on public API, no dead code, no TODO stubs left behind for core functionality. Errors are surfaced, never swallowed silently.
6. **Don't commit** — the lead integrates and commits. Don't touch git state.
7. Model downloads are approved by the user: Parakeet Unified CoreML (~0.6 GB, FluidInference on HF) and `mlx-community/gemma-4-26B-A4B-it-qat-4bit` (~15.6 GB). Only the agent whose brief says so should download each (avoid duplicate downloads). The user's Ollama has `gemma4:12b` at http://localhost:11434 for integration tests (use `think:false`).
8. Final report (≤350 words): public API you exposed (type + key signatures), how the app should construct/wire it, what you verified (commands + results), known limitations, and any contract changes you'd like.

## Build tip (added by lead): don't compile MLX unless you need it
`swift test` on the full package compiles every target (MLX's C++ takes a long time, and another agent's
in-progress module can break your build). Test in an **isolated package** that symlinks only what
you need, e.g.:
```
P=$TMPDIR/lk-<you>; mkdir -p $P/Sources $P/Tests; K=/Users/advaittahilyani/Lectern/Packages/LecternKit
ln -s $K/Sources/LecternCore $P/Sources/; ln -s $K/Sources/<YourTarget> $P/Sources/; ln -s $K/Tests/<YourTests> $P/Tests/
# write $P/Package.swift declaring just those targets (+ your external deps, e.g. FluidAudio)
cd $P && swift test
```
