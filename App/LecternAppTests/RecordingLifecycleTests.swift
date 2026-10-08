import Foundation
import LecternCore
import Synchronization
import Testing
@testable import Lectern

/// Recording integrity (audit B01–B04, B46): the microphone chosen in Setup is the one recorded,
/// the words the recognizer flushes at stop are kept, a failed engine stops the clock, and a stop
/// during engine startup can't leave capture running. Ported from the audit's
/// `AuditRegressionTests` fixtures (fake engine, in-memory store).
@Suite(.serialized) @MainActor struct RecordingLifecycleTests {
    private static let lastWords = "Last words before pause."

    private func services(engine: FlushingEngine, store: MemoryStore = MemoryStore()) -> AppServices {
        var services = AppServices.demo
        services.makeTranscriptionEngine = { _ in engine }
        services.store = store
        return services
    }

    private func liveModel(_ services: AppServices) -> LiveSessionModel {
        LiveSessionModel(session: LectureSession(title: "Audit", status: .live), course: nil, mode: .live,
                         services: services, settings: AppSettings(), preferences: UIPreferences())
    }

    // MARK: B01

    @Test func setupMicrophoneReachesRecordingOptions() async throws {
        let engine = FlushingEngine()
        let app = AppModel(services: services(engine: engine), isDemo: true)
        app.showSetup()
        app.setup.changeInputDevice("usb")
        app.startLecture()
        try await until { engine.lastOptions != nil }
        #expect(engine.lastOptions?.inputDeviceID == "usb")
        app.liveSession?.pause()
    }

    @Test func systemDefaultMicrophoneThatSetupPreviewedIsRecorded() async throws {
        let engine = FlushingEngine()
        let app = AppModel(services: services(engine: engine), isDemo: true)
        app.showSetup()
        let previewed = app.setup.inputDeviceID
        #expect(previewed != nil, "Setup previews a concrete input (the system default unless one was chosen)")
        app.startLecture()
        try await until { engine.lastOptions != nil }
        #expect(engine.lastOptions?.inputDeviceID == previewed)
        // Resuming after a pause keeps listening to the same microphone.
        let model = try #require(app.liveSession)
        model.pause()
        try await until { !engine.isRunning }
        model.resume()
        try await until { engine.isRunning }
        #expect(engine.lastOptions?.inputDeviceID == previewed)
        model.pause()
    }

    // MARK: B02

    @Test func pauseRetainsFinalWordsFlushedByStop() async throws {
        let engine = FlushingEngine()
        let model = liveModel(services(engine: engine))
        model.start(deckURL: nil, inputDeviceID: nil)
        try await until { engine.isRunning }
        model.pause()
        try await until(timeout: .seconds(2)) { model.transcript.contains { $0.text == Self.lastWords } }
        #expect(model.transcript.contains { $0.text == Self.lastWords })
        await model.close()
    }

    @Test func finishSavesFinalWordsFlushedByStop() async throws {
        let engine = FlushingEngine()
        let store = MemoryStore()
        let model = liveModel(services(engine: engine, store: store))
        model.start(deckURL: nil, inputDeviceID: nil)
        try await until { engine.isRunning }
        model.finish()
        try await until(timeout: .seconds(3)) { await store.saved(model.id)?.transcript.contains { $0.text == Self.lastWords } == true }
        #expect(await store.saved(model.id)?.transcript.contains { $0.text == Self.lastWords } == true)
        await model.close()
    }

    // MARK: B03

    @Test func quitSavesWordsFlushedByStop() async throws {
        let engine = FlushingEngine()
        let store = MemoryStore()
        let app = AppModel(services: services(engine: engine, store: store), isDemo: true)
        app.showSetup()
        app.startLecture()
        try await until { engine.isRunning }
        let id = try #require(app.liveSession?.id)
        await app.prepareForQuit()
        #expect(!engine.isRunning, "quitting stops capture")
        let saved = await store.saved(id)
        #expect(saved?.transcript.contains { $0.text == Self.lastWords } == true)
        #expect(saved?.status == .live || saved?.status == .paused, "the lecture is offered as interrupted on relaunch")
    }

    @Test func quitDoesNotWaitForARecognizerThatNeverFinishesStopping() async throws {
        let engine = FlushingEngine(holdStop: true)
        let app = AppModel(services: services(engine: engine), isDemo: true)
        app.showSetup()
        app.startLecture()
        try await until { engine.isRunning }
        // A regression shows as a slow quit, not a hang: the stop is released after 3 s.
        let watchdog = Task { try? await Task.sleep(for: .seconds(3)); engine.releaseStop() }
        let started = ContinuousClock.now
        await app.prepareForQuit(drainLimit: .milliseconds(200))
        #expect(started.duration(to: .now) < .seconds(2), "quit waits for the drain only up to its limit")
        watchdog.cancel()
        engine.releaseStop()
    }

