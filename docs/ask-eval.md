# Ask evaluation (8 October 2026)

The user found lecture Ask "quite stupid". This round rebuilt Ask's prompt and context, then
measured old and new designs, two on-device models and thinking on/off against a question set
from real lectures. Everything here ran on the user's M2 Max (30-core GPU, 32 GB) in the in-app
harness, Release build, while other agents were also building and testing on the machine.

## Summary

- **The main problem was the design, not Gemma.** With the same model, the new design raises
  the hand-graded score from **5.8 to 8.0 out of 9** (correctness + depth + grounding, 21
  questions). The old design failed in three ways: a prompt that asked for 1–4 sentences with a
  citation after every claim; retrieval that returned the wrong part of the lecture (it found
  nothing for "limitations of AMAT", because the lecturer said "not a perfect technique"); and an
  800-token cap.
- **Thinking (`low`) helps, but it is too slow to be the default.** It scored 8.4 and fixed most
  of what remained (it found the lecturer's NMRU hint for way prediction). But it takes 30–75 s
  to the first word on Gemma, against 2–3 s without thinking.
- **Qwen3.6-35B-A3B is not clearly better.** It scored 7.9 (8.1 once its range-style citations
  are parsed; that fix is now in). It explains a little more deeply and is more often right on
  CS 433, but its citations point at the wrong time more often. It is also about 2× slower to the
  first token (4.6 s against 2.6 s). Per docs/research/local-llm.md it also needs about 4 GB more memory (peak memory was not measured in these runs). Gemma stays the default.
- **New default:** the standard design, Gemma 4 26B-A4B, thinking off, 1,500 output tokens. A
  question during a lecture sees about 2–3 s to the first word and 10–18 s to the full answer,
  provided the background warm-up has run (see Latency).

## What changed in Ask

| | Old (`AskDesign.compact`) | New (`AskDesign.standard`) |
|---|---|---|
| Instructions | "Answer first, in 1–4 sentences", cite right after every claim, general knowledge only when the lecture doesn't cover the question | Teach like a TA: the mechanism, the reason and the trade-off. The lecture is the main source; fill gaps from own knowledge, briefly labelled. Cite once per point, never cite general knowledge. No "Based on…" openers. 80–250 words, show calculations step by step, correct a misspoken number. Keeps "This wasn't covered in the lecture." |
| Transcript | ≤ 1,600 tokens: BM25 windows plus the last 90 s | **The whole transcript so far** (≤ 20,000 tokens, about 80–90 min) in the system prefix, up to the last 5-minute boundary at least 30 s old. Everything after that boundary goes in the question. Past the cap: BM25 windows from the rest, plus the newest 1,600 tokens |
| Topics / slides / history | 400 / 800 (450 chars per slide) / 1,200 | 1,200 / 1,500 (1,200 chars per slide) / 2,000 |
| Output | 800 tokens, temperature 0.5 | 1,500 tokens, temperature 0.4. `reasoning(.low)` adds 1,100 for thinking |
| Cache | System prefix = instructions + deck digest | System prefix = instructions + digest + transcript. It only ever grows, in 5-minute steps. On-device, each step is prefilled in the background (`warmAskPrefixIfNeeded`, background priority, one token) |

Also fixed:
- Citation repair: "[S56:40]" → "[T56:40]", bare times inside a slide list, and ranges such as
  "[T35:03–T36:03]" (cited by their start).
- LaTeX cleanup: long `$…$` spans and nested `\mathbf{… \text{…}}` are now removed.
- Retrieval (both designs): windows already in the prompt are filtered out before the top 5 are
  taken, not after.

Measured prompt size (Gemma tokenizer, CS 433 at 70 min): about 21.8k tokens per question.
That is 19.9k of cached system prefix (2.5k instructions + digest, 17.4k transcript), about 1.9k
of question material, and history. CS 426 at 85 min: 23.3k. The harness's `-dry` mode prints
these sizes for any lecture without a model.

## Question set

- `TestData/cs433-oct8/`: today's CS 433 lecture ("Not Your (Grand)Mother's Cache", 70 min,
  737 segments, 15 takeaways, 28 slides), copied read-only from the library after recording
  ended. `questions.json` has 16 questions: conceptual "why/how" (5), definitions (4), "what did
  he say" recall (3), a comparison, AMAT arithmetic, and VIPT/TLB (not covered). Q1 is the user's
  real way-prediction question, asked at 65:43, with the real previous turn as history. Each
  question has a reference answer and key points written from the transcript.
