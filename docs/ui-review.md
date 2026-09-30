# Lectern UI review — 30 September 2026

Report only; no source edits or commits were made. The app has serious accessibility-triggered stability problems and a reproducible visual separation problem between Library and session content. The ordinary Library, deck picker, Settings, Stop, and export paths are substantially more reliable.

## Test run and coverage

- Built with `Scripts/build.sh DD-codex`; **BUILD SUCCEEDED**. Tested `/Users/advaittahilyani/Lectern/build/DD-codex/Build/Products/Debug/Lectern.app`, Debug, demo mode, usually `-demoSpeed 3`.
- macOS 27.0 (26A428), Xcode 27.0 (27A266a), Apple silicon. Starting repository commit: `a838569f33dbc79f7f5420e7c92bcf1706e28a93`. The working tree already contained other agents' edits and continued changing during the review. Findings concern the built binary, not a subsequently rebuilt checkout.
- Native computer use supplied pointer/keyboard interaction, screenshots, and accessibility-tree observations. No real API keys, sign-ins, microphone recording, cloud-provider requests, or model-download buttons were used. Download progress in demo Settings was scripted.
- Screenshots are in `screenshots/codex/`, referenced below by filename. There are **63 PNGs**, including both exported PDF pages. Appearance was forced Light/Dark for comparisons, then restored to **System**.
- Completed: Library/course navigation and search results/no-results; empty setup; real 34-page `TestData/lec9-ir-gen.pdf` through the native picker; loaded fan and all-page preview; microphone picker/meter; real-deck and matching sample-deck demo sessions; NOW updates/settling; expanded takeaway; finalized/volatile transcript and student Q&A; wrong answer and correct follow-up; correct quiz via keyboard after quiz acquired focus; backtrack pill appearance; Stop/Review/quiz results; Markdown and PDF export; Import picker and MediaSpace sheet; Course Ask panel; every Settings tab and all three role-provider menus; brief system accessibility checks.
- **Incomplete, not passes:** literal Finder-to-setup PDF drag; intermediate indexing progress (completed too fast to capture); interrupted-session recovery; a true empty course; full ten-cycle 1300→1000→800 streaming stress test; successful Ask streaming/citation activation; Focus panel over another app; two-minute away recap; review-missed-concepts flow; every shortcut in every supported focus context; every transient state in both appearances. Repeated crashes and the later inspector responsiveness failure blocked these. No PowerPoint fixture was available in the repository; optional real-microphone smoke test was not run.

## 1. Crashes / hangs

### C1 — accessibility resolution repeatedly crashes the app — **high**

Crash baseline: **20** Lectern `.ips` files. Final: **24**. **Four new crashes** occurred in this run:

| New report | Last action / reproduction path |
|---|---|
| `Lectern-2026-09-30-095854.ips` | New Lecture → load real 34-page IR PDF → Start → switch Dark → pause/resume → transcript Find → Ask via ⌘K. Typing did not focus the composer. A subsequent live accessibility-tree observation failed and the process exited. Last successful tree contained two settled takeaways and an empty Ask panel. |
| `Lectern-2026-09-30-101207.ips` | Restart demo → Library → Course Ask via ⌘⌥K → inspect panel → attempt to focus its question field and submit a question. Native accessibility interaction returned `noWindowsAvailable`; a new crash log appeared. |
| `Lectern-2026-09-30-101606.ips` | Matching sample deck → live for over three real minutes → wrong quiz answer and correct follow-up → brief VoiceOver check → restore VoiceOver off → S / ⌘⇧K catch-up attempt → accessibility observation/capture failed; new crash log. The exact action causing termination inside this short sequence is not isolated. |
| `Lectern-2026-09-30-104929.ips` | Fresh demo Library → Course Ask via ⌘⌥K → click suggested “What did he say about FIRST sets last week?” → accessibility observation failed and process exited. This reproduces the course failure without typing into its composer. |