    // MARK: B04

    @Test func failedEngineStartStopsTheRecordingClock() async throws {
        let engine = FlushingEngine(failStart: true)
        let model = liveModel(services(engine: engine))
        model.start(deckURL: nil, inputDeviceID: nil)
        try await until { model.notice(for: .transcript)?.id == "engine" }
        #expect(model.recordingState == .paused)
        #expect(model.notice(for: .transcript)?.actionLabel == "Choose mic")
        await model.close()
    }

    @Test func engineFailureMidLectureStopsTheClockAndChooseMicRestartsCapture() async throws {
        let engine = FlushingEngine()
        let model = liveModel(services(engine: engine))
        model.start(deckURL: nil, inputDeviceID: "builtin")
        try await until { engine.isRunning }
        engine.fail(TranscriptionError.deviceGone)
        try await until { model.recordingState == .paused }
        #expect(model.recordingState == .paused)
        #expect(model.notice(for: .transcript)?.id == "engine")
        let pausedAt = model.elapsed
        try await Task.sleep(for: .milliseconds(1_100))
        #expect(model.elapsed == pausedAt, "the clock is stopped")
        model.switchInputDevice("usb")
        try await until { engine.isRunning }
        #expect(model.recordingState == .recording)
        #expect(engine.lastOptions?.inputDeviceID == "usb")
        #expect(model.notice(for: .transcript) == nil)
        model.pause()
        await model.close()
    }

    @Test func chooseMicWhileRecordingKeepsTheWordsAndSwitchesDevice() async throws {
        let engine = FlushingEngine()
        let model = liveModel(services(engine: engine))
        model.start(deckURL: nil, inputDeviceID: "builtin")
        try await until { engine.isRunning }
        model.switchInputDevice("usb")
        try await until { engine.lastOptions?.inputDeviceID == "usb" && engine.isRunning }
        #expect(engine.lastOptions?.inputDeviceID == "usb")
        #expect(model.transcript.contains { $0.text == Self.lastWords }, "the first device's last words were flushed")
        #expect(model.recordingState == .recording)
        model.pause()
        await model.close()
    }

    // MARK: P06

    @Test func speakerRelabelRegroupsOnlyTheTailAndMatchesAFullRebuild() {
        var generator = SeededGenerator(seed: 42)
        for _ in 0..<200 {
            var transcript: [TranscriptSegment] = []
            var t: TimeInterval = 0
            for _ in 0..<Int.random(in: 1...40, using: &generator) {
                t += Double.random(in: 0...3, using: &generator)
                let words = Int.random(in: 1...30, using: &generator)
                let speaker: SpeakerRole? = [nil, .lecturer, .audience(index: 1)].randomElement(using: &generator)!
                transcript.append(TranscriptSegment(text: String(repeating: "word ", count: words), start: t, end: t + 1, isFinal: true, speaker: speaker))
                t += 1
            }
            let pauses = (0..<Int.random(in: 0...3, using: &generator)).map { _ in Double.random(in: 0...t, using: &generator) }
            let before = LiveSessionModel.paragraphs(from: transcript, pauses: pauses)
            // Relabel a few recent segments, as diarization does.
            let first = Int.random(in: max(0, transcript.count - 6)..<transcript.count, using: &generator)
            for i in first..<transcript.count where Bool.random(using: &generator) {
                transcript[i].speaker = [SpeakerRole.lecturer, .audience(index: 1)].randomElement(using: &generator)!
            }
            let regrouped = LiveSessionModel.regroup(before, transcript: transcript, pauses: pauses, from: transcript[first].id)
            #expect(regrouped == LiveSessionModel.paragraphs(from: transcript, pauses: pauses))
            let unchanged = before.prefix { p in !p.segments.contains { $0.id == transcript[first].id } }.dropLast()
            #expect(Array(regrouped.prefix(unchanged.count)) == Array(unchanged), "earlier paragraphs keep their identity")
        }
    }

    // MARK: B46

    @Test func pauseDuringEngineStartupLeavesNothingRunning() async throws {
        let engine = FlushingEngine(holdStart: true)
        let model = liveModel(services(engine: engine))
        model.start(deckURL: nil, inputDeviceID: nil)
        try await until { engine.isHoldingStart }
        model.pause()
        try await Task.sleep(for: .milliseconds(50))
        engine.releaseStart()
        try await until { engine.startReturned }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!engine.isRunning, "a start that finishes after Pause must be stopped")
        #expect(model.recordingState == .paused)
        await model.close()
    }
}

