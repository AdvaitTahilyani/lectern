import Foundation
import LecternCore
import Testing
@testable import LecternImport

/// Audit B08, B44 (import side), P12: a long import saves what it has done, can be finished from
/// that, reports non-fatal problems on the lecture, and stops its writers when it ends.
@Suite(.serialized) struct ImportCheckpointTests {
    private final class Saved: @unchecked Sendable {
        private let lock = NSLock()   // guards `stored`
        private var stored: [LectureSession] = []
        var all: [LectureSession] { lock.withLock { stored } }
        func append(_ session: LectureSession) { lock.withLock { stored.append(session) } }
    }

    private static let source = MediaSpaceSource(partnerID: "1329972", entryID: "1_oj3ppr67", ks: "djJ8KS-token_==", title: "Compiler Construction", pageURL: nil)

    private func captionServer() -> StubServer {
        StubServer { url in
            if url.path.hasSuffix("/action/list") { return .text(KalturaClientTests.captionList) }
            if url.path.hasSuffix("/action/serveAsJson") { return .text(KalturaClientTests.captionTrack) }
            return .notFound
        }
    }

    private func importer(
        server: StubServer, saved: Saved, brain: @escaping @Sendable () -> any LectureIntelligence = { FakeBrain() },
        interval: Duration = .zero, checkpoint: RecordingImporter.Checkpoint? = nil
    ) -> RecordingImporter {
        RecordingImporter(
            makeEngine: { FakeEngine() }, makeBrain: { _ in brain() }, kaltura: KalturaClient(session: server.session),
            checkpoint: checkpoint ?? { saved.append($0) }, checkpointInterval: interval
        )
    }

    @Test func theWholeTranscriptIsSavedBeforeSummarizingStarts() async throws {
        let saved = Saved()
        let result = try await importer(server: captionServer(), saved: saved)
            .importRecording(.mediaSpace(Self.source, preferCaptions: true), into: LectureSession(title: "", status: .importing), progress: { _ in })

        let checkpoints = saved.all
        let transcribed = try #require(checkpoints.first { $0.importRecord?.phase == .transcribed })
        #expect(transcribed.status == .importing)
        #expect(transcribed.transcript == result.transcript && !transcribed.transcript.isEmpty)
        #expect(transcribed.takeaways.isEmpty)
        #expect(result.status == .finished && !result.takeaways.isEmpty)
    }

    @Test func takeawaysAreCheckpointedAsTheyAreWritten() async throws {
        let saved = Saved()
        _ = try await importer(server: captionServer(), saved: saved)
            .importRecording(.mediaSpace(Self.source, preferCaptions: true), into: LectureSession(title: "", status: .importing), progress: { _ in })
        let summarizing = saved.all.filter { $0.importRecord?.phase == .summarizing }
        #expect(!summarizing.isEmpty)
        #expect(summarizing.allSatisfy { !$0.transcript.isEmpty && $0.status == .importing && !$0.takeaways.isEmpty })
    }

    @Test func aPartialTranscriptIsSavedWhileTheRecordingIsStillBeingTranscribed() async throws {
        guard SpeechFixture.isAvailable else { return }
        let directory = try makeTemporaryDirectory("checkpoint")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try SpeechFixture.make(AudioExtractorTests.sentence, format: "m4a", in: directory)
        let saved = Saved()
        let engine = RecordingImporterTests.engine()
        let importer = RecordingImporter(makeEngine: { engine }, makeBrain: { _ in FakeBrain() }, scratchDirectory: directory, checkpoint: { saved.append($0) }, checkpointInterval: .zero)
        _ = try await importer.importRecording(.file(audio), into: LectureSession(title: "x", status: .importing), progress: { _ in })

        let partials = saved.all.filter { $0.importRecord?.phase == .transcribing }
        #expect(partials.count >= 2)
        #expect(partials.map(\.transcript.count) == partials.map(\.transcript.count).sorted())
        #expect((partials.last?.transcript.count ?? 0) < RecordingImporterTests.segments().count + 1)
        #expect(partials.allSatisfy { $0.status == .importing && $0.duration == $0.transcript.last?.end })
    }

    @Test func aThrottledCheckpointDoesNotWriteOnEverySegment() async throws {
        let saved = Saved()
        _ = try await importer(server: captionServer(), saved: saved, interval: .seconds(3600))
            .importRecording(.mediaSpace(Self.source, preferCaptions: true), into: LectureSession(title: "", status: .importing), progress: { _ in })
        // Only the forced save at the end of transcription.
        #expect(saved.all.map { $0.importRecord?.phase } == [.transcribed])
    }