All four report `EXC_BAD_ACCESS` / `SIGSEGV` / `KERN_PROTECTION_FAILURE` on the main thread, with the stack-guard message and repeated `AccessibilityNode.accessibilityLabel()` resolution through AppKit accessibility attribute lookup. The sampled crash stacks each contain 12 accessibility-label frames. This points to a recursive accessibility-resolution problem; it does **not** prove that ordinary mouse-only use or answer generation itself causes the crash.

Evidence: `crash-evidence.json` contains exception metadata and leading frames; original `.ips` files remain in `~/Library/Logs/DiagnosticReports/`. Relevant last-good screens: `09-live-initial-dark.png`, `24-course-ask-dark.png`, `32-voiceover-dark.png`.

### H1 — severe responsiveness failure after compact/wide resizing and inspector reopening — **high**

Reproduction sequence: finish a no-deck demo → Review → use native Window → Move & Resize → Left (757 pt wide, inspector force-closed) → expand window to 1340 pt → reopen Ask with ⌘L → try composer. Subsequent computer-use calls took roughly 2–5 minutes, timed out, or reported no available window. The process stayed alive; there was **no additional crash log** for this failure. It needed quitting/restarting.

A two-second process sample of PID 96209 shows repeated `NSSplitViewItem._setCollapsed` / `SplitViewController.splitViewItem(...didChangeCollapsed...)` updates passing through the inspector binding and `LiveSessionView.setInspector(_:persist:)` (built symbols at lines 30/110). An inspector presentation/collapse feedback loop is a plausible explanation, not a proven source-level diagnosis. See `lectern-hang-sample.txt`, `38-review-narrow-dark.png`, `39-review-1340-dark.png`.

Initial edge-drag attempts did not change width; one later drag timed out. Those attempts alone are not counted as app crashes. The ten-cycle streaming resize test is **not certified**.

## 2. Broken functionality

### F1 — documented focus shortcuts leave focus on the window — **high**

- Library **⌘F** did not put focus in search. Clicking the field worked, including scopes, highlights, and a no-results state.
- Session **⌘F** revealed transcript search but left focus on the window.
- **⌘K** and **⌘L** selected Ask, but did not focus its composer. Text typed immediately after ⌘K was not inserted. DESIGN §4.4/§8 explicitly says to focus the composer.
- **⌘↩ Start** did nothing in setup on two attempts after dismissing the microphone popup. Clicking Start worked.
- **⌘⇧T** did nothing in Review; no inline title field appeared.

Screens: `02-search-empty-dark.png`, `03-search-results-dark.png`, `06-setup-empty-dark.png`, `36-review-dark.png`. Ask focus failure is documented by accessibility state; a successfully populated Ask screenshot could not be captured.

### F2 — keyboard commands depend on quiz focus beyond the documented condition — **medium**

With a quiz visibly present, no text field focused, and the main window focused, **2 then Return** left the question unanswered (`28-quiz-keys-no-response-dark.png`). Clicking option 2 produced the expected explanation and follow-up (`29-quiz-feedback-dark.png`). In a later no-deck run, the quiz container acquired focus and **1 then Return worked**. Thus keyboard answering works in some focus states, but not reliably under §8's “quiz visible, no text field focused” rule.

**Space pause/resume** also did nothing with the main window focused and no text input or takeaway selected; ⌘⇧P worked. Snooze/skip keyboard behavior was not fully verified before termination.

### F3 — demo uses inconsistent time bases, including reversed ranges — **medium; demo-specific**

At 3× speed, transcript timestamps advance faster than the recording clock. Pausing/stopping uses the clock time to end a takeaway that began on the scripted transcript timeline. Review showed **FIRST sets `2:42–1:12`** with total duration `1:13` and transcript through `3:15`. The same reversed range appears in both exports. A previous pause also exposed a reversed range in accessibility text.

