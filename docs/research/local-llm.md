# Local LLM for Lectern: research and recommendation

*Researched 2026-09-29. Target machine: MacBook Pro M2 Max, 30-core GPU, 32 GB unified memory, macOS 27.0 (checked on this Mac). gpt-oss is excluded, as the user asked.*

---

## TL;DR

| Role | Model | MLX repo (mlx-community) | Disk | Why |
|---|---|---|---|---|
| **Primary** | **Gemma 4 26B-A4B-it, QAT 4-bit** (MoE, 25.2B total / 3.8B active) | `mlx-community/gemma-4-26B-A4B-it-qat-4bit` (plain PTQ: `gemma-4-26b-a4b-it-4bit`) | 15.6 GB (15.4 plain) | Lowest measured grounded-summary hallucination of any candidate (Vectara 5.2%). Best instruction-following in its class (IFBench 77.3, NVIDIA-run). About 64–70 tok/s decode and about 600 tok/s prefill measured on M2 Max. Peak memory 14.3–16.5 GB from 1k to 32k context. Thinking is off by default in the HF template. Supported in mlx-swift-lm. |
| **Reasoning upgrade** (if RAM allows) | Qwen3.6-35B-A3B, 4-bit (MoE, 35B / 3B active, Gated-DeltaNet hybrid) | `mlx-community/Qwen3.6-35B-A3B-4bit` (or `-4bit-DWQ`) | 20.4 GB (20.7 DWQ) | Stronger knowledge and reasoning (MMLU-Pro 85.2, GPQA 86.0, HLE 21.4 vs 8.7) and a better AA-Omniscience score (−22 vs −51). But peak memory is **19.3–20 GB**, which is at the edge of the budget, and it hallucinates about 2× more on Vectara (Qwen3.5-35B-A3B: 10.5%). |
| **Lighter alternate** | Qwen3.5-9B, 4-bit (dense 9B, GDN hybrid) | `mlx-community/Qwen3.5-9B-MLX-4bit` | 6.0 GB | Strongest model under 10B on paper (MMLU-Pro 82.5, GPQA 81.7, IFEval 91.5, AA-LCR 63). About 6 GB. **Lighter, not faster:** a dense 9B decodes slower than the 3.8B-active MoE. |
| **Same-family light option** | Gemma 4 12B-it 4-bit | `mlx-community/gemma-4-12B-it-4bit` | 6.8 GB | Same prompt format as the primary. Already installed in Ollama (`gemma4:12b`). Measured slow on this Mac (see §4). |
| **Zero-download fallback** | Apple Foundation Models (on-device, macOS 27) | built-in | 0 | 8,192-token context on macOS 27, so it only fits trimmed prompts. Private Cloud Compute (32K context, reasoning, free under 2M downloads) is a better zero-download fallback when online. |
| **Not for live use** | Qwen3.8-27B (dense, best open model ≤32B) | `mlx-community/Qwen3.8-27B-4bit` (+ `-MTP-4bit` drafter) | 16.1 GB | Top quality (AA v4.3.2 = 34 xhigh / 20 non-reasoning). On M2 Max it runs **~14–18 tok/s and ~100–120 tok/s prefill**, so a 5k-token prompt takes 40–50 s cold. Only for post-lecture jobs. |

**Architecture takeaway.** On M2 Max, **prefill speed, not decode speed, decides whether the app feels live.** Keep every prompt append-only: a stable system prompt and slide text first, then the transcript so far, then the per-call instruction last. Reuse the KV/prompt cache between calls. A 5.5k-token prompt that took 32 s cold took **0.1 s** warm in the Ollama test on this Mac.

---

## 1. What has actually shipped (as of Sept 2026)

Checked against primary sources: HF org listings, model cards, config.json files.

