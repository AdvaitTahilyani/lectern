# Lectern third QA pass — Release, real models, and demo regression

30 September 2026. **Live and demo checks attempted; several checks remain partial.** Main blockers are a new audio-engine crash, lost imported slide context, unsafe import accessibility activation, and mismatched missed-concept material. Verified demo fixes include compact pane routing, post-Ask Space, citation navigation/highlights, and takeaway accessibility expansion.

Fresh `Scripts/build.sh DD-codex3 Release` succeeded and was signed with Lectern Local Signing. All Part A launches had **no flags**. Built checkout HEAD: `aec5c509a9482e7740e250b7df282044c613c1ba`; binary hash is retained in `ui-retest3-evidence/binary-sha256.txt`. No source edits or commits. No sign-ins, API keys, cloud-provider calls, or model downloads. Chrome and Visual Studio Code were quit to free memory. App appearance began at System, was changed to Dark and Light for demo verification, and was restored to System. Reduce Transparency, Increase Contrast, and Reduce Motion stayed off throughout; no accessibility setting was changed. Microphone access was explicitly authorized; System Settings already showed Lectern allowed, and onboarding subsequently displayed its input meter.

## 1. Crash / hang results

Baseline **0 active Lectern .ips files**, rather than the prior pass's 24: earlier reports had moved into the system's Retired directory. Final count **1**, including one new file: **Lectern-2026-09-30-164103.ips**. All checkpoints through 16:38:46 were zero. The crash occurred at **16:40:53.5359 +0530**, after the optional microphone session had been stopped and was in Review. Demo checks after relaunch and final quit at 17:15:39 added no further crash reports. Every recorded checkpoint is in [the journal](ui-retest3-evidence/crash-checks.jsonl).

The new crash is **EXC_CRASH / SIGABRT**, on a background cooperative thread. Its stack runs through `AVAudioEngineGraph::InstallTapOnNode`, `AudioCapture.installTap` (AudioCapture.swift:117), `startEngine` (:95), and `handleConfigurationChange` (:165). This is an audio configuration/tap failure, distinct from the previous accessibility recursion. The exact device/configuration-change trigger was not isolated; a guaranteed reproduction is not claimed. [Raw crash](ui-retest3-evidence/Lectern-2026-09-30-164103.ips), [extracted stack](ui-retest3-evidence/new-crash.json), [last microphone Review](screenshots/codex3/49-mic-finished-review.png).

No established Lectern hang was observed. A Finder inspection call stalled for **637 seconds**; an editor inspection earlier took 155 seconds. These are desktop-control delays and do not establish app hangs. The Finder delay extended the optional microphone session from the intended four minutes to **12:19**. An exact resize stress test was not requested or performed in this pass.

## 2. Live-mode findings and timings

### Setup and import

Onboarding passed: microphone meter active, models installed, cloud keys empty ([onboarding](screenshots/codex3/01-onboarding.png), [permission](screenshots/codex3/02-microphone-already-allowed.png), [meter](screenshots/codex3/03-microphone-meter.png), [models](screenshots/codex3/04-models-installed.png), [keys](screenshots/codex3/05-empty-api-keys.png)). Created **CS 426 — Compiler Construction** and saved `~/Documents/CS 426 Lecture Slides` as its folder; persisted course data confirms the exact folder.

Import did **not** suggest a deck; manually selected `lec9-ir-gen.pdf`, whose 34-page preview was visible ([deck selected](screenshots/codex3/08-import-real-deck.png)). Setup later suggested **lec8-ir3.pdf** ([Setup suggestion](screenshots/codex3/45-setup-folder-suggestion.png)). Parakeet was the selected on-device engine; all model roles were On-device (MLX).

An initial import was canceled by activating its combined accessibility progress element (see Q3-2). The timings below describe the restarted primary import only. Its persistent session ID is **68636255-D990-4AA7-9DF2-C86C58F58791**, titled **CS426 QA3 — SSA recap and IR**.

