# Lectern UI retest — 30 September 2026

Report only. No source edits, commits, real API keys, sign-ins, model downloads, or real recording were performed by this reviewer. Read `ui-review.md` before testing. Fresh `Scripts/build.sh DD-codex2` build succeeded; all launches used that Debug app with `-demo -demoSpeed 3`.

**Scope:** approximately 11:45–13:02 IST, macOS 27, native computer use and accessibility observations. Starting checkout HEAD was `1974eab011be88469cea9283347d8624e455cbdc`. Other work continued in the repository during testing; ending HEAD was `74f215885e8f86252becf1f67379b781c01bffb8`. Results describe the binary built at the start, not later source changes. Existing edits were left alone.

Screenshots below are relative to `screenshots/codex2/`. Dimensions are approximate logical points measured from 2× captures. FIXED means the requested behavior passed in the tested contexts; incomplete coverage is explicitly identified.

## 1. Crash / hang results

**Baseline: 24 Lectern `.ips` files. Final after quitting: 24. New `.ips` names: none.** Filename-set comparison also found no additions. The deliberate `pkill -9 Lectern` recovery test did not add a crash report.

| Checkpoint (IST) | `.ips` count | New files |
|---|---:|---|
| Before build, 11:45:01 | 24 | None |
| Fresh launch, 11:47:06 | 24 | None |
| Course Ask composer, 11:48:05 | 24 | None |
| Course Ask suggestion, 11:48:47 | 24 | None |
| Session Ask, 11:50:42 | 24 | None |
| VoiceOver pass, 11:53:11 | 24 | None |
| Initial quiz/menu checks, 11:54:44 | 24 | None |
| Original H1 sequence, 11:57:56 | 24 | None |
| Resize calibration, 12:01:01 | 24 | None |
| Settings / accessibility, 12:05:42 | 24 | None |
| Focus shortcuts / Review, 12:09:49 | 24 | None |
| PDF / Markdown exports, 12:12:12 | 24 | None |
| Focus / away checks, 12:17:35 | 24 | None |
| Continuation, 12:25:09 | 24 | None |
| Interrupted-session relaunch, 12:26:54 | 24 | None |
| Missed-concept practice, 12:28:20 | 24 | None |
| Additional H1 attempts, 12:32:46 | 24 | None |
| Compact keys / remaining shortcuts, 12:39:00 | 24 | None |
| Window-menu control limitation, 12:40:58 | 24 | None |
| Independent quiz-key checks, 12:45:04 | 24 | None |
| V1 / inspector streaming stress, 12:53:39 | 24 | None |
| Ask citations / transcript jump, 12:57:09 | 24 | None |
| Settings restoration, 13:01:57 | 24 | None |
| Final after quit, 13:02:06 | 24 | None |

### C1: FIXED in this retest

All four requested paths survived: session Ask via ⌘K and typing with the real 34-page fixture; Course Ask via ⌘⌥K and its composer; Course Ask via a suggested prompt; and VoiceOver traversal of takeaways, quiz, and Ask answers. Repeated accessibility reads during streaming also survived: six observations for each Course Ask path and eight for session Ask. Screens: [session stream](screenshots/codex2/07-session-ask-stream.png), [course composer](screenshots/codex2/03-course-ask-composer.png), [course suggestion](screenshots/codex2/04-course-ask-suggestion.png), [VoiceOver Ask](screenshots/codex2/12-voiceover-ask.png), [takeaway](screenshots/codex2/13-voiceover-takeaway.png), [quiz](screenshots/codex2/14-voiceover-quiz.png).

This verifies crash survival, not the accuracy of every spoken announcement; VoiceOver audio was not recorded.

### H1: PARTIAL — original sequence passes; exact stress test remains uncertified

Review → Window → Move & Resize → Left (757 pt) → expand to 1340 pt → ⌘L → type completed without the previous multi-minute responsiveness failure. Sizing action calls measured about 243 ms and 762 ms. The composer accepted the typed probe after focus settled. Screens: [757 pt](screenshots/codex2/21-review-left-757.png), [1340 pt](screenshots/codex2/22-review-expanded.png), [typed composer](screenshots/codex2/24-review-ask-typed.png).

