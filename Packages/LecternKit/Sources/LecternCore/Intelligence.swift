import Foundation

// MARK: - Intelligence contract (implemented in LecternIntelligence as `LectureBrain`)
//
// The app feeds finalized transcript segments in; the brain emits updates out. The app's
// @MainActor view model owns the canonical `LectureSession` and applies `BrainUpdate`s to it.

public enum BrainActivity: Sendable, Hashable {
    case idle
    /// Rolling takeaways, the final pass, or the lecture summary.
    case summarizing
    /// Writing a "While you were away" recap.
    case recapping
    case expanding(takeawayID: UUID)
    case writingQuestion
    case grading
    case answering
}

public enum BrainUpdate: Sendable, Hashable {
    /// Full current list of takeaways, chronological. The last one may be `isLive`.
    case takeaways([Takeaway])
    /// Detected current slide (1-based), or nil if unknown. Automatic detection only ever moves
    /// forward from the current slide.
    case currentSlide(Int?)
    /// The lecture seems to have gone back to an earlier slide. The app offers a "Jump back?"
    /// suggestion; it must never switch on its own. `nil` withdraws a previous suggestion.
    case backtrackSuggestion(Int?)
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
    /// The session the brain works for, so model usage (API cost) can be attributed to it.
    public var sessionID: UUID?
    /// The slide the lecture was last on (`LectureSession.currentSlide`) when reopening; with the
    /// takeaways' slides it tells the brain how far into the deck the lecture got.
    public var currentSlide: Int?

    public init(sessionTitle: String, courseName: String?, deck: SlideDeck?, transcript: [TranscriptSegment], takeaways: [Takeaway], quizHistory: [QuizRecord], sessionID: UUID? = nil, currentSlide: Int? = nil) {
        self.sessionTitle = sessionTitle
        self.courseName = courseName
        self.deck = deck
        self.transcript = transcript
        self.takeaways = takeaways
        self.quizHistory = quizHistory
        self.sessionID = sessionID
        self.currentSlide = currentSlide
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

    /// The user picked another provider or model for a role: every call started from now on uses
    /// `providers` (calls already running finish on the old ones). Cards, chat and quiz state are
    /// kept.
    func update(providers: RoleProviders)

    /// Writes details for up to `limit` settled takeaways that have none (oldest first), as
    /// background work that gives way to anything someone is waiting for. Details arrive through
    /// `.takeaways` updates; cards that couldn't be done are reported in one `.error`. Cancelling
    /// stops after the current card.
    func enrichTakeaways(limit: Int) async

    /// Session clock ticks from the app (seconds of recording), used for the quiz timer.
    func tick(sessionTime: TimeInterval)

    /// "While you were away": what happened between two session times.
    func recap(from: TimeInterval, to: TimeInterval) async throws -> Recap

    /// Summary of the whole lecture for Review, written from the takeaways (and their details),
    /// quiz results and anything the lecturer flagged. Call after `finish()`; works equally for a
    /// lecture reopened from disk (everything it needs is in the `BrainContext`).
    func lectureSummary() async throws -> LectureSummary

    /// Waits until all scheduled summary work is done (import / batch mode).
    func waitUntilIdle() async

    /// Speaker labels arrived for earlier segments (lecturer vs. audience); used to weight
    /// student questions differently in summaries.
    func applySpeakers(_ labels: [UUID: SpeakerRole])

    /// The user changed the current slide manually (clicked a thumbnail, accepted a backtrack
    /// suggestion). Tracking continues forward from here.
    func setCurrentSlide(_ page: Int)

    /// A deck was added to a lecture that already has a brain (Add Deck during a live lecture or in
    /// Review). Later prompts, Ask and quizzes use it; slide tracking starts from here.
    func attachDeck(_ deck: SlideDeck, slides: (any SlideSearching)?) async
}

public extension LectureIntelligence {
    /// For brains without providers (scripted demo, test doubles): nothing to switch.
    func update(providers: RoleProviders) {}

    /// For brains whose cards come with details (scripted demo, test doubles).
    func enrichTakeaways(limit: Int) async {}
}

// MARK: - "While you were away"

/// Catch-up summary of a stretch of lecture the user missed (e.g. while Lectern was in the
/// background). Produced on demand by `LectureIntelligence.recap(from:to:)`.
public struct Recap: Codable, Sendable, Hashable {
    public var from: TimeInterval
    public var to: TimeInterval
    /// One-sentence headline, e.g. "Moved from 3-address code to genExpr for expression trees."
    public var headline: String
    /// 2–4 short bullets of what was covered, most important first.
    public var bullets: [String]
    /// Anything the lecturer flagged as important/administrative in that window
    /// ("this will be on the exam", "MP2 due Friday").
    public var flagged: [String]
    public var slides: [Int]

    public init(from: TimeInterval, to: TimeInterval, headline: String, bullets: [String], flagged: [String] = [], slides: [Int] = []) {
        self.from = from
        self.to = to
        self.headline = headline
        self.bullets = bullets
        self.flagged = flagged
        self.slides = slides
    }
}