| Event | Time from import start | Evidence / limitation |
|---|---:|---|
| Transcription still at 95% | 88.65 s | [progress](screenshots/codex3/18-transcription-late.png) |
| Summarizing 0% observed | 110.01 s | [stage change](screenshots/codex3/19-import-summarizing.png); transcription completion lies between these observations |
| First takeaway generated | 121.41 s | Persisted `updatedAt`; first card was not displayed individually during background processing |
| Import result / three takeaways completed | 137.17 s | Persisted start/end times; auto-opened Review |
| Lecture summary generated | 173.55 s | Persisted `generatedAt`; approximately 36.38 s after import result |
| First UI observation with three cards | 174.68 s | [Review](screenshots/codex3/20-import-finished.png); includes a 20-second observation call |

Model-load time cannot be isolated from the summarization interval. Stage polling provides bounds, not an exact transcription duration. Raw timings are in `ui-retest3-evidence/live-timings.json`.

### Review and Ask

Three cards appeared and accessible default activation **expanded** the first, with a separate **Show in transcript** action ([expanded](screenshots/codex3/22-real-takeaway-expanded.png)). Content broadly covers phi-function placement, quiz announcements, and AST conversion. The requested recap grouping is **partial**: the first card covers 0:12–3:17, and the AST card starts at 6:46 even though the reference starts the new topic around 8:10. Summary includes overview, concepts, and flags, and ends at a sentence boundary ([summary](screenshots/codex3/21-review-no-slides-summary.png)). It carries the transcription error **V** instead of **B** into its explanation.

**Import lost deck metadata:** Review showed No slides even though `slides.pdf` was on disk. All imported takeaway slide-page lists and corrections were empty. Adding the deck through Review restored the hero and thumbnails ([real deck](screenshots/codex3/23-review-real-deck.png)); reopening the lecture was then needed to refresh Ask's slide context. Thus jargon dotted underlines/original-on-hover were **COULD NOT TEST on this imported session**; the optional microphone session also persisted zero corrections. The toggle itself is enabled. No correction/hover pass is claimed.

| Question | Completed local-answer latency | Result |
|---|---:|---|
| Truncated initial prompt: “What correction d” | 12.379 s | Correct B-prime vs Z correction with 7:53 citation; full intended keyboard input did not land, so this is not a full-question pass |
| How is an addition AST converted to three-address code? | 8.015 s | Grounded T1/T2 explanation with 9:13, 9:36, 9:50 citations ([answer](screenshots/codex3/28-ask2-completed.png)) |
| What register allocation / spill-cost formula was taught? | 8.120 s | Correctly states it was not covered ([abstention](screenshots/codex3/30-ask3-uncovered-answer.png)) |
| Explain slide 6 immediately after attaching deck | 8.428 s | Says no slides were provided: stale Ask context ([failure](screenshots/codex3/31-ask4-slide-answer.png)) |
| Explain slide 6 after reopening lecture | 23.039 s | Correctly rejects “code” premise and explains compilation models, with Slide 6 chip |

These are persisted user-to-assistant-message times, not first-token latency. Repeated streaming accessibility observations survived. Slide 6 chip sets the real hero to **6 of 34** ([success](screenshots/codex3/33-real-slide-citation-success.png)). A 9:13 chip opened Transcript ([timestamp](screenshots/codex3/32-real-time-citation-jump.png)); correct visible-row highlight is not certified. Course citation opens the lecture ([course navigation](screenshots/codex3/38-course-citation-open.png)); exact time destination is not certified.

Both course-wide questions answered: relationship between SSA/AST topics and what was said about virtual registers. Responses cite Lecture 1 ([first](screenshots/codex3/35-course-ask1-answer.png), [second](screenshots/codex3/37-course-ask2-answer.png)); persisted course chat is retained in evidence. Course-answer observation bounds were 25.687 s for the first and 67.174 s for the second; these include time until inspection and are not exact inference latency. The stored course answers have completion timestamps but no paired user-send timestamps.

### Settings and exports

Installed models: **Parakeet 930 MB**, **Gemma 4 26B-A4B 15.64 GB**. Transcription status separately says 600 MB; this size inconsistency is recorded. All roles show on-device providers; September cloud spending **$0.00**. Separate labeled role/provider/model popups now appear, with provider Values and model Help names; model popup Values remain absent ([Models](screenshots/codex3/12-settings-real-models.png), [popup](screenshots/codex3/13-model-popup.png)). **Fix course jargon from slides** is on ([Transcription](screenshots/codex3/11-settings-transcription.png)). Storage showed **553 KB · 1 lecture · 16.57 GB in 2 models** during import ([Storage](screenshots/codex3/10-settings-storage.png)); not a final post-import storage measurement.