// MARK: - Helpers

private enum TranscriptionError: Error { case deviceGone }

/// Deterministic randomness for the regrouping property test.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
private func until(timeout: Duration = .seconds(1), _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        if ContinuousClock.now > deadline { return }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Like a real recognizer: the last sentence is still volatile while recording and is only
/// emitted as `.final` by `stop()`, which then finishes the stream.
nonisolated private final class FlushingEngine: TranscriptionEngine, Sendable {
    private struct State {
        var options: TranscriptionOptions?
        var continuation: AsyncThrowingStream<TranscriptionEvent, Error>.Continuation?
        var holding: CheckedContinuation<Void, Never>?
        var isHoldingStart = false
        var startReturned = false
        var stopHolding: CheckedContinuation<Void, Never>?
    }

    let engineID = TranscriptionEngineID.parakeet
    private let failStart: Bool
    private let holdStart: Bool
    private let holdStop: Bool
    private let state = Mutex(State())

    init(failStart: Bool = false, holdStart: Bool = false, holdStop: Bool = false) {
        self.failStart = failStart
        self.holdStart = holdStart
        self.holdStop = holdStop
    }

    var lastOptions: TranscriptionOptions? { state.withLock { $0.options } }
    var isRunning: Bool { state.withLock { $0.continuation != nil } }
    var isHoldingStart: Bool { state.withLock { $0.isHoldingStart } }
    var startReturned: Bool { state.withLock { $0.startReturned } }

    /// The device died mid-lecture: the stream ends with `error`.
    func fail(_ error: any Error) {
        let continuation = state.withLock { s in defer { s.continuation = nil }; return s.continuation }
        continuation?.finish(throwing: error)
    }

    func releaseStart() {
        let waiting = state.withLock { s in defer { s.holding = nil }; return s.holding }
        waiting?.resume()
    }

    func releaseStop() {
        let waiting = state.withLock { s in defer { s.stopHolding = nil }; return s.stopHolding }
        waiting?.resume()
    }

    func readiness() async -> EngineReadiness { .ready }
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws { progress(1) }

    func start(options: TranscriptionOptions) async throws -> AsyncThrowingStream<TranscriptionEvent, Error> {
        if holdStart {
            await withCheckedContinuation { c in state.withLock { $0.holding = c; $0.isHoldingStart = true } }
        }
        if failStart { throw CocoaError(.fileReadNoPermission) }
        let (stream, continuation) = AsyncThrowingStream<TranscriptionEvent, Error>.makeStream()
        state.withLock { $0.options = options; $0.continuation = continuation; $0.startReturned = true }
        continuation.yield(.volatile(TranscriptSegment(text: "Last words before pause.", start: options.timeOffset, end: options.timeOffset + 1, isFinal: false)))
        return stream
    }

    func stop() async {
        if holdStop { await withCheckedContinuation { c in state.withLock { $0.stopHolding = c } } }
        let continuation = state.withLock { s in defer { s.continuation = nil }; return s.continuation }
        let offset = lastOptions?.timeOffset ?? 0
        continuation?.yield(.final(TranscriptSegment(text: "Last words before pause.", start: offset, end: offset + 1, isFinal: true)))
        continuation?.finish()
    }

    func transcribeFile(at url: URL, options: TranscriptionOptions) async throws -> AsyncThrowingStream<TranscriptionEvent, Error> {
        try await start(options: options)
    }
}

private actor MemoryStore: SessionStoring {
    private var sessions: [UUID: LectureSession] = [:]
    func loadCourses() async throws -> [Course] { [] }
    func saveCourses(_ courses: [Course]) async throws {}
    func loadSessions() async throws -> [LectureSession] { Array(sessions.values) }
    func loadSession(id: UUID) async throws -> LectureSession {
        guard let s = sessions[id] else { throw CocoaError(.fileNoSuchFile) }
        return s
    }
    func save(_ session: LectureSession) async throws { sessions[session.id] = session }
    func delete(sessionID: UUID) async throws { sessions[sessionID] = nil }
    func folder(for sessionID: UUID) async throws -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("lectern-recording-tests") }
    func importSlides(from url: URL, into sessionID: UUID) async throws -> String { "slides.pdf" }
    func loadCourseChat(courseID: UUID) async throws -> [CourseAnswer] { [] }
    func saveCourseChat(_ answers: [CourseAnswer], courseID: UUID) async throws {}
    func saved(_ id: UUID) -> LectureSession? { sessions[id] }
}
