# Fix round, 8 October 2026: rules for every agent

Inputs:
- the Codex audit:
  `/Users/advaittahilyani/Documents/Codex/2026-10-08/the-code-lives-in-two-places/outputs/lectern-audit.md`
  (47 findings B01–B47, performance items P01–P12; failing diagnostic fixtures in its `evidence/`)
- the user's own bug list, in your brief.

Read README.md, docs/AGENTS.md and the audit sections for your IDs before changing anything.

## The user may be recording a real lecture right now
`/Applications/Lectern.app` is running. Never kill, relaunch, replace or modify it.
- No GPU model work: no `LECTERN_LIVE_TESTS`, no `-selftest`, no Ollama.
  Exception: you may run the on-device pipeline harness only when `pgrep -x Lectern` prints nothing.
- Run every build and test at low priority: prefix with `nice -n 15`.
- Never write to the real library at `~/Library/Application Support/Lectern`. Reading is allowed
  (e.g. to inspect timings in a real session.json). Test with disposable data, temp directories and
  in-memory stores.
- Don't run `Scripts/install.sh`. The lead installs once at the end.

## Build hygiene: the user wants exactly one Lectern build on this machine
- App builds: `nice -n 15 Scripts/build.sh DD-<you>` (Debug), and app tests:
  `nice -n 15 Scripts/test-app.sh DD-<you>`.
- Package tests: isolated packages under `$TMPDIR` (see docs/AGENTS.md, "Build tip"). For suites with
  real-data tests, run once in the real package with `--scratch-path /Users/advaittahilyani/Lectern/.build-<you>`.
- **Before you report, delete everything you created:** `rm -rf build/DD-<you> .build-<you>` and your
  `$TMPDIR` packages. Never leave a built Lectern.app behind.

## Concurrency
Six agents edit the repo at once, each owning the areas in its brief.
- Shared files (notably `App/Lectern/Models/LiveSessionModel.swift`, `AppModel.swift`,
  `LecternCore/Models.swift`): re-read immediately before every edit, keep edits small and local,
  never reformat or reorder.
- The `decks` agent owns the slide-deck data model change (one lecture → several decks). Everyone
  else keeps using `session.deck` and `BrainContext.deck` as the combined deck.
- Don't commit or touch git state.

## Quality bar
- Every fixed audit item gets a regression test that fails before and passes after, where the logic
  is testable. Port the matching fixture from the audit's `evidence/` folder when one exists.
- Items the audit labels a "risk" must be reproduced before you choose a fix.
- Report per ID: root cause, fix, test evidence. Also list anything you deliberately left, with why.
