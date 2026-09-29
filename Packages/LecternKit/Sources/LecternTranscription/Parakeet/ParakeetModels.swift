import FluidAudio
import Foundation

/// Where FluidAudio keeps the models Lectern uses, and what "installed" means.
enum ParakeetModels {
    /// Streaming tier: 70 left / 7 chunk / 7 right encoder frames of 80 ms = 1120 ms latency,
    /// the best streaming WER of the published tiers.
    static let streamingConfig = UnifiedConfig(leftFrames: 70, chunkFrames: 7, rightFrames: 7)
    static let encoderPrecision = UnifiedEncoderPrecision.int8
    static let fallbackVersion = AsrModelVersion.ultra

    /// Approximate download sizes in bytes, for `EngineReadiness.needsDownload`.
    static let unifiedBytes: Int64 = 620_000_000
    static let vocabularyBytes: Int64 = 100_000_000
    static let fallbackBytes: Int64 = 600_000_000

    static var streamingLatency: TimeInterval { Double(streamingConfig.latencyMs) / 1000 }

    private static var modelsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    static var unifiedDirectory: URL {
        modelsRoot.appendingPathComponent(Repo.parakeetUnified.folderName, isDirectory: true)
    }

    static var isUnifiedInstalled: Bool {
        let names = ModelNames.ParakeetUnified.self
        let required = [
            names.streamingEncoderFile(precision: encoderPrecision, contextSuffix: streamingConfig.contextSuffix),
            names.decoderFile, names.jointDecisionFile, names.vocab,
        ]
        return required.allSatisfy {
            FileManager.default.fileExists(atPath: unifiedDirectory.appendingPathComponent($0).path)
        }
    }

    /// The CTC keyword-spotting model used for vocabulary boosting.
    static var isVocabularyModelInstalled: Bool {
        CtcModels.modelsExist(at: CtcModels.defaultCacheDirectory())
    }

    static var isFallbackInstalled: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: fallbackVersion), version: fallbackVersion)
    }
}
