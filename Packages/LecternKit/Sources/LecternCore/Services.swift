import Foundation

// MARK: - Slides contract (implemented in LecternSlides)

public struct SlideHit: Sendable, Hashable {
    public var page: Int
    /// Relevance score, higher is better. Not comparable across queries.
    public var score: Double
    /// The most relevant excerpt of the page text.
    public var excerpt: String

    public init(page: Int, score: Double, excerpt: String) {
        self.page = page
        self.score = score
        self.excerpt = excerpt
    }
}

public protocol SlideIngesting: Sendable {
    /// Parses a PDF (text via PDFKit, Vision OCR fallback for image-only pages). `progress` is 0...1.
    func ingest(pdfAt url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> SlideDeck
}

/// Retrieval over a deck's pages. Built once per session.
public protocol SlideSearching: Sendable {
    func search(_ query: String, limit: Int) -> [SlideHit]
    /// Best guess of which slide the given recent transcript text is about, or nil if unclear.
    /// `near` is the previous current slide (lectures mostly move forward by 0–2 pages).
    /// **Never returns a page before `near`**: automatic tracking only moves forward.
    func likelySlide(forTranscript text: String, near: Int?) -> Int?

    /// An earlier slide the lecture appears to have returned to, backed by strong, sustained
    /// evidence — surfaced to the user as a suggestion only, never applied automatically.
    /// Returns nil when there's no convincing backward candidate.
    func backtrackCandidate(forTranscript text: String, current: Int) -> Int?
}

public extension SlideSearching {
    func backtrackCandidate(forTranscript text: String, current: Int) -> Int? { nil }
}

// MARK: - Persistence contract (implemented in LecternStore)

public protocol SessionStoring: Sendable {
    func loadCourses() async throws -> [Course]
    func saveCourses(_ courses: [Course]) async throws

    /// All sessions, newest first. Implementations may return lightweight copies.
    func loadSessions() async throws -> [LectureSession]
    func loadSession(id: UUID) async throws -> LectureSession
    func save(_ session: LectureSession) async throws
    func delete(sessionID: UUID) async throws

    /// Folder holding the session's files (slides PDF, etc.). Created on demand.
    func folder(for sessionID: UUID) async throws -> URL
    /// Copies a PDF into the session folder, returns the stored file name.
    func importSlides(from url: URL, into sessionID: UUID) async throws -> String

    /// Course-wide Ask history (oldest first).
    func loadCourseChat(courseID: UUID) async throws -> [CourseAnswer]
    func saveCourseChat(_ answers: [CourseAnswer], courseID: UUID) async throws
}

public extension SessionStoring {
    func loadCourseChat(courseID: UUID) async throws -> [CourseAnswer] { [] }
    func saveCourseChat(_ answers: [CourseAnswer], courseID: UUID) async throws {}
}

// MARK: - Settings

public struct QuizSettings: Codable, Sendable, Hashable {
    public var enabled: Bool
    /// Minutes between quiz pings.
    public var intervalMinutes: Double
    public var allowMultipleChoice: Bool
    public var allowShortAnswer: Bool
    public enum Difficulty: String, Codable, Sendable, CaseIterable, Hashable { case gentle, standard, challenging }
    public var difficulty: Difficulty

    public init(enabled: Bool = true, intervalMinutes: Double = 8, allowMultipleChoice: Bool = true, allowShortAnswer: Bool = true, difficulty: Difficulty = .standard) {
        self.enabled = enabled
        self.intervalMinutes = intervalMinutes
        self.allowMultipleChoice = allowMultipleChoice
        self.allowShortAnswer = allowShortAnswer
        self.difficulty = difficulty
    }
}

public struct AppSettings: Codable, Sendable, Hashable {
    public var providers: [LLMRole: ProviderConfig]
    public var transcriptionEngine: TranscriptionEngineID
    public var inputDeviceID: String?
    /// Global jargon list, merged with per-session vocabulary.
    public var vocabulary: [String]
    public var quiz: QuizSettings
    /// Seconds of new transcript between rolling-summary updates.
    public var summaryIntervalSeconds: Double
    public var hasCompletedOnboarding: Bool

    public init(
        providers: [LLMRole: ProviderConfig] = AppSettings.defaultProviders,
        transcriptionEngine: TranscriptionEngineID = .parakeet,
        inputDeviceID: String? = nil,
        vocabulary: [String] = [],
        quiz: QuizSettings = .init(),
        summaryIntervalSeconds: Double = 150,
        hasCompletedOnboarding: Bool = false
    ) {
        self.providers = providers
        self.transcriptionEngine = transcriptionEngine
        self.inputDeviceID = inputDeviceID
        self.vocabulary = vocabulary
        self.quiz = quiz
        self.summaryIntervalSeconds = summaryIntervalSeconds
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }

    /// Default on-device model repo. Updated from docs/research/local-llm.md.
    public static let defaultOnDeviceModel = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"

    public static var defaultProviders: [LLMRole: ProviderConfig] {
        let local = ProviderConfig(kind: .onDevice, model: defaultOnDeviceModel)
        return [.summaries: local, .quizzes: local, .ask: local]
    }

    public func provider(for role: LLMRole) -> ProviderConfig {
        providers[role] ?? ProviderConfig(kind: .onDevice, model: Self.defaultOnDeviceModel)
    }
}
