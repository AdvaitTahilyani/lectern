import Foundation
import NaturalLanguage

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

    /// At most `limit` whole sentences of `s` (per the linguistic tokenizer, so "e.g." doesn't end
    /// one). A trailing fragment without terminal punctuation — a reply cut off mid-sentence — is
    /// dropped when earlier sentences remain, otherwise closed with a period.
    static func wholeSentences(_ s: String, limit: Int) -> String {
        let text = collapse(s)
        guard !text.isEmpty else { return "" }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespaces)
            if !sentence.isEmpty { sentences.append(sentence) }
            return true
        }
        if sentences.count > 1, let last = sentences.last, !Self.endsSentence(last) { sentences.removeLast() }
        var kept = Array(sentences.prefix(limit))
        if let last = kept.last, !Self.endsSentence(last) { kept[kept.count - 1] = last + "." }
        return kept.joined(separator: " ")
    }

    private static func endsSentence(_ s: String) -> Bool {
        let closers = CharacterSet(charactersIn: "\"'”’)]")
        let trimmed = s.trimmingCharacters(in: closers)
        return trimmed.last.map { ".!?…".contains($0) } ?? false
    }

    /// At most `maxChars`, always ending at the end of a sentence: the whole sentences that fit,
    /// or, when even the first is too long, that sentence cut at its last clause break (", ",
    /// "; ", ": ", " — ") and closed with a period. Never ends in "…".
    static func fitSentences(_ s: String, maxChars: Int) -> String {
        let text = collapse(s)
        guard text.count > maxChars else { return text }
        var fitted = ""
        for sentence in wholeSentences(text, limit: .max).splitSentences() {
            let next = fitted.isEmpty ? sentence : fitted + " " + sentence
            guard next.count <= maxChars else { break }
            fitted = next
        }
        if !fitted.isEmpty { return fitted }
        let window = String(text.prefix(maxChars - 1))
        let breaks = [", ", "; ", ": ", " — ", " - "].compactMap { window.range(of: $0, options: .backwards)?.lowerBound }
        let cut = breaks.max().flatMap { window.distance(from: window.startIndex, to: $0) >= maxChars / 2 ? $0 : nil }
            ?? window.lastIndex(of: " ") ?? window.endIndex
        var clause = window[..<cut].trimmingCharacters(in: CharacterSet(charactersIn: " ,;:—-"))
        // Don't end on a dangling connective ("…into registers and then.").
        let connectives: Set<String> = ["and", "then", "or", "but", "so", "which", "while", "with", "to", "of", "the", "a", "an", "by", "for", "as", "that", "when"]
        while let space = clause.lastIndex(of: " "), connectives.contains(clause[clause.index(after: space)...].lowercased()) {
            clause = String(clause[..<space]).trimmingCharacters(in: CharacterSet(charactersIn: " ,;:—-"))
        }
        return clause + "."
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

private extension String {
    /// Sentences of already sentence-normalized text (as produced by `Text.wholeSentences`).
    func splitSentences() -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = self
        var result: [String] = []
        tokenizer.enumerateTokens(in: startIndex..<endIndex) { range, _ in
            let sentence = self[range].trimmingCharacters(in: .whitespaces)
            if !sentence.isEmpty { result.append(sentence) }
            return true
        }
        return result
    }
}
