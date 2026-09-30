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

    /// `likelySlide(forTranscript:near:)` at a known transcript time (seconds of recording, pauses
    /// excluded). Evidence over time (confirming a leap, stepping through build slides) is measured
    /// on this clock, so tracking behaves the same live, sped up, or during an import.
    func likelySlide(forTranscript text: String, near: Int?, sessionTime: TimeInterval) -> Int?

    /// `backtrackCandidate(forTranscript:current:)` at a known transcript time.
    func backtrackCandidate(forTranscript text: String, current: Int, sessionTime: TimeInterval) -> Int?
}

public extension SlideSearching {
    /// Default for implementations without temporal evidence: the time is ignored.
    func likelySlide(forTranscript text: String, near: Int?, sessionTime: TimeInterval) -> Int? {
        likelySlide(forTranscript: text, near: near)
    }

    func backtrackCandidate(forTranscript text: String, current: Int, sessionTime: TimeInterval) -> Int? {
        backtrackCandidate(forTranscript: text, current: current)
    }
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
    /// Correct misheard course jargon ("gen expression" → `genExpr`) using the lecture's slides.
    public var fixesJargonFromSlides: Bool
    /// Optional monthly spending cap for cloud APIs, in US dollars. Once this month's spend reaches
    /// it, cloud roles fall back to the on-device model. `nil` means no cap.
    public var monthlyCloudCapUSD: Double?

    public init(
        providers: [LLMRole: ProviderConfig] = AppSettings.defaultProviders,
        transcriptionEngine: TranscriptionEngineID = .parakeet,
        inputDeviceID: String? = nil,
        vocabulary: [String] = [],
        quiz: QuizSettings = .init(),
        summaryIntervalSeconds: Double = 150,
        hasCompletedOnboarding: Bool = false,
        fixesJargonFromSlides: Bool = true,
        monthlyCloudCapUSD: Double? = nil
    ) {
        self.providers = providers
        self.transcriptionEngine = transcriptionEngine
        self.inputDeviceID = inputDeviceID
        self.vocabulary = vocabulary
        self.quiz = quiz
        self.summaryIntervalSeconds = summaryIntervalSeconds
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.fixesJargonFromSlides = fixesJargonFromSlides
        self.monthlyCloudCapUSD = monthlyCloudCapUSD
    }

    enum CodingKeys: String, CodingKey {
        case providers, transcriptionEngine, inputDeviceID, vocabulary, quiz, summaryIntervalSeconds, hasCompletedOnboarding
        case fixesJargonFromSlides, monthlyCloudCapUSD
    }

    /// The original fields decode strictly; the fields added later decode tolerantly (missing or
    /// unreadable → their defaults), so saved settings from an older build keep loading.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providers = try c.decode([LLMRole: ProviderConfig].self, forKey: .providers)
        transcriptionEngine = try c.decode(TranscriptionEngineID.self, forKey: .transcriptionEngine)
        inputDeviceID = try c.decodeIfPresent(String.self, forKey: .inputDeviceID)
        vocabulary = try c.decode([String].self, forKey: .vocabulary)
        quiz = try c.decode(QuizSettings.self, forKey: .quiz)
        summaryIntervalSeconds = try c.decode(Double.self, forKey: .summaryIntervalSeconds)
        hasCompletedOnboarding = try c.decode(Bool.self, forKey: .hasCompletedOnboarding)
        fixesJargonFromSlides = ((try? c.decodeIfPresent(Bool.self, forKey: .fixesJargonFromSlides)) ?? nil) ?? true
        monthlyCloudCapUSD = (try? c.decodeIfPresent(Double.self, forKey: .monthlyCloudCapUSD)) ?? nil
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