The requested **ten cycles of 1300 → 1000 → 800 → 1300 pt were not achieved**. Repeated side/corner/alternate-edge drags left the window width unchanged. Some Window-menu attempts then produced stale-element errors and prevented further computer-control observations until relaunch. This is a control limitation, not evidence establishing an app hang.

A further ten-cycle attempt using window zoom plus inspector toggles ran to completion. All twenty captured widths were actually **1512 pt**, so it does **not** substitute for the requested resize test. Twenty inspector toggles succeeded; ten observations contained an actively streaming transcript tail. Maximum action-call durations were 470 ms for zoom and 167 ms for inspector toggling. These are tool-call measurements, not instrumented render/input latency. Screens [first](screenshots/codex2/116-stress-1-compact.png) and [last](screenshots/codex2/116-stress-10-wide.png). No new crash reports or the old multi-minute inspector-binding stall were observed, but the full width-changing / every-action-under-one-second bar is **not certified**.

## 2. Per-ID verdicts

| ID | Verdict | One-line evidence | Screenshot |
|---|---|---|---|
| C1 | **FIXED** | All four requested accessibility paths and repeated streaming-tree reads survived; 24 → 24 `.ips`. | [07](screenshots/codex2/07-session-ask-stream.png), [14](screenshots/codex2/14-voiceover-quiz.png) |
| H1 | **PARTIAL** | Exact original compact/wide/Ask repro passed; ten cycles at the four specified widths could not be completed. | [24](screenshots/codex2/24-review-ask-typed.png) |
| V1 | **PARTIAL** | Light and tested Review canvases are opaque; dark Live still shows recognizable Library cards at wide and compact widths with Reduce Transparency off. | [wide dark](screenshots/codex2/25-live-wide-dark-bleed.png), [compact dark](screenshots/codex2/97-compact-key-3.png), [compact light](screenshots/codex2/118-live-compact-light-early.png) |
| F1 | **PARTIAL** | Library search, wide Ask, Start and Finish work; transcript Find and title editor still fail to acquire typing focus, and compact Ask is inconsistent. | [11](screenshots/codex2/11-session-find-no-focus.png), [46](screenshots/codex2/46-title-saved.png), [110](screenshots/codex2/110-takeaway-copy-retry.png) |
| F2 | **PARTIAL** | Keys 1–4, snooze, skip and Space work in fresh-session contexts; Space still fails with only the window focused after returning from Ask. | [1](screenshots/codex2/15-quiz-key-1.png), [2](screenshots/codex2/31-quiz-key-2-return.png), [3](screenshots/codex2/104-quiz-key-3-followup.png), [4](screenshots/codex2/103-compact-key-4-active.png), [failure](screenshots/codex2/124-space-after-citation.png) |
| AX: Library cards | **FIXED** | Lecture cards are separate named buttons with Open actions; invoking Open entered the selected lecture. | [01](screenshots/codex2/01-library-accessibility.png) |
| AX: Setup actions | **FIXED** | Choose, Use sample deck, Replace and Remove have distinct accessible names. | [empty](screenshots/codex2/05-setup-empty-names.png), [loaded](screenshots/codex2/06-setup-loaded-names.png) |
| AX: Models role pickers | **NOT FIXED** | Summaries / Quizzes / Ask remain a combined text node; their popup roles and selected values are absent. | [36](screenshots/codex2/36-settings-models.png) |
| V2 | **FIXED** | Local-server URL and model fields each have one descriptive label, with placeholders inside the fields. | [37](screenshots/codex2/37-settings-local-fields.png) |
| V3 | **FIXED** | OpenAI and Anthropic key placeholders are inside empty secure fields; no external “Paste your key” duplicate. | [38](screenshots/codex2/38-settings-api-fields.png), [39](screenshots/codex2/39-settings-anthropic-fields.png) |
| V6 | **FIXED** | Quiz interval displays 8 minutes; the open menu also labels the current/custom interval and all normal choices. | [40](screenshots/codex2/40-quiz-interval.png), [41](screenshots/codex2/41-quiz-interval-menu.png) |
| V4 | **FIXED** | Slide-list images are approximately 96 × 54 pt, with separate page numbers aligned right; checked real and sample decks. | [14](screenshots/codex2/14-voiceover-quiz.png), [20](screenshots/codex2/20-review-wide-dark.png) |
| V5 | **FIXED** | Asking/follow-up cards stay around 210 pt with at least two settled takeaways visible at the tested 949 pt window height. | [28](screenshots/codex2/28-resize-edge-inset.png), [43](screenshots/codex2/43-live-compact-dark.png) |
| V7 | **FIXED** | Full Gemma 4 26B-A4B (QAT 4-bit) names are visible in the model-role rows. | [36](screenshots/codex2/36-settings-models.png) |
| V8 | **FIXED** | Fresh six-page PDF keeps every takeaway title with its first bullets; all six pages were rendered and visually checked. | [page 1](screenshots/codex2/56-pdf-page-1.png), [page 2](screenshots/codex2/57-pdf-page-2.png) |
| F3 | **FIXED** | All nine exported takeaway ranges move forward, from 0:00–0:17 through 2:41–3:12, matching Review / Markdown / PDF. | [54](screenshots/codex2/54-review-exported.png), [57](screenshots/codex2/57-pdf-page-2.png) |
| F4 | **FIXED** | Fresh Review/export summary ends “one token always suffices.”; copied seeded summary also ends with a complete sentence. | [54](screenshots/codex2/54-review-exported.png), [75](screenshots/codex2/75-summary-shortcut-copy.png) |

