import Foundation
import LecternCore

/// Fixes course jargon the recognizer misheard, using the lecture's own slide deck:
/// "gen expression" → `genExpr`, "L are" → `LR`, "newreg name" → `new_reg_name`, "cfg" → `CFG`.
///
/// It is deliberately conservative. A span of transcript words is replaced only when
/// - its spoken form matches a term that appears in the deck (after phonetic normalization,
///   letter homophones such as "are" → R, and the abbreviations lecturers expand aloud), and
/// - it doesn't read as ordinary English: at least one word must be non-everyday ("gen", "reg",
///   "a0"), or, for an acronym, the words must spell it letter by letter ("L are"). Everyday-word
///   spans are changed in only two narrow cases: an acronym pronounced as a word where "I" can't be
///   the pronoun ("the I lock instructions" → ILOC, never "so I lock it"), and a Greek letter's
///   homophone before a word the deck puts after that letter ("fee function" → "phi function").
/// Spans never cross sentence punctuation, and at most `maxEditsPerSegment` spans change per
/// segment. Only final segments are touched.
public struct TranscriptCorrector: TranscriptCorrecting {
    public let vocabulary: DeckVocabulary
    public let maxEditsPerSegment: Int

    private let termsByKey: [String: [DeckTerm]]
    private let phrases: [DeckTerm]
    private let longestSpan: Int

    public init(vocabulary: DeckVocabulary, maxEditsPerSegment: Int = 3) {
        self.vocabulary = vocabulary
        self.maxEditsPerSegment = maxEditsPerSegment
        var byKey: [String: [DeckTerm]] = [:]
        for term in vocabulary.terms where term.kind != .phrase {
            for key in term.spokenKeys { byKey[key, default: []].append(term) }
        }
        // Spelling variants of one term ("new_reg_name" ×22, "new_Reg_name" ×1): the deck's usual one wins.
        termsByKey = byKey.mapValues { $0.sorted { $0.occurrences > $1.occurrences } }
        phrases = vocabulary.terms.filter { $0.kind == .phrase }
        longestSpan = max(2, min(6, vocabulary.terms.map(\.maxWords).max() ?? 2))
    }

    /// Loads the system word list the phrase check uses (~2 MB, once per process). Call it off the
    /// main actor before correcting live segments, so the first near-miss doesn't stall the UI.
    public static func preloadWordList() {
        _ = EnglishDictionary.contains("lecture")
    }

    public init(deck: SlideDeck, maxEditsPerSegment: Int = 3) {
        self.init(vocabulary: DeckVocabulary(deck: deck), maxEditsPerSegment: maxEditsPerSegment)
    }

    /// One replacement the corrector would make.
    public struct Replacement: Sendable, Hashable {
        /// The words as heard (punctuation around the span excluded).
        public var heard: String
        public var replacement: String
        public var term: String
        /// Character range of `heard` in the input text.
        public var range: Range<String.Index>
    }

    public func correct(_ segment: TranscriptSegment) -> TranscriptSegment {
        guard segment.isFinal, !vocabulary.isEmpty else { return segment }
        let corrected = apply(replacements(in: segment.text), to: segment.text)
        guard corrected != segment.text else { return segment }
        var out = segment
        out.originalText = segment.originalText ?? segment.text
        out.text = corrected
        return out
    }

    /// The text with every accepted replacement applied.
    public func correct(_ text: String) -> String { apply(replacements(in: text), to: text) }

    /// The replacements for `text`, in order, non-overlapping, at most `maxEditsPerSegment`.
    public func replacements(in text: String) -> [Replacement] {
        let words = Word.split(text)
        guard !words.isEmpty else { return [] }
        var candidates: [(start: Int, count: Int, replacement: Replacement)] = []
        for start in words.indices {
            for count in 1...min(longestSpan, words.count - start) {
                // A span ends at sentence punctuation (it may end on that word, not run past it).
                if count > 1, words[start..<(start + count - 1)].contains(where: \.endsClause) { break }
                if let r = match(words, start: start, count: count, in: text) { candidates.append((start, count, r)) }
            }
        }
        // Longest spans first, then earliest; no overlaps; capped.
        var taken = IndexSet()
        var accepted: [(Int, Replacement)] = []
        for c in candidates.sorted(by: { ($0.count, -$0.start) > ($1.count, -$1.start) }) {
            let range = c.start..<(c.start + c.count)
            guard !taken.intersects(integersIn: range), accepted.count < maxEditsPerSegment else { continue }
            taken.insert(integersIn: range)
            accepted.append((c.start, c.replacement))
        }
        return accepted.sorted { $0.0 < $1.0 }.map(\.1)
    }

