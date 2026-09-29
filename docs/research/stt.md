# Lectern: On-device live speech-to-text research

Date: 2026-09-29. Target: macOS 26+ app (built with Xcode 27 / Swift 6.4), M2 Max 32 GB, 60-90 min university CS lectures, far-field built-in or USB mic, a ~15-18 GB MLX LLM running on the GPU at the same time.

Everything marked "(verified)" was checked first-hand: FluidAudio source cloned at `main` (commit 20d4f0b, 2026-09-26, tag v0.17.4), and Apple's API read from the Xcode 27 SDK `Speech.swiftinterface` on this machine (macOS 27.0, build 26A428) plus a small experiment. Everything else is from the cited web sources.

---

## 1. TL;DR recommendation

1. **Primary engine: FluidAudio (Swift package, Apache-2.0) running NVIDIA Parakeet Unified 0.6B (English) via `StreamingUnifiedAsrManager`, ANE only.**
   - True chunked streaming with punctuation and capitalization, token/word timestamps, ~1.1 s tier latency, English WER about the best available on-device, runs on the Neural Engine and keeps the GPU free for the LLM.
   - Optional jargon boosting with a small CTC model (`configureVocabularyBoosting`). This is the only on-device engine in this comparison with a working custom-vocabulary path that is also free.
2. **Fallback / second engine: Apple `SpeechAnalyzer` + `SpeechTranscriber`.** Zero download, zero app-memory for the model (it runs outside the app), explicitly designed for long-form and distant audio (lectures, meetings). Weakness: **no custom vocabulary on `SpeechTranscriber`** (verified by experiment below).
3. **Second fallback inside FluidAudio**: `SlidingWindowAsrManager` with `AsrModelVersion.ultra` (Parakeet TDT v3 post-trained, 15 s windows, volatile/confirmed updates, the most battle-tested path). Use if Unified streaming misbehaves on real lecture audio.
4. Put both engines behind one `TranscriptionEngine` protocol from day one and run a one-day bake-off on 3-4 real lecture recordings (Section 9) before locking the default.

### Verdict on the prior "Parakeet is better than Apple SpeechAnalyzer"

**Partly confirmed, but it is not a landslide and it is not the deciding factor.**

- Generic English accuracy: Parakeet is modestly better. Argmax's Earnings-22 run: Apple SpeechAnalyzer 14.0% WER vs Parakeet v2 (Argmax Pro SDK) 11.7% WER (about 16% relative). On a 13k-sample, 5-language, 7-scenario comparison (Dictato), Apple won clean speech in French/German/Italian, WhisperKit won clean English (5.2%), and Parakeet won on disfluent/natural speech in 3 of 5 languages. So there is no clean sweep either way.
- Apple explicitly tunes `SpeechTranscriber` for "long-form and distant audio, such as lectures, meetings, and conversations" (WWDC25 session 277). Parakeet has no such claim and no published far-field evaluation beyond AMI-SDM (10-11% WER for all Parakeet variants; that is a hard meeting dataset, not a lecture hall).
- **Where Parakeet clearly wins for Lectern: jargon.** Apple's `SpeechTranscriber` ignores `AnalysisContext.contextualStrings` (verified below, and matches third-party reports). FluidAudio has CTC-based vocabulary boosting that works in streaming (with limits).
- **Where Apple clearly wins: operational cost.** No 600 MB download, no ANE compile on first run, model is system-managed and auto-updated, no third-party dependency, does not count against the app's memory (important next to an 18 GB LLM).

Net: Parakeet-Unified as default for accuracy + jargon boosting + punctuation/word timestamps; Apple as a robust zero-dependency fallback and as an A/B reference. Confidence in "Parakeet better on Lectern's audio" is moderate until the bake-off is run: no source evaluates either engine on far-field CS lectures.

---

## 2. First-hand experiment: SpeechAnalyzer on jargon and simulated far-field (macOS 27.0)

Caveat up front: one 30 s script read by macOS `say` (voice Samantha), converted to 16 kHz mono; the "far-field" version adds an ffmpeg echo/low-pass/pink-noise chain. This is a smoke test of API behavior, not a WER benchmark. I did not run Parakeet (would require a ~0.6 GB model download; not done without your approval).

Reference text: "...An LL(1) grammar lets the parser choose a production using one token of lookahead. To build the parse table we compute the FIRST set and the FOLLOW set of every nonterminal. If a nonterminal can derive epsilon, that is an epsilon production... left recursion... left factoring... E prime..."

| Configuration | Clean audio | Simulated far-field |
|---|---|---|
| `SpeechTranscriber` | "LL, one, grammar", "look ahead", "the 1st set in the follow set", "non-terminal", mostly right otherwise | "top down parting", "parse table" ok, "E crime", "held out" (for LL(1)), "let factory apply" (left factoring): several errors but still full-sentence output |
| `SpeechTranscriber` + `contextualStrings[.general] = [LL(1), FIRST set, ...]` | **Identical output** (no effect) | **Identical output** (no effect) |
| `DictationTranscriber` (no hints) | "LL one", "top down passing", "the first set", "parts choose" | Drops large portions ("grammar, choose the production token...") |
| `DictationTranscriber` + `contextualStrings` | **"LL(1)", "FIRST set", "FOLLOW set", "nonterminal", "lookahead"** all correct | Partially better ("lookahead", "FIRST set", "FOLLOW set", "left factoring") but still loses words |
| `DictationTranscriber` + `.farField` hint | No visible change | No visible change |

Conclusions: (a) `SpeechTranscriber` is the better acoustic model (esp. far-field) but takes no vocabulary hints; (b) `DictationTranscriber` honors `contextualStrings` but is a worse, older-style model that fell apart on the degraded audio, so it is not a good primary; (c) Apple's ITN rewrote "first set" to "1st set", which would hurt CS terms.

Harness code lived in the session scratchpad (not part of the repo).