V5 was not certified at the 520 pt minimum height. Fixed classifications above concern this demo build; no real-provider or microphone-mode result is inferred.

### F1 individual shortcut results

| Shortcut / context | Result |
|---|---|
| Library ⌘F, then typing | **FIXED** — search receives the typed probe ([02](screenshots/codex2/02-library-command-f.png)). |
| Session ⌘F, then typing | **NOT FIXED** — search opens but remains empty and focus stays outside it ([11](screenshots/codex2/11-session-find-no-focus.png)). |
| Wide session ⌘K / ⌘L, then typing | **FIXED after focus settles** — composer accepts input ([07](screenshots/codex2/07-session-ask-stream.png), [24](screenshots/codex2/24-review-ask-typed.png)); some immediate probes were lost before the focus transition completed. |
| Setup ⌘↩ | **FIXED** — starts the demo. |
| Stop popover ⌘↩ | **FIXED** — finishes and enters Review ([44](screenshots/codex2/44-stop-popover.png), [45](screenshots/codex2/45-review-compact-dark.png)). |
| Review ⌘⇧T, type, ↩ / Esc | **PARTIAL** — field appears but does not acquire focus; clicking the field makes Return save and Escape cancel work ([48](screenshots/codex2/48-title-pointer-save.png), [49](screenshots/codex2/49-title-pointer-cancel.png)). |

Screenshot names `46-title-saved` and `47-title-cancelled` describe the attempted action, **not successful outcomes**. They show the failed unfocused attempts. Screens 48/49 are the successful pointer-assisted checks.

### F2 individual key coverage

Options 1 and 2 were tested on distinct initial questions, and options 4 then 3 on an initial question and its follow-up. Each selected/graded the corresponding answer; multiple-choice selection auto-submits, so Return is not necessary. S removed an active asking card ([97](screenshots/codex2/97-compact-key-s.png)). Escape removed a confirmed fresh FIRST-set question ([before](screenshots/codex2/106-quiz-escape-before.png), [after](screenshots/codex2/107-quiz-escape-after.png)). Space paused/resumed fresh sessions ([32](screenshots/codex2/32-space-pause.png), [33](screenshots/codex2/33-space-resume.png), [108](screenshots/codex2/108-space-after-quiz.png)).

**Remaining F2 repro:** paused Live → ⌘K and type/submit Ask → click a timestamp citation to return to Transcript → with the main window focused and no text field visible, press Space. It remains paused. AX identifies the focused element as the standard window ([124](screenshots/codex2/124-space-after-citation.png)). Earlier window-focus/resize contexts also ignored numeric keys before a fresh session/pane focus restored them. Screens 16–18 were taken after an already-graded question and are **not** independent numeric-key passes.

## 3. Previously untested checks

