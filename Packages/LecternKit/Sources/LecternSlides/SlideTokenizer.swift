import Foundation

/// Tokenizer for lecture text (slide text and spoken transcript).
///
/// Unlike a plain word splitter it understands computer-science notation:
/// - `LL(1)` yields `ll1` and `ll`; `FIRST(A)` yields `firsta` and `first`
/// - `->`, `→`, `=>`, `⇒` all yield `->`
/// - single Greek letters such as `ε` and `α` are kept, and "epsilon" maps to `ε`
/// Everything else is lowercased, stopword-filtered and lightly stemmed.
enum SlideTokenizer {
    static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        let scalars = Array(text.precomposedStringWithCompatibilityMapping.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            if let arrowLength = arrowLength(in: scalars, at: i) {
                result.append("->")
                i += arrowLength
            } else if isWordScalar(scalar) {
                var j = i
                while j < scalars.count, isWordScalar(scalars[j]) { j += 1 }
                let word = String(String.UnicodeScalarView(scalars[i..<j])).lowercased()
                if let inner = parenthesizedSuffix(in: scalars, at: j, wordLength: j - i) {
                    let innerText = String(String.UnicodeScalarView(scalars[inner.contentRange])).lowercased()
                    append(word + innerText, to: &result, stem: false)
                    j = inner.end
                }
                append(word, to: &result, stem: true)
                i = j
            } else {
                i += 1
            }
        }
        return result
    }

    // MARK: Scanning helpers

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }

    private static func arrowLength(in scalars: [Unicode.Scalar], at i: Int) -> Int? {
        if scalars[i] == "→" || scalars[i] == "⇒" { return 1 }
        guard i + 1 < scalars.count else { return nil }
        if scalars[i] == "-", scalars[i + 1] == ">" { return 2 }
        if scalars[i] == "=", scalars[i + 1] == ">" { return 2 }
        if i + 2 < scalars.count, scalars[i] == "-", scalars[i + 1] == "-", scalars[i + 2] == ">" { return 3 }
        return nil
    }

    /// Recognizes an immediately attached `(x)` group of 1...12 non-space characters after a
    /// short word, such as the `(1)` in `LL(1)` or the `(A)` in `FIRST(A)`.
    private static func parenthesizedSuffix(
        in scalars: [Unicode.Scalar], at index: Int, wordLength: Int
    ) -> (contentRange: Range<Int>, end: Int)? {
        guard wordLength <= 12, index < scalars.count, scalars[index] == "(" else { return nil }
        var j = index + 1
        while j < scalars.count, j - index <= 13 {
            let scalar = scalars[j]
            if scalar == ")" { return j > index + 1 ? ((index + 1)..<j, j + 1) : nil }
            if scalar == "(" || CharacterSet.whitespacesAndNewlines.contains(scalar) { return nil }
            j += 1
        }
        return nil
    }

    private static func append(_ word: String, to tokens: inout [String], stem: Bool) {
        let canonical = synonyms[word] ?? word
        let isSingleNonASCII = canonical.unicodeScalars.count == 1 && !(canonical.unicodeScalars.first?.isASCII ?? true)
        guard canonical.count >= 2 || isSingleNonASCII else { return }
        guard !stopwords.contains(canonical) else { return }
        tokens.append(stem ? Self.stem(canonical) : canonical)
    }

    // MARK: Stemming

    /// A deliberately light suffix stripper: plurals, `-ing`, `-ed`, and a trailing `e`, so that
    /// "parse", "parses", "parsed" and "parsing" agree without mangling technical terms.
    static func stem(_ word: String) -> String {
        guard word.count > 3, word.allSatisfy({ $0.isLetter }) else { return word }
        var w = word
        if w.hasSuffix("ies"), w.count > 4 {
            w = String(w.dropLast(3)) + "y"
        } else if w.hasSuffix("sses") {
            w = String(w.dropLast(2))
        } else if w.hasSuffix("s"), !w.hasSuffix("ss"), !w.hasSuffix("us"), !w.hasSuffix("is") {
            w = String(w.dropLast())
        }
        for suffix in ["ing", "ed"] where w.hasSuffix(suffix) && w.count - suffix.count >= 3 {
            let base = String(w.dropLast(suffix.count))
            guard base.contains(where: { "aeiouy".contains($0) }) else { break }
            w = undouble(base)
            break
        }
        if w.hasSuffix("e"), w.count > 3 { w.removeLast() }
        return w
    }

    /// "runn" -> "run", but "pass" and "call" keep their double letters.
    private static func undouble(_ base: String) -> String {
        guard let last = base.last, base.dropLast().last == last, !"lszaeiou".contains(last) else { return base }
        return String(base.dropLast())
    }

    private static let synonyms: [String: String] = ["epsilon": "ε", "eps": "ε", "arrow": "->"]

    static let stopwords: Set<String> = [
        "a", "about", "above", "after", "again", "all", "also", "am", "an", "and", "any", "are", "as", "at",
        "be", "because", "been", "before", "being", "below", "between", "both", "but", "by", "can", "could",
        "did", "do", "does", "doing", "don", "down", "during", "each", "few", "for", "from", "further", "get",
        "got", "had", "has", "have", "having", "he", "her", "here", "hers", "him", "his", "how", "if", "in",
        "into", "is", "it", "its", "itself", "just", "let", "lets", "may", "me", "more", "most", "my", "no",
        "nor", "not", "now", "of", "off", "on", "once", "only", "or", "other", "our", "ours", "out", "over",
        "own", "same", "she", "should", "so", "some", "such", "than", "that", "the", "their", "them", "then",
        "there", "these", "they", "this", "those", "through", "to", "too", "under", "until", "up", "us",
        "very", "was", "we", "were", "what", "when", "where", "which", "while", "who", "whom", "why", "will",
        "with", "would", "you", "your", "yours",
        // Spoken-language filler that carries no topic information.
        "actually", "basically", "gonna", "go", "going", "guys", "kind", "know", "like", "okay", "ok", "really",
        "right", "say", "sort", "stuff", "sure", "thing", "things", "think", "today", "um", "uh", "want",
        "well", "yeah", "yes",
    ]
}
