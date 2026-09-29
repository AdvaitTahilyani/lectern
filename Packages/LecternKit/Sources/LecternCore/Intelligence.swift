import Foundation

// MARK: - Intelligence contract (implemented in LecternIntelligence as `LectureBrain`)
//
// The app feeds finalized transcript segments in; the brain emits updates out. The app's
// @MainActor view model owns the canonical `LectureSession` and applies `BrainUpdate`s to it.

public enum BrainActivity: Sendable, Hashable {
    case idle
    case summarizing
    case expanding(takeawayID: UUID)
    case writingQuestion
    case grading
    case answering
}

public enum BrainUpdate: Sendable, Hashable {
    /// Full current list of takeaways, chronological. The last one may be `isLive`.
    case takeaways([Takeaway])
    /// Detected current slide (1-based), or nil if unknown.
    case currentSlide(Int?)
    /// A quiz question is ready to be offered to the user (the app shows a gentle ping).
    case quizReady(QuizQuestion)
    case activity(BrainActivity)
    /// Non-fatal error (e.g. a provider failed); the app shows it subtly.
    case error(String)
}

public enum AskEvent: Sendable, Hashable {
    case delta(String)
    /// Final message with parsed citations.
    case done(ChatMessage)
}

/// Snapshot the brain needs when it is created or when a session is reopened.
public struct BrainContext: Sendable {
    public var sessionTitle: String
    public var courseName: String?
    public var deck: SlideDeck?
    public var transcript: [TranscriptSegment]
    public var takeaways: [Takeaway]
    public var quizHistory: [QuizRecord]

    public init(sessionTitle: String, courseName: String?, deck: SlideDeck?, transcript: [TranscriptSegment], takeaways: [Takeaway], quizHistory: [QuizRecord]) {
        self.sessionTitle = sessionTitle
        self.courseName = courseName
        self.deck = deck
        self.transcript = transcript
        self.takeaways = takeaways
        self.quizHistory = quizHistory
    }
}

public protocol LectureIntelligence: Actor {
    /// Updates stream; one consumer (the live session view model).
    nonisolated var updates: AsyncStream<BrainUpdate> { get }

    /// Feed each finalized transcript segment as it arrives. Summaries/slide tracking are
    /// scheduled internally (debounced, never more than one LLM call per role in flight).
    func ingest(_ segment: TranscriptSegment)

    /// Called when recording stops: closes the live takeaway and runs a final summary pass.
    func finish() async

    /// Detailed summary for one takeaway (cached in the returned value; app persists it).
    func expand(takeawayID: UUID) async throws -> TakeawayDetail

    /// Generates a question now (also called internally on the quiz timer → `.quizReady`).
    /// `followUpOf`: when set, ask a *different* question on the same concept.
    func makeQuestion(followUpOf: QuizQuestion?) async throws -> QuizQuestion

    func grade(_ question: QuizQuestion, answer: String) async throws -> QuizGrade

    /// Records the outcome so future questions adapt (avoid repeats, revisit missed concepts).
    func record(_ record: QuizRecord)

    /// Streams an answer grounded in slides + transcript, with [S#]/[T mm:ss] citations.
    func ask(_ question: String, history: [ChatMessage]) -> AsyncThrowingStream<AskEvent, Error>

    /// Settings changes mid-session (quiz interval etc.).
    func update(quiz: QuizSettings, summaryIntervalSeconds: Double)

    /// Session clock ticks from the app (seconds of recording), used for the quiz timer.
    func tick(sessionTime: TimeInterval)
}
