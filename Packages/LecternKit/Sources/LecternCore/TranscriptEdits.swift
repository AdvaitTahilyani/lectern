import Foundation

// MARK: - Transcript corrections
//
// After recognition, final segments can be corrected (course jargon fixed from the slide deck, in
// LecternSlides as `TranscriptCorrector`). The segment keeps what was heard in `originalText`;
// `TranscriptEdit` recovers the individual word-level changes so the UI can mark them.

/// Rewrites final transcript segments, e.g. fixing misheard course jargon. Implementations are
/// conservative: a segment with nothing to fix comes back unchanged (and `originalText` stays nil).
public protocol TranscriptCorrecting: Sendable {
    func correct(_ segment: TranscriptSegment) -> TranscriptSegment
}

/// One contiguous word-level change between the heard text and the corrected text.
public struct TranscriptEdit: Sendable, Hashable {
    /// The words as heard, e.g. "gen expression".
    public var original: String
    /// The words that replaced them, e.g. "genExpr".
    public var corrected: String
    /// Where `corrected` sits in the corrected text.
    public var range: Range<String.Index>

    public init(original: String, corrected: String, range: Range<String.Index>) {
        self.original = original
        self.corrected = corrected
        self.range = range
    }

    /// The changed word runs of `corrected` relative to `original` (a word-level LCS diff).
    /// Pure deletions have nothing to point at in the corrected text and are left out.
    public static func edits(from original: String?, to corrected: String) -> [TranscriptEdit] {
        guard let original, original != corrected else { return [] }
        let old = words(in: original)
        let new = words(in: corrected)
        let n = old.count, m = new.count
        guard n > 0, m > 0 else { return [] }

        // lcs[i][j] = LCS length of old[i...] and new[j...].
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = old[i].text == new[j].text ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }

        var result: [TranscriptEdit] = []
        var i = 0, j = 0
        var runOld: [Substring] = []
        var runNew: [(text: Substring, range: Range<String.Index>)] = []
        func flush() {
            if let first = runNew.first, let last = runNew.last {
                result.append(TranscriptEdit(
                    original: runOld.joined(separator: " "),
                    corrected: runNew.map(\.text).joined(separator: " "),
                    range: first.range.lowerBound..<last.range.upperBound
                ))
            }
            runOld = []
            runNew = []
        }
        while i < n || j < m {
            if i < n, j < m, old[i].text == new[j].text {
                flush()
                i += 1
                j += 1
            } else if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] {
                runNew.append(new[j])
                j += 1
            } else {
                runOld.append(old[i].text)
                i += 1
            }
        }
        flush()
        return result
    }

    private static func words(in text: String) -> [(text: Substring, range: Range<String.Index>)] {
        var out: [(Substring, Range<String.Index>)] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                if let s = start { out.append((text[s..<index], s..<index)); start = nil }
            } else if start == nil {
                start = index
            }
            index = text.index(after: index)
        }
        if let s = start { out.append((text[s..<text.endIndex], s..<text.endIndex)) }
        return out
    }
}

extension TranscriptSegment {
    /// The word-level corrections applied to this segment; empty when it is exactly as heard.
    public var corrections: [TranscriptEdit] { TranscriptEdit.edits(from: originalText, to: text) }
}
