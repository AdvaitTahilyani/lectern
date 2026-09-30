import Foundation

// MARK: - Courses & sessions

public struct Course: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    /// Short code shown in the sidebar, e.g. "CS 421".
    public var code: String
    /// Full name, e.g. "Programming Languages & Compilers".
    public var name: String
    /// Optional hex accent, e.g. "#5E5CE6".
    public var colorHex: String?
    public var createdAt: Date
    /// Folder where the user keeps this course's slide decks (e.g. "~/Documents/CS 426 Lecture
    /// Slides"). Setup suggests the next deck from it.
    public var slidesFolder: URL?

    public init(id: UUID = UUID(), code: String, name: String, colorHex: String? = nil, createdAt: Date = .now, slidesFolder: URL? = nil) {
        self.id = id
        self.code = code
        self.name = name
        self.colorHex = colorHex
        self.createdAt = createdAt
        self.slidesFolder = slidesFolder
    }

    enum CodingKeys: String, CodingKey {
        case id, code, name, colorHex, createdAt, slidesFolder
    }

    /// The original fields decode strictly; `slidesFolder` (added later) decodes tolerantly
    /// (missing or unreadable → nil), so it can never cost a saved course.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        code = try c.decode(String.self, forKey: .code)
        name = try c.decode(String.self, forKey: .name)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        slidesFolder = (try? c.decodeIfPresent(URL.self, forKey: .slidesFolder)) ?? nil
    }
}

public enum SessionSource: Codable, Sendable, Hashable {
    case live
    /// Imported from a local audio/video file.
    case audioFile(originalFileName: String)
    /// Imported from Illinois MediaSpace (Kaltura). `usedCaptions` = transcript came from the
    /// caption track instead of on-device transcription.
    case mediaSpace(entryID: String, pageURL: URL?, usedCaptions: Bool)
}

public enum SessionStatus: String, Codable, Sendable, Hashable {
    case draft      // set up, not started
    case live       // recording right now
    case paused
    case finished
    /// Being built from an imported recording (transcribing / summarizing).
    case importing
}

/// One lecture. Persisted as a single JSON document by `LecternStore`.
public struct LectureSession: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var courseID: UUID?
    public var title: String
    public var createdAt: Date
    public var startedAt: Date?
    public var endedAt: Date?
    /// Seconds of actual recording (excludes pauses).
    public var duration: TimeInterval
    public var status: SessionStatus

    /// Parsed slide deck, if the user attached one. The PDF file itself is stored next to the
    /// session document under `deck.fileName`.
    public var deck: SlideDeck?

    /// Finalized transcript segments in chronological order.
    public var transcript: [TranscriptSegment]
    public var takeaways: [Takeaway]
    public var quiz: [QuizRecord]
    public var chat: [ChatMessage]
    /// 1-based slide page number the lecture is currently (or was last) on.
    public var currentSlide: Int?
    /// Custom vocabulary (jargon) for this session, merged with the global list.
    public var vocabulary: [String]
    /// How the session was created. `nil` means recorded live.
    public var source: SessionSource?
    /// Model-written summary of the whole lecture, generated after it ends (or lazily when a
    /// finished lecture without one is reopened).
    public var summary: LectureSummary?

    public init(
        id: UUID = UUID(),
        courseID: UUID? = nil,
        title: String,
        createdAt: Date = .now,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        duration: TimeInterval = 0,
        status: SessionStatus = .draft,
        deck: SlideDeck? = nil,
        transcript: [TranscriptSegment] = [],
        takeaways: [Takeaway] = [],
        quiz: [QuizRecord] = [],
        chat: [ChatMessage] = [],
        currentSlide: Int? = nil,
        vocabulary: [String] = [],
        source: SessionSource? = nil,
        summary: LectureSummary? = nil
    ) {
        self.id = id
        self.courseID = courseID
        self.title = title
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.duration = duration
        self.status = status
        self.deck = deck
        self.transcript = transcript
        self.takeaways = takeaways
        self.quiz = quiz
        self.chat = chat
        self.currentSlide = currentSlide
        self.vocabulary = vocabulary
        self.source = source
        self.summary = summary
    }

    /// Plain transcript text, one paragraph per segment.
    public var transcriptText: String {
        transcript.map(\.text).joined(separator: "\n")
    }
}

// MARK: - Transcript

