import Foundation
import LecternCore
import Synchronization
import Testing
@testable import Lectern

/// A quiz ping stays until the user answers, snoozes, skips or dismisses it. Questions that arrive
/// meanwhile queue behind it instead of replacing it or being dropped.
@Suite(.serialized) @MainActor struct QuizQueueTests {
    private func makeModel(_ brain: QueueBrain) -> LiveSessionModel {
        var services = AppServices.demo
        services.makeTranscriptionEngine = { _ in SilentEngine() }
        services.makeBrain = { _, _, _ in brain }
        let model = LiveSessionModel(session: LectureSession(title: "Quiz", status: .live), course: nil, mode: .live,
                                     services: services, settings: AppSettings(), preferences: UIPreferences())
        model.start(deckURL: nil, inputDeviceID: nil)
        return model
    }

    private func question(_ prompt: String) -> QuizQuestion {
        QuizQuestion(prompt: prompt, kind: .multipleChoice(options: ["a", "b", "c", "d"], correctIndex: 1), concept: prompt)
    }

    @Test func questionsQueueBehindTheOneOnScreenAndNothingTimesOut() async throws {
        let brain = QueueBrain()
        let model = makeModel(brain)
        let (first, second, third) = (question("one"), question("two"), question("three"))
        brain.send(first); brain.send(second); brain.send(third)
        try await until { model.queuedQuizzes.count == 2 }
        #expect(model.quiz?.question.id == first.id)
        #expect(model.queuedQuizzes.map(\.id) == [second.id, third.id])
        // There is no countdown: nothing but the user's own action changes the card.
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.quiz?.question.id == first.id)

        model.skipQuiz()
        #expect(model.quiz?.question.id == second.id, "the next waiting question takes its place")
        #expect(model.queuedQuizzes.map(\.id) == [third.id])
        #expect(model.quizRecords.first { $0.id == first.id }?.outcome == .skipped)

        model.snoozeQuiz()
        #expect(model.quiz?.question.id == third.id, "a snoozed question is put away for later; the next one shows")
        model.skipQuiz()
        #expect(model.quiz == nil)
        #expect(model.queuedQuizzes.isEmpty)
        model.pause()
        await model.close()
    }

    @Test func aDuplicateOrMalformedQuestionIsNotQueued() async throws {
        let brain = QueueBrain()
        let model = makeModel(brain)
        let shown = question("shown")
        let broken = QuizQuestion(prompt: "broken", kind: .multipleChoice(options: ["a", "b"], correctIndex: 7), concept: "broken")
        brain.send(shown); brain.send(shown); brain.send(broken)
        try await until { model.quiz != nil }
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.quiz?.question.id == shown.id)
        #expect(model.queuedQuizzes.isEmpty)
        model.pause()
        await model.close()
    }

    @Test func theSinglePaneTierHoldsQuestionsAndWiderTiersShowThem() async throws {
        let brain = QueueBrain()
        let model = makeModel(brain)
        model.layoutTier = .single
        model.pane = .transcript
        brain.send(question("one"))
        try await until { model.queuedQuizzes.count == 1 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.quiz == nil, "a card would be out of place over the transcript pane")
        model.layoutTier = .two   // the window widened: the Takeaways are showing again
        #expect(model.quiz != nil)
        model.pause()
        await model.close()

        // `pane` is stale outside the single-pane tier and must not hold questions back there.
        let otherBrain = QueueBrain()
        let wide = makeModel(otherBrain)
        wide.pane = .slides
        otherBrain.send(question("two"))
        try await until { wide.quiz != nil }
        #expect(wide.quiz != nil)
        wide.pause()
        await wide.close()
    }

    @Test func theFollowUpIsRequestedOnlyAfterTheWrongAnswerWasRecorded() async throws {
        let brain = QueueBrain()
        let model = makeModel(brain)
        brain.send(question("one"))
        try await until { model.quiz != nil }
        model.selectOption(0)   // the correct option is 1
        try await until { model.quiz?.activeQuestion.prompt == "follow-up" }
        let log = brain.log
        let made = try #require(log.firstIndex(of: "makeQuestion"))
        #expect(log[..<made].contains("record:0"), "the brain must know what was answered before it writes the follow-up")
        model.pause()
        await model.close()
    }

    @Test func finishingTheLectureDropsQuestionsThatWereNeverShown() async throws {
        let brain = QueueBrain()
        let model = makeModel(brain)
        brain.send(question("one")); brain.send(question("two"))
        try await until { model.queuedQuizzes.count == 1 }
        model.finish()
        #expect(model.quiz == nil)
        #expect(model.queuedQuizzes.isEmpty)
        await model.close()
    }
}