Exported and read [Markdown](CS426%20QA3%20Lecture.md), opened [PDF](CS426%20QA3%20Lecture.pdf) in Preview ([open PDF](screenshots/codex3/36-export-open-preview.png)), and opened Markdown through the Codex file tool (queued panel). All **three PDF pages** rendered and were visually inspected. Text, margins, and footers are legible; takeaway titles remain with their bullets. All three ranges move forward. Content defects above persist in both exports.

### Recovery, corruption, deletion, microphone

- **Real interrupted import: PASS.** Forced termination during transcription; relaunch displayed an interrupted-import card with Finish. Finish returned it to a normal Library card ([before](screenshots/codex3/39-second-import-before-kill.png), [offer](screenshots/codex3/40-real-import-recovery-library.png), [finished](screenshots/codex3/41-recovered-import-finished.png)). No resume-transcription offer appeared; Finish-only recovery was tested.
- **Corrupt file: PARTIAL.** Quit, copied the entire app-data directory to `~/Desktop/lectern-backup`, verified every copied file hash, and wrote literal `garbage` to the disposable session's JSON. Relaunch restored JSON byte-for-byte from its `.bak`, preserved the unreadable original, and displayed the interrupted card matching that backup's importing state. No notice explaining backup restoration was observed ([relaunch](screenshots/codex3/42-corrupt-session-restored-notice.png)). The primary lecture was untouched. Backup remains available; the disposable session was finished again before deletion.
- **Deletion: PASS.** Confirmation names **QA3 disposable recovery import** and explains Move to Trash ([confirmation](screenshots/codex3/43-delete-named-confirmation.png)). Library removes only that lecture. Finder confirms its session folder **E76DA276-F35B-417F-A288-CA963AC9EB4D** in Trash with JSON, backup, and unreadable original ([Trash folder](screenshots/codex3/48-deleted-session-in-trash.png)). Trash was not emptied.
- **Real microphone path: PARTIAL / functional pass.** Started with the real deck and played authorized Samantha speech. Final transcript and phi-function recap appeared; Auto followed to **Slide 13** ([result](screenshots/codex3/47-mic-transcript-result.png)). Finish produced two settled takeaways and Review ([finished](screenshots/codex3/49-mic-finished-review.png)). Duration **12:19** due to Finder control stall; exact four-minute behavior and volatile-to-final transition were not observed at their intended times. The timestamped reference text was spoken literally, so numeric timestamp artifacts in this synthetic mic transcript are expected from the test input. This microphone session is retained, ID **04B120A4-D206-4D01-940A-D27AD6DD1923**.

## 3. Per-ID verdicts

Demo relaunched with `-demo -demoSpeed 3` using the same Release binary. Wide is approximately **1512 pt**, compact approximately **757 pt**. Widths refer to window points, not the doubled screenshot pixels. Keyboard results below describe delivered app-targeted native input and observed focus; ordinary manual keyboard confirmation remains useful for inconsistent focus behavior.

