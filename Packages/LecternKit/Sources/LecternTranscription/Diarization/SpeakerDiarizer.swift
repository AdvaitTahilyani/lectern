import LecternCore
import FluidAudio
import Foundation

/// Streaming speaker diarization on the Neural Engine (NVIDIA Streaming Sortformer via FluidAudio).
///
/// Independent of the speech recognizer: it consumes the same 16 kHz mono samples and reports who
/// is speaking, with about a second of look-ahead latency. Sortformer tracks up to four speakers at
/// once, which suits a lecturer plus a few students; it is trained to ignore distant background
/// chatter, so very quiet questions can be missed.
actor SpeakerDiarizer {
    private static let configuration = SortformerConfig.balancedV2_1

    /// Approximate size of the model download.
    static let downloadBytes: Int64 = 240_000_000

    private let diarizer: SortformerDiarizer
    private let frameDuration: TimeInterval
    private let speakerCount: Int

    // MARK: Model management

    private static var bundleURL: URL? {
        guard let bundle = ModelNames.Sortformer.bundle(for: configuration) else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/sortformer", isDirectory: true)
            .appendingPathComponent(bundle, isDirectory: true)
    }

    static var isInstalled: Bool {
        guard let url = bundleURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Downloads (if needed) and compiles the model so the first session starts quickly.
    static func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        _ = try await ModelStore.shared.models(progress: progress)
    }

    /// Compiled CoreML models are immutable and safe to share between sessions.
    private struct SharedModels: @unchecked Sendable {
        let models: SortformerModels
    }

    /// Loads models once per process and hands them to each session.
    private actor ModelStore {
        static let shared = ModelStore()
        private var loaded: SharedModels?

        func models(progress: (@Sendable (Double) -> Void)? = nil) async throws -> SharedModels {
            if let loaded { return loaded }
            var handler: ProgressHandler?
            if let progress { handler = { @Sendable update in progress(update.fractionCompleted) } }
            let models = try await SortformerModels.loadFromHuggingFace(
                config: SpeakerDiarizer.configuration, progressHandler: handler
            )
            let shared = SharedModels(models: models)
            loaded = shared
            return shared
        }
    }

    // MARK: Session

    /// - Throws: if the models are missing and cannot be downloaded, or fail to load.
    init() async throws {
        let config = Self.configuration
        let models = try await ModelStore.shared.models()
        var timeline = DiarizerTimelineConfig.sortformerDefault
        timeline.storeSegments = false      // turns are derived from raw frames; keep memory flat
        timeline.maxStoredFrames = 0
        let diarizer = SortformerDiarizer(config: config, timelineConfig: timeline)
        diarizer.initialize(models: models.models)
        self.diarizer = diarizer
        frameDuration = TimeInterval(config.frameDurationSeconds)
        speakerCount = config.numSpeakers
    }

    /// Feeds audio; returns turns for whatever the model finished processing.
    func append(_ samples: [Float]) throws -> DiarizationProgress? {
        diarizer.addAudio(samples)
        return progress(from: try diarizer.process())
    }

    /// Flushes the model at end of audio.
    func finish() throws -> DiarizationProgress? {
        progress(from: try diarizer.finalizeSession())
    }

    private func progress(from update: DiarizerTimelineUpdate?) -> DiarizationProgress? {
        guard let chunk = update?.chunkResult, chunk.finalizedFrameCount > 0 else { return nil }
        let turns = SpeakerTurn.runs(
            probabilities: chunk.finalizedPredictions,
            speakerCount: speakerCount,
            firstFrame: chunk.startFrame,
            frameDuration: frameDuration
        )
        return DiarizationProgress(
            turns: turns,
            through: Double(chunk.startFrame + chunk.finalizedFrameCount) * frameDuration
        )
    }
}

extension EngineReadiness {
    /// Readiness of an engine whose own models need `missingBytes` more downloaded, together with
    /// the speaker diarization model shared by all engines.
    static func combining(missingBytes: Int64, diarization: Bool) -> EngineReadiness {
        let total = missingBytes + (diarization && !SpeakerDiarizer.isInstalled ? SpeakerDiarizer.downloadBytes : 0)
        return total > 0 ? .needsDownload(bytes: total) : .ready
    }
}