@MainActor
private func until(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { return }
        try await Task.sleep(for: .milliseconds(10))
    }
}

nonisolated private final class SilentEngine: TranscriptionEngine, Sendable {
    let engineID = TranscriptionEngineID.parakeet
    private let continuation = Mutex<AsyncThrowingStream<TranscriptionEvent, Error>.Continuation?>(nil)
    func readiness() async -> EngineReadiness { .ready }
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws { progress(1) }
    func start(options: TranscriptionOptions) async throws -> AsyncThrowingStream<TranscriptionEvent, Error> {
        let (stream, c) = AsyncThrowingStream<TranscriptionEvent, Error>.makeStream()
        continuation.withLock { $0 = c }
        return stream
    }
    func stop() async { continuation.withLock { $0?.finish(); $0 = nil } }
    func transcribeFile(at url: URL, options: TranscriptionOptions) async throws -> AsyncThrowingStream<TranscriptionEvent, Error> { try await start(options: options) }
}

/// A brain that emits whatever quiz questions the test hands it.
private actor QueueBrain: LectureIntelligence {
    nonisolated let updates: AsyncStream<BrainUpdate>
    private nonisolated let continuation: AsyncStream<BrainUpdate>.Continuation

    init() { (updates, continuation) = AsyncStream.makeStream() }

    nonisolated func send(_ q: QuizQuestion) { continuation.yield(.quizReady(q)) }

    /// `record:<answer>` and `makeQuestion` entries, in the order the brain received them.
    private nonisolated let events = Mutex<[String]>([])
    nonisolated var log: [String] { events.withLock { $0 } }

    func finish() async {}
    func update(providers: RoleProviders) {}
    func enrichTakeaways(limit: Int) async {}
    func lectureSummary() async throws -> LectureSummary { LectureSummary(overview: "Overview.") }
    func ingest(_ segment: TranscriptSegment) {}
    func expand(takeawayID: UUID) async throws -> TakeawayDetail { TakeawayDetail(bullets: [], keyTerms: []) }
    func makeQuestion(followUpOf: QuizQuestion?) async throws -> QuizQuestion {
        events.withLock { $0.append("makeQuestion") }
        guard let original = followUpOf else { throw CancellationError() }
        return QuizQuestion(prompt: "follow-up", kind: .multipleChoice(options: ["a", "b", "c", "d"], correctIndex: 0), concept: original.concept)
    }
    func grade(_ question: QuizQuestion, answer: String) async throws -> QuizGrade { QuizGrade(isCorrect: false, feedback: "Not quite.", citations: []) }
    func record(_ record: QuizRecord) { events.withLock { $0.append("record:\(record.answer ?? "-")") } }
    nonisolated func ask(_ question: String, history: [ChatMessage]) -> AsyncThrowingStream<AskEvent, Error> { AsyncThrowingStream { $0.finish() } }
    func update(quiz: QuizSettings, summaryIntervalSeconds: Double) {}
    func tick(sessionTime: TimeInterval) {}
    func recap(from: TimeInterval, to: TimeInterval) async throws -> Recap { throw CancellationError() }
    func waitUntilIdle() async {}
    func applySpeakers(_ labels: [UUID: SpeakerRole]) {}
    func setCurrentSlide(_ page: Int) {}
    func attachDeck(_ deck: SlideDeck, slides: (any SlideSearching)?) async {}
}