| ID / check | Verdict | One-line evidence |
|---|---|---|
| V1 | **PARTIAL** | No Library bleed in [dark wide](screenshots/codex3/61-live-wide-dark.png), [dark compact](screenshots/codex3/62-live-compact-dark.png), [light compact](screenshots/codex3/69-live-compact-light.png), [light wide](screenshots/codex3/70-live-wide-light.png); [Back](screenshots/codex3/75-back-library.png) succeeds and Ask citations work, but a search result leaves hero/transcript at unrelated positions ([destination](screenshots/codex3/77-search-result-opened.png)). |
| F1 | **PARTIAL** | Session ⌘F creates search but initial typing is lost ([first](screenshots/codex3/51-demo-find-shortcut.png)); an active repeat accepts FIRST ([repeat](screenshots/codex3/54-demo-find-active-repeat.png)). Review ⌘⇧T creates an editor but typing fails on two attempts ([repeat](screenshots/codex3/53-demo-title-active-repeat.png)); title focus is **NOT FIXED** in these probes. |
| F2 | **FIXED** | After Ask → Transcript with no editable field focused, Space resumes then pauses in [compact](screenshots/codex3/67-space-after-ask-first.png) / [compact paused](screenshots/codex3/68-space-after-ask-second.png) and [wide](screenshots/codex3/73-wide-space-after-ask-resumed.png) / [wide paused](screenshots/codex3/74-wide-space-after-ask-paused.png). |
| AX Models | **PARTIAL** | Real and [demo](screenshots/codex3/60-demo-models-accessibility.png) roles have separate labeled provider/model popups; provider Values are present, selected model names remain only in Help. |
| N1 | **FIXED** | Ask Slide 9/10 chips set the hero, Auto off, Resume following available in [compact](screenshots/codex3/65-compact-slide-citation.png) and [wide](screenshots/codex3/71-wide-slide-citation.png); 0:33 chips scroll to and highlight the containing 0:26 transcript segment in [compact](screenshots/codex3/66-compact-time-citation.png) and [wide](screenshots/codex3/72-wide-time-citation.png). |
| N2 | **NOT FIXED** | FIRST sets practice shows predictive-parsing material ([first](screenshots/codex3/55-missed-concept-one.png)); LEFT FACTORING shows FIRST-set material even after generation settles ([second](screenshots/codex3/57-missed-concept-two-settled.png)). |
| N3 | **FIXED** | Compact ⌘1–4 select [Takeaways](screenshots/codex3/63-compact-pane-1.png), [Transcript](screenshots/codex3/63-compact-pane-2.png), [Slides](screenshots/codex3/63-compact-pane-3.png), and [Ask](screenshots/codex3/63-compact-pane-4.png) exclusively; no inspector tab container appears. |
| N4 | **FIXED** | Default AX click [expands](screenshots/codex3/58-demo-ax-default-expands.png); named Show in transcript action is exposed and [invoked](screenshots/codex3/59-demo-named-transcript-action.png), separate from default activation. |
| Delete to Trash | **FIXED** | Real named confirmation and actual [Trash folder](screenshots/codex3/48-deleted-session-in-trash.png) verified; demo [named warning](screenshots/codex3/81-demo-delete-confirmation.png) and [Library removal](screenshots/codex3/82-demo-delete-removed.png) also pass. Separate physical Trash verification was on the real disposable session. |
| Focus panel | **PARTIAL** | Toggle exposes “Focus panel open” ([indicator](screenshots/codex3/79-focus-panel-toggle.png)); after raising Safari its blank page retains focus ([capture](screenshots/codex3/80-focus-over-safari.png)). App-only capture/AX selection does not expose the separate floating panel, so topmost stacking, glass rendering, and passive-focus behavior are not certified. |

Search detail: searching FIRST yields a Parsing II takeaway at **7:06 / Slide 7**. A normal AX click selects the row; double-click opens the lecture. The matching FIRST takeaway is visible, but the hero remains **1 of 18**, and Transcript remains near **17:34–20:06** with no 7:06 highlight. Thus basic opening works while precise destination navigation is incomplete. The slide/time badges are not distinct AX buttons. No claim is made that a single-click badge should itself activate.

## 4. New issues