| Check | Result and evidence |
|---|---|
| Ask end to end | **PARTIAL.** Question submission, answer streaming and stable AX reads pass. A paused live session at 2:03 produced FOLLOW answer chips for Slide 9, Slide 10 and valid transcript time 1:03. Clicking Slide 9 by both accessible action and visible pointer chip scrolled the thumbnail list but left hero **12 of 18**, Auto on ([120](screenshots/codex2/120-ask-slide-pointer-result.png)). Clicking 1:03 switched to Transcript but its first visible moment remained 1:22; the requested 1:03 was above the viewport ([121](screenshots/codex2/121-ask-valid-timestamp-result.png)). |
| Focus panel over Safari | **PARTIAL / visual requirements COULD NOT TEST.** ⌘⇧F toggled the Focus-open indicator. Safari accepted an address-field typing probe ([55](screenshots/codex2/55-focus-over-safari.png), [59](screenshots/codex2/59-focus-safari-clicked.png)). The control API routes input to a selected app and captures only that app's main window; it supplied no separately targetable macOS panel/window inventory. Thus this does not certify on-top stacking, nonactivation, or glass over Safari. No claim based solely on the implementation's floating/nonactivating flags. Panel was closed afterward. |
| While you were away | **FIXED / passes.** Switched to Safari for approximately two minutes (then repeated for over three minutes). The recap was eventually observed at the **top** of Takeaways: “Away 2 min · 6:22–8:12,” with panic-mode recovery, reading reminder and slide/transcript actions ([66](screenshots/codex2/66-live-wide-dark-top.png), [67](screenshots/codex2/67-away-recap-top.png)). Earlier scrolled-down screenshots 58/61 missed the card; they are not evidence of absence. Debug fallback was unnecessary once the card was found. |
| Review missed concepts | **PARTIAL.** Entry, fresh questions, grading, Next through both items, Exit, and completion back to Review work ([125](screenshots/codex2/125-review-practice-start.png), [126](screenshots/codex2/126-review-practice-second.png), [127](screenshots/codex2/127-review-practice-completed.png)). Associated takeaway content is wrong for both seeded missed concepts; see N2. |
| Interrupted-session recovery | **COULD NOT TEST persistent recovery.** Resumed a live demo, captured it ([68](screenshots/codex2/68-live-before-interruption.png)), ran `pkill -9 Lectern`, relaunched with demo arguments, and inspected Library. It contained seeded finished lectures and **no Resume or finish offer** ([69](screenshots/codex2/69-recovery-library.png)). DemoStore is in-memory per read-only source inspection, so the live demo session does not survive process death. This is an unsuccessful result for the requested demo sequence; real persisted-session recovery remains unverified. |

### Remaining shortcuts

| Shortcut | Result |
|---|---|
| ⌘⌥S | **FIXED / passes** — hides and restores the wide Slides column; AX logs record disappearance/reappearance. |
| ⌘1 / ⌘2 / ⌘3 | **PARTIAL** — compact segmented-control selections change correctly ([1](screenshots/codex2/100-pane-1.png), [2](screenshots/codex2/100-pane-2.png), [3](screenshots/codex2/100-pane-3.png)); ⌘2 also opens a cramped inspector (N3), and wide ⌘1/3 did not demonstrate the promised transfer of keyboard focus. |
| ⌘4 | **PARTIAL** — wide Ask opens and focuses the composer; compact attempts could leave Transcript displayed without an Ask composer ([110](screenshots/codex2/110-takeaway-copy-retry.png)). |
| ⌘↓ | **FIXED / passes** — after scrolling Transcript to older content, jumps back to its current bottom ([before](screenshots/codex2/122-transcript-before-jump-live.png), [after](screenshots/codex2/123-transcript-after-jump-live.png)). |
| ⌘⇧A | **FIXED / passes** — manual Slide 1 disables Auto and shows Resume following; shortcut restores Auto and detected Slide 10 ([82](screenshots/codex2/82-manual-slide.png), [83](screenshots/codex2/83-resume-slide-following.png)). |
| ⌘⇧C | **FIXED / passes** — copied Review summary was pasted into an unsent composer and contained the complete summary ([75](screenshots/codex2/75-summary-shortcut-copy.png)). |
| ⌘C on a takeaway | **PARTIAL** — works after pointer-expanding a takeaway: pasted Markdown begins `### From tokens to syntax trees (0:00–0:18)` ([113](screenshots/codex2/113-takeaway-pointer-expanded.png), [114](screenshots/codex2/114-takeaway-copy-success.png)). Collapsed card / keyboard-focus behavior is not certified; accessible default activation took a different action (N4). |

## 4. New issues

