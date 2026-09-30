import Foundation
import LecternCore
import OSLog
import Synchronization

/// Shared JSON configuration and tolerant decoding for everything `FileSessionStore` writes.
enum StoreCoding {
    static let logger = Logger(subsystem: "app.lectern", category: "store")

    /// `userInfo` key under which the reader passes in the `DropTally` for the file being decoded.
    static let tallyKey = CodingUserInfoKey(rawValue: "lectern.dropTally")!

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

/// Counts the values lossy decoding had to drop while reading one file, so the store can keep a
/// copy of the file before a save makes the loss permanent.
final class DropTally: Sendable {
    private let dropped = Mutex(0)
    var count: Int { dropped.withLock { $0 } }
    func record() { dropped.withLock { $0 += 1 } }
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
        let tally = decoder.userInfo[StoreCoding.tallyKey] as? DropTally
        schemaVersion = container.lossy(Int.self, forKey: .schemaVersion, default: 1, tally: tally)
        courses = container.lossyArray(Course.self, forKey: .courses, context: "courses", tally: tally)
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
        let tally = decoder.userInfo[StoreCoding.tallyKey] as? DropTally
        schemaVersion = container.lossy(Int.self, forKey: .schemaVersion, default: 1, tally: tally)
        answers = container.lossyArray(CourseAnswer.self, forKey: .answers, context: "course chat", tally: tally)
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, answers }
}

/// `Sessions/<uuid>/session.json`
struct SessionFile: Encodable {
    var schemaVersion = StoreCoding.schemaVersion
    var session: LectureSession
}

/// Decodes a `session.json`, tolerating unknown keys, missing collections, and individual
/// damaged elements inside collections (which are dropped and logged). Also migrates older
/// files (see `LectureSession.dropLegacySummaryTakeaway()`).
struct TolerantSessionFile: Decodable {
    var schemaVersion: Int
    var session: LectureSession

    /// `userInfo` keys giving fallbacks for fields a damaged file may lack.
    static let fallbackIDKey = CodingUserInfoKey(rawValue: "lectern.fallbackSessionID")!
    static let fallbackDateKey = CodingUserInfoKey(rawValue: "lectern.fallbackSessionDate")!

    enum CodingKeys: String, CodingKey { case schemaVersion, session }

    init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        let tally = decoder.userInfo[StoreCoding.tallyKey] as? DropTally
        schemaVersion = root.lossy(Int.self, forKey: .schemaVersion, default: 1, tally: tally)
        let fields = try root.nestedContainer(keyedBy: SessionKeys.self, forKey: .session)

        let fallbackID = decoder.userInfo[Self.fallbackIDKey] as? UUID
        let fallbackDate = decoder.userInfo[Self.fallbackDateKey] as? Date ?? Date(timeIntervalSince1970: 0)
        guard let id = fields.lossyOptional(UUID.self, forKey: .id) ?? fallbackID else {
            throw DecodingError.keyNotFound(SessionKeys.id, .init(codingPath: fields.codingPath, debugDescription: "Session has no id"))
        }

        session = LectureSession(
            id: id,
            courseID: fields.lossyOptional(UUID.self, forKey: .courseID, tally: tally),
            title: fields.lossy(String.self, forKey: .title, default: "Untitled Lecture", tally: tally),
            createdAt: fields.lossy(Date.self, forKey: .createdAt, default: fallbackDate, tally: tally),
            startedAt: fields.lossyOptional(Date.self, forKey: .startedAt, tally: tally),
            endedAt: fields.lossyOptional(Date.self, forKey: .endedAt, tally: tally),
            duration: fields.lossy(TimeInterval.self, forKey: .duration, default: 0, tally: tally),
            status: fields.lossy(SessionStatus.self, forKey: .status, default: .draft, tally: tally),
            deck: fields.lossyOptional(SlideDeck.self, forKey: .deck, tally: tally),
            transcript: fields.lossyArray(TranscriptSegment.self, forKey: .transcript, context: "transcript", tally: tally),
            takeaways: fields.lossyArray(Takeaway.self, forKey: .takeaways, context: "takeaways", tally: tally),
            quiz: fields.lossyArray(QuizRecord.self, forKey: .quiz, context: "quiz", tally: tally),
            chat: fields.lossyArray(ChatMessage.self, forKey: .chat, context: "chat", tally: tally),
            currentSlide: fields.lossyOptional(Int.self, forKey: .currentSlide, tally: tally),
            vocabulary: fields.lossyArray(String.self, forKey: .vocabulary, context: "vocabulary", tally: tally),
            source: fields.lossyOptional(SessionSource.self, forKey: .source, tally: tally),
            summary: fields.lossyOptional(LectureSummary.self, forKey: .summary, tally: tally)
        )
        // Migration: the summary used to be stored as a takeaway with a magic id. Drop it; the app
        // regenerates a `LectureSummary` the next time the lecture is reviewed.
        if session.dropLegacySummaryTakeaway() {
            StoreCoding.logger.info("Dropped the legacy summary takeaway of session \(id.uuidString, privacy: .public)")
        }
    }

    private enum SessionKeys: String, CodingKey {
        case id, courseID, title, createdAt, startedAt, endedAt, duration, status, deck
        case transcript, takeaways, quiz, chat, currentSlide, vocabulary, source, summary
    }
}

// MARK: - Lossy decoding helpers

private struct Discard: Decodable {
    init(from decoder: any Decoder) throws {}
}

extension KeyedDecodingContainer {
    /// The value for `key`, or `defaultValue` when the key is missing, null, or unreadable
    /// (unreadable values are logged).
    func lossy<T: Decodable>(_ type: T.Type, forKey key: Key, default defaultValue: T, tally: DropTally? = nil) -> T {
        do {
            return try decodeIfPresent(type, forKey: key) ?? defaultValue
        } catch {
            tally?.record()
            StoreCoding.logger.error("Ignoring unreadable \"\(key.stringValue, privacy: .public)\": \(error.localizedDescription, privacy: .public)")
            return defaultValue
        }
    }

    /// Like `lossy`, for optional fields: nil when missing, null, or unreadable (logged).
    func lossyOptional<T: Decodable>(_ type: T.Type, forKey key: Key, tally: DropTally? = nil) -> T? {
        do {
            return try decodeIfPresent(type, forKey: key)
        } catch {
            tally?.record()
            StoreCoding.logger.error("Ignoring unreadable \"\(key.stringValue, privacy: .public)\": \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The array for `key`: empty when missing, and skipping (and logging) elements that fail to decode.
    func lossyArray<T: Decodable>(_ type: T.Type, forKey key: Key, context: String, tally: DropTally? = nil) -> [T] {
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
                    tally?.record()
                    StoreCoding.logger.error("Dropping unreadable \(context, privacy: .public) element \(elements.currentIndex): \(error.localizedDescription, privacy: .public)")
                    _ = try? elements.decode(Discard.self)   // advance past the bad element
                }
            }
            if skipped > 0 {
                StoreCoding.logger.error("\(skipped) element(s) of \"\(context, privacy: .public)\" could not be read and were dropped")
            }
            return result
        } catch {
            tally?.record()
            StoreCoding.logger.error("Ignoring unreadable \"\(context, privacy: .public)\": \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
