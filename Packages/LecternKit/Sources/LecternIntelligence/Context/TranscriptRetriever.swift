import Foundation
import LecternCore

/// Keyword retrieval over the lecture transcript, grouped into short time windows so a hit carries
/// enough context to answer from and a single timestamp to cite.
struct TranscriptRetriever: Sendable {
    struct Window: Sendable, Hashable {
        var start: TimeInterval
        var end: TimeInterval
        var segments: ArraySlice<TranscriptSegment>
    }

    let windows: [Window]
    private let index: BM25Index

    /// - Parameter windowSeconds: target span of one retrievable window.
    init(segments: [TranscriptSegment], windowSeconds: TimeInterval = 45) {
        windows = Self.windows(segments, seconds: windowSeconds)
        index = BM25Index(documents: windows.map { $0.segments.flatMap { Self.terms($0.text) } })
    }

    /// Best-matching windows for `query`, highest score first; windows with no query term are excluded.
    func search(_ query: String, limit: Int) -> [Window] {
        index.search(Self.terms(query)).prefix(limit).map { windows[$0.index] }
    }

    /// Consecutive segments grouped into windows spanning at most `seconds`.
    static func windows(_ segments: [TranscriptSegment], seconds: TimeInterval) -> [Window] {
        var windows: [Window] = []
        var startIndex = segments.startIndex
        while startIndex < segments.endIndex {
            var end = startIndex
            while end + 1 < segments.endIndex, segments[end + 1].end - segments[startIndex].start <= seconds { end += 1 }
            windows.append(Window(start: segments[startIndex].start, end: segments[end].end, segments: segments[startIndex...end]))
            startIndex = end + 1
        }
        return windows
    }

    /// Lowercased, stop-word-free, lightly stemmed terms. Domain words such as "first", "follow"
    /// and "set" are deliberately kept: they are technical terms in CS lectures.
    static func terms(_ text: String) -> [String] {
        Text.words(text).compactMap { word in
            guard word.count > 1, !stopWords.contains(word) else { return nil }
            return stem(word)
        }
    }

    /// A tiny suffix stripper so "sets"/"set", "derives"/"derived"/"deriving" meet.
    static func stem(_ word: String) -> String {
        var w = word
        if w.count > 3 {
            if w.hasSuffix("ies") {
                w = String(w.dropLast(3)) + "y"
            } else if w.hasSuffix("sses") || (w.hasSuffix("es") && ["x", "ch", "sh"].contains(where: { w.dropLast(2).hasSuffix($0) })) {
                w = String(w.dropLast(2))
            } else if w.hasSuffix("s"), !["ss", "us", "is"].contains(where: { w.hasSuffix($0) }) {
                w = String(w.dropLast())
            }
        }
        if w.count > 5, w.hasSuffix("ing") {
            w = String(w.dropLast(3))
        } else if w.count > 4, w.hasSuffix("ed") {
            w = String(w.dropLast(2))
        }
        if w.count > 4, w.hasSuffix("e") { w = String(w.dropLast()) }
        return w
    }

    private static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "so", "of", "to", "in", "on", "at", "by", "for", "with",
        "is", "are", "was", "were", "be", "been", "being", "am", "it", "its", "this", "that", "these", "those",
        "i", "you", "we", "they", "he", "she", "me", "my", "our", "your", "their", "them", "us",
        "do", "does", "did", "have", "has", "had", "can", "could", "will", "would", "should", "may", "might",
        "what", "which", "who", "whom", "how", "why", "when", "where", "there", "here", "then", "than",
        "um", "uh", "like", "okay", "ok", "yeah", "right", "just", "really", "actually", "basically",
        "gonna", "wanna", "kind", "sort", "thing", "things", "stuff", "lot", "get", "got", "go", "going",
        "about", "from", "into", "out", "up", "down", "over", "also", "very", "not", "no", "yes", "all",
        "some", "any", "one", "now", "let", "lets", "say", "said", "see", "know", "think", "mean",
        "explain", "tell", "lecture", "professor", "talk", "talked", "discuss", "discussed",
    ]
}
