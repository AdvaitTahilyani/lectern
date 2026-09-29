import AppKit
import Foundation
import PDFKit

/// Guesses a slide's title: the first run of the largest font on the page when the page has real
/// size contrast, otherwise the first short line.
enum SlideTitleExtractor {
    /// Longest title kept, in characters.
    private static let maxLength = 120
    /// A line longer than this is a sentence, not a title, when falling back to "first line".
    private static let maxFallbackLength = 90
    /// The largest font must be at least this much bigger than the body font to count as a title.
    private static let minSizeRatio: CGFloat = 1.15

    static func title(of page: PDFPage, lines: [String], footerKeys: Set<String>) -> String? {
        if let sized = largestFontTitle(of: page, footerKeys: footerKeys) { return sized }
        return firstLineTitle(lines)
    }

    /// Title from a plain list of cleaned lines (used for OCR text when no font info exists).
    static func firstLineTitle(_ lines: [String]) -> String? {
        for line in lines {
            let candidate = tidy(line)
            let letters = candidate.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            if letters >= 2, candidate.count <= maxFallbackLength { return candidate }
        }
        return nil
    }

    private static func largestFontTitle(of page: PDFPage, footerKeys: Set<String>) -> String? {
        guard let attributed = page.attributedString, attributed.length > 0 else { return nil }

        struct Run { var text: String; var size: CGFloat }
        var runs: [Run] = []
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            runs.append(Run(text: attributed.attributedSubstring(from: range).string, size: font.pointSize))
        }
        // Ignore furniture (footers, page numbers) when looking for the biggest text.
        let candidates = runs.filter { run in
            let lines = SlideTextCleaner.lines(from: run.text)
            guard !lines.isEmpty else { return false }
            return !lines.allSatisfy { SlideTextCleaner.isPageNumber($0) || footerKeys.contains(SlideTextCleaner.furnitureKey($0)) }
        }
        guard let maxSize = candidates.map(\.size).max() else { return nil }

        var weights: [CGFloat: Int] = [:]
        for run in candidates { weights[(run.size * 2).rounded() / 2, default: 0] += run.text.count }
        guard let bodySize = weights.max(by: { $0.value < $1.value })?.key,
              maxSize >= bodySize * minSizeRatio
        else { return nil }

        var pieces: [String] = []
        for run in candidates {
            let isTitleSized = run.size >= maxSize - 0.5
            if isTitleSized { pieces.append(run.text) } else if !pieces.isEmpty { break }
        }
        let title = tidy(SlideTextCleaner.lines(from: pieces.joined(separator: "\n")).joined(separator: " "))
        return title.isEmpty ? nil : title
    }

    /// Strips leading bullets and trailing colons, collapses whitespace, caps the length.
    private static func tidy(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = result.first, "•‣◦▪▫●○■□-–—*·".contains(first) {
            result.removeFirst()
            result = result.trimmingCharacters(in: .whitespaces)
        }
        if result.count > maxLength {
            result = String(result.prefix(maxLength)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return result
    }
}