- `TestData/cs426-questions.json`: 5 questions on the CS 426 IR-generation lecture
  (`cs426-reference.txt` + `lec9-ir-gen.pdf`, no takeaways), including register allocation by
  graph coloring (not covered).
- Grading: by hand, against the key points. Each answer gets 0–3 for **correctness** (any false
  statement costs), **depth** (mechanism and why, all key points), and **grounding** (uses the
  lecture, citations that parse and point at the right place, extra knowledge labelled, honest
  "not covered"). Scores are in `TestData/ask-eval/` (answers) and summarised here.

## Scores (mean per answer, each 0–3; total out of 9)

| # | Configuration | Correct | Depth | Grounding | **Total** | CS 433 (16) | CS 426 (5) |
|---|---|---|---|---|---|---|---|
| 1 | Old prompt + old budgets, Gemma, thinking off (baseline) | 2.29 | 1.24 | 2.24 | **5.76** | 5.69 | 6.00 |
| 2 | New design (first prompt), Gemma, off | 2.71 | 2.76 | 2.48 | **7.95** | 7.94 | 8.00 |
| 3 | New design (first prompt), Gemma, **low** | 2.95 | 2.81 | 2.67 | **8.43** | 8.44 | 8.40 |
| 2b | New design (final prompt), Gemma, off **(shipping)** | 2.76 | 2.67 | 2.52 | **7.95** | 7.88 | 8.20 |
| 4 | New design (final prompt), Qwen3.6-35B-A3B 4-bit, off | 2.81 | 2.95 | 2.14 | **7.90** | 8.00 | 7.60 |

The final prompt (2b) added four rules after run 2: search the whole transcript, "S" is for
slides only, no "Based on…" openers, and illustrative numbers must support the claim. It fixed
Q7 (the 99% vs 97% numbers) and the S-prefixed citations. But it introduced a factual slip on Q4
(non-inclusive caches), so the total stayed level. Run 3 used the first prompt. Runs 2b and 4 ran before the range-citation repair landed; the
build that ships has it. If Qwen's
range citations had been parsed (now fixed), its grounding would be about 2.4 and its total
about 8.1.

Where each configuration lost points:
- **Baseline:** Q6 (AMAT) got wrong arithmetic (4.8, 5.2, 8.1 and 10.1 cycles in one answer). Q8
  said the lecture "does not explicitly discuss limitations of AMAT" (a retrieval miss; it does,
  at 26:01). Q1: see below. Most answers stopped at the slide's wording (depth 1.2), and the
  graph-coloring question got no general answer.
- **New design, Gemma, off:** Q1 still opens with "Based on the lecture…". It still says the
  mechanism "isn't detailed", although the lecturer mentions NMRU at 59:33. One factual slip per
  run (Q4 non-inclusive in 2b; Q7 numbers in 2). Some citations land on a nearby but different
  line.
- **Thinking low:** nearly all correct. Still slightly off timestamps, and Gemma still sometimes
  writes "[T1:1:02:06]".
