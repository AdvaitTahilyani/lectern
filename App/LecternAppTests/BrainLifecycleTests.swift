import Foundation
import LecternCore
import Synchronization
import Testing
@testable import Lectern

/// The lecture's brain after recording stops (audit P01, B44) and when providers change (B17).
@Suite(.serialized) @MainActor struct BrainLifecycleTests {
    private func services(brain: HeldBrain, providers: (@Sendable (AppSettings, UUID?) -> RoleProviders)? = nil) -> AppServices {
        var services = AppServices.demo
        services.makeTranscriptionEngine = { _ in QuietEngine() }
        services.makeBrain = { _, _, _ in brain }
        services.makeRoleProviders = providers
        return services
    }

    private func liveModel(_ services: AppServices, settings: AppSettings = AppSettings()) -> LiveSessionModel {
        LiveSessionModel(session: LectureSession(title: "Brain", status: .live), course: nil, mode: .live,
                         services: services, settings: settings, preferences: UIPreferences())
    }

    // MARK: P01

    @Test func finishReleasesTheLectureBeforeTheModelWorkEnds() async throws {
        let brain = HeldBrain()
        let model = liveModel(services(brain: brain))
        var released = false
        model.onFinished = { released = true }
        model.start(deckURL: nil, inputDeviceID: nil)
        model.finish()
        // The brain's final pass is still running (held), yet the lecture is no longer active.
        try await until { await brain.finishStarted }
        try await until { released }
        #expect(released)
        #expect(model.recordingState == .finished)
        #expect(model.summaryState == .writing)

        await brain.releaseFinish()
        try await until { model.summaryState == .ready }
        #expect(model.summaryState == .ready)
        // Card details come after the summary, as background work.
        try await until { await brain.enrichCalls == 1 }
        #expect(await brain.enrichCalls == 1)
        await model.close()
    }

    @Test func aLectureRecoveredAfterACrashFinishesLikeARecordedOne() async throws {
        let brain = HeldBrain()
        await brain.releaseFinish()
        let model = liveModel(services(brain: brain))
        var released = false
        model.onFinished = { released = true }
        model.finishWithoutRecording()
        try await until { model.summaryState == .ready }
        #expect(released)
        #expect(model.recordingState == .finished)
        #expect(await brain.finishStarted)
        await model.close()
    }

    // MARK: B17

    @Test func aProviderChangeReachesTheOpenLecturesBrain() async throws {
        let brain = HeldBrain()
        let built = Mutex<[AppSettings]>([])
        let model = liveModel(services(brain: brain, providers: { settings, _ in
            built.withLock { $0.append(settings) }
            return RoleProviders(summaries: NamedProvider(name: "new"), quizzes: NamedProvider(name: "new"), ask: NamedProvider(name: "new"))
        }))
        model.start(deckURL: nil, inputDeviceID: nil)

        // A change that doesn't touch providers leaves them alone.
        var settings = AppSettings()
        settings.quiz.intervalMinutes += 1
        model.applySettings(settings)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await brain.providerUpdates.isEmpty)

        settings.providers[.ask] = ProviderConfig(kind: .localServer, model: "gemma4:12b")
        model.applySettings(settings)
        try await until { await !brain.providerUpdates.isEmpty }
        #expect(await brain.providerUpdates == ["new"])
        #expect(built.withLock { $0.last?.provider(for: .ask).model } == "gemma4:12b")
        model.pause()
        await model.close()
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
private func until(timeout: Duration = .seconds(2), _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        if ContinuousClock.now > deadline { return }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// A recognizer that hears nothing.
nonisolated private final class QuietEngine: TranscriptionEngine, Sendable {
    let engineID = TranscriptionEngineID.parakeet
    private let continuation = Mutex<AsyncThrowingStream<TranscriptionEvent, Error>.Continuation?>(nil)

    func readiness() async -> EngineReadiness { .ready }
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws { progress(1) }

    func start(options: TranscriptionOptions) async throws -> AsyncThrowingStream<TranscriptionEvent, Error> {
        let (stream, c) = AsyncThrowingStream<TranscriptionEvent, Error>.makeStream()
        continuation.withLock { $0 = c }
        return stream
    }

    func stop() async {
        continuation.withLock { $0?.finish(); $0 = nil }
    }

    func transcribeFile(at url: URL, options: TranscriptionOptions) async throws -> AsyncThrowingStream<TranscriptionEvent, Error> {
        try await start(options: options)
    }
}

/// A provider identified by name (never called).
nonisolated private struct NamedProvider: LLMProvider {
    let kind = ProviderKind.localServer
    let name: String
    var model: String { name }
    func complete(_ request: LLMRequest) async throws -> LLMResponse { LLMResponse(text: "") }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> { AsyncThrowingStream { $0.finish() } }
    func healthCheck() async throws {}
}

/// A brain whose `finish()` waits until the test releases it, and which records provider changes
/// and enrichment requests.
private actor HeldBrain: LectureIntelligence {
    nonisolated let updates: AsyncStream<BrainUpdate>
    private let continuation: AsyncStream<BrainUpdate>.Continuation
    private(set) var finishStarted = false
    private var held: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private(set) var providerUpdates: [String] = []
    private(set) var enrichCalls = 0

    init() { (updates, continuation) = AsyncStream.makeStream() }

    func releaseFinish() {
        isReleased = true
        held?.resume()
        held = nil
    }

    func finish() async {
        finishStarted = true
        guard !isReleased else { return }
        await withCheckedContinuation { held = $0 }
    }

    func update(providers: RoleProviders) { providerUpdates.append(providers.ask.model) }
    func enrichTakeaways(limit: Int) async { enrichCalls += 1 }

    func lectureSummary() async throws -> LectureSummary {
        LectureSummary(overview: "Overview.")
    }

    func ingest(_ segment: TranscriptSegment) {}
    func expand(takeawayID: UUID) async throws -> TakeawayDetail { TakeawayDetail(bullets: [], keyTerms: []) }
    func makeQuestion(followUpOf: QuizQuestion?) async throws -> QuizQuestion { throw CancellationError() }
    func grade(_ question: QuizQuestion, answer: String) async throws -> QuizGrade { throw CancellationError() }
    func record(_ record: QuizRecord) {}
    nonisolated func ask(_ question: String, history: [ChatMessage]) -> AsyncThrowingStream<AskEvent, Error> { AsyncThrowingStream { $0.finish() } }
    func update(quiz: QuizSettings, summaryIntervalSeconds: Double) {}
    func tick(sessionTime: TimeInterval) {}
    func recap(from: TimeInterval, to: TimeInterval) async throws -> Recap { throw CancellationError() }
    func waitUntilIdle() async {}
    func applySpeakers(_ labels: [UUID: SpeakerRole]) {}
    func setCurrentSlide(_ page: Int) {}
    func attachDeck(_ deck: SlideDeck, slides: (any SlideSearching)?) async {}
}