public struct TranscriptSegment: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var text: String
    /// Seconds since the session started recording (pauses excluded).
    public var start: TimeInterval
    public var end: TimeInterval
    /// `false` while the recognizer may still revise this text (a "volatile" hypothesis).
    public var isFinal: Bool
    /// Who is talking, from speaker diarization. `nil` until diarization has labeled the segment.
    public var speaker: SpeakerRole?
    /// What the recognizer heard, when `text` was corrected afterwards (course jargon fixed from
    /// the slide deck). `nil` means `text` is exactly what was heard.
    public var originalText: String?

    public init(id: UUID = UUID(), text: String, start: TimeInterval, end: TimeInterval, isFinal: Bool, speaker: SpeakerRole? = nil, originalText: String? = nil) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
        self.isFinal = isFinal
        self.speaker = speaker
        self.originalText = originalText
    }

    enum CodingKeys: String, CodingKey {
        case id, text, start, end, isFinal, speaker, originalText
    }

    /// The original fields decode strictly; `originalText` (added later) decodes tolerantly
    /// (missing or unreadable → nil), so it can never cost a saved segment.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        start = try c.decode(TimeInterval.self, forKey: .start)
        end = try c.decode(TimeInterval.self, forKey: .end)
        isFinal = try c.decode(Bool.self, forKey: .isFinal)
        speaker = try c.decodeIfPresent(SpeakerRole.self, forKey: .speaker)
        originalText = (try? c.decodeIfPresent(String.self, forKey: .originalText)) ?? nil
    }
}

/// Diarization result, collapsed to what matters in a lecture: the lecturer vs. everyone else.
/// The lecturer is the dominant speaker; other voices are audience (student questions/answers).
public enum SpeakerRole: Codable, Sendable, Hashable {
    case lecturer
    /// A non-lecturer voice; `index` distinguishes different audience speakers (1, 2, …).
    case audience(index: Int)

    public var isLecturer: Bool { self == .lecturer }
}

// MARK: - Slides

public struct SlideDeck: Codable, Sendable, Hashable {
    /// File name of the PDF inside the session's folder, e.g. "slides.pdf".
    public var fileName: String
    /// Original file name the user dropped in, for display.
    public var originalFileName: String
    public var title: String?
    public var pages: [SlidePage]

    public init(fileName: String, originalFileName: String, title: String?, pages: [SlidePage]) {
        self.fileName = fileName
        self.originalFileName = originalFileName
        self.title = title
        self.pages = pages
    }

    public func page(_ number: Int) -> SlidePage? {
        pages.first { $0.number == number }
    }
}

public struct SlidePage: Codable, Sendable, Identifiable, Hashable {
    /// 1-based page number; also the identity.
    public var number: Int
    /// Heuristic title (usually the first prominent line).
    public var title: String?
    /// All extracted text on the page (PDFKit text, or Vision OCR when the page is an image).
    public var text: String
    /// Presenter notes, when the deck came from a PPTX/Keynote file that had them.
    public var notes: String?

    public var id: Int { number }

    public init(number: Int, title: String?, text: String, notes: String? = nil) {
        self.number = number
        self.title = title
        self.text = text
        self.notes = notes
    }
}

// MARK: - Takeaways (topic segments)

public struct Takeaway: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    /// The adaptive ≤2-line summary shown on the card.
    public var summary: String
    /// Filled on demand when the user expands the card.
    public var detail: TakeawayDetail?
    public var start: TimeInterval
    public var end: TimeInterval
    /// 1-based slide pages this topic covered.
    public var slidePages: [Int]
    /// `true` for the topic currently being lectured (summary still being refined).
    public var isLive: Bool
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        summary: String,
        detail: TakeawayDetail? = nil,
        start: TimeInterval,
        end: TimeInterval,
        slidePages: [Int] = [],
        isLive: Bool,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.detail = detail
        self.start = start
        self.end = end
        self.slidePages = slidePages
        self.isLive = isLive
        self.updatedAt = updatedAt
    }
}

public struct TakeawayDetail: Codable, Sendable, Hashable {
    /// Markdown-free bullet points, each one sentence or two.
    public var bullets: [String]
    public var keyTerms: [KeyTerm]
    /// Optional worked example / intuition paragraph.
    public var example: String?
    public var generatedAt: Date

    public init(bullets: [String], keyTerms: [KeyTerm], example: String? = nil, generatedAt: Date = .now) {
        self.bullets = bullets
        self.keyTerms = keyTerms
        self.example = example
        self.generatedAt = generatedAt
    }
}

public struct KeyTerm: Codable, Sendable, Hashable, Identifiable {
    public var term: String
    public var definition: String
    public var id: String { term }

    public init(term: String, definition: String) {
        self.term = term
        self.definition = definition
    }
}

// MARK: - Quiz

