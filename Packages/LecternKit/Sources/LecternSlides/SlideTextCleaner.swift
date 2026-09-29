import Foundation

/// Turns raw PDF/OCR text into clean lines and strips slide "furniture" (page numbers and
/// footers repeated on most pages).
enum SlideTextCleaner {
    /// PDFKit puts U+FFFC (object replacement character) in a page's text where an image is drawn.
    static let imageMarker = "\u{FFFC}"

    // MARK: Lines

    /// Splits raw text into trimmed, whitespace-collapsed, non-empty lines with ligatures
    /// expanded, control characters removed and words broken across lines rejoined.
    static func lines(from raw: String) -> [String] {
        let normalized = raw
            .precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: SlideTextCleaner.imageMarker, with: " ")
        let separators = CharacterSet.newlines.union(CharacterSet(charactersIn: "\u{0C}\u{0B}"))
        let lines = normalized.components(separatedBy: separators).compactMap { line -> String? in
            let cleaned = line.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\t" }
            let collapsed = String(String.UnicodeScalarView(cleaned))
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            return collapsed.isEmpty ? nil : collapsed
        }
        return dehyphenate(lines)
    }

    /// "pars-" + "ing tables" becomes "parsing tables" (only when the next line continues in
    /// lowercase, so "LL(1)-" or bullet lists are left alone).
    static func dehyphenate(_ lines: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < lines.count {
            var line = lines[index]
            while line.count > 1, line.hasSuffix("-"), index + 1 < lines.count,
                  let beforeHyphen = line.dropLast().last, beforeHyphen.isLowercase,
                  let next = lines[index + 1].first, next.isLowercase {
                line = String(line.dropLast()) + lines[index + 1]
                index += 1
            }
            result.append(line)
            index += 1
        }
        return result
    }

    // MARK: Furniture

    /// "3", "Page 3", "3 / 10", "3 of 10", "- 3 -".
    static func isPageNumber(_ line: String) -> Bool {
        line.wholeMatch(of: /(?i)[-–—\s]*(?:page\s*|slide\s*|p\.\s*)?\d{1,4}(?:\s*(?:\/|of)\s*\d{1,4})?[-–—\s]*/) != nil
    }

    /// A page-independent key for a line: lowercased, digits collapsed to "#", every
    /// punctuation/symbol character treated as a space, and edge numbers dropped. Two footer lines then match across pages
    /// ("CS 421 · Sep 29 · 7" vs "... · 8") and across text-vs-OCR readings ("·" read as "•").
    static func furnitureKey(_ line: String) -> String {
        var key = ""
        var previousWasDigit = false
        for character in line.lowercased() {
            if character.isNumber {
                if !previousWasDigit { key.append("#") }
                previousWasDigit = true
            } else {
                key.append(character.isLetter ? character : " ")
                previousWasDigit = false
            }
        }
        var tokens = key.split(whereSeparator: { $0.isWhitespace })
        // Numbers at either end are page numbers or dates that may or may not have been merged
        // into the footer line, so they do not take part in the comparison.
        while tokens.last == "#" { tokens.removeLast() }
        while tokens.first == "#" { tokens.removeFirst() }
        return tokens.joined(separator: " ")
    }

    /// Keys of short lines (course name, date, deck title...) that appear on most pages.
    /// Needs at least three text pages; a line qualifies when it appears on at least 60% of them.
    static func repeatedFooterKeys(in pages: [[String]]) -> Set<String> {
        let textPages = pages.filter { !$0.isEmpty }
        guard textPages.count >= 3 else { return [] }
        var pageCounts: [String: Int] = [:]
        for lines in textPages {
            let keys = Set(lines.filter { $0.count <= 100 }.map(furnitureKey).filter { $0.count >= 3 })
            for key in keys { pageCounts[key, default: 0] += 1 }
        }
        let threshold = max(3, Int((Double(textPages.count) * 0.6).rounded(.up)))
        return Set(pageCounts.filter { $0.value >= threshold }.keys)
    }

    /// Removes lone page numbers (only near the page edges, so real numeric content survives) and
    /// lines whose key is in `footerKeys`.
    static func removingFurniture(from lines: [String], footerKeys: Set<String>) -> [String] {
        lines.enumerated().compactMap { offset, line in
            let nearEdge = offset < 2 || offset >= lines.count - 2
            if nearEdge, isPageNumber(line) { return nil }
            if footerKeys.contains(furnitureKey(line)) { return nil }
            return line
        }
    }

    /// Appends the OCR lines that the extracted lines do not already contain (an image on an
    /// otherwise text-bearing slide). A line counts as already present when most of its words
    /// occur in one existing line, which tolerates small OCR misreadings.
    static func merging(ocrLines: [String], into lines: [String]) -> [String] {
        let existing = lines.map(words)
        let extra = ocrLines.filter { candidate in
            let candidateWords = words(candidate)
            guard candidateWords.count >= 1, alphanumericCount([candidate]) >= 2 else { return false }
            return !existing.contains { line in
                let shared = candidateWords.intersection(line).count
                return Double(shared) / Double(candidateWords.count) >= 0.6
            }
        }
        return lines + extra
    }

    private static func words(_ line: String) -> Set<String> {
        Set(line.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    /// Letters and digits in `lines`; used to decide whether a page has real text.
    static func alphanumericCount(_ lines: [String]) -> Int {
        lines.reduce(0) { $0 + $1.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count }
    }
}