    // MARK: - Matching one span

    private func match(_ words: [Word], start: Int, count: Int, in text: String) -> Replacement? {
        let span = Array(words[start..<(start + count)])
        guard span.allSatisfy({ !$0.norm.isEmpty }) else { return nil }
        let range = span[0].core.lowerBound..<span[count - 1].core.upperBound
        let heard = String(text[range])
        let previous = start > 0 ? words[start - 1] : nil

        if let greek = greekCollocation(span) {
            return Replacement(heard: heard, replacement: greek, term: greek, range: range)
        }

        let plainKey = SpokenKey.phonetic(span.map(\.norm).joined())
        let letterKey = SpokenKey.phonetic(span.map(\.letterized).joined())
        for key in Set([plainKey, letterKey]) {
            for term in termsByKey[key] ?? [] where count <= term.maxWords + 1 {
                guard heard != term.text else { continue }
                // Case-only fixes just capitalize an all-lower-case word ("cfg" → CFG). Anything the
                // recognizer already capitalized stays: "LLVM" (deck "llvm"), "IRs" (deck "IRS").
                if heard.lowercased() == term.text.lowercased(), heard != heard.lowercased() || term.text == term.text.lowercased() { continue }
                if accepts(span, term: term, key: key, previous: previous) {
                    return Replacement(heard: heard, replacement: term.text, term: term.text, range: range)
                }
            }
        }
        if let phrase = nearPhrase(span, key: plainKey, heard: heard) {
            return Replacement(heard: heard, replacement: phrase.text, term: phrase.text, range: range)
        }
        return nil
    }

    /// The ordinary-English gate for an identifier or acronym match.
    private func accepts(_ span: [Word], term: DeckTerm, key: String, previous: Word?) -> Bool {
        let spelledOut = span.allSatisfy(\.isLetterLike)
        // Short acronyms (LR, CFG, AST) only from one word or a letter-by-letter spelling.
        if term.kind == .acronym, key.count <= 3, span.count > 1, !spelledOut { return false }
        // Two-letter acronyms need a bare letter that can't be a word ("L are", not "I are").
        if term.kind == .acronym, key.count <= 2, span.count > 1, !span.contains(where: \.isBareLetter) { return false }

        if span.contains(where: \.isUnusual) { return true }
        // Spelled letter by letter ("L are", "see F G"); one lone letter is never an acronym ("x" isn't "CS").
        if term.kind == .acronym, span.count >= 2, spelledOut, span.contains(where: \.isBareLetter) { return true }

        // Every word is everyday English. Only an acronym said as a word, starting with "I"
        // where the pronoun reading is impossible ("the I lock code"), gets through.
        guard term.kind == .acronym, term.occurrences >= 2, key.count >= 4, span.count >= 2,
              span[0].norm == "i" || span[0].norm == "eye",
              let previous, Self.nonSubjectContext.contains(previous.norm) else { return false }
        return true
    }

    /// Words after which "I" can't be the subject pronoun (determiners, prepositions, "use").
    static let nonSubjectContext: Set<String> = [
        "the", "a", "an", "this", "these", "those", "our", "your", "their", "its", "his", "her", "my",
        "in", "of", "to", "into", "from", "with", "for", "on", "onto", "like", "called", "using",
        "use", "uses", "via", "about", "than", "any", "some", "each", "every",
    ]

    /// "fee function" → "phi function" when the deck writes φ (or "phi") before "function".
    private func greekCollocation(_ span: [Word]) -> String? {
        guard span.count == 2 else { return nil }
        for (name, followers) in vocabulary.greekCollocations {
            guard DeckVocabulary.greekHomophones[name]?.contains(span[0].norm) == true,
                  followers.contains(SpokenKey.singular(span[1].norm)) else { continue }
            return "\(name) \(span[1].coreText)"
        }
        return nil
    }

