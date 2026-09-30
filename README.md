# Lectern

A native macOS companion for live lectures. While the lecture runs, Lectern keeps a transcript,
turns it into short "takeaway" cards (about one per five minutes, each expandable), follows along
in the slide deck, pings you with quick questions, catches you up when you've drifted
("While you were away"), and answers questions grounded in the slides and transcript, for one
lecture or the whole course.

Everything runs on-device by default: speech on the Neural Engine, the language model on the GPU.
OpenAI and Anthropic APIs, or a local Ollama / LM Studio server, can be swapped in per role.

## Requirements

- Apple silicon Mac, macOS 26 or later (developed on an M2 Max, 32 GB, macOS 27)
- Xcode 27 with the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Disk: ~16 GB for the default language model, ~1 GB for the speech models

## Build and run

```bash
Scripts/build.sh                  # Debug build → build/DD-main/Build/Products/Debug/Lectern.app
Scripts/build.sh DD-release Release
Scripts/install.sh                # Release build, installed to /Applications/Lectern.app
```

Use a **Release** build for real lectures. The on-device model generates about 3× slower in Debug.

Launch options:

| Flag | Effect |
|---|---|
| `-demo` | Scripted compilers lecture with a simulated brain; no mic, models or network |
| `-demoSpeed 3` | Demo lecture at 3× |
| `-selftest mlx` | Loads the on-device model inside the app bundle, generates, prints timings, exits |
| `-selftest pipeline -audio <wav> -slides <pdf> [-speed 4] [-minutes N] [-report <md>]` | Runs a recording through the real stack headlessly and writes a report (latency, memory, cards, slide trajectory) |

On first launch, onboarding asks for microphone access and downloads the models. Settings → Models
manages the downloads.

## Models

| Role | Default | Alternatives |
|---|---|---|
| Speech | Parakeet (FluidAudio, Neural Engine) with Sortformer speaker detection | Apple SpeechAnalyzer |
| Summaries, quizzes, Ask | Gemma 4 26B-A4B, QAT 4-bit, via MLX in-process | Qwen3.6 35B-A3B, Qwen3.5 9B; Ollama / LM Studio; OpenAI; Anthropic |

Why these: see `docs/research/local-llm.md` and `docs/research/stt.md`. API keys are stored in the
macOS Keychain.

## How it's built

```
App/Lectern/             SwiftUI app. Views depend only on LecternCore; Composition/ wires the real modules
Packages/LecternKit/
  LecternCore            Models + protocols every module implements (no dependencies)
  LecternTranscription   Mic capture, Parakeet + Apple Speech engines, diarization
  LecternLLM             OpenAI, Anthropic, OpenAI-compatible local servers, Keychain
  LecternMLX             In-process MLX host: shared model, per-role prompt caches, downloads
  LecternSlides          PDF ingest (+ OCR), slide search, forward-only slide tracking
  LecternStore           JSON persistence, autosave, library search
  LecternIntelligence    LectureBrain (takeaways, quizzes, Ask, recaps) and course-wide Ask
  LecternImport          Recording import (files, Illinois MediaSpace), PPTX/Keynote → PDF
```

The brain only sees the `LLMProvider` and `SlideSearching` protocols, so changing a role's model
is a Settings choice, not a code change. Prompts keep a byte-stable prefix (instructions + slide
digest) so the on-device prompt cache, and Anthropic's prompt caching, can reuse it between calls.

Design spec: `docs/DESIGN.md`. UI QA report: `docs/ui-review.md`.

## Tests

```bash
cd Packages/LecternKit && swift test        # all modules; the first build compiles MLX (slow)
```

Live tests that call real models are opt-in: `LECTERN_LIVE_TESTS=1`. Real-lecture fixtures
(audio, captions, slides) live in `TestData/`, which is gitignored. Get one with
`Scripts/fetch-mediaspace.sh <saved-page.html> <name>`.

## Known limitations

- Builds are ad-hoc signed unless the local signing identity exists. Run
  `Scripts/make-signing-identity.sh` once, and `build.sh` signs every build with it, so macOS keeps
  microphone / Keychain / Automation permissions across rebuilds. The identity is only trusted on
  this Mac; other Macs need right-click → Open.
- Speaker detection handles up to 4 voices and can miss quiet students far from the mic.
- Custom-vocabulary boosting is off by default: it fixed jargon but dropped other words.
