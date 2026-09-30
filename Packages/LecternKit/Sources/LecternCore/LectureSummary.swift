import Foundation

// MARK: - Lecture summary (produced by `LectureIntelligence.lectureSummary()`)

/// The Review screen's summary of a whole lecture: an overview, the concepts worth knowing, what
/// the student should revisit (from their quiz misses) and what the lecturer flagged. Persisted in
/// `LectureSession.summary`.
public struct LectureSummary: Codable, Sendable, Hashable {
    /// 3–5 whole sentences on what the lecture covered.
    public var overview: String
    /// The lecture's key concepts, each with a one-line definition.
    public var keyConcepts: [KeyTerm]
    /// Concepts the student missed in quizzes, each "Concept — one-line why". Empty when nothing
    /// was missed.
    public var reviewThese: [String]
    /// What the lecturer flagged: exam hints, deadlines, "this is important". Only what was said.
    public var flagged: [String]
    /// 1-based slide pages most worth revisiting, ascending.
    public var slides: [Int]
    public var generatedAt: Date

    public init(overview: String, keyConcepts: [KeyTerm] = [], reviewThese: [String] = [], flagged: [String] = [], slides: [Int] = [], generatedAt: Date = .now) {
        self.overview = overview
        self.keyConcepts = keyConcepts
        self.reviewThese = reviewThese
        self.flagged = flagged
        self.slides = slides
        self.generatedAt = generatedAt
    }

    enum CodingKeys: String, CodingKey { case overview, keyConcepts, reviewThese, flagged, slides, generatedAt }

    /// Tolerant: a missing or unreadable field falls back to an empty value (and unreadable key
    /// concepts are skipped individually), so an older or hand-edited file still opens.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overview = (try? c.decodeIfPresent(String.self, forKey: .overview)) ?? ""
        keyConcepts = ((try? c.decodeIfPresent([Lossy<KeyTerm>].self, forKey: .keyConcepts)) ?? []).compactMap(\.value)
        reviewThese = ((try? c.decodeIfPresent([Lossy<String>].self, forKey: .reviewThese)) ?? []).compactMap(\.value)
        flagged = ((try? c.decodeIfPresent([Lossy<String>].self, forKey: .flagged)) ?? []).compactMap(\.value)
        slides = ((try? c.decodeIfPresent([Lossy<Int>].self, forKey: .slides)) ?? []).compactMap(\.value)
        generatedAt = (try? c.decodeIfPresent(Date.self, forKey: .generatedAt)) ?? Date(timeIntervalSince1970: 0)
    }

    /// True when there is nothing to show.
    public var isEmpty: Bool {
        overview.isEmpty && keyConcepts.isEmpty && reviewThese.isEmpty && flagged.isEmpty
    }
}

/// Decodes one array element, yielding nil instead of failing the whole array.
struct Lossy<T: Decodable>: Decodable {
    var value: T?
    init(from decoder: any Decoder) throws {
        value = try? decoder.singleValueContainer().decode(T.self)
    }
}

// MARK: - Legacy summary takeaway

extension LectureSession {
    /// Before `summary` existed, the app stored the lecture summary as a takeaway with this
    /// deterministic id (derived from the session id). Stores drop that takeaway when loading, and
    /// the summary is regenerated the next time the lecture is reviewed.
    public static func legacySummaryTakeawayID(for sessionID: UUID) -> UUID {
        let hex = sessionID.uuidString.replacingOccurrences(of: "-", with: "").suffix(12)
        return UUID(uuidString: "00000000-0000-4000-8000-\(hex)")!
    }

    /// Removes the legacy summary takeaway, if present. Returns whether one was removed.
    @discardableResult
    public mutating func dropLegacySummaryTakeaway() -> Bool {
        let legacy = Self.legacySummaryTakeawayID(for: id)
        let before = takeaways.count
        takeaways.removeAll { $0.id == legacy }
        return takeaways.count != before
    }
}