Expected: one consistent session timeline; a range must never end before it starts. Do not extrapolate this finding to real microphone mode without retesting. Evidence: `36-review-light.png`, `38-review-narrow-dark.png`, `42-export-page-1.png`, `Lecture Sep 30.md`.

### F4 — demo review summary ends mid-example — **medium; demo-specific**

The summary ends **“A′ → αA′ | ε, e.”** in the UI, Markdown, and PDF. It contains 71 whitespace-separated tokens, so the limit itself is respected, but truncation breaks the sentence/example. DESIGN §4.9 calls for a short coherent summary. Trim at a sentence boundary or generate a complete shorter statement. Evidence: `36-review-light.png`, `41-export-preview.png`, both export files.

## 3. Visual / layout issues

| ID / severity | Screen and screenshot | Observed problem | Expected / design reference |
|---|---|---|---|
| V1 **high** | Live and Review: `25-live-sample-dark.png`, `27-reduce-motion-dark.png`, `38-review-narrow-dark.png`, `39-review-1340-dark.png` | Large blurred Library lecture cards remain behind the Takeaways canvas. This persists past initial transition, after settling, and in Review. At compact width a roughly 188 pt tall band of unrelated Library imagery appears above the summary. It looks like the previous screen has leaked into the current one. | Opaque session canvas, with glass restricted to floating controls. §1 canvas token, §4.4 opaque Takeaways header, §5 settled opaque cards. Library should not remain recognizable behind session reading content. Reduce Transparency removes the bleed (`30-reduce-transparency-dark.png`); Increase Contrast alone leaves it (`31-increase-contrast-dark.png`). |
| V2 **medium** | Models → Local Server: `17-local-provider-light.png` / `17-local-provider-dark.png` | The URL is shown once inside the field and again as a blue label to its right. Model name is `gemma4:12b` inside the field while a separate external `qwen3:8b` label suggests a conflicting value. | One descriptive row label, one field, placeholder inside the field; clear active configuration. §4.10 native grouped Settings. |
| V3 **medium** | Models → OpenAI/Anthropic: `15-openai-light.png`, `16-anthropic-dark.png` | Empty API-key fields are followed by an external “Paste your key” label. It reads as a separate value/control instead of a placeholder, duplicating the row's purpose. | Placeholder in the secure field, with the provider/key label outside it. §4.10. No key was entered. |
| V4 **medium** | Live Slides: `25-live-sample-dark.png`, `29-quiz-feedback-dark.png` | Thumbnail list rows use roughly 200×112 pt images spanning most of the 240 pt column, with number badges over their lower-right corners. Only about 4–5 complete thumbnails fit below the hero in an 800 pt window. | §4.4 specifies compact 96×54 pt list thumbnails and a right-aligned page number. The current version fixes the previously reported tiny-left-image appearance, but trades away scanning density. |
| V5 **medium; polish** | Quiz: `27-reduce-motion-dark.png`, `29-quiz-feedback-dark.png` | The initial quiz occupies about 210 pt of the roughly 712 pt content height; the expanded wrong-answer follow-up is about 240 pt. With NOW beneath it, the two floating cards consume approximately one third to nearly half of available reading height depending on NOW expansion. | §4.6 allows a four-option card, so the basic structure is largely compliant. Make question/feedback expansion less disruptive, particularly at the 520 pt minimum window height. Do not shrink readable option targets. |
| V6 **low** | Settings → Quizzes: `18-quizzes-settings-light.png` / `18-quizzes-settings-dark.png` | “Ask me a question every” has an apparently blank current selection. | Always display the interval or Off. The demo may use an accelerated interval absent from the normal menu; label it explicitly rather than leaving it blank. Real-mode behavior unverified. |
| V7 **low** | Models role rows: `14-models-light.png`, `14-models-dark.png` | Long Gemma model names truncate in the compact model selector. Distinguishing quantization/name details are hidden. | §4.10 clear role/provider/model assignments. A wider field or full-name help would improve identification. |
| V8 **low** | Export PDF: `42-export-page-1.png`, `42-export-page-2.png` | The FIRST-set takeaway crosses the page boundary after its first bullet; page 2 starts with the remaining bullets and “Slides 7, 8,” without a repeated title. | §4.9 export typography is otherwise clean: Letter, readable margins, complete glyphs, page footers. Keep small takeaway blocks together where practical, or repeat the heading on continuation. |