| Family | Released open-weight models relevant to 32 GB | Notes |
|---|---|---|
| **Qwen** | 3.5 (Feb–Mar 2026): 397B-A17B, 122B-A10B, 35B-A3B, 27B, 9B, 4B, 2B, 0.8B. **3.6** (Apr 2026): 35B-A3B, 27B. **3.8** (Aug 2026): 27B dense, 2.4T-A95B. 3.7 was API-only. | All 3.5/3.6/3.8 models are Gated-DeltaNet + gated-attention hybrids (3:1). `model_type` is `qwen3_5` / `qwen3_5_moe`. **There is no Qwen3.8-35B-A3B yet.** It is only a ms-swift commit and community requests. `Qwen3.8-Flash-Next` (Aug 24) is 180B total (`qwen4_exp`), too big. |
| **Gemma** | **Gemma 4** (Mar 31 2026): E2B, E4B, 26B-A4B MoE, 31B dense. 12B "Unified" (Jun 3 2026). Apache 2.0. | 256K context (128K on E-series). Native system role. Thinking toggle. QAT checkpoints available. |
| **Mistral** | Ministral 3 (3B/8B/14B, Dec 2025). Mistral Small 4 (119B-A6B). Medium 3.5 (128B). | Ministral 3 has poor Vectara scores (14B: 19.4%, 8B: 21.7%). Small 4 is too big. |
| **Llama** | Nothing new since Llama 4 Scout/Maverick (Apr 2025, 109B/400B). | No small Llama 4. |
| **Phi** | No Phi-5. Phi-4 / Phi-4-mini remain. | Phi-4 (14B, 16K context) is dated. |
| **DeepSeek** | V4 / V4.1 Flash (284B-A13B), V4 Pro (1.6T). | No official small distills this generation. Community distills exist (e.g. `mlx-community/DeepSeek-V4-Pro-Qwen3.5-9B-4bit`). |
| **GLM (Z.ai)** | GLM-4.7-Flash (30B-A3B). GLM-5.x. GLM-5.3-Flash (Aug 2026) is **321B**. | 4.7-Flash: MLX 4-bit 16.9 GB, Vectara 9.3%, AA (old scale) 30 vs Gemma 26B's 31. |
| **IBM Granite** | Granite 4.2 (Aug 25 2026): 30B dense, 8B, 3B, with official MLX builds from `ibm-granite`. | 30B dense: MMLU-Pro 77.6, GPQA 66.4, IFBench 77.2. Dense 30B is too slow on M2 Max. Granite 4.0-h-small: Vectara 5.2%. |
| **Liquid (LFM)** | LFM2.5 (1.2B, 2.6B, 8B-A1B, VL). | Very fast, too weak for grading CS answers. |
| **SmolLM** | SmolLM3-3B (2025). | Too small. |
| **Kimi / Moonshot** | K2.5–K3, Kimi-Linear-48B-A3B (Oct 2025). | No small current models. Kimi-Linear 48B at 4-bit would be about 27 GB, over budget. |
| **NVIDIA Nemotron** | Nemotron 3 Nano 30B-A3B. **Nemotron 3.5 Lightning 30B-A3B** (Aug 11 2026, Mamba-2/MoE/attention hybrid, 1M context). | Lightning scores below both leaders on NVIDIA's own table (MMLU-Pro 81.9, GPQA 75.4, IFBench 71.9). MLX 4-bit is 17.8 GB. Nemotron 3 Nano: Vectara 9.6%. |
| **Apple** | Foundation Models framework, OS 27: rebuilt on-device model with vision, 8,192-token context. PCC model with 32K context and reasoning. New `LanguageModel` protocol lets MLX models back a `LanguageModelSession`. | See §6. |

**Why MoE with small active parameters.** Decode on Apple Silicon is limited by memory bandwidth: each token reads the active weights once. At about 400 GB/s, a 3–4B-active MoE at 4-bit decodes at 55–80 tok/s. Dense 27–31B models get 13–18 tok/s. Prefill is limited by compute and also scales with active parameters. That is why the ranking is dominated by Gemma 4 26B-A4B and Qwen3.6-35B-A3B.

---

## 2. mlx-swift-lm support (verified against `ml-explore/mlx-swift-lm` main, 2026-09-28)

I checked the `LLMModelFactory.swift` type registry and `Libraries/MLXLLM/Models/` directly. Latest release: 3.31.4 (2026-06-30). Main was last updated 2026-09-28 ("pick up mlx-swift 0.32.2").