---

## 3. Candidate comparison (as of 2026-09-29)

| | Parakeet Unified 0.6B streaming (FluidAudio) | Parakeet TDT v3 / Ultra sliding window (FluidAudio) | Nemotron Speech Streaming 0.6B (FluidAudio) | Apple SpeechTranscriber | WhisperKit large-v3-turbo (Argmax OSS) | whisper.cpp | Moonshine (streaming) |
|---|---|---|---|---|---|---|---|
| Streaming | True chunked-attention streaming, tiers 320/640/1120/2080 ms | Pseudo-streaming, 15 s window (11 s chunk + 2 s + 2 s), volatile+confirmed | True cache-aware streaming, 560/1120/2240 ms | True streaming, volatile + final | Chunked/re-decode (30 s window), latency several seconds | Chunked "stream" example, 30 s window | Yes (designed for live) |
| Compute | ANE (encoder), CPU for tiny decoder/joint. No GPU | ANE | ANE | System service, out of process (Apple's model) | ANE + GPU (CoreML) | GPU (Metal) and/or CoreML encoder | CPU (own runtime), not ANE |
| English WER (offline, HF Open ASR datasets avg of 8) | 5.9% (AMI 10.1, E22 11.2, GS 10.1, LS-c 1.6, LS-o 3.1, SPGI 2.0, TED 3.4, VP 5.8) | v2: 6.05%, v3: 6.34%; Ultra beats v3 (LS-c 2.13 vs 2.27, LS-o 3.81 vs 4.12 in FluidAudio harness) | 6.93% at 1.12 s chunk (AMI 11.7, E22 12.5) | Not on leaderboard. Earnings-22: 14.0% (Argmax); LibriSpeech clean ~2.1% (Inscribe) | Whisper large-v3-turbo about 7.8% avg | similar to Whisper | Not verified |
| Streaming WER (LibriSpeech test-clean) | 2.21% avg, 1.79% aggregate at 2080 ms; 2.25% at 1120 ms (150-file sweep) | n/a (window based) | 2.28-2.46% | n/a | n/a | n/a | n/a |
| Speed | RTFx 33x at 1120 ms tier, 54x at 2080 ms (FluidAudio, M-series Pro/M5 Pro) | RTFx ~110-130x | 42-94x | ~40-70x for files | ~35-110x depending on model | varies | fast |
| Punctuation / caps | Yes (model output) | No (TDT v2/v3 give punctuation per NVIDIA card; FluidAudio comparison table lists none for streaming path) | Yes | Yes (plus ITN, e.g. "1st") | Yes | Yes | Yes |
| Timestamps | Token + word (`consumeWordTimings()`) | Token timings per update | Token timings (`finishWithTokenTimings()`) | `CMTimeRange` per result + `audioTimeRange` per run | Word/segment | Segment | Yes |
| Custom vocabulary | CTC vocabulary boosting (`configureVocabularyBoosting`, ~15 s rescoring segments) | Same + `AsrManager.transcribe(customVocabulary:)` for files | Decode-time hotword bias exists in source for the multilingual variant (`NemotronVocabularyBias`) | **None on SpeechTranscriber**; DictationTranscriber honors `contextualStrings` and custom LM (`SFCustomLanguageModelData`) | Prompt tokens in OSS (weak); real custom vocabulary is in paid Pro SDK | initial prompt only | Not verified |
| Memory | ~565 MB int8 encoder on disk; resident CoreML models roughly this order | ~595 MB (Ultra) | ~600 MB per tier | Not counted against app | 1-1.6 GB | 1-1.6 GB | small |
| License | Apache-2.0 SDK. Model: FluidInference card says CC-BY-4.0; NVIDIA's card says NVIDIA Open Model License. Both allow commercial use; **verify before shipping** | SDK Apache-2.0, TDT CC-BY-4.0 | NVIDIA Open Model License | Apple SDK | MIT | MIT | English models MIT |
| Maintenance | FluidAudio: 6 releases in Sept 2026, v0.17.4 on 2026-09-25 | same package | same package | Apple | argmax-oss-swift v1.1.0 (2026-08-06), active | v1.9.4 (2026-09-11), very active | v0.1.5 (2026-08-24) |
| Min macOS | 14 (SDK), Unified uses standard CoreML | 14 (Ultra), 15 (Redux) | Apple Silicon required | 26 | 14 | any | any |

Notes:
- Open ASR Leaderboard (English avg WER, per NVIDIA cards and MarkTechPost roundup): Granite Speech 4.1 2B 5.33%, Canary-Qwen-2.5B 5.63%, Parakeet TDT v3 6.32-6.34%, Parakeet v2 6.05%. The top two are multi-GB LLM-decoder models that would fight the MLX LLM for the GPU and are not streaming; excluded.
- Far-field evidence is thin for every candidate. The best available public proxy is AMI (meeting room, single distant mic): Unified 10.1-10.14%, v2 11.16%, v3 11.31%, Nemotron 11.73%. Reverberation hurts all models; one study found Whisper reverb penalties of 0.1-1.1 WER points. NVIDIA's v2 card shows steep degradation at low SNR (large drops below about 5 dB SNR). Expect real lecture-hall WER of maybe 10-20% for any engine; the bake-off matters more than leaderboard rank.
- Kyutai STT (delayed-streams-modeling): last commit 2026-01-26, PyTorch/MLX (GPU), would contend with the LLM. Rejected.
- Moonshine: English models MIT, streaming, native Swift, but CPU-only runtime and no verified accuracy numbers vs Parakeet; rejected for now, revisit if ANE engines disappoint.
- WhisperKit / Argmax: the open-source package is now `argmax-oss-swift` (products WhisperKit, SpeakerKit, TTSKit). The Parakeet real-time streaming (160 ms) and custom vocabulary are in the commercial **Argmax Pro SDK** (advertised $0.42/device/month; a free Basic plan exists but I could not confirm what it includes). Not free, so not recommended.
- Whisper-family caveat for 90 min lectures: hallucination on silence/noise and repeated text loops are known failure modes of 30 s chunked decoding; transducer models (Parakeet) do not have this problem in the same way.

---

## 4. Why Parakeet Unified streaming is the pick (and its risks)

Reasons:
- Same checkpoint serves streaming and offline; streaming output "matches offline closely" because the encoder is stateless and re-encodes a `[left | chunk | right]` window each step; only the RNNT decoder LSTM state persists. Source comments state the engine is meant to run for hours, and the transcript is built incrementally (no O(n^2) re-decode), audio buffer is trimmed as it goes.
- Native punctuation and capitalization; word timings; no separate VAD needed.
- Runs the encoder on ANE (`.cpuAndNeuralEngine`; the manager explicitly coerces int8 away from GPU because int8 on GPU/MPSGraph crashes). GPU stays free for MLX. Note ANE and GPU share unified memory bandwidth, so expect a small contention, not zero.
- FluidAudio streaming tiers: `[L,C,R]` in 80 ms frames, latency = (C+R) x 80 ms:
  - 320 ms `(70,2,2)` 2.37% WER, RTFx 10x
  - 640 ms `(70,7,1)` 2.40%, 27x
  - **1120 ms `(70,7,7)` 2.25%, 33x (best streaming WER; recommended)**
  - 2080 ms `(70,13,13)` 2.47%, 54x (default in code)
  - Look-ahead (right context) drives WER; chunk size drives throughput. Live captions for lecture notes do not need sub-second latency; 1.1 s is plenty.
- Cost: at the 1120 ms tier it re-encodes a ~6.7 s window (5.6 s left + 0.56 chunk + 0.56 right) every 0.56 s, i.e. ~12x redundant compute, still 33x faster than real time on the benchmark machine, so roughly 3% ANE duty cycle. On M2 Max expect lower RTFx than the M5 Pro figures but still a large margin.

Risks:
- Newest path in the SDK (NVIDIA model released 2026-04-07; CoreML port and streaming manager more recent than TDT). The docs do not mark it "experimental" (grep found no such label), but its benchmark numbers are from FluidInference's own harness and the LibriSpeech test-clean set only. Treat as unproven on lecture audio until the bake-off. Fall back to `SlidingWindowAsrManager` + `.ultra` (long-tested, ~11 s stable chunks).
- FluidAudio API churn: 6 releases in the last week of measurement window (v0.16.1 to v0.17.4). Pin the version exactly (`exact:` in Package.swift) and upgrade deliberately.
- First-run ANE compile time for int8 encoder is not documented for Unified (Redux docs mention "several minutes" for that model). Measure it, warm up at install/onboarding, and show progress. CoreML caches the compiled plan afterwards.
- English only for Unified. If multilingual lectures ever matter, use `.ultra` (25 European languages) instead.
- Vocabulary boosting in streaming is documented as limited (multi-word terms and cross-chunk terms weaker; prefer single words). See Section 6.4.

---

## 5. Recommended architecture for Lectern

```
AVAudioEngine (built-in/USB mic)
   -> one persistent AVAudioConverter -> 16 kHz mono Float32
   -> TranscriptionEngine protocol
        ├─ ParakeetEngine   (FluidAudio StreamingUnifiedAsrManager, ANE)   [default]
        └─ AppleEngine      (SpeechAnalyzer + SpeechTranscriber)           [fallback / A-B]
   -> segments {text, start, end, isFinal} -> Lectern notes/LLM pipeline
```

Jargon strategy (layered, since no engine is perfect):
1. Engine-level: FluidAudio CTC vocabulary boosting seeded with course terms (syllabus, slide text, textbook index, previous lectures).
2. LLM-level: the local LLM already runs; feed it the glossary and the rolling transcript, and have it normalize term spellings ("epsilon production", "LL(1)", "FIRST/FOLLOW") when it writes notes. This is cheap insurance and works with either engine.
3. Do not post-process with Apple ITN-style output for CS terms; keep raw engine text for the LLM.

Engine-swap tips: both engines yield cumulative text; store segments keyed by time range and treat the last ~1 word (Parakeet) or any non-final result (Apple) as replaceable.

---

## 6. FluidAudio integration details (verified against source at main, commit 20d4f0b)

### 6.1 Package

- Repo: `https://github.com/FluidInference/FluidAudio.git` (Apache-2.0)
- Current release: **v0.17.4** (2026-09-25). Note: the README install snippet still says `from: "0.12.4"` (stale); use a current tag.
- `Package.swift`: tools 6.0 (also `Package@swift-6.2.swift`), platforms `.macOS(.v14)`, `.iOS(.v17)`. Library product **`FluidAudio`** (also executable `fluidaudiocli`).
- Dependencies: none from SPM registry; vendors a binary target `NemoTextProcessing.xcframework` (text-processing-rs v0.3.1, fetched from GitHub releases, ~8 MB per slice) for inverse text normalization. On Swift 6.2+ it can be disabled with `traits: []` (see `Documentation/ASR/PostProcessing.md`).

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4"),
],
targets: [
    .target(name: "Lectern", dependencies: [
        .product(name: "FluidAudio", package: "FluidAudio"),
    ]),
]
```

```swift
import FluidAudio
```

### 6.2 Streaming API: `StreamingUnifiedAsrManager` (public actor)

Key members (verified in `Sources/FluidAudio/ASR/Parakeet/Unified/StreamingUnifiedAsrManager.swift`):

```swift
public actor StreamingUnifiedAsrManager {
    public let config: UnifiedConfig
    public let encoderPrecision: UnifiedEncoderPrecision           // .int8 (default) | .fp16

    public init(configuration: MLModelConfiguration? = nil,
                config: UnifiedConfig = UnifiedConfig(),          // default (70,13,13) = 2080 ms
                encoderPrecision: UnifiedEncoderPrecision = .int8)

    // Model load. Downloads from HuggingFace if missing, then loads.
    public func loadModels(to directory: URL? = nil,
                           configuration: MLModelConfiguration? = nil,
                           progressHandler: ProgressHandler? = nil) async throws
    public func loadModels(from directory: URL) async throws       // offline / bundled

    public func configureVocabularyBoosting(vocabulary: CustomVocabularyContext,
                                            ctcModels: CtcModels,
                                            config: VocabularyRescorer.Config? = nil) async throws

    public func appendAudio(_ buffer: AVAudioPCMBuffer) throws     // any format; resampled to 16k mono internally
    public func processBufferedAudio() async throws                // decodes all complete chunks
    public func getPartialTranscript() -> String                   // cumulative text so far
    public func consumeTokenTimings() -> [TokenTiming]             // drains since last call
    public func consumeWordTimings() -> [WordTiming]               // drains same buffer; use one or the other
    public func setPartialTranscriptCallback(_ cb: @escaping @Sendable (String) -> Void)
    public func finish() async throws -> String                    // flush + final text
    public func reset() async throws                               // new session, models stay loaded
    public func cleanup() async                                    // release models
}

