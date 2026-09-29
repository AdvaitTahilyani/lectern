import Foundation

/// Small string helpers shared by the prompt builders.
enum Text {
    /// Collapses all runs of whitespace (including newlines) to single spaces.
    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Truncates at a word boundary, appending "…" when cut.
    static func truncate(_ s: String, maxChars: Int) -> String {
        guard s.count > maxChars else { return s }
        let cut = s.prefix(max(0, maxChars - 1))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > maxChars / 2 {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }

    /// Shortens to at most `maxChars`, preferring to end on a sentence boundary.
    static func clampSentences(_ s: String, maxChars: Int) -> String {
        let text = collapse(s)
        guard text.count > maxChars else { return text }
        let window = text.prefix(maxChars)
        if let end = window.lastIndex(where: { ".!?".contains($0) }),
           window.distance(from: window.startIndex, to: end) >= maxChars / 3 {
            return String(window[...end])
        }
        return truncate(text, maxChars: maxChars)
    }

    /// Lowercased words with punctuation removed, for fuzzy comparisons.
    static func words(_ s: String) -> [String] {
        s.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
            .map { $0.replacingOccurrences(of: "'", with: "") }
            .filter { !$0.isEmpty }
    }

    /// Word-level Jaccard similarity in 0...1.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Set(words(a)), y = Set(words(b))
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }
}
