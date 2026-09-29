import Foundation
import LecternCore

/// One match from a library-wide search.
public struct SearchHit: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case title
        case takeaway
        /// The presenter notes of a slide.
        case slideNotes
        case transcript
    }

    public var sessionID: UUID
    public var kind: Kind
    /// A short excerpt around the match, ellipsized at the cut ends.
    public var snippet: String
    /// Session time (seconds) to jump to: the takeaway's start or the segment's start. Nil for title hits.
    public var time: TimeInterval?
    /// 1-based slide to jump to, for `.slideNotes` hits.
    public var slide: Int?

    public var id: String {
        "\(sessionID.uuidString)|\(kind.rawValue)|\(time.map { String($0) } ?? "-")|\(slide.map(String.init) ?? "-")|\(snippet)"
    }

    public init(sessionID: UUID, kind: Kind, snippet: String, time: TimeInterval? = nil, slide: Int? = nil) {
        self.sessionID = sessionID
        self.kind = kind
        self.snippet = snippet
        self.time = time
        self.slide = slide
    }
}

/// Case- and accent-insensitive search across lecture titles, takeaways, slide notes and transcripts.
///
/// Every word of the query must occur in the same field (a title, one takeaway, one slide's notes, one transcript
/// segment, or two adjacent transcript segments for phrases that straddle a caption break).
/// Results are ordered title, takeaway, slide-notes, then transcript hits; within a kind, by
/// the order of `sessions` (pass them newest first) and then by time.
public enum LibrarySearch {
    /// Longest snippet, in characters.
    private static let snippetLength = 140
    /// Transcript hits kept per session, so a common word cannot bury every other lecture.
    public static let transcriptHitsPerSession = 20

    public static func search(_ query: String, in sessions: [LectureSession], limit: Int = 200) -> [SearchHit] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, limit > 0 else { return [] }

        var titles: [SearchHit] = [], takeaways: [SearchHit] = [], notes: [SearchHit] = [], transcripts: [SearchHit] = []
        for session in sessions {
            if let snippet = snippet(in: session.title, words: words) {
                titles.append(SearchHit(sessionID: session.id, kind: .title, snippet: snippet))
            }
            for takeaway in session.takeaways.sorted(by: { $0.start < $1.start }) {
                let fields = searchableFields(of: takeaway)
                if let snippet = fields.lazy.compactMap({ snippet(in: $0, words: words) }).first {
                    takeaways.append(SearchHit(sessionID: session.id, kind: .takeaway, snippet: snippet, time: takeaway.start))
                }
            }
            for page in session.deck?.pages ?? [] {
                if let text = page.notes, let snippet = snippet(in: text, words: words) {
                    notes.append(SearchHit(sessionID: session.id, kind: .slideNotes, snippet: snippet, slide: page.number))
                }
            }
            transcripts += transcriptHits(in: session, words: words)
        }
        return Array((titles + takeaways + notes + transcripts).prefix(limit))
    }

    // MARK: Fields

    private static func searchableFields(of takeaway: Takeaway) -> [String] {
        var fields = [takeaway.title, takeaway.summary]
        if let detail = takeaway.detail {
            fields += detail.bullets
            fields += detail.keyTerms.map { "\($0.term): \($0.definition)" }
            if let example = detail.example { fields.append(example) }
        }
        return fields
    }

    private static func transcriptHits(in session: LectureSession, words: [String]) -> [SearchHit] {
        let segments = session.transcript.filter(\.isFinal).sorted { $0.start < $1.start }
        var hits: [SearchHit] = []
        var previousMatched = false
        for (index, segment) in segments.enumerated() where hits.count < transcriptHitsPerSession {
            if let snippet = snippet(in: segment.text, words: words) {
                hits.append(SearchHit(sessionID: session.id, kind: .transcript, snippet: snippet, time: segment.start))
                previousMatched = true
                continue
            }
            // A phrase split across a caption break matches neither segment alone.
            if words.count > 1, !previousMatched, index + 1 < segments.count,
               let snippet = snippet(in: segment.text + " " + segments[index + 1].text, words: words) {
                hits.append(SearchHit(sessionID: session.id, kind: .transcript, snippet: snippet, time: segment.start))
            }
            previousMatched = false
        }
        return hits
    }

    // MARK: Matching

    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// An excerpt of `text` around the first word's first match, or nil unless every word occurs.
    private static func snippet(in text: String, words: [String]) -> String? {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var ranges: [Range<String.Index>] = []
        for word in words {
            guard let range = flat.range(of: word, options: options) else { return nil }
            ranges.append(range)
        }
        guard let match = ranges.min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }

        let before = flat.distance(from: flat.startIndex, to: match.lowerBound)
        var start = flat.index(match.lowerBound, offsetBy: -min(before, snippetLength / 3))
        if start > flat.startIndex, let space = flat[start..<match.lowerBound].firstIndex(of: " ") {
            start = flat.index(after: space)   // begin at a word boundary
        }
        let end = flat.index(start, offsetBy: snippetLength, limitedBy: flat.endIndex) ?? flat.endIndex
        var excerpt = String(flat[start..<end])
        if start > flat.startIndex { excerpt = "\u{2026}" + excerpt }
        if end < flat.endIndex { excerpt += "\u{2026}" }
        return excerpt
    }
}
