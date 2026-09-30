import Foundation
import LecternCore
import Testing
@testable import LecternImport

/// Progress stages in order, collected from the importer's callback.
private final class StageLog: @unchecked Sendable {
    private let lock = NSLock()   // guards `stored`
    private var stored: [ImportStage] = []
    var stages: [ImportStage] { lock.withLock { stored } }
    func append(_ stage: ImportStage) { lock.withLock { stored.append(stage) } }
}

/// Names of the working folders currently inside `scratch`.
private func workDirectories(in scratch: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
}

@Suite(.serialized, .enabled(if: SpeechFixture.isAvailable)) struct RecordingImporterTests {
    static let ids = (0..<4).map { _ in UUID() }

    static func segments() -> [TranscriptSegment] {
        ids.enumerated().map { index, id in
            TranscriptSegment(id: id, text: "Sentence number \(index) of the lecture.", start: Double(index) * 1.5, end: Double(index) * 1.5 + 1.5, isFinal: true)
        }
    }

    static func engine() -> FakeEngine {
        FakeEngine {
            segments().map { .final($0) }
                + [.level(0.5), .warning("Input was quiet"), .speakers([ids[0]: .lecturer, ids[2]: .audience(index: 1)])]
        }
    }

    @Test func importsAnAudioFileEndToEnd() async throws {
        let scratch = try makeTemporaryDirectory("scratch")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = try makeTemporaryDirectory("fixture")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try SpeechFixture.make(AudioExtractorTests.sentence, format: "m4a", in: directory)

        let engine = Self.engine()
        let brain = Box<FakeBrain?>(nil)
        let warnings = ProgressLog2()
        let importer = RecordingImporter(
            makeEngine: { engine },
            makeBrain: { context in
                let fake = FakeBrain()
                await fake.setContext(context)
                brain.value = fake
                return fake
            },
            scratchDirectory: scratch,
            onWarning: { warnings.append($0) }
        )

        let log = StageLog()
        let draft = LectureSession(title: "Week 4", status: .importing, deck: SlideDeck(fileName: "s.pdf", originalFileName: "s.pdf", title: nil, pages: []))
        let result = try await importer.importRecording(.file(audio), into: draft) { log.append($0) }

        // Session contents.
        #expect(result.id == draft.id && result.title == "Week 4")
        #expect(result.status == .finished)
        #expect(result.source == .audioFile(originalFileName: audio.lastPathComponent))
        #expect(result.transcript.map(\.text) == Self.segments().map(\.text))
        #expect(result.transcript.map(\.speaker) == [.lecturer, nil, .audience(index: 1), nil])
        #expect(result.takeaways.map(\.title) == ["Topic 1", "Topic 2"])   // the settled list, not the partial one
        let expected = try await AudioExtractorTests.sourceDuration(audio)
        #expect(abs(result.duration - expected) < 0.35)
        #expect(result.endedAt != nil && result.startedAt != nil)

        // What the engine saw: a 16 kHz mono WAV, diarization on.
        #expect(engine.formats.first?.sampleRate == 16_000 && engine.formats.first?.channelCount == 1)
        #expect(engine.options.first?.diarize == true)

        // What the brain saw.
        let fake = try #require(brain.value)
        #expect(await fake.context?.sessionTitle == "Week 4")
        #expect(await fake.context?.deck?.fileName == "s.pdf")
        #expect(await fake.ingested.map(\.id) == Self.ids)
        #expect(await fake.speakerLabels == [Self.ids[0]: .lecturer, Self.ids[2]: .audience(index: 1)])
        let idleWaits = await fake.idleWaits
        let finished = await fake.finished
        #expect(idleWaits == 1 && finished)

        // Non-fatal problems are surfaced.
        #expect(Set(warnings.values) == ["Input was quiet", "a summary pass failed once"])

        // Progress: stages in order, transcription reaches 1, ends finished.
        let stages = log.stages
        #expect(stages.first == .extractingAudio)
        #expect(stages.last == .finished)
        #expect(stages.contains(.transcribing(fraction: 1)))
        let transcribingIndex = try #require(stages.firstIndex(of: .transcribing(fraction: 0)))
        let summarizingIndex = try #require(stages.firstIndex(of: .summarizing(fraction: 0)))
        #expect(transcribingIndex < summarizingIndex)

        // Temporary files are gone.
        #expect(workDirectories(in: scratch).isEmpty)
    }

    @Test func mediaSpaceCaptionsSkipTranscriptionEntirely() async throws {
        let server = StubServer { url in
            if url.path.hasSuffix("/action/list") { return .text(KalturaClientTests.captionList) }
            if url.path.hasSuffix("/action/serveAsJson") { return .text(KalturaClientTests.captionTrack) }
            return .notFound
        }
        let engine = FakeEngine()
        let importer = RecordingImporter(makeEngine: { engine }, makeBrain: { _ in FakeBrain() }, kaltura: KalturaClient(session: server.session))
        let source = MediaSpaceSource(partnerID: "1329972", entryID: "1_oj3ppr67", ks: "djJ8KS-token_==", title: "Compiler Construction", pageURL: URL(string: "https://mediaspace.illinois.edu/media/t/1_oj3ppr67"))

        let result = try await importer.importRecording(.mediaSpace(source, preferCaptions: true), into: LectureSession(title: ""), progress: { _ in })

        #expect(engine.files.isEmpty)   // no ASR
        #expect(result.source == .mediaSpace(entryID: "1_oj3ppr67", pageURL: source.pageURL, usedCaptions: true))
        #expect(result.title == "Compiler Construction")
        #expect(result.transcript.count == 1)
        #expect(result.duration == 14.68)
        #expect(result.takeaways.count == 1 && result.status == .finished)
    }

    @Test func mediaSpaceWithoutCaptionsDownloadsAndTranscribes() async throws {
        let scratch = try makeTemporaryDirectory("scratch")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = try makeTemporaryDirectory("fixture")
        defer { try? FileManager.default.removeItem(at: directory) }
        let mp4 = try Data(contentsOf: SpeechFixture.make(AudioExtractorTests.sentence, format: "mp4", in: directory))
        let server = StubServer { url in
            if url.path.hasSuffix("/action/list") { return .text(#"{"totalCount":0,"objects":[]}"#) }
            if url.path.hasSuffix("/a.m3u8") { return .text(KalturaClientTests.masterPlaylist) }
            if url.path.hasSuffix("/a.mp4") { return .data(mp4) }
            return .notFound
        }
        let engine = Self.engine()
        let importer = RecordingImporter(makeEngine: { engine }, makeBrain: { _ in FakeBrain() }, kaltura: KalturaClient(session: server.session), scratchDirectory: scratch)
        let log = StageLog()
        let source = MediaSpaceSource(partnerID: "1329972", entryID: "1_oj3ppr67", ks: "djJ8KS-token_==", title: nil, pageURL: nil)

        let result = try await importer.importRecording(.mediaSpace(source, preferCaptions: true), into: LectureSession(title: "Lecture"), progress: { log.append($0) })

        #expect(result.source == .mediaSpace(entryID: "1_oj3ppr67", pageURL: nil, usedCaptions: false))
        #expect(engine.files.count == 1)
        #expect(log.stages.contains { if case .downloading(let f) = $0 { f == 1 } else { false } })
        #expect(workDirectories(in: scratch).isEmpty)
    }

    @Test func unreadableCaptionsFallBackToTranscribingTheAudio() async throws {
        let scratch = try makeTemporaryDirectory("scratch")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = try makeTemporaryDirectory("fixture")
        defer { try? FileManager.default.removeItem(at: directory) }
        let mp4 = try Data(contentsOf: SpeechFixture.make(AudioExtractorTests.sentence, format: "mp4", in: directory))
        let server = StubServer { url in
            if url.path.hasSuffix("/action/list") { return .text("<html>not json</html>") }
            if url.path.hasSuffix("/a.m3u8") { return .text(KalturaClientTests.masterPlaylist) }
            if url.path.hasSuffix("/a.mp4") { return .data(mp4) }
            return .notFound
        }
        let engine = Self.engine()
        let warnings = ProgressLog2()
        let importer = RecordingImporter(
            makeEngine: { engine }, makeBrain: { _ in FakeBrain() }, kaltura: KalturaClient(session: server.session),
            scratchDirectory: scratch, onWarning: { warnings.append($0) }
        )
        let source = MediaSpaceSource(partnerID: "1329972", entryID: "1_oj3ppr67", ks: "djJ8KS-token_==", title: nil, pageURL: nil)

        let result = try await importer.importRecording(.mediaSpace(source, preferCaptions: true), into: LectureSession(title: "Lecture"), progress: { _ in })

        #expect(engine.files.count == 1)
        #expect(result.source == .mediaSpace(entryID: "1_oj3ppr67", pageURL: nil, usedCaptions: false))
        #expect(warnings.values.contains { $0.contains("captions couldn't be read") })
    }

    @Test func anExpiredSessionStopsTheImportInsteadOfFallingBack() async throws {
        let server = StubServer { _ in StubResponse(status: 403) }
        let engine = FakeEngine()
        let importer = RecordingImporter(makeEngine: { engine }, makeBrain: { _ in FakeBrain() }, kaltura: KalturaClient(session: server.session))
        let source = MediaSpaceSource(partnerID: "1329972", entryID: "1_oj3ppr67", ks: "djJ8KS-token_==", title: nil, pageURL: nil)
        await #expect(throws: ImportError.sessionExpired) {
            try await importer.importRecording(.mediaSpace(source, preferCaptions: true), into: LectureSession(title: "x"), progress: { _ in })
        }
        #expect(engine.files.isEmpty)
    }

    @Test func aSilentRecordingIsReportedNotSummarized() async throws {
        let directory = try makeTemporaryDirectory("fixture")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try SpeechFixture.make("Hello.", format: "m4a", in: directory)
        let importer = RecordingImporter(makeEngine: { FakeEngine() }, makeBrain: { _ in FakeBrain() })
        await #expect(throws: ImportError.emptyTranscript) {
            try await importer.importRecording(.file(audio), into: LectureSession(title: "x"), progress: { _ in })
        }
    }

    @Test func anUnavailableEngineFailsClearly() async throws {
        let directory = try makeTemporaryDirectory("fixture")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try SpeechFixture.make("Hello.", format: "m4a", in: directory)
        let engine = FakeEngine()
        engine.readinessValue = .unavailable(reason: "models missing")
        let importer = RecordingImporter(makeEngine: { engine }, makeBrain: { _ in FakeBrain() })
        let error = await #expect(throws: ImportError.self) {
            try await importer.importRecording(.file(audio), into: LectureSession(title: "x"), progress: { _ in })
        }
        #expect(error?.errorDescription?.contains("models missing") == true)
    }

    @Test func cancellationStopsEverythingAndCleansUp() async throws {
        let scratch = try makeTemporaryDirectory("scratch")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = try makeTemporaryDirectory("fixture")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try SpeechFixture.make(AudioExtractorTests.sentence, format: "m4a", in: directory)
        let engine = FakeEngine()
        engine.hangs = true
        let importer = RecordingImporter(makeEngine: { engine }, makeBrain: { _ in FakeBrain() }, scratchDirectory: scratch)

        let task = Task {
            try await importer.importRecording(.file(audio), into: LectureSession(title: "x"), progress: { _ in })
        }
        while engine.files.isEmpty { try await Task.sleep(for: .milliseconds(10)) }   // engine is now "transcribing"
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(workDirectories(in: scratch).isEmpty)
        // The engine was told to stop.
        for _ in 0..<100 where engine.stopCalls == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.stopCalls >= 1)
    }

    @Test func cancellationDuringSummarizationDoesNotWaitForTheBrain() async throws {
        let directory = try makeTemporaryDirectory("fixture")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try SpeechFixture.make(AudioExtractorTests.sentence, format: "m4a", in: directory)
        let engine = Self.engine()
        let importer = RecordingImporter(makeEngine: { engine }, makeBrain: { _ in NeverIdleBrain() })

        let task = Task {
            try await importer.importRecording(.file(audio), into: LectureSession(title: "x"), progress: { _ in })
        }
        try await Task.sleep(for: .seconds(1.5))   // long enough to be waiting inside `waitUntilIdle`
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

/// A brain whose summary work never completes.
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
}

private final class ProgressLog2: @unchecked Sendable {
    private let lock = NSLock()   // guards `stored`
    private var stored: [String] = []
    var values: [String] { lock.withLock { stored } }
    func append(_ value: String) { lock.withLock { stored.append(value) } }
}

extension FakeBrain {
    func setContext(_ context: BrainContext) { self.context = context }
}