    @Test func anInterruptedImportCanBeFinishedFromItsCheckpointWithoutTheRecording() async throws {
        // The first run is cut off while summarizing, after the transcript was saved.
        let saved = Saved()
        let first = Task {
            try await importer(server: captionServer(), saved: saved, brain: { NeverIdleBrain() })
                .importRecording(.mediaSpace(Self.source, preferCaptions: true), into: LectureSession(title: "", status: .importing), progress: { _ in })
        }
        while saved.all.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        let checkpoint = try #require(saved.all.last)
        #expect(checkpoint.importRecord?.phase == .transcribed && !checkpoint.transcript.isEmpty)

        // The second run needs neither the media nor an engine.
        let engine = FakeEngine()
        let server = StubServer { _ in .notFound }
        let resuming = RecordingImporter(makeEngine: { engine }, makeBrain: { _ in FakeBrain() }, kaltura: KalturaClient(session: server.session))
        let result = try await resuming.resumeImport(checkpoint, progress: { _ in })

        #expect(result.status == .finished && !result.takeaways.isEmpty)
        #expect(result.transcript == checkpoint.transcript)
        #expect(engine.files.isEmpty && server.requests.isEmpty)
        #expect(result.importRecord == ImportRecord(phase: .complete, warnings: ["a summary pass failed once"]))   // the fake brain's one failed pass
    }

    @Test func resumingAPartialTranscriptSaysTheLectureIsIncomplete() async throws {
        var partial = LectureSession(title: "Long lecture", status: .importing)
        partial.transcript = [TranscriptSegment(text: "First part.", start: 0, end: 600, isFinal: true)]
        partial.importRecord = ImportRecord(phase: .transcribing, warnings: ["Input was quiet"])
        let resuming = RecordingImporter(makeEngine: { FakeEngine() }, makeBrain: { _ in FakeBrain() })
        let result = try await resuming.resumeImport(partial, progress: { _ in })

        let record = try #require(result.importRecord)
        #expect(record.phase == .complete)
        #expect(record.warnings.contains("Input was quiet"))
        #expect(record.warnings.contains { $0.contains("only the first 10 min") })
    }

    @Test func resumingThatWritesNothingKeepsTheEarlierTakeawaysAndSaysSo() async throws {
        var interrupted = LectureSession(title: "x", status: .importing)
        interrupted.transcript = [TranscriptSegment(text: "Some words.", start: 0, end: 5, isFinal: true)]
        interrupted.takeaways = [Takeaway(title: "Earlier", summary: "From before.", start: 0, end: 5, isLive: false)]
        interrupted.importRecord = ImportRecord(phase: .summarizing)
        let result = try await RecordingImporter(makeEngine: { FakeEngine() }, makeBrain: { _ in SilentBrain() })
            .resumeImport(interrupted, progress: { _ in })
        #expect(result.takeaways.map(\.title) == ["Earlier"])
        let warnings = try #require(result.importRecord?.warnings)
        #expect(warnings.contains { $0.contains("before the interruption") })
        #expect(!warnings.contains { $0.contains("No takeaways could be written") })
    }