Measured dimensions are approximate logical points from 2× screenshots. No pixel-perfect animation timing or color contrast measurement was performed.

## 4. Known-issues checklist

| Known issue | Result |
|---|---|
| Header “Listening…” doubled or clipped | **Not reproduced as a persistent defect.** Steady Listening and Summarizing labels fit. Brief ghosting was visible around a label crossfade; insufficient to call a lasting doubled label. |
| Finalized transcript as dim as volatile text | **Not reproduced.** Final text is visibly brighter; only the in-progress tail is gray. Student/lecturer Q&A grouping also renders clearly (`30-reduce-transparency-dark.png`, `32-voiceover-dark.png`). |
| Small left-aligned slide thumbs, far-right page number | **Not reproduced.** Thumbs fill the row and page numbers overlay lower-right. The different density issue is V4. |
| Quiz takes too much Takeaways height | **Confirmed as a space/polish concern**, quantified in V5. Not a claim that the basic four-row layout violates §4.6. |
| Snooze/Skip are bare text links | **Not reproduced.** Both have visible rounded filled button styling in the tested build. They remain very small secondary controls. |
| Real Liquid Glass renders well | **Confirmed for toolbar, NOW, quiz, Stop popover and backtrack pill.** Rounded highlights/material variation and opaque accessibility fallback are visible. Overall result is undermined by V1's canvas bleed. **Focus panel glass not verified**: toggling changed the app's Focus-open indicator, but this inspection did not establish the floating panel's appearance over another app. |

## 5. Shortcuts

DESIGN §8 is the authority. The request's Course Ask shortcut conflicts with it: **⌘⌥K is Course Ask; ⌘⇧K is live catch-up**.

| Shortcut | Observed result |
|---|---|
| ⌘N | Pass: setup opens. |
| ⌘, | Pass: Settings opens. |
| ⌘F | Fail focus in Library; transcript search opens without focus. |
| ⌘↩ | Start failed twice; Finish attempt did not dismiss Stop popover; clicking Finish worked. Ask send unverified due stability failures. |
| ⌘⇧P | Pass: pause/resume and paused transcript marker. |
| Space | Failed pause/resume with main window focus and no text input/takeaway focus. |
| ⌘. | Pass: Stop confirmation popover. |
| ⌘K / ⌘L | Ask opens; composer focus fails. |
| ⌘⇧K | Attempted late in the live run; crash before a catch-up result could be verified. |
| ⌘⇧F | Focus-open indicator toggles. Actual floating/nonactivating behavior unverified. |
| 1–4 / Return | 2/Return failed with window focus; 1/Return passed with quiz focus. All four keys individually not certified. |
| S / Esc (quiz) | S attempted; state changed around live progression, but snooze outcome not isolated. Esc skip not certified. |
| ⌘E | Pass: native Markdown save panel; PDF available in Export menu. |
| ⌘⇧T | Fail: no edit field in Review. |
| ⌘⌥K | Pass: Course Ask panel opens; interacting with it reproduces C1. |
| ⌘⇧I (Import) | Pass: Import Recording sheet. |
| ⌘⇧N, ⌘⌥I, ⌘⌥S, ⌘1/2/3/4, ⌘↓, takeaway ↑/↓/Return/Esc, slide ←/→, ⌘⇧A, ⌘⇧C, takeaway ⌘C, ⌃⌘S | Not fully tested in their required focus contexts. Do not treat this group as failed or passed. Pointer sidebar/course navigation and takeaway expansion worked. Inspector reopening after resize is covered by H1. |

## 6. Accessibility findings