- **Qwen:** the deepest explanations (Q1 covers prediction, misprediction cost, 85% and 70%).
  But it cites ranges ("[T35:03–T36:03]", now repaired), drops the hour ("[T21:05]" for 1:21:05,
  which points at the wrong place), and cites times that don't support the claim ("[T1:01:14]"
  for tag-array facts said at 55:38). It also made two small factual slips (calling 4 "already a
  double"; a wrong aliasing fix for VIPT).

## Latency (first word / full answer, seconds)

| Configuration | Prompt tokens | TTFT p50 (max) | Total p50 (max) | Output tokens p50 |
|---|---|---|---|---|
| Baseline (re-run on a quieter machine) | 3.8k | 3.8 (8.4) | 8.3 (12.5) | 138 |
| New, Gemma, off (2b) | 21.8k | 2.6 (7.0) | 14.3 (18.9) | 287 |
| New, Gemma, low (3) | 21.8k | 53.8 (236) | 71.4 (410) | 1,301 |
| New, Qwen, off (4) | 21.5k | 4.6 (5.7) | 15.7 (21.4) | 312 |

- These TTFTs assume the transcript prefix is already in the KV cache. The harness's `-warm`
  option prefills it before the first question of each new step, as the app does in the
  background. A **cold** prefill of the whole 70-minute prefix took **46–57 s on Gemma**
  (about 400 tok/s) and **38–44 s on Qwen**.
- Live, the background warm-up normally only adds the newest 5 minutes:
  measured with `-warmsteps 6` on CS 433, consecutive steps from 40:39 to 1:10:39 took 24.5 s
  for the first (cold, 40 min of prefix), then 3.3, 3.5, 3.5, 3.5, 4.0 and 3.9 s each
  (background priority, about every 5 minutes).
- When a full cold prefill still happens:
  - After a question has been answered, the next step's warm-up re-prefills the whole prefix in
    the background. This is because the MLX cache can rewind sliding-window layers only by
    `slidingWindowRewindSlack` (2,048 tokens), and a question plus its answer is longer than
    that.
  - The first question after reopening a lecture in Review is cold, about 45 s for an hour of
    lecture, because nothing warms a lecture that isn't being recorded.

  See "Deliberately left".
- The baseline's first run had outliers (237 s for one answer) while another agent was building
  the app. It was re-run for the table. Its answers did not change materially, and the scores
  use the first run, which matches the shipped retrieval exactly.
- Thinking at `low` spends about 1,000 thinking tokens before the first visible word. At the
  30–45 tok/s Gemma decodes at 22k context on this machine, that is at least 25–35 s, even on an
  idle machine.

## The way-prediction question, side by side

**Question** (asked at 65:43, after "Explain the faster ways to organise/look up caches that he
just spoke about"): *How do you predict the way? Also why is just looking at the tags faster
than the usual way?*

What a good answer contains:
- The predictor keeps a little state per set (the lecturer's suggestion: reuse the NMRU/MRU
  pointer, 59:33), or in general a table indexed by PC/address.
- Read the predicted way's tag + data first. A wrong guess costs a second access.
- The goal is energy, not speed: ~85% accuracy on I-caches, ~70% energy saving.
- Tags are faster because the tag array is far smaller and narrower than the data array (a
  ~30-bit tag vs a 64-byte block per way).
- Phased lookup trades slower hits for faster misses.

**Old design, Gemma** (12 s; 1/0/1):
> Based on the provided lecture materials:
> - **How to predict the way:** The lecture mentions that you can "store some data to predict which way will be accessed" [S13]. However, the specific mechanism for how that prediction is generated (the actual algorithm or logic) was not detailed in the provided context.
> - **Why tag lookup is faster:** A tag lookup is faster than a full lookup because the tag store is a separate structure from the data store [S54:36, S55:04]. Because the tag lookup is a "little bit faster than the data lookup," checking only the tags allows for faster misses [T58:08].

**New design, Gemma, thinking off** (7.0 s to first word, 16.7 s; 2/2/2):
> Based on the lecture and slides, here is the explanation for your questions:
>
> **How do you predict the way?** The lecturer mentions that way prediction involves storing some data to predict which way will be accessed [S13]. While the specific mechanism for generating that prediction isn't detailed in the provided transcript or slides, the lecture notes that it is highly effective in instruction caches because the **locality principle** is very strong there—specifically because of repetitive patterns like loops [T1:00:54]. This allows the system to predict the way with high accuracy (around 85% for instruction caches) [S13].
>
> **Why is looking at just the tags faster?** In a conventional cache, the system performs a tag and data lookup simultaneously [S13]. This means the hardware must power up and search all n ways in a set to find a match [T45:40]. Looking at only the tags is faster for two main reasons:
> - **Reduced Latency on Misses:** If you only check the tags, you don't waste time waiting for the data store to respond if the tag doesn't match. This allows the "miss" signal to be sent to the lower level of the memory hierarchy sooner [S13, T58:36].
> - **Reduced Energy/Complexity:** Searching the data store is "expensive" because you are essentially performing multiple lookups at once [T45:40]. By checking only the tags first, you avoid the energy cost of searching the data in ways that don't contain the requested block [S13].

**New design, Gemma, thinking low** (52 s to first word, 73 s; 3/2/2):
> **How do you predict the way?** Way prediction involves storing metadata to guess which "way" in a set will be accessed [S13]. For example, the lecturer mentions using a policy like **NMRU** (Not Most Recently Used) to keep track of which way was most recently written to, and then using that information to make a prediction [T1:00:30]. This is particularly effective in instruction caches because the strong temporal locality found in loops makes the next instruction's location highly predictable [T1:00:54].
>
> **Why is just looking at the tags faster than the usual way?** In a conventional cache, the tag and data are looked up simultaneously [S13]. In a **phased lookup**, you check only the tags first [S13]. This is faster specifically for **misses** [S13]. In a conventional setup, you waste time and energy searching the data store for a block that isn't actually there [T58:08]. By checking only the tags first, you can identify a miss much earlier, allowing you to start the "miss penalty" (requesting the data from a lower level) sooner [S13, T59:01]. While this might slightly increase the latency of a hit (unless the cache is pipelined), it significantly reduces the time wasted on misses [S13].

**New design, Qwen3.6-35B-A3B, thinking off** (5.7 s to first word, 20.7 s; 3/3/1):
> **Why looking at tags is faster:** In a conventional cache, the tag store and data store are often treated as a single large structure. To check for a hit, you must read the data array simultaneously with the tags to see if they match. Data arrays are physically larger and have more cells to switch on, which increases capacitance and lookup time [T1:01:14]. By separating the **tag store** from the **data store**, you can perform the tag lookup first. Since the tag store is much smaller and narrower, this lookup is faster [T1:01:14]. This separation also allows for **pipelining**, where the cache can start checking the tags for a new request before the previous request has finished reading the data, increasing throughput even if single-request latency doesn't drop significantly [T1:01:14].
>
> **How way prediction works:** Way prediction avoids reading all N ways in a set-associative cache by guessing which way contains the data before the full lookup completes. The cache stores a small predictor (often derived from the **NMRU** replacement policy) that indicates the most recently used way [T1:00:33].
> 1. The system reads the predicted way's tag and data simultaneously [S13].
> 2. If the tag matches, you get the data quickly with low energy [S13].
> 3. If the tag does not match (a misprediction), the system must then read the tags and data for the remaining N-1 ways [S13].
>
> This is highly effective in **instruction caches** because loops exhibit strong temporal locality, leading to prediction accuracies of ~85% [S13]. While it saves ~70% energy on hits, it makes misses slower because you must read all ways sequentially if the prediction fails [S13].

None of them explains the size difference between the tag and data arrays as clearly as the
reference does. Only thinking and Qwen connect way prediction to the NMRU pointer.

## Recommendation: is Gemma the bottleneck?

**Not any more, for most questions.** Going from the old to the new design gained 2.2 points
out of 9. Swapping Gemma for Qwen gained nothing measurable, and turning on thinking gained
0.5. What remains is a cluster of Gemma weaknesses:
- It misses a detail mentioned in passing in a 20k-token context (the NMRU hint).
- It makes one plausible-sounding slip per run.
- It keeps the "Based on…" opener after a previous turn.

Thinking fixes most of these, so the capability is there. It just costs 30–75 s.

Suggested next steps, in order:
1. Ship the new design with Gemma, thinking off (this change).
2. Add an opt-in "Think longer" action on an answer that re-asks with `AskDesign.standard.reasoning(.low)`
   (≈1 minute on-device), for the hard "explain why" questions.
3. If the user wants the best answers live, compare a cloud model for the Ask role. A cloud
   model would also remove the cold-prefill problem.

### How to compare a cloud model (needs the user's API key)

1. In Lectern, open Settings › Models and add an Anthropic API key. Set the **Ask** role to
   Claude Sonnet 5.5 (or Haiku 4.5). Quit Lectern.
2. Run:

   ```
   cd /Users/advaittahilyani/Lectern
   Scripts/build.sh DD-ask Release && M=build/DD-ask/Build/Products/Release/Lectern.app/Contents/MacOS && ln -f $M/Lectern $M/LecternHarness
   $M/LecternHarness -selftest ask -model settings -questions TestData/cs433-oct8/questions.json -session TestData/cs433-oct8/session.json -report TestData/ask-eval/cloud-cs433.md -json TestData/ask-eval/cloud-cs433.json
   $M/LecternHarness -selftest ask -model settings -questions TestData/cs426-questions.json -transcript TestData/cs426-reference.txt -slides TestData/lec9-ir-gen.pdf -report TestData/ask-eval/cloud-cs426.md -json TestData/ask-eval/cloud-cs426.json
   ```

   `-model settings` uses the Ask provider from Settings through the app's normal metering, so
   the calls appear in the app's API cost meter.
3. Expected cost: each question is about 22k input tokens. Most of that is the system prefix,
   which Anthropic caches: one write per lecture, then cache reads. The output is about 400
   tokens. For all 21 questions on Sonnet 5.5 that comes to roughly $0.25–0.40.

   In live use the costs differ. The prefix grows every 5 minutes, so the first question after
   each step pays a fresh cache write (1.25× input price, ~20k tokens, about $0.05 on Sonnet
   5.5). Further questions within the same step are cache hits.

## Reproducing

Use a Release build. Run only when `pgrep -x Lectern` and `pgrep -x LecternHarness` are both
empty, and run one model at a time.

```
cd /Users/advaittahilyani/Lectern
nice -n 15 Scripts/build.sh DD-ask Release
M=build/DD-ask/Build/Products/Release/Lectern.app/Contents/MacOS; ln -f $M/Lectern $M/LecternHarness
Q433="-questions TestData/cs433-oct8/questions.json -session TestData/cs433-oct8/session.json"
Q426="-questions TestData/cs426-questions.json -transcript TestData/cs426-reference.txt -slides TestData/lec9-ir-gen.pdf"
$M/LecternHarness -selftest ask $Q433 -design compact -report /tmp/c1-cs433.md -json /tmp/c1-cs433.json   # baseline
$M/LecternHarness -selftest ask $Q433 -warm -report /tmp/c2-cs433.md -json /tmp/c2-cs433.json             # new, off
$M/LecternHarness -selftest ask $Q433 -warm -reasoning low -report /tmp/c3-cs433.md                      # new, low
$M/LecternHarness -selftest ask $Q433 -warm -model mlx-community/Qwen3.6-35B-A3B-4bit -report /tmp/c4-cs433.md
$M/LecternHarness -selftest ask $Q433 -dry -report /tmp/sizes.md                                          # prompt sizes, no model
$M/LecternHarness -selftest ask $Q433 -warmsteps 6                                                        # background warm-up cost
# … and the same with $Q426.
rm -rf build/DD-ask
```

Results from this round: `TestData/ask-eval/` (`c1`…`c5`, `.md` with answers + timing, `.json`
for grading). Mapping to the table above: run 2b is `c4-…`, Qwen is `c5-…`, and `c1b-…` is the
baseline latency re-run.

## Deliberately left / follow-ups

- **Cold prefix after reopening a lecture, and after each answer.** The brain warms the prefix
  only while a lecture is ingesting. Two fixes would close the gap:
  - A `prepareForQuestions()` on `LectureIntelligence`, which the app would call when the Ask
    panel opens. This is a LecternCore contract change.
  - In LecternMLX, a prompt-cache checkpoint at the end of the system message, or a larger
    `slidingWindowRewindSlack`, so a grown prefix can always be reused incrementally after an
    answer.

  Both are outside this brief.
- **`AskDesign.compact`** (old instructions and budgets, `@_spi(Evaluation)`) stays only so the
  harness can compare designs on one build. Delete it, and the harness's `-design` flag, once the
  comparison is no longer needed. This is a knowing exception to "no dead code".
- **Course-wide Ask** still uses the terse prompt and 800 tokens (`Prompts.courseInstructions`,
  `GenerationProfile.answer`). It would benefit from the same instructions. Its context is
  retrieval across lectures, so the prefix design doesn't carry over directly.
- **The session title is wrong.** The CS 433 session is titled "Class 07 Exploiting Parallelism
  Using Software Techniques", but the deck is Class 15 ("Not Your (Grand)Mother's Cache",
  `class15_new.pdf`). That title goes into every prompt's `Lecture:` line. It should be checked
  wherever titles are suggested.
- The evaluation-only `warmAskPrefix()` always builds the transcript-style prefix. Don't
  combine `-warm` with `-design compact`: it would warm a prefix the compact design never uses.
- Gemma sometimes still writes `$48 - 6 = 42$` (no LaTeX inside, so the cleaner leaves the
  dollar signs) and `[T1:1:02:06]`.
