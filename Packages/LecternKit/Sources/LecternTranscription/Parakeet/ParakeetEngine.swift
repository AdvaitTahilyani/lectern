import FluidAudio
import Foundation
import LecternCore

/// NVIDIA Parakeet on the Neural Engine via FluidAudio.
///
/// Streams with `StreamingUnifiedAsrManager` (1120 ms tier, int8 encoder, ANE only, so the GPU
/// stays free for the LLM) and falls back to the sliding-window Parakeet TDT manager if the
/// unified models cannot be loaded. The recognizer's cumulative text is turned into
/// `.volatile`/`.final` events by `SegmentAssembler`. Custom vocabulary uses FluidAudio's CTC
/// vocabulary boosting: corrections land on text that is at most ~15 s old, so only the volatile
/// tail is expected to change.
///
/// Create one instance per app and keep it: loading the models takes seconds.
public final class ParakeetEngine: TranscriptionEngine {
    public let engineID = TranscriptionEngineID.parakeet
    private let core = ParakeetCore()

    public init() {}

    public func readiness() async -> EngineReadiness {
        await core.readiness()
    }

    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await core.prepare(progress: progress)
    }

    public func start(options: TranscriptionOptions) async throws -> AsyncThrowingStream<TranscriptionEvent, Error> {
        try await core.startLive(options: options)
    }

    public func stop() async {
        await core.stopLive()
    }

    public func transcribeFile(at url: URL, options: TranscriptionOptions) async throws -> AsyncThrowingStream<TranscriptionEvent, Error> {
        try await core.transcribeFile(at: url, options: options)
    }
}