- **High: accessibility stability.** Four crashes during accessible interaction/inspection make this the first accessibility fix. VoiceOver was not needed for the first two crashes.
- **High: Library cards lose individual accessible targets.** The lecture collection was represented as one long combined text element containing multiple lectures, rather than independently selectable/openable lecture cards. Section headers and toolbar controls were exposed normally. §9 requires actionable custom controls.
- **Medium: setup labels erase distinct actions.** Empty setup exposes Choose/sample links as “Drop the slide deck here.” Loaded preview, Replace, and Remove become “Slide deck loaded” (Remove has a help hint). The visual controls differ, but their accessible names do not. Give each action a distinct label.
- **Medium: Models role pickers are absent from the accessible control tree.** Roles were combined into text; menus could be opened by pointer coordinates. Provider/model assignment should expose separate labeled popup controls and selected values.
- **Takeaways:** collapsed cards expose title, range, slides, summary and secondary Copy/Ask actions. Expanded cards expose details, terms, slides, timestamp and buttons. The quiz options were exposed on later observations; earlier visible quiz states lacked them in the returned tree. This variation and C1 prevent a reliable screen-reader pass.
- **Reduce Motion:** switched on during live playback; tested settled cards, volatile/final text and quiz state. No gross layout failure. A motion capture was not recorded, so the absence of every animation cannot be certified.
- **Reduce Transparency:** on/off verified. Opaque fallback removes the Library bleed and keeps text readable (`30-reduce-transparency-dark.png`).
- **Increase Contrast:** on/off verified. UI remains readable, but the unrelated Library bleed persists. No numerical WCAG contrast pass claimed.
- **VoiceOver:** ⌘F5 did not enable it in this environment; enabled explicitly in System Settings, briefly inspected expanded takeaway/quiz, then disabled. Spoken announcements/audio were not captured, so announcement correctness is unverified.
- **Restoration:** Reduce Motion, Reduce Transparency, Increase Contrast and VoiceOver are all off again, as at baseline. App appearance is back to System. Window geometry/sidebar/inspector preferences were exercised during QA; their original geometry was not restored precisely.

## 7. Five changes with the greatest polish impact

1. **Fix accessible-label recursion and inspector presentation feedback first.** A lecture app must survive screen-reader interaction, pane switching and resizing. These failures prevent trustworthy QA of Ask and recovery flows.
2. **Make every session reading canvas opaque.** Remove the previous Library screen from behind Live and Review; keep glass on floating controls only.
3. **Make shortcut focus reliable.** Search and Ask should immediately accept typing, Start/Finish/title-edit should match displayed shortcuts, and quiz answering should work whenever the documented conditions hold.
4. **Clean up Settings form labeling.** Eliminate external placeholder/value duplicates, show the active interval, expose role pickers accessibly, and make selected models identifiable.
5. **Improve reading density and temporal coherence.** Compact the slide list, manage quiz/feedback height without shrinking targets, use one demo timeline, and finish summaries at complete sentence boundaries.

### Export verification and screen inventory

`Lecture Sep 30.md` was opened/read and contains metadata, Summary, Takeaways, Quiz and timestamped Transcript. `Lecture Sep 30.pdf` opened in Preview; both Letter-sized pages were rendered and visually checked. Text is legible, math/Greek glyphs render, footers are present, and there is no observed overlap or clipping. Content defects F3/F4 are shared by both formats. Files are retained beside this report in the QA outputs directory.

Screens by group: `01–05` Library/search; `06–08` setup/deck preview; `09–10` real-deck live/pause; `12–20` all Settings tabs/providers; `21–23` Import/MediaSpace; `24` Course Ask; `25–32` sample live/quiz/accessibility; `34–35` no-deck live/Stop; `36–39` Review/results/compact-wide layouts; `41–42` exported PDF. `26-focus-dark.png` is a limited composite capture, not evidence that Focus floats correctly. Screenshot `07-setup-loaded-light.png` shows completed indexing, not intermediate progress.
