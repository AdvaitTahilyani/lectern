import Foundation
import LecternCore

/// Builds a finished `LectureSession` from a recording: audio → transcript (on-device ASR, or the
/// MediaSpace caption track) → speaker labels → takeaways from the intelligence layer.
///
/// The importer depends only on `LecternCore`; the app supplies the concrete engine and brain.
public struct RecordingImporter: RecordingImporting {
    public typealias EngineFactory = @Sendable () -> any TranscriptionEngine
    public typealias BrainFactory = @Sendable (BrainContext) async -> any LectureIntelligence
    /// Rewrites the finished transcript before it is summarized (e.g. deck-based jargon fixes).
    public typealias TranscriptCorrection = @Sendable ([TranscriptSegment], SlideDeck?) async -> [TranscriptSegment]

    private let makeEngine: EngineFactory
    private let makeBrain: BrainFactory
    private let kaltura: KalturaClient
    private let extractor: AudioExtractor
    private let onWarning: @Sendable (String) -> Void
    private let scratchRoot: URL
    private let correctTranscript: TranscriptCorrection?

    /// - Parameters:
    ///   - makeEngine: creates the transcription engine used for `transcribeFile`.
    ///   - makeBrain: creates the intelligence for the session being built. Quizzes are irrelevant
    ///     here; the importer only reads takeaways.
    ///   - kaltura: MediaSpace client (injectable for tests).
    ///   - scratchDirectory: where per-import working folders (downloads, extracted audio) are
    ///     created; each is removed when the import ends, however it ends.
    ///   - onWarning: non-fatal problems (engine warnings, failed summary passes) worth showing
    ///     subtly; the import still completes.
    ///   - correctTranscript: applied to the transcript before summarizing, so takeaways are
    ///     written from the corrected text.
    public init(
        makeEngine: @escaping EngineFactory,
        makeBrain: @escaping BrainFactory,
        kaltura: KalturaClient = KalturaClient(),
        audioExtractor: AudioExtractor = AudioExtractor(),
        scratchDirectory: URL = FileManager.default.temporaryDirectory,
        onWarning: @escaping @Sendable (String) -> Void = { _ in },
        correctTranscript: TranscriptCorrection? = nil
    ) {
        self.makeEngine = makeEngine
        self.makeBrain = makeBrain
        self.kaltura = kaltura
        self.extractor = audioExtractor
        self.scratchRoot = scratchDirectory
        self.onWarning = onWarning
        self.correctTranscript = correctTranscript
    }

