# CS 426 lecture 9 — full-length evaluation of the real stack

Run: `LecternHarness -selftest pipeline -audio TestData/cs426-lecture.wav -slides TestData/lec9-ir-gen.pdf -speed 4 -report TestData/pipeline-full-85min.md -quizzes 8 -recaps "0-8,42-54,62-75" -asks "…"` (Release build `DD-eval`, Gemma 4 26B A4B QAT 4-bit via in-process MLX for all three roles, Parakeet + diarization for speech).

Artifacts: `TestData/pipeline-full-85min.md` (raw report, memory table, every LLM call), `TestData/pipeline-full-85min.transcript.txt` (what Parakeet actually produced, with L/A speaker tags). Ground truth is `TestData/cs426-reference.txt` (machine captions, but good enough to locate topic changes) and the deck `lec9-ir-gen.pdf`.

Conditions: 85:00 of audio at 4×, 820 segments, wall 1631 s (feed 1277 s, i.e. on schedule; then 67 s to drain and settle; quizzes 197 s; 5 Asks 48 s; 3 recaps 42 s). 34 GB machine, load average ~12 at start. A Codex QA session (`build/DD-codex2/.../Lectern -demo -demoSpeed 3`, PID 81309) **was running** at the start of the run and at ~12 min in; it was gone at ~22 min (i.e. it overlapped most of the feed). Other agents' builds were also active. Treat latencies as pessimistic; the ratios (overlap vs alone) are more trustworthy than the absolutes.

## What the lecture actually contains (from the reference)

