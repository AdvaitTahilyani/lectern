import Foundation
import LecternCore
import OSLog

/// Shared JSON configuration and tolerant decoding for everything `FileSessionStore` writes.
enum StoreCoding {
    static let logger = Logger(subsystem: "app.lectern", category: "store")

    /// Bumped when a change to the on-disk format cannot be read by older code.
    static let schemaVersion = 1

    /// Milliseconds are enough for timestamps and keep the files readable.
    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSecondDateStyle = Date.ISO8601FormatStyle()

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(dateStyle))
        }
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = try? dateStyle.parse(string) { return date }
            return try wholeSecondDateStyle.parse(string)
        }
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }
}

// MARK: - Envelopes

/// `courses.json`
struct CoursesFile: Codable {
    var schemaVersion: Int
    var courses: [Course]

    init(courses: [Course]) {
        schemaVersion = StoreCoding.schemaVersion
        self.courses = courses
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = container.lossy(Int.self, forKey: .schemaVersion, default: 1)
        courses = container.lossyArray(Course.self, forKey: .courses, context: "courses")
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, courses }
}

/// `Courses/<course-uuid>/chat.json`
struct CourseChatFile: Codable {
    var schemaVersion: Int
    var answers: [CourseAnswer]

    init(answers: [CourseAnswer]) {
        schemaVersion = StoreCoding.schemaVersion
        self.answers = answers
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = container.lossy(Int.self, forKey: .schemaVersion, default: 1)
        answers = container.lossyArray(CourseAnswer.self, forKey: .answers, context: "course chat")
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, answers }
}

/// `Sessions/<uuid>/session.json`
struct SessionFile: Encodable {
    var schemaVersion = StoreCoding.schemaVersion
    var session: LectureSession
}

/// Decodes a `session.json`, tolerating unknown keys, missing collections, and individual
/// damaged elements inside collections (which are dropped and logged).
struct TolerantSessionFile: Decodable {
    var schemaVersion: Int
    var session: LectureSession

    /// `userInfo` keys giving fallbacks for fields a damaged file may lack.
    static let fallbackIDKey = CodingUserInfoKey(rawValue: "lectern.fallbackSessionID")!
    static let fallbackDateKey = CodingUserInfoKey(rawValue: "lectern.fallbackSessionDate")!

    enum CodingKeys: String, CodingKey { case schemaVersion, session }

    init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = root.lossy(Int.self, forKey: .schemaVersion, default: 1)
        let fields = try root.nestedContainer(keyedBy: SessionKeys.self, forKey: .session)

        let fallbackID = decoder.userInfo[Self.fallbackIDKey] as? UUID
        let fallbackDate = decoder.userInfo[Self.fallbackDateKey] as? Date ?? Date(timeIntervalSince1970: 0)
        guard let id = fields.lossyOptional(UUID.self, forKey: .id) ?? fallbackID else {
            throw DecodingError.keyNotFound(SessionKeys.id, .init(codingPath: fields.codingPath, debugDescription: "Session has no id"))
        }

        session = LectureSession(
            id: id,
            courseID: fields.lossyOptional(UUID.self, forKey: .courseID),
            title: fields.lossy(String.self, forKey: .title, default: "Untitled Lecture"),
            createdAt: fields.lossy(Date.self, forKey: .createdAt, default: fallbackDate),
            startedAt: fields.lossyOptional(Date.self, forKey: .startedAt),
            endedAt: fields.lossyOptional(Date.self, forKey: .endedAt),
            duration: fields.lossy(TimeInterval.self, forKey: .duration, default: 0),
            status: fields.lossy(SessionStatus.self, forKey: .status, default: .draft),
            deck: fields.lossyOptional(SlideDeck.self, forKey: .deck),
            transcript: fields.lossyArray(TranscriptSegment.self, forKey: .transcript, context: "transcript"),
            takeaways: fields.lossyArray(Takeaway.self, forKey: .takeaways, context: "takeaways"),
            quiz: fields.lossyArray(QuizRecord.self, forKey: .quiz, context: "quiz"),
            chat: fields.lossyArray(ChatMessage.self, forKey: .chat, context: "chat"),
            currentSlide: fields.lossyOptional(Int.self, forKey: .currentSlide),
            vocabulary: fields.lossyArray(String.self, forKey: .vocabulary, context: "vocabulary"),
            source: fields.lossyOptional(SessionSource.self, forKey: .source)
        )
    }

    private enum SessionKeys: String, CodingKey {
        case id, courseID, title, createdAt, startedAt, endedAt, duration, status, deck
        case transcript, takeaways, quiz, chat, currentSlide, vocabulary, source
    }
}

// MARK: - Lossy decoding helpers

private struct Discard: Decodable {
    init(from decoder: any Decoder) throws {}
}

extension KeyedDecodingContainer {
    /// The value for `key`, or `defaultValue` when the key is missing, null, or unreadable
    /// (unreadable values are logged).
    func lossy<T: Decodable>(_ type: T.Type, forKey key: Key, default defaultValue: T) -> T {
        do {
            return try decodeIfPresent(type, forKey: key) ?? defaultValue
        } catch {
            StoreCoding.logger.error("Ignoring unreadable \"\(key.stringValue, privacy: .public)\": \(error.localizedDescription, privacy: .public)")
            return defaultValue
        }
    }

    /// Like `lossy`, for optional fields: nil when missing, null, or unreadable (logged).
    func lossyOptional<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        do {
            return try decodeIfPresent(type, forKey: key)
        } catch {
            StoreCoding.logger.error("Ignoring unreadable \"\(key.stringValue, privacy: .public)\": \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The array for `key`: empty when missing, and skipping (and logging) elements that fail to decode.
    func lossyArray<T: Decodable>(_ type: T.Type, forKey key: Key, context: String) -> [T] {
        guard contains(key), (try? decodeNil(forKey: key)) == false else { return [] }
        do {
            var elements = try nestedUnkeyedContainer(forKey: key)
            var result: [T] = []
            var skipped = 0
            while !elements.isAtEnd {
                do {
                    result.append(try elements.decode(T.self))
                } catch {
                    skipped += 1
                    StoreCoding.logger.error("Dropping unreadable \(context, privacy: .public) element \(elements.currentIndex): \(error.localizedDescription, privacy: .public)")
                    _ = try? elements.decode(Discard.self)   // advance past the bad element
                }
            }
            if skipped > 0 {
                StoreCoding.logger.error("\(skipped) element(s) of \"\(context, privacy: .public)\" could not be read and were dropped")
            }
            return result
        } catch {
            StoreCoding.logger.error("Ignoring unreadable \"\(context, privacy: .public)\": \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