| ID / severity | Screen and repro | Evidence |
|---|---|---|
| Q3-1 **High** | Import Recording → choose WAV + 34-page PDF → import → Review. PDF remains on disk but session loses deck metadata, Review says No slides, card slide associations/jargon corrections are empty. Add Deck restores display; Ask context remains stale until lecture is reopened. | [selected deck](screenshots/codex3/08-import-real-deck.png), [missing slides](screenshots/codex3/21-review-no-slides-summary.png), [stale Ask](screenshots/codex3/31-ask4-slide-answer.png) |
| Q3-2 **High, accessibility** | During import, activate the named progress accessibility element normally. It inherits Cancel, removes the in-flight import without confirmation, and moves its session folder to Trash. The progress element is advertised as a progress indicator; Cancel should be a distinct action. | [before](screenshots/codex3/14-import-progress.png), [after](screenshots/codex3/15-import-stage-screen.png); read-only source corroborates combined children containing Cancel |
| Q3-3 **Medium, content** | Import actual first ten minutes; AST takeaway starts 6:46 although transcript/reference has SSA/quiz discussion until ~8:10. Recap is not grouped through the requested transition. Misheard V instead of B is carried into takeaway and summary. | [takeaways](screenshots/codex3/21-review-no-slides-summary.png), exported Markdown/PDF |
| Q3-4 **Medium** | Corrupt disposable JSON after verified backup and relaunch. Backup restoration works but no restoration notice is observed; only generic interrupted-session banner appears. | [relaunch](screenshots/codex3/42-corrupt-session-restored-notice.png) |
| Q3-5 **Medium, accessibility** | Import sheet's visible Choose Slide Deck / selected PDF / remove control are absent from its AX tree; pointer needed to attach deck. | [sheet](screenshots/codex3/07-import-options.png), paired AX evidence |
| Q3-6 **Low** | Models selected names are in Help rather than popup Value; provider descriptions duplicate their labels. Speech model size is 600 MB in Transcription versus 930 MB in Models. | [Models](screenshots/codex3/12-settings-real-models.png), [Transcription](screenshots/codex3/11-settings-transcription.png) |
| Q3-7 **High** | Real mic lecture → play speech → Stop/Finish → Review → later audio configuration callback aborts. Observed once at 16:40:53; exact external configuration event not isolated. | [last Review](screenshots/codex3/49-mic-finished-review.png), [crash stack](ui-retest3-evidence/new-crash.json), [raw .ips](ui-retest3-evidence/Lectern-2026-09-30-164103.ips) |
| Q3-8 **Medium** | Library search FIRST → double-click Parsing II takeaway labeled 7:06 / Slide 7 after previously visiting that Review. Correct lecture and takeaway open, but hero stays Slide 1 and Transcript retains a later scroll position instead of highlighting 7:06. | [search row](screenshots/codex3/76-search-slide-time-result.png), [destination](screenshots/codex3/77-search-result-opened.png) |
| Q3-9 **Low, layout** | Pause live demo, select Takeaways, resize to compact. A large blank upper area remains above the takeaway stack; no Library content bleeds through it. | [compact light](screenshots/codex3/69-live-compact-light.png), [compact dark](screenshots/codex3/62-live-compact-dark.png) |

Immediate keyboard typing was lost after real ⌘K, and one pointer-assisted typed prompt truncated. Complete prompts set through the field were verified before submission. Demo F1 probes reproduce inconsistent focus, but these observations should still receive an independent ordinary-keyboard check. No source edits were made to investigate them.

The demo Parsing II summary also visibly ends mid-word at “synchroni”; the real model-generated import summary ends at a sentence boundary. This is a remaining fixture/content polish observation, not a failure of every generated summary.

## 5. Top five remaining problems

1. **Prevent the audio-engine configuration/tap abort**, including callbacks around Stop and finished Review.
2. **Preserve imported deck metadata and refresh Ask context**, enabling slide associations and jargon correction throughout import.
3. **Make import accessibility activation safe**, with separate Cancel and visible deck controls.
4. **Match missed-concept practice material to its heading and question**, rather than adjacent takeaway content.
5. **Finish focus and destination routing**, so Find/title shortcuts accept immediate typing and search opens the requested transcript/slide location.

Backup-restoration notices, accurate topic boundaries, selected-model accessibility Values, model-size consistency, and compact empty space remain secondary polish items. Jargon hover and floating-panel composition require a further directly observable check.

### Cleanup and retained artifacts

Lectern was quit; no Lectern process remained at the final check. Appearance is restored to **System** ([verification](screenshots/codex3/83-restored-system-appearance.png)). Reduce Transparency, Increase Contrast, and Reduce Motion remained **0/off**. The temporary blank Safari tab was closed and the Focus panel toggled off. No source edits or commits, no sign-ins/API keys, and no app cloud-provider calls.

The real primary lecture, microphone session, course, Markdown/PDF exports, and verified **~/Desktop/lectern-backup** remain for inspection. The recovery test lecture is recoverable in Trash. Its damaged JSON was restored successfully from backup before it was finished and deleted; no full-directory rollback was needed. Demo deletion affected only a seeded Graph Search fixture. Screenshots and paired AX observations are preserved alongside this report.

Work briefly paused when ordinary quota was exhausted, then resumed after the user's explicit **“let the credit run”** authorization. No further banked reset or credit purchase was initiated. Credit balances are account-wide and are not treated as a measurement of this chat's consumption.

The authorized summary was sent to the existing Claude desktop Lectern conversation by **Return/Enter only**. The new “You said” message appeared, the composer emptied, and Claude entered its waiting/running state. No Send now control was used.