public struct UnifiedConfig: Sendable {
    public init(leftFrames: Int = 70, chunkFrames: Int = 13, rightFrames: Int = 13, ...)
    public var latencyMs: Int   // (chunk + right) * 80 ms
}
public struct WordTiming: Codable, Sendable { word: String; startTime: TimeInterval; endTime: TimeInterval }
public struct TokenTiming: Codable, Sendable { token: String; tokenId: Int; startTime; endTime; confidence: Float }
public typealias ProgressHandler = @Sendable (DownloadProgress) -> Void  // fractionCompleted, phase
```

Latency tier selection: choose `UnifiedConfig(leftFrames: 70, chunkFrames: 7, rightFrames: 7)` for 1120 ms. Each tier is a different encoder bundle downloaded lazily by `contextSuffix` (`70_7_7`). Also available generically: `StreamingModelVariant.parakeetUnified1120ms.createManager()` returns `any StreamingAsrManager` (protocol has `appendAudio`, `processBufferedAudio`, `finish`, `reset`, `cleanup`, `setPartialTranscriptCallback`, `getPartialTranscript`, but not word timings; use the concrete class for timings).

Protocol `StreamingAsrManager: Actor` (in `Streaming/StreamingAsrManager.swift`) is implemented by `StreamingEouAsrManager`, `StreamingNemotronAsrManager`, `StreamingUnifiedAsrManager`. `SlidingWindowAsrManager` deliberately does not conform.

### 6.3 Audio input requirements

- Model input is 16 kHz mono Float32. `appendAudio(_:)` accepts any `AVAudioPCMBuffer` and converts via `AudioConverter.resampleBuffer`, which returns samples directly if the buffer is already 16 kHz / mono / Float32 / non-interleaved; otherwise it converts each buffer statelessly.
- **Recommendation**: do your own conversion with one persistent `AVAudioConverter` in the tap (snippet below) so resampling is continuous across buffers, and pass 16 kHz mono buffers to the manager. Docs also warn never to hand-parse WAV/PCM bytes.
- Buffer size from the tap can be anything; the manager accumulates and only decodes when a full chunk plus right context is available.

### 6.4 Partial vs final; timestamps

- No volatile/final flag on the Unified streaming engine. Text is cumulative and append-only (RNNT greedy decode; tokens are committed once emitted). Latency (1.1 s here) is the right-context look-ahead. Punctuation appears as the model emits it, so commit sentences when you see `. ? !`.
- The last token in a drained timing batch can carry a provisional one-frame `endTime` until the next token arrives. Treat the newest word as unstable in UI.
- Timestamps are seconds on the stream clock (global encoder frame x 0.08 s), starting at the first audio you append; they do not reset until `reset()`.
- With vocabulary boosting enabled the picture changes: audio and timings for the un-rescored tail are retained and rescored in word-aligned ~15 s segments, so `getPartialTranscript()` (and the callback) can **revise earlier text retroactively**. `finish()` always rescores the tail. Treat the string as replaceable, diff it, and do not assume append-only.
- `SlidingWindowAsrManager` (for reference): `transcriptionUpdates: AsyncStream<SlidingWindowTranscriptionUpdate>` where each update has `text`, `isConfirmed` (Bool), `confidence`, `tokenTimings`, `ctcDetectedTerms`/`ctcAppliedTerms`; `volatileTranscript` / `confirmedTranscript` properties; config `SlidingWindowAsrConfig.streaming` = 11 s chunk, 1 s hypothesis chunk, 2 s left and right context, confirmation threshold 0.80. Loads with `loadModels(_ models: AsrModels)` after `AsrModels.downloadAndLoad(version: .ultra)`, then `startStreaming(source:)`, `streamAudio(_:)`, `finish()`.

### 6.5 Model download and caching

- Source: HuggingFace `FluidInference/parakeet-unified-en-0.6b-coreml` (subfolder contents chosen by encoder precision and tier). int8 encoder about 565 MB (fp16 about 1.1 GB); decoder/joint small; total ~0.6 GB for the recommended setup.
- First-run API: `try await asr.loadModels(progressHandler:)` (download + CoreML load + ANE compile). It has completeness checking and purge-and-retry (`ModelHub.loadWithRecovery`) so an interrupted download does not brick the cache.
- Cache location: `~/Library/Application Support/FluidAudio/Models/<repo folder>` (inside the app container if sandboxed). Override with the `to:` parameter.
- Offline / ship-with-app: set `ModelHub.offlineMode = true` once at startup and use `loadModels(from: bundledDirectory)`; missing files throw `DownloadError.modelMissing`. Mirrors: `ModelRegistry.baseURL = "https://..."`, `REGISTRY_URL` env var, or `https_proxy`.
- Vocabulary boosting adds `CtcModels.downloadAndLoad(variant: .ctc110m)` (~98 MB, `FluidInference/parakeet-ctc-110m-coreml`) or `.ctc06b` (larger).

### 6.6 VAD

`VadManager` (Silero, ANE): 4096-sample (256 ms) chunks at 16 kHz.

```swift
let vad = try await VadManager()
var state = await vad.makeStreamState()
let r = try await vad.processStreamingChunk(chunk, state: state, config: .default,
                                            returnSeconds: true, timeResolution: 2)