| Time | Real content |
|---|---|
| 0:07–1:00 | Correction of a slide from lecture 8 (phi placement: B' not Z) |
| 1:09–6:28 | Mini quiz 1, mostly silent; brief remarks on the "can" wording |
| 6:28–8:00 | Answers to the quiz (diamond CFG needs no phi); second slide correction |
| 8:03–16:00 | Today's goal: AST to 3-address code; the 3 cases (constant, variable, e1+e2); virtual registers are unlimited; loadI, symbol table, base+offset, loadAI |
| 16:00–22:40 | `genExpr`: NUM case, `new_reg_name` counter, ID case (base/offset from symbol table), "no single correct IR" (mult vs shift) |
| 22:40–26:00 | PLUS case: recursive genExpr returns the result register; `emit` |
| 26:00–29:00 | COOL IR differs from the slides; LLVM build APIs create SSA registers; reusing registers makes liveness hard; only expressions so far |
| 29:00–37:15 | Worked example `4 + a + 2` (needs left assoc. AST), unoptimized code, offset-0 loads, "be naive, optimize in a separate pass" |
| 37:15–42:10 | `*`, `-`, `/` (div by zero → signal), example `x + 4*y`, precedence belongs to the front end |
| 42:10–44:30 | Aside: instruction scheduling, ILP, pipeline bubbles |
| 44:31–53:51 | Mixed-type expressions, conversion tables, `x + 4.0` needs a convert op, fadd vs add, semantic analysis placement |
| 53:53–59:30 | `let`: naming vs assignment, alloc + store, Expr must not contain x |
| 59:42–60:33 | Nested lets, shadowing, symbol-table hierarchy |
| 60:33–66:22 | Boolean/relational expressions; true=1/false=0 (or nonzero); logical vs bitwise `&&`/`&` teaser, answer deferred to next class |
| 66:45–71:34 | Mini quiz 2 (announcement about B1–B5 labels), silent, "we can end the class" |
| 71:34–74:15 | Post-class student chatter (advisor, Rubik's cube) |
| 74:15–77:00 | Q: casting convention / language manual; CompCert |
| 77:00–81:33 | MP1 viva, credit-hour petition, draw the CFG/dominator tree, **exam is written, not MCQ** |
| 81:33–85:00 | Debug vs release builds of the compiler; why ILOC in lecture but LLVM in the MPs |

So there are roughly 16–19 distinct topics; the last 13 minutes are Q&A and administration with a few real technical answers.

## 1. Cards

**Count: 14** (target ~17). Durations: 2:50, 3:14, 3:54, 4:04, 4:30, 4:39, 4:58, 6:10, 6:28, 6:34, 6:36, 7:53, 9:26, 10:02; median 5:34, mean 5:48. The two longest (10:02, 9:26) are the last two cards, both mostly non-lecture. Real content cards run 2:50–7:53, which is fine; the shortfall is that whole stretches produce no card.

**Opening recap card exists** ("Recap: Node convergence and phi functions", 0:07–4:37), but see the gap below.

### Boundary table

| System boundary | Nearest true boundary | Verdict |
|---|---|---|
| 0:07 | 0:07 | ok |
| 4:37 end of recap, **next card starts 8:11** | quiz answers run to 8:00 | **3:34 hole with no card**, which contains the quiz explanation (6:28–7:23) and the second slide correction (7:31) |
| 8:11 | 8:03 | ok |
| 16:04 | 16:00 (genExpr) | ok |
| 22:40 | 22:39 (PLUS case) | exact |
| 25:54 | 26:00 (COOL IR / build APIs) | ok |
| 30:52 | 29:06 (`4+a+2` example starts) | 1:46 late; the card mid-example |
| 34:56 | 34:58 ("optimizations done later") | exact |
| 37:46 | 37:15 (other operators) | 31 s late, harmless |
| 44:20 | 44:31 (mixed types) | ok |
| 48:14 | none (still mixed types until 53:51) | **arbitrary split; two near-duplicate cards** |
| 54:24 | 53:53 (`let`) | ok |
| 1:00:52 | 1:00:33 (boolean expressions) | ok |
| 1:05:31 | 1:05:21 (logical vs bitwise teaser) | ok |
| 1:15:33 | 1:15:33 (CompCert) | ok, but this card then swallows 9.5 min of unrelated Q&A |
| missing | 42:10 (instruction scheduling), 66:45 (mini quiz 2), 77:00 (viva/exam format), 81:33 (debug builds), 83:23 (ILOC vs LLVM) | never get a card |

Where the boundary exists it is usually within 10 s of the truth, which is excellent. The problems are omissions and the two ends of the lecture.

### Card-by-card grading

| # | Card | Grade | Notes |
|---|---|---|---|
| 1 | 0:07–4:37 Recap: Node convergence and phi functions | B | Summary correct for 0:07–1:00 only. Repeats the ASR slip: "path from V to B prime" (the lecturer said B to B'). The 3.5 min of silent quiz are not mentioned. |
| 2 | 8:11–16:04 AST to 3-address code conversion | B− | Correct but the summary is cut off mid-sentence: "…and binary operations are handled…". Omits "virtual registers are unlimited". |
| 3 | 16:04–22:40 Implementing genExpr | A− | "For constant nodes … loadI; for variable nodes, it uses a symbol table to find the base and offset for a loadAO". Specific, right. Omits the new_reg_name counter and "no single correct IR". |
| 4 | 22:40–25:54 Recursive expression generation | A | Exact boundary, exact content. |
| 5 | 25:54–30:52 Compiler Build APIs | C | **Factual slip**: "These APIs automatically handle register allocation and SSA form". The lecturer said the API creates a new register because the IR is always SSA; register allocation is a different phase. No slides linked. |
| 6 | 30:52–34:56 AST-based code generation | D | Title and summary describe the *slide* ("postorder traversal … assigning virtual registers to operators"). The word "postorder" is never spoken (grep of the reference: 0 hits). Misses the actual content: left-associativity, the `4+a+2` example, the offset-0 observation. Slide link 11 is wrong (S18–S20). |
| 7 | 34:56–37:46 Code generation optimization | A− | "Optimizations are typically performed in separate passes after IR generation to maintain a simple, bug-free source of truth." Right, specific. Slide link 16 is wrong: S20 literally says "Optimizations usually happen after…". |
| 8 | 37:46–44:20 Handling other operations | D | "Code generation follows a postorder traversal, loading operands into registers before emitting the operation." Says nothing about `*`, `-`, `/`, division by zero, precedence-in-the-front-end or **instruction scheduling**, the most substantive idea in the window. Slide link 11 is wrong (S21–S23). |
| 9 | 44:20–48:14 Mixed type expressions | A | "…uses a conversion table to determine the result type. Both operands are then converted to this common type…" |
| 10 | 48:14–54:24 Code generation with type conversion | D | Sentence one is the same as card 9: "the compiler uses a conversion table to determine the target type." The real second half (x+4.0 needs a convert op, fadd vs add, where semantic analysis lives) is absent. Duplicate card. |
| 11 | 54:24–1:00:52 Let expressions | A | "…binds an expression's result to a name by allocating memory via an alloc instruction, evaluating the expression, and storing the result. Symbol table hierarchies handle variable shadowing." |
| 12 | 1:00:52–1:05:31 Numerical representation of booleans | A− | Correct (zero false, non-zero true). |
| 13 | 1:05:31–1:15:33 Logical vs Bitwise Operations | F | **Hallucinated conclusion.** "Logical operators … differ from bitwise operators because they may require short-circuiting, which affects code generation and optimization." The lecturer explicitly withheld the answer ("I'll be shortly giving the answer, maybe not this class, but in the next class", 66:15). "Short circuit" appears only in the post-class student chat (73:42, and the sidecar shows diarization tagged it `(L)`) and on slide S33, which was never presented. 10 minutes span 1 min of teaching, 5 min of silent quiz, 4 min of chatter. |
| 14 | 1:15:33–1:24:59 Compiler Correctness and Verification | D | Only the CompCert minute (75:33–77:00) is summarised. The other 8 minutes hold the exam format, MP1 viva, CFG/dominator exam advice, debug builds and ILOC vs LLVM. The user-facing card silently omits all of it. |

Grade summary: 6 good (3, 4, 7, 9, 11, 12), 3 acceptable (1, 2, 5 with an error), 4 poor (6, 8, 10, 14), 1 harmful (13).

Hallucination/vagueness flags: card 13 (unsupported claim asserted as lecture fact), card 5 ("register allocation"), cards 6/8 (describing slide vocabulary, not what was said), card 10 (duplicate), card 2 (truncated with "…").

## 2. Slide trajectory

The harness emitted: `9:56=13, 17:47=14, 21:16=15, 26:05=16, 35:02=17, 37:40=21, 45:13=24, 54:39=26, 58:43=27, 1:00:32=28, 1:01:10=29, 1:02:55=30`; no backtrack suggestions (correct: none were warranted).

True onsets are inferred from what the lecturer says (no slide log exists), so treat lags below a minute as noise.

| Slide | True onset | Tracker | Lag | |
|---|---|---|---|---|
| S13 attack strategy | ~8:41 | 9:56 | +1:15 | ok |
| S14 genExpr | 16:55 | 17:47 | +0:52 | ok |
| S15 new_reg_name | ~18:30 | 21:16 | +2:46 | late |
| S16 base/offset | ~19:45 | 26:05 | +6:20 | late |
| S17 PLUS case | ~22:40 | 35:02 | +12 min | badly late |
| S18–S20 `4+a+2` and optimizations | 29:06–35:00 | never emitted | | missed |
| S21 other operations | 37:15 | 37:40 | +0:25 | ok |
| S22, S23 (x+4*y) | 38:38, 41:56 | never emitted | | missed |
| S24 mixed types | 44:31 | 45:13 | +0:42 | ok |
| S25 let | 53:53 | (26 at 54:39) | | S25 skipped |
| S28 shadowing | 59:42 | 1:00:32 | +0:50 | ok |
| S29 booleans | 60:33 | 1:01:10 | +0:37 | ok |
| S30 numerical booleans | 62:26 | 1:02:55 | +0:29 | ok |

It never overshot into S31–S34 (which the lecture never reached), which is the important safety property. The S14–S20 stretch (seven near-identical listings) is a build group, and the tracker cannot resolve it: it was up to 12 minutes behind, and by 35:00 it was 3 slides behind. Outside that stretch lag is 25–75 s. Card slide links inherit the problem (cards 6, 7, 8 link S11/S16/S11).

## 3. Quizzes (8 questions, 16 attempts)

Formats alternated MCQ / short answer (4 each; the harness forces this so both paths get tested). The wrong short answers were written by the model (a "plausible student misconception"); the right ones were the question's own reference answer. One harness bug: `target takeaway` for Q1 printed `[0:07–4:37]`; the true target was card 14 (fixed in the harness by waiting for the final takeaway update; the raw report keeps the old line).

**Grading verdicts: 16/16 as intended** (8 wrong answers graded wrong, 8 right answers graded right). No false accepts. Caveat: the "correct" short answers were verbatim reference text, so this does not test leniency for paraphrases or partial answers, and the wrong answers were flat contradictions, not near-misses. See problem 10.

| Q | Type | Answerable from what was taught? | Options / single-correct | Feedback quality |
|---|---|---|---|---|
| 1 Compiler correct when… (card 14) | MCQ | Yes (75:48) but it is a post-class aside | **Ambiguous.** Correct: "simulating language-level semantics is equivalent to simulating generated code". Distractor C: "the compiler is guaranteed to be bug-free and contains no errors". The lecturer said CompCert *is* "guaranteed to be bug-free", and the wrong-answer feedback itself concedes "a verified compiler like CompCert is guaranteed to be bug-free [T1:16:14]". A student who picks C was taught it. | Cites T1:15:48 and T1:16:14, both real and on-topic. |
| 2 Short-circuit AND (card 13) | short | **No.** Taught nowhere in the lecture; reference cites `[S33]`, a slide that was never shown; the lecturer deferred it to next class. | n/a | Feedback correct but cites S33. Question exists only because card 13 hallucinated the topic. |
| 3 Why must Expr not contain x in `let` | MCQ | Yes (58:35 "otherwise it's circular") | One correct ("prevent circularity"); distractors "shadowing", "type safety" plausible; "memory leaks" weak | Correct explanation, cites T58:37 and T1:00:01 (both support). |
| 4 Mixed-type procedure | short | Yes | n/a | Wrong answer ("cast the final result to the type of the first operand") rejected; explanation cites S24 and T46:59, both fine. |
| 5 Goal of instruction scheduling | MCQ | Yes, but it is a 2-minute aside, and card 8 does not mention it | One correct ("maximize utilization of pipeline units"). Distractors C ("ensure postorder traversal order") and D ("convert AST to 3-address code") are **not plausible**; only A is a real trap. | "some hazards may be unavoidable" is an added claim the lecturer did not make (he said "as long as there are no data hazards"). Cites T44:09 which supports the main point. |
| 6 Order of emission in tree walk | short | Slide-only fact (S11); the lecturer never says "postorder" | n/a | Right; the claim "Preorder traversal would process the operator before its children [S11]" is not on S11 (harmless). |
| 7 Build API destination operand | MCQ | Yes (27:07–27:17) | **Ambiguous.** Correct: "a new register is automatically created". Distractor D: "The programmer must manually assign source and destination operands". The lecturer said with the API you *do* "give the source operands, destination operands, and the opcode". D is arguably true. Distractors B, C are true statements about the no-API case, so the question depends on reading "destination operand" narrowly. | Explanation matches the transcript (T27:06, T27:37 cited and on-point). Calls the mechanism "SSA form" (right); card 5 calls it "register allocation" (wrong). |
| 8 What the ID case retrieves from the symbol table | short | Yes (20:00–20:40) | n/a | Right, cites S14 and T20:02, both support. The reference answer text itself contains `[S14, T20:02]` markers. |

Wrong-answer explanations: right in 8/8 on the central idea, cited in 8/8, citations point at supporting text in 7/8 (Q2's is a slide never shown; Q6's second clause is unsupported). Correct-answer feedback for short answers was always the bare "The answer is correct." (no citation, no reinforcement).

Timed quiz pings during the feed (not graded, 8 of them): all well formed; but the [1:16:05] ping asks about short-circuiting (rooted in card 13's hallucination), [22:46] and [40:24] both ask "in what order are the children processed", and [31:29] repeats what became Q7. The planner only avoids repeats within a takeaway; nothing dedups the same concept across neighbouring cards.

## 4. Ask

| Q | Latency (first token) | Correct? | Citations |
|---|---|---|---|
| A1 Why does genExpr create a new virtual register each time? | 17.7 s (12.1) | Mostly. "Simplicity … avoid tracking which values are live", "infinite supply", both right. Third bullet ("Separation of Concerns: … typically handled in later passes") is an extrapolation; it misses the SSA reason (27:14). | `T27:47, T27:49` are the same passage (padding); `T9:46, T18:45` support "infinite registers". All resolve to real text. |
| A2 `let` vs assignment, why allocate memory? | 11.1 s (4.9) | Yes: "not an assignment … names the result", "assume everything is in memory", "arrays cannot be stored in registers". | 7 cites, all real and on point (54:36, 54:59, 56:14, 57:05, 57:48); a few redundant. |
| A3 How is `x + 4 * 2.3e0` handled when x is an int? | 8.7 s (4.3) | **Generic.** Restates the conversion-table procedure with the slide's formula and never says the concrete outcome (x promoted to floating point, 4 promoted, multiply and add in float; OCaml would demand `float_of_int`). | Only `S24`, and no transcript cite even though 44:31–53:51 discusses it. |
| A4 What did the professor say about the exam format? | 4.1 s (2.4) | **Yes**: "written questions where you will need to draw things or write a few sentences … not multiple choice". Matches 81:01–81:33 in the reference. | `T1:21:19` and `T1:21:24` are the same passage and it supports the claim exactly. The retrieval found what no card recorded. |
| A5 (not covered) register allocation with graph coloring | 6.3 s (4.7) | **Good handling**: "This wasn't covered in the lecture so far … do not discuss graph coloring for register allocation." | Attaches `S10, S11` to a negative claim, implying support that isn't there. Ignores its own instruction to give a brief general answer labelled as background, and says "so far" for a lecture that ended. It also misses that the lecturer did mention unlimited virtual registers as the reason allocation isn't a concern at this stage. |

Overall Ask is the strongest feature: no invented facts, every timestamp resolves to text on the topic, the negative case is handled. Weaknesses are shallow answers to applied questions (A3), duplicated citations, decorative citations on refusals. Ask found the exam-format answer that the cards missed.

## 5. Recaps

| Window | Latency | Accuracy |
|---|---|---|
| 0:00–8:00 | 14.7 s | Headline "Corrected phi function placement and conducted a mini quiz." Correct. Bullets: phi rule; diamond needs no phi (7:04). Flagged "Corrected slides will be posted on the website" (correct, 0:59) and "Mini quiz was administered". Missed the second correction (Z, 7:31). Better than the card. |
| 42:00–54:00 | 14.7 s | Instruction scheduling, conversion tables, fadd vs add, semantic analysis on AST or IR: all correct. **`slides: 21,22,…,33` is wrong**: the lecture had not passed S25 by 54:00; this is 13 slides listed, apparently the model echoing the digest. |
| 1:02:00–1:15:00 | 12.8 s | Boolean numeric representation right; "logical operators … can follow the same patterns as arithmetic" right (66:32); flagged "The upcoming mini quiz is very close in difficulty to the midterm" is right (67:09) though the quiz was happening then, not "upcoming". Missed the logical-vs-bitwise teaser and that the answer is deferred. Slides "30" correct. |

## 6. Performance

**Memory** (`physFootprint`, sampled per 60 s of session time, full table in the raw report). Model load at ~3:00 jumps the footprint from 0.15 GB to 16.8 GB. Steady state oscillates 15.7–18.3 GB (± ~1.5 GB, follows individual generations). Peak 18.3 GB (54% of 34 GB).

| Window | min | mean | max (MB) |
|---|---|---|---|
| 0–10 | 15697 | 15857 | 16549 |
| 10–20 | 16811 | 17708 | 18245 |
| 20–30 | 16561 | 17092 | 18204 |
| 30–40 | 16657 | 17110 | 17814 |
| 40–50 | 16661 | 17689 | 18171 |
| 50–60 | 16670 | 17372 | 18125 |
| 60–70 | 16780 | 17240 | 18078 |
| 70–80 | 16723 | 17161 | 18254 |
| 80–85 | 16845 | 17106 | 18027 |

No leak: linear fit +2.4 MB/min (~ +0.2 GB across 85 min), the floor creeps 16.56 → 16.66 → 16.72 → 16.85 GB per 20-minute window (+0.3 GB in an hour), the ceiling is flat ~18.2 GB. Footprint fell to 15.77 GB after the quizzes (a cache flush when prompt families changed) and rose again to 16.7 GB after recaps. Nothing to fix, but a periodic MLX cache clear would trim the 1.5 GB peaks.

**Latency** (measured at the provider boundary; includes the MLX scheduler's queue wait and any GPU sharing with other processes, which the harness cannot separate).

| | n | p50 | p90 | max |
|---|---|---|---|---|
| Rolling summaries in the feed | 36 | 11.7 s | 44.9 s | 86.5 s |
| … excluding the 5 warm-up calls | 31 | 12.4 s | 44.9 s | 86.5 s |
| … not overlapped by a timed quiz call | 28 | 10.1 s | | 48.5 s |
| … overlapped by a timed quiz call | 8 | **32.5 s** | | 86.5 s |
| Timed quiz generation in the feed | 8 | 32.6 s | | 75.7 s |
| Quiz generation at the end (idle GPU) | 8 | MCQ 9.1–12.1 s, short 5.3–9.4 s; the first one 55 s (cold) | | |
| Quiz grading, right answer | 8 | 1.0–1.5 s | | |
| Quiz grading, wrong answer | 8 | MCQ 2.0–3.7 s, short 10.2–15.9 s | | |
| Ask (5) | 5 | 8.6 s | 17.6 s | 17.6 s (first token 2.4–12.0 s) |
| Recap (3) | 3 | 14.7 s | | 14.7 s |
| Final `finish()` pass | 1 | 23.1 s | | |

Everything ~10 s for ~5k tokens in and ~100 tokens out when alone. The first call of the run cost 35 s (model load; the harness does not call `OnDeviceStack.warmUp`, the app does).

**Did the brain keep up at 4×?** Yes in aggregate, no instantaneously. The feed ended on schedule (1277 s vs 1275 s nominal) and the last card settled 67 s after the last word. But card coverage lagged the live edge by mean 3:34 of lecture time, p90 7:21, max **11:22** (at 16:00 session time, one 86 s summary stuck behind a 76 s timed quiz) and a second 6–8 minute band at 52–59 min (a 53 s quiz then a 53 s summary). At 4× those are 1–3 wall minutes; at 1× the same calls would put cards ~90 s behind, tolerable. Contention rule of thumb from the data: **a summary that overlaps a timed quiz call takes 3.2× as long** (32.5 s vs 10.1 s median). One additional oddity: between 47:00 and 48:09 the feed released no segments for ~55 s of wall time before call 26 even started, so this points at the speech engine or machine load rather than the brain; it caught up afterwards.

## 7. Top problems, in priority order

1. **Whole stretches of the lecture never reach a card, and the app's own prompt says so on purpose.** Two forms: (a) the opening recap card is closed at 4:37 by the 240 s backstop and the later `.opened` at 8:11 cannot add a card for 4:37–8:11 because `addOpeningRecap` bails when any settled card exists (`Brain/LectureBrain+Takeaways.swift`, guard `timeline.takeaways.filter({ !$0.isLive }).isEmpty`); (b) the last 13 minutes (exam format, viva, debug builds, ILOC vs LLVM) were classified `admin_or_chat`, which extends the live card and discards the content (`Takeaways/TopicTimeline.swift`, admin branch of `apply`; rule in `Prompts.summariesInstructions`: "Admin and chit-chat (homework, exams, quizzes, logistics …) never become a topic"). Fixes: on `.opened`, if the last settled card is a `Recap:` card whose `end` is before the new card's `start`, extend its `end` (or run `addOpeningRecap` on the residual range when it is longer than ~60 s); for admin lines, do not extend the live card's `end` and instead collect them (using `LectureBrain.announcementPattern` in `Brain/LectureBrain+Recap.swift`) into an "Announcements" card/list; a student asking about exam format is the main reason to open the app after class. Let the model open a card for technical Q&A after the class-ending line.

2. **Content from slides that were never shown leaks into cards and quizzes** (card 13 "short-circuiting", Q2 citing S33, the [1:16:05] ping). `DeckDigest.render` puts all 34 slides in the byte-stable system prompt, so the model treats the whole deck as taught. Fixes: add a per-call tail line in `Prompts.segmentation`, `Prompts.quizQuestion`, `Prompts.ask` like `SLIDES NOT YET SHOWN: S31–S34 (do not present their content as taught)` computed from `slideHistory`; in `LectureBrain+Quiz.makeQuizQuestion` drop reply slides above `max(slideHistory.page)+2` and reject questions whose reference cites them in `checkQuestion`; in `SlideSupport.supported` (`Context/SlideSupport.swift`) restrict `fallback` and matches to slides at or before the tracker's high-water mark.

3. **Post-class chatter is treated as lecturer speech.** Diarization labelled 737 of 820 segments `L`, including the students' conversation from 71:34 ("it's always short circuit"). Without a "class ended" signal the summarizer folded chat into card 13. Fix in the brain: detect the closing line (`(?i)(end|wrap up) (the )?class|that's (all|it) for today`) in `ingest`, store `classEndedAt`, and pass "the lecturer ended class at m:ss; later lines are conversation, only technical Q&A directed at the lecturer counts" in the segmentation tail; stop timed quizzes after it (`scheduleQuizIfDue`). Also treat an obvious speaker-mix (`?`/`A` runs) as a hint in `TranscriptText.render`.

4. **Cards paraphrase slide vocabulary instead of what was said** (cards 6, 8, 13: "postorder traversal … assigning virtual registers to operators"), and one card is a duplicate (10 vs 9). Fixes: in `Prompts.summariesInstructions` add "Every summary must contain at least one fact that was said in the transcript, not only on the slide; if the lecturer gave an example, name it (e.g. `4 + a + 2`)"; add a settle-time pass in `TopicTimeline` that merges adjacent settled cards when `similarity(summary) >= 0.5` (today `isNearDuplicate` only runs against the live card at the moment of a split: `duplicateTitleSimilarity`, `similarTitleSimilarity`, `restatedSummaryContainment`) or, when it splits, forces `closed_summary` and `summary` to differ; make `Prompts.splitPressure` mention "a sub-example (worked example, student question) is not a new topic".

5. **Summaries are truncated with an ellipsis** (card 2: "…binary operations are handled…"): `TopicTimeline.maxSummaryChars = 220` and `Text.clampSentences` falls back to `truncate` when the model overshoots by one clause. Fix: on overshoot, re-ask once ("shorten to 220 characters") through `StructuredGeneration`'s repair turn, or drop the last clause instead of appending "…". `TopicTimeline.check` already rejects summaries over 300, so the 220–300 band is where this happens.

6. **Slide links on cards and the tracker fail inside build groups.** Cards 6, 7, 8 got S11/S16/S11, where the phrase in card 7 is verbatim on S20. `SlideSupport.supported` ranks by BM25 across the whole deck with `minShareOfBest = 0.5`, then prefers `cited`; the model's `slides` list came from the digest. Prefer, in order, `slidesShown(from: card.start, to: card.end)` intersected with support, then BM25. For the tracker (`LecternSlides/SlideIndex.swift`), inside a build group use only new lexical evidence unique to the later page (e.g. `4 + a + 2`, "Optimizations usually happen") and advance when a unique term of the *next* page is spoken; today it lagged up to 12 min there. `Recap.slides` (problem 7) has the same disease.

7. **Recap slide numbers are hallucinated** (`21,22,…,33` for a window ending at slide 24). `Brain/LectureBrain+Recap.swift` does `excerpts.sanitize(reply.slides)`, which accepts any valid page. Fix: use `slidesShown(from:to:)` (already implemented on the brain) and only add reply slides within ±1 of that set; and reword the prompt to "slides shown during this stretch are listed under SLIDES SHOWN" and supply them.

8. **Timed quizzes and rolling summaries fight over one GPU** and the priority is inverted. `GenerationScheduler.priority(of:)` (`LecternMLX/Host/GenerationScheduler.swift`) puts quizzes above summaries, so a background ping jumps the queue and delays takeaways (overlapped summaries median 32.5 s vs 10.1 s alone; coverage lag up to 11 min at 4×). Fix: user-initiated question writing keeps priority 2; `runTimedQuiz` (`Brain/LectureBrain+Quiz.swift`) should use a lower priority than summaries, or `scheduleQuizIfDue` should defer while `summaryTask != nil` or `sessionTime - lastTakeawayEnd > 2 min`. Also the timer fires 8 times in 85 min with two repeats of "traversal order"; pass all earlier prompts of neighbouring cards as `avoid`.

9. **MCQ distractor quality.** Q1 (option C is what the lecturer said), Q7 (option D arguably true) are ambiguous; Q5's two distractors are unrelated to the question. Fix in `Prompts.quizQuestion` MCQ block: "Each distractor must be false according to the material, and must not be a statement the lecturer made. Two distractors should be common misconceptions of this specific idea, not other topics from the lecture." Add a cheap verification step (`LectureBrain+Quiz.makeQuestion`): re-ask the model to answer the question blindly and reject if it selects a different option than `correct_answer`, or if it says two options are correct.

10. **Grading has only been shown to reject blatant wrong answers.** All 8 short-answer "right" attempts were verbatim references, and correct short answers get the uninformative "The answer is correct." Next tests should use paraphrases, partially correct answers, and near-miss wrongs ("preorder" vs "postorder" was the only one). In `Prompts.shortAnswerGrading` ask for one sentence that names the key idea and cites it when correct. For a MCQ `Prompts.multipleChoiceFeedback`, the added "some hazards may be unavoidable" shows the model adding unsupported detail; add "Do not add facts that are not in the material".

11. **Ask polish.** Deduplicate citations that point at the same transcript window (`CitationNormalizer`/`validCitations`: merge times within ~10 s); for the "not covered" branch, suppress citations and follow the prompt's own instruction (brief general answer labelled as background, drop "so far" once the lecture has ended). For applied questions like A3, `LectureBrain.askContext` should always retrieve transcript excerpts, not only slides (`TokenBudget.askTranscript` budget is split between recent 90 s and BM25 windows; the recent 90 s at the end of a lecture is wasted on chatter).

## 8. Harness follow-ups

- Call `OnDeviceStack.shared.warmUp` before the feed so the 35 s first-call model load and JSON-grammar compilation are excluded, as they are in the app.
- Record MLX queue wait separately from generation time (`GenerationScheduler.queueDepth`) so contention with other processes can be told apart.
- Add paraphrase and near-miss short-answer attempts (problem 10) and a ground-truth slide log to the test data.
- The Q1 "target takeaway" print bug is fixed in `PipelineSelfTest.swift` (waits for the final takeaways update before choosing candidates). The `DD-eval` binary that produced the report predates this fix; after the other agent's LecternSlides breakage cleared, `Scripts/build.sh DD-eval Release` succeeded again and `LecternHarness` was re-linked, but the fixed harness has not been re-run end to end.
