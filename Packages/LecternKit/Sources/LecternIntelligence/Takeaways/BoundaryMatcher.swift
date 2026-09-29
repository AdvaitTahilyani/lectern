import Foundation
import LecternCore

/// Finds where the model's `boundary_quote` ("the first words of the new topic") occurs in the
/// transcript, tolerating paraphrase, dropped filler words and ASR spelling variants.
enum BoundaryMatcher {
    struct Match: Equatable, Sendable {
        /// Index into the searched segment array.
        var segmentIndex: Int
        /// Interpolated session time at which the quote starts.
        var time: TimeInterval
        /// Fraction of quote words matched, in order (0...1).
        var score: Double
    }

    /// Words of the quote that are compared; the opening words carry the boundary.
    static let maxQuoteWords = 10
    static let minimumScore = 0.6
    /// Quote words may be separated by at most this many transcript words (filler, restarts).
    static let maxGap = 2

    /// Best match of `quote` within `segments[range]`. Among equally good matches, those at or after
    /// `preferFrom` (the newly arrived text) win, and then the earliest.
    static func locate(quote: String, in segments: [TranscriptSegment], range: Range<Int>, preferFrom: Int) -> Match? {
        let q = Array(Text.words(quote).prefix(maxQuoteWords))
        guard !q.isEmpty, !range.isEmpty else { return nil }

        struct Token { var word: String; var segment: Int; var offset: Int; var count: Int }
        var tokens: [Token] = []
        for index in range {
            let words = Text.words(segments[index].text)
            for (offset, word) in words.enumerated() {
                tokens.append(Token(word: word, segment: index, offset: offset, count: words.count))
            }
        }

        let words = tokens.map(\.word)
        // Best alignment, keyed by the position of its first matched word (the real boundary).
        var best: (position: Int, score: Double)?
        for p in tokens.indices where wordsMatch(words[p], q[0]) || (q.count > 2 && wordsMatch(words[p], q[1])) {
            guard let aligned = align(q, words, from: p), aligned.score >= minimumScore else { continue }
            if let current = best {
                let preferred = tokens[aligned.first].segment >= preferFrom && tokens[current.position].segment < preferFrom
                if aligned.score > current.score + 0.001 || (abs(aligned.score - current.score) <= 0.001 && preferred) {
                    best = (aligned.first, aligned.score)
                }
            } else {
                best = (aligned.first, aligned.score)
            }
        }
        guard let best else { return nil }
        let token = tokens[best.position]
        let segment = segments[token.segment]
        let fraction = token.offset <= 2 ? 0 : Double(token.offset) / Double(max(1, token.count))
        let time = segment.start + fraction * max(0, segment.end - segment.start)
        return Match(segmentIndex: token.segment, time: time, score: best.score)
    }

    /// Fraction of quote words found in order starting at `start` (allowing small gaps), and the
    /// position of the first matched word.
    private static func align(_ quote: [String], _ words: [String], from start: Int) -> (score: Double, first: Int)? {
        var matched = 0
        var first: Int?
        var cursor = start
        for q in quote {
            var j = cursor
            while j < words.count, j <= cursor + maxGap, !wordsMatch(words[j], q) { j += 1 }
            guard j < words.count, j <= cursor + maxGap else { continue }
            matched += 1
            first = first ?? j
            cursor = j + 1
        }
        guard let first else { return nil }
        return (Double(matched) / Double(quote.count), first)
    }

    /// Equal, one edit apart (for words of 4+ letters), or sharing a 5-letter prefix.
    static func wordsMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let shorter = min(a.count, b.count)
        if shorter >= 5, a.prefix(5) == b.prefix(5) { return true }
        return shorter >= 4 && abs(a.count - b.count) <= 1 && editDistance(a, b, limit: 1) <= 1
    }

    private static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let x = Array(a), y = Array(b)
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            if current.min()! > limit { return limit + 1 }
            previous = current
        }
        return previous[y.count]
    }
}