    public func importRecording(
        _ source: RecordingSource,
        into session: LectureSession,
        progress: @escaping @Sendable (ImportStage) -> Void
    ) async throws -> LectureSession {
        let workDirectory = scratchRoot.appendingPathComponent("lectern-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        var result = session
        var transcript: Transcript
        switch source {
        case .file(let url):
            transcript = try await transcribe(mediaFile: url, vocabulary: session.vocabulary, workDirectory: workDirectory, progress: progress)
            result.source = .audioFile(originalFileName: url.lastPathComponent)
            if result.title.isEmpty { result.title = url.deletingPathExtension().lastPathComponent }

        case .mediaSpace(let mediaSource, let preferCaptions):
            var fromCaptions: Transcript?
            if preferCaptions {
                progress(.downloading(fraction: 0))
                let segments = try await captionSegments(for: mediaSource)
                if !segments.isEmpty { fromCaptions = Transcript(segments: segments, duration: segments.last?.end ?? 0) }
            }
            if let fromCaptions {
                transcript = fromCaptions
            } else {
                progress(.downloading(fraction: 0))
                let media = try await kaltura.downloadMedia(for: mediaSource, into: workDirectory) { progress(.downloading(fraction: $0)) }
                transcript = try await transcribe(mediaFile: media, vocabulary: session.vocabulary, workDirectory: workDirectory, progress: progress)
            }
            result.source = .mediaSpace(entryID: mediaSource.entryID, pageURL: mediaSource.pageURL, usedCaptions: fromCaptions != nil)
            if result.title.isEmpty { result.title = mediaSource.title ?? "MediaSpace lecture" }
        }
        try Task.checkCancellation()
        guard !transcript.segments.isEmpty else { throw ImportError.emptyTranscript }

        if let correctTranscript { transcript.segments = await correctTranscript(transcript.segments, session.deck) }
        progress(.summarizing(fraction: 0))
        result.transcript = transcript.segments
        result.duration = max(transcript.duration, transcript.segments.last?.end ?? 0)
        result.takeaways = try await summarize(transcript, session: result, progress: progress)
        result.status = .finished
        result.startedAt = result.startedAt ?? result.createdAt
        result.endedAt = .now
        progress(.finished)
        return result
    }

    // MARK: - Transcript

    /// The MediaSpace caption track, or nothing when it can't be had for any reason other than an
    /// expired session: captions are only preferred, so the audio is transcribed instead.
    private func captionSegments(for source: MediaSpaceSource) async throws -> [TranscriptSegment] {
        do {
            return try await kaltura.captions(for: source)
        } catch ImportError.sessionExpired {
            throw ImportError.sessionExpired
        } catch {
            try Task.checkCancellation()
            onWarning("The lecture's captions couldn't be read (\(error.localizedDescription)); transcribing the audio instead.")
            return []
        }
    }

    private struct Transcript {
        var segments: [TranscriptSegment]
        var duration: TimeInterval
    }

    /// Extracts 16 kHz audio from `mediaFile` and runs the engine over it.
    private func transcribe(
        mediaFile: URL,
        vocabulary: [String],
        workDirectory: URL,
        progress: @escaping @Sendable (ImportStage) -> Void
    ) async throws -> Transcript {
        progress(.extractingAudio)
        let audio = workDirectory.appendingPathComponent("audio-\(UUID().uuidString).wav")
        let duration = try await extractor.extract(from: mediaFile, to: audio)
        try Task.checkCancellation()

        let engine = makeEngine()
        switch await engine.readiness() {
        case .ready:
            break
        case .needsDownload:
            try await engine.prepare { progress(.downloading(fraction: $0)) }
        case .unavailable(let reason):
            throw ImportError.mediaUnavailable("transcription is unavailable: \(reason)")
        }

        progress(.transcribing(fraction: 0))
        let options = TranscriptionOptions(vocabulary: vocabulary, diarize: true)
        var segments: [TranscriptSegment] = []
        var speakers: [UUID: SpeakerRole] = [:]
        try await withTaskCancellationHandler {
            let events = try await engine.transcribeFile(at: audio, options: options)
            for try await event in events {
                switch event {
                case .final(let segment):
                    segments.append(segment)
                    if duration > 0 { progress(.transcribing(fraction: min(1, segment.end / duration))) }
                case .speakers(let labels):
                    speakers.merge(labels) { _, new in new }
                case .warning(let message):
                    onWarning(message)
                case .volatile, .level:
                    break
                }
            }
        } onCancel: {
            Task { await engine.stop() }
        }
        try Task.checkCancellation()
        progress(.transcribing(fraction: 1))

        for index in segments.indices { segments[index].speaker = speakers[segments[index].id] ?? segments[index].speaker }
        return Transcript(segments: segments, duration: duration)
    }

    // MARK: - Takeaways

    private func summarize(
        _ transcript: Transcript,
        session: LectureSession,
        progress: @escaping @Sendable (ImportStage) -> Void
    ) async throws -> [Takeaway] {
        let context = BrainContext(sessionTitle: session.title, courseName: nil, deck: session.deck, transcript: [], takeaways: [], quizHistory: [], sessionID: session.id)
        let brain = await makeBrain(context)
        let latest = LatestTakeaways()
        let duration = max(transcript.duration, 1)
        let onWarning = self.onWarning

        // The brain reports coverage through `updates`; the newest takeaway's end time is a real
        // progress signal for a transcript that is ingested all at once.
        let updates = Task {
            for await update in brain.updates {
                switch update {
                case .takeaways(let takeaways):
                    latest.set(takeaways)
                    if let end = takeaways.last?.end { progress(.summarizing(fraction: min(0.99, end / duration))) }
                case .error(let message):
                    onWarning(message)
                default:
                    break
                }
            }
        }
        defer { updates.cancel() }

        let speakers = Dictionary(transcript.segments.compactMap { segment in segment.speaker.map { (segment.id, $0) } }, uniquingKeysWith: { _, new in new })
        await brain.applySpeakers(speakers)
        for segment in transcript.segments {
            try Task.checkCancellation()
            await brain.ingest(segment)
        }
        try await awaitCancellable {
            await brain.waitUntilIdle()
            await brain.finish()
        }

        // `finish()` emits the settled list as its last update; give the consumer a moment to
        // receive it (the stream itself only ends when the brain is released).
        for _ in 0..<50 where latest.value.last?.isLive != false {
            try await Task.sleep(for: .milliseconds(20))
        }
        return latest.value
    }
}

/// Newest takeaway list seen on the brain's update stream.
private final class LatestTakeaways: @unchecked Sendable {
    private let lock = NSLock()   // guards `takeaways`
    private var takeaways: [Takeaway] = []

    var value: [Takeaway] {
        lock.lock(); defer { lock.unlock() }
        return takeaways
    }

    func set(_ new: [Takeaway]) {
        lock.lock(); defer { lock.unlock() }
        takeaways = new
    }
}