/// All mutable state of `ParakeetEngine`, isolated in one actor.
private actor ParakeetCore {
    private var unified: StreamingUnifiedAsrManager?
    /// Vocabulary terms the loaded unified manager is boosted with (boosting cannot be unset).
    private var boostedTerms: [String]?
    private var fallbackModels: AsrModels?
    private var vocabularyModels: CtcModels?
    private let live = LiveSessionSlot()

    // MARK: Readiness & preparation

    func readiness() -> EngineReadiness {
        var missing: Int64 = 0
        if !ParakeetModels.isUnifiedInstalled && !ParakeetModels.isFallbackInstalled { missing += ParakeetModels.unifiedBytes }
        if !ParakeetModels.isVocabularyModelInstalled { missing += ParakeetModels.vocabularyBytes }
        return EngineReadiness.combining(missingBytes: missing, diarization: true)
    }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(0)
        // Progress budget: speech models 0...0.7, vocabulary model to 0.75, speaker model to 1.
        do {
            _ = try await loadUnified { progress($0 * 0.7) }
        } catch {
            do {
                fallbackModels = try await AsrModels.downloadAndLoad(version: ParakeetModels.fallbackVersion) { progress($0.fractionCompleted * 0.7) }
            } catch let fallbackError {
                throw TranscriptionError.recognitionFailed(
                    "Parakeet models could not be loaded (\(error.localizedDescription)); fallback also failed (\(fallbackError.localizedDescription))."
                )
            }
        }
        progress(0.7)
        _ = try await loadVocabularyModels()
        progress(0.75)
        try await SpeakerDiarizer.prepare { progress(0.75 + $0 * 0.25) }
        progress(1)
    }

    private func loadUnified(progress: (@Sendable (Double) -> Void)? = nil) async throws -> StreamingUnifiedAsrManager {
        if let unified { return unified }
        let manager = StreamingUnifiedAsrManager(config: ParakeetModels.streamingConfig, encoderPrecision: ParakeetModels.encoderPrecision)
        var handler: ProgressHandler?
        if let progress {
            handler = { @Sendable update in progress(update.fractionCompleted) }
        }
        try await manager.loadModels(progressHandler: handler)
        unified = manager
        boostedTerms = nil
        return manager
    }

    private func loadVocabularyModels() async throws -> CtcModels {
        if let vocabularyModels { return vocabularyModels }
        let models = try await CtcModels.downloadAndLoad()
        vocabularyModels = models
        return models
    }

    // MARK: Recognizer construction

    /// Builds a recognizer for one session. Warnings describe degraded features (for example
    /// unavailable vocabulary boosting) and are emitted at the start of the event stream.
    private func makeRecognizer(vocabulary: [String]) async throws -> (recognizer: any StreamingRecognizer, warnings: [String]) {
        guard ParakeetModels.isUnifiedInstalled || ParakeetModels.isFallbackInstalled || unified != nil || fallbackModels != nil else {
            throw TranscriptionError.modelsNotInstalled(engine: "Parakeet")
        }
        let terms = Self.normalized(vocabulary)
        var warnings: [String] = []
        if unified != nil || ParakeetModels.isUnifiedInstalled {
            do {
                let manager = try await unifiedManager(boostedWith: terms, warnings: &warnings)
                let recognizer = try await UnifiedRecognizer(manager: manager, latency: ParakeetModels.streamingLatency)
                return (recognizer, warnings)
            } catch {
                guard ParakeetModels.isFallbackInstalled || fallbackModels != nil else { throw error }
                warnings.append("Parakeet streaming unavailable (\(error.localizedDescription)); using the sliding-window model.")
                unified = nil
            }
        }
        let recognizer = try await slidingWindowRecognizer(vocabulary: terms, warnings: &warnings)
        return (recognizer, warnings)
    }

    /// The unified manager, boosted with exactly `terms` (or not at all when empty). Boosting can be
    /// added to a loaded manager but not removed, so a vocabulary change that would need removal
    /// loads a fresh manager.
    private func unifiedManager(boostedWith terms: [String], warnings: inout [String]) async throws -> StreamingUnifiedAsrManager {
        let desired: [String]? = terms.isEmpty ? nil : terms
        if let current = unified {
            if boostedTerms == desired { return current }
            if boostedTerms == nil, let desired {
                await configureBoosting(current, terms: desired, warnings: &warnings)
                return current
            }
            unified = nil
        }
        let manager = try await loadUnified()
        if let desired { await configureBoosting(manager, terms: desired, warnings: &warnings) }
        return manager
    }

    private func configureBoosting(_ manager: StreamingUnifiedAsrManager, terms: [String], warnings: inout [String]) async {
        do {
            let ctc = try await loadVocabularyModels()
            let vocabulary = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) })
            try await manager.configureVocabularyBoosting(vocabulary: vocabulary, ctcModels: ctc)
            boostedTerms = terms
        } catch {
            warnings.append("Custom vocabulary unavailable: \(error.localizedDescription)")
        }
    }

    private func slidingWindowRecognizer(vocabulary terms: [String], warnings: inout [String]) async throws -> SlidingWindowRecognizer {
        let models: AsrModels
        if let fallbackModels {
            models = fallbackModels
        } else {
            models = try await AsrModels.downloadAndLoad(version: ParakeetModels.fallbackVersion)
            fallbackModels = models
        }
        let manager = SlidingWindowAsrManager(config: .streaming)
        try await manager.loadModels(models)
        if !terms.isEmpty {
            do {
                let ctc = try await loadVocabularyModels()
                let vocabulary = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) })
                try await manager.configureVocabularyBoosting(vocabulary: vocabulary, ctcModels: ctc)
            } catch {
                warnings.append("Custom vocabulary unavailable: \(error.localizedDescription)")
            }
        }
        return try await SlidingWindowRecognizer(manager: manager)
    }

    private static func normalized(_ vocabulary: [String]) -> [String] {
        var seen = Set<String>()
        return vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(200)
            .map { $0 }
    }

    // MARK: Sessions

    /// Everything a session needs before audio starts flowing.
    private func openSession(
        options: TranscriptionOptions
    ) async throws -> (stream: AsyncThrowingStream<TranscriptionEvent, Error>, sink: EventSink, pipeline: RecognitionPipeline, diarization: DiarizationFeed?) {
        let (recognizer, warnings) = try await makeRecognizer(vocabulary: options.vocabulary)
        let (stream, continuation) = AsyncThrowingStream<TranscriptionEvent, Error>.makeStream(bufferingPolicy: .unbounded)
        let sink = EventSink(continuation: continuation, timeOffset: options.timeOffset, labelSpeakers: options.diarize)
        for warning in warnings { sink.send(.warning(warning)) }
        let diarization = options.diarize ? await DiarizationFeed.start(sink: sink) : nil
        if diarization == nil { sink.stopLabeling() }
        let pipeline = RecognitionPipeline(
            recognizer: recognizer, assembler: SegmentAssembler(timeOffset: options.timeOffset), sink: sink
        )
        return (stream, sink, pipeline, diarization)
    }

    func startLive(options: TranscriptionOptions) async throws -> AsyncThrowingStream<TranscriptionEvent, Error> {
        try await live.start { id in try await self.openLive(options: options, session: id) }
    }

    private func openLive(options: TranscriptionOptions, session id: UUID) async throws -> LiveSessionSlot.Opened {
        let session = try await openSession(options: options)
        let capture = AudioCapture()
        let audio: AsyncThrowingStream<AudioCaptureEvent, Error>
        do {
            audio = try await capture.start(deviceID: options.inputDeviceID)
        } catch {
            session.diarization?.cancel()
            await session.pipeline.cancel()
            throw error
        }
        let task = Task {
            await SessionRunner.runLive(audio: audio, recognizer: session.pipeline, diarization: session.diarization, sink: session.sink)
            await capture.stop()
        }
        // The consumer dropped the stream (or it ended): stop this session, never a newer one.
        session.sink.onTermination { [live] in
            Task { await live.stop(session: id) }
        }
        return LiveSessionSlot.Opened(stream: session.stream) {
            await capture.stop()   // ends the audio stream; the task then flushes and finishes
            await task.value
        }
    }

    func stopLive() async {
        await live.stop()
    }

    func transcribeFile(at url: URL, options: TranscriptionOptions) async throws -> AsyncThrowingStream<TranscriptionEvent, Error> {
        let source = try AudioFileSource(url: url)
        let session = try await openSession(options: options)
        let task = Task {
            await SessionRunner.runFile(source: source, recognizer: session.pipeline, diarization: session.diarization, sink: session.sink)
        }
        session.sink.onTermination { task.cancel() }
        return session.stream
    }
}