    @Test func resumingWithoutATranscriptIsRefused() async {
        let resuming = RecordingImporter(makeEngine: { FakeEngine() }, makeBrain: { _ in FakeBrain() })
        await #expect(throws: ImportResumeError.nothingToResume) {
            try await resuming.resumeImport(LectureSession(title: "x", status: .importing), progress: { _ in })
        }
    }

    @Test func nonFatalProblemsAreKeptOnTheFinishedLecture() async throws {
        // FakeBrain reports "a summary pass failed once" while finishing.
        let result = try await importer(server: captionServer(), saved: Saved())
            .importRecording(.mediaSpace(Self.source, preferCaptions: true), into: LectureSession(title: "x", status: .importing), progress: { _ in })
        #expect(result.status == .finished)
        #expect(result.importRecord == ImportRecord(phase: .complete, warnings: ["a summary pass failed once"]))
    }

    @Test func aLectureWithNoTakeawaysSaysSo() async throws {
        let result = try await importer(server: captionServer(), saved: Saved(), brain: { SilentBrain() })
            .importRecording(.mediaSpace(Self.source, preferCaptions: true), into: LectureSession(title: "x", status: .importing), progress: { _ in })
        #expect(result.status == .finished && result.takeaways.isEmpty)
        #expect(result.importRecord?.warnings.contains { $0.contains("No takeaways") } == true)
        #expect(result.importRecord?.warnings.contains { $0.contains("may be unfinished") } == false)
    }

    @Test func aFailingCheckpointIsAWarningNotAFailure() async throws {
        struct DiskFull: LocalizedError { var errorDescription: String? { "disk full" } }
        let result = try await importer(server: captionServer(), saved: Saved(), checkpoint: { _ in throw DiskFull() })
            .importRecording(.mediaSpace(Self.source, preferCaptions: true), into: LectureSession(title: "x", status: .importing), progress: { _ in })
        #expect(result.status == .finished)
        #expect(result.importRecord?.warnings.contains { $0.contains("disk full") } == true)
    }

    @Test func noCheckpointIsWrittenAfterTheImportReturns() async throws {
        let count = Box(0)
        let slow: RecordingImporter.Checkpoint = { _ in
            try await Task.sleep(for: .milliseconds(40))
            count.value += 1
        }
        _ = try await importer(server: captionServer(), saved: Saved(), checkpoint: slow)
            .importRecording(.mediaSpace(Self.source, preferCaptions: true), into: LectureSession(title: "x", status: .importing), progress: { _ in })
        let atReturn = count.value
        try await Task.sleep(for: .milliseconds(300))
        #expect(count.value == atReturn)
    }

    // MARK: awaitCancellable (P12)

    @Test func cancellingTheWaitCancelsTheWorkBehindIt() async throws {
        let observed = Box<Bool?>(nil)
        let task = Task {
            try await awaitCancellable {
                do { try await Task.sleep(for: .seconds(3600)); observed.value = false } catch { observed.value = true }
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        for _ in 0..<100 where observed.value == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(observed.value == true)
    }
}

/// A brain that never produces a takeaway.
private actor SilentBrain: LectureIntelligence {
    nonisolated let updates = AsyncStream<BrainUpdate> { _ in }
    func ingest(_ segment: TranscriptSegment) {}
    func finish() async {}
    func waitUntilIdle() async {}
    func expand(takeawayID: UUID) async throws -> TakeawayDetail { throw CancellationError() }
    func makeQuestion(followUpOf: QuizQuestion?) async throws -> QuizQuestion { throw CancellationError() }
    func grade(_ question: QuizQuestion, answer: String) async throws -> QuizGrade { throw CancellationError() }
    func record(_ record: QuizRecord) {}
    nonisolated func ask(_ question: String, history: [ChatMessage]) -> AsyncThrowingStream<AskEvent, Error> { AsyncThrowingStream { $0.finish() } }
    func update(quiz: QuizSettings, summaryIntervalSeconds: Double) {}
    func tick(sessionTime: TimeInterval) {}
    func recap(from: TimeInterval, to: TimeInterval) async throws -> Recap { throw CancellationError() }
    func lectureSummary() async throws -> LectureSummary { throw CancellationError() }
    func applySpeakers(_ labels: [UUID: SpeakerRole]) {}
    func setCurrentSlide(_ page: Int) {}
    func attachDeck(_ deck: SlideDeck, slides: (any SlideSearching)?) async {}
}

/// A brain whose summary work never completes (as in `RecordingImporterTests`).
private actor NeverIdleBrain: LectureIntelligence {
    nonisolated let updates = AsyncStream<BrainUpdate> { _ in }
    func ingest(_ segment: TranscriptSegment) {}
    func finish() async {}
    func waitUntilIdle() async { try? await Task.sleep(for: .seconds(3600)) }
    func expand(takeawayID: UUID) async throws -> TakeawayDetail { throw CancellationError() }
    func makeQuestion(followUpOf: QuizQuestion?) async throws -> QuizQuestion { throw CancellationError() }
    func grade(_ question: QuizQuestion, answer: String) async throws -> QuizGrade { throw CancellationError() }
    func record(_ record: QuizRecord) {}
    nonisolated func ask(_ question: String, history: [ChatMessage]) -> AsyncThrowingStream<AskEvent, Error> { AsyncThrowingStream { $0.finish() } }
    func update(quiz: QuizSettings, summaryIntervalSeconds: Double) {}
    func tick(sessionTime: TimeInterval) {}
    func recap(from: TimeInterval, to: TimeInterval) async throws -> Recap { throw CancellationError() }
    func lectureSummary() async throws -> LectureSummary { throw CancellationError() }
    func applySpeakers(_ labels: [UUID: SpeakerRole]) {}
    func setCurrentSlide(_ page: Int) {}
    func attachDeck(_ deck: SlideDeck, slides: (any SlideSearching)?) async {}
}
