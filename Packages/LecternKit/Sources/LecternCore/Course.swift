import Foundation

// MARK: - Course-wide Ask (implemented in LecternIntelligence as `CourseAssistant`)
//
// Answers questions across every lecture of a course ("what did he say about phi functions last
// week?"). Citations carry the lecture they point into.

/// One lecture as seen by the course assistant.
public struct CourseLecture: Sendable {
    public var session: LectureSession
    /// 1-based ordinal within the course, by date ("Lecture 9"). Used in citations "[L9 S12]".
    public var ordinal: Int
    /// Retrieval over this lecture's deck, if it has one.
    public var slides: (any SlideSearching)?

    public init(session: LectureSession, ordinal: Int, slides: (any SlideSearching)?) {
        self.session = session
        self.ordinal = ordinal
        self.slides = slides
    }
}

public struct CourseCitation: Codable, Sendable, Hashable {
    public var sessionID: UUID
    public var ordinal: Int
    public var citation: Citation

    public init(sessionID: UUID, ordinal: Int, citation: Citation) {
        self.sessionID = sessionID
        self.ordinal = ordinal
        self.citation = citation
    }
}

public struct CourseAnswer: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var question: String
    /// Text with inline markers "[L9 S12]" (lecture 9, slide 12) and "[L9 T14:32]".
    public var text: String
    public var citations: [CourseCitation]
    public var createdAt: Date

    public init(id: UUID = UUID(), question: String, text: String, citations: [CourseCitation], createdAt: Date = .now) {
        self.id = id
        self.question = question
        self.text = text
        self.citations = citations
        self.createdAt = createdAt
    }
}

public enum CourseAskEvent: Sendable, Hashable {
    case delta(String)
    case done(CourseAnswer)
}

public protocol CourseAssisting: Sendable {
    /// Streams an answer grounded in the course's lectures. `history` is prior Q&A in this
    /// course chat (oldest first) for follow-up questions.
    func ask(_ question: String, history: [CourseAnswer]) -> AsyncThrowingStream<CourseAskEvent, Error>
}

extension CitationParser {
    /// Parses "[L9 S12]", "[L9 T14:32]", "[L3 S4, L3 S5]" given a map from ordinal → session id.
    public static func courseCitations(in text: String, sessions: [Int: UUID]) -> [CourseCitation] {
        var result: [CourseCitation] = []
        var seen = Set<CourseCitation>()
        for match in text.matches(of: /\[([^\[\]]{1,80})\]/) {
            for token in match.1.split(separator: ",") {
                let parts = token.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count == 2, parts[0].first == "L" || parts[0].first == "l",
                      let ordinal = Int(parts[0].dropFirst()), let id = sessions[ordinal],
                      let inner = citations(in: "[\(parts[1])]").first else { continue }
                let c = CourseCitation(sessionID: id, ordinal: ordinal, citation: inner)
                if seen.insert(c).inserted { result.append(c) }
            }
        }
        return result
    }
}
