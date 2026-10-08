import Foundation

/// Repairs citation markers models get slightly wrong, so `CitationParser` (and the app's citation
/// links) pick them up:
/// - a bare timestamp copied from the transcript's own line format: "[14:32]" → "[T14:32]";
/// - a timestamp given the slide prefix: "[S56:40]" → "[T56:40]" (slides are plain numbers);
/// - either one inside a list with valid citations: "[S12, 55:38]" → "[S12, T55:38]";
/// - a range, which cites where it starts: "[T35:03–T36:03]" → "[T35:03]".
/// A bracket is rewritten only when every comma-separated part is a citation, optionally with a
/// course lecture prefix ("L9 "), so footnotes, code and Markdown links are left alone.
enum CitationNormalizer {
    static func normalize(_ text: String) -> String {
        text.replacing(/\[([^\[\]]{1,80})\]/) { match in
            var parts: [String] = []
            for part in match.1.split(separator: ",", omittingEmptySubsequences: false) {
                guard let fixed = normalizedToken(part.trimmingCharacters(in: .whitespaces)) else { return String(match.0) }
                parts.append(fixed)
            }
            return "[" + parts.joined(separator: ", ") + "]"
        }
    }

    /// The token in citation form, or nil if it isn't a citation.
    private static func normalizedToken(_ token: String) -> String? {
        let ends = token.split(whereSeparator: { "–—-".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
        if ends.count == 2 {
            guard let start = normalizedToken(ends[0]), normalizedToken(ends[1]) != nil else { return nil }
            return start
        }
        guard let match = token.wholeMatch(of: /(L\d{1,3}\s+)?([STst]?)(\d{1,2}(?::\d{2}){1,2}|\d{1,4})/) else { return nil }
        let lecture = match.1.map(String.init) ?? ""
        let kind = match.2.uppercased()
        let value = String(match.3)
        let isTime = value.contains(":")
        switch (kind, isTime) {
        case ("S", false), ("T", true): return lecture + kind + value
        case ("S", true), ("", true): return lecture + "T" + value
        default: return nil   // a bare number ("[3]") or "T12"
        }
    }
}
