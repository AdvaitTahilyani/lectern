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

        let asciiWords = words.map { word in word.utf8.allSatisfy { $0 < 0x80 } ? Array(word.lowercased().utf8) : nil }
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
            // Transcript hits come last, so hits beyond `limit` could never be shown.
            if transcripts.count < limit { transcripts += transcriptHits(in: session, words: words, asciiWords: asciiWords) }
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

    private static func transcriptHits(in session: LectureSession, words: [String], asciiWords: [[UInt8]?]) -> [SearchHit] {
        let segments = session.transcript.filter(\.isFinal).sorted { $0.start < $1.start }
        guard !segments.isEmpty else { return [] }
        // Most segments contain none of the query words, so a cheap presence test per word decides
        // whether the (allocating) snippet builder needs to run at all.
        let everyWord: UInt64 = words.count >= 64 ? .max : (1 << UInt64(words.count)) - 1
        func presence(_ text: String) -> UInt64 {
            var mask: UInt64 = 0
            for bit in words.indices.prefix(64) where contains(text, words[bit], ascii: asciiWords[bit]) {
                mask |= 1 << UInt64(bit)
            }
            return mask
        }

        var hits: [SearchHit] = []
        var previousMatched = false
        var current = presence(segments[0].text)
        for index in segments.indices {
            let next = index + 1 < segments.count ? presence(segments[index + 1].text) : 0
            defer { current = next }
            if current == everyWord, let snippet = snippet(in: segments[index].text, words: words) {
                hits.append(SearchHit(sessionID: session.id, kind: .transcript, snippet: snippet, time: segments[index].start))
                if hits.count == transcriptHitsPerSession { break }
                previousMatched = true
                continue
            }
            // A phrase split across a caption break matches neither segment alone. (When the next
            // segment matches by itself it gets its own hit; a second one here would be a duplicate.)
            if words.count > 1, !previousMatched, index + 1 < segments.count, current | next == everyWord, next != everyWord,
               let snippet = snippet(in: segments[index].text + " " + segments[index + 1].text, words: words) {
                hits.append(SearchHit(sessionID: session.id, kind: .transcript, snippet: snippet, time: segments[index].start))
                if hits.count == transcriptHitsPerSession { break }
            }
            previousMatched = false
        }
        return hits
    }

    // MARK: Matching

    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Whether `text` contains `word`, ignoring case and accents. Plain-ASCII text (nearly every
    /// transcript segment) against an ASCII word is scanned bytewise, which is about 20x faster than
    /// Foundation's folding search; anything else takes the general path.
    private static func contains(_ text: String, _ word: String, ascii needle: [UInt8]?) -> Bool {
        if let needle {
            var text = text
            let found: Bool? = text.withUTF8 { haystack in
                if haystack.contains(where: { $0 >= 0x80 }) { return nil }
                guard haystack.count >= needle.count else { return false }
                func lower(_ byte: UInt8) -> UInt8 { byte >= 65 && byte <= 90 ? byte + 32 : byte }
                for start in 0...(haystack.count - needle.count) where lower(haystack[start]) == needle[0] {
                    if needle.indices.dropFirst().allSatisfy({ lower(haystack[start + $0]) == needle[$0] }) { return true }
                }
                return false
            }
            if let found { return found }
        }
        return text.range(of: word, options: options) != nil
    }

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
