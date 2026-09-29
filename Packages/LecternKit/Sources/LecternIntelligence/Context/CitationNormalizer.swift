import Foundation

/// Models sometimes copy the transcript's own "[14:32]" line format instead of writing the
/// "[T14:32]" citation form. This rewrites bare bracketed timestamps so `CitationParser` (and the
/// app's citation links) pick them up.
enum CitationNormalizer {
    private static let time = #"\d{1,2}:\d{2}(?::\d{2})?"#

    static func normalize(_ text: String) -> String {
        guard let pattern = try? Regex("\\[(\(time)(?:\\s*,\\s*\(time))*)\\]") else { return text }
        return text.replacing(pattern) { match in
            let inner = String(text[match.range].dropFirst().dropLast())
            return "[" + inner.split(separator: ",").map { "T" + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ") + "]"
        }
    }
}
