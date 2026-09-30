// swift-tools-version: 6.2
import PackageDescription

// LecternKit: every capability lives in its own module so backends can be swapped.
//
//   LecternCore           models + protocols (no dependencies)
//   LecternTranscription  Parakeet (FluidAudio, ANE) + Apple SpeechAnalyzer engines, audio capture
//   LecternLLM            OpenAI, Anthropic, OpenAI-compatible local server providers, Keychain
//   LecternMLX            in-process on-device LLM provider (MLX Swift) + model downloads
//   LecternSlides         PDF ingest, OCR fallback, thumbnails, slide retrieval
//   LecternStore          JSON persistence of courses + sessions
//   LecternIntelligence   LectureBrain: takeaways, quizzes, Ask (depends only on protocols)
let package = Package(
    name: "LecternKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LecternCore", targets: ["LecternCore"]),
        .library(name: "LecternTranscription", targets: ["LecternTranscription"]),
        .library(name: "LecternLLM", targets: ["LecternLLM"]),
        .library(name: "LecternMLX", targets: ["LecternMLX"]),
        .library(name: "LecternSlides", targets: ["LecternSlides"]),
        .library(name: "LecternStore", targets: ["LecternStore"]),
        .library(name: "LecternIntelligence", targets: ["LecternIntelligence"]),
        .library(name: "LecternImport", targets: ["LecternImport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4"),
        // Pinned to main: 3.31.4 predates MLXGuidedGeneration (JSON-schema constrained decoding) and the
        // Sept 2026 Gemma 4 fixes (fused logit softcap, wrap-aware RotatingKVCache trim).
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", revision: "c043fb3b1ccf00f54ef8882a1e8da45c6e32e6f8"),
        // LecternMLX: MLX GPU memory controls, Hugging Face downloader, tokenizers (mlx-swift-lm 3.x ships none).
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.32.2"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .target(name: "LecternCore"),
        .target(
            name: "LecternTranscription",
            dependencies: ["LecternCore", .product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .target(name: "LecternLLM", dependencies: ["LecternCore"]),
        .target(
            name: "LecternMLX",
            dependencies: [
                "LecternCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXGuidedGeneration", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .target(name: "LecternSlides", dependencies: ["LecternCore"]),
        .target(name: "LecternStore", dependencies: ["LecternCore"]),
        .target(name: "LecternIntelligence", dependencies: ["LecternCore"]),
        .target(name: "LecternImport", dependencies: ["LecternCore"]),
        .testTarget(name: "LecternCoreTests", dependencies: ["LecternCore"]),
        .testTarget(name: "LecternIntelligenceTests", dependencies: ["LecternIntelligence"]),
        .testTarget(name: "LecternSlidesTests", dependencies: ["LecternSlides"]),
        .testTarget(name: "LecternStoreTests", dependencies: ["LecternStore"]),
        .testTarget(name: "LecternLLMTests", dependencies: ["LecternLLM"]),
        .testTarget(name: "LecternImportTests", dependencies: ["LecternImport", "LecternCore"]),
        .testTarget(name: "LecternTranscriptionTests", dependencies: ["LecternTranscription", "LecternCore"]),
        .testTarget(
            name: "LecternMLXTests",
            dependencies: [
                "LecternMLX", "LecternCore", "LecternIntelligence",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ]
        ),
    ]
)