public struct QuizQuestion: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: Codable, Sendable, Hashable {
        case multipleChoice(options: [String], correctIndex: Int)
        case shortAnswer(referenceAnswer: String)
    }

    public var id: UUID
    public var prompt: String
    public var kind: Kind
    /// The concept being tested, e.g. "FIRST sets". Used to ask a different follow-up on the same concept.
    public var concept: String
    public var sourceSlides: [Int]
    /// Transcript time range the question was generated from.
    public var sourceStart: TimeInterval?
    public var sourceEnd: TimeInterval?
    /// If this question is a follow-up after a wrong answer, the question it follows.
    public var followUpOf: UUID?
    public var createdAt: Date
    /// Why the correct answer is right, from the question writer (multiple choice). Lets feedback
    /// written after the session is reopened use the same reasoning.
    public var explanation: String?
    /// The material the question was written from, so grading and follow-ups after a reopen see
    /// exactly what the writer saw. `nil` for questions saved before this was recorded.
    public var grounding: QuizGrounding?

    public init(
        id: UUID = UUID(),
        prompt: String,
        kind: Kind,
        concept: String,
        sourceSlides: [Int] = [],
        sourceStart: TimeInterval? = nil,
        sourceEnd: TimeInterval? = nil,
        followUpOf: UUID? = nil,
        createdAt: Date = .now,
        explanation: String? = nil,
        grounding: QuizGrounding? = nil
    ) {
        self.id = id
        self.prompt = prompt
        self.kind = kind
        self.concept = concept
        self.sourceSlides = sourceSlides
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.followUpOf = followUpOf
        self.createdAt = createdAt
        self.explanation = explanation
        self.grounding = grounding
    }

    enum CodingKeys: String, CodingKey {
        case id, prompt, kind, concept, sourceSlides, sourceStart, sourceEnd, followUpOf, createdAt, explanation, grounding
    }

    /// The original fields decode strictly; the optional grounding fields added later decode
    /// tolerantly (missing or unreadable → nil), so they can never cost a saved quiz record.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        prompt = try c.decode(String.self, forKey: .prompt)
        kind = try c.decode(Kind.self, forKey: .kind)
        concept = try c.decode(String.self, forKey: .concept)
        sourceSlides = try c.decodeIfPresent([Int].self, forKey: .sourceSlides) ?? []
        sourceStart = try c.decodeIfPresent(TimeInterval.self, forKey: .sourceStart)
        sourceEnd = try c.decodeIfPresent(TimeInterval.self, forKey: .sourceEnd)
        followUpOf = try c.decodeIfPresent(UUID.self, forKey: .followUpOf)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        explanation = (try? c.decodeIfPresent(String.self, forKey: .explanation)) ?? nil
        grounding = (try? c.decodeIfPresent(QuizGrounding.self, forKey: .grounding)) ?? nil
    }
}

/// What a quiz question was written from: the topic and summary it was about and the slides whose
/// text was shown to the writer. The transcript comes from `QuizQuestion.sourceStart`/`sourceEnd`.
public struct QuizGrounding: Codable, Sendable, Hashable {
    public var topic: String
    public var summary: String
    public var slides: [Int]

    public init(topic: String, summary: String, slides: [Int] = []) {
        self.topic = topic
        self.summary = summary
        self.slides = slides
    }
}

public struct QuizGrade: Codable, Sendable, Hashable {
    public var isCorrect: Bool
    /// Short feedback. When wrong: a concise explanation grounded in slides/transcript.
    public var feedback: String
    public var citations: [Citation]

    public init(isCorrect: Bool, feedback: String, citations: [Citation] = []) {
        self.isCorrect = isCorrect
        self.feedback = feedback
        self.citations = citations
    }
}

public enum QuizOutcome: String, Codable, Sendable, Hashable {
    case correct, incorrect, skipped
}

/// A question plus what happened to it. Persisted in the session.
public struct QuizRecord: Codable, Sendable, Identifiable, Hashable {
    public var question: QuizQuestion
    /// For MCQ: the option index as a string ("2"); for short answer: the typed text.
    public var answer: String?
    public var grade: QuizGrade?
    public var outcome: QuizOutcome?
    public var askedAt: TimeInterval   // session time
    public var answeredAt: Date?

    public var id: UUID { question.id }

    public init(question: QuizQuestion, answer: String? = nil, grade: QuizGrade? = nil, outcome: QuizOutcome? = nil, askedAt: TimeInterval, answeredAt: Date? = nil) {
        self.question = question
        self.answer = answer
        self.grade = grade
        self.outcome = outcome
        self.askedAt = askedAt
        self.answeredAt = answeredAt
    }
}

// MARK: - Ask (chat)

public enum Citation: Codable, Sendable, Hashable {
    /// 1-based slide page.
    case slide(Int)
    /// Session time in seconds.
    case time(TimeInterval)
}

public struct ChatMessage: Codable, Sendable, Identifiable, Hashable {
    public enum Role: String, Codable, Sendable, Hashable { case user, assistant }

    public var id: UUID
    public var role: Role
    /// For assistant messages, text may contain inline citation markers "[S12]" (slide 12) and
    /// "[T14:32]" (timestamp). `CitationParser` extracts them.
    public var text: String
    public var citations: [Citation]
    public var createdAt: Date

    public init(id: UUID = UUID(), role: Role, text: String, citations: [Citation] = [], createdAt: Date = .now) {
        self.id = id
        self.role = role
        self.text = text
        self.citations = citations
        self.createdAt = createdAt
    }
}