| Candidate | HF `model_type` | Registered in Swift? | Extras in Swift |
|---|---|---|---|
| Gemma 4 26B-A4B / 31B / E-series | `gemma4` (text: `gemma4_text`) | **Yes** (`Gemma4.swift`, `Gemma4Text.swift`) | Gemma 4 assistant (MTP-style) drafter: `Libraries/MLXVLM/Gemma4AssistantRegistration.swift`, `gemma4_assistant`. Fused logit softcap (Sept 2026 fixes). |
| Gemma 4 12B Unified | `gemma4_unified` | **Yes** | — |
| Qwen3.5 / 3.6 / 3.8 dense (9B, 27B) | `qwen3_5` (text: `qwen3_5_text`) | **Yes** (`Qwen35.swift`), GatedDelta kernel in `MLXLMCommon/GatedDelta.swift` | MTP speculative decoding (`Qwen35MTP.swift`, `Qwen35TextMTPRegistration`, `MTPSpeculativeTokenIterator`). Fused GDN projections (#572, Aug 2026). |
| Qwen3.6-35B-A3B | `qwen3_5_moe` | **Yes** (`Qwen35MoE.swift`) | MTP drafter registered for `qwen3_5_moe` |
| Qwen3-Next 80B | `qwen3_next` | Yes | (too big) |
| Nemotron 3.5 Lightning | `nemotron_h` | Yes | — |
| GLM-4.7-Flash | `glm4_moe_lite` | Yes | — |
| LFM2.5-8B-A1B | `lfm2_moe` | Yes | — |
| Granite 4.2 | `granite` | Yes | — |
| Ministral 3 | `mistral3` | Yes | — |

**The concern about hybrid linear-attention support in Swift is resolved.** Qwen3.5/3.6/3.8 (Gated DeltaNet) and Nemotron-H (Mamba-2) are both implemented in Swift, not just in Python mlx-lm. Recent commits show active work: "Let training differentiate the gated-delta recurrence", "Fuse Qwen GDN input projections", "Allow downstream specialization of the Qwen3.5 GDN/MoE blocks".

Other Swift features that matter for Lectern:
- **`MLXGuidedGeneration`**: grammar-constrained decoding (JSON Schema / EBNF via XGrammar) for any MLX model, macOS 14+. With the `MLXFoundationModels` bridge, a `@Generable` type passed to `LanguageModelSession.respond(generating:)` is automatically constrained. This removes most JSON-reliability risk for workload 1.
- **`MLXFoundationModels`**: an `MLXLanguageModel` that conforms to Apple's OS 27 `FoundationModels.LanguageModel`. Apple's on-device model, PCC, an MLX model, and Anthropic's `AnthropicLanguageModel` Swift package can then all sit behind one `LanguageModelSession` API. Requires the macOS 27 SDK; this Mac is on macOS 27.0.
- `PromptCacheReusePolicy` / `KVCacheTree`: prefix-cache reuse across turns. It handles recurrent/rotating caches by rebuilding when a trim is impossible, which is another reason to keep prompts append-only.
- `ThinkingBudget.swift`, `ReasoningConfig`, and a `Qwen35ToolCallParser` / `GemmaFunctionParser` are included.

**Memory ceiling on this Mac.** `MTLDevice.recommendedMaxWorkingSetSize` is **26.8 GB** (queried on this machine), so Metal's limit is not the constraint. The real limits are total RAM and memory pressure from Parakeet, the browser, and Xcode. `memory_pressure` showed 25% free during testing, with Xcode compiling.

---

## 3. Ranked shortlist: comparison table

Benchmarks come from vendor model cards unless marked otherwise. "Thinking" means reasoning-mode scores. Most vendor tables are reasoning-on, so expect non-thinking scores to be lower.

| # | Model | Params (total / active) | Quant → disk | Peak RAM measured (ctx) | Context | Key benchmarks | Hallucination | Apple Silicon speed (measured) | Swift | Repo IDs |
|---|---|---|---|---|---|---|---|---|---|---|
| **1** | **Gemma 4 26B-A4B-it** | 25.2B / 3.8B (128 experts, 8 active, 30 layers, 1024-token sliding window + global layers) | QAT 4-bit → 15.6 GB. 4-bit → 15.4. 5-bit → 18.5. 6-bit → 21.7. 8-bit → 28.0 | 14.3 GB (1k), 14.9 (4k), 15.6 (16k), 16.5 (32k) on M2 Max | 256K | MMLU-Pro 82.6. GPQA-D 82.3. LCB v6 77.1. AIME26 88.3. IFBench 77.25 (NVIDIA-run). HLE 8.7. AA Index v4.3.2 ≈17 (est.). AA-LCR 66% | **Vectara 5.2%** (94.8% factual consistency). AA-Omniscience −51 (guesses when it doesn't know) | **M2 Max 38c/64GB, oMLX 0.3.8, 4-bit:** PP 547/618/627/612 tok/s, TG 70.4/66.0/62.0/56.0 at 1k/4k/8k/16k. **M2 Max 32GB (MTPLX, UD-4bit):** AR 63.8–65.4 tok/s; with Gemma assistant drafter 70–80 tok/s (+10–22%, 80–90% acceptance) | Yes (`gemma4`) | `mlx-community/gemma-4-26B-A4B-it-qat-4bit` · `mlx-community/gemma-4-26b-a4b-it-4bit` · drafter `mlx-community/gemma-4-26B-A4B-it-qat-assistant-4bit` (0.27 GB) · Ollama `gemma4:26b-mlx`, `gemma4:26b-a4b-it-qat` |
| **2** | **Qwen3.6-35B-A3B** | 35B / 3B (256 experts, 8 routed + 1 shared, 40 layers: 30 GDN + 10 gated-attention) | 4-bit → 20.4 GB. 4-bit DWQ → 20.7. 5-bit → 24.8. 6-bit → 29.1. OptiQ-4bit-REAP-19B (expert-pruned) → 12.4 | 19.3 GB (1k), 20.0 (4k) on a 32 GB M2 Pro. 21.9 (4k) on a 64 GB M1 Max | 262K (1M YaRN) | MMLU-Pro 85.2. GPQA 86.0. SuperGPQA 64.7. LCB v6 80.4. HLE 21.4. AIME26 92.7. IFBench 63.7 (NVIDIA-run). AA v4.3.2 = 18. AA-LCR 72% | Qwen3.5-35B-A3B on Vectara: 10.5% (3.6 not yet listed). **AA-Omniscience −22** (better calibrated on closed-book facts) | **M1 Max 32c, oMLX, mlx-community 4-bit:** PP 440 / TG 42.0 (4k); PP 314 / TG 39.1 (16k). **M2 Pro 16c 32GB:** PP 336 / TG 54.6 (4k). **M3 Max 40c (6-bit):** PP 1,393 / TG 71.1 (4k). M2 Max 38c 32GB community row: PP ≈588 / TG ≈82 (1k; search-snippet only, page not opened) | Yes (`qwen3_5_moe`) + MTP | `mlx-community/Qwen3.6-35B-A3B-4bit` · `-4bit-DWQ` · MTP drafter `mlx-community/Qwen3.6-35B-A3B-MTP-4bit` (0.49 GB) · Ollama `qwen3.6:35b-a3b` |
| **3** | **Qwen3.5-9B** | 9B dense (GDN hybrid) | 4-bit → 6.0 GB. 8-bit → 10.5 | ~7 GB est. | 262K | MMLU-Pro 82.5. GPQA 81.7. IFEval 91.5. IFBench 64.5. AA-LCR 63.0. LongBench v2 55.2. LCB v6 65.6 (thinking) | Qwen3.5 family on Vectara: 10.5–12.1% | No reliable M2 Max row found. Third-party guides report 25–35 tok/s on Macs. Bandwidth math suggests about 40 tok/s max on M2 Max. **Measure before relying on it.** | Yes (`qwen3_5`) + MTP | `mlx-community/Qwen3.5-9B-MLX-4bit` · `mlx-community/Qwen3.5-9B-8bit` |
| 4 | Gemma 4 12B-it (Unified) | 11.95B dense | 4-bit → 6.8 GB. 8-bit → 12.8 (QAT-4bit repo is 11.0 GB, avoid) | 8.1 GB in Ollama (Q4_K_M, 8k ctx) | 256K | MMLU-Pro 77.2. GPQA 78.8. LCB 72.0. AIME26 77.5 | n/a (Gemma 3 12B: 4.4%) | **Measured on this Mac (M2 Max 30c 32GB, Ollama 0.34.4 GGUF Q4_K_M, Xcode build running):** cold prefill 5,526 tok in 32.5 s = **170 tok/s**; decode **16 tok/s**; warm (cached prefix) prefill 0.1 s | Yes (`gemma4_unified`) | `mlx-community/gemma-4-12B-it-4bit` · Ollama `gemma4:12b` (installed), `gemma4:12b-mlx` |
| 5 | Qwen3.8-27B | 27.8B dense (64 layers, 3:1 GDN:attention) | 4-bit → 16.1 GB. oQ6 → 23.3. 8-bit → 29.5 | ~17 GB | 262K (1M) | GPQA 89.2. IFBench 79.5. LCB v6 90.3. AA v4.3.2: 34 (xhigh), 20 (non-reasoning) | Qwen3.5-27B on Vectara: 12.1% | **M2 Max 38c 32GB (oQ4e + MTP):** PP 104 / TG 13.7. **M2 Max 38c 64GB (6-bit + MTP):** PP 119 / TG 17.7. Qwen3.6-27B 6-bit on M2 Max: PP 114 / TG 14.5 (4k) | Yes + MTP | `mlx-community/Qwen3.8-27B-4bit` · `mlx-community/Qwen3.8-27B-MTP-4bit` · Ollama `qwen3.8:27b-mlx` |
| (tiny) | Gemma 4 E4B-it | 4.5B effective (8B with embeddings) | 4-bit → 5.2 GB | — | 128K | MMLU-Pro 69.4. GPQA 58.6 | AA-Omniscience −20 | M2 Max 30c 32GB (oMLX): PP 1,255 / TG 31.0 (4k) | Yes | `mlx-community/gemma-4-e4b-it-4bit` |

### Reading the evidence

- **Workloads 1, 2 and 4 are grounded summarisation and RAG.** The best proxy is Vectara's summarisation-faithfulness leaderboard (updated 2026-09-22). Gemma 4 26B-A4B scores **5.2%**, better than every Qwen3.5 model (10.5–12.1%), GLM-4.7-Flash (9.3%), Nemotron 3 Nano (9.6%), Claude Haiku 4.5 (9.8%) and Ministral 3 (19–22%).
- **Workload 3 (grading CS answers) rewards reasoning.** Qwen3.6-35B-A3B is clearly ahead on HLE (21.4 vs 8.7) and a few points ahead on GPQA and MMLU-Pro. Its AA-Omniscience score (−22 vs −51) means it bluffs less on closed-book facts. Mitigation for Gemma: generate the answer key and rubric with the question, grounded in the transcript, so grading becomes comparison rather than recall. This removes most of Gemma's closed-book disadvantage.
- **Instruction following.** On NVIDIA's independent table, IFBench is Gemma 26B 77.3 vs Qwen3.6-35B 63.7. This supports Gemma for strict formatting, although constrained decoding makes JSON validity model-independent anyway.
- **Token efficiency when thinking.** AA found Gemma 4 uses about 2.5× fewer reasoning tokens than Qwen3.5-27B, and flags Qwen3.6/3.8 as "very verbose" (Qwen3.6-35B-A3B: 160M output tokens for the index). On-device, verbosity is latency: a 3,000-token think at 60 tok/s is 50 s.
- **Memory.** Gemma leaves about 4–5 GB of headroom inside the 18–20 GB budget, even at 32k context. Qwen3.6-35B-A3B at 4-bit is 19.3–20 GB peak before any transcript growth, so on a 32 GB machine with STT and a browser it risks swapping. The REAP-19B pruned variant (12.4 GB) fixes the memory issue, but it is a community expert-pruning with no independent quality evaluation. Treat it as experimental.
- **Benchmark caveats.** Vendor tables use thinking mode. Qwen's own table shows Gemma 26B at 17.4 on SWE-bench Verified vs Google's much higher agentic numbers, which suggests harness differences, and agentic coding doesn't matter for Lectern. AA Intelligence Index values changed scale between versions: April 2026 values of 31/37 became 17/18 on v4.3.2. Compare only within one version.

---

## 4. Speed and latency on this Mac (M2 Max, 30-core GPU)

- The measured M2 Max rows above are from 38-core GPUs. **Your GPU has 30 cores**, with the same 400 GB/s bandwidth. Expect decode to be nearly unchanged (bandwidth-bound) and **prefill about 15–20% lower** (compute-bound).
- **Expected for Gemma 4 26B-A4B (4-bit, MLX):** decode ≈ 55–65 tok/s at 4–8k context. Prefill ≈ 480–550 tok/s, so a cold 5k-token prompt takes about 9–10 s to the first token. With append-only prefix reuse, a 3-minute transcript delta (~600 tokens at ~150 wpm) plus a ~150-token instruction takes **≈1.3–1.6 s to first token**, which meets the "within a couple of seconds" goal.
- **Local measurement** (`gemma4:12b`, Ollama 0.34.4, llama.cpp backend, Q4_K_M, 5,526-token lecture prompt, JSON-schema `format`, `think:false`, while Xcode was compiling):
  - cold: 32.5 s prefill (170 tok/s), 16 tok/s decode
  - warm, identical prefix: 0.10 s prefill
  - Both runs returned valid, sensible JSON (`"decision":"continue"`, correct title, slides 12–14).
  - The decode speed was far below theory. Causes are likely the dense 12B architecture, GGUF rather than MLX, and heavy concurrent CPU/GPU load. **Takeaway:** on this Mac the 26B-A4B MoE should be *faster* than the 12B dense model, as well as smarter.
- Speculative decoding helps a little. The Gemma 4 assistant drafter gave +10–22% on M2 Max. Qwen MTP gives about 2.5–2.8 tokens per cycle on prose. Both drafters are supported in mlx-swift-lm. They are worth enabling for workloads 2 and 4 (long outputs) and not worth it for 150-token JSON.
- Speed degrades with context. Gemma 26B decodes at 46.5 tok/s at 32k and 34.5 at 64k. A full 75-minute lecture is about 15k transcript tokens plus about 5–15k slide tokens, so it stays in the fast zone. Retrieve relevant slides instead of sending the whole deck.

---

## 5. Quantization, thinking modes, and settings

### Quantization
- **Gemma 4 26B-A4B:** use **QAT 4-bit** (`gemma-4-26B-A4B-it-qat-4bit`). Google trained it for int4, so it loses less quality than post-training 4-bit at the same size. The mlx-community 4-bit repos already keep the dense MLP and router at 8-bit (mixed precision, seen in config.json). 5-bit (18.5 GB) is borderline for the budget, and 6-bit/8-bit do not fit alongside STT and a browser.
- **Qwen3.6-35B-A3B:** 4-bit or 4-bit DWQ (distilled weight quantization, about 0.3 GB larger and usually closer to bf16). Nothing larger fits.
- **Dense 9–12B fallbacks:** 4-bit is fine. 8-bit (10–13 GB) is affordable if you want maximum fidelity from a small model.
- Avoid the "abliterated", "heretic", "uncensored" and merged fine-tunes that dominate mlx-community listings. Their quality is unevaluated and alignment is removed.

### Thinking toggles and chat-template gotchas
- **Gemma 4:** thinking turns on when `<|think|>` begins the system prompt. The HF/MLX chat template reads `enable_thinking` and **defaults to false** (`enable_thinking | default(false)`). Reasoning comes out as `<|channel>thought … <channel|>`. **Strip prior thoughts from history** before the next user turn. Gemma 4 supports a real `system` role (Gemma 3 did not).
  - **Ollama gotcha:** `ollama show gemma4:12b` reports thinking **default: true**. Always send `"think": false` for the frequent calls.
- **Qwen3.6 / 3.5:** thinking is **on by default**. Pass `enable_thinking=false` (mlx-swift-lm additional template context; `chat_template_kwargs` for mlx_lm.server / LM Studio / vLLM-style servers; `think:false` in Ollama).
  - `preserve_thinking` retains past reasoning. Leave it off for Lectern.
  - Qwen3.8 adds `reasoning_effort` low/medium/xhigh. Qwen3.6 is on/off only, so use mlx-swift-lm's `ThinkingBudget` to cap thinking.
  - Vendor non-thinking sampling uses **presence_penalty 1.5**. That penalises repeated tokens, which can distort JSON keys and repeated technical terms (FIRST/FOLLOW). I recommend presence_penalty 0 for JSON and grading calls; this is my judgment, not a vendor setting.
- **JSON:** don't rely on prompt-only JSON. Use:
  - `MLXGuidedGeneration` / `@Generable` in-process
  - Ollama's `format: <JSON schema>` (verified working here)
  - LM Studio structured output / `response_format` on OpenAI-compatible servers (check mlx_lm.server's current support before relying on it)

  Use enums (`continue` | `new_topic`) and integer arrays for slide pages. Post-validate that every slide number exists in the deck. With thinking on, constrain only the final answer (think freely first, then run a constrained JSON pass) so the grammar doesn't block the reasoning channel.
- **Prompt layout for cache reuse:**
  - `[system + JSON contract] → [slide text for the current section] → [transcript so far, append-only] → [short task instruction + current-topic state]`
  - Never put timestamps or other changing fields before the transcript.
  - Start a fresh cache per topic segment rather than sliding a window: GDN, Mamba and sliding-window caches cannot be trimmed.

### Recommended per-task settings

These are for the primary model, Gemma 4 26B-A4B. Google's defaults are temperature 1.0, top_p 0.95, top_k 64; lower temperatures are my recommendation for determinism.

| Task | Thinking | Temp / top_p / top_k | Max new tokens | Notes |
|---|---|---|---|---|
| 1. Topic segmentation + 2-line summary (every 2–4 min) | **Off** | 0.3 / 0.95 / 64 | 256 | Guided JSON (schema with enum and integer array). Include the previous topic's title and summary in the instruction. Summary capped at 2 sentences in the schema description. |
| 2. Expanded section summary (on click) | Off | 0.6 / 0.95 / 64 | 600 | Stream it. Optional assistant-drafter speculative decoding. |
| 3a. Quiz generation | Off | 0.8 / 0.95 / 64 | 400 | Generate question, options, **answer key, rubric and source slide/timestamp** together (guided JSON). Keeps grading grounded. |
| 3b. Grading + explanation | **On** (low) | 1.0 / 0.95 / 64 (Google's thinking default) | ~1,500 thinking + 300 answer | Compare against the stored key. Emit a verdict via a second constrained pass or strict schema. If wrong, generate a *different* follow-up question and exclude prior question IDs in the prompt. |
| 4. Chat Q&A with citations | Off (user toggle "think harder" → On) | 0.5 / 0.95 / 64 | 800 | Ask for `[S14]`-style citations, then validate them against the retrieved slide set. Say "not covered in this lecture" when retrieval is empty. |

If Qwen3.6-35B-A3B is used instead:
- non-thinking: 0.7 / 0.8 / 20 (presence 0 for JSON)
- thinking: 1.0 / 0.95 / 20, and hard-cap thinking at about 2k tokens, because it is verbose

---

## 6. Apple Foundation Models (zero-download fallback)

- **On-device model (macOS 27):** rebuilt from scratch per WWDC26 ("better at logic and tool calling"), now with vision. A Gemini distillation has been reported but not confirmed by Apple.
  - `SystemLanguageModel().contextSize` returns **8192** on macOS 27 (4096 on 26.x). A 3–8k-token lecture prompt plus output barely fits.
  - Use it only with aggressive retrieval and trimming (e.g. last ~3k transcript tokens plus top-3 slides) for workloads 1 and 3a, or as the fallback when no model is downloaded.
  - Guided generation (`@Generable`) is native and reliable. Apple publishes no benchmarks comparable to the table above, so use Apple's new Evaluations framework to test it on Lectern's prompts.
- **Private Cloud Compute model (OS 27):** 32K context, reasoning levels (`ContextOptions(reasoningLevel:)`), no API key. **Free for developers with fewer than 2 million first-time downloads.** It is private (no prompt retention) but needs a network connection. It is a strong zero-download "cloud-ish" tier between local MLX and paid APIs.
- **Unifying abstraction:** on OS 27 the `LanguageModel` protocol lets Lectern use a single `LanguageModelSession` code path across:
  - `SystemLanguageModel`
  - `PrivateCloudComputeLanguageModel`
  - `MLXLanguageModel` (from mlx-swift-lm `MLXFoundationModels`)
  - `AnthropicLanguageModel` (Anthropic's Swift package)
  - a custom executor for an OpenAI-compatible server

  `DynamicProfile` can switch model or reasoning level per task, for example on-device for segmentation and PCC or MLX with thinking for grading.

---

## 7. Server fallback (OpenAI-compatible)

- **Ollama 0.34.4 (installed):** has MLX-engine tags for all candidates:
  - `gemma4:26b-mlx`, `gemma4:26b-a4b-it-qat`
  - `qwen3.6:35b-a3b`, `qwen3.6:35b-a3b-mtp-q4_K_M`
  - `qwen3.8:27b-mlx`, `gemma4:12b-mlx`

  Gotchas:
  - pass `think:false`
  - set `num_ctx` explicitly (e.g. 16384), because the default is small and silently truncates
  - `format` takes a JSON schema
  - keep-alive (`keep_alive`) matters, since a cold load of `gemma4:12b` took 7.2 s
- **LM Studio (MLX engine)** and **`mlx_lm.server`** also serve these models. Pass `chat_template_kwargs: {enable_thinking: false}` for Qwen.
- **oMLX** (community MLX server) is where most of the M-series benchmarks above come from. It supports MTP and prefix caching.
- In-process MLX Swift is still preferable: no second process, one memory pool, direct KV-cache control, and guided generation via XGrammar.

---

## 8. Cheap API models (optional API mode)

Prices are per 1M tokens, standard tier, checked 2026-09-29. **Cost per lecture** assumes 100k input + 10k output tokens with no caching; the second figure assumes 70% of input is cache hits, which the append-only layout makes realistic. Reasoning tokens bill as output.

| Provider / model | Input | Cached input | Output | $/lecture (no cache) | $/lecture (70% cached) | Notes |
|---|---|---|---|---|---|---|
| OpenAI **gpt-6-luna** (released 2026-09-22) | $0.10 | $0.01 | $0.50 | **$0.015** | ≈$0.009 | Cheapest current-gen model. 1.1M context. Reasoning effort none → max. Use `none`/`low` for segmentation. |
| OpenAI gpt-5.6-luna | $0.20 | $0.02 | $1.20 | $0.032 | ≈$0.019 | Previous gen. |
| OpenAI gpt-5.4-nano | $0.20 | $0.02 | $1.25 | $0.033 | ≈$0.020 | Vectara 3.1%, the best measured faithfulness among these. |
| OpenAI gpt-5.4-mini | $0.75 | $0.075 | $4.50 | $0.12 | ≈$0.07 | Vectara 5.5%. |
| OpenAI gpt-6-sol | $2.00 | $0.20 | $10.00 | $0.30 | ≈$0.17 | Mid-tier. |
| Anthropic **Claude Haiku 4.5** (`claude-haiku-4-5`) | $1.00 | $0.10 read ($1.25 5-min write) | $5.00 | **$0.15** | ≈$0.095 | 200K context. Cheapest Claude. Vectara 9.8%. |
| Anthropic **Claude Sonnet 5.5** (`claude-sonnet-5-5`) | $2.00 | $0.20 read ($2.50 5-min write) | $10.00 | $0.30 | ≈$0.19 | 1M context. Thinking can't be fully disabled; use `thinking: {type: "between_tools"}` or low effort for the frequent calls. The newer tokenizer produces ~1.0–1.35× more tokens for the same text. |

Batch APIs halve prices but are asynchronous, so they're unusable for live calls. An end-of-lecture study-guide job could use them.

Recommendation for API mode:
- **gpt-6-luna** (or gpt-5.4-nano for maximum faithfulness) for workloads 1, 2 and 4, at about 1–3¢ per lecture
- **Claude Haiku 4.5 or Sonnet 5.5** for quiz grading if higher quality is wanted, still well under $0.30 per lecture

---

## 9. Final recommendation

1. **Ship Gemma 4 26B-A4B-it QAT 4-bit via mlx-swift-lm as the default local model** (`mlx-community/gemma-4-26B-A4B-it-qat-4bit`, 15.6 GB download, about 15–16.5 GB resident).
   - Thinking off for workloads 1, 2, 3a and 4, with guided JSON.
   - Low thinking for grading (3b).
   - Append-only prompts with prefix-cache reuse.
2. **Offer Qwen3.6-35B-A3B 4-bit/DWQ as a "Max reasoning" option** only when free RAM is at least 22 GB before load. Better for grading tricky CS answers; about 2× worse measured grounded-summary faithfulness and tighter memory.
3. **Lighter alternate: Qwen3.5-9B 4-bit (6 GB)** for machines or sessions under memory pressure. Gemma 4 12B is the same-family alternative and is already installed in Ollama, but measured slow here.
4. **Zero-download:** Apple's on-device model (8K context; trimmed prompts only). Better, when online: Apple PCC (32K, free under 2M downloads). Wrap everything behind the OS 27 `LanguageModel` protocol.
5. **Before committing, validate on this machine:** measure TTFT and tok/s for Gemma 26B-A4B with a real lecture transcript, cold and warm, with Parakeet running. Also measure JSON validity and slide-citation accuracy over about 50 transcript windows. Nothing in §3 was measured on a 30-core M2 Max except the gemma4:12b Ollama run.

---

## Sources

**Model cards and releases**
- Qwen3.6-35B-A3B model card: https://huggingface.co/Qwen/Qwen3.6-35B-A3B
- Qwen3.8-27B model card: https://huggingface.co/Qwen/Qwen3.8-27B
- Qwen3.5-9B model card: https://huggingface.co/Qwen/Qwen3.5-9B
- Qwen GitHub (release timeline, MLX support): https://github.com/QwenLM/Qwen3.8
- Qwen3.6-35B-A3B blog: https://qwen.ai/blog?id=qwen3.6-35b-a3b
- Qwen3.8-35B-A3B status (unreleased): https://huggingface.co/Qwen/Qwen3.8-27B/discussions/120 , https://kie.ai/blog/what-is-qwen3-8-35b
- Qwen 3.5–3.8 overview: https://codersera.com/blog/qwen-3-5-complete-guide-2026/
- Gemma 4 model card: https://ai.google.dev/gemma/docs/core/model_card_4
- Gemma 4 announcement: https://blog.google/innovation-and-ai/technology/developers-tools/gemma-4/
- NVIDIA Nemotron 3.5 Lightning 30B-A3B card (includes Qwen3.6/Gemma 4 comparison): https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-BF16
- IBM Granite 4.2 30B card: https://huggingface.co/ibm-granite/granite-4.2-30b
- Mistral models overview: https://docs.mistral.ai/models/overview
- HF org listings checked: meta-llama, microsoft, ibm-granite, mistralai, LiquidAI, moonshotai, HuggingFaceTB, zai-org, deepseek-ai, nvidia, google, Qwen (https://huggingface.co/api/models?author=...)

**MLX / Swift**
- mlx-swift-lm (model registry, MLXGuidedGeneration, MLXFoundationModels, MTP): https://github.com/ml-explore/mlx-swift-lm
- LLMModelFactory registry: https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLLM/LLMModelFactory.swift
- mlx-community repos (sizes computed from the HF tree API): https://huggingface.co/mlx-community

**Benchmarks and measurements**
- Artificial Analysis: Gemma 4 article: https://artificialanalysis.ai/articles/gemma-4-everything-you-need-to-know
- AA: Sub-32B open weights (Apr 2026): https://artificialanalysis.ai/articles/sub-32b-open-weights
- AA: Qwen3.6 35B A3B vs Gemma 4 26B A4B: https://artificialanalysis.ai/models/comparisons/qwen3-6-35b-a3b-vs-gemma-4-26b-a4b
- AA: Qwen3.6 35B A3B: https://artificialanalysis.ai/models/qwen3-6-35b-a3b
- AA: Qwen3.8 27B (non-reasoning / xhigh): https://artificialanalysis.ai/models/qwen3-8-27b-non-reasoning , https://artificialanalysis.ai/models/qwen3-8-27b
- Simon Willison on Qwen 3.8 27B AA score: https://simonwillison.net/2026/Aug/17/qwen-38-27b-scores-52/
- Vectara hallucination leaderboard (updated 2026-09-22): https://github.com/vectara/hallucination-leaderboard
- oMLX: Gemma 4 26B-A4B on M2 Max 38c: https://omlx.ai/benchmarks/fm5r831j
- oMLX: Qwen3.6-35B-A3B on M1 Max 32c: https://omlx.ai/benchmarks/performance/ep9vz4x0
- oMLX: Qwen3.6-35B-A3B on M2 Pro 16c 32GB: https://omlx.ai/benchmarks/358ctcgf
- oMLX: Qwen3.6-35B-A3B 6-bit on M3 Max 40c: https://omlx.ai/benchmarks/performance/mid144b2
- oMLX: Qwen3.6-27B 6-bit on M2 Max 38c: https://omlx.ai/benchmarks/96514jl9
- oMLX: Qwen3.8-27B oQ6e-mtp on M2 Max: https://omlx.ai/benchmarks/performance/7475t4dk
- oMLX: Qwen3.8-27B oQ4e-mtp on M2 Max 32GB: https://omlx.ai/benchmarks/performance/4np065my
- MTPLX issue #527 (Gemma 4 26B-A4B on M2 Max 32GB, with and without drafter): https://github.com/youssofal/MTPLX/issues/527
- Qwen3.8-27B oMLX MTP recipe (M4 Max): https://github.com/Weschera/Qwen3.8-27B-oMLX-MTP-Mac
- Silicon Score, Qwen3.6-35B-A3B: https://siliconscore.com/models/qwen3-6-35b-a3b/
- Local measurement: Ollama 0.34.4, `gemma4:12b` Q4_K_M, this Mac (M2 Max 30c, 32 GB, macOS 27.0), 2026-09-29

**Apple**
- WWDC26: What's new in the Foundation Models framework: https://developer.apple.com/videos/play/wwdc2026/241/
- WWDC26: Bring an LLM provider to the Foundation Models framework: https://developer.apple.com/videos/play/wwdc2026/339/
- macOS 27 foundation model notes: https://rits.shanghai.nyu.edu/ai/apple-foundation-models-macos-27/

**Servers**
- Ollama library tags: https://ollama.com/library/gemma4/tags , https://ollama.com/library/qwen3.6/tags , https://ollama.com/library/qwen3.8/tags
- LM Studio Gemma 4: https://lmstudio.ai/models/gemma-4

**API pricing**
- Anthropic pricing: https://platform.claude.com/docs/en/about-claude/pricing
- OpenAI pricing: https://developers.openai.com/api/docs/pricing
- GPT-6 Luna details: https://llm-stats.com/models/gpt-6-luna , https://www.vellum.ai/blog/gpt-6-sol-and-luna-benchmarks-explained