| ID / severity | Screen and screenshot | Reproduction and observed result |
|---|---|---|
| N1 **high** | Live Ask / citations: [120](screenshots/codex2/120-ask-slide-pointer-result.png), [121](screenshots/codex2/121-ask-valid-timestamp-result.png) | Start sample-deck demo → pause around 2:03 with hero Slide 12 → Ask “Explain FOLLOW sets and their role.” → click Slide 9 chip: list scrolls, hero remains 12 and Auto stays on. Click valid 1:03 chip: Transcript opens but the cited moment is above the visible viewport (first visible timestamp 1:22). |
| N2 **medium; seeded demo** | Review practice: [72](screenshots/codex2/72-review-missed-question.png), [126](screenshots/codex2/126-review-practice-second.png) | Library → seeded Parsing II, CS 421 → Quiz → Review missed concepts. FIRST sets item shows a FOLLOW takeaway and FOLLOW bullets; Next to left factoring shows panic-mode recovery. Questions themselves match the concept labels, so the study material conflicts with the retry question. Reproduced in two passes. |
| N3 **medium** | Compact Live panes: [101](screenshots/codex2/101-fresh-quiz-monitor.png), [110](screenshots/codex2/110-takeaway-copy-retry.png) | At 757 pt, invoke ⌘2: pane changes to Transcript but inspector also opens, leaving a roughly 416 pt main region and duplicate transcript surfaces. Invoke ⌘4 in compact mode: Ask/composer can remain absent while Transcript stays displayed. Enlarging restores the Ask inspector. |
| N4 **medium; accessibility** | Takeaway activation: [109](screenshots/codex2/109-takeaway-expanded.png), [113](screenshots/codex2/113-takeaway-pointer-expanded.png) | With collapsed “From tokens to syntax trees” exposed as a button with “Double-tap to expand,” invoke its default accessible click. It seeks to Transcript instead of expanding the card. A pointer click on the visible title expands and exposes the detail/Copy controls. The combined element appears to inherit a timestamp action; observed behavior is the finding, not a confirmed source diagnosis. |

Existing V1/F1/F2/Models findings are not duplicated as new issues. The apparent practice-card overflow in early screenshot 71 resolved when the generated question finished (72), so it is not listed as a persistent defect. Long demo runtime can generate timestamps beyond available scripted content; the final N1 timestamp check deliberately used a time actually present in the transcript.

## 5. Top five remaining polish items

1. **Finish opaque dark-session backgrounds (V1).** Remove recognizable Library content from early wide and compact Live reading regions; Light and tested Review already look substantially better.
2. **Make keyboard focus survive navigation and layout changes (F1/F2/N3).** Focus transcript Find/title fields immediately, restore session-wide keys after leaving Ask, and keep compact pane shortcuts coherent.
3. **Make citations land visibly on their target (N1).** Slide citation should select the cited hero and override following; timestamp citation should bring the corresponding transcript moment into view when switching tabs.
4. **Expose actionable accessibility controls.** Separate labeled model-role popups with selected values, and make takeaway default activation match its expansion hint (N4).
5. **Align missed-concept practice material with the concept (N2).** FIRST/FOLLOW and left-factoring/panic-mode mismatches make the otherwise working practice flow confusing.

### Cleanup and retained evidence

App appearance restored to **System** ([128](screenshots/codex2/128-appearance-restored-system.png)); **VoiceOver off** ([129](screenshots/codex2/129-voiceover-restored-off.png)). Reduce Transparency and Increase Contrast were verified off and were not enabled during this retest; Reduce Motion was not changed. Temporary Safari typing-probe tabs were closed. Focus panel was closed. `pkill -x Lectern` completed; a subsequent process check found no Lectern process. Window geometry/inspector preferences were exercised and were not restored to an exact original size.

Fresh [Markdown](ui-retest-evidence/exported-lecture.md) and [PDF](ui-retest-evidence/exported-lecture.pdf) exports are retained. The Markdown includes metadata, complete summary, all nine forward takeaway ranges, quiz records and transcript. The six-page PDF opened in Preview and was rendered in full; takeaway blocks on pages 1/2 remain together. Export-content checks concern these files, not old review exports.

Raw crash checkpoints, streaming accessibility snapshots, Models accessibility state, shortcut traces and the unsuccessful width-stress measurements are retained under `ui-retest-evidence/`. Screenshots named “calibration,” “attempt,” “saved,” or “stress compact” must be interpreted using this report rather than assumed to prove the attempted state.
