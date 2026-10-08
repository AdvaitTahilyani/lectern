# Bug hunt: rules

You own one slice of the codebase. **Read every line of every file in it.** The user wants the app
polished, not "AI slop": find what is actually broken and fix it, however minor.

Also follow docs/ROUND-OCT8.md: builds at `nice -n 15`, no GPU or model runs, never write to the
real library, never touch /Applications, delete your own builds before reporting, don't commit.

## Look for
- Logic errors: wrong conditions, inverted checks, off-by-one, wrong units or timebases, wrong
  variable used, missing `await`/`return`/`break`, unhandled enum cases or states, stale captured
  values, values computed and then ignored.
- Wiring that doesn't work: buttons or menu items that do nothing or the wrong thing, settings
  that aren't read, state that never updates the UI, notifications nobody observes, shortcuts
  bound twice or not at all.
- Lifecycle bugs: tasks never cancelled, observers never removed, work after dismissal,
  continuations never finished, double resumes.
- Real races and leaks, where the failure can actually happen. Not theoretical ones.
- User-facing text: typos, wrong pluralization, wrong numbers, misleading labels, wrong
  accessibility labels/hints.
- Dead code: unused functions, properties, parameters, imports, files; unreachable branches;
  comments that no longer match the code.

## How to fix
- Minimal, local changes that make the code obviously correct. No refactors, renames for taste,
  reformatting, or new abstractions.
- **No pointlessly defensive code.** Don't guard impossible states, don't add `try?` to hide
  errors, don't add fallbacks for things that can't happen.
- **No useless regression tests.** Add a test only when a bug is subtle enough to come back and
  the logic is cheap to test in isolation. Update existing tests that assert the wrong behavior.
- Unsure whether something is a bug? Check how it's used. Still unsure? Report it, don't change it.
- Other agents edit nearby. Re-read a file immediately before each edit. Respect the report-only
  files in your brief.

## Verify
Build what you touched (isolated package for modules; `nice -n 15 Scripts/build.sh DD-<you>` for the
app) and run the existing tests of every module you changed.

## Report
1. Each fix: `file:line`, what was broken (one line), what you changed.
2. Found but not fixed: why (report-only file, judgment call, needs a product decision).
Nothing else: no summaries of what was fine.
