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
    /// Persists the import's work so far. A failure is reported as a warning; the import goes on.
    public typealias Checkpoint = @Sendable (LectureSession) async throws -> Void

    private let makeEngine: EngineFactory
    private let makeBrain: BrainFactory
    private let kaltura: KalturaClient
    private let extractor: AudioExtractor
    private let onWarning: @Sendable (String) -> Void
    private let scratchRoot: URL
    private let correctTranscript: TranscriptCorrection?
    private let checkpoint: Checkpoint?
    private let checkpointInterval: Duration

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
    ///   - checkpoint: called with the session (status `.importing`, `importRecord` saying how far
    ///     it got) while the import runs: every `checkpointInterval` during transcription and
    ///     summarizing, and always once the whole transcript exists. A crash or failure then
    ///     leaves a transcript that `resumeImport(_:progress:)` can finish.
    public init(
        makeEngine: @escaping EngineFactory,
        makeBrain: @escaping BrainFactory,
        kaltura: KalturaClient = KalturaClient(),
        audioExtractor: AudioExtractor = AudioExtractor(),
        scratchDirectory: URL = FileManager.default.temporaryDirectory,
        onWarning: @escaping @Sendable (String) -> Void = { _ in },
        correctTranscript: TranscriptCorrection? = nil,
        checkpoint: Checkpoint? = nil,
        checkpointInterval: Duration = .seconds(20)
    ) {
        self.makeEngine = makeEngine
        self.makeBrain = makeBrain
        self.kaltura = kaltura
        self.extractor = audioExtractor
        self.scratchRoot = scratchDirectory
        self.onWarning = onWarning
        self.correctTranscript = correctTranscript
        self.checkpoint = checkpoint
        self.checkpointInterval = checkpointInterval
    }

    public func importRecording(
        _ source: RecordingSource,
        into session: LectureSession,
        progress: @escaping @Sendable (ImportStage) -> Void
    ) async throws -> LectureSession {
        let workDirectory = scratchRoot.appendingPathComponent("lectern-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let saver = ProgressSaver(base: session, checkpoint: checkpoint, interval: checkpointInterval, warnings: ImportWarnings(forward: onWarning))
        var result = session
        var transcript: Transcript
        switch source {
        case .file(let url):
            transcript = try await transcribe(mediaFile: url, vocabulary: session.vocabulary, workDirectory: workDirectory, saver: saver, progress: progress)
            result.source = .audioFile(originalFileName: url.lastPathComponent)
            if result.title.isEmpty { result.title = url.deletingPathExtension().lastPathComponent }

        case .mediaSpace(let mediaSource, let preferCaptions):
            var fromCaptions: Transcript?
            if preferCaptions {
                progress(.downloading(fraction: 0))
                let segments = try await captionSegments(for: mediaSource, warnings: saver.warnings)
                if !segments.isEmpty { fromCaptions = Transcript(segments: segments, duration: segments.last?.end ?? 0) }
            }
            if let fromCaptions {
                transcript = fromCaptions
            } else {
                progress(.downloading(fraction: 0))
                let media = try await kaltura.downloadMedia(for: mediaSource, into: workDirectory) { progress(.downloading(fraction: $0)) }
                transcript = try await transcribe(mediaFile: media, vocabulary: session.vocabulary, workDirectory: workDirectory, saver: saver, progress: progress)
            }
            result.source = .mediaSpace(entryID: mediaSource.entryID, pageURL: mediaSource.pageURL, usedCaptions: fromCaptions != nil)
            if result.title.isEmpty { result.title = mediaSource.title ?? "MediaSpace lecture" }
        }
        try Task.checkCancellation()
        guard !transcript.segments.isEmpty else { throw ImportError.emptyTranscript }

        if let correctTranscript { transcript.segments = await correctTranscript(transcript.segments, session.deck) }
        result.transcript = transcript.segments
        result.duration = max(transcript.duration, transcript.segments.last?.end ?? 0)
        await saver.save(result, phase: .transcribed)
        return try await finish(result, transcript: transcript, saver: saver, progress: progress)
    }

    public func resumeImport(
        _ session: LectureSession,
        progress: @escaping @Sendable (ImportStage) -> Void
    ) async throws -> LectureSession {
        guard !session.transcript.isEmpty else { throw ImportResumeError.nothingToResume }
        let saver = ProgressSaver(base: session, checkpoint: checkpoint, interval: checkpointInterval, warnings: ImportWarnings(forward: onWarning, existing: session.importRecord?.warnings ?? []))
        var result = session
        var segments = session.transcript
        let partial = session.importRecord?.phase == .transcribing
        if partial {
            // The recording was only partly transcribed when the import stopped.
            let minutes = Int((segments.last?.end ?? 0) / 60)
            saver.warnings.add("The import was interrupted, so this lecture covers only the first \(max(1, minutes)) min of the recording.")
            if let correctTranscript { segments = await correctTranscript(segments, session.deck) }
        }
        result.transcript = segments
        result.takeaways = []
        result.duration = max(session.duration, segments.last?.end ?? 0)
        if partial { await saver.save(result, phase: .transcribed) } else { await saver.adopt(result) }
        var finished = try await finish(result, transcript: Transcript(segments: segments, duration: result.duration), earlierTakeaways: session.takeaways, saver: saver, progress: progress)
        // Keep what the interrupted run had already written when this one wrote nothing.
        if finished.takeaways.isEmpty { finished.takeaways = session.takeaways }
        return finished
    }

    /// Writes the takeaways for `result.transcript` and returns the finished lecture.
    private func finish(
        _ session: LectureSession,
        transcript: Transcript,
        earlierTakeaways: [Takeaway] = [],
        saver: ProgressSaver,
        progress: @escaping @Sendable (ImportStage) -> Void
    ) async throws -> LectureSession {
        var result = session
        progress(.summarizing(fraction: 0))
        result.takeaways = try await summarize(transcript, session: result, earlierTakeaways: earlierTakeaways, saver: saver, progress: progress)
        result.status = .finished
        result.startedAt = result.startedAt ?? result.createdAt
        result.endedAt = .now
        let warnings = saver.warnings.all
        result.importRecord = warnings.isEmpty ? nil : ImportRecord(phase: .complete, warnings: warnings)
        progress(.finished)
        return result
    }

    // MARK: - Transcript

    /// The MediaSpace caption track, or nothing when it can't be had for any reason other than an
    /// expired session: captions are only preferred, so the audio is transcribed instead.
    private func captionSegments(for source: MediaSpaceSource, warnings: ImportWarnings) async throws -> [TranscriptSegment] {
        do {
            return try await kaltura.captions(for: source)
        } catch ImportError.sessionExpired {
            throw ImportError.sessionExpired
        } catch {
            try Task.checkCancellation()
            warnings.add("The lecture's captions couldn't be read (\(error.localizedDescription)); transcribing the audio instead.")
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
        saver: ProgressSaver,
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
                    await saver.saveTranscribing(segments)
                case .speakers(let labels):
                    speakers.merge(labels) { _, new in new }
                case .warning(let message):
                    saver.warnings.add(message)
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
        earlierTakeaways: [Takeaway],
        saver: ProgressSaver,
        progress: @escaping @Sendable (ImportStage) -> Void
    ) async throws -> [Takeaway] {
        let context = BrainContext(sessionTitle: session.title, courseName: nil, deck: session.deck, transcript: [], takeaways: [], quizHistory: [], sessionID: session.id)
        let brain = await makeBrain(context)
        let latest = LatestTakeaways()
        let duration = max(transcript.duration, 1)
        let warnings = saver.warnings

        // The brain reports coverage through `updates`; the newest takeaway's end time is a real
        // progress signal for a transcript that is ingested all at once.
        let updates = Task {
            for await update in brain.updates {
                switch update {
                case .takeaways(let takeaways):
                    latest.set(takeaways)
                    if let end = takeaways.last?.end { progress(.summarizing(fraction: min(0.99, end / duration))) }
                    await saver.saveSummarizing(takeaways)
                case .error(let message):
                    warnings.add(message)
                default:
                    break
                }
            }
        }
        // Stop the update loop and wait for it before leaving, however this ends: a checkpoint it
        // was writing must not land after the caller's own (later) save.
        func stopUpdates() async {
            updates.cancel()
            await updates.value
        }

        let speakers = Dictionary(transcript.segments.compactMap { segment in segment.speaker.map { (segment.id, $0) } }, uniquingKeysWith: { _, new in new })
        await brain.applySpeakers(speakers)
        do {
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
            var settled = false
            for _ in 0..<50 {
                if latest.value.last?.isLive == false { settled = true; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            if !settled, !latest.value.isEmpty { warnings.add("The last takeaway may be unfinished: the final summary pass didn't report back.") }
        } catch {
            await stopUpdates()
            throw error
        }
        await stopUpdates()
        let takeaways = latest.value
        if takeaways.isEmpty {
            warnings.add(earlierTakeaways.isEmpty
                ? "No takeaways could be written for this lecture; the transcript was imported without them."
                : "No new takeaways could be written; the takeaways shown are from before the interruption and may not cover the whole lecture.")
        }
        return takeaways
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