    /// A near-miss of a proper title phrase: same words except one, where the heard word is a
    /// non-word close to the deck's ("Hindly Milner" → "Hindley–Milner"). A real English word is
    /// never replaced this way ("core generation" stays, even with "Code Generation" in the deck).
    private func nearPhrase(_ span: [Word], key: String, heard: String) -> DeckTerm? {
        guard span.count >= 2, !phrases.isEmpty else { return nil }
        for phrase in phrases {
            guard phrase.components.count == span.count else { continue }
            let differing = zip(span.map(\.norm), phrase.components).filter { $0.0 != $0.1 }
            guard differing.count == 1, let (heardWord, deckWord) = differing.first else { continue }
            let limit = deckWord.count >= 8 ? 2 : 1
            guard heardWord.count >= 4, heardWord.first == deckWord.first,
                  Self.editDistance(heardWord, deckWord, limit: limit) <= limit,
                  !CommonWords.contains(heardWord), !CommonWords.contains(deckWord),
                  !EnglishDictionary.contains(heardWord) else { continue }
            return phrase
        }
        return nil
    }

    /// Levenshtein distance, giving up (returning `limit + 1`) once it must exceed `limit`.
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var next = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(1, b.count) where !b.isEmpty {
                next[j] = min(row[j] + 1, next[j - 1] + 1, row[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            if next.min() ?? 0 > limit { return limit + 1 }
            row = next
        }
        return a.isEmpty ? b.count : row[b.count]
    }

    // MARK: - Applying

    private func apply(_ replacements: [Replacement], to text: String) -> String {
        var out = text
        for r in replacements.reversed() { out.replaceSubrange(r.range, with: r.replacement) }
        return out
    }
}

// MARK: - Transcript words

/// One whitespace-separated word of a segment, with its punctuation peeled off.
struct Word {
    /// The word without surrounding punctuation, as a range of the segment text.
    var core: Range<String.Index>
    var coreText: String
    /// Lower-cased letters and digits only ("LL(1)," → "ll1").
    var norm: String
    /// `norm` with letter homophones spelled as the letter ("are" → "r", "see" → "c") and a zero
    /// between letters read as O ("a0" → "ao").
    var letterized: String
    /// Followed by sentence punctuation (. , ; : ? !).
    var endsClause: Bool

    /// Not an everyday word, and more than a single character ("gen", "reg", "a0", "cfg").
    var isUnusual: Bool { norm.count >= 2 && !norm.allSatisfy(\.isNumber) && !CommonWords.contains(norm) }
    /// A lone letter that isn't also a word ("L", "R" — not "I" or "a").
    var isBareLetter: Bool { norm.count == 1 && norm.first!.isLetter && norm != "i" && norm != "a" }
    /// A single letter or digit, or a letter homophone ("are", "see").
    var isLetterLike: Bool { letterized.count == 1 }

    static let homophones: [String: String] = [
        "are": "r", "see": "c", "sea": "c", "why": "y", "you": "u", "oh": "o", "owe": "o", "be": "b",
        "bee": "b", "tea": "t", "tee": "t", "eye": "i", "aye": "i", "jay": "j", "kay": "k", "queue": "q",
        "cue": "q", "ex": "x", "gee": "g", "pea": "p", "pee": "p", "dee": "d", "ef": "f", "eff": "f",
        "el": "l", "ell": "l", "em": "m", "en": "n", "es": "s", "ess": "s", "vee": "v", "zee": "z",
        "zed": "z", "aitch": "h",
    ]

    static func split(_ text: String) -> [Word] {
        var words: [Word] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else { index = text.index(after: index); continue }
            var end = index
            while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
            words.append(Word(text, index..<end))
            index = end
        }
        return words
    }

    private init(_ text: String, _ range: Range<String.Index>) {
        var lower = range.lowerBound, upper = range.upperBound
        while lower < upper, !Self.isCoreEdge(text[lower]) { lower = text.index(after: lower) }
        while upper > lower, !Self.isCoreEdge(text[text.index(before: upper)]) { upper = text.index(before: upper) }
        // Keep a closing parenthesis that belongs to the word ("LL(1)").
        if upper < range.upperBound, text[upper] == ")", text[lower..<upper].contains("(") { upper = text.index(after: upper) }
        core = lower..<upper
        coreText = String(text[core])
        norm = coreText.lowercased().filter { ($0.isLetter || $0.isNumber) && $0.isASCII }
        let trailing = text[upper..<range.upperBound]
        endsClause = trailing.contains(where: { ".,;:?!".contains($0) })
        if let letter = Self.homophones[norm] {
            letterized = letter
        } else if norm.contains(where: \.isLetter), norm.contains("0") {
            letterized = norm.replacingOccurrences(of: "0", with: "o")
        } else {
            letterized = norm
        }
    }

    private static func isCoreEdge(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
}
