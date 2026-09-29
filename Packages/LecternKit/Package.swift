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
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.4"),
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
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ]
        ),
        .target(name: "LecternSlides", dependencies: ["LecternCore"]),
        .target(name: "LecternStore", dependencies: ["LecternCore"]),
        .target(name: "LecternIntelligence", dependencies: ["LecternCore"]),
        .testTarget(name: "LecternCoreTests", dependencies: ["LecternCore"]),
        .testTarget(name: "LecternIntelligenceTests", dependencies: ["LecternIntelligence"]),
        .testTarget(name: "LecternSlidesTests", dependencies: ["LecternSlides"]),
        .testTarget(name: "LecternLLMTests", dependencies: ["LecternLLM"]),
    ]
)
