import Foundation

/// Picks the passage of a page that best matches a query.
enum SlideExcerpt {
    private static let targetLength = 240

    /// The best window of one or two adjacent lines/sentences, scored by summed IDF of matching
    /// query terms. Falls back to the start of the page when nothing matches.
    static func best(in text: String, queryWeights: [String: Double]) -> String {
        let units = units(of: text)
        guard !units.isEmpty else { return "" }

        var bestIndex = 0
        var bestScore = 0.0
        for (index, unit) in units.enumerated() {
            let terms = Set(SlideTokenizer.tokens(unit))
            let score = terms.reduce(0.0) { $0 + (queryWeights[$1] ?? 0) }
            if score > bestScore { bestScore = score; bestIndex = index }
        }
        var excerpt = units[bestIndex]
        // Widen short hits with the next unit for context, or the previous one at the page end.
        for neighbour in [bestIndex + 1, bestIndex - 1] where units.indices.contains(neighbour) && excerpt.count < targetLength / 2 {
            let candidate = neighbour > bestIndex ? excerpt + " " + units[neighbour] : units[neighbour] + " " + excerpt
            if candidate.count <= targetLength { excerpt = candidate }
        }
        if excerpt.count > targetLength { excerpt = String(excerpt.prefix(targetLength)).trimmingCharacters(in: .whitespaces) + "…" }
        return excerpt
    }

    /// Lines, with over-long lines split into sentences.
    private static func units(of text: String) -> [String] {
        text.components(separatedBy: .newlines).flatMap { line -> [String] in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count > targetLength else { return trimmed.isEmpty ? [] : [trimmed] }
            return SentenceSplitter.sentences(in: trimmed)
        }
    }
}