state = r.state           // r.probability, r.event?.kind == .speechStart / .speechEnd, r.event?.time
```

Optional for Lectern (use to skip silence between slides to save power, or to mark pauses); the Unified/RNNT path does not require it.

### 6.7 Minimal working example (mic to live text)

Typechecked in Swift 6 language mode against a stub module of the signatures above (the real FluidAudio binary was not built here, so API names are transcribed from source, not compiler-confirmed against the real module):

```swift
import AVFoundation
import FluidAudio

private struct SendableBuffer: @unchecked Sendable { let buffer: AVAudioPCMBuffer }

actor ParakeetLive {
    private let engine = AVAudioEngine()
    private let asr = StreamingUnifiedAsrManager(
        config: UnifiedConfig(leftFrames: 70, chunkFrames: 7, rightFrames: 7),  // 1120 ms tier
        encoderPrecision: .int8)
    private var pump: Task<Void, Never>?
    private var cont: AsyncStream<SendableBuffer>.Continuation?

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await asr.loadModels(progressHandler: { progress($0.fractionCompleted) })
    }

    func start(onText: @escaping @Sendable (String, [WordTiming]) -> Void) throws {
        let mic = engine.inputNode.outputFormat(forBus: 0)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                   channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: mic, to: target)!
        let (stream, cont) = AsyncStream<SendableBuffer>.makeStream(bufferingPolicy: .unbounded)
        self.cont = cont

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: mic) { buf, _ in
            let cap = AVAudioFrameCount(Double(buf.frameLength) * 16_000 / mic.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
            var fed = false
            converter.convert(to: out, error: nil) { _, st in
                if fed { st.pointee = .noDataNow; return nil }
                fed = true; st.pointee = .haveData; return buf
            }
            cont.yield(SendableBuffer(buffer: out))
        }
        engine.prepare()
        try engine.start()

        let asr = self.asr
        pump = Task {
            for await item in stream {
                do {
                    try await asr.appendAudio(item.buffer)
                    try await asr.processBufferedAudio()
                    let words = await asr.consumeWordTimings()       // drains new words
                    if !words.isEmpty { onText(await asr.getPartialTranscript(), words) }
                } catch { break }
            }
        }
    }

    func stop() async throws -> String {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        cont?.finish()
        await pump?.value
        return try await asr.finish()
    }
}
```

Notes: `installTap(onBus:bufferSize:format:block:)` is deprecated in the macOS 27 SDK in favor of a throwing variant (`installTapOnBus:bufferSize:format:error:block:`, macOS 27+); the old one still works and compiles with a warning on a macOS 26 deployment target. Handle `AVAudioEngineConfigurationChange` (USB mic hot-plug or default-device change) by rebuilding the tap and converter.

### 6.8 Custom vocabulary (jargon boosting) snippet

```swift
let ctc = try await CtcModels.downloadAndLoad()                // variant: .ctc110m default
let vocab = CustomVocabularyContext(terms: [
    CustomVocabularyTerm(text: "LL(1)", aliases: ["L L one", "LL one"]),
    CustomVocabularyTerm(text: "lookahead", aliases: ["look ahead"]),
    CustomVocabularyTerm(text: "epsilon"),
    CustomVocabularyTerm(text: "nonterminal", aliases: ["non terminal", "non-terminal"]),
    CustomVocabularyTerm(text: "FIRST"), CustomVocabularyTerm(text: "FOLLOW"),
])
try await asr.configureVocabularyBoosting(vocabulary: vocab, ctcModels: ctc)   // before streaming starts
```

Facts: terms without `ctcTokenIds` are tokenized automatically. `CustomVocabularyTerm` supports `weight`, `aliases`, `minSimilarity`; `CustomVocabularyContext` has `alpha`, `minCtcScore`, `minSimilarity`, `minCombinedConfidence`, `minTermLength` (default 3 letters: very short terms like "LL" are skipped as an over-fire guard). Docs claim ~99% keyword accuracy in file mode but explicitly warn streaming is weaker (multi-word compounds limited, cross-chunk terms not detected in the sliding-window path, prefer single words). Multi-word CS terms ("epsilon production", "FIRST set") are better handled as aliases plus the LLM post-pass. Test with real lectures; over-firing on common words is the failure mode to watch.

### 6.9 Alternatives inside the same package (if Unified underperforms)

- `SlidingWindowAsrManager` + `AsrModels.downloadAndLoad(version: .ultra)` (595 MB int8 encoder, iOS 17 / macOS 14; more accurate than v3 in all FluidAudio benchmarks; `.v2` is English-only and tighter on rare English words). Batch API: `AsrManager(config: .default)`, `loadModels(_:)`, `transcribe(_ samples: [Float], source:)`.
- Nemotron: `StreamingNemotronAsrManager` (`loadModels(to:configuration:progressHandler:)`, `appendAudio`, `processBufferedAudio`, `getPartialTranscript`, `setPartialCallback`, `finishWithTokenTimings()`), tiers 560/1120/2240 ms. Docs in `Documentation/ASR/Nemotron.md` are partly stale (they show a `process(audioBuffer:)` path and `loadModels(modelDir:)`); prefer the signatures in source. Licensed under NVIDIA Open Model License; English WER a bit worse than Unified (6.93% vs ~5.9% average).
- Parakeet EOU 120M (`StreamingEouAsrManager`, 160/320/1280 ms): small and fast but lower accuracy; not for lectures.

---

## 7. Apple SpeechAnalyzer integration (verified in Xcode 27 SDK `Speech.swiftinterface` + compiled)

### 7.1 Availability

- Framework `Speech` (built in). `SpeechAnalyzer`, `SpeechTranscriber`, `DictationTranscriber`, `SpeechDetector`, `AssetInventory`, `AnalysisContext`, `AnalyzerInput` are `@available(macOS 26)`. Not available on watchOS.
- `SpeechTranscriber.isAvailable` (static Bool) is true on this machine; `installedLocales` had `en_US` (+ other English) and `supportedLocales` had 45 locales.
- macOS 27 additions (do not require for macOS 26 deployment): `AnalyzerInputConverter` (converts any `AVAudioBuffer` to the analyzer format), `CaptureInputSequenceProvider` (feeds `AVCaptureDevice` audio straight into an `AsyncSequence<AnalyzerInput>`), `AssetInputSequenceProvider` (files/assets), `AnalyzerInput.bufferFormat/bufferDuration` and `CMSampleBuffer` init, `SpeechAnalyzer.Options(priority:modelRetention:ignoresResourceLimits:)`, `SFSpeechError.Code.cannotConfigureAudioSystem`. `AnalyzerInput.buffer` is deprecated in 27.
- The "video preset" `.offlineTranscription` mentioned in WWDC25 does not exist in the shipping SDK. Presets on `SpeechTranscriber`: `.transcription`, `.transcriptionWithAlternatives`, `.timeIndexedTranscriptionWithAlternatives`, `.progressiveTranscription`, `.timeIndexedProgressiveTranscription`.

### 7.2 Key signatures

```swift
final class SpeechTranscriber : SpeechModule, LocaleDependentSpeechModule {
    convenience init(locale: Locale, preset: SpeechTranscriber.Preset)
    convenience init(locale: Locale,
                     transcriptionOptions: Set<TranscriptionOption>,   // [.etiquetteReplacements]
                     reportingOptions: Set<ReportingOption>,           // .volatileResults, .alternativeTranscriptions, .fastResults
                     attributeOptions: Set<ResultAttributeOption>)     // .audioTimeRange, .transcriptionConfidence
    static var isAvailable: Bool
    static var supportedLocales: [Locale] { get async }
    static func supportedLocale(equivalentTo: Locale) async -> Locale?
    static var installedLocales: [Locale] { get async }
    var results: some AsyncSequence<SpeechTranscriber.Result, any Error>
    struct Result { let range: CMTimeRange; let resultsFinalizationTime: CMTime; var text: AttributedString; let alternatives: [AttributedString] }
    // (isFinal comes from SpeechModuleResult protocol; used below)
}
actor SpeechAnalyzer {
    convenience init(modules: [any SpeechModule], options: Options? = nil)
    convenience init<S: AsyncSequence>(inputSequence: S, modules: [any SpeechModule], options: Options? = nil,
                                       analysisContext: AnalysisContext = .init(),
                                       volatileRangeChangedHandler: ...? = nil) where S.Element == AnalyzerInput
    func prepareToAnalyze(in: AVAudioFormat?) async throws
    func start<S: AsyncSequence>(inputSequence: S) async throws where S.Element == AnalyzerInput
    func analyzeSequence<S>(_ s: S) async throws -> CMTime?
    func finalize(through: CMTime?) async throws
    func finalizeAndFinishThroughEndOfInput() async throws
    func cancelAndFinishNow() async
    var volatileRange: CMTimeRange? { get }
    func setContext(_ c: AnalysisContext) async throws          // replaces, not additive
    static func bestAvailableAudioFormat(compatibleWith: [any SpeechModule]) async -> AVAudioFormat?
    static func bestAvailableAudioFormat(compatibleWith: [any SpeechModule], considering: AVAudioFormat?) async -> AVAudioFormat?
}
struct AnalyzerInput { init(buffer: AVAudioPCMBuffer); init(buffer: AVAudioPCMBuffer, bufferStartTime: CMTime?) }
final class AssetInventory {
    static func status(forModules: [any SpeechModule]) async -> Status         // .unsupported .downloading .supported .installed
    static func assetInstallationRequest(supporting: [any SpeechModule]) async throws -> AssetInstallationRequest?  // nil = nothing to install
    static func reserve(locale:) async throws -> Bool ; static func release(reservedLocale:) async -> Bool
    static var maximumReservedLocales: Int
}
final class AssetInstallationRequest: ProgressReporting { var progress: Progress; func downloadAndInstall() async throws }
```

### 7.3 Volatile vs final, timestamps, formats

- `reportingOptions: [.volatileResults]` turns on volatile results. Each `Result` has `isFinal`; a volatile result replaces the previous volatile result for the overlapping time range (do not append every partial). Finals arrive sentence-by-sentence roughly 0.5-1 s after speech (in my test at 8x real-time feed, finals landed as full sentences). `.fastResults` is faster but less accurate.
- Timing: `result.range` (`CMTimeRange` on the analyzer's audio timeline) and, with `.audioTimeRange`, a per-run `audioTimeRange` attribute on `result.text` (AttributedString) for word-level times, via `AttributeScopes.SpeechAttributes`.
- Format: the analyzer does not resample for you. Get `bestAvailableAudioFormat(compatibleWith:considering: micFormat)` and convert with `AVAudioConverter` (or the macOS 27 `AnalyzerInputConverter`). Do not hard-code sample rates.
- Finishing: finishing the input stream alone does not end the session. Call `finalizeAndFinishThroughEndOfInput()` while the results consumer is still running, then await the consumer. If the analyzer or results stream throws, the session is finished; create a new analyzer to recover.
- One input sequence at a time per analyzer.

### 7.4 Minimal working example (compiled clean in Swift 6 mode on Xcode 27)

```swift
import Speech
import AVFoundation
import CoreMedia

