# Rules for code-review agents (Lectern)

You are one of several reviewers, each covering one slice of the codebase. Other agents are
**actively editing** parts of the repo at the same time. Read README.md and docs/AGENTS.md first.

## What to look for (in priority order)
1. **Bugs.** Logic errors, off-by-ones, races and actor-reentrancy mistakes, unhandled errors or
   errors swallowed silently, cancellation not honored, leaks (retained tasks, observers,
   continuations never finished), wrong units/timebases, edge cases (empty input, very long
   lectures, missing files, mid-stream failure), Swift 6 concurrency hazards
   (`@unchecked Sendable` without real synchronization, `MainActor.assumeIsolated` misuse).
2. **Efficiency.** Work done on the main thread that shouldn't be, repeated O(n²) scans over
   growing transcripts, redundant re-encoding/re-rendering, needless copies of large arrays,
   polling where an event exists.
3. **Dead code.** Unused types, functions, parameters, properties, imports, stale files. The
   `App/Lectern/Demo/` stack and `-selftest` harness are NOT dead; they are used by `-demo` and
   headless tests.
4. **Needless complexity.** Abstractions with one trivial use, duplicated helpers that should be
   one, convoluted control flow that a simpler equivalent replaces.
5. **Comments.** Remove comments that just restate the code, stale comments that no longer match,
   and leftover debugging notes. KEEP comments that explain *why* (design decisions, API quirks,
   measured numbers, workarounds). Don't strip doc comments on public API.

## What you may change yourself
- Fix directly when the change is **local and low-risk**: a clear bug with an obvious fix (add or
  adjust a unit test that fails before and passes after), dead-code removal, simplifications that
  preserve behavior, comment cleanup, small efficiency wins.
- **Report instead of changing** when the fix changes behavior users would notice, alters a public
  API/contract in LecternCore, spans modules, or you are less than confident. Describe it
  precisely (file:line, failure scenario, proposed fix).
- **Never edit files listed as "report-only" in your brief.** Other agents are working in them;
  put findings for those files in your report.
- No formatting sweeps, no renames for taste, no reordering. Keep diffs minimal and reviewable.
- Re-read a file immediately before each edit (it may have changed under you).

## Verification
- After changes, build and run the tests of every module you touched, in an isolated package
  (see "Build tip" in docs/AGENTS.md). For app changes: `Scripts/build.sh DD-review-<you>`.
- Don't run MLX or Ollama models: other agents are using the GPU for evaluations.
- Don't commit or touch git state.

## Report (≤ 400 words)
1. Changes made: each with file, one line on what and why, and the test evidence.
2. Findings not fixed, most severe first: file:line, scenario, proposed fix.
3. Anything you'd recommend but consider a judgment call.

## Warning: real-data tests skip in isolated packages
Tests that use `TestData/` (the real CS 426 lecture, captions, slides) find it relative to their
source path, which symlinked isolated packages change, so there they **silently skip** (they
"pass" in ~1 ms). Before reporting, run the suites of any module whose real-data tests could be
affected in the REAL package once:
`swift test --package-path Packages/LecternKit --scratch-path /Users/advaittahilyani/Lectern/.build-<you> --filter <Suite>`
(the first build compiles MLX; later ones are incremental). A real-data test should take seconds.