struct TranscriptSegment: Sendable {
    let text: String; let start: TimeInterval; let end: TimeInterval; let isFinal: Bool
}

final class AppleSTT: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Error>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?

    func start(onSegment: @escaping @Sendable (TranscriptSegment) -> Void) async throws {
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
                     ?? Locale(identifier: "en_US")
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [.volatileResults],
                                            attributeOptions: [.audioTimeRange])
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await req.downloadAndInstall()          // system-managed model download
        }
        let micFormat = engine.inputNode.outputFormat(forBus: 0)
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber], considering: micFormat) else {
            throw NSError(domain: "STT", code: 1)
        }
        analyzerFormat = fmt
        converter = AVAudioConverter(from: micFormat, to: fmt)

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = cont
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: fmt)

        resultsTask = Task {
            for try await r in transcriber.results {
                onSegment(TranscriptSegment(text: String(r.text.characters),
                                            start: r.range.start.seconds,
                                            end: r.range.end.seconds,
                                            isFinal: r.isFinal))
            }
        }
        try await analyzer.start(inputSequence: stream)

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buf, _ in
            guard let self, let conv = self.converter, let fmt = self.analyzerFormat else { return }
            let cap = AVAudioFrameCount(Double(buf.frameLength) * fmt.sampleRate / buf.format.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return }
            var fed = false
            conv.convert(to: out, error: nil) { _, st in
                if fed { st.pointee = .noDataNow; return nil }
                fed = true; st.pointee = .haveData; return buf
            }
            self.inputContinuation?.yield(AnalyzerInput(buffer: out))
        }
        engine.prepare()
        try engine.start()
    }

    func stop() async throws {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        inputContinuation?.finish()
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        try await resultsTask?.value
    }
}
```

(The repo-side version should be an actor with proper isolation; this shape is kept minimal. The result handling was exercised with a file-driven harness on this Mac; the mic path itself was only typechecked, not run.)

### 7.5 Custom vocabulary on Apple (what actually works)

- `SpeechTranscriber`: no vocabulary API in the interface (no content hints, no custom LM). `AnalysisContext.contextualStrings[.general] = [...]` + `analyzer.setContext(_:)` (or `analysisContext:` in the init) **compiles and runs but had no effect on output** in my test. Apple's guidance for contextual strings is "brief phrases, at most ~100 across tags" and hints only bias, never guarantee.
- `DictationTranscriber`: honors `contextualStrings` (verified: fixed LL(1), FIRST set, FOLLOW set, nonterminal on clean audio) and supports `contentHints: [.farField, .shortForm, .atypicalSpeech, .customizedLanguage(modelConfiguration:)]`, where the last uses a compiled `SFCustomLanguageModelData` custom language model (phrase counts, templates, custom pronunciations). That is a real jargon path, but the base model is markedly weaker on degraded audio, and `.farField` made no visible difference in my test. Use only if Apple must be the primary and jargon matters more than raw accuracy. Presets: `.progressiveLongDictation`, `.timeIndexedLongDictation`, etc.

### 7.6 Other Apple behavior worth knowing

- Model is retained in system storage, "does not increase the run-time memory size", and "operates outside of your application's memory space"; Apple updates it automatically. `SpeechAnalyzer.Options.modelRetention` (`.whileInUse`, `.lingering`, `.processLifetime`) controls how long it stays loaded.
- Language asset count per app is limited (`AssetInventory.maximumReservedLocales`).
- File throughput reports: 34-minute video in 45 s (MacStories/Yap, ~45x), peak memory about 200 MB for multi-hour files (blog reports). Live-mic long-session stability at 90 minutes is undocumented; test it.
- `AVAudioEngine` taps reportedly stop firing reliably with some Bluetooth devices (community reports); irrelevant for built-in/USB, but rebuild on route change.

---

## 8. Info.plist keys and entitlements

| Need | Key / entitlement | Notes |
|---|---|---|
| Microphone | `NSMicrophoneUsageDescription` (Info.plist) + `com.apple.security.device.audio-input` (App Sandbox and/or Hardened Runtime) | Request via `AVAudioApplication.requestRecordPermission()` (async) or `AVCaptureDevice.requestAccess(for: .audio)`. |
| Speech recognition | `NSSpeechRecognitionUsageDescription` | Required for legacy `SFSpeechRecognizer`. `SpeechAnalyzer` needs only mic permission per Apple's sample flow, and my file-driven test needed no authorization, but the mic path was not tested under TCC. Adding the key is harmless; include it to be safe. |
| FluidAudio model download | `com.apple.security.network.client` | Downloads from `huggingface.co` over HTTPS (ATS default is fine). Not needed if you bundle models and set `ModelHub.offlineMode = true`. |
| Apple model download | none | `AssetInventory` downloads through system services; no network entitlement observed to be required. |
| CoreML / ANE | none | No special entitlement. Run the app from a signed build for realistic ANE behavior. |
| User-selected files (export notes) | `com.apple.security.files.user-selected.read-write` | Only if you export. |

FluidAudio cache path in the sandbox: `~/Library/Containers/<bundle id>/Data/Library/Application Support/FluidAudio/Models/`.

---

## 9. Open questions and bake-off plan (do before locking the default)

1. Record 3-4 real lectures (built-in mic from the back of a room; USB mic; a slide-heavy lecture with lots of notation). Transcribe each with (a) Unified 1120 ms, (b) Unified + vocabulary boosting, (c) `.ultra` sliding window, (d) SpeechTranscriber, (e) optionally WhisperKit large-v3-turbo. Hand-correct 5-10 minutes of each as reference. Report WER, jargon-term recall (LL(1), FIRST/FOLLOW, epsilon production, lookahead), latency to partial, CPU/GPU/ANE power (`powermetrics`), and thermal behavior over 90 minutes with the LLM running.
2. Measure Unified first-run compile time and steady-state RTFx on the M2 Max with the LLM active. FluidAudio's own numbers are from newer M-series Pro chips.
3. Confirm the Unified CoreML model license (CC-BY-4.0 per FluidInference vs NVIDIA Open Model License per NVIDIA); both permit commercial use, but attribution/notice requirements differ.
4. Run a 90-minute soak test of `StreamingUnifiedAsrManager` and `SpeechAnalyzer` (memory growth, dropped audio, results-stream errors); test USB hot-unplug and sleep/wake.
5. Decide whether to run both engines in parallel for a "confidence" merge. Not recommended for v1: doubles ANE load and complexity.
6. Watch upstream: FluidAudio Unified streaming fixes (releases are near-daily), and Apple's `SpeechTranscriber` for any contextual-string support in later macOS 27 betas (re-run the Section 2 test each beta).

---

## 10. Sources

FluidAudio and models
- FluidAudio repo and README: https://github.com/FluidInference/FluidAudio (source read from clone at commit 20d4f0b)
- FluidAudio releases (v0.17.0 to v0.17.4, Sept 2026): https://github.com/FluidInference/FluidAudio/releases
- FluidAudio docs (in repo): `Documentation/Models.md`, `Documentation/ASR/GettingStarted.md`, `Documentation/ASR/Nemotron.md`, `Documentation/ASR/CustomVocabulary.md`, `Documentation/ASR/ParakeetUltra.md`, `Sources/FluidAudio/ASR/Parakeet/Unified/benchmark.md`
- Key source files: `Sources/FluidAudio/ASR/Parakeet/Unified/StreamingUnifiedAsrManager.swift`, `UnifiedConfig.swift`, `Streaming/StreamingAsrManager.swift`, `Streaming/ParakeetModelVariant.swift`, `SlidingWindow/SlidingWindowAsrManager.swift`, `SlidingWindow/TDT/AsrModels.swift`, `Shared/MLModelConfigurationUtils.swift`
- FluidAudio docs site: https://docs.fluidinference.com/introduction
- HF card, Parakeet Unified CoreML: https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml
- HF card, NVIDIA Parakeet Unified EN 0.6B: https://huggingface.co/nvidia/parakeet-unified-en-0.6b
- HF card, NVIDIA Parakeet TDT 0.6B v2: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2
- HF card, NVIDIA Parakeet TDT 0.6B v3: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
- HF card, NVIDIA Nemotron Speech Streaming EN 0.6B: https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b
- parakeet-mlx (reference, Apache-2.0, last push 2026-08-29): https://github.com/senstella/parakeet-mlx
- Zerm issue referencing FluidAudio 0.17.4 bump: https://github.com/arcusis/Zerm/issues/353

Apple
- Xcode 27 SDK `Speech.swiftinterface` (local: `/Applications/Xcode.app/.../MacOSX.sdk/System/Library/Frameworks/Speech.framework/Versions/A/Modules/Speech.swiftmodule/arm64e-apple-macos.swiftinterface`) and `AVAudioNode.h` (installTap deprecation)
- WWDC25 session 277, "Bring advanced speech-to-text to your app with SpeechAnalyzer": https://developer.apple.com/videos/play/wwdc2025/277/
- SpeechAnalyzer docs: https://developer.apple.com/documentation/speech/speechanalyzer
- MacStories, Yap/SpeechAnalyzer speed test: https://www.macstories.net/stories/hands-on-how-apples-new-speech-apis-outpace-whisper-for-lightning-fast-transcription/
- iOS 26 didn't kill custom vocabulary (DictationTranscriber vs SpeechTranscriber): https://dev.to/simple_memo/ios-26-didnt-kill-custom-vocabulary-youre-adding-it-to-the-wrong-module-5bdc
- SpeechAnalyzer live-mic gotchas: https://simplememofast.com/en/blog/ios26-speechanalyzer-live-mic
- macOS 27 SpeechAnalyzer notes (community): https://github.com/yrocaz/mac-transcriber/blob/main/docs/research/2026-07-27-apple-speechanalyzer-docs.md
- Apple developer forum, live voice input with SpeechAnalyzer: https://developer.apple.com/forums/thread/819555

Benchmarks and comparisons
- Argmax, Apple SpeechAnalyzer vs Argmax (Earnings-22 WER): https://www.argmaxinc.com/blog/apple-and-argmax
- Dictato 13k-recording comparison: https://dicta.to/blog/speech-to-text-engine-comparison-mac-2026/
- Inscribe SpeechAnalyzer benchmark and HN discussion: https://get-inscribe.com/blog/apple-speech-api-benchmark.html , https://news.ycombinator.com/item?id=48894752
- Open ASR Leaderboard (blog, repo): https://huggingface.co/blog/open-asr-leaderboard , https://github.com/huggingface/open_asr_leaderboard
- MarkTechPost open ASR roundup (July 2026): https://www.marktechpost.com/2026/07/23/best-open-speech-recognition-asr-models-in-2026-wer-languages-latency-and-license-compared/
- Parakeet vs Whisper comparisons (vendor blogs, lower reliability): https://whispernotes.app/blog/parakeet-v3-default-mac-model , https://vocai.net/blog/parakeet-vs-whisper-mac-benchmark-2026/

Other engines
- Argmax OSS SDK (WhisperKit, v1.1.0): https://github.com/argmaxinc/argmax-oss-swift
- Argmax Pro SDK and pricing: https://www.argmaxinc.com/pricing , https://www.argmaxinc.com/blog/pro-sdk-ga
- whisper.cpp (v1.9.4): https://github.com/ggml-org/whisper.cpp
- Moonshine (v0.1.5): https://github.com/moonshine-ai/moonshine
- Kyutai delayed-streams-modeling: https://github.com/kyutai-labs/delayed-streams-modeling
